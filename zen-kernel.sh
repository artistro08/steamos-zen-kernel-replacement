#!/usr/bin/env bash
#===============================================================================
# zen-kernel.sh  v1.0
#
# Keeps a custom linux-zen kernel installed on SteamOS across image updates, and
# prompts you to restart into it — working in both Desktop and Game Mode.
#
# SteamOS ships each update as a fresh read-only image, which wipes any custom
# kernel from /boot. This tool re-installs linux-zen on boot when it detects the
# image changed, makes it the default GRUB entry, and shows a restart prompt.
#
# COMMANDS
#   sudo ./zen-kernel.sh install-service    install + enable everything (idempotent)
#   sudo ./zen-kernel.sh reapply            re-install linux-zen now
#   sudo ./zen-kernel.sh enable | disable   turn the boot automation on/off
#   sudo ./zen-kernel.sh status             show current state
#   sudo ./zen-kernel.sh uninstall-service  remove services (keeps this script/state)
#   diagnostics: test-notify, test-toast [type], flag-notify   (see `help`)
#
# HOW IT WORKS
#   * zen-kernel-reapply.service (oneshot, boot): rebuilds linux-zen if the OS
#     build changed, then drops a flag file. It runs before Steam is up, so it
#     never tries to draw UI itself.
#   * zen-kernel-notify.service (daemon): polls that flag and shows the prompt
#     once the UI is ready — a persistent notification with a Restart button in
#     Desktop Mode, or a native Steam toast in Game Mode.
#   Both units are anchored to default.target (so they fire in Game Mode too) and
#   are registered for preservation across atomic updates.
#
# REQUIREMENTS
#   * SteamOS desktop install using GRUB (config at /efi/EFI/steamos/grub.cfg).
#   * linux-zen installable via your configured pacman repos.
#   * Game Mode toasts need Steam CEF debugging enabled once:
#       touch /home/deck/.local/share/Steam/.cef-enable-remote-debugging
#     then restart Steam.
#===============================================================================
set -euo pipefail

########################  USER CONFIG  ########################
# Set to 1 once reinstall_kernel() below matches how you install linux-zen.
CONFIGURED=1

# SteamOS account — always "deck" on a standard SteamOS install.
STEAM_USER="deck"

# Persistent home for this tool (under the account's home; survives image updates).
ZEN_HOME="${ZEN_HOME:-/home/$STEAM_USER/.zen-kernel}"

# Show a restart prompt after a reinstall (0 = stay silent).
NOTIFY=1

# Game Mode toast style = Steam notification type. Type 3 reliably renders a
# custom text message as a Game Mode toast; "neutral" types (31 General,
# 7 SystemUpdate) carry only structured data and render blank with custom text.
# Experiment live with:  sudo ./zen-kernel.sh test-toast <type>
TOAST_TYPE=3

# Wording of the prompts — edit freely.
TOAST_MSG="linux-zen reinstalled after a SteamOS update — restart from the Steam power menu to apply it."
DESKTOP_TITLE="linux-zen reinstalled"
DESKTOP_BODY="A SteamOS update replaced your kernel and linux-zen was reinstalled. Restart to boot into it."
###############################################################

