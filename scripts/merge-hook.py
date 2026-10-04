#!/usr/bin/env python3
"""Idempotently merge one hook entry into a Claude/Codex hook-config JSON file.

WHY THIS EXISTS: setup.sh merged hook config with `jq`, and on a machine without
jq every hook install printed "skip: jq not installed" and carried on. The
install looked successful -- exit 0, "Done." -- while the Stop hook, the
SessionStart reseed, the run-cost report, the stop-gate and the model-cap
PreToolUse hook were all silently absent. That is the whole `.next-action` seam
and the L9 auto-continue chain, gone, with the failure visible only in
mid-install chatter nobody re-reads. Observed on 2026-09-10: a full
`setup.sh --tools claude` install shipped zero hooks for exactly this reason.

python3 is already a hard dependency of this repo (validate_skills.py,
check_contracts.py, eval-runner.py), so falling back to it costs nothing that
was not already required. jq stays the preferred path when present.

Usage:
  merge-hook.py <file> <event> <command> [--matcher M] [--timeout N] [--label L]

Exit 0 on success or when the entry is already present (idempotent); 1 on error.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file")
    ap.add_argument("event", help="Stop | SessionStart | PreToolUse | ...")
    ap.add_argument("command")
    ap.add_argument("--matcher", default=None)
    ap.add_argument("--timeout", type=int, default=None)
    ap.add_argument("--label", default=None, help="what to call this hook in output")
    args = ap.parse_args(argv)

    path = args.file
    label = args.label or args.event

    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)

    data: dict = {}
    if os.path.isfile(path):
        try:
            with io.open(path, encoding="utf-8") as f:
                text = f.read().strip()
            data = json.loads(text) if text else {}
        except (ValueError, OSError) as e:
            # Never clobber a file we cannot parse -- a settings.json is the
            # user's, and a bad merge is worse than a missing hook.
            print(f"  error: {path} is not readable JSON ({e}); refusing to touch it",
                  file=sys.stderr)
            return 1
    if not isinstance(data, dict):
        print(f"  error: {path} is not a JSON object; refusing to touch it", file=sys.stderr)
        return 1

    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        print(f"  error: {path} has a non-object .hooks; refusing to touch it", file=sys.stderr)
        return 1
    entries = hooks.setdefault(args.event, [])
    if not isinstance(entries, list):
        print(f"  error: {path} has a non-array .hooks.{args.event}; refusing",
              file=sys.stderr)
        return 1

    # Idempotent on the exact command string, matching the jq path's `any(...)`.
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for h in entry.get("hooks") or []:
            if isinstance(h, dict) and h.get("command") == args.command:
                print(f"  skip: {label} already wired ({args.command})")
                return 0

    hook: dict = {"type": "command", "command": args.command}
    if args.timeout is not None:
        hook["timeout"] = args.timeout
    entry: dict = {"hooks": [hook]}
    if args.matcher:
        entry["matcher"] = args.matcher
    entries.append(entry)

    tmp = path + ".tmp"
    try:
        with io.open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print(f"  error: failed to write {path}: {e}", file=sys.stderr)
        return 1

    print(f"  wrote: {path} (added {label})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
