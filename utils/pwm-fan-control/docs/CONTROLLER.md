# Controller

## Purpose

`pwm-fan-control` is the complete non-graphical product. It is a BusyBox shell
daemon and CLI that reads `/etc/pwm-fan.conf`.

The controller controls or observes one PWM fan. It publishes current status
and router history. It also logs state changes.

LuCI is not required to configure, run, inspect, or recover the service.

The executable coordinates small side-effect-free libraries: `config.sh` owns
configuration, the hardware/policy/modem/fan-watch modules own their respective
device responsibilities, `control.sh` owns filtering
and raw-PWM control math, and `runtime.sh` owns status and bounded history.

## Command line

```text
pwm-fan-control run [-c FILE]
pwm-fan-control validate [-c FILE] --json
pwm-fan-control probe [-c FILE] --json
pwm-fan-control config-json
pwm-fan-control config-install -c FILE --expect REVISION
pwm-fan-control config-set KEY VALUE
pwm-fan-control config-reset --expect REVISION
pwm-fan-control status-json
pwm-fan-control clear-history
pwm-fan-control help
```

Commands return bounded diagnostics and meaningful exit status. JSON commands
write one complete JSON document to stdout. Human-readable failures go to
stderr only when JSON was not requested.

The procd init script manages the foreground controller process. It also
manages one foreground modem sampler when modem monitoring is on. The sampler
does not control the fan. The init script signals reload and does not use an
unlimited respawn loop.

## Runtime roles

| Mode | Role | Behavior |
|---|---|---|
| Disabled | Off | no daemon and no ongoing work |
| Kernel | Observe | one policy handoff, then read-only observation |
| Auto | Control | one-sided cooling PID |
| Curve | Control | stepped or smooth temperature curve |
| Manual | Control | fixed configured output |

Auto, Curve, and Manual calculate normalized cooling demand, raise it to the
evaluated DTS floor, convert it according to the validated PWM direction, and
apply the effective raw PWM through one verified write path.

## Startup lifecycle

1. Parse configuration once.
2. Validate configuration once.
3. Report missing-key warnings.
4. Derive runtime role.
5. Exit immediately when already Disabled.
6. Discover required hardware once.
7. Build and normalize the DTS policy once.
8. Acquire the daemon lock without waiting, before any handoff or PWM write.
9. If normalization is unsupported, preserve kernel ownership and select the
   degraded Kernel observer without writing PWM.
10. Otherwise apply one policy handoff when entering configured Kernel mode.
11. Initialize role-specific state and scheduling deadlines.
12. Enter the common runtime loop.

Starting Disabled does not discover hardware. Entering Disabled from a running
control role performs handoff before exit. The monitor-only fallback preserves
the saved configured mode, reports `active_mode=kernel`, sets
`HANDOFF_ON_EXIT=0`, and emits one `kernel_monitor_fallback` warning.

## Reload lifecycle

Reload is processed at a safe loop boundary:

1. Parse the disk candidate once.
2. Validate it once.
3. Compare normalized candidate values with active values.
4. Reject changes to `hwmon_name` or `thermal_zone`. These targets require a
   service restart.
5. For every other accepted non-Disabled candidate, refresh hardware discovery
   and rebuild the kernel policy.
6. Prepare affected derived state.
7. Commit active values only after all checks succeed.
8. Apply selective state resets.

Failure preserves the complete previous runtime configuration and hardware
paths. `configuration_state` separately reports that the disk config is
invalid or unapplied.

### Transitions

Control to Kernel evaluates and applies one handoff, resets control-only state,
then continues in read-only observe role.

Kernel to control confirms writable PWM, resets relevant control state, and
begins control on the next cycle.

Active to Disabled performs handoff when leaving control, removes status and
lock, and exits.

## Stop and crash behavior

`TERM` and `INT` request a clean stop at a loop boundary. A clean stop:

1. completes the current required operation
2. performs policy handoff when controlling
3. removes the lock and live status
4. emits one stop event
5. exits.

Signal handling is idempotent. The daemon never claims handoff after an
untrappable crash. The design relies on the target kernel PWM-fan implementation
resuming thermal control after process disappearance; that behavior is a
platform assumption and requires device validation.

## Hardware discovery

`hardware_discover` finds exactly one configured PWM hwmon device and exactly
one configured thermal zone, matches the relevant cooling device, resolves the
fan and thermal DTS nodes, and detects tachometer availability.

