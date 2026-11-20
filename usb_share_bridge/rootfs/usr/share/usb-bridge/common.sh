# Shared logic for USB Share Bridge add-on scripts.
# Scripts must run under bashio (#!/command/with-contenv bashio) so bashio
# functions are available before sourcing this file.

MANIFEST="/data/usb-bridge-manifest.tsv"
USBB_MISSING=0
LOG_LEVEL="${LOG_LEVEL:-info}"
USBB_CONFIG_JSON=""

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# Raw add-on options. Prefers the Supervisor API (live config edits) and
# falls back to /data/options.json, which exists in production and tests.
usbb::raw_config() {
    local options
    if [ -n "${SUPERVISOR_API:-}" ]; then
        if options="$(bashio::app.config 2>/dev/null)"; then
            printf '%s' "$options"
            return 0
        fi
        usbb::log warning "Supervisor API unavailable; falling back to /data/options.json."
    fi
    if [ -r /data/options.json ]; then
        cat /data/options.json
        return 0
    fi
    echo '{}'
}

usbb::load_config() {
    USBB_CONFIG_JSON="$(usbb::raw_config)"
}

usbb::config_default() {
    # Echo a config value or a default when unset/null/empty.
    local key="$1" default="$2" value
    [ -z "${USBB_CONFIG_JSON:-}" ] && usbb::load_config
    value="$(jq -r --arg k "$key" '(.[$k] // null)' <<< "${USBB_CONFIG_JSON}")"
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

usbb::config_true() {
    local key="$1" value
    value="$(usbb::config_default "$1" "false")"
    [ "$value" = "true" ]
}

usbb::config_devices_json() {
    [ -z "${USBB_CONFIG_JSON:-}" ] && usbb::load_config
    jq -c '(.devices // [])' <<< "${USBB_CONFIG_JSON}"
}

usbb::init_logging() {
    LOG_LEVEL="$(usbb::config_default log_level info)"
}

usbb::log() {
    local level="$1"
    shift
    local msg="$*"
    case "$LOG_LEVEL" in
        debug) ;;
        info)
            [ "$level" = "debug" ] && return 0
            ;;
        warning)
            [ "$level" = "debug" ] && return 0
            [ "$level" = "info" ] && return 0
            ;;
        error) [ "$level" != "error" ] && return 0 ;;
    esac
    case "$level" in
        debug) bashio::log.debug "$msg" ;;
        info) bashio::log.info "$msg" ;;
        warning) bashio::log.warning "$msg" ;;
        error) bashio::log.error "$msg" ;;
    esac
}

usbb::is_vidpid() {
    [[ "$1" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]]
}

usbb::is_busid() {
    [[ "$1" =~ ^[0-9][0-9.\-]*$ ]]
}

# ---------------------------------------------------------------------------
# Server discovery
# ---------------------------------------------------------------------------

# Echo "busid<TAB>description<TAB>vid:pid" lines; return 1 if unreachable.
usbb::list_remote() {
    local server="$1" line busid desc vidpid out
    if ! out="$(usbip list -r "$server" 2>/dev/null)"; then
        return 1
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([0-9][0-9.\-]*):[[:space:]]+(.+)[[:space:]]\(([[:xdigit:]]{4}:[[:xdigit:]]{4})\)$ ]] || continue
        busid="${BASH_REMATCH[1]}"
        desc="${BASH_REMATCH[2]}"
        vidpid="${BASH_REMATCH[3]}"
        printf '%s\t%s\t%s\n' "$busid" "$desc" "$vidpid"
    done <<< "$out"
    return 0
}

usbb::read_config_devices() {
    # Fill two arrays (passed by name) from the add-on devices option.
    local -n __names="$1"
    local -n __ids="$2"
    local json
    __names=()
    __ids=()
    json="$(usbb::config_devices_json)"
    while IFS=$'\t' read -r n i; do
        __names+=("$n")
        __ids+=("$i")
    done < <(jq -r '(. // [])[] | [(.name // "?"), (.id // "")] | @tsv' <<< "$json")
}

