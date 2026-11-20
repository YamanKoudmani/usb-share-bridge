#!/command/with-contenv bashio
# shellcheck shell=bash

source /usr/share/usb-bridge/common.sh
usbb::init_logging
usbb::load_config

SERVER="$(usbb::config_default server "")"
if [ -z "${SERVER}" ]; then
    bashio::exit.nok "Option 'server' is required - set it in the add-on options."
fi

ATTACH_MODE="$(usbb::config_default attach_mode all)"
if [ "${ATTACH_MODE}" != "all" ] && [ "${ATTACH_MODE}" != "select" ]; then
    bashio::exit.nok "Option 'attach_mode' must be 'all' or 'select' (got '${ATTACH_MODE}')."
fi

DEVICES_JSON="$(usbb::config_devices_json)"
DEVICE_COUNT="$(jq -r 'length' <<< "${DEVICES_JSON}")"
if [ "${ATTACH_MODE}" = "select" ] && [ "${DEVICE_COUNT}" -eq 0 ]; then
    bashio::exit.nok "attach_mode is 'select' but 'devices' is empty - add devices, or switch attach_mode to 'all' to attach everything the server shares."
fi

usbb::log info "Attach mode: ${ATTACH_MODE}."

while IFS=$'\t' read -r name id; do
    if [ -z "$id" ]; then
        bashio::exit.nok "Device '$name' has no id - set a VID:PID like 0bda:2838 or a bus id like 1-1."
    fi
    if ! usbb::is_vidpid "$id" && ! usbb::is_busid "$id"; then
        bashio::exit.nok "Device '$name' has invalid id '$id' - expected VID:PID like 0bda:2838 or bus id like 1-1."
    fi
done < <(jq -r '(. // [])[] | [(.name // "?"), (.id // "")] | @tsv' <<< "${DEVICES_JSON}")

usbb::log info "Configuration OK: ${DEVICE_COUNT} device(s) against server ${SERVER}."

# Reachability probe (non-fatal): plain TCP connect to the USB/IP port.
HOST="${SERVER%%:*}"
PORT="${SERVER##*:}"
if [ "${PORT}" = "${SERVER}" ]; then
    PORT=3240
fi
if timeout 3 bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
    usbb::log info "Server ${SERVER} is reachable on TCP ${PORT}."
else
    usbb::log warning "Server ${SERVER} is not reachable on TCP ${PORT} yet - the monitor loop will keep retrying."
fi
