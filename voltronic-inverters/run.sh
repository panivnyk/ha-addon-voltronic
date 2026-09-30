#!/usr/bin/with-contenv bashio

set -e

INVERTER_CONFIG="/etc/inverter/inverter.conf"
MQTT_CONFIG="/etc/inverter/mqtt.json"

# Check configuration files
if [ ! -f "$INVERTER_CONFIG" ]; then
    bashio::log.error "Inverter configuration file not found: $INVERTER_CONFIG"
    exit 1
fi

if [ ! -f "$MQTT_CONFIG" ]; then
    bashio::log.error "MQTT configuration file not found: $MQTT_CONFIG"
    exit 1
fi

# Get device type from add-on configuration
DEVICE=$(bashio::config 'device_type')

bashio::log.info "Configured device type: $DEVICE"

case "${DEVICE}" in
    serial)
        DEVICE_PATH="/dev/ttyS0"
        bashio::log.info "Using serial device: $DEVICE_PATH"
        ;;

    usb-serial)
        DEVICE_PATH="/dev/ttyUSB0"
        bashio::log.info "Using USB serial device: $DEVICE_PATH"
        ;;

    usb)
        bashio::log.info "USB auto-detection started"

        DEVICE_PATH=""

        for HID in /dev/hidraw*; do
            [ -e "$HID" ] || continue

            N="${HID##*/}"

            D=$(readlink -f "/sys/class/hidraw/$N/device" 2>/dev/null || true)

            bashio::log.info "Checking HID device: $HID"

            while [ "$D" != "/" ] && [ -n "$D" ]; do

                if [ -f "$D/idVendor" ] && [ -f "$D/idProduct" ]; then
                    VID=$(cat "$D/idVendor" 2>/dev/null || true)
                    PID=$(cat "$D/idProduct" 2>/dev/null || true)

                    bashio::log.info "Detected HID $HID: VID=$VID PID=$PID"

                    if [ "$VID" = "0665" ] && [ "$PID" = "5161" ]; then
                        DEVICE_PATH="$HID"
                        break 2
                    fi
                fi

                D="${D%/*}"
            done
        done

        if [ -z "$DEVICE_PATH" ]; then
            bashio::log.error "Voltronic USB HID device 0665:5161 not found"
            exit 1
        fi

        bashio::log.info "Found Voltronic USB HID device: $DEVICE_PATH"
        ;;

    *)
        bashio::log.error "Invalid device type: ${DEVICE}"
        exit 1
        ;;
esac

bashio::log.info "Selected inverter device: $DEVICE_PATH"

# Update inverter.conf with detected device
echo "[DEBUG] Updating inverter.conf file with device: $DEVICE_PATH"

sed -i "s|^device=.*|device=${DEVICE_PATH}|" "$INVERTER_CONFIG" || {
    bashio::log.error "Error updating $INVERTER_CONFIG"
    exit 1
}

bashio::log.info "Inverter configuration updated"

# Update the mqtt.json file
BROKER_HOST=$(bashio::config 'mqtt_broker_host')
MQTT_USERNAME=$(bashio::config 'mqtt_username')
MQTT_PASSWORD=$(bashio::config 'mqtt_password')
DEVICE_NAME=$(bashio::config 'device_name')

bashio::log.info "Configuring MQTT connection"
bashio::log.info "MQTT broker: ${BROKER_HOST}"
bashio::log.info "MQTT device name: ${DEVICE_NAME}"

# Update MQTT configuration
jq \
    --arg host "$BROKER_HOST" \
    --arg username "$MQTT_USERNAME" \
    --arg password "$MQTT_PASSWORD" \
    --arg device_name "$DEVICE_NAME" \
    '
    .broker = $host |
    .username = $username |
    .password = $password |
    .device_name = $device_name
    ' \
    "$MQTT_CONFIG" > "${MQTT_CONFIG}.tmp"

mv "${MQTT_CONFIG}.tmp" "$MQTT_CONFIG"

bashio::log.info "MQTT configuration updated"

# Start inverter poller
bashio::log.info "Starting Voltronic inverter poller"

/opt/inverter-cli/bin/inverter_poller -d -1
