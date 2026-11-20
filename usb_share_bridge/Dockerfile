ARG BUILD_FROM=ghcr.io/home-assistant/base:latest
FROM ${BUILD_FROM}

# kmod: modprobe for vhci-hcd fallback
# linux-tools-usbip: the `usbip` client tools
# hwids-usb: usb.ids for readable names in `usbip` output
RUN apk add --no-cache kmod linux-tools-usbip hwids-usb

COPY rootfs /

RUN chmod +x /etc/cont-init.d/*.sh \
    && chmod +x /etc/services.d/bridge/run \
    && chmod +x /etc/services.d/bridge/finish
