#!/bin/bash

# ==============================================================================
# Script: audit_tkgs_conformance.sh
# Description: Iterates through all TKGs clusters in a Supervisor environment.
#              1. Logs into Supervisor using AO credentials.
#              2. Iterates through EVERY Namespace to find Workload Clusters.
#              3. Logs into each Workload Cluster using AD credentials.
#              4. Scans all Pods for CNCF/Cloud-Native Best Practice Violations.
#
# Checks Performed (Non-Conformance Flags):
#   - Privileged Containers
#   - Missing Liveness or Readiness Probes
#   - Missing Resource Limits
#   - Usage of mutable ':latest' image tags
#
# Output: CSV file and Log file
# Usage: ./audit_tkgs_conformance.sh [-S <supervisor_endpoint>] [-v]
# ==============================================================================

# Define Output Directory
OUTPUT_DIR="$HOME/tmp/tkgs_conformance_reports"
mkdir -p "$OUTPUT_DIR" # Ensure the directory exists

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

OUTPUT_FILE="${OUTPUT_DIR}/conformance_audit_${CLEAN_ENDPOINT}_${CURRENT_DATE}.csv"
LOG_FILE="${OUTPUT_DIR}/conformance_audit_${CLEAN_ENDPOINT}_${CURRENT_DATE}.log"

echo "Output CSV: $OUTPUT_FILE"
echo "Execution Log: $LOG_FILE"

# Logging Function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    if [[ "$VERBOSE" == "true" ]] || [[ "$level" == "INFO" ]] || [[ "$level" == "ERROR" ]]; then
        echo "[$level] $message" >&2
    fi
}

log "INFO" "Starting Conformance Audit for Supervisor: $SUPERVISOR_ENDPOINT"

# Initialize CSV Header
echo "Cluster Name,Namespace,Pod Name,Container Name,Non-Conformant Behavior,Image Used" | tee "$OUTPUT_FILE"

log "INFO" "Attempting Supervisor Login..."

# Login to Supervisor using AO credentials
export KUBECTL_VSPHERE_PASSWORD="$AO_PASSWORD"
if ! kubectl vsphere login --server "$SUPERVISOR_ENDPOINT" --vsphere-username "$AO_USER" --insecure-skip-tls-verify > /dev/null 2>&1; then
    log "ERROR" "Failed to login to Supervisor Cluster. Check credentials."
    exit 1
fi

SUPERVISOR_CONTEXT=$(kubectl config current-context)
log "INFO" "Connected to Supervisor Context: $SUPERVISOR_CONTEXT"

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

    export KUBECONFIG=$(mktemp)
    export KUBECTL_VSPHERE_PASSWORD="$PASS"

    local CLUSTER_OUTPUT="${TEMP_DIR}/${CLUSTER_NAME}_${SUPERVISOR_NS}.csv"
    local PODS_JSON="${TEMP_DIR}/${CLUSTER_NAME}_${SUPERVISOR_NS}_pods.json"
    local CMD_LOG="${TEMP_DIR}/${CLUSTER_NAME}_${SUPERVISOR_NS}.cmd.log"

    # Authenticate to Workload Cluster
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
    
    if [ ! -s "$KUBECONFIG" ]; then
        local_log "ERROR" "Login successful but KUBECONFIG is empty."
        rm -f "$KUBECONFIG"
        return
    fi
    
    local_log "DEBUG" "Login successful."

    # Query Pods
    local_log "DEBUG" "Scanning pods for conformance issues..."
    kubectl get pods -A -o json --kubeconfig "$KUBECONFIG" > "$PODS_JSON" 2> "$CMD_LOG"
    
    if [ ! -s "$PODS_JSON" ]; then
        local ERR_MSG=$(cat "$CMD_LOG" | head -n 1)
        local_log "ERROR" "Failed to retrieve pods. Error: '$ERR_MSG'"
        rm -f "$KUBECONFIG" "$PODS_JSON" "$CMD_LOG"
        return
    fi

    if ! jq -e . "$PODS_JSON" > /dev/null 2>&1; then
        local HEAD_CONTENT=$(head -n 5 "$PODS_JSON")
        local_log "ERROR" "Invalid JSON output from kubectl. Dump: $HEAD_CONTENT"
        rm -f "$KUBECONFIG" "$PODS_JSON" "$CMD_LOG"
        return
    fi

    # --------------------------------------------------------------------------
    # JQ Filter: Check for Conformance Violations
    # --------------------------------------------------------------------------
    jq -r --arg c_name "$CLUSTER_NAME" '
        .items[] | 
        .metadata.name as $pod |
        .metadata.namespace as $ns |
        .spec.containers[] |
        .name as $cname |
        .image as $img |
        
        # Collect violations into a list to ensure multiple issues are reported per container
        (
            [
              if (.securityContext.privileged == true) then "Security Violation: Privileged Container" else empty end,
              if (.livenessProbe == null) then "Reliability Violation: Missing Liveness Probe" else empty end,
              if (.readinessProbe == null) then "Reliability Violation: Missing Readiness Probe" else empty end,
              if (.resources.limits == null) then "Resiliency Violation: Missing Resource Limits" else empty end,
              if (.image | endswith(":latest")) then "Best Practice Violation: Using latest Tag" else empty end
            ]
        ) as $violations |
        
        # Output one row per violation found
        $violations[] |
        
        "\($c_name),\($ns),\($pod),\($cname),\(.),\($img)"
    ' "$PODS_JSON" > "$CLUSTER_OUTPUT" 2>> "$CMD_LOG"
    
    if [ $? -ne 0 ]; then
        local JQ_ERR=$(cat "$CMD_LOG")
        local_log "ERROR" "JQ Parsing Failed. Details: $JQ_ERR"
        rm -f "$KUBECONFIG" "$PODS_JSON" "$CMD_LOG"
        return
    fi
    
    if [ -s "$CLUSTER_OUTPUT" ]; then
        local num_issues=$(wc -l < "$CLUSTER_OUTPUT")
        local_log "INFO" "Audit complete. Found $num_issues non-conformant items."
        cat "$CLUSTER_OUTPUT"
    else
        local_log "DEBUG" "Audit complete. All pods are conformant."
    fi

    rm -f "$KUBECONFIG" "$PODS_JSON" "$CMD_LOG"
}

