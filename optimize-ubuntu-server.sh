#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
VERSION="0.0.2"
DRY_RUN=false
ASSUME_YES=false
DO_LVM=false
DO_OPTIONAL=true
DO_SNAP=true
DO_UPGRADE=true
DO_DNS=true
DNS_ONLY=false
INCLUDE_PHASED=false
LOG_FILE="/var/log/ubuntu-server-optimizer.log"
RESOLVED_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_RESTART_CMD="systemctl restart systemd-resolved"
RESOLVED_ACTIVE_CMD="systemctl is-active --quiet systemd-resolved"
DNS_VERIFY_CMD="dns_default_verify"
DNS_GLOBAL_CMD="dns_default_global"
if [[ "${UVO_TEST:-0}" == 1 && "${BASH_SOURCE[0]}" != "$0" ]]; then
  RESOLVED_DIR="${UVO_RESOLVED_DIR:-$RESOLVED_DIR}"
  RESOLVED_RESTART_CMD="${UVO_RESOLVED_RESTART_CMD:-$RESOLVED_RESTART_CMD}"
  RESOLVED_ACTIVE_CMD="${UVO_RESOLVED_ACTIVE_CMD:-$RESOLVED_ACTIVE_CMD}"
  DNS_VERIFY_CMD="${UVO_DNS_VERIFY_CMD:-$DNS_VERIFY_CMD}"
  DNS_GLOBAL_CMD="${UVO_DNS_GLOBAL_CMD:-$DNS_GLOBAL_CMD}"
fi
DNS_CONF='[Resolve]
DNS=94.140.14.14#dns.adguard-dns.com 94.140.15.15#dns.adguard-dns.com 1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
FallbackDNS=8.8.8.8#dns.google 8.8.4.4#dns.google
DNSOverTLS=opportunistic
'