usbb::usbids_name() {
    # Echo "Vendor Product" for a VID:PID from the hwdata usb.ids database,
    # if available. Prints nothing when unknown.
    local vidpid="$1"
    local file="/usr/share/hwdata/usb.ids"
    if [ ! -r "$file" ]; then
        file="/usr/share/usb.ids"
    fi
    [ -r "$file" ] || return 0
    awk -v v="${vidpid%%:*}" -v p="${vidpid##*:}" '
        BEGIN { inv = 0 }
        /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][ \t]/ {
            if (inv) { inv = 0 }
            if ($1 == v) {
                vendor = $0
                sub(/^[0-9a-f]+[ \t]+/, "", vendor)
                inv = 1
            }
            next
        }
        inv && /^\t/ && $1 == p {
            product = $0
            sub(/^\t[0-9a-f]+[ \t]+/, "", product)
            print vendor " " product
            exit
        }
    ' "$file" 2>/dev/null
    return 0
}

# Resolve configured devices against the server; write the attach manifest.
# Returns 1 only when the server cannot be reached (old manifest is kept).
usbb::discover() {
    local server devices_raw found=0 i name id busid vidpid mode desc idsname
    server="$(usbb::config_default server "")"
    if [ -z "$server" ] || [ "$server" = "null" ]; then
        usbb::log error "No 'server' configured - set it in the add-on options."
        return 1
    fi

    usbb::log info "Discovering shared devices on server $server..."
    if ! devices_raw="$(usbb::list_remote "$server")"; then
        usbb::log warning "Could not list devices on $server (server offline, or firewall blocking TCP 3240?)"
        return 1
    fi

    local -a names=() ids=()
    usbb::read_config_devices names ids
    mode="$(usbb::config_default attach_mode all)"
    if [ "$mode" != "all" ] && [ "$mode" != "select" ]; then
        usbb::log error "Invalid attach_mode '$mode' - expected 'all' or 'select'."
        return 1
    fi

    local tmp="${MANIFEST}.tmp"
    : > "$tmp"

    if [ "$mode" = "all" ]; then
        # Default: mirror whatever the Windows side shares. The Windows GUI
        # checkboxes are the single source of truth - nothing to type here.
        while IFS=$'\t' read -r busid desc vidpid; do
            [ -n "${busid:-}" ] || continue
            name="$desc"
            if idsname="$(usbb::usbids_name "$vidpid")" && [ -n "$idsname" ]; then
                case "$desc" in
                    Bulk*|Interface*|Unknown*|USB*)
                        # Raw usbipd strings carry no identity; use usb.ids.
                        name="$idsname"
                        ;;
                esac
            fi
            printf '%s\t%s\t%s\t%s\n' "$server" "$busid" "$name" "$vidpid" >> "$tmp"
            found=$((found + 1))
            usbb::log info "Will attach: $name ($vidpid, server busid $busid)"
        done <<< "$devices_raw"
        mv "$tmp" "$MANIFEST"
        usbb::log info "Discovery finished: $found shared device(s) on server $server (attach_mode=all)."
        return 0
    fi

    for i in "${!names[@]}"; do
        name="${names[$i]}"
        id="${ids[$i]}"
        busid=""
        vidpid=""
        if usbb::is_vidpid "$id"; then
            vidpid="$id"
            busid="$(printf '%s\n' "$devices_raw" | awk -F'\t' -v vp="$vidpid" 'tolower($3) == tolower(vp) { print $1; exit }')"
        elif usbb::is_busid "$id"; then
            busid="$id"
            if [ -z "$(printf '%s\n' "$devices_raw" | awk -F'\t' -v b="$busid" '$1 == b { print $1; exit }')" ]; then
                busid=""
            fi
        else
            usbb::log error "Device '$name' has invalid id '$id' (expected VID:PID like 0bda:2838 or bus id like 1-1)."
            continue
        fi
        if [ -z "$busid" ]; then
            usbb::log warning "Device '$name' ($id) is not visible on server $server - is it plugged in and shared (usbipd bind)?"
            continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$server" "$busid" "$name" "$vidpid" >> "$tmp"
        found=$((found + 1))
        usbb::log info "Resolved '$name' ($id) -> server busid $busid"
    done

    mv "$tmp" "$MANIFEST"
    usbb::log info "Discovery finished: $found of ${#names[@]} configured device(s) resolvable."
    return 0
}