# >>> Put YOUR working linux-zen install commands here. <<<
# steamos-readonly is toggled for you (disabled before, re-enabled after).
reinstall_kernel() {
  pacman-key --init
  pacman-key --populate holo

  # Aux packages may use --needed; libnotify powers the Desktop notification.
  pacman -Sy --needed --noconfirm linux-zen-headers libnotify mkinitcpio

  # linux-zen is installed WITHOUT --needed on purpose: after an image update the
  # pacman DB can still list it as installed while its files were wiped with the
  # old rootfs, so --needed would skip it and nothing would reach /boot. Forcing
  # the install re-extracts the kernel and re-runs its mkinitcpio hooks.
  pacman -S --noconfirm linux-zen

  # GRUB's 10_linux only makes a menu entry for a kernel whose image is in /boot,
  # so place it there ourselves rather than relying on packaging hooks firing.
  local moddir kver
  moddir=$(ls -d /usr/lib/modules/*-zen*/ 2>/dev/null | sort -V | tail -1)
  if [ -z "$moddir" ] || [ ! -e "${moddir}vmlinuz" ]; then
    echo "!! linux-zen image missing under /usr/lib/modules — pacman did not extract it. Aborting." >&2
    return 1
  fi
  kver=$(basename "$moddir")
  install -m644 "${moddir}vmlinuz" /boot/vmlinuz-linux-zen

  # mkinitcpio prints ERRORs for Deck-only modules (steamdeck, *_hwmon, ...) on
  # non-Deck hardware and can exit nonzero, yet still builds a working image — so
  # ignore its exit code and verify the artifacts landed instead.
  if [ -e /etc/mkinitcpio.d/linux-zen.preset ]; then
    mkinitcpio -p linux-zen || true
  else
    mkinitcpio -k "$kver" -g /boot/initramfs-linux-zen.img || true
  fi
  if [ ! -s /boot/vmlinuz-linux-zen ] || [ ! -s /boot/initramfs-linux-zen.img ]; then
    echo "!! zen kernel/initramfs missing from /boot after build. Aborting." >&2
    return 1
  fi

  # GRUB_TIMEOUT=0 shows no menu, so the default must be zen. GRUB_TOP_LEVEL pins
  # it to the first entry (SteamOS's Arch-derived 10_linux honors it).
  if grep -q '^GRUB_TOP_LEVEL=' /etc/default/grub; then
    sed -i 's|^GRUB_TOP_LEVEL=.*|GRUB_TOP_LEVEL=/boot/vmlinuz-linux-zen|' /etc/default/grub
  else
    printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-linux-zen\n' >> /etc/default/grub
  fi

  update-grub
}

#------------------------------------------------------------------ internals --
SELF="$(readlink -f "$0")"
INSTALLED="$ZEN_HOME/zen-kernel.sh"
STATE_DIR="$ZEN_HOME/state"
LOG="$ZEN_HOME/reapply.log"
LOG_MAX_LINES=300
NOTIFY_FLAG="$STATE_DIR/notify-pending"
UNIT="/etc/systemd/system/zen-kernel-reapply.service"
NOTIFY_UNIT="/etc/systemd/system/zen-kernel-notify.service"
OLD_TIMER="/etc/systemd/system/zen-kernel-reapply.timer"   # removed if present (legacy)
ATOMIC_CONF="/etc/atomic-update.conf.d/zen-kernel.conf"
RUN=(); RUN_USER=""
STEAM_UID="$(id -u "$STEAM_USER" 2>/dev/null || echo 1000)"

log() { mkdir -p "$ZEN_HOME"; printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }; }
current_build() { ( . /etc/os-release; echo "${BUILD_ID:-unknown}" ); }
on_zen() { uname -r | grep -qi zen; }
zen_present() { [ -e /boot/vmlinuz-linux-zen ]; }   # "present" = image actually in /boot

# Keep the log from growing without bound.
trim_log() {
  [ -f "$LOG" ] || return 0
  local n; n=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt "$LOG_MAX_LINES" ]; then
    tail -n "$LOG_MAX_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || rm -f "$LOG.tmp"
  fi
}

# --- session discovery ---
# Echoes "<mode> <pid> <uid>" for deck's active graphical session (game|desktop).
# Only deck-owned processes are matched, so a root-owned Xorg can't mislead us.
detect_session() {
  local p proc
  # gamescope renames itself to "gamescope-wl", so match by substring (no -x).
  if p=$(pgrep -u "$STEAM_USER" gamescope 2>/dev/null | head -1) && [ -n "$p" ]; then
    echo "game $p $STEAM_UID"; return 0
  fi
  for proc in plasmashell kwin_wayland kwin_x11 ksmserver; do
    if p=$(pgrep -u "$STEAM_USER" -x "$proc" 2>/dev/null | head -1) && [ -n "$p" ]; then
      echo "desktop $p $STEAM_UID"; return 0
    fi
  done
  return 1
}

# Read one VAR=value from a process's environment (root only).
env_of() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1 || true; }

# Build RUN[] = a "sudo -u deck env ..." prefix from deck's session pid.
build_run() {
  local pid=$1 xrd dbus wl dpy
  RUN_USER="$STEAM_USER"
  xrd=$(env_of "$pid" XDG_RUNTIME_DIR);           : "${xrd:=/run/user/$STEAM_UID}"
  dbus=$(env_of "$pid" DBUS_SESSION_BUS_ADDRESS); : "${dbus:=unix:path=$xrd/bus}"
  wl=$(env_of "$pid" WAYLAND_DISPLAY); dpy=$(env_of "$pid" DISPLAY)
  RUN=(sudo -u "$STEAM_USER" env XDG_RUNTIME_DIR="$xrd" DBUS_SESSION_BUS_ADDRESS="$dbus")
  [ -n "$wl" ]  && RUN+=(WAYLAND_DISPLAY="$wl")
  [ -n "$dpy" ] && RUN+=(DISPLAY="$dpy")
}

