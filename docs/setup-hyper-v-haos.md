# Setup guide: Windows 11 Hyper-V host → HAOS VM

This guide wires up the whole chain for your scenario: a Windows 11 mini
PC running Hyper-V, HAOS as a VM, and a Realtek SDR (plus other USB
devices) plugged into the host.

## 0. Requirements

- Windows 11 host with Hyper-V, administrator access.
- HAOS VM with a current Home Assistant OS (the client needs the
  `vhci-hcd` kernel module, which current HAOS includes).
- The VM must be able to reach the host over TCP (Default Switch is fine).

## 1. Windows host — install and share devices

Double-click **Setup.cmd** in the extracted (or cloned) repo folder and
approve the UAC prompt. That is the whole install: Setup.cmd is a batch
file, so the execution policy never blocks it. It self-elevates, clears
the "downloaded from the internet" marker that ZIP extracts carry, runs
the full installation (usbipd-win via winget, app copy to
`C:\Program Files\USBShare`, auto-share task, firewall, Start Menu
shortcut) and then opens the GUI. The downloaded folder can be deleted
afterwards.

Prefer a terminal? `powershell -ExecutionPolicy Bypass -File
windows\Install.ps1` from an elevated console does the same (the Bypass
flag sidesteps the execution policy that blocks ZIP-extracted scripts).

If usbipd-win isn't installed yet, the GUI shows an **Install usbipd-win**
button — click it once and the winget installer runs in a console window.

Then:

1. Tick the checkbox next to each device you want to share (e.g. the
   RTL-SDR). Checked = shared; unchecking stops sharing it.
2. Under **Allowed client IP(s)**, enter the HAOS VM's IP — that is what
   scopes the firewall rule for TCP 3240.
3. Click **Save & Apply**. The GUI writes
   `C:\ProgramData\USBShare\config.json`, binds newly selected devices,
   unbinds deselected ones, and refreshes the scoped firewall rule. The
   activity log at the bottom confirms each step.
4. Optionally click **Register auto-share task** (or run `Install.ps1`
   once) so devices re-share automatically at boot and every 5 minutes,
   even with the GUI closed.
5. Optionally tick **Start with Windows** so the GUI itself launches at
   each logon (elevated via a logon task, so there is no UAC prompt).
   Note the distinction: device sharing already survives reboots via the
   auto-share task; this checkbox only controls whether the window opens
   for you automatically.

For a headless or scripted setup, `Install.ps1` performs the full
installation (usbipd-win via winget, app copy to
`C:\Program Files\USBShare`, config starter, scheduled task, firewall,
Start Menu shortcut), and `usb-share.ps1` exposes the same operations as
commands:

```powershell
cd "C:\Program Files\USBShare"
.\usb-share.ps1 list --json       # find VID:PID values
.\usb-share.ps1 doctor
.\usb-share.ps1 sync
```

`doctor` should end with "All checks passed." and `sync` should report
each device as bound. If a device is unplugged into another port later,
the scheduled task re-resolves it by VID:PID automatically.

## 2. Hyper-V networking

With the Default Switch, the guest can reach the host at the switch's
host-side IP:

```powershell
Get-NetIPAddress -InterfaceAlias "vEthernet (Default Switch)" |
    Select-Object -ExpandProperty IPAddress
```

Use that IP as the add-on's `server` and (or) the VM's address on that
subnet in `allowedClients`. Two caveats:

- The Default Switch IP can change after reboots. If you want a stable
  setup, create an external or internal switch with a static host IP, or
  use Tailscale/WireGuard addresses (next section) which never change.
- The scoped firewall rule only admits the IPs in `allowedClients`. If
  you change the VM's IP, update the config and run
  `.\usb-share.ps1 firewall`.

## 3. Internet (or Wi-Fi) use — tunnel first

USB/IP is unauthenticated and unencrypted, so never expose TCP 3240
beyond your LAN. The cleanest path:

1. Install the official **Tailscale add-on** in HAOS (or the WireGuard
   add-on if you run your own VPN) and sign it into your tailnet.
2. Install the **Tailscale client** on Windows and sign into the same
   tailnet.
3. In `C:\ProgramData\USBShare\config.json`, set `allowedClients` to the
   **HAOS Tailscale IP**, and run `.\usb-share.ps1 firewall`.
