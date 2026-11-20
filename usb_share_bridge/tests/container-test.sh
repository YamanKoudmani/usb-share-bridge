#!/bin/sh
# Runs inside the built image; verifies script syntax and the discovery
# pipeline end to end against a fake usbip client (no real vhci needed).
set -eu

# In production, s6 creates this before running cont-init scripts.
mkdir -p /run/s6/container_environment
# with-contenv imports env vars from this directory, so publish the test flag.
echo 1 > /run/s6/container_environment/USBBRIDGE_SKIP_MODULES

echo '== syntax checks =='
for f in /usr/share/usb-bridge/common.sh \
         /etc/cont-init.d/05-kernel-module.sh \
         /etc/cont-init.d/10-config-check.sh \
         /etc/cont-init.d/20-discover.sh \
         /etc/services.d/bridge/run \
         /etc/services.d/bridge/finish; do
    bash -n "$f"
    echo "  OK  $f"
done

echo '== kernel module check (test mode) =='
/etc/cont-init.d/05-kernel-module.sh
echo '  OK  sysfs check warns (does not fail) when the path is absent'

echo '== kernel module check with fake vhci sysfs =='
mkdir -p /tmp/fake-vhci
echo /tmp/fake-vhci > /run/s6/container_environment/USBBRIDGE_VHCI_SYSFS
/etc/cont-init.d/05-kernel-module.sh
echo '  OK  sysfs check passes when the control interface is present'

echo '== config check =='
/etc/cont-init.d/10-config-check.sh

echo '== discovery against fake usbip =='
cp /tmp/fake-usbip.sh /usr/local/bin/usbip
chmod +x /usr/local/bin/usbip
/etc/cont-init.d/20-discover.sh

echo '== manifest assertions =='
[ -s /data/usb-bridge-manifest.tsv ]
awk -F'\t' '$1=="127.0.0.1:3240" && $2=="1-1" && $3=="RTL-SDR" && $4=="0bda:2838" {found=1} END {exit !found}' /data/usb-bridge-manifest.tsv
awk -F'\t' '$1=="127.0.0.1:3240" && $2=="2-2" && $3=="CP210x serial" && $4=="10c4:ea60" {found=1} END {exit !found}' /data/usb-bridge-manifest.tsv
! grep -q 'Ghost device' /data/usb-bridge-manifest.tsv
echo 'manifest:'
cat /data/usb-bridge-manifest.tsv

echo '== all container tests passed =='