usage() {
cat <<'EOF'
Ubuntu Server Optimizer
Usage: sudo ./optimize-ubuntu-server.sh [options]
  --dry-run       Print planned commands/package plan without changing system
  -y, --yes       Skip conservative confirmations only; optional removals still require approval
  --no-snap       Do not offer Snap removal
  --no-upgrade    Do not offer package upgrades
  --include-phased Include phased updates in apt upgrade (explicit opt-in)
  --no-optional   Do not offer optional package removal
  --expand-lvm    Offer root LVM expansion if the VG already has free space
  --no-lvm        Do not offer LVM expansion
  --no-dns        Do not set DNS resolvers
  --dns-only      Run only the DNS step (AdGuard, Cloudflare, Google fallback)
  -h, --help      Show help

Default interactive run:
- Check Ubuntu/systemd and show current status
- Set multi-user.target, disable Apport and motd-news.timer if present
- Clean APT cache; simulate autoremove and ask before applying
- Offer removal of Snap/all Snap apps and optional packages
- Set DNS via systemd-resolved drop-in: AdGuard, Cloudflare, Google fallback; per-link DNS untouched
- Report memory, disk, failed services, enabled services, boot time and slow units
LVM expansion is OFF by default. It only uses existing free VG space; it does not
resize the virtual disk, partition or physical volume. Does not install Docker.
EOF
}
log(){ printf '\n[INFO] %s\n' "$*" | tee -a "$LOG_FILE"; }
warn(){ printf '\n[WARN] %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
die(){ warn "$*"; exit 1; }
run(){
  if $DRY_RUN; then printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'; else "$@" 2>&1 | tee -a "$LOG_FILE"; fi
}
confirm(){
  local prompt="$1" answer
  if $DRY_RUN; then printf '[DRY-RUN] Would ask: %s\n' "$prompt"; return 1; fi
  if $ASSUME_YES; then return 0; fi
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}
confirm_optional(){
  local prompt="$1" answer
  if $DRY_RUN; then printf '[DRY-RUN] Would ask explicit approval: %s\n' "$prompt"; return 1; fi
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}
dns_run(){ local -a cmd; IFS=' ' read -ra cmd <<<"$1"; "${cmd[@]}"; }
dns_default_verify(){ timeout 10 resolvectl query --cache=no example.com; }
dns_global_ok(){ awk '$1=="Global:"{for(i=2;i<=NF;i++){split($i,a,"#"); if(a[1]=="94.140.14.14")f=1}} END{exit !f}'; }
dns_default_global(){ resolvectl dns | dns_global_ok; }
dns_remove_legacy(){
  local legacy="$RESOLVED_DIR/dns.conf"
  [[ -f "$legacy" && "$(<"$legacy")" == "${DNS_CONF%$'\n'}" ]] || return 0
  if $DRY_RUN; then printf '[DRY-RUN] Would remove legacy %s\n' "$legacy"; return 0; fi
  rm -f "$legacy" || { warn "Could not remove legacy $legacy"; return 1; }
}
dns_step(){
  local conf="$RESOLVED_DIR/90-uvo-dns.conf" backup="$RESOLVED_DIR/90-uvo-dns.conf.bak" tmp="$RESOLVED_DIR/90-uvo-dns.conf.new"
  if ! dns_run "$RESOLVED_ACTIVE_CMD" >/dev/null 2>&1; then log "systemd-resolved is not active; skipping DNS step."; return 0; fi
  if [[ -f "$conf" && "$(<"$conf")" == "${DNS_CONF%$'\n'}" ]]; then log "DNS drop-in already up to date."; dns_remove_legacy; return; fi
  if $DRY_RUN; then printf '[DRY-RUN] Would write %s and restart systemd-resolved\n' "$conf"; return 0; fi
  mkdir -p "$RESOLVED_DIR" || { warn "Could not create $RESOLVED_DIR"; return 1; }
  local had_old=false
  if [[ -f "$conf" ]]; then cp -p "$conf" "$backup" || { warn "Could not back up $conf"; return 1; }; had_old=true; log "Backed up existing DNS drop-in to $backup"; fi
  if ! { printf '%s' "$DNS_CONF" >"$tmp" && chmod 644 "$tmp" && mv "$tmp" "$conf"; }; then
    rm -f "$tmp"; warn "Could not write $conf; existing DNS configuration left as is."; return 1
  fi
  dns_run "$RESOLVED_RESTART_CMD" >>"$LOG_FILE" 2>&1 || warn "systemd-resolved restart reported an error."
  if dns_run "$DNS_VERIFY_CMD" >>"$LOG_FILE" 2>&1 && dns_run "$DNS_GLOBAL_CMD" >>"$LOG_FILE" 2>&1; then log "DNS resolvers set and lookup verified."; dns_remove_legacy; return; fi
  local restored=true
  if $had_old; then mv "$backup" "$conf" || restored=false; else rm -f "$conf" || restored=false; fi
  dns_run "$RESOLVED_RESTART_CMD" >>"$LOG_FILE" 2>&1 || warn "systemd-resolved restart failed after rollback; check the service."
  if $restored; then warn "DNS lookup failed after change; previous DNS configuration restored."; else warn "DNS lookup failed after change; restore failed: $conf"; fi
  return 1
}
if [[ "${UVO_LIB:-0}" == 1 && "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    -y|--yes) ASSUME_YES=true ;;
    --no-snap) DO_SNAP=false ;;
    --no-upgrade) DO_UPGRADE=false ;;
    --include-phased) INCLUDE_PHASED=true ;;
    --no-optional) DO_OPTIONAL=false ;;
    --expand-lvm) DO_LVM=true ;;
    --no-lvm) DO_LVM=false ;;
    --no-dns) DO_DNS=false ;;
    --dns-only) DNS_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if $DNS_ONLY && ! $DO_DNS; then echo "--dns-only cannot be combined with --no-dns" >&2; exit 2; fi
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run with sudo: sudo $0 [options]"
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Ubuntu only. Detected: ${PRETTY_NAME:-unknown}"
command -v systemctl >/dev/null 2>&1 || die "systemd is required."
command -v apt-get >/dev/null 2>&1 || die "APT is required."
mkdir -p /var/log; touch "$LOG_FILE"; chmod 600 "$LOG_FILE" || true

