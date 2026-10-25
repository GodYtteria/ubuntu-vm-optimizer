#!/usr/bin/env bash
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/uvo-dns-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fails=0
check(){ local name="$1"; shift; if eval "$1"; then echo "PASS $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }
checkv(){ local name="$1"; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }
export UVO_LIB=1 UVO_TEST=1 UVO_DNS_GLOBAL_CMD=true
export UVO_RESOLVED_DIR="$work/resolved.conf.d"
export UVO_RESOLVED_ACTIVE_CMD="true"
printf '#!/usr/bin/env bash\necho x >> "%s/restarts"\n' "$work" >"$work/fake-restart"
chmod +x "$work/fake-restart"
: >"$work/restarts"
export UVO_RESOLVED_RESTART_CMD="$work/fake-restart"
export UVO_DNS_VERIFY_CMD="true"
source "$here/optimize-ubuntu-server.sh"
LOG_FILE="$work/log"; : >"$LOG_FILE"
conf="$UVO_RESOLVED_DIR/90-uvo-dns.conf"
dns_step >/dev/null
check "first run writes file" '[[ -f "$conf" ]] && grep -q "^DNS=94.140.14.14#dns.adguard-dns.com" "$conf" && grep -q "^FallbackDNS=8.8.8.8#dns.google" "$conf" && grep -q "^DNSOverTLS=opportunistic" "$conf"'
check "first run restarts once" '[[ "$(wc -l <"$work/restarts")" -eq 1 ]]'
before="$(stat -c %Y.%i "$conf")"; sleep 1
dns_step >/dev/null
after="$(stat -c %Y.%i "$conf")"
checkv "second run does not write" [ "$after" = "$before" ]
check "second run does not restart" '[[ "$(wc -l <"$work/restarts")" -eq 1 ]]'
printf '[Resolve]\nDNS=9.9.9.9\n' >"$conf"
dns_step >/dev/null
check "backup created from old file" 'grep -q "^DNS=9.9.9.9" "$UVO_RESOLVED_DIR/90-uvo-dns.conf.bak"'
check "changed file rewritten" 'grep -q "^DNS=94.140.14.14" "$conf"'
printf '[Resolve]\nDNS=9.9.9.9\n' >"$conf"
DNS_VERIFY_CMD="false"
rc=0; dns_step >/dev/null 2>&1 || rc=$?
checkv "failed verify returns nonzero" [ "$rc" -ne 0 ]
check "failed verify restores backup" 'grep -q "^DNS=9.9.9.9" "$conf"'
rm -f "$conf" "$UVO_RESOLVED_DIR/90-uvo-dns.conf.bak"
rc=0; dns_step >/dev/null 2>&1 || rc=$?
check "failed verify with no old file removes conf" '[[ $rc -ne 0 && ! -e "$conf" ]]'
DNS_VERIFY_CMD="true"
RESOLVED_ACTIVE_CMD="false"
dns_step >/dev/null
check "inactive resolved skips" '[[ ! -e "$conf" ]]'
RESOLVED_ACTIVE_CMD="true"
printf '[Resolve]\nDNS=9.9.9.9\n' >"$conf"
mkdir "$UVO_RESOLVED_DIR/90-uvo-dns.conf.new"
rc=0; dns_step >/dev/null 2>&1 || rc=$?
checkv "failing write returns nonzero" [ "$rc" -ne 0 ]
check "failing write leaves old conf intact" 'grep -q "^DNS=9.9.9.9" "$conf"'
rmdir "$UVO_RESOLVED_DIR/90-uvo-dns.conf.new"
rm -f "$conf" "$UVO_RESOLVED_DIR/90-uvo-dns.conf.bak"
DNS_GLOBAL_CMD="false"
rc=0; dns_step >/dev/null 2>&1 || rc=$?
check "failed global dns check rolls back" '[[ $rc -ne 0 && ! -e "$conf" ]]'
DNS_GLOBAL_CMD="true"
printf '%s' "$DNS_CONF" >"$UVO_RESOLVED_DIR/dns.conf"
dns_step >/dev/null
check "legacy dns.conf with our content removed" '[[ ! -e "$UVO_RESOLVED_DIR/dns.conf" && -f "$conf" ]]'
printf '[Resolve]\nDNS=9.9.9.9\n' >"$UVO_RESOLVED_DIR/dns.conf"
dns_step >/dev/null
check "legacy dns.conf with other content kept" 'grep -q "^DNS=9.9.9.9" "$UVO_RESOLVED_DIR/dns.conf"'
leak="$(UVO_TEST=0 UVO_LIB=1 UVO_RESOLVED_DIR=/evil UVO_RESOLVED_RESTART_CMD=evil UVO_RESOLVED_ACTIVE_CMD=evil UVO_DNS_VERIFY_CMD=evil UVO_DNS_GLOBAL_CMD=evil bash -c 'source "$1"; echo "$RESOLVED_DIR|$RESOLVED_RESTART_CMD|$RESOLVED_ACTIVE_CMD|$DNS_VERIFY_CMD|$DNS_GLOBAL_CMD"' _ "$here/optimize-ubuntu-server.sh")"
checkv "overrides ignored without UVO_TEST" [ "$leak" = "/etc/systemd/resolved.conf.d|systemctl restart systemd-resolved|systemctl is-active --quiet systemd-resolved|dns_default_verify|dns_default_global" ]
rc=0; out="$(UVO_LIB=0 bash "$here/optimize-ubuntu-server.sh" --dns-only --no-dns 2>&1)" || rc=$?
checkv "dns-only with no-dns exits 2" [ "$rc" -eq 2 ]
checkv "dns-only with no-dns explains" [ "$out" = "--dns-only cannot be combined with --no-dns" ]
printf '%s' "$DNS_CONF" >"$UVO_RESOLVED_DIR/dns.conf"
rm -f "$conf"; mkdir "$UVO_RESOLVED_DIR/90-uvo-dns.conf.new"
rc=0; dns_step >/dev/null 2>&1 || rc=$?
checkv "failed write keeps legacy dns.conf" [ -f "$UVO_RESOLVED_DIR/dns.conf" ]
rmdir "$UVO_RESOLVED_DIR/90-uvo-dns.conf.new"; rm -f "$UVO_RESOLVED_DIR/dns.conf"
printf '[Resolve]\nDNS=9.9.9.9\n' >"$conf"
DNS_VERIFY_CMD="false"
mv(){ [[ "$1" == *.bak ]] && return 1; command mv "$@"; }
rc=0; dns_step >"$work/out" 2>&1 || rc=$?
unset -f mv
checkv "failed restore returns nonzero" [ "$rc" -ne 0 ]
checkv "failed restore warns restore failed" grep -q "restore failed: $conf" "$work/out"
checkv "failed restore does not claim restored" bash -c '! grep -q "configuration restored" "$1"' _ "$work/out"
DNS_VERIFY_CMD="true"
rm -f "$conf" "$UVO_RESOLVED_DIR/90-uvo-dns.conf.bak"
checkv "global check accepts adguard" bash -c 'source "$1"; printf "Global: 94.140.14.14#dns.adguard-dns.com 1.1.1.1\nLink 2 (eth0): 10.0.0.1\n" | dns_global_ok' _ "$here/optimize-ubuntu-server.sh"
checkv "global check rejects 94.140.14.140" bash -c '! { source "$1"; printf "Global: 94.140.14.140 94.140.15.140\n" | dns_global_ok; }' _ "$here/optimize-ubuntu-server.sh"
checkv "global check ignores link lines" bash -c '! { source "$1"; printf "Link 2 (eth0): 94.140.14.14\n" | dns_global_ok; }' _ "$here/optimize-ubuntu-server.sh"
trace="$(UVO_TEST=1 UVO_RESOLVED_DIR=/evil UVO_RESOLVED_RESTART_CMD=evil UVO_DNS_VERIFY_CMD=evil bash -x "$here/optimize-ubuntu-server.sh" --help 2>&1 >/dev/null)"
checkv "direct run never assigns overrides" bash -c '! grep -q "evil" <<<"$1"' _ "$trace"
checkv "direct run keeps default dir" grep -q "^+ RESOLVED_DIR=/etc/systemd/resolved.conf.d" <<<"$trace"
echo "failures=$fails"
[[ $fails -eq 0 ]]
