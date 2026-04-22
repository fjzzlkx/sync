#!/bin/bash
###############################################################################
# generate_msck.sh — Generate MSCK REPAIR TABLE SQL for partition tables
#
# Wrapper script for lib/partition_utils.py that integrates with the project.
#
# Usage:
#   ./generate_msck.sh                    # Scan data/nta, output to partition_sql/
#   ./generate_msck.sh <ddl_dir>          # Custom DDL directory
#   ./generate_msck.sh <ddl_dir> <output_sql>  # Custom input and output
#
# Output: SQL file with MSCK REPAIR statements for all partition tables
###############################################################################
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export BASE_DIR

source "${BASE_DIR}/config.sh"
source "${LIB_DIR}/common.sh"

# Initialize logging
init_log "generate_msck"

log "=========================================="
log "Generate MSCK REPAIR SQL"
log "=========================================="

# Check Python environment
check_python 3.6 || exit 1

# Determine directories
if [ $# -ge 1 ]; then
    DDL_DIR="$1"
else
    DDL_DIR="${DATA_DIR}/nta"
fi

if [ $# -ge 2 ]; then
    OUTPUT_SQL="$2"
else
    OUTPUT_SQL="${PARTITION_SQL_DIR}/msck_repair.sql"
fi

log "Scanning DDLs: ${DDL_DIR}"
log "Output SQL:    ${OUTPUT_SQL}"

# Check if directory exists
if [ ! -d "${DDL_DIR}" ]; then
    log_error "DDL directory not found: ${DDL_DIR}"
    log_error "Run export_nta.sh first to generate DDLs"
    exit 1
fi

# Create output directory
mkdir -p "$(dirname "${OUTPUT_SQL}")"

# Run Python tool
log "Scanning for partition tables..."
if python3 "${LIB_DIR}/partition_utils.py" "${DDL_DIR}" "${OUTPUT_SQL}" 2>> "${_LOG_FILE}"; then
    log "MSCK REPAIR SQL generated successfully"
    
    # Count statements
    STMT_COUNT=$(grep -c "MSCK REPAIR TABLE" "${OUTPUT_SQL}" || echo "0")
    log "Generated ${STMT_COUNT} MSCK REPAIR statement(s)"
    
    log ""
    log "To execute the repairs, run:"
    log "  ${SHAHE_BEELINE_CMD} -f ${OUTPUT_SQL}"
else
    log_error "Failed to generate MSCK REPAIR SQL"
    exit 1
fi

log "=========================================="
log "MSCK Generation Complete"
log "=========================================="
