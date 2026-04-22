#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
lib/partition_utils.py — Generate MSCK REPAIR TABLE SQL for partition tables.

Scans HQL/DDL files for PARTITIONED BY and generates MSCK REPAIR statements.
Skips known problematic tables.

Usage:
    python partition_utils.py <ddl_dir> [output_sql_file]
    python partition_utils.py              # uses BASE_DIR/data/nta, writes to partition_sql/

Output: SQL file with one "MSCK REPAIR TABLE db.table;" per partition table.
"""

import os
import sys
import re

# Tables known to cause issues with MSCK REPAIR — skip them.
SKIP_TABLES = {
    "nta_rh_result.cphone_oa_area_time_day",
    "nta_rh_result.sphone_oa_area_time_day",
    "nta_rh_result.mphone_oa_area_time_day",
    "nta_rh_result.gphone_oa_area_time_day",
    "nta_rh_result.net_phone_oa_area_time_day",
    "nta_rh_etl.nta_etl_tel_1_info_all",
}


def find_partition_tables(ddl_dir):
    """Scan DDL files for PARTITIONED BY and return list of (db, table)."""
    tables = []
    if not os.path.isdir(ddl_dir):
        return tables

    for root, _dirs, files in os.walk(ddl_dir):
        for f in files:
            if not f.endswith(".create_table.sql"):
                continue
            filepath = os.path.join(root, f)
            try:
                with open(filepath, "r") as fh:
                    content = fh.read()
            except Exception:
                continue

            if "PARTITIONED BY" not in content.upper():
                continue

            parts = f.replace(".create_table.sql", "").split(".", 1)
            if len(parts) != 2:
                continue
            db, table = parts
            full_name = "{}.{}".format(db, table)
            if full_name not in SKIP_TABLES:
                tables.append((db, table))

    return sorted(tables)


def generate_msck_sql(tables):
    """Generate MSCK REPAIR TABLE statements."""
    lines = []
    for db, table in tables:
        lines.append("MSCK REPAIR TABLE {}.{};".format(db, table))
    return "\n".join(lines)


def main():
    base_dir = os.environ.get("BASE_DIR", "")

    if len(sys.argv) >= 2:
        ddl_dir = sys.argv[1]
    elif base_dir:
        ddl_dir = os.path.join(base_dir, "data", "nta")
    else:
        print("Usage: python partition_utils.py <ddl_dir> [output_sql]", file=sys.stderr)
        sys.exit(1)

    # Output file
    if len(sys.argv) >= 3:
        output_file = sys.argv[2]
    elif base_dir:
        output_file = os.path.join(base_dir, "partition_sql", "msck_repair.sql")
    else:
        output_file = None

    tables = find_partition_tables(ddl_dir)
    sql = generate_msck_sql(tables)

    if output_file:
        os.makedirs(os.path.dirname(output_file), exist_ok=True)
        with open(output_file, "w") as fh:
            fh.write(sql + "\n")
        print(
            "Generated MSCK REPAIR for {} table(s) → {}".format(len(tables), output_file),
            file=sys.stderr,
        )
    else:
        print(sql)

    print("{} partition table(s) found.".format(len(tables)), file=sys.stderr)


if __name__ == "__main__":
    main()
