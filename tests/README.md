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

## Not covered yet

- Real SSH to Windows / WSL (lab-only; needs `hosts.conf` + keys)
- `install.ps1` (run on Windows manually)
- Interactive `rth ssh`
