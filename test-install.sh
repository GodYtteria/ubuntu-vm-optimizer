#!/usr/bin/env bash
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${UVO_SCRIPT:-$here/optimize-ubuntu-server.sh}"
work="$(mktemp -d "${TMPDIR:-/tmp}/uvo-install-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fails=0
check(){ local name="$1"; shift; if eval "$1"; then echo "PASS $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }
size="$(wc -c <"$script")"
last_line_start="$(( size - $(tail -n1 "$script" | wc -c) ))"
check "version is 0.0.4" 'grep -q "^VERSION=\"0.0.4\"" "$script"'
check "last line calls main" '[[ "$(tail -n1 "$script")" == "main \"\$@\"" ]]'
check "piped --help prints usage" 'bash -s -- --help <"$script" | grep -q "^Usage:"'
for pct in 10 30 60 90; do
  n=$(( size * pct / 100 ))
  head -c "$n" "$script" >"$work/trunc.$pct"
  check "truncated at ${pct}% runs nothing" '[[ -z "$(bash -s -- --help <"$work/trunc.$pct" 2>/dev/null)" ]]'
done
head -c "$last_line_start" "$script" >"$work/trunc.nolast"
check "truncated before last line runs nothing" '[[ -z "$(bash -s -- --help <"$work/trunc.nolast" 2>&1)" ]]'
check "piped non-root run asks nothing and exits 1" 'out="$(setsid bash -s -- --dns-only <"$script" 2>&1)" && rc=0 || rc=$?; [[ $rc -eq 1 && "$out" == *"Run with sudo"* ]]'
export UVO_LIB=1
# shellcheck disable=SC1090
source "$script"
LOG_FILE="$work/log"; : >"$LOG_FILE"
printf 'y\n' >"$work/answer-y"
check "no tty: stdin answer ignored, default No printed" 'out="$(printf "y\n" | ask "Q1?" 2>&1)" && rc=0 || rc=$?; [[ $rc -eq 1 && "$out" == *"default No"* ]]'
check "no tty: confirm_optional default No" 'out="$(printf "y\n" | confirm_optional "Q2?" 2>&1)" && rc=0 || rc=$?; [[ $rc -eq 1 && "$out" == *"default No"* ]]'
check "tty source answer y accepted" 'PROMPT_SRC="$work/answer-y"; printf "n\n" | ask "Q3?" 2>/dev/null'
check "tty source answer n rejected" 'printf "n\n" >"$work/answer-n"; PROMPT_SRC="$work/answer-n"; ! ask "Q4?" 2>/dev/null'
check "tty source EOF defaults No" ': >"$work/answer-eof"; PROMPT_SRC="$work/answer-eof"; ! ask "Q5?" 2>/dev/null'
check "--yes accepts without reading" 'PROMPT_SRC=none; ASSUME_YES=true; out="$(ask "Q6?" 2>&1)"; [[ "$out" == *"--yes"* ]]'
check "--yes accepts optional too" 'ASSUME_YES=true; confirm_optional "Q7?" >/dev/null'
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