Ambiguous matches fail rather than selecting an arbitrary path. A failed
refresh preserves the previous complete valid hardware state. After a live path
failure, rediscovery is retried no more frequently than every ten monotonic
seconds.

## DTS policy normalization

`policy_build` reads:

- fan `cooling-levels`
- thermal cooling maps
- trip temperatures and hysteresis
- referenced cooling states.

It produces ordered points:

```text
trip_temperature_millic
hysteresis_millic
release_temperature_millic
state
pwm
```

where release temperature is trip minus hysteresis.

Validation ensures every referenced state exists, every state maps to a raw
DTS cooling level, cooling state never decreases with increasing temperature,
trip order is valid, and duplicates are normalized deterministically. Raw PWM
levels may be monotonically ascending or descending. Mixed/non-monotonic raw
levels are rejected because their cooling direction is ambiguous.

## Live kernel floor

`policy_floor_reset` initializes evaluator state with one documented
conservative rule when startup occurs inside a hysteresis band.

`policy_floor_update CPU_MILLIC` advances or releases states using normalized
trip and release temperatures and previous evaluator state. It sets:

```text
POLICY_STATE
POLICY_FLOOR_PWM
```

The evaluator never reads `cur_state`. Every mode uses raw CPU temperature for
the floor, regardless of modem selection or filtering. It also exposes a
normalized cooling demand so userspace arbitration and fan supervision remain
correct when raw PWM polarity is descending.

## PWM application

`pwm_apply_verified TARGET_PWM` is the only normal write path:

1. Read actual PWM.
2. Return success if already equal.
3. Write the raw target.
4. Read back actual PWM.
5. Retry the target once when unequal.
6. Return success or failure.

It updates:

```text
HW_REQUESTED_PWM
HW_ACTUAL_PWM
HW_PWM_STATE
```

`pwm_force_full` receives the strongest raw PWM derived from the validated
maximum cooling state; it never assumes that raw `255` means full cooling.
`policy_handoff` uses already loaded hardware and policy and never rediscovers
or reparses DTS.

## Temperature selection and filtering

CPU temperature is required in every running role. Optional Wi-Fi and modem
temperatures never substitute for CPU health.

Auto and Curve use:

```text
selected_temperature_millic =
    max(cpu_temperature_millic,
        available wifi_temperature_millic,
        fresh modem_temperature_millic)

temperature_filter_update selected_temperature_millic
control_temperature_millic = FILTER_OUTPUT_MILLIC
```

`none` returns the current input and clears buffered readings. `median` keeps
timestamped readings for the selected 5, 10, or 15-second duration. It returns
the median of the readings that remain in that duration.

Filtering resets when Auto or Curve starts. It also resets when the filter,
control interval, Wi-Fi source, modem source, modem endpoint, or modem interval
changes. Temporary optional-source loss does not reset the buffer. Kernel and Manual bypass
selection and filtering.

## Auto PID

Auto uses normalized internal output from `0.0` to `1.0`:

```text
error = control_temperature - target
if PID is idle and control_temperature <= target:
    requested_output = 0
if PID is idle and control_temperature > target:
    PID becomes active
if PID is active and control_temperature <= target - 2 C:
    PID becomes idle and resets its state
if PID is active:
    P = Kp * error
    D = Kd * temperature_rate
    candidate_I = clamp(I + Ki * error * dt, 0, integral_limit)
    requested_output = clamp(P + candidate_I + D, 0, 1.0)
```

The PID does not calculate P, I, or D while it is idle. Idle requests zero
userspace output. The kernel thermal floor can still request fan output.

Auto starts the PID when the temperature increases past the target. The active
PID remains active until the temperature decreases to `target - 2 C`.

The active PID can decrease output between the target and the idle threshold.
When the PID enters idle, it resets the integral and derivative state.

Negative error decreases the integral toward zero and never below zero.
Positive accumulation stops while the existing output is saturated. The
configured integral limit remains an independent limit.

Entering Auto, changing PID settings, or an excessive sample gap resets the PID
state. Auto never imports PWM or integral state from another mode.

The final normalized output is retained as cooling demand until kernel-floor
arbitration, then converted once to direction-aware raw PWM. Control does not
convert through an intermediate rounded percentage.

## Curve

Curve uses the same selected and filtered temperature as Auto. Configured
percentages are converted to normalized 0..255 cooling demand when configuration
becomes active; raw PWM conversion occurs only after floor arbitration.

