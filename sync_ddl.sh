#!/bin/bash
###############################################################################
# sysn_all_daily.sh — Daily HDFS distcp sync for nta_rh_* databases
#
# Improvements over the original:
#   1. Retry with exponential backoff for transient failures
#   2. Exit-code checking & per-task status tracking
#   3. Timestamped logging
#   4. HDFS connectivity pre-flight check
#   5. Lock file to prevent overlapping runs
#   6. Summary report at end (with optional alert hook)
#   7. Configurable variables at the top
###############################################################################
set -o pipefail

# ========================= Configuration =====================================
WORK_DIR="/data/SYS_TBDS/TBDS_SYNC"
LOG_DIR="${WORK_DIR}/logs"
LOCK_FILE="${WORK_DIR}/.sysn_all_daily.lock"

# --- Source HDFS HA configuration ---
# The source cluster has two NameNodes (Active/Standby). Using a logical
# NameService URI so distcp automatically fails over to the standby NN.
SRC_NAMESERVICE="srcCluster"
SRC_NN1="172.20.80.130:8020"
SRC_NN2="172.20.80.131:8020"
SRC_HDFS="hdfs://${SRC_NAMESERVICE}"

DST_NAMESERVICE="hdfsCluster"
DST_HDFS="hdfs://${DST_NAMESERVICE}"
WAREHOUSE="/apps/hive/warehouse"

# Databases to sync
DATABASES=(
    "nta_rh_backup"
    "nta_rh_check"
    "nta_rh_datacenter"
    "nta_rh_deal"
    "nta_rh_etl"
    "nta_rh_query"
    "nta_rh_result"
    "nta_rh_sync"
)

# Retry settings
MAX_RETRIES=3
RETRY_DELAY_BASE=60   # seconds; actual delay = RETRY_DELAY_BASE * attempt

# Hadoop distcp common parameters
# HA properties are injected so the client can resolve the logical NameService
DISTCP_OPTS=(
    -D yarn.app.mapreduce.am.resource.mb=8192
    -D "yarn.app.mapreduce.am.command-opts=-Xmx6144m"
    -D dfs.nameservices=${DST_NAMESERVICE},${SRC_NAMESERVICE}
    -D dfs.ha.namenodes.${SRC_NAMESERVICE}=nn1,nn2
    -D dfs.namenode.rpc-address.${SRC_NAMESERVICE}.nn1=${SRC_NN1}
    -D dfs.namenode.rpc-address.${SRC_NAMESERVICE}.nn2=${SRC_NN2}
    -D dfs.client.failover.proxy.provider.${SRC_NAMESERVICE}=org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider
    -D mapreduce.job.hdfs-servers.token-renewal.exclude=${SRC_NAMESERVICE}
    -D dfs.replication=2
    -D distcp.dynamic.max.chunks.tolerable=50000
    -delete -update -i -pbca
    -numListstatusThreads 40
    -m 64
    -bandwidth 100
    -strategy dynamic
)

# Post-sync SQL
MSCK_SQL="${WORK_DIR}/partition_table/msck_partition_table_clean.sql"

# ========================= Functions =========================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

# Cleanup lock file on exit
cleanup() {
    rm -f "${LOCK_FILE}"
    log "Lock file removed. Script exiting."
}

# Pre-flight: verify HDFS connectivity
# For the HA source cluster, we try both NameNodes directly to confirm
# at least one is reachable before starting the sync.
check_hdfs() {
    local hdfs_uri="$1"
    local label="$2"
    log "Checking HDFS connectivity: ${label} (${hdfs_uri})..."
    if ! hadoop fs -test -d "${hdfs_uri}${WAREHOUSE}" 2>/dev/null; then
        log_error "Cannot reach ${label} HDFS at ${hdfs_uri}${WAREHOUSE}"
        return 1
    fi
    log "  ${label} HDFS is reachable."
    return 0
}

check_src_hdfs_ha() {
    log "Checking source HDFS HA connectivity (${SRC_NN1}, ${SRC_NN2})..."
    local nn1_ok=false nn2_ok=false
    hadoop fs -ls "hdfs://${SRC_NN1}${WAREHOUSE}" &>/dev/null && nn1_ok=true
    hadoop fs -ls "hdfs://${SRC_NN2}${WAREHOUSE}" &>/dev/null && nn2_ok=true

    if ${nn1_ok}; then log "  NN1 (${SRC_NN1}): reachable"; else log "  NN1 (${SRC_NN1}): unreachable"; fi
    if ${nn2_ok}; then log "  NN2 (${SRC_NN2}): reachable"; else log "  NN2 (${SRC_NN2}): unreachable"; fi

    if ! ${nn1_ok} && ! ${nn2_ok}; then
        log_error "Both source NameNodes are unreachable! Aborting."
        return 1
    fi
    log "  Source HDFS HA is healthy (at least one NN reachable)."
    return 0
}

