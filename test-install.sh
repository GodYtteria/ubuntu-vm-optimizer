#!/usr/bin/env bash
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/optimize-ubuntu-server.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/uvo-install-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fails=0
check(){ local name="$1"; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fails=$((fails+1)); fi; }
size="$(wc -c <"$script")"
last_line_start="$(( size - $(tail -n1 "$script" | wc -c) ))"

version_is_005(){ grep -q '^VERSION="0.0.5"' "$script"; }
last_line_is_main(){ [[ "$(tail -n1 "$script")" == 'main "$@"' ]]; }
piped_help(){ bash -s -- --help <"$script" | grep -q '^Usage:'; }
truncated_runs_nothing(){ head -c "$1" "$script" >"$work/trunc"; [[ -z "$(bash -s -- --help <"$work/trunc" 2>/dev/null)" ]]; }
piped_nonroot_exits_1(){ local out rc=0; out="$(setsid bash -s -- --dns-only <"$script" 2>&1)" || rc=$?; [[ $rc -eq 1 && "$out" == *"Run with sudo"* ]]; }

UVO_LIB=1; UVO_TEST=1
source "$here/optimize-ubuntu-server.sh"
LOG_FILE="$work/log"; : >"$LOG_FILE"

ask_ignores_stdin(){ local out rc=0; out="$(printf 'y\n' | ask 'Q?' 2>&1)" || rc=$?; [[ $rc -eq 1 && "$out" == *"default No"* ]]; }
removal_ignores_stdin(){ local out rc=0; out="$(printf 'y\n' | confirm_removal 'Q?' 2>&1)" || rc=$?; [[ $rc -eq 1 && "$out" == *"default No"* ]]; }
answer_from_source(){ printf '%s\n' "$1" >"$work/ans"; PROMPT_SRC="$work/ans"; ask 'Q?' 2>/dev/null; }
answer_y_accepted(){ answer_from_source y; }
answer_n_rejected(){ ! answer_from_source n; }
answer_eof_rejected(){ : >"$work/ans"; PROMPT_SRC="$work/ans"; ! ask 'Q?' 2>/dev/null; }
yes_accepts(){ local out; PROMPT_SRC=none; ASSUME_YES=true; out="$(ask 'Q?' 2>&1)"; [[ "$out" == *"--yes"* ]]; }
yes_skips_removal(){ local out rc=0; ASSUME_YES=true; ASSUME_REMOVALS=false; out="$(confirm_removal 'Q?' 2>&1)" || rc=$?; [[ $rc -eq 1 && "$out" == *"skipped (use --yes-removals)"* ]]; }
removals_flag_accepts(){ ASSUME_REMOVALS=true; confirm_removal 'Q?' >/dev/null; }

src_none(){ PROMPT_SRC=x; TTY_PATH="$work/missing"; select_prompt_src </dev/null; [[ "$PROMPT_SRC" == none ]]; }
src_override(){ : >"$work/fake-tty"; PROMPT_SRC=x; TTY_PATH="$work/fake-tty"; select_prompt_src </dev/null; [[ "$PROMPT_SRC" == "$work/fake-tty" ]]; }
src_tty_stdin(){
  local out
  out="$(python3 -I - "$script" <<'PY'
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.environ["UVO_LIB"] = "1"
    os.execvp("bash", ["bash", "-c", 'source "$1"; select_prompt_src; echo "SRC=$PROMPT_SRC"', "_", sys.argv[1]])
data = b""
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
os.waitpid(pid, 0)
sys.stdout.write(data.decode())
PY
)"
  [[ "$out" == *"SRC=/dev/stdin"* ]]
}

bin="$work/bin"; mkdir -p "$bin"
printf '#!/usr/bin/env bash\necho 0\n' >"$bin/id"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/systemctl"
printf '#!/usr/bin/env bash\necho installed\n' >"$bin/dpkg-query"
cat >"$bin/apt-get" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_APT_CALLS"
mutating=false; yes=false; simulate=false
for a in "$@"; do
  case "$a" in
    upgrade|purge|autoremove) mutating=true ;;
    -y) yes=true ;;
    -s) simulate=true ;;
  esac
done
if $mutating && ! $simulate; then
  if [[ -t 0 ]]; then exit 0; fi
  if ! $yes || [[ "${DEBIAN_FRONTEND:-}" != noninteractive ]] || [[ "$*" != *"Dpkg::Options::=--force-confold"* ]]; then
    echo "E: apt would prompt and abort on closed stdin: $*" >&2; exit 100
  fi
fi
exit 0
EOS
chmod +x "$bin"/*
printf 'ID=ubuntu\nPRETTY_NAME="Ubuntu Fake"\n' >"$work/os-release"
export FAKE_APT_CALLS="$work/apt-calls"
run_main_piped(){
  : >"$FAKE_APT_CALLS"
  ( ASSUME_YES=false; ASSUME_REMOVALS=false; PATH="$bin:$PATH"; OS_RELEASE_FILE="$work/os-release"; LOG_FILE="$work/main.log"; TTY_PATH="$work/missing"
    printf 'y\ny\ny\ny\n' | main --no-dns --no-snap --no-lvm "$@" ) >"$work/main.out" 2>&1
}
piped_yes_run_passes(){ run_main_piped --yes && ! grep -q "apt would prompt" "$work/main.out"; }
piped_yes_run_used_y(){ grep -q -- '-y .*upgrade' "$FAKE_APT_CALLS" && grep -q -- '-y .*autoremove' "$FAKE_APT_CALLS"; }
piped_yes_skips_removals(){ ! grep -q 'purge modemmanager' "$FAKE_APT_CALLS" && grep -q 'skipped (use --yes-removals)' "$work/main.out"; }
piped_removals_run_passes(){ run_main_piped --yes --yes-removals && ! grep -q "apt would prompt" "$work/main.out"; }
piped_removals_purge_used_y(){ grep -q -- '-y .*purge modemmanager' "$FAKE_APT_CALLS"; }

check "version is 0.0.5" version_is_005
check "last line calls main" last_line_is_main
check "piped --help prints usage" piped_help
for pct in 10 30 60 90; do check "truncated at ${pct}% runs nothing" truncated_runs_nothing "$(( size * pct / 100 ))"; done
check "truncated before last line runs nothing" truncated_runs_nothing "$last_line_start"
check "piped non-root run exits 1 without asking" piped_nonroot_exits_1
check "no tty: stdin answer ignored, default No printed" ask_ignores_stdin
check "no tty: removal ignores stdin, default No" removal_ignores_stdin
check "tty source answer y accepted" answer_y_accepted
check "tty source answer n rejected" answer_n_rejected
check "tty source EOF defaults No" answer_eof_rejected
check "--yes accepts normal prompt" yes_accepts
check "--yes alone skips removal" yes_skips_removal
check "--yes-removals accepts removal" removals_flag_accepts
check "select_prompt_src: none" src_none
check "select_prompt_src: tty override" src_override
check "select_prompt_src: stdin is tty" src_tty_stdin
check "piped fake-root main --yes succeeds with fake apt" piped_yes_run_passes
check "piped main used -y for upgrade and autoremove" piped_yes_run_used_y
check "piped main --yes skipped removals" piped_yes_skips_removals
check "piped main --yes --yes-removals succeeds" piped_removals_run_passes
check "piped main purge used -y" piped_removals_purge_used_y
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
