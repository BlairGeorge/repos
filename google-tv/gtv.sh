#!/usr/bin/env bash
# gtv.sh - find, analyze, back up, debloat and restore a Google TV over wireless ADB.
# Runs anywhere adb runs: Termux on an Android phone, Linux, macOS.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${GTV_STATE:-$HERE/state}"
BACKUPS="$STATE/backups"
REPORTS="$STATE/reports"
JOURNAL="$STATE/journal.log"
PLAN="$STATE/plan.txt"
LIST="$HERE/debloat-list.txt"
ANIM_KEYS="window_animation_scale transition_animation_scale animator_duration_scale"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
now() { date +%Y%m%d-%H%M%S; }

need_adb() {
  command -v adb >/dev/null 2>&1 || die "adb not found. In Termux run: pkg install android-tools"
}

serial() {
  if [ -n "${GTV_SERIAL:-}" ]; then echo "$GTV_SERIAL"
  elif [ -f "$STATE/device" ]; then cat "$STATE/device"
  else die "no TV selected; run: $0 connect"
  fi
}

# Resolve the TV once, in the main shell, so a missing TV stops the script.
need_tv() { need_adb; SERIAL="$(serial)"; }

# Run a shell command on the TV, stripping the CRs older adb versions emit.
tv() { adb -s "$SERIAL" shell "$@" </dev/null | tr -d '\r'; }

pkgs() { tv pm list packages "$@" | sed -n 's/^package://p' | sort; }

confirm() {
  printf '%sType "yes" to continue: ' "${1:+$1 }"
  read -r reply
  [ "$reply" = "yes" ] || die "cancelled, nothing changed"
}

journal() { mkdir -p "$STATE"; echo "$(now) $*" >> "$JOURNAL"; }

list_field() {  # list_field <package> <field#>: look a package up in debloat-list.txt
  awk -F'|' -v p="$1" -v f="$2" '!/^#/ && $2==p {print $f; exit}' "$LIST"
}

latest_backup() {
  [ -f "$BACKUPS/LATEST" ] || die "no backup yet; run: $0 backup"
  echo "$BACKUPS/$(cat "$BACKUPS/LATEST")"
}

# ---------------------------------------------------------------------------

cmd_find() {
  need_adb
  info "Looking for TVs advertising wireless debugging (mDNS)..."
  adb mdns check || true
  local found
  found="$(adb mdns services 2>/dev/null | grep -E '_adb-tls-(connect|pairing)' || true)"
  if [ -z "$found" ]; then
    cat <<EOF
Nothing found over mDNS. That's common on some routers and phones.
Read the address straight off the TV instead:
  TV: Settings > System > Developer options > Wireless debugging
  - "IP address & port"            -> use with: $0 connect <ip:port>
  - "Pair device with pairing code" -> use with: $0 pair <ip:port> <code>
EOF
    return 0
  fi
  echo "$found"
  echo
  echo "_adb-tls-pairing = pairing address (only while the pairing dialog is open)"
  echo "_adb-tls-connect = connect address"
}

