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

Open an elevated PowerShell in the repo's `windows/` folder:

```powershell
.\Install.ps1
```

This verifies or installs usbipd-win (via winget), copies the app to
`C:\ProgramFiles\USBShare`, creates `C:\ProgramData\USBShare\config.json`,
and registers a scheduled task that keeps your devices shared at boot and
every 5 minutes.

Now find your devices and fill in the config:

```powershell
cd "C:\Program Files\USBShare"
.\usb-share.ps1 list --json
notepad C:\ProgramData\USBShare\config.json
```

Put each device's `VidPid` (e.g. `0bda:2838`) in `devices`, and put the
HAOS VM's IP in `allowedClients` — that is what scopes the firewall rule
for TCP 3240. Then verify and share:

```powershell
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
devices:
  - name: RTL-SDR
    id: 0bda:2838          # same VID:PID as on the Windows side
  - name: Z-Stick
    id: 0658:0200
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
