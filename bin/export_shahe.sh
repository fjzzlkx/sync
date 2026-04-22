#!/bin/bash
###############################################################################
# export_shahe.sh — Export all SHAHE DDLs (standalone, for background execution)
###############################################################################
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${BASE_DIR}/config.sh"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/export_ddl.sh"

# Disable job control notification to avoid terminal noise
set +m

export_all_ddl "shahe"
