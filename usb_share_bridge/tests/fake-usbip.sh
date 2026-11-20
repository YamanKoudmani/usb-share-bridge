#!/bin/sh
# Fake `usbip` client used for container-local tests (no vhci available).
if [ "$1" = "list" ]; then
    printf -- '- 127.0.0.1\n'
    printf -- '     1-1: Realtek : RTL2838UHIDIR (0bda:2838)\n'
    printf -- '          : /sys/devices/pci0000:00/0000:00:14.0/usb1/1-1\n'
    printf -- '     2-2: Silicon Labs : CP210x UART Bridge (10c4:ea60)\n'
    printf -- '          : /sys/devices/pci0000:00/0000:00:14.0/usb2/2-2\n'
    exit 0
fi
exit 1
