# TBDS Sync - Hive 数据同步工具集

自动化 Hive 数据库和表结构在 NTA（源集群）和 SHAHE（目标集群）之间的同步。

## 目录结构

```
.
├── bin/                         # 主要工作流脚本
│   ├── sync_all.sh             # 完整同步（数据+DDL并行）⭐ 推荐
│   ├── sync_data.sh            # 数据同步（HDFS DistCp）
│   ├── sync_ddl.sh             # DDL 导出（NTA + SHAHE 并行）
│   ├── export_nta.sh           # 导出 NTA DDL
│   └── export_shahe.sh         # 导出 SHAHE DDL
├── tools/                       # 辅助工具
│   ├── ddl_diff.sh             # DDL 差异对比
│   ├── sync_modified_tables.sh # 同步变更的表
│   └── generate_msck.sh        # 生成 MSCK REPAIR SQL
├── lib/                         # 共享库
│   ├── common.sh               # 通用函数（日志、锁、检查等）
│   ├── export_ddl.sh           # DDL 导出逻辑
│   ├── distcp.sh               # DistCp 数据同步逻辑
│   ├── sync_table.sh           # 单表 DDL 同步逻辑
│   ├── ddl_diff.py             # DDL 差异对比工具（Python）
│   └── partition_utils.py      # 分区表 MSCK 生成工具（Python）
├── data/                        # DDL 导出目录
│   ├── nta/                    # NTA 集群 DDL
│   ├── shahe/                  # SHAHE 集群 DDL
│   └── work/                   # 临时工作目录
├── logs/                        # 日志目录
├── partition_sql/               # 生成的 MSCK SQL
├── config.sh                    # 全局配置（集群地址、数据库列表等）
├── sync.sh                      # 统一入口脚本
└── README.md                    # 本文档
```

## 快速开始

### 1. 配置

编辑 `config.sh`，设置：
- 集群地址（NameNode、Beeline 命令路径）
- 数据库列表
- 重试参数

### 2. 基本工作流

#### 推荐：完整自动化同步（并行执行）

```bash
# 一键完成所有同步任务（推荐）
./sync.sh all
```

这个命令会并行执行：
- **任务 A**：HDFS 数据同步（distcp）
- **任务 B**：DDL 导出 → 对比差异 → 同步变更表

执行完成后自动生成 MSCK REPAIR SQL。

#### 使用统一入口（分步执行）

```bash
# 完整同步（串行）
./sync.sh data                   # 同步数据（HDFS DistCp）
./sync.sh ddl                    # 导出两端 DDL

# 增量同步
./sync.sh ddl                    # 导出两端 DDL
./sync.sh diff                   # 对比差异
./sync.sh modified               # 同步变更的表

# 维护工具
./sync.sh msck                   # 生成 MSCK REPAIR SQL
./sync.sh help                   # 显示帮助
```

#### 直接调用脚本

```bash
# 完整自动化同步
./bin/sync_all.sh                # 并行执行数据同步和DDL检查

# 完整同步（分步）
./bin/sync_data.sh               # 同步数据
./bin/sync_ddl.sh                # 导出两端 DDL

# 增量同步
./bin/sync_ddl.sh                # 导出两端 DDL
./tools/ddl_diff.sh              # 对比差异
./tools/sync_modified_tables.sh  # 同步变更的表
```

## 脚本详解

### 完整自动化同步

#### `bin/sync_all.sh` - 完整同步工作流（推荐）⭐

并行执行数据同步和 DDL 检查，自动化完成所有同步任务。

**执行流程：**
```
启动
 ├─ 任务 A（并行）：HDFS 数据同步
 │   └─ distcp 同步 8 个数据库
 │
 └─ 任务 B（并行）：DDL 同步
     ├─ 1. 导出 NTA 和 SHAHE DDL
     ├─ 2. 对比 DDL 差异
     └─ 3. 同步变更的表
 
等待两个任务完成
 └─ 生成 MSCK REPAIR SQL
```

**用法：**
```bash
./sync.sh all
# 或
./bin/sync_all.sh
```

**优势：**
- ⚡ 并行执行，速度提升约 50%
- 🤖 全自动化，无需人工干预
- 📊 详细的任务状态报告
- 📝 独立的任务日志

