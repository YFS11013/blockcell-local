#!/usr/bin/env python3
"""Generate historical MT4 signal packs by date.

Examples:
  python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py --months 6
  python domain_experts/forex/ea/scripts/generate_historical_signal_packs.py \
      --start-date 2025-01-01 --end-date 2025-06-30 --overwrite
"""

from __future__ import annotations

import argparse
import calendar
import copy
import datetime as dt
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


UTC = dt.timezone.utc


def parse_date(value: str) -> dt.date:
    try:
        return dt.datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"Invalid date '{value}', expected YYYY-MM-DD."
        ) from exc


def parse_iso8601_utc(value: str) -> dt.datetime:
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def format_iso8601_utc(value: dt.datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def add_months(base_date: dt.date, months: int) -> dt.date:
    month_index = (base_date.month - 1) + months
    year = base_date.year + month_index // 12
    month = (month_index % 12) + 1
    max_day = calendar.monthrange(year, month)[1]
    day = min(base_date.day, max_day)
    return dt.date(year, month, day)


def load_template(path: Path) -> Dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"Template file not found: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    required = [
        "version",
        "symbol",
        "timeframe",
        "bias",
        "valid_from",
        "valid_to",
    ]
    missing = [key for key in required if key not in payload]
    if missing:
        raise ValueError(f"Template missing required fields: {', '.join(missing)}")
    return payload


def derive_time_window(
    template: Dict[str, Any]
) -> Tuple[dt.time, dt.timedelta, Optional[dt.datetime]]:
    try:
        valid_from = parse_iso8601_utc(str(template["valid_from"]))
        valid_to = parse_iso8601_utc(str(template["valid_to"]))
        duration = valid_to - valid_from
    except Exception:
        return dt.time(8, 0, 0, tzinfo=UTC), dt.timedelta(days=1), None

    if duration.total_seconds() <= 0:
        duration = dt.timedelta(days=1)

    anchor_time = dt.time(
        valid_from.hour,
        valid_from.minute,
        valid_from.second,
        tzinfo=UTC,
    )
    return anchor_time, duration, valid_from


def shift_news_blackouts(pack: Dict[str, Any], delta: dt.timedelta) -> None:
    items = pack.get("news_blackout")
    if not isinstance(items, list):
        return

    for item in items:
        if not isinstance(item, dict):
            continue

        for key in ("start", "end"):
            raw = item.get(key)
            if not isinstance(raw, str):
                continue
            try:
                shifted = parse_iso8601_utc(raw) + delta
            except Exception:
                continue
            item[key] = format_iso8601_utc(shifted)


def build_pack_for_date(
    template: Dict[str, Any],
    day: dt.date,
    anchor_time: dt.time,
    duration: dt.timedelta,
    template_valid_from: Optional[dt.datetime],
    append_comment: bool,
) -> Dict[str, Any]:
    pack = copy.deepcopy(template)
    valid_from = dt.datetime.combine(day, anchor_time).astimezone(UTC)
    valid_to = valid_from + duration
    version = valid_from.strftime("%Y%m%d-%H%M")

    pack["version"] = version
    pack["valid_from"] = format_iso8601_utc(valid_from)
    pack["valid_to"] = format_iso8601_utc(valid_to)

    if template_valid_from is not None:
        shift_news_blackouts(pack, valid_from - template_valid_from)

    if append_comment:
        base_comment = str(pack.get("comment", "")).strip()
        suffix = f"historical seed {day.isoformat()}"
        pack["comment"] = f"{base_comment} | {suffix}" if base_comment else suffix

    return pack


def resolve_date_range(args: argparse.Namespace) -> Tuple[dt.date, dt.date]:
    has_start = args.start_date is not None
    has_end = args.end_date is not None

    if has_start != has_end:
        raise ValueError("Use both --start-date and --end-date together.")

    if has_start and has_end:
        start = args.start_date
        end = args.end_date
    else:
        end = dt.datetime.now(UTC).date()
        start = add_months(end, -args.months)

    if start > end:
        raise ValueError(f"Invalid range: start date {start} is later than end date {end}.")
    return start, end


