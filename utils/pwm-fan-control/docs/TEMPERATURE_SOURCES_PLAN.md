# Optional Wi-Fi temperature source

This document defines the Wi-Fi temperature-source extension. The general
configuration and runtime contracts remain in [`CONFIGURATION.md`](CONFIGURATION.md)
and [`CONTROLLER.md`](CONTROLLER.md).

## Goal

Extend the existing control input:

```text
max(CPU, fresh optional Modem)
```

with one optional Wi-Fi input:

```text
max(CPU, available optional Wi-Fi, fresh optional Modem)
```

CPU remains mandatory and always participates in Auto and Curve. The raw CPU
reading also continues to evaluate the device-tree kernel cooling floor.
Kernel remains read-only after handoff, and Manual retains fixed userspace
output. Those modes may monitor Wi-Fi temperature but do not use it to calculate
output.

## Configuration

Add one setting without changing the configuration format version:

| Key | Accepted value | Default |
|---|---|---|
| `wifi_source` | `off`, `auto`, or one supported MediaTek stable hwmon name | `off` |

The existing missing-key-default behavior makes old configurations operational
with Wi-Fi disabled. The next successful Save or Save & Apply renders the new
key. No migration rewrites an existing conffile merely because the key is
missing.

Meanings:

- `off`: do not discover or sample Wi-Fi temperatures in the daemon
- `auto`: discover supported Wi-Fi hwmon sensors and use the hottest available
  reading
- exact name, for example `mt7915_phy1`: discover exactly one matching hwmon
  device and use its `temp1_input`.

Configuration stores the stable content of the hwmon `name` file. It never
stores `/sys/class/hwmon/hwmonN` paths.

## Discovery

The controller performs bounded enumeration of `/sys/class/hwmon/hwmon*` and
reads `name` plus `temp1_input`.

The read-only probe returns supported Wi-Fi temperature candidates with:

```text
name
temperature_millic
available
selected
```

For exact-name mode, zero matches is unavailable and more than one match is
ambiguous. For `auto`, every supported unique Wi-Fi sensor is a candidate and
the hottest valid current reading becomes the Wi-Fi group value. Detection must
recognize MT7915 names such as `mt7915_phy0` and `mt7915_phy1`; adding other
wireless drivers later requires explicit fixtures rather than treating every
hwmon temperature as Wi-Fi.

Probe discovery is read-only. It never changes saved selection, writes PWM, or
starts a service.

## Runtime selection

CPU and enabled Wi-Fi sensors are read once per controller cycle. Modem retains
its separate bounded sampler and existing freshness deadline.

```text
wifi_temperature =
    exact selected sensor
    or max(valid auto-discovered Wi-Fi sensors)

selected_temperature =
    max(cpu_temperature, available wifi_temperature,
        fresh modem_temperature)
```

`selected_temperature_source` identifies the exact winner:

```text
cpu
wifi:mt7915_phy0
wifi:mt7915_phy1
modem
```

Equal readings use a deterministic winner: CPU, then Wi-Fi names in bytewise
order, then Modem. The winner enters the existing shared filter once. Temporary
Wi-Fi loss does not reset the filter while CPU remains available.

Changing `wifi_source` refreshes hardware discovery and resets filter, Curve
hysteresis, and PID state at the safe reload boundary. It does not require a
service restart.

## Availability and safety

Wi-Fi is optional, like Modem:

- unavailable, unreadable, implausible, or ambiguous Wi-Fi data is excluded
- CPU continues controlling Auto and Curve
- Wi-Fi health reports the problem without substituting zero
- transition and recovery events are emitted once, not every cycle.

CPU failure remains a required hardware failure and invokes the existing
strongest-output reaction. Enabling Wi-Fi does not weaken CPU health or the
kernel floor.

In exact-name mode, a missing configured sensor remains configured and is
reported unavailable. In `auto`, supported sensors may appear or disappear;
the status always identifies which exact sensor currently supplies the Wi-Fi
value.

## Status and history

Fresh daemon status adds:

```text
wifi_source
wifi_temperature_millic
wifi_temperature_source
wifi_state
wifi_sensors[]
```

Each bounded sensor entry contains stable name, current temperature or null,
availability, and whether it currently supplies the Wi-Fi group value.
Existing `selected_temperature_source`, `selected_temperature_millic`, and
`filtered_temperature_millic` retain their meanings.

The next history format adds the Wi-Fi group temperature and exact selected
source. The rpcd/history parser accepts old and new rows during upgrade; added
fields are null for old rows. The browser never reconstructs the winner by
comparing historical series.

## Logging

New events are transitions:

- `wifi_temperature_unavailable source=...`
- `wifi_temperature_recovered source=...`

Persistent details remain in status rather than flooding `logd`.

## Verification requirements

Source tests cover:

- disabled Wi-Fi preserving existing CPU/Modem behavior
- changing `hwmonN` indices with stable `mt7915_phy0`/`mt7915_phy1` names
- exact source selection
- automatic hottest-radio selection
- CPU, Wi-Fi, and Modem hottest-value arbitration
- deterministic ties
- missing, duplicate, malformed, and recovered Wi-Fi sensors
- CPU failure remaining fail-safe while Wi-Fi is healthy
- Kernel and Manual control behavior remaining unchanged.