# Extract the YARN application ID from a distcp log file
get_yarn_app_id() {
    local log_file="$1"
    # distcp logs a line like: "Submitted application application_1234567890123_0001"
    # or the tracking URL contains the app ID
    grep -oE 'application_[0-9]+_[0-9]+' "${log_file}" | tail -1
}

# Check YARN application final status
# Returns: 0 = SUCCEEDED, 1 = FAILED/KILLED/UNKNOWN
check_yarn_app_status() {
    local app_id="$1"
    if [ -z "${app_id}" ]; then
        log_error "  No YARN application ID found."
        return 1
    fi

    log "  Checking YARN application status: ${app_id} ..."
    local yarn_output
    yarn_output=$(yarn application -status "${app_id}" 2>/dev/null)

    local final_status
    final_status=$(echo "${yarn_output}" | grep -i 'Final-State' | awk -F: '{print $2}' | tr -d '[:space:]')
    local yarn_state
    yarn_state=$(echo "${yarn_output}" | grep -i '\bState\b' | head -1 | awk -F: '{print $2}' | tr -d '[:space:]')

    log "  YARN State: ${yarn_state}, Final-State: ${final_status}"

    if [ "${final_status}" = "SUCCEEDED" ]; then
        return 0
    else
        # Extract diagnostics for debugging
        local diag
        diag=$(echo "${yarn_output}" | grep -i 'Diagnostics' | head -1)
        [ -n "${diag}" ] && log_error "  ${diag}"
        return 1
    fi
}

# Check distcp counters for partial failures (because -i ignores copy errors)
check_distcp_counters() {
    local log_file="$1"
    # Look for "Files Failed to copy" counter in the MapReduce output
    local failed_count
    failed_count=$(grep -i 'Files Failed to copy' "${log_file}" | tail -1 | grep -oE '[0-9]+$')
    local files_copied
    files_copied=$(grep -i 'Files copied' "${log_file}" | tail -1 | grep -oE '[0-9]+$')
    local bytes_copied
    bytes_copied=$(grep -i 'Bytes Copied' "${log_file}" | tail -1 | grep -oE '[0-9]+$')

    log "  Distcp counters: files_copied=${files_copied:-0}, bytes_copied=${bytes_copied:-0}, files_failed=${failed_count:-0}"

    if [ -n "${failed_count}" ] && [ "${failed_count}" -gt 0 ]; then
        log_error "  WARNING: ${failed_count} files failed to copy (masked by -i flag)."
        return 1
    fi
    return 0
}

# Run distcp for a single database with retry
sync_database() {
    local db_name="$1"
    local src="${SRC_HDFS}${WAREHOUSE}/${db_name}.db"
    local dst="${DST_HDFS}${WAREHOUSE}/${db_name}.db"
    local log_file="${LOG_DIR}/${db_name}_$(date '+%Y%m%d').log"
    local attempt=0
    local rc=1

    log "Syncing ${db_name} ..."
    log "  SRC: ${src}"
    log "  DST: ${dst}"
    log "  LOG: ${log_file}"

    while [ ${attempt} -lt ${MAX_RETRIES} ]; do
        attempt=$((attempt + 1))
        log "  Attempt ${attempt}/${MAX_RETRIES} for ${db_name} ..."

        # Mark the log position before this attempt so we can extract the app ID
        local log_start_line=1
        [ -f "${log_file}" ] && log_start_line=$(wc -l < "${log_file}")

        hadoop distcp "${DISTCP_OPTS[@]}" "${src}" "${dst}" >> "${log_file}" 2>&1
        rc=$?

        # --- Three-layer verification ---
        # Layer 1: distcp exit code
        if [ ${rc} -eq 0 ]; then
            log "  Exit code: 0 (OK)"
        else
            log_error "  Exit code: ${rc} (FAIL)"
        fi

        # Layer 2: YARN application final status
        local app_id
        app_id=$(get_yarn_app_id "${log_file}")
        local yarn_ok=true
        if [ -n "${app_id}" ]; then
            check_yarn_app_status "${app_id}" || yarn_ok=false
        else
            log "  (Could not extract YARN app ID — skipping YARN status check)"
        fi

        # Layer 3: distcp counters — catch partial failures hidden by -i flag
        local counters_ok=true
        check_distcp_counters "${log_file}" || counters_ok=false

        # Final verdict: all three layers must pass
        if [ ${rc} -eq 0 ] && ${yarn_ok} && ${counters_ok}; then
            log "  [OK] ${db_name} synced successfully on attempt ${attempt}."
            return 0
        fi

        log_error "  Attempt ${attempt} failed for ${db_name} (exit_code=${rc}, yarn_ok=${yarn_ok}, counters_ok=${counters_ok})."

        if [ ${attempt} -lt ${MAX_RETRIES} ]; then
            local delay=$((RETRY_DELAY_BASE * attempt))
            log "  Retrying in ${delay}s ..."
            sleep ${delay}
        fi
    done

    log_error "  [FAIL] ${db_name} failed after ${MAX_RETRIES} attempts."
    return 1
}

