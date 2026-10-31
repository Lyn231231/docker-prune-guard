<div align="center">

# docker-prune-guard

**Prune Docker without shooting yourself in the foot — it asks the registry which digests are pinned before deleting anything.**

[![tests](https://img.shields.io/badge/tests-passing-brightgreen?style=flat-square)](#quick-start)
[![shell](https://img.shields.io/badge/shell-bash%203.2%2B-black?style=flat-square&logo=gnubash)](#quick-start)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

</div>

## About

`docker system prune -a` does not know that a container may be recreated
tomorrow from an image older than 30 days, and `docker volume prune` deletes
volumes whose `LINKS` column reads `0` while still being referenced by a
compose file. Both of those have cost real people real data.

This script builds an explicit keep-set first — running containers, images
referenced by compose files under the configured roots, and anything matching
`--protect` — then prints exactly what would be removed. Removal needs `--yes`,
and a removal that would cross the keep-set aborts the whole run.

## Quick start

```bash
git clone https://github.com/Lyn231231/docker-prune-guard
cd docker-prune-guard
bash test_prune_guard.sh         # full suite
sudo ./prune-guard.sh --dry-run  # shows what would go
```

## Configuration

| Key | Description |
| --- | --- |
| `--dry-run` | print the plan, delete nothing |
| `--keep-days N` | never touch images newer than N days (default 14) |
| `--protect PATTERN` | image name glob to keep regardless of age, repeatable |
| `--yes` | required for any actual removal |
## Roadmap

- [ ] Podman support
- [ ] JSON plan output for review before apply
- [ ] Warning when an image is referenced only by a stopped container

## Contributing

Issues and pull requests are welcome. Please keep changes small and focused,
and add a test for any behaviour change — every repository here ships with a
runnable test suite and no third-party dependencies, so CI is just
`python3 -m unittest` / `bash test_*.sh`.

## License

[MIT](LICENSE)
