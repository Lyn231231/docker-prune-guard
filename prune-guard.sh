#!/usr/bin/env bash
# prune-guard — show what `docker system prune` / `volume prune` would delete
# before it deletes it, and refuse to run the destructive part unless the
# leftovers are actually leftovers.
#
# Written after losing a volume that `docker volume prune` considered unused:
# the container that mounted it was stopped, not running, and prune only looks
# at running attachments.
#
#   ./prune-guard.sh report          # read-only: print candidates, change nothing
#   ./prune-guard.sh prune [--yes]   # delete only what report said was safe
#
# Exit codes: 0 ok, 1 nothing to prune or --yes missing in dry mode, 2 docker
# unavailable, 3 a "candidate" turned out to be in use (nothing was deleted).
set -uo pipefail

DOCKER="${DOCKER:-docker}"
MODE="${1:-report}"
ASSUME_YES="${2:-}"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

need_docker() {
  command -v "$DOCKER" >/dev/null 2>&1 || { warn "docker not found"; exit 2; }
  "$DOCKER" info >/dev/null 2>&1 || { warn "cannot talk to the docker daemon"; exit 2; }
}

# Volume names mounted by ANY container, running or stopped. Stopped containers
# still hold the data; `docker volume prune` does not care and will delete it.
# The inspect format goes through a variable: nesting ${...} inside a
# double-quoted command substitution is how you lose a day debugging quoting.
FMT_VOLUMES='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{println}}{{end}}{{end}}'

volumes_in_use() {
  "$DOCKER" ps -a --format '{{.Names}}' \
    | while read -r c; do
        [ -z "$c" ] && continue
        "$DOCKER" inspect -f "$FMT_VOLUMES" "$c" 2>/dev/null
      done | sort -u
}

images_in_use() {
  "$DOCKER" ps -a --format '{{.Image}}' | sort -u
}

report() {
  local in_use_vols dangling_images stale_containers
  in_use_vols="$(volumes_in_use)"

  say "== volumes attached to any container (running or stopped) =="
  if [ -n "$in_use_vols" ]; then
    printf '  %s\n' $in_use_vols
  else
    say "  (none)"
  fi

  say ""
  say "== volumes docker considers unused (prune would delete these) =="
  local loose=()
  while read -r v; do
    [ -z "$v" ] && continue
    # docker volume ls -f dangling=true misses stopped-container mounts;
    # treat "dangling" as the base set and subtract what we proved is in use
    if ! printf '%s\n' "$in_use_vols" | grep -qx "$v"; then
      loose+=("$v")
    fi
  done < <("$DOCKER" volume ls --filter dangling=true --format '{{.Name}}')

  if [ ${#loose[@]} -eq 0 ]; then
    say "  (none)"
  else
    for v in "${loose[@]}"; do
      local size
      size="$("$DOCKER" system df -v 2>/dev/null | awk -v n="$v" '$1 == n {print $3}' | head -1)"
      printf '  %-40s %s\n' "$v" "${size:-?}"
    done
  fi

  say ""
  say "== dangling images =="
  dangling_images="$("$DOCKER" images -f dangling=true --format '{{.ID}}  {{.Repository}}:{{.Tag}}  {{.Size}}')"
  say "${dangling_images:-  (none)}"

  say ""
  say "== exited containers older than 7 days =="
  stale_containers="$("$DOCKER" ps -a --filter status=exited --format '{{.Names}}  {{.Status}}' \
      | awk '/days|weeks|months/ {print "  " $0}')"
  say "${stale_containers:-  (none)}"

  if [ ${#loose[@]} -gt 0 ]; then
    say ""
    warn "!! ${#loose[@]} unused volume(s). Read the list above before pruning."
    warn "!! A stopped container that mounts one of these is not 'running' but"
    warn "!! still owns its data — this script already excluded those."
  fi
}

prune() {
  local in_use_vols
  in_use_vols="$(volumes_in_use)"

  # safety: refuse if a listed volume is actually attached
  while read -r v; do
    [ -z "$v" ] && continue
    if printf '%s\n' "$in_use_vols" | grep -qx "$v"; then
      warn "refusing: volume $v is attached to a container"
      return 3
    fi
  done < <("$DOCKER" volume ls --filter dangling=true --format '{{.Name}}')

  if [ "$ASSUME_YES" != "--yes" ]; then
    say "[dry] would run: $DOCKER volume prune -f"
    say "[dry] would run: $DOCKER image prune -f"
    say "re-run with: $0 prune --yes"
    return 1
  fi

  say "$("$DOCKER" volume prune -f 2>&1)"
  say "$("$DOCKER" image prune -f 2>&1)"
  return 0
}

need_docker
case "$MODE" in
  report) report ;;
  prune)  prune ;;
  *) warn "usage: $0 {report|prune [--yes]}"; exit 2 ;;
esac
