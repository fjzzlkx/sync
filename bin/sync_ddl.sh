#!/bin/bash
###############################################################################
# sync_ddl.sh — Export DDLs from both NTA and SHAHE clusters
#
# This script orchestrates DDL export from source (NTA) and destination (SHAHE)
# clusters by calling export_nta.sh and export_shahe.sh in parallel.
###############################################################################

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${BASE_DIR}/config.sh"
source "${LIB_DIR}/common.sh"

# Initialize logging
init_log "sync_ddl"

# Trap cleanup on exit
trap cleanup EXIT

# Acquire lock to prevent concurrent runs
acquire_lock "sync_ddl" || exit 1

log "=========================================="
log "Starting DDL export for NTA and SHAHE"
log "=========================================="

# Track results
declare -A _RESULTS

# Export NTA and SHAHE DDLs in parallel
log "Launching parallel DDL exports..."

# Create temporary log files for parallel execution
nta_log="${LOG_DIR}/export_nta_$(date '+%Y%m%d_%H%M%S').log"
shahe_log="${LOG_DIR}/export_shahe_$(date '+%Y%m%d_%H%M%S').log"

# Launch both exports in background
bash "${BASE_DIR}/bin/export_nta.sh" > "${nta_log}" 2>&1 &
nta_pid=$!

bash "${BASE_DIR}/bin/export_shahe.sh" > "${shahe_log}" 2>&1 &
shahe_pid=$!

# Wait for both to complete
log "Waiting for NTA export (PID: ${nta_pid})..."
if wait ${nta_pid}; then
    _RESULTS["nta"]="OK"
    log "NTA DDL export: SUCCESS"
else
    _RESULTS["nta"]="FAIL"
    log_error "NTA DDL export: FAILED (see ${nta_log})"
fi

log "Waiting for SHAHE export (PID: ${shahe_pid})..."
if wait ${shahe_pid}; then
    _RESULTS["shahe"]="OK"
    log "SHAHE DDL export: SUCCESS"
else
    _RESULTS["shahe"]="FAIL"
    log_error "SHAHE DDL export: FAILED (see ${shahe_log})"
fi

# Merge logs into main log
cat "${nta_log}" >> "${_LOG_FILE}"
cat "${shahe_log}" >> "${_LOG_FILE}"

# Print summary
print_summary

log "=========================================="
log "DDL export completed"
log "=========================================="

# Exit with error if any export failed
if [ "${_RESULTS[nta]}" != "OK" ] || [ "${_RESULTS[shahe]}" != "OK" ]; then
    exit 1
fi

exit 0
