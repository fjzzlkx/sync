#!/bin/bash
###############################################################################
# lib/export_ddl.sh — Unified Hive DDL export
#
# Sourced by sync_ddl.sh. Do NOT execute directly.
# Requires: config.sh + lib/common.sh sourced first.
###############################################################################

# Enable alias expansion so NTA_BEELINE / SHAHE_BEELINE work in non-interactive shells
shopt -s expand_aliases 2>/dev/null || true

# Export all table DDLs for a given cluster.
# Usage: export_all_ddl <cluster>
#   cluster = "nta" (source, uses NTA_BEELINE_CMD) or "shahe" (dest, uses SHAHE_BEELINE_CMD)
# Exports to: data/<cluster>/<db>/<db>.<table>.create_table.sql
export_all_ddl() {
    local cluster="$1"
    local beeline_cmd

    case "${cluster}" in
        nta) beeline_cmd="${NTA_BEELINE_CMD}" ;;
        shahe) beeline_cmd="${SHAHE_BEELINE_CMD}"  ;;
        *)   log_error "export_all_ddl: unknown cluster '${cluster}'. Use 'nta' or 'shahe'."; return 1 ;;
    esac

    local out_dir="${DATA_DIR}/${cluster}"
    mkdir -p "${out_dir}"

    log "Exporting DDLs for cluster '${cluster}' → ${out_dir}"

    local fail_count=0
    for db in "${DATABASES[@]}"; do
        if export_single_db_ddl "${beeline_cmd}" "${db}" "${out_dir}"; then
            log "  ${cluster}/${db}: exported OK"
        else
            log_error "  ${cluster}/${db}: export FAILED"
            ((fail_count++))
        fi
    done

    if (( fail_count > 0 )); then
        log_error "export_all_ddl(${cluster}): ${fail_count} database(s) failed."
        return 1
    fi
    log "export_all_ddl(${cluster}): all databases exported."
}

# Export DDLs for one database.
# Usage: export_single_db_ddl <beeline_cmd> <database> <out_dir>
# Optimization: batch-export all tables in ONE beeline session to reduce connection overhead.
export_single_db_ddl() {
    local beeline_cmd="$1"
    local db="$2"
    local out_dir="$3"

    local db_dir="${out_dir}/${db}"
    mkdir -p "${db_dir}"
    mkdir -p "${DATA_DIR}/work"

    log "  Exporting tables from ${db}..."

    # Step 1: Get table list
    local table_list_file="${DATA_DIR}/work/.table_list_${db}.tmp"
    ${beeline_cmd} --showHeader=false --outputformat=csv2 \
        -e "USE ${db}; SHOW TABLES;" \
        > "${table_list_file}" 2>/dev/null

    sed -i '/^\s*$/d' "${table_list_file}" 2>/dev/null || true

    if [ ! -s "${table_list_file}" ]; then
        log_warn "SHOW TABLES returned empty for ${db}."
        rm -f "${table_list_file}"
        return 1
    fi

    # Step 2: Generate batch SQL — one SHOW CREATE TABLE per line
    local batch_sql="${DATA_DIR}/work/.batch_${db}.sql"
    echo "USE ${db};" > "${batch_sql}"
    while IFS= read -r line; do
        table=$(echo "${line}" | tr -d '\r\n' | xargs)
        [ -z "${table}" ] && continue
        case "${table}" in *" "*) continue ;; esac
        echo "SHOW CREATE TABLE ${db}.${table};" >> "${batch_sql}"
    done < "${table_list_file}"
    rm -f "${table_list_file}"

    # Step 3: Execute ALL SHOW CREATE TABLE in ONE beeline session
    local raw_output="${DATA_DIR}/work/.raw_${db}.out"
    ${beeline_cmd} --showHeader=false --outputformat=csv2 \
        -f "${batch_sql}" \
        > "${raw_output}" 2>/dev/null
    rm -f "${batch_sql}"

    if [ ! -s "${raw_output}" ]; then
        log_warn "Batch export returned empty for ${db}."
        return 1
    fi

    # Step 4: Split raw output into individual table DDL files
    # Each SHOW CREATE TABLE result starts with "CREATE TABLE ..." line
    local table sql_file current_table="" current_content="" count=0
    while IFS= read -r line; do
        # Detect new CREATE TABLE statement
        if [[ "${line}" =~ ^CREATE\ TABLE ]]; then
            # Save previous table's DDL
            if [ -n "${current_table}" ] && [ -n "${current_content}" ]; then
                sql_file="${db_dir}/${db}.${current_table}.create_table.sql"
                echo "${current_content}" > "${sql_file}"
                ((count++))
            fi
            # Extract db.table from: CREATE TABLE `db`.`table` ( or CREATE TABLE db.table (
            current_table=$(echo "${line}" | sed -E 's/CREATE TABLE[[:space:]]+//; s/[[:space:]]*\(.*//; s/`//g')
            current_content="${line}"
        elif [ -n "${current_table}" ]; then
            current_content="${current_content}
${line}"
        fi
    done < "${raw_output}"

    # Save last table
    if [ -n "${current_table}" ] && [ -n "${current_content}" ]; then
        sql_file="${db_dir}/${db}.${current_table}.create_table.sql"
        echo "${current_content}" > "${sql_file}"
        ((count++))
    fi

    rm -f "${raw_output}"

    if [ ${count} -eq 0 ]; then
        log_warn "No valid tables exported for ${db}."
        return 1
    fi
    log "  ${db}: exported ${count} table(s) in 1 beeline session"
    return 0
}