**日志：**
- 主日志：`logs/sync_all_YYYYMMDD_HHMMSS.log`
- 任务 A 日志：`logs/task_a_data_sync_YYYYMMDD_HHMMSS.log`
- 任务 B 日志：`logs/task_b_ddl_sync_YYYYMMDD_HHMMSS.log`

---

### 数据同步

#### `bin/sync_data.sh` - HDFS 数据同步

使用 Hadoop DistCp 同步 8 个数据库的 HDFS 数据。

**特性：**
- 三层验证（退出码 + YARN 状态 + DistCp 计数器）
- 指数退避重试
- HA NameNode 支持
- 自动 MSCK REPAIR

**用法：**
```bash
./sync.sh data
# 或
./bin/sync_data.sh
```

**日志：**
- 主日志：`logs/sync_data_YYYYMMDD_HHMMSS.log`
- DistCp 日志：`logs/distcp_<db>_YYYYMMDD_HHMMSS.log`

---

### DDL 管理

#### `bin/sync_ddl.sh` - 并行导出 DDL

并行导出 NTA 和 SHAHE 两端的所有表 DDL。

**用法：**
```bash
./sync.sh ddl
# 或
./bin/sync_ddl.sh
```

**输出：**
- `data/nta/<db>/<db>.<table>.create_table.sql`
- `data/shahe/<db>/<db>.<table>.create_table.sql`

---

#### `bin/export_nta.sh` / `bin/export_shahe.sh` - 单端导出

单独导出某一端的 DDL（可后台运行）。

**用法：**
```bash
./sync.sh nta        # 导出 NTA
./sync.sh shahe      # 导出 SHAHE
# 或
./bin/export_nta.sh
./bin/export_shahe.sh
```

---

#### `tools/ddl_diff.sh` - DDL 差异对比

对比 NTA 和 SHAHE 的 DDL，找出结构不一致的表。

**用法：**
```bash
./sync.sh diff
# 或
./tools/ddl_diff.sh
```

**输出：**
- 控制台：变更表列表
- 文件：`data/work/modified_tables.txt`

**示例输出：**
```
Found 3 modified table(s):
  - nta_rh_deal order_info
  - nta_rh_etl user_profile
  - nta_rh_query search_log
```

---

#### `tools/sync_modified_tables.sh` - 同步变更表

根据 `ddl_diff.sh` 的结果，仅同步结构变更的表。

**用法：**
```bash
# 先运行 ddl_diff.sh
./sync.sh diff

# 再同步变更的表
./sync.sh modified
# 或
./tools/sync_modified_tables.sh
```

**同步流程（每个表）：**
1. 备份 HDFS 数据
2. 导出源表 DDL
3. 转换为目标 DDL
4. DROP + CREATE 目标表
5. 恢复 HDFS 数据
6. MSCK REPAIR（如果是分区表）

---

### 分区表管理

#### `tools/generate_msck.sh` - 生成 MSCK REPAIR SQL

扫描 DDL 文件，为所有分区表生成 MSCK REPAIR 语句。

**用法：**
```bash
# 扫描 data/nta，输出到 partition_sql/msck_repair.sql
./sync.sh msck
# 或
./tools/generate_msck.sh

# 自定义输入输出
./tools/generate_msck.sh <ddl_dir> <output_sql>
```

**执行生成的 SQL：**
```bash
/bin/SHAHE_BEELINE -f partition_sql/msck_repair.sql
```

---

## 高级用法

### 单表同步

```bash
# 直接调用 lib/sync_table.sh
./lib/sync_table.sh <src_db> <src_table> <dst_db> <dst_table>

# 示例
./lib/sync_table.sh nta_rh_deal order_info nta_rh_deal order_info
```

### 自定义 DDL 对比

```bash
# 对比自定义目录
./tools/ddl_diff.sh /path/to/nta_ddls /path/to/shahe_ddls
```

### 自定义 MSCK 生成

```bash
# 扫描自定义目录
./tools/generate_msck.sh /path/to/ddls /path/to/output.sql
```

---

## 日志和监控

### 日志位置

所有脚本的日志都在 `logs/` 目录：

