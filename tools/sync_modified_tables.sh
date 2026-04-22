#!/bin/bash
###############################################################################
# sync_modified_tables.sh — Sync only tables with DDL changes
#
# Reads the modified tables list from ddl_diff.sh and syncs them using
# lib/sync_table.sh. This is more efficient than syncing all tables.
#
# Usage:
#   ./ddl_diff.sh                    # First, identify modified tables
#   ./sync_modified_tables.sh        # Then, sync only those tables
#
# Prerequisites: Run ddl_diff.sh first to generate modified_tables.txt
###############################################################################
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${BASE_DIR}/config.sh"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/sync_table.sh"

# Initialize logging
init_log "sync_modified_tables"

# Trap cleanup on exit
trap cleanup EXIT

# Acquire lock to prevent concurrent runs
acquire_lock "sync_modified_tables" || exit 1

log "=========================================="
log "Sync Modified Tables"
log "=========================================="

# Check for modified tables list
MODIFIED_TABLES="${DATA_DIR}/work/modified_tables.txt"

if [ ! -f "${MODIFIED_TABLES}" ]; then
    log_error "Modified tables list not found: ${MODIFIED_TABLES}"
    log_error "Run ./ddl_diff.sh first to identify modified tables"
    exit 1
fi

# Count tables
TOTAL_COUNT=$(wc -l < "${MODIFIED_TABLES}" | tr -d ' ')

if [ "${TOTAL_COUNT}" -eq 0 ]; then
    log "No modified tables to sync"
    exit 0
fi

log "Found ${TOTAL_COUNT} modified table(s) to sync"

# Track results
declare -A _RESULTS
SUCCESS_COUNT=0
FAIL_COUNT=0

# Sync each modified table
while IFS=' ' read -r db table; do
    [ -z "${db}" ] && continue
    [ -z "${table}" ] && continue
    
    log "Syncing ${db}.${table}..."
    
    if sync_single_table "${db}" "${table}" "${db}" "${table}"; then
        _RESULTS["${db}.${table}"]="OK"
        ((SUCCESS_COUNT++))
        log "  ✓ ${db}.${table} synced successfully"
    else
        _RESULTS["${db}.${table}"]="FAIL"
        ((FAIL_COUNT++))
        log_error "  ✗ ${db}.${table} sync failed"
    fi
done < "${MODIFIED_TABLES}"

# Print summary
log "=========================================="
log "Sync Summary"
log "=========================================="
log "Total:   ${TOTAL_COUNT}"
log "Success: ${SUCCESS_COUNT}"
log "Failed:  ${FAIL_COUNT}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    log_error "Some tables failed to sync"
    print_summary
    exit 1
fi

log "All modified tables synced successfully"
log "=========================================="
exit 0