def iter_days(start: dt.date, end: dt.date, step_days: int) -> List[dt.date]:
    if step_days <= 0:
        raise ValueError("--step-days must be >= 1")
    days: List[dt.date] = []
    cursor = start
    step = dt.timedelta(days=step_days)
    while cursor <= end:
        days.append(cursor)
        cursor += step
    return days


def parse_args(argv: List[str]) -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    ea_root = script_dir.parent

    parser = argparse.ArgumentParser(
        description="Batch-generate historical signal_pack JSON files by day."
    )
    parser.add_argument(
        "--template",
        type=Path,
        default=ea_root / "signal_pack_example.json",
        help="Base signal pack template JSON path.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ea_root / "history" / "signal_packs",
        help="Directory to store generated signal packs.",
    )
    parser.add_argument(
        "--months",
        type=int,
        default=6,
        help="When start/end not provided, generate for the latest N months.",
    )
    parser.add_argument(
        "--start-date",
        type=parse_date,
        help="Inclusive start date in YYYY-MM-DD.",
    )
    parser.add_argument(
        "--end-date",
        type=parse_date,
        help="Inclusive end date in YYYY-MM-DD.",
    )
    parser.add_argument(
        "--step-days",
        type=int,
        default=1,
        help="Date step in days. Default: 1 (daily).",
    )
    parser.add_argument(
        "--filename-pattern",
        default="signal_pack_{version}.json",
        help="Filename pattern. Supports {version} and {date}.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing files when target path exists.",
    )
    parser.add_argument(
        "--append-comment",
        action="store_true",
        help="Append 'historical seed YYYY-MM-DD' to comment field.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview generation result without writing files.",
    )
    parser.add_argument(
        "--write-index",
        action="store_true",
        help="Write index.json in output directory.",
    )
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)

    if args.months <= 0 and args.start_date is None and args.end_date is None:
        print("ERROR: --months must be >= 1", file=sys.stderr)
        return 2

    try:
        template = load_template(args.template)
        anchor_time, duration, template_valid_from = derive_time_window(template)
        start_date, end_date = resolve_date_range(args)
        target_days = iter_days(start_date, end_date, args.step_days)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if not args.dry_run:
        args.output_dir.mkdir(parents=True, exist_ok=True)

    generated = 0
    skipped = 0
    index_rows: List[Dict[str, Any]] = []

    for day in target_days:
        pack = build_pack_for_date(
            template=template,
            day=day,
            anchor_time=anchor_time,
            duration=duration,
            template_valid_from=template_valid_from,
            append_comment=args.append_comment,
        )
        version = str(pack["version"])
        file_name = args.filename_pattern.format(
            version=version,
            date=day.strftime("%Y%m%d"),
        )
        output_path = args.output_dir / file_name

        index_rows.append(
            {
                "date": day.isoformat(),
                "version": version,
                "file_name": file_name,
                "valid_from": pack["valid_from"],
                "valid_to": pack["valid_to"],
            }
        )

        if output_path.exists() and not args.overwrite:
            skipped += 1
            continue

        generated += 1
        if args.dry_run:
            continue

        output_path.write_text(
            json.dumps(pack, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    if args.write_index and not args.dry_run:
        index_path = args.output_dir / "index.json"
        index_path.write_text(
            json.dumps(index_rows, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    mode = "DRY-RUN" if args.dry_run else "WRITE"
    print(f"[{mode}] template: {args.template}")
    print(f"[{mode}] output_dir: {args.output_dir}")
    print(f"[{mode}] range: {start_date} .. {end_date} (step={args.step_days}d)")
    print(f"[{mode}] total_days: {len(target_days)}")
    print(f"[{mode}] generated: {generated}")
    print(f"[{mode}] skipped_existing: {skipped}")
    if args.write_index:
        print(f"[{mode}] index: {'enabled' if not args.dry_run else 'preview only'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
