#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
REMOVE_SNAP=false
REMOVE_OPTIONAL_PACKAGES=false
DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Ubuntu VM Optimizer

Usage:
  sudo ./optimize-ubuntu-server.sh [options]

Options:
  --remove-snap               Remove Snap only after listing installed snaps and confirmation.
  --remove-optional-packages  Offer to purge ModemManager, PackageKit, open-iscsi,
                              and multipath-tools (only if you do not use them).
  --dry-run                   Show planned actions without changing the system.
  -y, --yes                   Skip confirmation prompts (not recommended for optional removals).
  -h, --help                  Show this help.

Default actions (conservative):
  - Set default boot target to multi-user.target (no graphical login target).
  - Disable Apport crash reporting.
  - Disable the motd-news timer if present.
  - Clean APT cache and remove unused dependencies.

Optional package removals can affect systems using cellular modems, PackageKit/software
management tools, iSCSI, multipath storage, or Snap applications. Inspect the plan first.
USAGE
}

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
run() {
  if $DRY_RUN; then
    printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}
confirm() {
  local prompt="$1" answer
  if $ASSUME_YES; then
    [[ "$prompt" == *"optional packages"* ]] && { warn "--yes does not approve optional package removals; skipping."; return 1; }
    return 0
  fi
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

while (($#)); do
  case "$1" in
    --remove-snap) REMOVE_SNAP=true ;;
    --remove-optional-packages) REMOVE_OPTIONAL_PACKAGES=true ;;
    --dry-run) DRY_RUN=true ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run with sudo: sudo $0 [options]" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify operating system." >&2; exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != ubuntu ]]; then
  echo "This script supports Ubuntu only (detected: ${PRETTY_NAME:-unknown})." >&2
  exit 1
fi

log "Ubuntu VM Optimizer v${VERSION} — detected ${PRETTY_NAME:-Ubuntu}"
log "Current state:"
free -h || true
df -h / || true

log "Plan: set multi-user.target, disable Apport and motd-news timer when available, then clean APT."
if ! $DRY_RUN && ! confirm "Apply conservative server optimizations?"; then
  echo "Cancelled."; exit 0
fi

if command -v systemctl >/dev/null 2>&1; then
  run systemctl set-default multi-user.target
  if systemctl list-unit-files apport.service --no-legend 2>/dev/null | grep -q '^apport\.service'; then
    run systemctl disable --now apport.service || warn "Could not disable apport.service; continuing."
  fi
  if systemctl list-unit-files motd-news.timer --no-legend 2>/dev/null | grep -q '^motd-news\.timer'; then
    run systemctl disable --now motd-news.timer || warn "Could not disable motd-news.timer; continuing."
  fi
fi

run apt-get clean
if $DRY_RUN; then
  echo "[DRY-RUN] apt-get -s autoremove --purge"
  apt-get -s autoremove --purge || true
else
  log "Reviewing unused-package removal plan:"
  apt-get -s autoremove --purge || true
  if confirm "Run apt autoremove --purge using the plan above?"; then
    apt-get autoremove --purge
  else
    warn "Skipped autoremove."
  fi
fi

if $REMOVE_OPTIONAL_PACKAGES; then
  optional=(modemmanager packagekit open-iscsi multipath-tools)
  installed=()
  for pkg in "${optional[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed; then
      installed+=("$pkg")
    fi
  done
  if ((${#installed[@]})); then
    warn "Optional packages selected for possible removal: ${installed[*]}"
    warn "Do NOT remove multipath-tools/open-iscsi if your VM depends on multipath or iSCSI storage."
    if $DRY_RUN; then
      printf '[DRY-RUN] apt-get purge'; printf ' %q' "${installed[@]}"; printf '\n'
    elif confirm "Purge these optional packages?"; then
      apt-get purge "${installed[@]}"
      if confirm "Remove unused dependencies after optional package removal?"; then
        apt-get autoremove --purge
      fi
    else
      warn "Skipped optional package removal."
    fi
  else
    log "None of the optional packages are installed."
  fi
fi

if $REMOVE_SNAP; then
  if ! command -v snap >/dev/null 2>&1; then
    log "Snap is not installed; skipping Snap removal."
  else
    log "Installed Snap packages (review before continuing):"
    snap list || true
    warn "Removing Snap will remove ALL installed Snap applications."
    if $DRY_RUN; then
      echo "[DRY-RUN] Would remove installed snaps and purge snapd only after explicit confirmation."
    elif confirm "Remove all installed Snap applications and purge snapd?"; then
      mapfile -t snap_names < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -vE '^(snapd|core[0-9]*|bare)$' || true)
      for name in "${snap_names[@]}"; do
        snap remove "$name" || warn "Could not remove snap: $name"
      done
      mapfile -t remaining_snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)
      for name in "${remaining_snaps[@]}"; do
        snap remove "$name" || warn "Could not remove snap: $name"
      done
      apt-get purge snapd
      if confirm "Run apt autoremove --purge after removing Snap?"; then apt-get autoremove --purge; fi
    else
      warn "Skipped Snap removal."
    fi
  fi
fi

log "Final status:"
if command -v systemctl >/dev/null 2>&1; then
  systemctl get-default || true
  systemctl --failed --no-pager || true
fi
free -h || true
df -h / || true
log "Finished. Review output above; reboot only when convenient to validate startup changes."
