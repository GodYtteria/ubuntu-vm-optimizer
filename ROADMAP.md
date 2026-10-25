# Roadmap

## Done

- [x] DNS step: AdGuard, Cloudflare, Google fallback via a systemd-resolved drop-in, with `--no-dns` and `--dns-only`. Evidence: `bash test-dns.sh` rc=0, 10 checks pass (write, no rewrite, backup, rollback, skip when inactive); with the idempotence check removed 2 checks fail.
- [x] One-line install: `curl ... | sudo bash` and `| sudo bash -s -- --dns-only`; prompts read `/dev/tty`, safe default and `--yes` without one; body wrapped in `main` so a truncated download runs nothing. Evidence: `bash test-install.sh` rc=0, 16 checks pass; against the v0.0.3 script 10 checks fail (truncation at 60% and 90% printed usage, prompts read stdin).
- [x] Safe piped apt and separate removal consent: mutating apt-get runs with `-y`, `DEBIAN_FRONTEND=noninteractive` and `--force-confold`; removals need `--yes-removals`. Evidence: `bash test-install.sh` rc=0, 25 checks pass; with `-y` stripped from the script 4 checks fail (fake apt aborts on closed stdin).
- [x] Piped override guard: test overrides and `UVO_LIB` are honoured only when the script is sourced; the last line is one `if` statement so any cut runs nothing; os-release values strip one matching quote pair. Evidence: `bash test-install.sh` rc=0, 31 checks pass; against the v0.0.5 script the piped-override check and the last-line cut check fail.