4. In the add-on options, set `server` to the **Windows Tailscale IP**.

Now the USB/IP session is end-to-end encrypted and both endpoints have
stable addresses, even across sites. The same works with plain WireGuard.

## 4. HAOS — install the add-on

The repo root is already an add-on repository manifest. Push it to GitHub:

1. Push this repo to a GitHub repository of yours. (Update `repository.yaml`
   and the docs links to point at your repo URL.)
2. In Home Assistant: Settings → Add-ons → Add-on Store → ⋮ menu →
   Repositories → paste your repo URL.
3. Install **USB Share Bridge**.

No GitHub? Copy the repo to the HAOS `/addons` folder via the SSH or Samba
add-on; the add-on then appears in the store under local repositories.

Configure the add-on options:

```yaml
server: 192.168.x.x        # Windows host IP (or Tailscale IP); "IP:3240" also works
attach_mode: all           # default - attach everything shared on the Windows side
```

That is the entire HAOS-side configuration. With the default
`attach_mode: all`, the add-on attaches **every device the Windows GUI
has ticked** — the checkboxes are the single source of truth, so nothing
else is typed here. Devices appear under friendly usb.ids names in the
logs (e.g. "Realtek Semiconductor Corp. RTL2838 DVB-T" instead of raw
usbipd strings), and unchecking a device on Windows stops sharing it, so
it drops off here too.

Only if this server feeds several HAOS instances (or you want this VM to
ignore some shared devices) switch to `attach_mode: select` and list
devices manually:

```yaml
attach_mode: select
devices:
  - name: RTL-SDR
    id: 0bda:2838          # VID:PID (preferred) or server bus id like 1-1
```

Start the add-on. On boot it verifies the `vhci-hcd` kernel module,
validates the config, probes the server, discovers shared devices, and
attaches them. Every poll cycle it re-checks attachments and reattaches
anything lost (a replug on the server is handled by re-resolving the
bus ID). On shutdown it detaches cleanly so the server never holds a
stale attachment.

## 5. Acceptance checklist

Run through this once on target hardware:

1. Add-on log shows `Attached 'RTL-SDR' (busid X-X)`.
2. Home Assistant: Settings → System → Hardware → the device appears.
3. SSH add-on / HAOS console: `lsusb` shows the Realtek device.
4. rtl_433 (or your SDR integration) decodes without errors for a few
   minutes over a wired LAN hop.
5. Unplug the SDR on the Windows side, plug it back in: within a couple
   of poll intervals the add-on re-resolves and reattaches it.
6. Reboot both machines: everything comes back without manual steps
   (scheduled task on Windows, `boot: auto` on the add-on).

## 6. RTL-SDR performance notes

The SDR streams isochronous IQ data (~1.5–3 MB/s at 2.4 MSPS). Over wired
gigabit LAN this is comfortable; over Wi-Fi or a long Internet path you
may see dropped samples (rtl_433 "lost samples" warnings). If that happens:

- Prefer the Tailscale/WireGuard direct path (it often avoids relays) or
  wired links on both ends.
- Lower the sample rate if your use case tolerates it.
- If the SDR is all you need over a lossy link, consider running
  `rtl_tcp` on Windows and pointing a network-capable SDR consumer at
  it instead — less faithful, but immune to USB-level jitter. For general
  USB devices, USB/IP remains the right tool.

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Add-on: server not reachable | Windows Firewall blocking 3240 (run `.\usb-share.ps1 firewall`), wrong `server` IP, or usbipd service stopped (`Get-Service usbipd`) |
| Add-on: device not visible on server | Device not bound on Windows — run `.\usb-share.ps1 sync`; check `.\usb-share.ps1 list` |
| Attach fails, "already attached" elsewhere | A stale client attachment; stop the add-on (its `finish` detaches), then start it again |
| Add-on: vhci-hcd not available | Update HAOS to a current version; the manifest `kernel_modules` loads it at start |
| Bind fails on Windows | PowerShell not elevated; run as Administrator |
| Device disappears after replug | Normal within one poll + rediscovery cycle; the add-on re-resolves bus IDs automatically |
| SDR lost samples | See section 6; use wired LAN / direct tunnel path |
| Wrong device matched by VID:PID | Two identical devices share a VID:PID — in that case use the server bus ID (`1-3`) in the add-on device id instead |
