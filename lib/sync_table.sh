#!/bin/bash
###############################################################################
# lib/sync_table.sh — Sync a single table's DDL from NTA to SHAHE
#
# Performs: backup HDFS data → generate target DDL → drop + create → restore
#           → MSCK REPAIR (if partitioned).
#
# Can be sourced (provides sync_single_table function) or executed directly.
#
# Usage (direct):
#   ./sync_table.sh <src_db> <src_table> <dst_db> <dst_table>
#
# Usage (sourced):
#   source lib/sync_table.sh
#   sync_single_table "nta_rh_deal" "some_table" "nta_rh_deal" "some_table"
#
# Requires: config.sh + lib/common.sh sourced first (when sourced).
###############################################################################

# If executed directly, bootstrap config
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    source "${BASE_DIR}/config.sh"
    source "${LIB_DIR}/common.sh"
    init_log "sync_table"

    if [ $# -ne 4 ]; then
        echo "Usage: $0 <src_db> <src_table> <dst_db> <dst_table>" >&2
        exit 1
    fi
    sync_single_table "$@"
    exit $?
fi

# Sync a single table DDL from NTA → SHAHE with rollback safety.
# Args: <src_db> <src_table> <dst_db> <dst_table>
sync_single_table() {
    local src_db="$1" src_tb="$2" dst_db="$3" dst_tb="$4"
    local warehouse="${WAREHOUSE}"

    log "--- sync_single_table: ${src_db}.${src_tb} → ${dst_db}.${dst_tb} ---"

    # Paths
    local table_data="${DST_HDFS}${warehouse}/${dst_db}.db/${dst_tb}"
    local backup_path="${table_data}.bak"
    local work_dir="${DATA_DIR}/work"
    local src_sql="${work_dir}/${src_db}.${src_tb}.src.sql"
    local dst_sql="${work_dir}/${dst_db}.${dst_tb}.dst.sql"

    mkdir -p "${work_dir}"

    # Cleanup stale backup from previous failed runs
    hdfs dfs -rm -r -f "${backup_path}" 2>/dev/null || true

    # ---- Step 1: Backup HDFS data ----
    log "  [1/5] Backup: ${table_data} → ${backup_path}"
    if hdfs dfs -test -d "${table_data}" 2>/dev/null; then
        hdfs dfs -mv "${table_data}" "${backup_path}" || {
            log_error "Failed to backup ${table_data}"
            return 1
        }
    else
        log_warn "  No existing data at ${table_data}, skip backup."
    fi

    # ---- Rollback function ----
    _rollback() {
        log_error "  Rolling back ${dst_db}.${dst_tb}..."
        if hdfs dfs -test -d "${backup_path}" 2>/dev/null; then
            hdfs dfs -rm -r -f "${table_data}" 2>/dev/null || true
            hdfs dfs -mv "${backup_path}" "${table_data}" 2>/dev/null || true
            log "  Rollback complete."
        else
            log_error "  No backup found for rollback!"
        fi
    }

    # ---- Step 2: Get source DDL and generate target DDL ----
    log "  [2/5] Export source DDL: ${src_db}.${src_tb}"
    ${NTA_BEELINE_CMD} --showHeader=false --outputformat=csv2 \
        -e "USE ${src_db}; SHOW CREATE TABLE ${src_db}.${src_tb};" \
        > "${src_sql}" 2>/dev/null

    if [ ! -s "${src_sql}" ]; then
        log_error "  Failed to export source DDL for ${src_db}.${src_tb}"
        _rollback
        return 1
    fi

    # Transform: replace source DB references with destination DB
    # Scoped sed: only replace backtick-quoted and dot-qualified DB names
    sed -e "s/\`${src_db}\`/\`${dst_db}\`/g" \
        -e "s/${src_db}\./${dst_db}\./g" \
        "${src_sql}" > "${dst_sql}"

    if [ ! -s "${dst_sql}" ]; then
        log_error "  Failed to generate target DDL"
        _rollback
        return 1
    fi

    # ---- Step 3: Drop existing table ----
    log "  [3/5] DROP TABLE IF EXISTS ${dst_db}.${dst_tb}"
    ${SHAHE_BEELINE_CMD} -e "DROP TABLE IF EXISTS ${dst_db}.${dst_tb};" 2>/dev/null || {
        log_error "  DROP TABLE failed for ${dst_db}.${dst_tb}"
        _rollback
        return 1
    }

    # ---- Step 4: Create table with new DDL ----
    log "  [4/5] CREATE TABLE from ${dst_sql}"
    ${SHAHE_BEELINE_CMD} -f "${dst_sql}" 2>/dev/null || {
        log_error "  CREATE TABLE failed for ${dst_db}.${dst_tb}"
        _rollback
        return 1
    }

    # ---- Step 5: Restore data ----
    log "  [5/5] Restore data: ${backup_path} → ${table_data}"
    if hdfs dfs -test -d "${backup_path}" 2>/dev/null; then
        # Remove the empty directory created by CREATE TABLE
        hdfs dfs -rm -r -f "${table_data}" 2>/dev/null || true
        hdfs dfs -mv "${backup_path}" "${table_data}" || {
            log_error "  Failed to restore data for ${dst_db}.${dst_tb}"
            return 1
        }
    fi

    # ---- MSCK REPAIR if partitioned ----
    if grep -qi "PARTITIONED BY" "${dst_sql}" 2>/dev/null; then
        log "  Running MSCK REPAIR TABLE ${dst_db}.${dst_tb}"
        ${SHAHE_BEELINE_CMD} -e "MSCK REPAIR TABLE ${dst_db}.${dst_tb};" 2>/dev/null || {
            log_warn "  MSCK REPAIR failed for ${dst_db}.${dst_tb} (non-fatal)"
        }
    fi

    log "--- sync_single_table: ${dst_db}.${dst_tb} DONE ---"
    return 0
}