cmd_pair() {
  need_adb
  [ $# -ge 1 ] || die "usage: $0 pair <ip:pairing-port> [code]  (from the TV's 'Pair device with pairing code' dialog)"
  adb pair "$@"
}

cmd_connect() {
  need_adb
  local target="${1:-}"
  if [ -z "$target" ]; then
    local hits
    hits="$(adb mdns services 2>/dev/null | awk '/_adb-tls-connect/ {print $NF}' | sort -u || true)"
    [ -n "$hits" ] || die "no TV found via mDNS; pass the address shown on the TV: $0 connect <ip:port>"
    [ "$(echo "$hits" | wc -l)" -eq 1 ] || die "several devices found, pick one: $0 connect <ip:port>
$hits"
    target="$hits"
  fi
  adb connect "$target"
  [ "$(adb -s "$target" get-state 2>/dev/null || true)" = "device" ] \
    || die "could not connect to $target. Pair first ($0 pair ...) and accept the prompt on the TV."
  mkdir -p "$STATE"
  echo "$target" > "$STATE/device"
  SERIAL="$target"
  if grep -q 'android.software.leanback' <<<"$(tv pm list features)"; then
    info "Connected to TV: $(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model) ($target)"
  else
    echo "warning: $target does not report itself as a TV (no leanback feature). Double-check the address." >&2
  fi
}

cmd_analyze() {
  need_tv
  mkdir -p "$REPORTS"
  local out="$REPORTS/analyze-$(now).txt"
  { analyze_body; } 2>&1 | tee "$out"
  echo
  info "Report saved to $out - share it so we can review the plan together."
}

analyze_body() {
  echo "### Device"
  echo "Model:    $(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model)"
  echo "Android:  $(tv getprop ro.build.version.release) (SDK $(tv getprop ro.build.version.sdk))"
  echo "Build:    $(tv getprop ro.build.fingerprint)"
  echo "Uptime:   $(tv uptime)"

  local cores load mem_total mem_avail data_use
  cores="$(tv grep -c ^processor /proc/cpuinfo)"
  load="$(tv cat /proc/loadavg | awk '{print $1}')"
  mem_total="$(tv cat /proc/meminfo | awk '/^MemTotal:/ {print $2}')"
  mem_avail="$(tv cat /proc/meminfo | awk '/^MemAvailable:/ {print $2}')"
  data_use="$(tv df /data | tail -n 1 | awk '{gsub("%","",$5); print $5}')"

  echo
  echo "### Memory"
  tv cat /proc/meminfo | grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):'
  echo
  echo "### Storage (/data)"
  tv df -h /data
  echo
  echo "### CPU: $cores cores, 1-min load $load"
  tv top -b -n 1 -m 15 2>/dev/null || tv top -n 1 -m 15 || true
  echo
  echo "### Biggest memory users"
  tv dumpsys meminfo | awk '
    /^Total (PSS|RSS) by process:/ {f=1; c=0; print; next}
    f && /^[[:space:]]*$/ {if (c>0) f=0; next}
    f {if (c<20) print; c++}'
  echo
  echo "### Thermal"
  tv dumpsys thermalservice 2>/dev/null | awk 'tolower($0) ~ /thermal status|temperature\{/ && n++ < 12' || echo "(not available)"
  echo
  echo "### Animation scales"
  local k; for k in $ANIM_KEYS; do echo "$k = $(tv settings get global "$k")"; done
  echo
  echo "### Packages"
  echo "installed: $(pkgs | wc -l)  disabled: $(pkgs -d | wc -l)  third-party: $(pkgs -3 | wc -l)"
  echo
  echo "Third-party (user-installed) apps:"
  pkgs -3 | sed 's/^/  /'
  echo
  echo "Known packages from debloat-list.txt that are installed and enabled:"
  local enabled; enabled="$(pkgs -e)"
  awk -F'|' '!/^#/ && NF>=4 {print $1"|"$2"|"$3}' "$LIST" | while IFS='|' read -r risk pkg what; do
    if grep -qxF "$pkg" <<<"$enabled"; then printf '  %-7s %-45s %s\n' "$risk" "$pkg" "$what"; fi
  done

  echo
  echo "### Likely causes of slowness"
  local flagged=0
  if [ -n "$mem_total" ] && [ -n "$mem_avail" ] && [ $((mem_avail * 100 / mem_total)) -lt 20 ]; then
    echo "- LOW FREE MEMORY: only $((mem_avail * 100 / mem_total))% available. Background apps are the usual cause; disabling unused ones helps most."
    flagged=1
  fi
  if [[ "$data_use" =~ ^[0-9]+$ ]] && [ "$data_use" -ge 85 ]; then
    echo "- STORAGE NEARLY FULL: /data is ${data_use}% used. Android slows down badly when storage is nearly full; clear app caches or remove apps."
    flagged=1
  fi
  if [ -n "$cores" ] && awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c)}'; then
    echo "- HIGH CPU LOAD: load $load on $cores cores. Check the top CPU list above for a runaway app."
    flagged=1
  fi
  [ "$flagged" -eq 1 ] || echo "- No obvious bottleneck right now. Run this again while the TV feels slow."
}