# --- Game Mode: native Steam toast via the CEF debug socket ---
# Connects to Steam's SharedJSContext target and calls
# SteamClient.ClientNotifications.DisplayClientNotification(<type>, ...).
# Args: <message> [type]. Nonzero exit = Steam/CEF not reachable (caller retries).
steam_toast() {
  python3 - "$1" "${2:-3}" <<'PY'
import sys, json, socket, base64, os, time, http.client
from urllib.parse import urlparse

HOST, PORT, TITLE = "localhost", 8080, "SharedJSContext"
msg = sys.argv[1] if len(sys.argv) > 1 else "linux-zen reinstalled — restart to apply."
try:
    ntype = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].strip() else 3
except ValueError:
    ntype = 3

def targets():
    c = http.client.HTTPConnection(HOST, PORT, timeout=4)
    c.request("GET", "/json"); data = c.getresponse().read(); c.close()
    return json.loads(data)

def ws_url():
    ts = targets()
    for t in ts:
        if t.get("title") == TITLE and t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    for t in ts:
        if "Steam" in (t.get("title") or "") and t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    raise RuntimeError("no CEF target")

def connect(url):
    p = urlparse(url); path = p.path + (("?" + p.query) if p.query else "")
    s = socket.create_connection((p.hostname, p.port), timeout=4)
    key = base64.b64encode(os.urandom(16)).decode()
    hs = "\r\n".join([f"GET {path} HTTP/1.1", f"Host: {p.hostname}:{p.port}",
        "Upgrade: websocket", "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13", "\r\n"])
    s.send(hs.encode()); resp = b""
    while b"\r\n\r\n" not in resp:
        ch = s.recv(4096)
        if not ch: break
        resp += ch
    if b"101" not in resp.split(b"\r\n")[0]:
        raise RuntimeError("ws upgrade failed")
    return s

def send_text(s, m):
    b = m.encode(); f = bytearray([0x81]); n = len(b); mb = 0x80
    if n <= 125: f.append(n | mb)
    elif n <= 65535: f.append(126 | mb); f += n.to_bytes(2, "big")
    else: f.append(127 | mb); f += n.to_bytes(8, "big")
    mk = os.urandom(4); f += mk
    f += bytes(x ^ mk[i % 4] for i, x in enumerate(b))
    s.send(f)

try:
    url = ws_url()
except ConnectionRefusedError:
    print("cef-refused"); sys.exit(3)
except Exception as e:
    print("cef-unreachable:", e); sys.exit(3)

try:
    s = connect(url)
    payload = json.dumps({"rawbody": msg, "state": "ingame", "steamid": ""})
    js = ("(function(){try{if(window.SteamClient&&SteamClient.ClientNotifications){"
          "SteamClient.ClientNotifications.DisplayClientNotification(" + str(ntype) + ","
          + json.dumps(payload) + ",function(a){});}}catch(e){console.error(e);}})();")
    send_text(s, json.dumps({"id": 1, "method": "Runtime.evaluate",
        "params": {"expression": js, "awaitPromise": False, "returnByValue": True}}))
    time.sleep(0.4); s.close()
    print("ok"); sys.exit(0)
except Exception as e:
    print("send-error:", e); sys.exit(4)
PY
}

# --- Desktop Mode: persistent notification with a Restart button ---
# Non-blocking: the click-waiter runs in the background so the daemon keeps polling.
# Returns 0 if a prompt was launched, 1 if no notifier is available (caller retries).
notify_desktop() {  # $1=pid (deck's session)
  build_run "$1"
  if command -v notify-send >/dev/null 2>&1; then
    ( act=$("${RUN[@]}" notify-send --app-name="linux-zen" --urgency=critical --expire-time=0 \
            --icon=system-reboot --action="reboot=Restart now" --wait \
            "$DESKTOP_TITLE" "$DESKTOP_BODY" 2>/dev/null) || true
      [ -n "$act" ] && systemctl reboot ) & disown 2>/dev/null || true
    return 0
  fi
  if command -v kdialog >/dev/null 2>&1; then    # KDE fallback if libnotify missing
    ( "${RUN[@]}" kdialog --title "$DESKTOP_TITLE" --yesno "$DESKTOP_BODY"$'\n\n'"Restart now?" 2>/dev/null \
        && systemctl reboot ) & disown 2>/dev/null || true
    return 0
  fi
  return 1
}

