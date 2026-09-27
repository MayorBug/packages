# Configuration

## File contract

The standalone controller reads `/etc/pwm-fan.conf`. The root-owned file is a
package conffile, mode `0600`, and is preserved across upgrades.

The format is intentionally small:

- UTF-8 or ASCII text with a maximum size of 16 KiB
- blank lines and lines that start with `#` are ignored
- one `key=value` setting on each line
- spaces around the key and value are removed
- no quotes, escapes, inline comments, expansion, or shell syntax
- unknown keys, duplicate keys, malformed lines, and unsupported config
  versions are structural errors.

The file is always parsed as data. It is never sourced, evaluated, or passed to
a shell as executable text.

## Canonical defaults

`config_defaults()` in the controller package is the sole runtime authority
for concrete default values. The controller ships `/etc/pwm-fan.conf` as the
standalone, commented representation operators edit over SSH. Its canonical
render test compares the complete shipped file with controller output so the
two cannot drift unnoticed.

LuCI obtains defaults through `config-json`. It does not contain another
default table. Long explanations belong here and in LuCI, while config-file
comments remain short and concrete.

## Validation reference

| Key | Accepted value | Active use |
|---|---|---|
| `config_version` | exactly `2` | all |
| `mode` | `kernel`, `auto`, `curve`, `manual`, `disabled` | all |
| `control_interval_s` | integer 1-60 | running daemon |
| `hwmon_name` | safe sysfs component, 1-64 characters | except Disabled |
| `thermal_zone` | safe sysfs component, 1-64 characters | except Disabled |
| `tach_enabled` | `0` or `1` | observation roles |
| `temperature_filter` | `none` or `median` | Auto/Curve |
| `temperature_filter_duration_s` | `5`, `10`, or `15` | median filter |
| `wifi_source` | `off`, `auto`, or a supported MediaTek Wi-Fi hwmon name | optional monitoring and Auto/Curve |
| `modem_source` | `off`, `qmanager_http`, `quectel_at` | Kernel/Auto/Curve |
| `modem_http_host` | conservative hostname or IPv4 address | QManager HTTP |
| `modem_at_device` | absolute `/dev/` TTY path | Quectel AT |
| `modem_interval_s` | integer 10-30 | modem enabled |
| `pid_target_c` | number 30-100 | Auto |
| `pid_kp` | number 0-0.20 | Auto |
| `pid_ki` | number 0-0.001667 | Auto |
| `pid_kd` | number 0-1.20 | Auto |
| `pid_integral_limit` | number 0-1.00 | Auto |
| `curve_style` | `step` or `smooth` | Curve |
| `curve_hysteresis_c` | number 0-20 | stepped Curve |
| `curve_points` | 2-10 ordered unique pairs | Curve |
| `manual_output_percent` | integer 0-100 | Manual |
| `manual_timeout_min` | integer 0-1440 | Manual |

Numbers use a period as decimal separator and no suffix. Temperature config
values use degrees Celsius and output config values use percentages. Curve
temperatures strictly increase and outputs never decrease.

### Wi-Fi hwmon temperature

`wifi_source=off` preserves CPU/modem behavior. `auto` discovers supported
MediaTek Wi-Fi hwmon names such as `mt7915_phy0` and uses the hottest readable
radio. An exact stable hwmon name selects only that radio. Configuration never
stores the changing `hwmonN` directory number. Wi-Fi is optional: an unavailable
radio is reported and CPU control continues.

### QManager public HTTP

The controller supports these projects:

- [QManager](https://github.com/dr-dolomite/QManager)
- [QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N)

`modem_http_host` contains only a host name or IPv4 address. Do not include a
scheme, port, or path. The controller requests this fixed public endpoint:

```text
http://HOST/cgi-bin/quecmanager/public/overview.sh
```

Current QManager installations redirect that request to HTTPS. The controller
uses `uclient-fetch --no-check-certificate` because QManager uses a local
self-signed certificate.

The endpoint must return a JSON object with these three usable fields:

```json
{
  "state": "ok",
  "modem_reachable": true,
  "temperature": 48
}
```

The response can contain other fields. The controller accepts a temperature
from 0 through 125 degrees Celsius and converts it to millidegrees Celsius.
`state` other than `ok`, an unreachable modem, a missing field, or an invalid
temperature makes that poll fail. A failed poll does not change CPU-only fan
control.

Unused mode-specific values remain part of the effective config so changing
modes does not discard tuning. Syntax and range validation apply to them even
when inactive. Hardware applicability tests apply only when necessary.

## Defaults and diagnostics

`config_defaults()` owns concrete values. Parsing, validation, diagnostics,
canonical rendering, and reset all read its immutable initialization snapshot.

### Missing known key

A missing current key is compatible:

- its current default becomes the effective value
- raw input remains absent
- the result contains a `missing_key_defaulted` warning
- the configuration remains operational
- the controller does not rewrite the file
- the next successful Save & Apply renders the missing key.

### Invalid present value

An invalid supplied value is never replaced silently:

- preserve and return the actual value
- return an error that contains the key, line, value, and constraint
- reject initial startup and candidate installation
- after failed reload, keep the previous valid runtime configuration active.

Validation never performs shell arithmetic on a value until its integer form
and range are valid. Invalid numeric text produces normal structured
diagnostics. It cannot abort the daemon during reload.

## Transactional activation

Parsing a candidate and activating it are separate operations. The daemon
keeps an explicit active mode.

The daemon changes its runtime role after validation, discovery, policy
construction, and the required kernel handoff succeed. A failed Kernel or Disabled handoff retains the
previous control role and requests full output as the conservative fallback.

Single-key persistent writes run in an isolated process. Success or failure
cannot mutate the caller's active `CFG_*` values. Hardware paths and their
normalized policy are likewise one transaction: a failed policy build restores
the complete previous hardware and policy snapshot.

Changes to `hwmon_name` or `thermal_zone` require a service restart. Save can
store these changes without changing the running daemon. Save & Apply must
restart the service. All other accepted non-Disabled changes use reload.

### Structural error

Unknown keys, duplicate keys, malformed lines, unsupported syntax, and an
unsupported `config_version` reject the complete candidate.

### Structured diagnostic

Each diagnostic contains:

```text
severity
code
key
line
value
default_value
message
```

Independent diagnostics are collected where safe. At most 64 entries are
returned. On overflow, one `diagnostics_truncated` warning replaces the final
entry. Text length is also bounded. Machine fields are stable. LuCI can
localize the message.

## Config JSON contract

```sh
pwm-fan-control config-json
```

returns:

```text
valid
config_revision
raw_values
effective_values
defaults
diagnostics
```

`raw_values` preserves what is actually present, including invalid values.
`effective_values` contains defaults for missing valid keys. Invalid present
values do not receive a pretend effective replacement.

## Validation and applicability

Configuration validity and hardware applicability are separate:

```sh
pwm-fan-control validate -c FILE --json
pwm-fan-control probe -c FILE --json
```

`validate` checks text structure, values, ranges, and cross-field rules without
hardware access.

`probe` first requires valid config, then performs one read-only discovery and
DTS-policy parse. It reports userspace-control applicability separately from
read-only observation availability. When discovery succeeds but policy
normalization fails, it still returns safe CPU/PWM/RPM telemetry with
`observation_available=true` and `applicable=false`. It never writes PWM or
changes service state.

## Config revision

`config_revision` is an optimistic-concurrency token only. MD5 is sufficient
because the token is not a security digest.

Calculate it only when:

- the interface loads the configuration for editing
- `config-install` verifies a save
- `config-reset` verifies a reset
- a successful write returns the new revision.

It must not appear in runtime status, health, history, control calculations,
hardware state, reload comparisons, or cache keys.

## One write path

`config.sh` is the only renderer, lock owner, and writer. All writes follow:

```text
acquire config lock
read latest file
verify expected revision when supplied
parse candidate
validate candidate
render the complete canonical file
write a same-directory temporary file with umask 077
chmod 0600
atomically rename
release lock
```

Failure preserves the original file. Lock acquisition and stale-lock handling
are bounded.

Public write commands are:

```sh
pwm-fan-control config-install -c FILE --expect REVISION
pwm-fan-control config-set KEY VALUE
pwm-fan-control config-reset --expect REVISION
```

`config-set` uses the same complete parse, render, and atomic install path. It
does not perform an unanchored text substitution.

Reset installs current defaults with `mode=kernel`. It preserves history and
system logs.

## Reload behavior

Reload parses and validates a candidate once. Each accepted non-Disabled
candidate repeats hardware discovery and rebuilds the kernel policy. The
daemon commits runtime values only after all required checks pass.

An invalid disk config leaves the previous runtime config active and changes
`configuration_state` to report that disk and runtime differ. Runtime config
health is not represented by a file hash.

State resets are selective:

| Change | Reset |
|---|---|
| mode | mode-local state |
| PID settings | PID state |
| filter type, duration, or control interval | filter state |
| curve settings | curve state |
| hwmon or thermal zone | hardware and policy |
| modem source, host, device, or interval | modem state |
| tach setting | fan-watch state |
| manual timeout | timeout origin |

## Upgrade from format 1

The service upgrades a format-1 file one time. It preserves all settings that
are not filter settings. It removes `temperature_samples` and sets these
values:

```text
temperature_filter=median
temperature_filter_duration_s=10
```

The service writes the complete format-2 file atomically. A format-2 file that
contains `temperature_samples` is invalid.

## Modem settings

### QManager HTTP

The host setting supplies only the host. The daemon constructs:

```text
http://HOST/cgi-bin/quecmanager/public/overview.sh
```

The five-second request is bounded to 64 KiB. QManager JSON is parsed once and
must report an OK state, reachable modem, and plausible finite temperature.
RM551 and RM520N endpoint layouts use the same public response contract.

### Quectel AT

The device is an absolute TTY under `/dev`. Serial setup is 115200 baud, raw
8N1, no echo, and no flow control, with optional unsupported `stty` flags
removed on bounded retries.

Frequent AT polling can make the modem unstable. Use QManager HTTP when it is
available.

The five-second transaction ignores echo, blank lines, and unrelated messages,
requires final `OK`, and selects the highest plausible `cpuss-0` through
`cpuss-4` temperature. The controller can cache a successful serial setup until
a request fails.

## Command-line workflow

```sh
pwm-fan-control config-json
pwm-fan-control validate -c /etc/pwm-fan.conf --json
pwm-fan-control probe -c /etc/pwm-fan.conf --json
/etc/init.d/pwm-fan-control reload
pwm-fan-control status-json
logread -e pwm-fan-control
```

The controller package remains fully configurable without LuCI.