log "Ubuntu Server Optimizer v${VERSION} — ${PRETTY_NAME:-Ubuntu}"
log "Log file: $LOG_FILE"
if $DNS_ONLY; then
  if ! $DRY_RUN && ! confirm "Set DNS resolvers via systemd-resolved?"; then log "Cancelled."; exit 0; fi
  dns_step || die "DNS step failed."
  exit 0
fi
log "No Docker install or VM CPU/RAM changes will be performed."
log "Create a VM snapshot/backup before changing a production server."
hostnamectl 2>/dev/null | tee -a "$LOG_FILE" || true
printf '\n--- memory ---\n' | tee -a "$LOG_FILE"; free -h 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- root filesystem ---\n' | tee -a "$LOG_FILE"; df -h / 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- root source ---\n' | tee -a "$LOG_FILE"; findmnt -no SOURCE,FSTYPE / 2>&1 | tee -a "$LOG_FILE" || true
if ! $DRY_RUN && ! confirm "Apply conservative headless-server optimizations?"; then log "Cancelled."; exit 0; fi

log "1/8: Set default target to multi-user.target."
run systemctl set-default multi-user.target
log "2/8: Disable Apport and motd-news.timer when present."
if systemctl list-unit-files --no-legend apport.service 2>/dev/null | awk '{print $1}' | grep -qx apport.service; then
  run systemctl disable --now apport.service || warn "Could not disable Apport."
fi
if systemctl list-unit-files --no-legend motd-news.timer 2>/dev/null | awk '{print $1}' | grep -qx motd-news.timer; then
  run systemctl disable --now motd-news.timer || warn "Could not disable motd-news timer."
fi

log "3/8: APT update/upgrade, cache cleanup, and autoremove review."
if $DO_UPGRADE; then
  log "Refreshing APT package indexes."
  run apt-get update
  log "Reviewing available upgrades."
  if $DRY_RUN; then
    run apt-get -s upgrade
  else
    apt-get -s upgrade 2>&1 | tee -a "$LOG_FILE" || true
    if $INCLUDE_PHASED; then
      warn "Including phased updates overrides Ubuntu's staged rollout policy."
      if confirm_optional "Run apt upgrade including phased updates?"; then
        run apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade
      else
        log "Skipped phased-inclusive upgrade."
      fi
    elif confirm_optional "Install currently offered upgrades with apt-get upgrade? Phased updates remain phased."; then
      run apt-get upgrade
    else
      log "Skipped package upgrades."
    fi
  fi
else
  log "Package upgrades disabled by --no-upgrade."
fi
run apt-get clean
if $DRY_RUN; then
  echo '[DRY-RUN] apt-get -s autoremove --purge'
  apt-get -s autoremove --purge 2>&1 || true
else
  apt-get -s autoremove --purge 2>&1 | tee -a "$LOG_FILE" || true
  if confirm_optional "Run apt autoremove --purge using the plan above?"; then run apt-get autoremove --purge; else log "Skipped autoremove."; fi
fi

