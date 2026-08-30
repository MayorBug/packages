#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

set -eu
. "$(dirname "$0")/lib.sh"
setup_tmp

sys=$TEST_TMP/sys
run=$TEST_TMP/run
bin=$TEST_TMP/bin
mkdir -p "$sys/class/hwmon/hwmon0" "$sys/class/thermal/thermal_zone0" \
	"$sys/class/thermal/cooling_device0" "$sys/devices/pwmfan" \
	"$sys/firmware/devicetree/base/fan" \
	"$sys/firmware/devicetree/base/thermal-zones/cpu-thermal/trips/trip0" \
	"$sys/firmware/devicetree/base/thermal-zones/cpu-thermal/cooling-maps/map0" \
	"$run" "$bin"

printf 'pwmfan\n' > "$sys/class/hwmon/hwmon0/name"
printf '0\n' > "$sys/class/hwmon/hwmon0/pwm1"
printf '1200\n' > "$sys/class/hwmon/hwmon0/fan1_input"
ln -s "$sys/devices/pwmfan" "$sys/class/hwmon/hwmon0/device"
ln -s "$sys/firmware/devicetree/base/fan" "$sys/devices/pwmfan/of_node"
printf 'cpu-thermal\n' > "$sys/class/thermal/thermal_zone0/type"
printf '50000\n' > "$sys/class/thermal/thermal_zone0/temp"
printf 'pwm-fan\n' > "$sys/class/thermal/cooling_device0/type"
printf '0\n' > "$sys/class/thermal/cooling_device0/cur_state"
printf '2\n' > "$sys/class/thermal/cooling_device0/max_state"
ln -s "$sys/devices/pwmfan" "$sys/class/thermal/cooling_device0/device"

python3 - "$sys" <<'PY'
import pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
def cells(path, *values):
    path.write_bytes(b''.join(struct.pack('>I', value) for value in values))
fan = root / 'firmware/devicetree/base/fan'
zone = root / 'firmware/devicetree/base/thermal-zones/cpu-thermal'
cells(fan / 'phandle', 1)
cells(fan / 'cooling-levels', 0, 128, 255)
cells(zone / 'trips/trip0/phandle', 2)
cells(zone / 'trips/trip0/temperature', 60000)
cells(zone / 'trips/trip0/hysteresis', 2000)
cells(zone / 'cooling-maps/map0/cooling-device', 1, 1, 1)
cells(zone / 'cooling-maps/map0/trip', 2)
PY

config=$TEST_TMP/manual.conf
sed -e 's/^mode=.*/mode=manual/' -e 's/^tach_enabled=.*/tach_enabled=0/' \
	"$DEFAULT_CONFIG" > "$config"
printf '0\n' > "$TEST_TMP/uptime"

cat > "$bin/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PWM_FAN_TEST_LOG"
EOF
cat > "$bin/sleep" <<'EOF'
#!/bin/sh
value=$(awk '{ print int($1) }' "$PWM_FAN_UPTIME_FILE")
printf '%s\n' "$((value + 2))" > "$PWM_FAN_UPTIME_FILE"
[ ! -r "$PWM_FAN_STATUS_FILE" ] || cp "$PWM_FAN_STATUS_FILE" "$PWM_FAN_CAPTURED_STATUS"
kill -TERM "$PPID"
EOF
chmod +x "$bin/logger" "$bin/sleep"

disabled_config=$TEST_TMP/disabled.conf
sed 's/^mode=.*/mode=disabled/' "$DEFAULT_CONFIG" > "$disabled_config"
