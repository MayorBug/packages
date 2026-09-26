# Controller architecture

## Package boundary

`pwm-fan-control` owns all fan-control decisions. It has no dependency on
LuCI, rpcd, UCI, a browser, or an updater.

The package owns these functions:

- configuration parsing, defaults, diagnostics, and atomic file updates
- hwmon and thermal-zone discovery
- device-tree policy parsing
- Kernel, Auto, Curve, Manual, and Disabled modes
- modem temperature collection
- verified PWM writes and fan supervision
- current status, history, and controller events

The optional `luci-app-pwm-fan` package uses the public command-line and file
contracts. It does not make safety or control decisions.

## Installed components

- `/usr/sbin/pwm-fan-control` selects a command or starts the daemon.
- `/usr/lib/pwm-fan/` contains the controller modules.
- `/etc/init.d/pwm-fan-control` starts the controller with procd.
- The init script starts a separate modem sampler when modem monitoring is on.
- `/etc/pwm-fan.conf` contains the standalone configuration.
- `/var/run/pwm-fan-control/` contains replaceable status and history data.
- OpenWrt `logd` stores controller events.

## Runtime flow

The controller parses and validates the configuration before hardware access.
An active mode then finds one hwmon device and one CPU thermal zone.

Each control cycle does these actions in order:

1. Read the required hardware data.
2. Use the last fresh modem sample, when one exists.
3. Select and filter the control temperature.
4. Calculate the requested fan output.
5. Apply the minimum output from the kernel policy.
6. Write and read back PWM when the active mode controls the fan.
7. Update the fan state.
8. Replace the current status file.
9. Add a history record when its deadline expires.
The controller never requests modem data. The modem sampler can wait for HTTP
or serial I/O without delaying a controller cycle. It publishes each valid
sample with an atomic file replacement. The controller reads that file without
waiting.

A sample stays valid for two modem polling intervals. The controller ignores
an older sample and continues with CPU temperature. It uses modem data again
when the sampler publishes a fresh sample.

Kernel mode gives control to the kernel once. It then reads the hardware but
does not write PWM. If startup discovers the fan and CPU sensor but cannot
normalize the kernel policy safely, the saved mode is preserved while the
runtime enters a degraded Kernel observer. That fallback never writes PWM and
continues publishing temperature, actual PWM, optional RPM, status, and history.
Disabled mode does not find or access hardware. It leaves no persistent
controller or modem process.

A normal stop gives control back to the Linux thermal policy. After an
untrappable crash, the design relies on the target kernel `pwm-fan`
implementation resuming as the hardware fallback; this is a platform assumption
that requires device validation.

## Module ownership

The configuration module owns configuration decisions. The daemon owns state
changes and safety reactions.

Separate modules own hardware access, kernel policy, modem access, and fan
supervision. These modules return explicit results to the daemon.

The API module converts controller data to JSON. It does not contain defaults,
validation rules, health rules, or control algorithms.

## Public contracts

- [`CONFIGURATION.md`](CONFIGURATION.md) defines the configuration and diagnostics.
- [`CONTROLLER.md`](CONTROLLER.md) defines modes, status, history, and events.
- `config-json`, `validate`, `probe`, and `status-json` are bounded local interfaces.

A client can use daemon data only while the identity and heartbeat are fresh.
The client must not show stale output as current output.

## Safety order

The CPU sensor is required for every running role. A normalized kernel thermal
policy is required before userspace may write PWM. If normalization fails at
startup, the kernel retains ownership and the daemon is limited to read-only
observation. Modem data and history are optional.

Auto, Curve, and Manual cannot request less cooling than the kernel floor. A
required sensor, live policy, or PWM error in an established control role
requests the strongest output derived from the last validated policy.

An optional modem or history error does not stop CPU fan control.

## Development rules

The package uses one owner for each mutable default and safety decision.
Modules have one clear responsibility. New abstractions must remove real
repeated behavior without more coupling.
