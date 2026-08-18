#!/usr/bin/env python3
"""Token-cost audit for Claude Code sessions.

Reads the local Claude Code transcript store (~/.claude/projects/**) and reports
where a run's tokens actually went: main-thread vs sub-agents, per model tier,
per sub-agent, and how context size grew over the session.

Purpose-built to answer three questions this toolkit keeps hitting:
  1. Did `models.cap` actually take effect?          (--check-cap)
  2. Which stage / sub-agent burned the budget?      (top sub-agents table)
  3. Was the cost fan-out, or context drag?          (CONTEXT DRAG section)

Stdlib only, read-only, no network -- safe on locked-down machines.

Usage:
  python scripts/token-audit.py --list
  python scripts/token-audit.py --project poc-contractor
  python scripts/token-audit.py --session <uuid> --check-cap sonnet
  python scripts/token-audit.py --project foo --json audit.json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

# Rough per-Mtok USD: (input, cache_write, cache_read, output). Used only as a
# relative "where did it go" signal, never as a billing figure.
PRICE = {
    "opus": (15.00, 18.75, 1.50, 75.00),
    "sonnet": (3.00, 3.75, 0.30, 15.00),
    "haiku": (1.00, 1.25, 0.10, 5.00),
    "fable": (3.00, 3.75, 0.30, 15.00),
}
TIER_RANK = {"haiku": 1, "sonnet": 2, "opus": 3}
USAGE_KEYS = ("inp", "out", "cr", "cw", "n")


def tier_of(model):
    """Map a wire model id (claude-opus-5[1m], claude-haiku-4-5-...) to a tier."""
    m = (model or "").lower()
    for t in ("opus", "sonnet", "haiku", "fable"):
        if t in m:
            return t
    return "other"


def fmt(n):
    if n >= 1_000_000_000:
        return "%.2fB" % (n / 1e9)
    if n >= 1_000_000:
        return "%.2fM" % (n / 1e6)
    return "%.1fk" % (n / 1e3)


def cost_of(tier, u):
    p = PRICE.get(tier)
    if not p:
        return 0.0
    return (u["inp"] * p[0] + u["cw"] * p[1] + u["cr"] * p[2] + u["out"] * p[3]) / 1e6


def blank():
    return dict(inp=0, out=0, cr=0, cw=0, n=0)


def add(dst, u):
    for k in USAGE_KEYS:
        dst[k] += u[k]


def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(x.get("text", "") for x in c if isinstance(x, dict))
    return ""


def scan_file(path):
    """Extract usage rows and provenance from one .jsonl transcript."""
    by_model = defaultdict(blank)
    curve = []
    slash = []
    first_prompt = ""
    ts_first = ts_last = None

    try:
        fh = path.open(encoding="utf-8", errors="replace")
    except OSError:
        return {}

    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue

            ts = d.get("timestamp")
            if ts:
                ts_first = ts_first or ts
                ts_last = ts

            msg = d.get("message") or {}
            usage = msg.get("usage") or {}
            if usage:
                u = dict(
                    inp=usage.get("input_tokens", 0),
                    out=usage.get("output_tokens", 0),
                    cr=usage.get("cache_read_input_tokens", 0),
                    cw=usage.get("cache_creation_input_tokens", 0),
                    n=1,
                )
                add(by_model[msg.get("model", "?")], u)
                # Context on the wire for this call = everything except output.
                curve.append(((ts or "")[:19], u["inp"] + u["cr"] + u["cw"]))

            if d.get("type") == "user":
                txt = text_of(msg)
                if "<command-name>" in txt:
                    cmd = txt.split("<command-name>")[1].split("</command-name>")[0]
                    slash.append(((ts or "")[:19], cmd.strip()))
                if not first_prompt and txt.strip():
                    first_prompt = " ".join(txt.split())[:120]

    return dict(
        by_model=dict(by_model),
        curve=curve,
        slash=slash,
        first_prompt=first_prompt,
        ts_first=ts_first,
        ts_last=ts_last,
    )


def roll(by_model):
    """Collapse wire model ids into tiers."""
    out = defaultdict(blank)
    for model, u in by_model.items():
        add(out[tier_of(model)], u)
    return dict(out)


def print_table(title, tiers):
    if not tiers:
        return 0.0
    print("\n  " + title)
    print("    %-10s %6s %9s %9s %10s %8s"
          % ("tier", "calls", "output", "cache_w", "cache_r", "~$"))
    total = 0.0
    for tier, u in sorted(tiers.items(), key=lambda kv: -cost_of(kv[0], kv[1])):
        c = cost_of(tier, u)
        total += c
        print("    %-10s %6d %9s %9s %10s %8.2f"
              % (tier, u["n"], fmt(u["out"]), fmt(u["cw"]), fmt(u["cr"]), c))
    print("    %-10s %6s %9s %9s %10s %8.2f" % ("TOTAL", "", "", "", "", total))
    return total


def report_session(session, args):
    main = scan_file(session)
    if not main or not main["by_model"]:
        return {}

    # Sub-agent transcripts live in a sibling dir named after the session uuid.
    sub_dir = session.with_suffix("")
    subs = []
    if sub_dir.is_dir():
        for p in sorted(sub_dir.rglob("*.jsonl")):
            s = scan_file(p)
            if s and s["by_model"]:
                s["path"] = p
                subs.append(s)

    main_t = roll(main["by_model"])
    sub_t = defaultdict(blank)
    for s in subs:
        for tier, u in roll(s["by_model"]).items():
            add(sub_t[tier], u)
    sub_t = dict(sub_t)

    print("=" * 78)
    print("SESSION  " + session.stem)
    print("  window %s -> %s" % ((main["ts_first"] or "")[:19], (main["ts_last"] or "")[:19]))
    if main["first_prompt"]:
        print("  opened with: " + main["first_prompt"])
    cmds = sorted({c for _, c in main["slash"]})
    if cmds:
        print("  slash commands: " + ", ".join(cmds))

    main_cost = print_table(
        "MAIN THREAD (orchestrator -- NOT governed by models.cap)", main_t)
    sub_cost = print_table(
        "SUB-AGENTS (%d agents -- governed by models.cap)" % len(subs), sub_t)

    total = main_cost + sub_cost
    if total:
        print("\n  SPLIT: main thread %.0f%%  |  sub-agents %.0f%%   (~$%.2f relative)"
              % (main_cost / total * 100, sub_cost / total * 100, total))

    # Context drag: is the cost one long thread, or genuine fan-out?
    curve = main["curve"]
    if curve:
        peak = max(c for _, c in curve)
        avg = sum(c for _, c in curve) / len(curve)
        print("\n  CONTEXT DRAG: %d main-thread calls, avg context %s, peak %s"
              % (len(curve), fmt(int(avg)), fmt(peak)))
        print("    -> each main-thread call re-reads the whole context: "
              "%d x %s = %s cache-read tokens."
              % (len(curve), fmt(int(avg)), fmt(int(avg * len(curve)))))
        if avg > 150_000:
            print("    -> VERDICT: context drag dominates. Shorten the SESSION "
                  "(/clear between stages); cutting agent count will not help much.")

    # Cap check.
    if args.check_cap:
        cap = args.check_cap.lower()
        cap_rank = TIER_RANK.get(cap, 0)
        print("\n  CAP CHECK (models.cap = %s):" % cap)
        violations = [(t, u) for t, u in sub_t.items() if TIER_RANK.get(t, 0) > cap_rank]
        if violations:
            for t, u in violations:
                print("    !! %d sub-agent calls ran on %s (above cap) -- ~$%.2f"
                      % (u["n"], t, cost_of(t, u)))
            print("    NOTE: the adversarial Review->Fix lenses ride the SEPARATE")
            print("          reviewer-model axis (default opus) and are cap-exempt BY DESIGN.")
            print("          Lower those with pipeline.review_fix.model, not models.cap.")
        else:
            print("    OK -- no sub-agent call exceeded %s." % cap)
        if "fable" in sub_t:
            print("    fable present (%d calls) -- reviewer axis was explicitly opted in."
                  % sub_t["fable"]["n"])
        if TIER_RANK.get(tier_of(max(main_t, key=lambda k: main_t[k]["n"])), 0) > cap_rank:
            print("    FYI: the MAIN THREAD ran above the cap. That is by design --")
            print("         models.cap governs sub-agents only. Set your session model too.")

    if subs and not args.brief:
        print("\n  TOP SUB-AGENTS BY COST")
        rows = []
        for s in subs:
            c = sum(cost_of(t, u) for t, u in roll(s["by_model"]).items())
            tiers = "+".join(sorted({tier_of(m) for m in s["by_model"]}))
            rows.append((c, tiers, s["first_prompt"]))
        for c, tiers, prompt in sorted(rows, key=lambda r: -r[0])[: args.top]:
            print("    $%7.2f  %-14s %s" % (c, tiers, prompt[:78]))

    return dict(
        session=session.stem,
        main=main_t,
        subs=sub_t,
        main_cost=main_cost,
        sub_cost=sub_cost,
        agents=len(subs),
    )


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(Path.home() / ".claude" / "projects"),
                    help="transcript store (default ~/.claude/projects)")
    ap.add_argument("--list", action="store_true",
                    help="list projects and sessions by size, then exit")
    ap.add_argument("--project", help="substring match on the project dir name")
    ap.add_argument("--session", help="session uuid or prefix")
    ap.add_argument("--check-cap", metavar="TIER",
                    help="assert no sub-agent exceeded this tier (haiku|sonnet|opus)")
    ap.add_argument("--min-mb", type=float, default=1.0,
                    help="skip sessions smaller than this (default 1MB)")
    ap.add_argument("--top", type=int, default=12, help="how many sub-agents to list")
    ap.add_argument("--brief", action="store_true", help="skip the sub-agent listing")
    ap.add_argument("--json", metavar="PATH", help="also write machine-readable results")
    args = ap.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print("No transcript store at %s" % root, file=sys.stderr)
        return 1

    sessions = []
    for proj in sorted(root.iterdir()):
        if not proj.is_dir():
            continue
        if args.project and args.project.lower() not in proj.name.lower():
            continue
        for f in sorted(proj.glob("*.jsonl")):
            sessions.append((proj.name, f))

    if args.list:
        for pname, f in sorted(sessions, key=lambda pf: -pf[1].stat().st_size):
            print("%9.1fMB  %-42s %s" % (f.stat().st_size / 1e6, pname, f.stem))
        return 0

    if args.session:
        sessions = [(p, f) for p, f in sessions if f.stem.startswith(args.session)]
    else:
        sessions = [(p, f) for p, f in sessions
                    if f.stat().st_size >= args.min_mb * 1e6]

    if not sessions:
        print("No sessions matched. Try --list.", file=sys.stderr)
        return 1

    results = []
    for pname, f in sorted(sessions, key=lambda pf: -pf[1].stat().st_size):
        r = report_session(f, args)
        if r:
            r["project"] = pname
            results.append(r)

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2), encoding="utf-8")
        print("\nwrote " + args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
