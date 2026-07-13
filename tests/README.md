# tests

## Local smoke (no SSH remotes)

```bash
./tests/smoke.sh
```

Uses `fixtures/hosts.local.conf` (`mac_kind=local` only).

## What it covers

| Area | Checks |
|------|--------|
| CLI | `--version`, `--help` |
| config | `list`, `status`, missing config exit 1 |
| exec | `run`, `matrix`, `--json`, fail exit 3 |
| doctor | local ok |
| guide | human + `--json` |
| syntax | `bash -n` on `bin/rth`, `lib/*`, `install.sh` |

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on every push/PR to `main`:

- `ubuntu-latest` + `macos-latest`
- `bash -n` + ShellCheck
- `./tests/smoke.sh`
- local `./install.sh --verify` dry-run

Tag `v*` → `.github/workflows/release.yml` publishes `rth-vX.Y.Z.tar.gz`.

## Not covered yet

- Real SSH to Windows / WSL (lab-only; needs `hosts.conf` + keys)
- Full `install.ps1` E2E on Windows runners
- Interactive `rth ssh`
