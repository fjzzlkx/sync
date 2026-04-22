#!/bin/bash
###############################################################################
# config.sh — Single source of truth for all TBDS_SYNC configuration
#
# Sourced by entry scripts. Do NOT execute directly.
###############################################################################

# ========================= Path Resolution ===================================
# BASE_DIR is the TBDS_SYNC_AI root, resolved from whoever sources this file.
# Entry scripts must set _ENTRY_DIR before sourcing config.sh.
if [ -z "${BASE_DIR:-}" ]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export BASE_DIR

DATA_DIR="${BASE_DIR}/data"
LOG_DIR="${BASE_DIR}/logs"
LIB_DIR="${BASE_DIR}/lib"
PARTITION_SQL_DIR="${BASE_DIR}/partition_sql"

# ========================= HDFS Configuration ================================

# Source cluster — HA with two NameNodes
SRC_NAMESERVICE="srcCluster"
SRC_NN1="172.20.80.130:8020"
SRC_NN2="172.20.80.131:8020"
SRC_HDFS="hdfs://${SRC_NAMESERVICE}"

# Destination cluster
DST_NAMESERVICE="hdfsCluster"
DST_HDFS="hdfs://${DST_NAMESERVICE}"

WAREHOUSE="/apps/hive/warehouse"

# ========================= Hive / Beeline ====================================

NTA_BEELINE_CMD="/bin/NTA_BEELINE"    # Source cluster beeline
SHAHE_BEELINE_CMD="/bin/SHAHE_BEELINE"    # Destination cluster beeline

# ========================= Databases =========================================

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

# ========================= Retry Settings ====================================

MAX_RETRIES=3
RETRY_DELAY_BASE=60   # seconds; actual delay = base * attempt

# ========================= Hadoop Client =====================================
# These are ONLY used by hadoop distcp (in lib/distcp.sh).
# DO NOT set them globally — NTA_BEELINE and SHAHE_BEELINE have their own JVM config.
# export HADOOP_CLIENT_OPTS  # set per-command in distcp.sh
# export HADOOP_HEAPSIZE     # set per-command in distcp.sh

# ========================= DistCp Options ====================================
# HA properties are injected so the Hadoop client can resolve both nameservices.
# dfs.nameservices MUST list the destination first to preserve existing config.

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
