#!/bin/bash
###############################################################################
# export_shahe.sh — Export all SHAHE DDLs (standalone, for background execution)
###############################################################################
set -euo pipefail

# Load user environment (aliases like SHAHE_BEELINE are defined here)
shopt -s expand_aliases 2>/dev/null || true
source "$HOME/.bashrc" 2>/dev/null || true

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${BASE_DIR}/config.sh"
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/export_ddl.sh"

# Disable job control notification to avoid terminal noise
set +m

export_all_ddl "shahe"
