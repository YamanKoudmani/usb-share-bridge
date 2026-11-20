# Research: USB passthrough to a HAOS VM on Hyper-V

## The problem

Hyper-V does not support consumer USB passthrough. Discrete Device
Assignment (DDA) is the only native device-assignment mechanism and it is a
Windows Server feature that binds a whole PCIe device to a VM; it does not
work for ordinary USB controllers on Windows 11 desktops. Enhanced Session
Mode / RDP device redirection requires an active interactive RDP session,
which an appliance VM like Home Assistant OS cannot maintain. That leaves
network-based USB forwarding as the practical route.

## The standard: USB/IP

USB/IP is a Linux kernel feature (drivers `usbip-host` / `vhci-hcd`) that
tunnels raw USB request blocks over TCP. The receiving machine enumerates the
remote device through a virtual host controller, so the OS sees a genuine USB
device with the original VID/PID, endpoints, and transfer types — including
the isochronous endpoints an RTL-SDR uses to stream samples. This is what
makes it suitable for SDRs: applications such as `rtl_433`, `rtl_sdr`, and
Home Assistant USB integrations work unmodified against the attached device.

Any credible solution for this task either implements this protocol or
replaces it with per-application streaming. Notably, "make the guest see a
real USB device" fundamentally requires kernel-mode drivers on both ends
(a Windows USB device host driver, a Linux virtual host controller). Writing
and signing those from scratch is a multi-month kernel project; every
commercial product in this space builds on kernel infrastructure rather
than reinventing it.

## Existing implementations

| Product | Server OS | Client OS | Model | Notes |
|---|---|---|---|---|
| [usbipd-win](https://github.com/dorssel/usbipd-win) | Windows | Any USB/IP client (Linux, WSL…) | Open source (GPL), signed drivers via the Windows Hardware Developer Center | Implements the standard USB/IP server on Windows. The only actively maintained Windows option with properly signed drivers. Older forks such as `usbip-win` lack signed drivers and are risky on Windows 11. |
| [VirtualHere](https://www.virtualhere.com/) | Windows, Linux, macOS | Windows, Linux, macOS | Closed source, commercial/licensed client | Polished product with compression and its own protocol. Good benchmark for UX; licensing and closed source are the tradeoffs. |
| [USB Network Gate (Electronic Team)](https://www.electronic.us/products/usb-network-gate/) | Windows, Linux, macOS | Windows, Linux, macOS | Closed source, roughly USD 160 per shared device (as of Nov 2026) | Feature-rich; per-device pricing. |
| [Linux USB/IP tools](https://github.com/torvalds/linux/tree/master/tools/usb/usbip) | Linux | Linux | Open source, in-kernel | The reference protocol implementation. |
| [hassio-usbip-mounter](https://github.com/irakhlin/hassio-usbip-mounter) / [ha-usbip-client](https://github.com/cryptedx/ha-usbip-client) | n/a (client only) | HAOS add-on | Open source | Proves the HAOS client path: add-ons may load `vhci-hcd` via `kernel_modules:` in the add-on manifest and drive it from a privileged container. The client interface is sysfs — there is no `/dev/vhci` character device on modern kernels ([vhci_hcd.c](https://github.com/torvalds/linux/blob/master/drivers/usb/usbip/vhci_hcd.c)). |

## Security posture of USB/IP

The USB/IP protocol itself has no authentication or encryption; a bound
device is attachable by anyone who can reach TCP port 3240 on the server.
That is acceptable on a trusted LAN with a scoped firewall rule, but over the
Internet the stream must ride a private tunnel. The practical options, in
order of preference:

1. **WireGuard / Tailscale** between the Windows host and HAOS. HAOS has
   official add-ons for both; Windows runs the standard client. The USB/IP
   session then travels encrypted end-to-end and the firewall rule can be
   scoped to the tunnel addresses.
2. **SSH port forwarding** — workable for experiments, but a tethered
   forward is fragile for an always-on appliance.
3. Exposing port 3240 directly to the Internet — never do this.

## SDR-specific notes

RTL-SDRs stream isochronous IQ data (about 1.5–3 MB/s at common 2.4 MSPS
settings). The kernel USB/IP stack supports isochronous transfers, and a
wired LAN hop generally keeps up; Wi-Fi or a long Internet path can drop
samples, which shows up as RTL-SDR lost-sample warnings. If the SDR is used
only for RF reception (e.g., `rtl_433`), an application-level fallback exists:
run `rtl_tcp` (or SpyServer) on Windows and point the consumer at it over
TCP. That path has no USB semantics but is very resilient to jitter. The
generic USB/IP route remains the better default because it works for every
device (Z-wave sticks, serial adapters, card readers), not just SDRs.

## What was verified this session

- usbipd-win project, install/usage documentation (bind/list, Linux client
  attach) — via project README and docs.
- HAOS add-on container mechanics (`kernel_modules`, Alpine
  `linux-tools-usbip` package, sysfs remount requirement, privileged
  profile) — via the source of a working, published add-on
  (cryptedx/ha-usbip-client, cloned and inspected), plus the kernel
  source confirming the sysfs (not /dev) client interface.
- Commercial alternatives' existence and rough positioning — via vendor
  pages and community discussion threads.

Not independently re-verified this session (stated as general knowledge):
exact VirtualHere licensing terms, current USB Network Gate pricing
fluctuations, and real-world RTL-SDR sample-loss rates over USB/IP links.
