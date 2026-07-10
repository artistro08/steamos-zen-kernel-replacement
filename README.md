# SteamOS Zen Kernel Replacement

Keeps a custom **linux-zen** kernel installed on SteamOS across image updates, sets it as the default boot entry, and prompts you to restart into it — in both Desktop and Game Mode.

SteamOS ships each update (and branch switch) as a fresh read-only image, which wipes any custom kernel from `/boot`. This tool detects the image change on boot, rebuilds linux-zen, re-pins it in GRUB, and shows a restart prompt.

## Why?

I wanted an automated way to replace the kernel on updates because of some incompatibilities with my current system. More specifically, Sleep doesn't work. This fixes that.

## Requirements

- SteamOS desktop install using **GRUB** (config at `/efi/EFI/steamos/grub.cfg`).
- `linux-zen` available in your pacman repos — it is on a standard SteamOS install (the `extra` repo).
- Account is `deck` (the SteamOS default).
- Game Mode toasts require Steam CEF debugging (one-time, see below).

## Install

On a standard SteamOS install **the tool installs linux-zen for you**.

1. **Save the script** under your home, e.g. `~/zen-kernel.sh`.

2. **Confirm linux-zen is available:**
   ```bash
   pacman -Sl | grep linux-zen
   ```
   Standard SteamOS lists it from `extra`. If you get nothing back, your pacman config doesn't provide it — add a repo that does, set `CONFIGURED=0` at the top of the script, edit `reinstall_kernel()` to match your source, then continue.

3. **Install it** by running the tool once:
   ```bash
   sudo ~/zen-kernel.sh reapply
   ```
   This unlocks the read-only filesystem, initializes the pacman keyring, installs `linux-zen`, copies it into `/boot`, builds the initramfs, and pins it as the default GRUB entry.

4. **Reboot and confirm:**
   ```bash
   uname -r        # should end in -zen
   ```
   If it didn't boot into zen, see [Troubleshooting](#troubleshooting).

5. **Enable the automation** so it survives future image updates:
   ```bash
   sudo ~/zen-kernel.sh install-service
   ```
   This copies the script to `/home/deck/.zen-kernel/`, installs + enables the two systemd units, and registers them to survive updates. It's **idempotent** — safe to re-run anytime.

> If you edit the script later, re-run `install-service` to push the changes live.

## Commands

| Command | Description |
|---|---|
| `install-service` | Install + enable everything (idempotent) |
| `reapply` | Install / re-install linux-zen now |
| `enable` / `disable` | Turn the boot automation on/off |
| `status` | Show build, kernel, session, and service state |
| `uninstall-service` | Remove services (keeps script + state) |

Diagnostics: `test-notify` (show the prompt now), `test-toast [type]` (fire a Game Mode toast), `flag-notify` (set the flag; the daemon shows the prompt). Run with `sudo`.

## Configuration

Edit the `USER CONFIG` block at the top of the script:

| Variable | Purpose |
|---|---|
| `CONFIGURED` | Must be `1` for the tool to run. Set to `0` while you adapt `reinstall_kernel()` to a non-standard setup |
| `NOTIFY` | `1` to show a restart prompt after a reinstall, `0` to stay silent |
| `TOAST_MSG` / `DESKTOP_TITLE` / `DESKTOP_BODY` | Prompt wording |
| `TOAST_TYPE` | Steam notification type for the Game Mode toast (default `3`) |
| `reinstall_kernel()` | The commands that install linux-zen. The default works on standard SteamOS; change it only if linux-zen comes from a different source |

## How it works

- **`zen-kernel-reapply.service`** (oneshot, boot): if the OS build changed, rebuilds linux-zen, copies it into `/boot`, rebuilds the initramfs, pins it via `GRUB_TOP_LEVEL`, then drops a flag file. Runs before Steam is up, so it never touches the UI itself.
- **`zen-kernel-notify.service`** (daemon): polls that flag and shows the prompt once the UI is ready — a persistent notification with a **Restart now** button in Desktop Mode, or a native Steam toast in Game Mode. Clears the flag once shown (or if you've already booted onto zen).

Both units are anchored to `default.target` (so they fire in Game Mode too) and are preserved across atomic updates.

## Game Mode toasts (one-time setup)

The Game Mode toast goes through Steam's CEF debug socket, which is off by default:

```bash
touch /home/deck/.local/share/Steam/.cef-enable-remote-debugging
```

Then restart Steam. `status` shows `steam cef :8080: reachable` when it's on. This lives under `/home`, so it persists across updates. (Desktop notifications need no setup.)

## Files

- Script (installed copy): `/home/deck/.zen-kernel/zen-kernel.sh`
- Log: `/home/deck/.zen-kernel/reapply.log` (auto-trimmed)
- Units: `/etc/systemd/system/zen-kernel-{reapply,notify}.service`

## Troubleshooting

- **Not on zen after reboot** → run `sudo ~/zen-kernel.sh status`; check `zen in /boot: yes` and that the top-level GRUB entry points at `vmlinuz-linux-zen`. For a safety net on the first zen boot, temporarily set `GRUB_TIMEOUT=10` in `/etc/default/grub` and run `sudo update-grub` to get a boot menu.
- **`reapply` fails with "image missing under /usr/lib/modules"** → `pacman -S linux-zen` didn't install (repo missing or keyring issue). Confirm `pacman -Sl | grep linux-zen` returns a result.
- **No Game Mode toast** → confirm `steam cef :8080: reachable`; if not, do the CEF step above and restart Steam.
- **Check what happened** → `tail /home/deck/.zen-kernel/reapply.log` or `journalctl -u zen-kernel-reapply.service`.

## Uninstall

```bash
sudo ~/zen-kernel.sh uninstall-service   # removes services; keeps script + /boot kernel
```
