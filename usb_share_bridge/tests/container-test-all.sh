#!/bin/sh
# Runs inside the built image; verifies attach_mode=all: every shared
# device on the server is attached, and junk descriptions get usb.ids names.
set -eu

mkdir -p /run/s6/container_environment
echo 1 > /run/s6/container_environment/USBBRIDGE_SKIP_MODULES

echo '== syntax checks =='
bash -n /usr/share/usb-bridge/common.sh

echo '== attach-all mode: config check =='
/etc/cont-init.d/10-config-check.sh

echo '== attach-all mode: discovery =='
cp /tmp/fake-usbip.sh /usr/local/bin/usbip
chmod +x /usr/local/bin/usbip
/etc/cont-init.d/20-discover.sh

echo '== manifest assertions =='
[ -s /data/usb-bridge-manifest.tsv ]
grep -q '1-1' /data/usb-bridge-manifest.tsv
grep -q '2-2' /data/usb-bridge-manifest.tsv
grep -q '0bda:2832' /data/usb-bridge-manifest.tsv
awk -F'\t' '$2=="3-1" && $3 !~ /^Bulk-In/ && $3 != "" {found=1} END {exit !found}' /data/usb-bridge-manifest.tsv
echo 'manifest:'
cat /data/usb-bridge-manifest.tsv

echo '== attach-all tests passed =='
