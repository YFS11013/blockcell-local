#!/usr/bin/env python3
"""
validate.py — 验证 MT4 文件协议 JSON 是否符合 schema

用法:
    python validate.py job.json
    python validate.py result.json --type result
    python validate.py heartbeat.json --type heartbeat
    python validate.py error.json --type error
    python validate.py examples/  # 批量验证目录下所有 .json

依赖:
    pip install jsonschema
"""

import sys
import json
import argparse
from pathlib import Path

SCHEMA_DIR = Path(__file__).parent

TYPE_MAP = {
    "job":       "job.schema.json",
    "result":    "result.schema.json",
    "heartbeat": "heartbeat.schema.json",
    "error":     "error.schema.json",
}

# 根据文件名自动推断类型
FILENAME_HINTS = {
    "job":       ["job"],
    "result":    ["result"],
    "heartbeat": ["heartbeat"],
    "error":     ["error"],
}


def load_schema(schema_type: str) -> dict:
    path = SCHEMA_DIR / TYPE_MAP[schema_type]
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def infer_type(filename: str) -> str | None:
    name = Path(filename).stem.lower()
    for t, hints in FILENAME_HINTS.items():
        if any(h in name for h in hints):
            return t
    return None


def validate_file(filepath: Path, schema_type: str | None = None) -> bool:
    try:
        from jsonschema import validate, ValidationError, SchemaError
    except ImportError:
        print("ERROR: jsonschema not installed — run: pip install jsonschema")
        sys.exit(2)

    # 推断类型
    t = schema_type or infer_type(filepath.name)
    if not t:
        print(f"SKIP  {filepath.name} — cannot infer type, use --type to specify")
        return True

    # 加载 JSON
    try:
        with open(filepath, encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"FAIL  {filepath.name} — invalid JSON: {e}")
        return False

    # 验证
    schema = load_schema(t)
    try:
        validate(instance=data, schema=schema)
        print(f"PASS  {filepath.name} [{t}]")
        return True
    except ValidationError as e:
        print(f"FAIL  {filepath.name} [{t}] — {e.message}")
        print(f"      path: {' -> '.join(str(p) for p in e.absolute_path)}")
        return False


def main():
    parser = argparse.ArgumentParser(description="MT4 文件协议 JSON schema 验证器")
    parser.add_argument("target", help="JSON 文件路径或目录")
    parser.add_argument("--type", choices=list(TYPE_MAP.keys()),
                        help="强制指定 schema 类型（不指定则按文件名自动推断）")
    args = parser.parse_args()

    target = Path(args.target)
    files = []

    if target.is_dir():
        files = sorted(target.glob("*.json"))
        if not files:
            print(f"No .json files found in {target}")
            sys.exit(0)
    elif target.is_file():
        files = [target]
    else:
        print(f"ERROR: {target} not found")
        sys.exit(2)

    results = [validate_file(f, args.type) for f in files]
    total = len(results)
    passed = sum(results)
    failed = total - passed

    print(f"\n{passed}/{total} passed", end="")
    if failed:
        print(f", {failed} failed")
        sys.exit(1)
    else:
        print()


if __name__ == "__main__":
    main()
