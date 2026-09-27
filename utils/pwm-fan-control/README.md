# PWM Fan Control

`pwm-fan-control` controls Linux `pwm-fan` devices on OpenWrt. It operates as
a command-line program and as a procd service.

The controller supports these modes:

- Kernel observes the fan while the Linux thermal policy controls it.
- Auto uses a PID controller.
- Curve uses configured temperature points.
- Manual uses a fixed output for a limited time.
- Disabled stops the service and does not access the hardware.

The Linux thermal policy always supplies the minimum cooling level. Auto,
Curve, and Manual cannot request less cooling than this level. Device-tree
cooling levels may use ascending or electrically inverted raw PWM values; the
controller normalizes cooling demand and derives fail-safe output from the
strongest declared cooling state. Auto and Curve can optionally include the
hottest supported MediaTek Wi-Fi hwmon reading alongside CPU and modem data.

If the fan and CPU sensor are discoverable but the thermal policy cannot be
normalized safely, the service preserves the saved mode while running as a
degraded, read-only Kernel observer. It does not write PWM in this fallback.

The package installs these main files:

- `/etc/pwm-fan.conf`
- `/etc/init.d/pwm-fan-control`
- `/usr/sbin/pwm-fan-control`
- `/usr/lib/pwm-fan/`

LuCI is not required. The optional `luci-app-pwm-fan` package adds a graphical
interface for the same configuration and controller data.

## Documentation

The detailed documents are developer contracts. Read them in this authority
order when two statements conflict:

1. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) defines ownership and system boundaries.
2. [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) defines configuration behavior.
3. [`docs/CONTROLLER.md`](docs/CONTROLLER.md) defines runtime behavior.

[`docs/TEMPERATURE_SOURCES_PLAN.md`](docs/TEMPERATURE_SOURCES_PLAN.md) defines
the optional Wi-Fi temperature-source extension.

Report a conflict instead of selecting the lower document.

## Glossary

- **PWM** controls fan output with a pulse-width signal.
- **hwmon** is the Linux hardware-monitor interface.
- **DTS** is the device-tree source that describes the hardware and thermal policy.
- **PID** is the proportional, integral, and derivative control method.

File and time terms:

- **Atomic write** replaces a complete file without exposing partial content.
- **Monotonic time** increases while the router runs and ignores wall-clock changes.

## Standalone operation

1. Edit the configuration file.

   ```sh
   vi /etc/pwm-fan.conf
   ```

2. Validate the configuration.

   ```sh
   pwm-fan-control validate -c /etc/pwm-fan.conf --json
   ```

3. Examine the detected hardware.

   ```sh
   pwm-fan-control probe -c /etc/pwm-fan.conf --json
   ```

4. Enable and start the service.

   ```sh
   /etc/init.d/pwm-fan-control enable
   /etc/init.d/pwm-fan-control start
   ```

5. Read the current status and events.

   ```sh
   pwm-fan-control status-json
   logread -e pwm-fan-control
   ```

## Tests

Run the focused source tests:

```sh
tests/run_tests.sh
```
