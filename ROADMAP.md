# Roadmap

## Done

- [x] DNS step: AdGuard, Cloudflare, Google fallback via a systemd-resolved drop-in, with `--no-dns` and `--dns-only`. Evidence: `bash test-dns.sh` rc=0, 10 checks pass (write, no rewrite, backup, rollback, skip when inactive); with the idempotence check removed 2 checks fail.
