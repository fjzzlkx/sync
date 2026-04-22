#!/bin/bash
###############################################################################
# lib/distcp.sh — DistCp with retry and three-layer verification
#
# Sourced by sync_data.sh. Do NOT execute directly.
# Requires: config.sh + lib/common.sh sourced first.
###############################################################################

# Run distcp for a single database with retry and verification.
# Usage: sync_database <db_name>
# Returns: 0 on success, 1 on failure after all retries exhausted.
sync_database() {
    local db="$1"
    local src_path="${SRC_HDFS}${WAREHOUSE}/${db}.db"
    local dst_path="${DST_HDFS}${WAREHOUSE}/${db}.db"

    log "======== Syncing: ${db} ========"
    log "  Source: ${src_path}"
    log "  Dest:   ${dst_path}"

    local attempt=0
    while (( attempt < MAX_RETRIES )); do
        ((attempt++))
        log "Attempt ${attempt}/${MAX_RETRIES} for ${db}..."

        local distcp_log="${LOG_DIR}/distcp_${db}_$(date '+%Y%m%d_%H%M%S').log"

        # Set Hadoop JVM options ONLY for distcp (not for beeline commands)
        export HADOOP_CLIENT_OPTS="-Xms2048m -Xmx8192m"
        export HADOOP_HEAPSIZE=8192

        # ------- Run distcp -------
        hadoop distcp "${DISTCP_OPTS[@]}" "${src_path}" "${dst_path}" \
            > "${distcp_log}" 2>&1
        local exit_code=$?

        # ------- Layer 1: Exit code -------
        if (( exit_code != 0 )); then
            log_error "[Layer1] distcp exit code = ${exit_code} for ${db}"
            _retry_or_fail "${db}" "${attempt}" "${distcp_log}" && continue || return 1
        fi
        log "[Layer1] distcp exit code = 0 (OK)"

        # ------- Layer 2: YARN application status -------
        local app_id
        app_id=$(grep -oE 'application_[0-9]+_[0-9]+' "${distcp_log}" | tail -1)

        if [ -n "${app_id}" ]; then
            local yarn_status
            yarn_status=$(yarn application -status "${app_id}" 2>/dev/null \
                | grep -oP 'Final-State\s*:\s*\K\S+')
            if [ "${yarn_status}" != "SUCCEEDED" ]; then
                log_error "[Layer2] YARN Final-State = '${yarn_status}' for ${db} (${app_id})"
                _retry_or_fail "${db}" "${attempt}" "${distcp_log}" && continue || return 1
            fi
            log "[Layer2] YARN Final-State = SUCCEEDED (${app_id})"
        else
            log_warn "[Layer2] No YARN application ID found in log; skipping YARN check."
        fi

        # ------- Layer 3: DistCp counters (partial failure detection) -------
        local files_failed
        files_failed=$(grep -oP 'Files Failed to copy=\K[0-9]+' "${distcp_log}" || echo "0")
        if (( files_failed > 0 )); then
            log_error "[Layer3] ${files_failed} files failed to copy for ${db}"
            _retry_or_fail "${db}" "${attempt}" "${distcp_log}" && continue || return 1
        fi

        local files_copied bytes_copied
        files_copied=$(grep -oP 'Files copied=\K[0-9]+' "${distcp_log}" || echo "?")
        bytes_copied=$(grep -oP 'Bytes Copied=\K[0-9]+' "${distcp_log}" || echo "?")
        log "[Layer3] Files copied: ${files_copied}, Bytes copied: ${bytes_copied}"

        log "======== ${db}: SUCCESS ========"
        return 0
    done

    log_error "======== ${db}: FAILED (all ${MAX_RETRIES} retries exhausted) ========"
    return 1
}

# Internal: decide whether to retry or give up.
# Returns 0 if should retry (continue), 1 if exhausted.
_retry_or_fail() {
    local db="$1" attempt="$2" distcp_log="$3"

    if (( attempt >= MAX_RETRIES )); then
        log_error "All ${MAX_RETRIES} retries exhausted for ${db}. See: ${distcp_log}"
        return 1
    fi

    local delay=$(( RETRY_DELAY_BASE * attempt ))
    log_warn "Will retry ${db} in ${delay}s..."
    sleep "${delay}"
    return 0
}