# Try to show the pending prompt ONCE. 0 = shown, 1 = UI not ready yet (retry).
show_pending_notification() {
  local info mode pid
  info=$(detect_session) || return 1
  read -r mode pid _ <<<"$info"
  if [ "$mode" = game ]; then
    steam_toast "$TOAST_MSG" "$TOAST_TYPE" >/dev/null 2>&1 || return 1
    log "notify: Game Mode toast shown."
    return 0
  fi
  notify_desktop "$pid" || return 1
  log "notify: Desktop prompt shown (${STEAM_USER})."
  return 0
}

# --- notify daemon: bridges "reinstall happened" -> "UI is ready" ---
cmd_notify_daemon() {
  need_root
  mkdir -p "$STATE_DIR"
  trim_log
  log "notify-daemon: started."
  local announced=0 i=0
  while true; do
    if on_zen; then
      # Already booted into zen -> any pending "please restart" is stale.
      if [ -e "$NOTIFY_FLAG" ]; then
        rm -f "$NOTIFY_FLAG"; announced=0
        log "notify-daemon: on zen; cleared stale prompt."
      fi
    elif [ -e "$NOTIFY_FLAG" ]; then
      if [ "$announced" -eq 0 ]; then
        log "notify-daemon: restart prompt pending; waiting for the UI."
        announced=1
      fi
      if show_pending_notification; then rm -f "$NOTIFY_FLAG"; announced=0; fi
    fi
    i=$(( i + 1 )); [ $(( i % 360 )) -eq 0 ] && trim_log   # ~hourly
    sleep 10
  done
}

# --- reinstall flow ---
cmd_reapply() {
  need_root
  mkdir -p "$STATE_DIR"; trim_log
  local auto=0; [ "${1:-}" = "--auto" ] && auto=1
  local build; build="$(current_build)"

  # Normal (non-update) boot: build matches and zen is present -> skip fast.
  if [ "$auto" = 1 ] \
     && [ "$(cat "$STATE_DIR/last-build" 2>/dev/null)" = "$build" ] \
     && zen_present; then
    log "auto: linux-zen already present for build $build — nothing to do."
    return 0
  fi

  if [ "$CONFIGURED" != 1 ]; then
    log "NOT CONFIGURED: edit reinstall_kernel() and set CONFIGURED=1 first."
    [ "$auto" = 1 ] && return 0 || exit 2
  fi

  log "Reinstalling linux-zen for build $build ..."
  steamos-readonly disable || true
  local rc=0
  reinstall_kernel || rc=$?
  steamos-readonly enable || true

  if [ "$rc" -ne 0 ]; then
    log "reinstall_kernel FAILED (rc=$rc). Marker unchanged; will retry next boot."
    return "$rc"
  fi

  echo "$build" > "$STATE_DIR/last-build"
  log "Done: linux-zen installed for build $build."

  # Already on zen? Nothing to prompt; clear any stale flag.
  if on_zen; then rm -f "$NOTIFY_FLAG"; return 0; fi

  # Drop the flag; the notify daemon shows the prompt once the UI is ready.
  if [ "$NOTIFY" = 1 ]; then
    touch "$NOTIFY_FLAG"
    log "notify: flagged restart prompt for build $build."
  fi
}

# --- install / service management ---
_write_units() {
  cat > "$UNIT" <<EOF
[Unit]
Description=Reinstall linux-zen after SteamOS image updates
Wants=network-online.target
After=network-online.target
ConditionPathExists=$INSTALLED

[Service]
Type=oneshot
ExecStart=$INSTALLED reapply --auto
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF

  cat > "$NOTIFY_UNIT" <<EOF
[Unit]
Description=Show the linux-zen restart prompt when the UI is ready

[Service]
Type=simple
ExecStart=$INSTALLED notify-daemon
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

  # Carry both units + their enable symlinks across atomic image updates.
  mkdir -p "$(dirname "$ATOMIC_CONF")"
  cat > "$ATOMIC_CONF" <<EOF
$UNIT
$NOTIFY_UNIT
/etc/systemd/system/default.target.wants/zen-kernel-reapply.service
/etc/systemd/system/default.target.wants/zen-kernel-notify.service
EOF
}

