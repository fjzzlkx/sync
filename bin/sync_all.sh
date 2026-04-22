#!/bin/bash
###############################################################################
# sync_all.sh — Complete sync workflow (data + DDL check in parallel)
#
# This script orchestrates the full sync process:
#   1. Parallel execution:
#      - Task A: DistCp HDFS data sync
#      - Task B: Export DDLs → Compare → Sync modified tables
#   2. Wait for both tasks to complete
#   3. Generate MSCK REPAIR SQL
#   4. Report summary
#
# Usage: ./sync_all.sh
###############################################################################

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${BASE_DIR}/config.sh"
source "${LIB_DIR}/common.sh"

# Initialize logging
init_log "sync_all"

# Trap cleanup on exit
trap cleanup EXIT

# Acquire lock to prevent concurrent runs
acquire_lock "sync_all" || exit 1

log "=========================================="
log "TBDS Complete Sync - Start"
log "=========================================="
log "This will run in parallel:"
log "  Task A: HDFS data sync (distcp)"
log "  Task B: DDL export → compare → sync modified tables"
log ""

# Create temporary log files for parallel tasks
TASK_A_LOG="${LOG_DIR}/task_a_data_sync_$(date '+%Y%m%d_%H%M%S').log"
TASK_B_LOG="${LOG_DIR}/task_b_ddl_sync_$(date '+%Y%m%d_%H%M%S').log"

# Track results
declare -A _RESULTS

# ========================= Task A: Data Sync =================================

task_a_data_sync() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task A: Starting HDFS data sync..." >> "${TASK_A_LOG}"
    
    if bash "${BASE_DIR}/bin/sync_data.sh" >> "${TASK_A_LOG}" 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task A: Data sync completed successfully" >> "${TASK_A_LOG}"
        return 0
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task A: Data sync FAILED" >> "${TASK_A_LOG}"
        return 1
    fi
}

# ========================= Task B: DDL Sync ==================================

task_b_ddl_sync() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: Starting DDL sync workflow..." >> "${TASK_B_LOG}"
    
    # Step 1: Export DDLs from both clusters (parallel)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: Step 1/3 - Exporting DDLs..." >> "${TASK_B_LOG}"
    if ! bash "${BASE_DIR}/bin/sync_ddl.sh" >> "${TASK_B_LOG}" 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: DDL export FAILED" >> "${TASK_B_LOG}"
        return 1
    fi
    
    # Step 2: Compare DDLs
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: Step 2/3 - Comparing DDLs..." >> "${TASK_B_LOG}"
    if ! bash "${BASE_DIR}/tools/ddl_diff.sh" >> "${TASK_B_LOG}" 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: DDL comparison FAILED" >> "${TASK_B_LOG}"
        return 1
    fi
    
    # Check if there are modified tables
    MODIFIED_TABLES="${DATA_DIR}/work/modified_tables.txt"
    if [ ! -f "${MODIFIED_TABLES}" ] || [ ! -s "${MODIFIED_TABLES}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: No modified tables found - DDLs are in sync" >> "${TASK_B_LOG}"
        return 0
    fi
    
    MODIFIED_COUNT=$(wc -l < "${MODIFIED_TABLES}" | tr -d ' ')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: Found ${MODIFIED_COUNT} modified table(s)" >> "${TASK_B_LOG}"
    
    # Step 3: Sync modified tables
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: Step 3/3 - Syncing modified tables..." >> "${TASK_B_LOG}"
    if ! bash "${BASE_DIR}/tools/sync_modified_tables.sh" >> "${TASK_B_LOG}" 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: Modified tables sync FAILED" >> "${TASK_B_LOG}"
        return 1
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task B: DDL sync workflow completed successfully" >> "${TASK_B_LOG}"
    return 0
}

# ========================= Launch Parallel Tasks =============================

log "Launching parallel tasks..."
log "  Task A log: ${TASK_A_LOG}"
log "  Task B log: ${TASK_B_LOG}"
log ""

# Launch Task A in background
task_a_data_sync &
TASK_A_PID=$!
log "Task A (Data Sync) started with PID: ${TASK_A_PID}"

# Launch Task B in background
task_b_ddl_sync &
TASK_B_PID=$!
log "Task B (DDL Sync) started with PID: ${TASK_B_PID}"

log ""
log "Both tasks running in parallel. Waiting for completion..."
log ""

# ========================= Wait for Tasks ====================================

# Wait for Task A
log "Waiting for Task A (Data Sync) to complete..."
if wait ${TASK_A_PID}; then
    _RESULTS["task_a_data_sync"]="OK"
    log "✓ Task A (Data Sync): SUCCESS"
else
    _RESULTS["task_a_data_sync"]="FAIL"
    log_error "✗ Task A (Data Sync): FAILED"
fi

# Wait for Task B
log "Waiting for Task B (DDL Sync) to complete..."
if wait ${TASK_B_PID}; then
    _RESULTS["task_b_ddl_sync"]="OK"
    log "✓ Task B (DDL Sync): SUCCESS"
else
    _RESULTS["task_b_ddl_sync"]="FAIL"
    log_error "✗ Task B (DDL Sync): FAILED"
fi

log ""
log "Both tasks completed. Merging logs..."

# Merge task logs into main log
echo "" >> "${_LOG_FILE}"
echo "==================== Task A: Data Sync Log ====================" >> "${_LOG_FILE}"
cat "${TASK_A_LOG}" >> "${_LOG_FILE}"
echo "" >> "${_LOG_FILE}"
echo "==================== Task B: DDL Sync Log ====================" >> "${_LOG_FILE}"
cat "${TASK_B_LOG}" >> "${_LOG_FILE}"
echo "" >> "${_LOG_FILE}"

# ========================= Post-Sync: MSCK REPAIR ============================

log "=========================================="
log "Post-Sync: Generate MSCK REPAIR SQL"
log "=========================================="

if bash "${BASE_DIR}/tools/generate_msck.sh" >> "${_LOG_FILE}" 2>&1; then
    log "MSCK REPAIR SQL generated successfully"
    log "To execute: /bin/SHAHE_BEELINE -f ${PARTITION_SQL_DIR}/msck_repair.sql"
else
    log_warn "MSCK REPAIR SQL generation failed (non-fatal)"
fi

# ========================= Summary ===========================================

log ""
log "=========================================="
log "TBDS Complete Sync - Summary"
log "=========================================="

print_summary

# Detailed status
log ""
log "Detailed Status:"
log "  Task A (Data Sync):  ${_RESULTS[task_a_data_sync]}"
log "  Task B (DDL Sync):   ${_RESULTS[task_b_ddl_sync]}"
log ""
log "Logs:"
log "  Main log:   ${_LOG_FILE}"
log "  Task A log: ${TASK_A_LOG}"
log "  Task B log: ${TASK_B_LOG}"
log ""

# Check if any task failed
if [ "${_RESULTS[task_a_data_sync]}" != "OK" ] || [ "${_RESULTS[task_b_ddl_sync]}" != "OK" ]; then
    log_error "Some tasks failed. Please check the logs above."
    log "=========================================="
    exit 1
fi

log "All tasks completed successfully!"
log "=========================================="
exit 0