```
logs/
├── sync_data_20260422_143000.log
├── sync_ddl_20260422_143500.log
├── ddl_diff_20260422_144000.log
├── distcp_nta_rh_deal_20260422_143100.log
└── ...
```

### 日志格式

```
[2026-04-22 14:30:00] [INFO]  Starting daily HDFS sync
[2026-04-22 14:30:05] [WARN]  NameNode nn1 unreachable
[2026-04-22 14:30:10] [ERROR] Failed to sync nta_rh_deal
```

### 锁文件

防止并发执行，锁文件位于 `logs/`:

```
logs/
├── sync_data.lock
├── sync_ddl.lock
└── sync_modified_tables.lock
```

---

## 错误处理

### 常见问题

**1. "Another instance is already running"**
- 原因：锁文件存在
- 解决：等待前一个任务完成，或删除 `logs/*.lock`

**2. "Cannot reach HDFS"**
- 原因：NameNode 不可达
- 解决：检查网络、NameNode 状态

**3. "Beeline command not found"**
- 原因：`/bin/NTA_BEELINE` 或 `/bin/SHAHE_BEELINE` 不存在
- 解决：检查 `config.sh` 中的路径配置

**4. "DDL directory not found"**
- 原因：未先运行 DDL 导出
- 解决：先运行 `./sync_ddl.sh` 或 `./export_nta.sh`

### 回滚机制

`sync_modified_tables.sh` 和 `lib/sync_table.sh` 有自动回滚：
- 失败时自动恢复 HDFS 数据
- 备份路径：`<table_path>.bak`

---

## 性能优化

### 并行执行

- `sync_ddl.sh` 并行导出 NTA 和 SHAHE（约 50% 提速）
- `sync_data.sh` 串行同步数据库（避免集群过载）

### DistCp 参数调优

编辑 `config.sh` 中的 `DISTCP_OPTS`：

```bash
DISTCP_OPTS=(
    -m 64              # Map 任务数（根据集群调整）
    -bandwidth 100     # 带宽限制 MB/s
    -strategy dynamic  # 动态负载均衡
    ...
)
```

### 重试策略

```bash
MAX_RETRIES=3           # 最大重试次数
RETRY_DELAY_BASE=60     # 基础延迟（秒）
# 实际延迟 = RETRY_DELAY_BASE * 重试次数
```

---

## 定时任务

### Cron 示例

```cron
# 推荐：每天凌晨 2 点完整同步（并行执行）
0 2 * * * cd /data/SYS_TBDS/TBDS_SYNC && ./sync.sh all >> logs/cron.log 2>&1

# 或者分步执行：
# 每天凌晨 2 点同步数据
0 2 * * * cd /data/SYS_TBDS/TBDS_SYNC && ./sync.sh data >> logs/cron.log 2>&1

# 每天凌晨 4 点导出 DDL
0 4 * * * cd /data/SYS_TBDS/TBDS_SYNC && ./sync.sh ddl >> logs/cron.log 2>&1

# 每周一凌晨 5 点对比并同步变更表
0 5 * * 1 cd /data/SYS_TBDS/TBDS_SYNC && ./sync.sh diff && ./sync.sh modified >> logs/cron.log 2>&1
```

---

## 维护

### 清理旧日志

```bash
# 删除 30 天前的日志
find logs/ -name "*.log" -mtime +30 -delete
```

### 清理临时文件

```bash
# 清理工作目录
rm -rf data/work/*
```

### 更新数据库列表

编辑 `config.sh`：

```bash
DATABASES=(
    "nta_rh_backup"
    "nta_rh_check"
    # ... 添加新数据库
)
```

---

## 架构设计

### 模块化

- **config.sh**: 单一配置源
- **lib/common.sh**: 共享工具函数
- **lib/*.sh**: 可复用的业务逻辑
- **lib/*.py**: Python 辅助工具
- **入口脚本**: 编排和调度

### 错误处理

- 三层验证（DistCp）
- 自动回滚（表同步）
- 锁机制（防并发）
- 详细日志（可追溯）

### 可扩展性

- 新增数据库：修改 `config.sh`
- 新增集群：复制并修改入口脚本
- 自定义逻辑：扩展 `lib/` 函数

---

## 许可

内部工具，仅供 TBDS 项目使用。