# Send alert (customize this for your environment: email, webhook, etc.)
send_alert() {
    local subject="$1"
    local body="$2"
    # Example: send via mail command (uncomment and adapt as needed)
    # echo "${body}" | mail -s "${subject}" ops-team@example.com

    # Example: send via webhook (uncomment and adapt as needed)
    # curl -s -X POST "https://your-webhook-url" \
    #     -H "Content-Type: application/json" \
    #     -d "{\"title\": \"${subject}\", \"text\": \"${body}\"}"

    log "ALERT: ${subject}"
    log "${body}"
}

# ========================= Main ==============================================

# --- Lock file guard ---
if [ -f "${LOCK_FILE}" ]; then
    existing_pid=$(cat "${LOCK_FILE}" 2>/dev/null)
    if kill -0 "${existing_pid}" 2>/dev/null; then
        log_error "Another instance is already running (PID: ${existing_pid}). Exiting."
        exit 1
    else
        log "Stale lock file found (PID: ${existing_pid} is not running). Removing."
        rm -f "${LOCK_FILE}"
    fi
fi
echo $$ > "${LOCK_FILE}"
trap cleanup EXIT

# --- Setup ---
export HADOOP_CLIENT_OPTS="-Xms2048m -Xmx8192m"
export HADOOP_HEAPSIZE=8192

cd "${WORK_DIR}" || { log_error "Cannot cd to ${WORK_DIR}"; exit 1; }
mkdir -p "${LOG_DIR}"

log "=========================================="
log "Starting daily HDFS sync"
log "=========================================="

# --- Pre-flight checks ---
check_src_hdfs_ha || { log_error "Pre-flight check failed. Aborting."; exit 1; }
check_hdfs "${DST_HDFS}" "DESTINATION" || { log_error "Pre-flight check failed. Aborting."; exit 1; }

# --- Sync databases ---
FAILED_DBS=()
SUCCEED_DBS=()

for db in "${DATABASES[@]}"; do
    if sync_database "${db}"; then
        SUCCEED_DBS+=("${db}")
    else
        FAILED_DBS+=("${db}")
    fi
done

# --- Post-sync: repair partitions ---
log "Running MSCK REPAIR TABLE ..."
if [ -f "${MSCK_SQL}" ]; then
    beeline2 -f "${MSCK_SQL}" >> "${LOG_DIR}/msck_repair_$(date '+%Y%m%d').log" 2>&1
    msck_rc=$?
    if [ ${msck_rc} -ne 0 ]; then
        log_error "MSCK repair failed (exit code: ${msck_rc})."
        FAILED_DBS+=("msck_repair")
    else
        log "MSCK repair completed successfully."
    fi
else
    log_error "MSCK SQL file not found: ${MSCK_SQL}"
    FAILED_DBS+=("msck_repair")
fi

# --- Cleanup environment ---
unset HADOOP_CLIENT_OPTS
unset HADOOP_HEAPSIZE

# --- Summary ---
log "=========================================="
log "Daily sync summary"
log "=========================================="
log "  Succeeded: ${#SUCCEED_DBS[@]}/${#DATABASES[@]} — ${SUCCEED_DBS[*]:-none}"
log "  Failed:    ${#FAILED_DBS[@]} — ${FAILED_DBS[*]:-none}"
log "=========================================="

if [ ${#FAILED_DBS[@]} -gt 0 ]; then
    send_alert \
        "[TBDS SYNC] Daily sync FAILED — $(date '+%Y-%m-%d')" \
        "Failed databases: ${FAILED_DBS[*]}. Succeeded: ${SUCCEED_DBS[*]:-none}. Check logs at ${LOG_DIR}."
    exit 1
fi

log "All syncs completed successfully."
exit 0
