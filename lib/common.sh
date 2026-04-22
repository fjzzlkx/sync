#!/bin/bash
###############################################################################
# lib/common.sh — Shared utility functions for all TBDS_SYNC scripts
#
# Sourced by entry scripts. Do NOT execute directly.
# Requires: config.sh sourced first (for BASE_DIR, LOG_DIR, etc.)
###############################################################################

# ========================= Logging ===========================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "${_LOG_FILE:-/dev/null}"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "${_LOG_FILE:-/dev/null}" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "${_LOG_FILE:-/dev/null}" >&2
}

# Initialize log file for a given script name.
# Usage: init_log "sync_data"
init_log() {
    local name="$1"
    mkdir -p "${LOG_DIR}"
    _LOG_FILE="${LOG_DIR}/${name}_$(date '+%Y%m%d_%H%M%S').log"
    export _LOG_FILE
    log "Log file: ${_LOG_FILE}"
}

# ========================= Python Environment ================================

# Check if Python 3 is available and meets minimum version requirement.
# Usage: check_python [min_version]
check_python() {
    local min_version="${1:-3.6}"
    
    if ! command -v python3 &>/dev/null; then
        log_error "Python 3 is not installed or not in PATH"
        log_error "Please install Python 3.${min_version#*.}+ to use Python tools"
        return 1
    fi
    
    local py_version
    py_version=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
    
    if [ -z "${py_version}" ]; then
        log_warn "Could not detect Python version, proceeding anyway..."
        return 0
    fi
    
    # Simple version comparison (works for X.Y format)
    if awk "BEGIN {exit !(${py_version} >= ${min_version})}"; then
        log "Python ${py_version} detected (>= ${min_version} required)"
        return 0
    else
        log_error "Python ${py_version} detected, but ${min_version}+ is required"
        return 1
    fi
}

# ========================= Lock File =========================================
# Prevents overlapping runs of the same entry script.

acquire_lock() {
    local lock_name="${1:-default}"
    _LOCK_FILE="${LOG_DIR}/${lock_name}.lock"

    if [ -f "${_LOCK_FILE}" ]; then
        local old_pid
        old_pid=$(cat "${_LOCK_FILE}" 2>/dev/null)
        if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
            log_error "Another instance (PID ${old_pid}) is running. Exiting."
            return 1
        fi
        log_warn "Stale lock file found (PID ${old_pid} dead). Removing."
        rm -f "${_LOCK_FILE}"
    fi

    echo $$ > "${_LOCK_FILE}"
    log "Lock acquired: ${_LOCK_FILE} (PID $$)"
}

release_lock() {
    if [ -n "${_LOCK_FILE:-}" ] && [ -f "${_LOCK_FILE}" ]; then
        rm -f "${_LOCK_FILE}"
        log "Lock released: ${_LOCK_FILE}"
    fi
}

# ========================= HDFS Pre-flight Checks ============================

# Check destination HDFS connectivity.
check_dst_hdfs() {
    log "Checking destination HDFS (${DST_HDFS})..."
    if ! hdfs dfs -test -d "${DST_HDFS}${WAREHOUSE}" 2>/dev/null; then
        log_error "Cannot reach destination HDFS: ${DST_HDFS}${WAREHOUSE}"
        return 1
    fi
    log "Destination HDFS OK."
}

# Check source HDFS HA — at least one NameNode must respond.
check_src_hdfs_ha() {
    log "Checking source HDFS HA NameNodes..."

    local nn1_host="${SRC_NN1%%:*}"
    local nn2_host="${SRC_NN2%%:*}"
    local nn1_port="${SRC_NN1##*:}"
    local nn2_port="${SRC_NN2##*:}"

    local nn1_ok=false nn2_ok=false

    if nc -z -w5 "${nn1_host}" "${nn1_port}" 2>/dev/null; then
        nn1_ok=true
        log "NameNode nn1 (${SRC_NN1}) reachable."
    else
        log_warn "NameNode nn1 (${SRC_NN1}) unreachable."
    fi

    if nc -z -w5 "${nn2_host}" "${nn2_port}" 2>/dev/null; then
        nn2_ok=true
        log "NameNode nn2 (${SRC_NN2}) reachable."
    else
        log_warn "NameNode nn2 (${SRC_NN2}) unreachable."
    fi

    if ! $nn1_ok && ! $nn2_ok; then
        log_error "Both source NameNodes unreachable. Aborting."
        return 1
    fi
    log "Source HDFS HA check passed."
}

# ========================= Summary Reporting =================================

# Print a pass/fail summary table.
# Usage: print_summary  (reads from _RESULTS associative array)
#   declare -A _RESULTS; _RESULTS["db_name"]="OK|FAIL"
print_summary() {
    log "============ Summary ============"
    local fail_count=0
    local db status
    for db in "${!_RESULTS[@]}"; do
        status="${_RESULTS[$db]}"
        log "  ${db} : ${status}"
        [ "${status}" != "OK" ] && ((fail_count++))
    done
    log "================================="
    log "Total: ${#_RESULTS[@]}  Failed: ${fail_count}"
    return ${fail_count}
}

# Alert hook — override this function to send DingTalk/WeChat/email alerts.
send_alert() {
    local message="$1"
    log_warn "ALERT (no handler configured): ${message}"
    # TODO: Add webhook / email integration here.
}

# ========================= Cleanup ===========================================

# Trap helper — call in entry scripts: trap cleanup EXIT
cleanup() {
    release_lock
    log "Script finished."
}