Step mode retains hysteresis without reducing below the appropriate requested
point. Smooth mode initially retains the monotone shape-preserving interpolation
already used by the application and never overshoots adjacent points.

Curve state resets only when mode, curve, filter, or modem selection changes.

## Manual

Manual converts the configured percentage to normalized 0..255 cooling demand
on activation. Optional modem monitoring continues, but Manual does not use
modem temperature for fan output and does not select or filter temperature. It
still reads raw CPU
temperature and enforces the DTS floor.

At timeout:

1. call `config-set mode kernel`
2. perform policy handoff
3. transition directly to Kernel observe role.

If the config write fails, remain in the current safe Manual role and report
the failure. Runtime and disk modes must not be allowed to diverge silently.

## Modem acquisition

Supported sources are QManager public HTTP and direct Quectel AT.

The HTTP source supports these projects:

- [QManager](https://github.com/dr-dolomite/QManager)
- [QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N)

The controller keeps this modem state:

```text
MODEM_TEMPERATURE_MILLIC
MODEM_SAMPLED_UPTIME
MODEM_STATE
```

Transactions have a five-second timeout and a 64 KiB input limit. QManager JSON
is parsed once by one `jsonfilter` process. That process extracts `state`,
`modem_reachable`, and `temperature` into three newline-separated records. The
controller checks the record count before it reads the records. The later
`sed` calls read the extracted text file; they do not parse the JSON again.

The QManager public endpoint is an allowlisted projection of its status cache.
It can contain network and signal data in addition to the three fields above.
The controller ignores all other fields. Both supported QManager variants use
the same endpoint path and field names.

The controller starts the request with HTTP. Current RM520N QManager
installations redirect HTTP to HTTPS and use a local self-signed certificate.
`uclient-fetch` follows the redirect with certificate checking disabled. The
controller can cache a successful AT serial setup until a request fails.
Parsers return facts and do not log events.

The modem sampler runs as a separate procd instance. It makes bounded HTTP or
AT requests and atomically publishes successful readings to a private runtime
file. The controller never starts a modem request and never waits for one.

A reading stays fresh for two configured modem intervals. The controller uses
CPU temperature immediately when no fresh modem reading exists. Loss after
availability emits one transition. Recovery emits one transition. Disabled
mode does not run the modem sampler.

## Fan watchdog

```text
fan_watch_update NOW EXPECTED_PWM ACTUAL_PWM PWM_STATE RPM TACH_STATE
```

returns one state:

```text
idle
spinup
running
fan_failed
pwm_not_applied
pwm_unavailable
tach_unavailable
tach_read_error
```

It distinguishes a requested PWM that was not applied from an applied output
with zero RPM. Missing tachometer and failed tachometer reads are separate.

Zero normalized cooling demand with zero RPM is healthy, regardless of raw PWM
polarity. Above the configured normalized running threshold, the watchdog
provides a monotonic spin-up allowance and requires consecutive valid zero-RPM
samples before it declares `fan_failed`. Expected and actual raw PWM are first
converted to cooling demand. The watchdog calculates state only; the daemon
owns fail-safe reactions and transition logging.

## Ordered runtime cycle

One cycle is:

```text
now = monotonic_now()

telemetry_read(cpu, actual_pwm, rpm)
policy_floor_update(raw_cpu_temperature)

if role == control:
    if mode == Auto:
        select CPU and fresh modem
        update shared filter
        calculate requested_demand with PID
    else if mode == Curve:
        select CPU and fresh modem
        update shared filter
        calculate requested_demand from curve
    else if mode == Manual:
        requested_demand = configured manual cooling demand

    effective_demand = max(requested_demand, kernel_floor_demand)
    requested_pwm = direction_to_raw(requested_demand)
    effective_pwm = direction_to_raw(effective_demand)
    pwm_apply_verified(effective_pwm)

fan_watch_update(now, expected_demand, actual_demand, pwm_state, rpm, tach_state)
apply fail-safe reaction when required

snapshot = build current state once
write status every cycle
append the same snapshot to history if due
sleep until the absolute next deadline
```

The separate modem sampler publishes optional data. Its work cannot delay this
cycle.

## Failure behavior

### Required CPU or policy failure

An unsupported policy detected before userspace takes ownership starts the
read-only Kernel monitoring fallback and performs no PWM write. In an
established control role, loss of required CPU or policy data attempts the
strongest output from the last validated policy, publishes an explicit failure,
and retries discovery with ten-second backoff. Kernel observe publishes the
failure without userspace PWM writes after handoff.

### PWM write failure

Attempt full output once, mark output unvalidated, publish the fault, and retry
bounded recovery on later cycles. Recovery requires confirmed successful
application and is logged once.

### Fan failure

In a control role, request full output and preserve the confirmed fan fault
until valid RPM recovery. Kernel observe supervises RPM against the normalized
actual applied output without writing PWM; it does not claim that `cur_state`
or the evaluated floor was applied by the kernel.

### Optional modem failure

Expire the sample and use CPU only. It never triggers the global fan fail-safe.

### History failure

Set `history_state`, log one transition, and retry later. Cooling, watchdog,
status, and service lifecycle continue.

## Runtime status

The daemon atomically writes `/var/run/pwm-fan-control/status.json` with:

```text
contract_version
process_id
timestamp
started_uptime
updated_uptime
controller_running
controller_fresh
configured_mode
active_mode
curve_style
temperature_filter
temperature_filter_duration_s
tach_enabled
wifi_source
modem_source
modem_http_host
modem_at_device
modem_interval_s
hwmon_name
thermal_zone
tachometer_available
runtime_role
configuration_state
configuration_diagnostics (status-json envelope)
hardware_state
control_state
control_reason
history_state
cpu_temperature_millic
wifi_temperature_millic
wifi_temperature_source
wifi_state
wifi_sensors
modem_temperature_millic
selected_temperature_source
selected_temperature_millic
filtered_temperature_millic
requested_pwm
kernel_policy_direction
kernel_strongest_pwm
kernel_floor_state
kernel_floor_pwm
effective_pwm
actual_pwm
rpm
tach_state
fan_state
modem_state
health
pid
```

Auto status sets `pid.state` to `active` or `idle`. The PID object does not
contain a configurable idle margin.

Kernel status has null `requested_pwm` and `effective_pwm`. The monitor-only
fallback additionally has null policy direction, strongest output, and kernel
floor fields because no policy was validated. It continues to publish actual
PWM, CPU temperature, optional RPM, and history. Manual status has null selected
and filtered temperatures while retaining optional modem telemetry. Disabled
has no live snapshot.
`config_revision` is never included.

`configured_mode`, `configuration_state`, and configuration diagnostics describe
the file currently on disk. `active_mode` and runtime telemetry describe the
fresh daemon snapshot. A rejected reload can therefore expose invalid saved
configuration while continuing to publish the previous healthy active mode.

`status-json` returns a deterministic Disabled result without probing, merges
disk configuration state into a fresh snapshot, or returns explicit
stopped/stale state. Requested output, PID data, and modem data from a stopped
or stale daemon are never returned as current. The read-only probe supplies
current hardware PWM and CPU telemetry independently.

## History

The daemon owns `/var/run/pwm-fan-control/history.tsv`. Every record is the current
runtime snapshot and contains twelve tab-separated fields. The first ten retain
the version-1 layout; Wi-Fi fields are appended for compatibility:

```text
timestamp mode cpu_temperature_millic modem_temperature_millic requested_pwm
kernel_floor_pwm effective_pwm actual_pwm rpm fan_state
wifi_temperature_millic selected_temperature_source
```

The normalizer accepts legacy ten-field rows and new twelve-field rows.
Unavailable values are literal `null`. One record is appended every 60
monotonic seconds in Kernel, Auto, Curve, and Manual. Disabled adds none.

Append and clear share one `mkdir` lock. After append, malformed rows are
discarded and the newest 1,440 valid records are atomically retained. History
survives daemon restart and mode transition but is cleared by reboot.

## Logging

Significant transitions use `logger -t pwm-fan-control` with bounded structured
fields. The public stopped-fan event is `fan_stopped`. `fan_failed` remains an
internal fan-watch state:

```text
level=error code=fan_stopped expected_pwm=128 rpm=0
```

The controller logs each start, stop, reload, mode transition, and config
rejection once. The controller also logs each failure and recovery transition
once. Repeated cycle failures update status without flooding logd.

## Implementation constraints

- BusyBox `/bin/sh` only.
- No `eval`, sourced config, Bash arrays, or process substitution.
- Bounded files, payloads, diagnostics, loops, locks, and retries.
- Shared library functions have no top-level side effects.
- Hardware discovery and probe perform no writes.
- Required cooling precedes optional work.
- One implementation owns each safety-critical behavior.