cmd_backup() {
  need_tv
  local dir="$BACKUPS/$(now)"
  mkdir -p "$dir"
  info "Backing up package states and settings to $dir"
  tv getprop > "$dir/getprop.txt"
  pkgs -u > "$dir/packages-known.txt"      # includes apps uninstalled for the user
  pkgs    > "$dir/packages-installed.txt"
  pkgs -e > "$dir/packages-enabled.txt"
  pkgs -d > "$dir/packages-disabled.txt"
  local ns; for ns in global secure system; do tv settings list "$ns" > "$dir/settings-$ns.txt"; done
  local k; for k in $ANIM_KEYS; do echo "$k=$(tv settings get global "$k")"; done > "$dir/animations.txt"
  basename "$dir" > "$BACKUPS/LATEST"
  journal "backup $(basename "$dir")"
  info "Done: $(wc -l < "$dir/packages-enabled.txt") enabled, $(wc -l < "$dir/packages-disabled.txt") disabled packages recorded."
  echo "Tip: copy the '$STATE' folder somewhere safe (e.g. cloud storage) as well."
}

cmd_plan() {
  need_tv
  [ -f "$BACKUPS/LATEST" ] || cmd_backup
  local enabled; enabled="$(pkgs -e)"
  mkdir -p "$STATE"
  {
    echo "# Debloat plan for $(tv getprop ro.product.model) - review before running '$0 apply'."
    echo "# Lines without a leading '#' will be DISABLED. Add or remove '#' to choose."
    echo "# 'keep' packages are never listed and are refused by apply."
    echo "#"
    local risk
    for risk in low app medium; do
      echo "# ---- $risk ----"
      awk -F'|' -v r="$risk" '!/^#/ && $1==r {print $2"|"$3"|"$4}' "$LIST" | while IFS='|' read -r pkg what breaks; do
        grep -qxF "$pkg" <<<"$enabled" || continue
        local prefix=""; [ "$risk" = "low" ] || prefix="#"
        printf '%s%-45s # %s | breaks: %s\n' "$prefix" "$pkg" "$what" "$breaks"
      done
    done
  } > "$PLAN"
  cat "$PLAN"
  echo
  info "Plan written to $PLAN. Edit it (e.g. nano $PLAN), then run: $0 apply"
}

cmd_apply() {
  need_tv
  local backup; backup="$(latest_backup)"
  [ -f "$PLAN" ] || die "no plan yet; run: $0 plan"
  local selected; selected="$(grep -v '^[[:space:]]*#' "$PLAN" | awk 'NF {print $1}')"
  [ -n "$selected" ] || die "the plan has nothing selected"

  local p bad=""
  for p in $selected; do
    if [ "$(list_field "$p" 1)" = "keep" ]; then bad="$bad $p"; fi
  done
  [ -z "$bad" ] || die "refusing to disable core packages:$bad"

  echo "These packages will be DISABLED (reversible with '$0 restore' or '$0 enable <pkg>'):"
  for p in $selected; do
    printf '  %-45s %s\n' "$p" "$(list_field "$p" 3)"
    if [ -z "$(list_field "$p" 1)" ]; then echo "    ^ not in debloat-list.txt - make sure you know what this is"; fi
  done
  echo "Backup that restore will use: $(basename "$backup")"
  confirm ""

  local ok=0 fail=0
  for p in $selected; do
    if grep -q 'disabled-user' <<<"$(tv pm disable-user --user 0 "$p" 2>&1)"; then
      journal "disable $p"; echo "  disabled $p"; ok=$((ok + 1))
    else
      echo "  FAILED   $p (left unchanged)"; fail=$((fail + 1))
    fi
  done
  info "Disabled $ok, failed $fail. Reboot the TV ($0 reboot), then check that home, remote, and your apps work."
}

cmd_animations() {
  need_tv
  local v="${1:-}"
  case "$v" in 0|0.5|1|1.0) ;; *) die "usage: $0 animations <0|0.5|1>  (0.5 = snappier, 1 = default)";; esac
  latest_backup >/dev/null
  confirm "Set all animation scales to $v?"
  local k; for k in $ANIM_KEYS; do
    journal "setting global $k from $(tv settings get global "$k") to $v"
    tv settings put global "$k" "$v"
  done
  info "Animation scales set to $v."
}

