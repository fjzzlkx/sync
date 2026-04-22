#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
lib/ddl_diff.py — Compare NTA and SHAHE DDLs to find modified tables.

Reads DDL SQL files from data/nta/ and data/shahe/, compares them ignoring
transient metadata (transient_lastDdlTime, spark.sql.create.version),
and outputs modified tables as "db table" lines to stdout.

Usage:
    python ddl_diff.py <nta_dir> <shahe_dir>
    python ddl_diff.py                          # uses BASE_DIR/data/{nta,shahe}

Exit codes:
    0 — completed (may output 0 or more modified tables)
    1 — error
"""

import os
import sys
import re


def normalize_ddl(content):
    """Normalize a DDL string for comparison.

    1. Strip everything after TBLPROPERTIES (metadata noise).
    2. Remove transient_lastDdlTime lines.
    3. Remove spark.sql.create.version lines.
    4. Collapse whitespace.
    """
    # Cut at TBLPROPERTIES — structural changes are before this
    idx = content.find("TBLPROPERTIES")
    if idx != -1:
        content = content[:idx]

    # Remove known noisy lines
    content = re.sub(r"'transient_lastDdlTime'\s*=\s*'[^']*'", "", content)
    content = re.sub(r"'spark\.sql\.create\.version'\s*=\s*'[^']*'", "", content)

    # Collapse whitespace for stable comparison
    content = re.sub(r"\s+", " ", content).strip()
    return content


def load_ddls(directory):
    """Load all DDL files from a directory tree into a dict.

    Returns: { "db.table": normalized_content, ... }
    """
    ddls = {}
    if not os.path.isdir(directory):
        return ddls

    for root, _dirs, files in os.walk(directory):
        for f in files:
            if not f.endswith(".create_table.sql"):
                continue
            # filename format: db.table.create_table.sql
            parts = f.replace(".create_table.sql", "").split(".", 1)
            if len(parts) != 2:
                continue
            db, table = parts
            filepath = os.path.join(root, f)
            try:
                with open(filepath, "r") as fh:
                    content = fh.read()
                ddls["{}.{}".format(db, table)] = normalize_ddl(content)
            except Exception:
                pass
    return ddls


def main():
    base_dir = os.environ.get("BASE_DIR", "")

    if len(sys.argv) >= 3:
        nta_dir = sys.argv[1]
        ft_dir = sys.argv[2]
    elif base_dir:
        nta_dir = os.path.join(base_dir, "data", "nta")
        ft_dir = os.path.join(base_dir, "data", "shahe")
    else:
        print("Usage: python ddl_diff.py <nta_dir> <shahe_dir>", file=sys.stderr)
        sys.exit(1)

    nta_ddls = load_ddls(nta_dir)
    ft_ddls = load_ddls(ft_dir)

    if not nta_ddls:
        print("WARNING: No NTA DDLs found in {}".format(nta_dir), file=sys.stderr)

    modified = []
    for key, nta_content in sorted(nta_ddls.items()):
        ft_content = ft_ddls.get(key, "")
        if nta_content != ft_content:
            db, table = key.split(".", 1)
            modified.append((db, table))

    # Output: "db table" per line, consumed by sync_ddl.sh
    for db, table in modified:
        print("{} {}".format(db, table))

    if modified:
        print(
            "Found {} modified table(s).".format(len(modified)),
            file=sys.stderr,
        )
    else:
        print("No modified tables found.", file=sys.stderr)


if __name__ == "__main__":
    main()
