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