cmd_enable() {
  need_tv
  [ $# -ge 1 ] || die "usage: $0 enable <package>..."
  local p; for p in "$@"; do
    if tv pm enable --user 0 "$p"; then journal "enable $p"; fi
  done
}

cmd_restore() {
  need_tv
  local backup="${1:-}"
  if [ -n "$backup" ]; then backup="$BACKUPS/$backup"; else backup="$(latest_backup)"; fi
  [ -d "$backup" ] || die "backup not found: $backup (see: ls $BACKUPS)"

  local model_then model_now
  model_then="$(awk -F'[][]' '/\[ro.product.model\]/ {print $4}' "$backup/getprop.txt")"
  model_now="$(tv getprop ro.product.model)"
  [ "$model_then" = "$model_now" ] || echo "warning: backup was taken on '$model_then', connected TV is '$model_now'" >&2

  local installed_now enabled_now disabled_now
  installed_now="$(pkgs)"; enabled_now="$(pkgs -e)"; disabled_now="$(pkgs -d)"

  local actions="" p
  while read -r p; do
    [ -n "$p" ] || continue
    if ! grep -qxF "$p" <<<"$installed_now"; then actions="$actions
reinstall $p"
    elif grep -qxF "$p" <<<"$disabled_now"; then actions="$actions
enable $p"
    fi
  done < "$backup/packages-enabled.txt"
  while read -r p; do
    [ -n "$p" ] || continue
    if grep -qxF "$p" <<<"$enabled_now"; then actions="$actions
disable $p"; fi
  done < "$backup/packages-disabled.txt"
  local line k v
  while IFS='=' read -r k v; do
    if [ "$(tv settings get global "$k")" != "$v" ]; then actions="$actions
setting $k $v"; fi
  done < "$backup/animations.txt"
  actions="$(echo "$actions" | sed '/^$/d')"

  if [ -z "$actions" ]; then info "TV already matches backup $(basename "$backup"). Nothing to do."; return 0; fi
  echo "Restoring to backup $(basename "$backup"):"
  echo "$actions" | sed 's/^/  /'
  if [ "${GTV_DRY_RUN:-0}" = "1" ]; then info "dry run, nothing changed"; return 0; fi
  confirm ""

  echo "$actions" | while read -r line; do
    set -- $line
    case "$1" in
      reinstall) tv cmd package install-existing --user 0 "$2" ;;
      enable)    tv pm enable --user 0 "$2" ;;
      disable)   tv pm disable-user --user 0 "$2" ;;
      setting)   if [ "$3" = "null" ]; then tv settings delete global "$2"; else tv settings put global "$2" "$3"; fi ;;
    esac
    journal "restore $line"
  done
  info "Restore complete. Reboot the TV to be safe: $0 reboot"
}

cmd_status() {
  echo "TV:      $(cat "$STATE/device" 2>/dev/null || echo 'not selected')"
  echo "Backups: $(ls "$BACKUPS" 2>/dev/null | grep -v LATEST | tr '\n' ' ')"
  echo "Latest:  $(cat "$BACKUPS/LATEST" 2>/dev/null || echo none)"
  echo "Recent changes:"
  tail -n 20 "$JOURNAL" 2>/dev/null | sed 's/^/  /' || echo "  none"
}

cmd_reboot() { need_tv; adb -s "$SERIAL" reboot; }

usage() {
  cat <<EOF
Usage: $0 <command>

  find                     look for TVs with wireless debugging on this Wi-Fi
  pair <ip:port> [code]    pair using the TV's "Pair device with pairing code" dialog
  connect [ip:port]        connect to the TV (auto-detects if only one is found)
  analyze                  diagnose slowness; saves a report to share
  backup                   save package states + settings (done automatically before plan)
  plan                     write a reviewable debloat plan to $PLAN
  apply                    disable what the plan selects (asks for confirmation)
  animations <0|0.5|1>     set animation speed (backed up, restorable)
  enable <pkg>...          re-enable specific packages
  restore [backup-name]    put packages + animation settings back as in a backup
  status                   show selected TV, backups and recent changes
  reboot                   reboot the TV

Set GTV_DRY_RUN=1 with restore to preview without changing anything.
EOF
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  find|pair|connect|analyze|backup|plan|apply|animations|enable|restore|status|reboot) "cmd_$cmd" "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