# ---------------------------------------------------------------------------
# Attach / detach
# ---------------------------------------------------------------------------

usbb::remount_sysfs() {
    # Required for USB/IP attach from inside a container.
    if ! mount -o remount -t sysfs sysfs /sys >/dev/null 2>&1; then
        usbb::log warning "Could not remount /sys rw - usbip attach may fail."
        return 1
    fi
    usbb::log debug "Remounted /sys rw for USB/IP."
    return 0
}

usbb::is_attached() {
    # True if the given server busid shows up in 'usbip port'.
    local busid="$1" out escaped
    command -v usbip >/dev/null 2>&1 || return 1
    out="$(usbip port 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    escaped="$(printf '%s' "$busid" | sed 's/[.]/\\./g')"
    printf '%s\n' "$out" | grep -Eq "(^|[^0-9])${escaped}([^0-9]|$)"
}

usbb::attach() {
    local server="$1" busid="$2" name="${3:-}" attempt
    local retries="${ATTACH_RETRIES:-3}" delay="${ATTACH_DELAY:-2}"
    [ "$retries" -lt 1 ] && retries=1
    usbb::log info "Attaching '$name' (busid $busid) from $server..."
    # Clear any stale attachment first (errors are expected/ignored).
    usbip detach -r "$server" -b "$busid" >/dev/null 2>&1 || true
    for attempt in $(seq 1 "$retries"); do
        if usbip attach --remote "$server" --busid "$busid" >/dev/null 2>&1; then
            usbb::log info "Attached '$name' (busid $busid) on attempt $attempt/$retries."
            return 0
        fi
        usbb::log warning "Attach attempt $attempt/$retries failed for '$name' (busid $busid)."
        # Clean up possible half-attached state before retrying.
        usbip detach -r "$server" -b "$busid" >/dev/null 2>&1 || true
        [ "$attempt" -lt "$retries" ] && sleep "$delay"
    done
    usbb::log error "Failed to attach '$name' (busid $busid) after $retries attempt(s)."
    return 1
}

# Walk the manifest and attach anything missing. Sets USBB_MISSING.
usbb::attach_missing() {
    local phase="${1:-monitor}" server busid name vidpid attached_any=false
    USBB_MISSING=0
    if [ ! -s "$MANIFEST" ]; then
        return 0
    fi
    while IFS=$'\t' read -r server busid name vidpid; do
        [ -n "${busid:-}" ] || continue
        if usbb::is_attached "$busid"; then
            usbb::log debug "$name (busid $busid) is attached."
            continue
        fi
        USBB_MISSING=$((USBB_MISSING + 1))
        usbb::log warning "$name (busid $busid) is NOT attached ($phase)."
        if [ "$AUTO_REATTACH" = "true" ]; then
            if usbb::attach "$server" "$busid" "$name"; then
                attached_any=true
                sleep "${ATTACH_DELAY:-2}"
            fi
        else
            usbb::log error "Auto-reattach is disabled - manual action required."
        fi
    done < "$MANIFEST"
    [ "$attached_any" = "true" ] && usbb::log info "Attach pass ($phase) complete."
    return 0
}

usbb::detach_all() {
    local out port
    command -v usbip >/dev/null 2>&1 || return 0
    out="$(usbip port 2>/dev/null)" || out=""
    if [ -n "$out" ] && printf '%s\n' "$out" | grep -Eq 'Port [0-9]+'; then
        printf '%s\n' "$out" | grep -Eo 'Port [0-9]+' | awk '{print $2}' | sort -un | while read -r port; do
            if usbip detach -p "$port" >/dev/null 2>&1; then
                usbb::log info "Detached USB/IP port $port."
            else
                usbb::log warning "Failed to detach USB/IP port $port."
            fi
        done
        return 0
    fi
    # Port listing failed - blind detach over the vhci port range.
    for port in $(seq 0 15); do
        usbip detach -p "$port" >/dev/null 2>&1 || true
    done
    usbb::log info "Detach pass complete (blind mode)."
}
