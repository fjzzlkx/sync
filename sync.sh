#!/bin/bash
###############################################################################
# sync.sh — Unified entry point for TBDS sync operations
#
# Usage:
#   ./sync.sh data              # Sync HDFS data (distcp)
#   ./sync.sh ddl               # Export DDLs from both clusters
#   ./sync.sh nta               # Export NTA DDLs only
#   ./sync.sh shahe             # Export SHAHE DDLs only
#   ./sync.sh diff              # Compare DDLs and find changes
#   ./sync.sh modified          # Sync only modified tables
#   ./sync.sh msck              # Generate MSCK REPAIR SQL
#   ./sync.sh help              # Show this help
###############################################################################

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
export BASE_DIR

show_help() {
    cat << EOF
TBDS Sync - Unified Entry Point

Usage: ./sync.sh <command>

Commands:
  all         Complete sync workflow (data + DDL in parallel) - RECOMMENDED
  
  data        Sync HDFS data using distcp (main workflow)
  ddl         Export DDLs from both NTA and SHAHE clusters (parallel)
  nta         Export DDLs from NTA cluster only
  shahe       Export DDLs from SHAHE cluster only
  
  diff        Compare NTA and SHAHE DDLs to find modified tables
  modified    Sync only tables with DDL changes
  msck        Generate MSCK REPAIR TABLE SQL for partition tables
  
  help        Show this help message

Examples:
  # Recommended: Complete sync (parallel execution)
  ./sync.sh all               # Data sync + DDL check in parallel
  
  # Full sync workflow (sequential)
  ./sync.sh data              # 1. Sync data
  ./sync.sh ddl               # 2. Export DDLs
  
  # Incremental sync workflow
  ./sync.sh ddl               # 1. Export DDLs
  ./sync.sh diff              # 2. Find changes
  ./sync.sh modified          # 3. Sync changed tables
  
  # Maintenance
  ./sync.sh msck              # Generate partition repair SQL

For more details, see README.md
EOF
}

case "${1:-help}" in
    all)
        exec "${BASE_DIR}/bin/sync_all.sh"
        ;;
    data)
        exec "${BASE_DIR}/bin/sync_data.sh"
        ;;
    ddl)
        exec "${BASE_DIR}/bin/sync_ddl.sh"
        ;;
    nta)
        exec "${BASE_DIR}/bin/export_nta.sh"
        ;;
    shahe)
        exec "${BASE_DIR}/bin/export_shahe.sh"
        ;;
    diff)
        exec "${BASE_DIR}/tools/ddl_diff.sh"
        ;;
    modified)
        exec "${BASE_DIR}/tools/sync_modified_tables.sh"
        ;;
    msck)
        exec "${BASE_DIR}/tools/generate_msck.sh"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown command '$1'" >&2
        echo "" >&2
        show_help
        exit 1
        ;;
esac
