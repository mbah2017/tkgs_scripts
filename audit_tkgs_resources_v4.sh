#!/bin/bash

# ==============================================================================
# Script: audit_tkgs_resources.sh
# Description: Iterates through all TKGs clusters in a Supervisor environment.
#              1. Logs into Supervisor using AO credentials.
#              2. Iterates through EVERY Namespace to find Workload Clusters.
#              3. Logs into each Workload Cluster using AD credentials.
#              4. Checks Pod resource requests and flags those exceeding limits.
#              * SUPPORTS PARALLEL EXECUTION WITH CONTEXT ISOLATION *
#              * INCLUDES LOGGING AND VERBOSITY CONTROL *
# Output: CSV file and Log file
# Requirements: kubectl, jq, kubectl-vsphere plugin
# Usage: ./audit_tkgs_resources.sh [-S <supervisor_endpoint>] [-v]
# ==============================================================================

# Define Output Directory
OUTPUT_DIR="$HOME/tmp/tkgs_audit_reports"
mkdir -p "$OUTPUT_DIR" # Ensure the directory exists

CPU_THRESHOLD_M=512     # 512m (millicores)
MEM_THRESHOLD_MI=500    # 500Mi (Mebibytes)
MAX_JOBS=5              # Number of concurrent cluster checks
VERBOSE=false           # Default verbosity

# Verify jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it to run this script."
    exit 1
fi

# ==============================================================================
# 1. Credentials & Setup
# ==============================================================================

# Parse command line arguments
SUPERVISOR_ENDPOINT=""

while getopts "S:v" opt; do
  case ${opt} in
    S)
      SUPERVISOR_ENDPOINT=${OPTARG}
      ;;
    v)
      VERBOSE=true
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

echo "---------------------------------------------------"
echo "Authentication Setup"
echo "---------------------------------------------------"

if [ -z "$SUPERVISOR_ENDPOINT" ]; then
    read -p "Enter Supervisor Endpoint (IP or FQDN): " SUPERVISOR_ENDPOINT
else
    echo "Supervisor Endpoint: $SUPERVISOR_ENDPOINT"
fi

read -p "Enter Supervisor Username (AO Account): " AO_USER
read -s -p "Enter Supervisor Password: " AO_PASSWORD
echo ""
echo "---------------------------------------------------"
read -p "Enter Workload Cluster Username (AD Account): " AD_USER
read -s -p "Enter Workload Cluster Password: " AD_PASSWORD
echo ""
echo "---------------------------------------------------"

# Generate Dynamic Filenames based on Supervisor and Date
CURRENT_DATE=$(date +%Y-%m-%d_%H%M%S)
CLEAN_ENDPOINT=$(echo "$SUPERVISOR_ENDPOINT" | sed 's/[^a-zA-Z0-9.-]//g')

OUTPUT_FILE="${OUTPUT_DIR}/tkgs_audit_${CLEAN_ENDPOINT}_${CURRENT_DATE}.csv"
LOG_FILE="${OUTPUT_DIR}/tkgs_audit_${CLEAN_ENDPOINT}_${CURRENT_DATE}.log"

echo "Output CSV: $OUTPUT_FILE"
echo "Execution Log: $LOG_FILE"

# Logging Function
# Usage: log <LEVEL> <MESSAGE>
# Writes to Log File. Prints to Screen if Level is INFO/ERROR or if VERBOSE is true.
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Write to log file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Write to console based on verbosity
    if [[ "$VERBOSE" == "true" ]] || [[ "$level" == "INFO" ]] || [[ "$level" == "ERROR" ]]; then
        # Use stderr for logs so stdout can remain clean for CSV piping if needed
        echo "[$level] $message" >&2
    fi
}

log "INFO" "Starting Audit Script for Supervisor: $SUPERVISOR_ENDPOINT"
log "INFO" "Thresholds: CPU > ${CPU_THRESHOLD_M}m | RAM > ${MEM_THRESHOLD_MI}Mi"

# Initialize CSV Header
echo "Cluster Name,Namespace,Pod Name,Container Name,CPU Request (m),Memory Request (Mi)" | tee "$OUTPUT_FILE"

log "INFO" "Attempting Supervisor Login..."

# Login to Supervisor using AO credentials
export KUBECTL_VSPHERE_PASSWORD="$AO_PASSWORD"
if ! kubectl vsphere login --server "$SUPERVISOR_ENDPOINT" --vsphere-username "$AO_USER" --insecure-skip-tls-verify > /dev/null 2>&1; then
    log "ERROR" "Failed to login to Supervisor Cluster. Check credentials."
    exit 1
fi

