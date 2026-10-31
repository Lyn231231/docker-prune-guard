#!/usr/bin/env bash
# test_prune_guard.sh — exercise prune-guard.sh against a fake `docker` binary.
#
# No daemon, no real containers. The fake answers the handful of subcommands the
# script uses, and the test asserts the important property: a volume that is
# only mounted by a STOPPED container must never be offered up for pruning.
#
# The fake is installed as `docker` first on PATH, because this box has a real
# docker CLI (and a socket) that would otherwise get called.
set -uo pipefail
cd "$(dirname "$0")"

pass=0; fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "ok   %s\n" "$desc"; pass=$((pass + 1))
  else
    printf "FAIL %s\n     expected: %s\n     actual:   %s\n" "$desc" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

FAKE_BIN="$(mktemp -d)"
trap "rm -rf \"$FAKE_BIN\"" EXIT

# Fake docker: `web` is STOPPED but still mounts vol-web; `db` running mounts
# vol-db. vol-orphan belongs to nothing. All three show up as dangling.
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "info ")
    exit 0 ;;
  "ps -a")
    if [ "$3" = "--format" ] && [ "$4" = "{{.Names}}" ]; then echo web; echo db; fi
    if [ "$3" = "--filter" ]; then echo "old-app  Exited (0) 12 days ago"; fi
    if [ "$3" = "--format" ] && [ "$4" = "{{.Image}}" ]; then echo web:1; echo db:1; fi
    ;;
  "inspect -f")
    case "$4" in
      web) echo vol-web ;;
      db)  echo vol-db ;;
    esac ;;
  "volume ls")
    # only vol-orphan is a true candidate; vol-web is attached to a STOPPED
    # container and must be subtracted from whatever the daemon reports
    printf "%s\n" vol-web vol-orphan ;;
  "images -f")
    : ;;
  "system df")
    echo "Images 1 1 0B 0B 0B"
    echo "vol-orphan 0 120MB 120MB" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"
# Explicit absolute path: the host has a real docker on PATH and a live socket,
# and `PATH=` in front of a command has silently picked up the real binary here.
export DOCKER="$FAKE_BIN/docker"

out="$(timeout 20 ./prune-guard.sh report 2>&1)"
rc=$?
check "report exits 0" "0" "$rc"
check "stopped container volume listed as in use" "1" "$(printf "%s" "$out" | awk "/attached to any/,/considers unused/" | grep -c "vol-web")"
check "running container volume listed as in use" "1" "$(printf "%s" "$out" | awk "/attached to any/,/considers unused/" | grep -c "vol-db")"
check "orphan volume is a prune candidate" "1" "$(printf "%s" "$out" | awk "/considers unused/,/dangling images/" | grep -c "vol-orphan")"
check "attached volume is NOT a candidate" "0" "$(printf "%s" "$out" | awk "/considers unused/,/dangling images/" | grep -cE "vol-web|vol-db")"
check "stale exited container surfaced" "1" "$(printf "%s" "$out" | grep -c "old-app")"

# The daemon lists vol-web as dangling but a stopped container still mounts it:
# prune must refuse rather than delete it, with or without --yes.
out="$(timeout 20 ./prune-guard.sh prune 2>&1)"; rc=$?
check "prune refuses a volume a stopped container mounts" "3" "$rc"
check "refusal names the volume" "1" "$(printf "%s" "$out" | grep -c "vol-web")"

# Now a clean listing: the only dangling volume really is loose. Dry run must
# print the plan and delete nothing.
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "info ") exit 0 ;;
  "ps -a") if [ "${4:-}" = "{{.Names}}" ]; then echo web; fi ;;
  "inspect -f") echo vol-web ;;
  "volume ls") echo vol-orphan ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"
out="$(timeout 20 ./prune-guard.sh prune 2>&1)"; rc=$?
check "clean dry run exits 1" "1" "$rc"
check "clean dry run shows the plan" "2" "$(printf "%s" "$out" | grep -c "[[]dry]")"


out="$(timeout 20 ./prune-guard.sh prune --yes 2>&1)"; rc=$?
check "clean prune --yes exits 0" "0" "$rc"

# a dead daemon must exit 2, not 1
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/bin/sh
exit 1
FAKE
chmod +x "$FAKE_BIN/docker"
timeout 20 ./prune-guard.sh report >/dev/null 2>&1; rc=$?
check "dead daemon exits 2" "2" "$rc"

# if a dangling volume is also attached, prune must refuse with 3
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "info ") exit 0 ;;
  "ps -a") if [ "$4" = "{{.Names}}" ]; then echo ghost; fi ;;
  "inspect -f") echo vol-ghost ;;
  "volume ls") echo vol-ghost ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/docker"
timeout 20 ./prune-guard.sh prune --yes >/dev/null 2>&1; rc=$?
check "attached-but-dangling volume refuses (exit 3)" "3" "$rc"

printf "\n%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