# ==============================================================================
# 3. Cluster Discovery & Processing
# ==============================================================================

log "INFO" "---------------------------------------------------"
log "INFO" "Discovering clusters..."

NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
TOTAL_CLUSTERS_FOUND=0

for NS in $NAMESPACES; do
    CLUSTERS_JSON="${WORK_DIR}/clusters_${NS}.json"
    kubectl get clusters -n "$NS" -o json > "$CLUSTERS_JSON" 2>/dev/null
    
    if ! jq -e . "$CLUSTERS_JSON" > /dev/null 2>&1; then
        rm -f "$CLUSTERS_JSON"
        continue
    fi
    
    NS_COUNT=$(jq '.items | length' "$CLUSTERS_JSON")
    
    if [[ -z "$NS_COUNT" ]] || [[ "$NS_COUNT" -eq 0 ]]; then
        rm -f "$CLUSTERS_JSON"
        continue
    fi
    
    TOTAL_CLUSTERS_FOUND=$((TOTAL_CLUSTERS_FOUND + NS_COUNT))
    log "INFO" "Found $NS_COUNT clusters in namespace: $NS"

    for item in $(jq -r '.items[] | @base64' "$CLUSTERS_JSON"); do
        _jq() { echo ${item} | base64 --decode | jq -r ${1}; }

        CLUSTER_NAME=$(_jq '.metadata.name')
        SUPERVISOR_NS=$NS
        
        log "DEBUG" "Spawning check for: $CLUSTER_NAME ($SUPERVISOR_NS)"

        (
            audit_cluster "$CLUSTER_NAME" "$SUPERVISOR_NS" "$SUPERVISOR_ENDPOINT" "$AD_USER" "$AD_PASSWORD" "$WORK_DIR" "$LOG_FILE" "$VERBOSE"
        ) &

        while (( $(jobs -r -p | wc -l) >= MAX_JOBS )); do
            wait -n 2>/dev/null || wait
        done

    done
    rm -f "$CLUSTERS_JSON"
done

if [ "$TOTAL_CLUSTERS_FOUND" -eq 0 ]; then
    log "WARN" "No Clusters found."
    rm -rf "$WORK_DIR"
    exit 0
fi

log "INFO" "Waiting for jobs to complete..."
wait

log "INFO" "---------------------------------------------------"
log "INFO" "Aggregating results..."

if ls "$WORK_DIR"/*.csv 1> /dev/null 2>&1; then
    cat "$WORK_DIR"/*.csv >> "$OUTPUT_FILE"
    TOTAL_ROWS=$(wc -l < "$OUTPUT_FILE")
    TOTAL_RECORDS=$((TOTAL_ROWS - 1))
    log "INFO" "Done. Total violations found: $TOTAL_RECORDS"
else
    log "INFO" "No violations found in any cluster."
fi

rm -rf "$WORK_DIR"
unset AO_PASSWORD
unset AD_PASSWORD
unset KUBECTL_VSPHERE_PASSWORD

log "INFO" "Conformance report saved to $OUTPUT_FILE"