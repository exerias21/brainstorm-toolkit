#!/usr/bin/env bash
# brainstorm-toolkit — expiring leases for what a git worktree cannot isolate.
#
# WHY THIS EXISTS: a worktree per writer isolates files and the index, but not
# a shared database, a fixed port, a cron window, or the CPU a full test suite
# needs. Two lanes that both run the suite, or one that runs a long read while
# a nightly job writes, collide no matter how their files are split. A lease is
# a named claim with an expiry: an agent takes it before touching the shared
# thing and releases it after. It is a courtesy, not a lock the OS enforces --
# whatever touches the resource must ask first.
#
# WHY IT EXPIRES: an agent that crashes, is killed or simply forgets never
# releases. A lease without a TTL turns that into a resource held forever and a
# human hunting for who holds it. Every lease here expires; `renew` extends it.
#
# State: one flat file, <state>/leases.tsv (resource<TAB>holder<TAB>expires
# epoch), guarded by a mkdir lock (portable: flock is absent on stock macOS).
# <state> is $PARALLEL_STATE_DIR, else <main worktree>/.claude/parallel, so
# every worktree of one repo shares one lease table. Gitignore .claude/parallel/.
#
# Subcommands (several resources = all-or-nothing, so two lanes asking for
# overlapping sets can never each hold half and deadlock):
#
#   lease.sh acquire <resource>... --holder H [--ttl SECONDS]
#     exit 0 and print "acquired ..." when every resource is free, expired or
#     already held by H (that renews it). exit 1 and print "held: <resource>
#     by <holder> until <epoch>" for each blocker, taking nothing.
#   lease.sh renew <resource>... --holder H [--ttl SECONDS]
#     extend H's leases. exit 1 if another holder has any of them.
#   lease.sh release <resource>... --holder H
#     drop H's leases. Not held is fine (exit 0); held by another is exit 1.
#   lease.sh sweep        drop expired leases, print each one dropped.
#   lease.sh list         print the live leases, one per line.
#
# Defaults: --holder from $LEASE_HOLDER; --ttl 900 seconds. $LEASE_NOW
# overrides the clock (tests only). Never waits for a busy resource: a caller
# that wants to wait should re-try on its own schedule (a background-task
# notification), not spin in a polling loop here.
set -euo pipefail

usage() { sed -n '22,36p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
SUB="$1"; shift

HOLDER="${LEASE_HOLDER:-}"
TTL=900
RES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --holder) HOLDER="${2:-}"; shift 2 ;;
    --ttl)    TTL="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    --*) echo "lease.sh: unknown flag $1" >&2; usage ;;
    *) RES+=("$1"); shift ;;
  esac
done

case "$TTL" in ''|*[!0-9]*) echo "lease.sh: --ttl must be a positive integer" >&2; exit 2 ;; esac
[ "$TTL" -ge 1 ] || { echo "lease.sh: --ttl must be >= 1" >&2; exit 2; }
for r in "${RES[@]+"${RES[@]}"}"; do
  case "$r" in *[[:space:]]*|'') echo "lease.sh: resource names may not contain whitespace" >&2; exit 2 ;; esac
done
case "$HOLDER" in *[[:space:]]*) echo "lease.sh: holder may not contain whitespace" >&2; exit 2 ;; esac

state_dir() {
  if [ -n "${PARALLEL_STATE_DIR:-}" ]; then printf '%s' "$PARALLEL_STATE_DIR"; return; fi
  local common
  if common="$(git rev-parse --git-common-dir 2>/dev/null)"; then
    printf '%s/.claude/parallel' "$(cd "$(dirname "$common")" && pwd)"
  else
    printf '%s/.claude/parallel' "$PWD"
  fi
}
STATE="$(state_dir)"
mkdir -p "$STATE"
FILE="$STATE/leases.tsv"
LOCK="$STATE/leases.lock"
touch "$FILE"
NOW="${LEASE_NOW:-$(date +%s)}"

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# The lock is held for milliseconds, so a lock dir older than 30s belongs to a
# killed process; break it rather than wedge every later caller.
take_lock() {
  local tries=0
  until mkdir "$LOCK" 2>/dev/null; do
    if [ $(( $(date +%s) - $(mtime "$LOCK") )) -gt 30 ]; then rmdir "$LOCK" 2>/dev/null || true; continue; fi
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || { echo "lease.sh: could not take $LOCK" >&2; exit 3; }
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

# Rewrites FILE without expired rows; prints each dropped row on fd 3.
purge_expired() {
  local tmp="$FILE.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r r h e; do
    [ -n "${r:-}" ] || continue
    if [ "$e" -gt "$NOW" ]; then printf '%s\t%s\t%s\n' "$r" "$h" "$e" >> "$tmp"
    else printf 'expired: %s by %s at %s\n' "$r" "$h" "$e" >&3; fi
  done < "$FILE"
  mv "$tmp" "$FILE"
}

holder_of() { awk -F'\t' -v r="$1" '$1==r {print $2 "\t" $3; exit}' "$FILE"; }

# Drop the named resources (any holder) and append them for HOLDER.
write_rows() {
  local tmp="$FILE.tmp.$$" exp=$((NOW + TTL)) r
  awk -F'\t' -v list=" ${RES[*]} " 'index(list, " " $1 " ") == 0' "$FILE" > "$tmp"
  for r in "${RES[@]}"; do printf '%s\t%s\t%s\n' "$r" "$HOLDER" "$exp" >> "$tmp"; done
  mv "$tmp" "$FILE"
}

need_res()    { [ "${#RES[@]}" -ge 1 ] || { echo "lease.sh $SUB: name at least one resource" >&2; exit 2; }; }
need_holder() { [ -n "$HOLDER" ] || { echo "lease.sh $SUB: --holder (or \$LEASE_HOLDER) is required" >&2; exit 2; }; }

# Every resource must be free or already HOLDER's; otherwise report and fail.
check_free() {
  local r cur h e blocked=0
  for r in "${RES[@]}"; do
    cur="$(holder_of "$r")"
    [ -n "$cur" ] || continue
    h="${cur%%$'\t'*}"; e="${cur##*$'\t'}"
    if [ "$h" != "$HOLDER" ]; then echo "held: $r by $h until $e"; blocked=1; fi
  done
  return "$blocked"
}

case "$SUB" in
  acquire|renew)
    need_res; need_holder; take_lock
    purge_expired 3>/dev/null
    if ! check_free; then exit 1; fi
    write_rows
    verb=acquired; [ "$SUB" = renew ] && verb=renewed
    echo "$verb: ${RES[*]} by $HOLDER until $((NOW + TTL))"
    ;;
  release)
    need_res; need_holder; take_lock
    purge_expired 3>/dev/null
    if ! check_free; then exit 1; fi
    tmp="$FILE.tmp.$$"
    awk -F'\t' -v list=" ${RES[*]} " 'index(list, " " $1 " ") == 0' "$FILE" > "$tmp"
    mv "$tmp" "$FILE"
    echo "released: ${RES[*]} by $HOLDER"
    ;;
  sweep)
    take_lock
    purge_expired 3>&1
    ;;
  list)
    take_lock
    purge_expired 3>/dev/null
    while IFS=$'\t' read -r r h e; do
      [ -n "${r:-}" ] && printf '%s\t%s\t%s (in %ss)\n' "$r" "$h" "$e" "$((e - NOW))"
    done < "$FILE"
    ;;
  -h|--help) usage ;;
  *) echo "lease.sh: unknown subcommand $SUB" >&2; usage ;;
esac
exit 0