cmd_install_service() {
  need_root
  mkdir -p "$STATE_DIR"

  # Keep a persistent copy the services run from. Safe to run from any location,
  # including the installed copy itself (avoids install's "same file" error).
  if [ "$SELF" != "$INSTALLED" ]; then
    install -Dm755 "$SELF" "$INSTALLED"
  fi

  _write_units
  systemctl daemon-reload
  systemctl disable --now zen-kernel-reapply.timer 2>/dev/null || true   # remove legacy timer
  rm -f "$OLD_TIMER"
  systemctl enable zen-kernel-reapply.service
  systemctl enable zen-kernel-notify.service
  systemctl restart zen-kernel-notify.service     # reload code if it was already running
  log "Installed: reinstall service + notify daemon enabled (default.target)."
  log "Persistent copy: $INSTALLED   |   manual reapply: sudo $INSTALLED reapply"
}

cmd_enable() {
  need_root
  systemctl enable zen-kernel-reapply.service
  systemctl enable --now zen-kernel-notify.service
  log "Automation enabled."
}

cmd_disable() {
  need_root
  systemctl disable zen-kernel-reapply.service
  systemctl disable --now zen-kernel-notify.service
  log "Automation disabled."
}

cmd_status() {
  local reinstall notify
  reinstall=$(systemctl is-enabled zen-kernel-reapply.service 2>/dev/null) || reinstall="not installed"
  notify=$(systemctl is-active zen-kernel-notify.service 2>/dev/null)     || notify="inactive"
  echo "current build:    $(current_build)"
  echo "last done build:  $(cat "$STATE_DIR/last-build" 2>/dev/null || echo none)"
  echo "running kernel:   $(uname -r)"
  echo "on zen:           $(on_zen && echo yes || echo no)"
  echo "zen in /boot:     $(zen_present && echo yes || echo no)"
  echo -n "session:          "; detect_session || echo "none detected"
  echo -n "steam cef :8080:  "; (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null && echo reachable || echo "not reachable"
  echo "reinstall svc:    $reinstall"
  echo "notify daemon:    $notify"
  echo "prompt pending:   $([ -e "$NOTIFY_FLAG" ] && echo yes || echo no)"
  echo -n "ran this boot:    "; journalctl -b -u zen-kernel-reapply.service -q -n1 -o cat 2>/dev/null | grep -q . && echo yes || echo "no (not yet / not triggered)"
}

cmd_uninstall() {
  need_root
  systemctl disable --now zen-kernel-reapply.service 2>/dev/null || true
  systemctl disable --now zen-kernel-notify.service  2>/dev/null || true
  systemctl disable --now zen-kernel-reapply.timer   2>/dev/null || true
  rm -f "$UNIT" "$NOTIFY_UNIT" "$ATOMIC_CONF" "$OLD_TIMER"
  systemctl daemon-reload
  log "Removed services + atomic-update entry ($ZEN_HOME kept — delete manually if desired)."
}

usage() {
  cat <<EOF
zen-kernel.sh — keep linux-zen installed on SteamOS across image updates.

  sudo $0 install-service    install + enable everything (idempotent)
  sudo $0 reapply            re-install linux-zen now
  sudo $0 enable | disable   turn the boot automation on/off
  sudo $0 status             show current state
  sudo $0 uninstall-service  remove services (keeps this script + state)

Diagnostics:
  sudo $0 test-notify        show the restart prompt now, in the current mode
  sudo $0 test-toast [type]  fire a Steam Game Mode toast (optionally try a type)
  sudo $0 flag-notify        set the pending flag; the daemon shows the prompt
EOF
}

case "${1:-help}" in
  install-service)    cmd_install_service ;;
  reapply)            shift; cmd_reapply "${1:-}" ;;
  enable)             cmd_enable ;;
  disable)            cmd_disable ;;
  status)             cmd_status ;;
  uninstall-service)  cmd_uninstall ;;
  notify-daemon)      cmd_notify_daemon ;;                  # internal: run by the notify service
  test-notify)        need_root; show_pending_notification && echo "shown" || echo "UI not ready (daemon would retry)" ;;
  test-toast)         shift; rc=0; steam_toast "linux-zen toast test (type ${1:-$TOAST_TYPE})" "${1:-$TOAST_TYPE}" || rc=$?; echo "(steam_toast exit $rc)" ;;
  flag-notify)        need_root; mkdir -p "$STATE_DIR"; touch "$NOTIFY_FLAG"; echo "flag set: $NOTIFY_FLAG" ;;
  help|-h|--help)     usage ;;
  *)                  echo "Unknown command: $1" >&2; echo >&2; usage; exit 1 ;;
esac
