#!/bin/bash
###############################################################################
# ddl_diff.sh — Compare NTA and SHAHE DDLs to find modified tables
#
# Wrapper script for lib/ddl_diff.py that integrates with the project structure.
#
# Usage:
#   ./ddl_diff.sh                    # Compare data/nta vs data/shahe
#   ./ddl_diff.sh <nta_dir> <shahe_dir>  # Custom directories
#
# Output: List of modified tables (one per line: "db table")
###############################################################################
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export BASE_DIR

source "${BASE_DIR}/config.sh"
source "${LIB_DIR}/common.sh"

# Initialize logging
init_log "ddl_diff"

log "=========================================="
log "DDL Diff Analysis"
log "=========================================="

# Check Python environment
check_python 3.6 || exit 1

# Determine directories
if [ $# -ge 2 ]; then
    NTA_DIR="$1"
    SHAHE_DIR="$2"
else
    NTA_DIR="${DATA_DIR}/nta"
    SHAHE_DIR="${DATA_DIR}/shahe"
fi

log "Comparing DDLs:"
log "  NTA:   ${NTA_DIR}"
log "  SHAHE: ${SHAHE_DIR}"

# Check if directories exist
if [ ! -d "${NTA_DIR}" ]; then
    log_error "NTA directory not found: ${NTA_DIR}"
    log_error "Run export_nta.sh first to generate DDLs"
    exit 1
fi

if [ ! -d "${SHAHE_DIR}" ]; then
    log_error "SHAHE directory not found: ${SHAHE_DIR}"
    log_error "Run export_shahe.sh first to generate DDLs"
    exit 1
fi

# Run Python diff tool
log "Running DDL comparison..."
MODIFIED_TABLES="${DATA_DIR}/work/modified_tables.txt"
mkdir -p "${DATA_DIR}/work"

if python3 "${LIB_DIR}/ddl_diff.py" "${NTA_DIR}" "${SHAHE_DIR}" > "${MODIFIED_TABLES}" 2>> "${_LOG_FILE}"; then
    log "DDL comparison completed"
    
    # Count and display results
    MODIFIED_COUNT=$(wc -l < "${MODIFIED_TABLES}" | tr -d ' ')
    
    if [ "${MODIFIED_COUNT}" -gt 0 ]; then
        log "Found ${MODIFIED_COUNT} modified table(s):"
        while IFS= read -r line; do
            log "  - ${line}"
        done < "${MODIFIED_TABLES}"
        
        log ""
        log "Modified tables list saved to: ${MODIFIED_TABLES}"
        log ""
        log "To sync these tables, run:"
        log "  ./sync_modified_tables.sh"
    else
        log "No modified tables found - DDLs are in sync"
    fi
else
    log_error "DDL comparison failed"
    exit 1
fi

log "=========================================="
log "DDL Diff Analysis Complete"
log "=========================================="