# Capture the current Supervisor context
SUPERVISOR_CONTEXT=$(kubectl config current-context)
log "INFO" "Connected to Supervisor Context: $SUPERVISOR_CONTEXT"

# Create a temporary directory for parallel processing results
WORK_DIR=$(mktemp -d)
log "DEBUG" "Temporary work directory created: $WORK_DIR"

# ==============================================================================
# 2. Parallel Processing Function
# ==============================================================================

audit_cluster() {
    local CLUSTER_NAME=$1
    local SUPERVISOR_NS=$2
    local ENDPOINT=$3
    local USER=$4
    local PASS=$5
    local TEMP_DIR=$6
    local LOG_PATH=$7
    local IS_VERBOSE=$8

    # Function-specific log helper (to append to the main log file correctly)
    local_log() {
        local lvl=$1
        local msg=$2
        local ts=$(date +'%Y-%m-%d %H:%M:%S')
        echo "[$ts] [$lvl] ($CLUSTER_NAME) $msg" >> "$LOG_PATH"
        if [[ "$IS_VERBOSE" == "true" ]] || [[ "$lvl" == "ERROR" ]]; then
             echo "[$lvl] ($CLUSTER_NAME) $msg" >&2
        fi
    }

    local_log "DEBUG" "Starting processing..."

    # CRITICAL: Create a unique KUBECONFIG file for this process.
    export KUBECONFIG=$(mktemp)
    export KUBECTL_VSPHERE_PASSWORD="$PASS"

    # Define output file for this specific cluster thread
    local CLUSTER_OUTPUT="${TEMP_DIR}/${CLUSTER_NAME}_${SUPERVISOR_NS}.csv"
    local PODS_JSON="${TEMP_DIR}/${CLUSTER_NAME}_${SUPERVISOR_NS}_pods.json"

    # Authenticate to the specific Workload Cluster
    local_log "DEBUG" "Attempting login..."
    
    LOGIN_OUTPUT=$(kubectl vsphere login --server "$ENDPOINT" \
        --tanzu-kubernetes-cluster-name "$CLUSTER_NAME" \
        --tanzu-kubernetes-cluster-namespace "$SUPERVISOR_NS" \
        --vsphere-username "$USER" \
        --insecure-skip-tls-verify 2>&1)
    
    if [ $? -ne 0 ]; then
        local_log "ERROR" "Login failed. Details: $LOGIN_OUTPUT"
        rm -f "$KUBECONFIG"
        return
    fi
    
    # VALIDATION: Check if kubeconfig actually has content
    if [ ! -s "$KUBECONFIG" ]; then
        local_log "ERROR" "Login appeared successful but KUBECONFIG is empty. Falls back to localhost. Login Output: $LOGIN_OUTPUT"
        rm -f "$KUBECONFIG"
        return
    fi
    
    local_log "DEBUG" "Login successful."

    # Query Pods - Capture to file first to avoid JQ pipes breaking on non-JSON error text
    local_log "DEBUG" "Querying pods and calculating resources..."
    
    # Capture stderr and stdout to the file to catch everything
    kubectl get pods -A -o json --kubeconfig "$KUBECONFIG" > "$PODS_JSON" 2>&1
    
    # Check if the file is valid JSON using jq exit code
    if ! jq -e . "$PODS_JSON" > /dev/null 2>&1; then
        # Capture the first line to see what the error/text is
        local HEAD_CONTENT=$(head -n 1 "$PODS_JSON")
        local_log "ERROR" "Failed to retrieve valid JSON for pods. Server might have returned a plain text error. Content start: '$HEAD_CONTENT'"
        rm -f "$KUBECONFIG" "$PODS_JSON"
        return
    fi

    # Process valid JSON
    jq -r --arg c_name "$CLUSTER_NAME" \
        --argjson cpu_limit "$CPU_THRESHOLD_M" \
        --argjson mem_limit "$MEM_THRESHOLD_MI" '
        .items[] | 
        {
            podName: .metadata.name,
            namespace: .metadata.namespace,
            containers: .spec.containers[]
        } |
        (.containers.resources.requests.cpu // "0") as $raw_cpu |
        (if ($raw_cpu | contains("m")) then ($raw_cpu | sub("m";"") | tonumber) else (($raw_cpu | tonumber) * 1000) end) as $cpu_m |
        (.containers.resources.requests.memory // "0") as $raw_mem |
        (
            if ($raw_mem | contains("Gi")) then ($raw_mem | sub("Gi";"") | tonumber * 1024)
            elif ($raw_mem | contains("Mi")) then ($raw_mem | sub("Mi";"") | tonumber)
            elif ($raw_mem | contains("Ki")) then ($raw_mem | sub("Ki";"") | tonumber / 1024)
            else ($raw_mem | tonumber / 1048576)
            end
        ) as $mem_mi |
        select($cpu_m > $cpu_limit or $mem_mi > $mem_limit) |
        "\($c_name),\(.namespace),\(.podName),\(.containers.name),\($cpu_m),\($mem_mi)"
    ' "$PODS_JSON" > "$CLUSTER_OUTPUT"
    
    # Result Handling
    if [ -s "$CLUSTER_OUTPUT" ]; then
        local num_pods=$(wc -l < "$CLUSTER_OUTPUT")
        local_log "INFO" "Audit complete. Found $num_pods high-usage containers."
        # Print CSV lines to stdout for visibility (optional)
        cat "$CLUSTER_OUTPUT"
    else
        local_log "DEBUG" "Audit complete. No high usage pods found."
    fi

    # Cleanup unique kubeconfig and temp json
    rm -f "$KUBECONFIG" "$PODS_JSON"
}

# ==============================================================================
# 3. Cluster Discovery & Processing
# ==============================================================================

log "INFO" "---------------------------------------------------"
log "INFO" "Discovering and auditing clusters across all namespaces..."

# Get all namespaces
NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
TOTAL_CLUSTERS_FOUND=0

for NS in $NAMESPACES; do
    # Check for clusters in this namespace
    # Capture to file to validate JSON
    CLUSTERS_JSON="${WORK_DIR}/clusters_${NS}.json"
    kubectl get clusters -n "$NS" -o json > "$CLUSTERS_JSON" 2>/dev/null
    
    # Validate if we got valid JSON with items
    if ! jq -e . "$CLUSTERS_JSON" > /dev/null 2>&1; then
        # This usually means no resources or permissions error, just skip
        rm -f "$CLUSTERS_JSON"
        continue
    fi
    
    NS_COUNT=$(jq '.items | length' "$CLUSTERS_JSON")
    
    if [[ -z "$NS_COUNT" ]] || [[ "$NS_COUNT" -eq 0 ]]; then
        rm -f "$CLUSTERS_JSON"
        continue
    fi
    
    # Increment total
    TOTAL_CLUSTERS_FOUND=$((TOTAL_CLUSTERS_FOUND + NS_COUNT))
    log "INFO" "Found $NS_COUNT clusters in namespace: $NS"

    # Iterate through clusters in this namespace
    # Note: Using a for loop over command substitution avoids subshell issues with 'jobs' logic
    for item in $(jq -r '.items[] | @base64' "$CLUSTERS_JSON"); do
        _jq() {
         echo ${item} | base64 --decode | jq -r ${1}
        }

        CLUSTER_NAME=$(_jq '.metadata.name')
        SUPERVISOR_NS=$NS # We are explicitly in this namespace
        
        log "DEBUG" "Spawning job for cluster: $CLUSTER_NAME (Namespace: $SUPERVISOR_NS)"

        # Spawn background job
        (
            audit_cluster "$CLUSTER_NAME" "$SUPERVISOR_NS" "$SUPERVISOR_ENDPOINT" "$AD_USER" "$AD_PASSWORD" "$WORK_DIR" "$LOG_FILE" "$VERBOSE"
        ) &

        # Job Control: Limit number of parallel jobs
        # Wait if we have reached MAX_JOBS
        while (( $(jobs -r -p | wc -l) >= MAX_JOBS )); do
            wait -n 2>/dev/null || wait
        done

    done
    rm -f "$CLUSTERS_JSON"
done

if [ "$TOTAL_CLUSTERS_FOUND" -eq 0 ]; then
    log "WARN" "No Clusters found in any namespace."
    rm -rf "$WORK_DIR"
    exit 0
fi

# Wait for all remaining background jobs to finish
log "INFO" "Waiting for remaining jobs to complete..."
wait

log "INFO" "---------------------------------------------------"
log "INFO" "Aggregating results..."

# Combine all partial CSVs into the main output file
if ls "$WORK_DIR"/*.csv 1> /dev/null 2>&1; then
    cat "$WORK_DIR"/*.csv >> "$OUTPUT_FILE"
    TOTAL_ROWS=$(wc -l < "$OUTPUT_FILE")
    # Subtract 1 for header
    TOTAL_RECORDS=$((TOTAL_ROWS - 1))
    log "INFO" "Aggregation complete. Total records found: $TOTAL_RECORDS"
else
    log "INFO" "No high resource pods found in any cluster."
fi

# Cleanup
rm -rf "$WORK_DIR"
unset AO_PASSWORD
unset AD_PASSWORD
unset KUBECTL_VSPHERE_PASSWORD

log "INFO" "Audit finished successfully. Report saved to $OUTPUT_FILE"