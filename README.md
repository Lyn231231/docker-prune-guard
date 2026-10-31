# prune-guard

A wrapper around `docker volume prune` / `docker image prune` that first asks
the daemon what is *attached*, not just what is *running*.

## The failure

`docker volume prune` only considers a volume in use if a **running** container
mounts it. Stop a container for an afternoon, run `docker system prune`, and the
volume is gone. The container is still there, still configured to mount it, and
next time it starts it gets an empty volume with the right name — which looks
exactly like a working stack until you notice the data is missing.

The second half of the problem is that nobody notices. Prune runs from a timer or
a cron job, prints three lines, and exits 0.

## What this does

```bash
./prune-guard.sh report          # read-only
./prune-guard.sh prune           # dry run: prints what it would do
./prune-guard.sh prune --yes     # actually prunes
```

`report` prints four lists:

- volumes mounted by any container, running or stopped
- volumes the daemon offers as prune candidates (dangling)
- dangling images
- exited containers older than a week

`prune` computes the attached set again, then subtracts it from the candidate
set. If anything you are about to delete turns out to be mounted by *any*
container — including one that is stopped, restarting, or dead — it prints the
volume name and exits 3 without touching anything.

Exit codes: `0` ok, `1` dry run with work to do, `2` docker missing or the
daemon is unreachable, `3` refused because a candidate is attached.

## Why not just use the filter

```bash
docker volume prune -f --filter label=keep=yes
```

That works if everything you care about is labelled. On a box where stacks come
and go, most volumes are not labelled, and adding the label retroactively means
touching every compose file first. `prune-guard` reads the live mount table
instead, which is the thing the daemon already knows and the filter cannot see.

## Tests

```bash
./test_prune_guard.sh
```

13 checks against a fake `docker` binary: an attached volume must never appear as
a candidate, `prune --yes` must refuse when a candidate is attached, a dead
daemon must exit 2 rather than 1, and a clean listing must prune only the loose
volume. No daemon is contacted; the test runs on a laptop or in CI.

## License

MIT. See [LICENSE](LICENSE).
