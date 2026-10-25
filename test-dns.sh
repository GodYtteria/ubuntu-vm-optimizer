#!/usr/bin/env bash
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/uvo-dns-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fails=0
check(){ if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
export UVO_LIB=1
export UVO_RESOLVED_DIR="$work/resolved.conf.d"
export UVO_RESOLVED_ACTIVE_CMD="true"
printf '#!/usr/bin/env bash\necho x >> "%s/restarts"\n' "$work" >"$work/fake-restart"
chmod +x "$work/fake-restart"
: >"$work/restarts"
export UVO_RESOLVED_RESTART_CMD="$work/fake-restart"
export UVO_DNS_VERIFY_CMD="true"
source "$here/optimize-ubuntu-server.sh"
LOG_FILE="$work/log"; : >"$LOG_FILE"
conf="$UVO_RESOLVED_DIR/dns.conf"
dns_step >/dev/null
check "first run writes file" '[[ -f "$conf" ]] && grep -q "^DNS=94.140.14.14#dns.adguard-dns.com" "$conf" && grep -q "^FallbackDNS=8.8.8.8#dns.google" "$conf" && grep -q "^DNSOverTLS=opportunistic" "$conf"'
check "first run restarts once" '[[ "$(wc -l <"$work/restarts")" -eq 1 ]]'
before="$(stat -c %Y.%i "$conf")"; sleep 1
dns_step >/dev/null
check "second run does not write" '[[ "$(stat -c %Y.%i "$conf")" == "$before" ]]'
check "second run does not restart" '[[ "$(wc -l <"$work/restarts")" -eq 1 ]]'
printf '[Resolve]\nDNS=9.9.9.9\n' >"$conf"
dns_step >/dev/null
check "backup created from old file" 'grep -q "^DNS=9.9.9.9" "$UVO_RESOLVED_DIR/dns.conf.bak"'
check "changed file rewritten" 'grep -q "^DNS=94.140.14.14" "$conf"'
printf '[Resolve]\nDNS=9.9.9.9\n' >"$conf"
DNS_VERIFY_CMD="false"
rc=0; dns_step >/dev/null 2>&1 || rc=$?
check "failed verify returns nonzero" '[[ $rc -ne 0 ]]'
check "failed verify restores backup" 'grep -q "^DNS=9.9.9.9" "$conf"'
rm -f "$conf" "$UVO_RESOLVED_DIR/dns.conf.bak"
rc=0; dns_step >/dev/null 2>&1 || rc=$?
check "failed verify with no old file removes conf" '[[ $rc -ne 0 && ! -e "$conf" ]]'
DNS_VERIFY_CMD="true"
RESOLVED_ACTIVE_CMD="false"
dns_step >/dev/null
check "inactive resolved skips" '[[ ! -e "$conf" ]]'
echo "failures=$fails"
[[ $fails -eq 0 ]]