log "4/8: Optional packages."
if $DO_OPTIONAL; then
  optional=(modemmanager packagekit open-iscsi multipath-tools)
  installed=()
  for pkg in "${optional[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed; then installed+=("$pkg"); fi
  done
  if ((${#installed[@]})); then
    printf 'Installed optional packages: %s\n' "${installed[*]}" | tee -a "$LOG_FILE"
    warn "Do not remove modemmanager with cellular hardware, open-iscsi with iSCSI, or multipath-tools with multipath storage."
    if confirm_optional "Purge all listed optional packages (${installed[*]})?"; then
      run apt-get purge "${installed[@]}"
      if confirm_optional "Run apt autoremove --purge after optional package removal?"; then run apt-get autoremove --purge; fi
    else log "Skipped optional package removal."; fi
  else log "No listed optional packages installed."; fi
else log "Optional package removal disabled by flag."; fi

log "5/8: Optional Snap removal."
if $DO_SNAP; then
  if command -v snap >/dev/null 2>&1 && dpkg-query -W -f='${db:Status-Status}' snapd 2>/dev/null | grep -qx installed; then
    snap list 2>&1 | tee -a "$LOG_FILE" || true
    warn "This removes ALL Snap applications; required Snap apps/services will stop working."
    if confirm_optional "Remove all Snap apps and purge snapd?"; then
      mapfile -t snap_names < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -v '^snapd$' || true)
      for name in "${snap_names[@]}"; do run snap remove "$name" || warn "Could not remove snap $name; continuing."; done
      run apt-get purge snapd
      if confirm_optional "Run apt autoremove --purge after Snap removal?"; then run apt-get autoremove --purge; fi
    else log "Skipped Snap removal."; fi
  else log "Snap is not installed."; fi
else log "Snap removal disabled by flag."; fi

log "6/8: Optional root LVM expansion."
if $DO_LVM; then
  if command -v lvs >/dev/null 2>&1 && command -v vgs >/dev/null 2>&1 && command -v lvextend >/dev/null 2>&1; then
    root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
    root_type="$(findmnt -nro FSTYPE / 2>/dev/null || true)"
    root_lv=""
    if [[ "$root_source" == /dev/mapper/* || "$root_source" == /dev/*/* ]]; then
      while read -r lv; do
        [[ -n "$lv" ]] || continue
        if [[ "$(readlink -f "$lv")" == "$(readlink -f "$root_source")" ]]; then root_lv="$lv"; break; fi
      done < <(lvs --noheadings -o lv_path 2>/dev/null | xargs -n1)
    fi
    if [[ -n "$root_lv" ]]; then
      root_vg="$(lvs --noheadings -o vg_name "$root_lv" 2>/dev/null | xargs || true)"
      vg_free="$(vgs --noheadings --units b --nosuffix -o vg_free "$root_vg" 2>/dev/null | awk '{printf "%.0f",$1}' || echo 0)"
      if [[ "${vg_free:-0}" =~ ^[0-9]+$ ]] && (( vg_free > 1048576 )); then
        log "Root LV: $root_lv; free VG space: ${vg_free} bytes; filesystem: ${root_type:-unknown}"
        warn "This uses only free space already in the VG; it does not enlarge the VM disk or partition."
        if confirm_optional "Extend root LV and filesystem using all free VG space?"; then run lvextend -l +100%FREE -r "$root_lv"; else log "Skipped LVM expansion."; fi
      else log "No meaningful free space in the root VG; skipping."; fi
    else log "Root is not safely identifiable as an LVM LV; skipping."; fi
  else log "LVM tools not installed; skipping."; fi
else log "LVM expansion disabled. Use --expand-lvm to offer it."; fi

log "7/8: DNS resolvers."
if $DO_DNS; then dns_step || die "DNS step failed."; else log "DNS step disabled by --no-dns."; fi

log "8/8: Final diagnostics."
printf '\n--- default target ---\n' | tee -a "$LOG_FILE"; systemctl get-default 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- failed units ---\n' | tee -a "$LOG_FILE"; systemctl --failed --no-pager 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- memory ---\n' | tee -a "$LOG_FILE"; free -h 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- root filesystem ---\n' | tee -a "$LOG_FILE"; df -h / 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- enabled services ---\n' | tee -a "$LOG_FILE"; systemctl list-unit-files --type=service --state=enabled --no-pager 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- boot time ---\n' | tee -a "$LOG_FILE"; systemd-analyze time 2>&1 | tee -a "$LOG_FILE" || true
printf '\n--- slow startup units (top 20) ---\n' | tee -a "$LOG_FILE"; systemd-analyze blame 2>&1 | head -n 20 | tee -a "$LOG_FILE" || true
log "Finished. Review $LOG_FILE. Verify changes after reboot during a maintenance window."
log "Cloud-init, SSH, Tailscale, UFW and core networking were not disabled. Docker was not installed."
