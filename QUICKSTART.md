# 快速开始指南

## 一分钟上手

```bash
# 1. 配置（首次使用）
vim config.sh

# 2. 完整自动化同步（推荐）⭐
./sync.sh all       # 并行执行数据同步和DDL检查
```

## 常用命令

| 命令 | 说明 | 用途 |
|------|------|------|
| `./sync.sh all` | **完整自动化同步** ⭐ | **推荐：并行执行所有任务** |
| `./sync.sh data` | 数据同步 | 每日数据同步 |
| `./sync.sh ddl` | DDL 导出 | 导出两端表结构 |
| `./sync.sh diff` | DDL 对比 | 找出结构差异 |
| `./sync.sh modified` | 同步变更表 | 只同步变化的表 |
| `./sync.sh msck` | 生成 MSCK | 分区表修复 |
| `./sync.sh help` | 帮助信息 | 查看所有命令 |

## 典型场景

### 场景 1：完整自动化同步（推荐）⭐

```bash
# 一键完成所有任务（并行执行）
./sync.sh all
```

**执行内容：**
- 任务 A（并行）：HDFS 数据同步
- 任务 B（并行）：DDL 导出 → 对比 → 同步变更表
- 最后：生成 MSCK REPAIR SQL

**优势：**
- ⚡ 速度快（并行执行）
- 🤖 全自动化
- 📊 详细报告

### 场景 2：每日数据同步（仅数据）

```bash
./sync.sh data
```

### 场景 3：表结构变更后同步（仅DDL）

```bash
# 1. 导出最新 DDL
./sync.sh ddl

# 2. 找出变更的表
./sync.sh diff

# 3. 同步变更的表
./sync.sh modified
```

### 场景 4：分区表修复

```bash
# 1. 生成 MSCK SQL
./sync.sh msck

# 2. 执行修复
/bin/SHAHE_BEELINE -f partition_sql/msck_repair.sql
```

### 场景 5：单表同步

```bash
./lib/sync_table.sh nta_rh_deal order_info nta_rh_deal order_info
```

## 定时任务配置

```bash
# 编辑 crontab
crontab -e

# 推荐：每天凌晨 2 点完整自动化同步
0 2 * * * cd /data/SYS_TBDS/TBDS_SYNC && ./sync.sh all >> logs/cron.log 2>&1

# 或者分步执行
0 2 * * * cd /data/SYS_TBDS/TBDS_SYNC && ./sync.sh data >> logs/cron.log 2>&1
0 4 * * * cd /data/SYS_TBDS/TBDS_SYNC && ./sync.sh ddl >> logs/cron.log 2>&1
```

## 故障排查

### 查看日志

```bash
# 最新日志
ls -lt logs/ | head

# 查看完整同步日志
tail -f logs/sync_all_20260422_143000.log

# 查看任务 A（数据同步）日志
tail -f logs/task_a_data_sync_20260422_143000.log

# 查看任务 B（DDL同步）日志
tail -f logs/task_b_ddl_sync_20260422_143000.log
```

### 清理锁文件

```bash
# 如果提示 "Another instance is running"
rm -f logs/*.lock
```

### 检查环境

```bash
# 检查 Python
python3 --version

# 检查 Beeline
ls -l /bin/NTA_BEELINE /bin/SHAHE_BEELINE

# 检查 HDFS
hdfs dfs -ls /apps/hive/warehouse
```

## 性能对比

| 方式 | 执行时间 | 说明 |
|------|---------|------|
| `./sync.sh all` | ~60 分钟 | 并行执行，推荐 ⭐ |
| 分步执行 | ~90 分钟 | 串行执行 |

*实际时间取决于数据量和集群性能

## 更多信息

详细文档请参考 [README.md](README.md)
