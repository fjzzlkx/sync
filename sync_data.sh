#!/bin/bash
###############################################################################
# sync_data.sh — Entry Point 1: Daily HDFS DistCp Data Sync
#
# Copies 8 NTA databases from source HDFS to destination HDFS, then runs
# MSCK REPAIR on partition tables.
#
# Usage: ./sync_data.sh
###############################################################################
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=config.sh
source "${BASE_DIR}/config.sh"
# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/distcp.sh
source "${LIB_DIR}/distcp.sh"

# ========================= Main ==============================================

main() {
    init_log "sync_data"
    trap cleanup EXIT

    log "=========================================="
    log " Daily HDFS DistCp Sync — Start"
    log "=========================================="

    # --- Lock ---
    acquire_lock "sync_data" || exit 1

    # --- Pre-flight ---
    check_src_hdfs_ha || exit 1
    check_dst_hdfs    || exit 1

    # --- Sync each database ---
    declare -A _RESULTS
    local has_failure=false

    for db in "${DATABASES[@]}"; do
        if sync_database "${db}"; then
            _RESULTS["${db}"]="OK"
        else
            _RESULTS["${db}"]="FAIL"
            has_failure=true
        fi
    done

    # --- Partition repair ---
    log "Running MSCK REPAIR on partition tables..."
    local msck_sql="${PARTITION_SQL_DIR}/msck_repair.sql"

    if [ -f "${msck_sql}" ]; then
        ${SHAHE_BEELINE_CMD} -f "${msck_sql}" \
            >> "${LOG_DIR}/msck_repair_$(date '+%Y%m%d').log" 2>&1 \
            && log "MSCK REPAIR completed." \
            || log_error "MSCK REPAIR failed (see log)."
    else
        log_warn "No MSCK REPAIR SQL found at ${msck_sql}. Skipping."
    fi

    # --- Summary ---
    if ! print_summary; then
        send_alert "sync_data: some databases failed. Check ${_LOG_FILE}"
    fi

    log "=========================================="
    log " Daily HDFS DistCp Sync — Done"
    log "=========================================="

    ${has_failure} && exit 1 || exit 0
}

main "$@"
