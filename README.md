# brew-thermostat

A fail-safe thermostat for a kombucha fermentation vessel, built from two Tasmota
devices talking directly to each other. No custom hardware, no code running on a
server, and no dependency on Home Assistant or MQTT for the control loop.

A DS18B20 sensor multicasts its temperature to a smart plug over the LAN. The plug
decides for itself whether to switch a 25W brew belt on, and — crucially — switches
itself **off** if the readings ever stop arriving.

## Status

Verified working on real hardware on 2026-07-16, with one caveat: the brew belt had
not yet arrived, so the loop has been proven end-to-end but has never actually driven
a heater. The first real heating cycle is still pending.

## Hardware

| Role | Name | IP | Chip | Firmware | Notes |
|---|---|---|---|---|---|
| Sensor | `temp-probe` | 192.168.0.64 | ESP32 | 15.5.0 | DS18B20, has Berry |
| Plug | `tasmota2` | 192.168.0.58 | ESP8285 | 15.5.0 | Energy monitoring, **no Berry** |

The plug has no Berry scripting compiled in, so all plug-side logic must be written
with the Rules engine. This is the single biggest constraint on the design.

Other Tasmota devices on this LAN are in use — `.57`, `.62`, `.32`, `.53`, `.52`, `.89`.
Leave them alone.

Broker: `192.168.0.2:1883`, user `tasmota`. Home Assistant runs on the same host.

## Setpoints

| Parameter | Value | Reason |
|---|---|---|
| Target | 24C | Ideal kombucha fermentation |
| Heat on below | 23.5C | Target minus half the deadband |
| Heat off above | 24.5C | Target plus half the deadband |
| Hard cutoff | 30C | Well clear of ~35C, which kills the SCOBY |
| Sanity floor | 5C | Anything at or below this is treated as a broken sensor |
| Sanity ceiling | 40C | Anything above is treated as a broken sensor |
| Failsafe timeout | 600s (10 min) | No readings for 10 minutes ⇒ heat off |
| Sensor telemetry | 60s | Ten heartbeats per failsafe window |

The 1C deadband is a starting guess. A 25W belt heating a large, slow thermal mass
should produce long, lazy cycles; if the relay turns out to chatter, widen it.

## How it works

```
  DS18B20                Device Groups                   Relay
  ┌────────────┐         (UDP multicast)         ┌──────────────────┐
  │ temp-probe │ ──── brewtemp=23.4 ──────────►  │    tasmota2      │
  │  (ESP32)   │        every 60s                │   (ESP8285)      │
  └────────────┘                                 │                  │
                                                 │  Rule1: sanity   │
                                                 │  Rule2: hysteresis
                                                 │  PulseTime: 600s │
                                                 └────────┬─────────┘
                                                          │
                                                    25W brew belt
```

There are three independent layers of protection, and each one distrusts the layer
above it:

1. **Sanity gate** — a reading must look like a real temperature before it is allowed
   to influence anything.
2. **Hysteresis + hard cutoff** — decides heat on/off, and refuses to heat above 30C.
3. **`PulseTime` failsafe** — implemented in the plug's own firmware. If readings stop
   for any reason at all, the relay switches itself off without needing to be told.

Layer 3 is the one that matters. It runs on the plug, so it still works when the WiFi
is down, the broker is down, Home Assistant is down, or the sensor is unplugged. This
is why the fail-safe requirement could not have been met with a Home Assistant
automation.

## Setup from scratch

Type these into the Tasmota console of each device (**Consoles → Console** in the web
UI), or via `http://<ip>/cm?cmnd=<command>`.

### On the sensor (192.168.0.64)

```
DevGroupName1 brew
DevGroupShare 64,64
SetOption85 1
TelePeriod 60
Rule1 ON Tele-DS18B20#Temperature DO DevGroupSend1 192=brewtemp=%value% ENDON
Rule1 1
Restart 1
```

### On the plug (192.168.0.58)

```
DevGroupName1 brew
DevGroupShare 64,64
SetOption85 1
PowerOnState 0
PulseTime1 700
Rule1 ON Event#brewtemp DO Backlog Var1 %value%; Event s1=%value% ENDON ON Event#s1>5 DO Event s2=%value% ENDON ON Event#s2>40 DO Power1 off ENDON
Rule2 ON Event#s2>30 DO Power1 off ENDON ON Event#s2<23.5 DO Power1 on ENDON ON Event#s2>24.5 DO Power1 off ENDON
Rule1 1
Rule2 1
Restart 1
```

`SetOption85` does not take effect until the device restarts. Both devices need it.

A working snapshot of this configuration is captured in
[`config/captured-config.txt`](config/captured-config.txt).

## The rules, annotated

### Sensor rule

```
Rule1 ON Tele-DS18B20#Temperature DO DevGroupSend1 192=brewtemp=%value% ENDON
```

| Fragment | Meaning |
|---|---|
| `ON ... DO ... ENDON` | Tasmota rule syntax: a trigger and an action. |
| `Tele-DS18B20#Temperature` | Fires on each **telemetry** reading of the DS18B20's temperature. The `Tele-` prefix means the periodic report (every `TelePeriod` seconds), not an instantaneous poll. |
| `DevGroupSend1` | Broadcast to device group **1** (the one named `brew`). |
| `192=` | Item 192 is `DGR_ITEM_EVENT` — see the gotchas below. It carries an arbitrary string to every group member. |
| `brewtemp=%value%` | The payload. `%value%` expands to the temperature that triggered the rule. On the receiving devices this fires an event named `brewtemp` with that value. |

So: every 60 seconds, "here is the temperature" goes out to the group.

### Plug Rule1 — sanity gate

```
ON Event#brewtemp DO Backlog Var1 %value%; Event s1=%value% ENDON
ON Event#s1>5      DO Event s2=%value%                          ENDON
ON Event#s2>40     DO Power1 off                                ENDON
```

| Line | Meaning |
|---|---|
| `ON Event#brewtemp` | Catches the event broadcast by the sensor. |
| `Backlog A; B` | Runs two commands in sequence. |
| `Var1 %value%` | Stashes the reading in variable 1. **Nothing reads `Var1`** — it exists purely so the last reading is visible in the console and in Home Assistant. It is observability, not logic. |
| `Event s1=%value%` | Re-fires the value as a *new* event named `s1`, passing it to the next stage. This chaining is how a multi-step decision is built. |
| `ON Event#s1>5` | **The sanity gate.** Only a value above 5C is passed on to `s2`. Junk, an empty payload, and the DS18B20's `-127` error value all fail this test and stop here — so they can never reach the heating logic. |
| `ON Event#s2>40` | Above 40C is not a plausible brew temperature, so treat it as a broken sensor (the DS18B20 reports `85` on error) and cut the power. |

The gate is a **whitelist**, not a blacklist. Only a plausible value earns the right to
make a decision; everything else falls through to the safe state. This is deliberate,
and the reason why is in the gotchas.

### Plug Rule2 — hysteresis and cutoff

```
ON Event#s2>30   DO Power1 off ENDON
ON Event#s2<23.5 DO Power1 on  ENDON
ON Event#s2>24.5 DO Power1 off ENDON
```

| Line | Meaning |
|---|---|
| `ON Event#s2>30 DO Power1 off` | Hard safety cutoff, checked before anything else. |
| `ON Event#s2<23.5 DO Power1 on` | Too cold — heat. This also refreshes the `PulseTime` countdown (see below). |
| `ON Event#s2>24.5 DO Power1 off` | Warm enough — stop. |

Between 23.5 and 24.5 **no rule fires at all**, and the relay simply keeps its current
state. That gap *is* the deadband: it is what stops the relay chattering around the
setpoint. A reading of 24.0 doing nothing is correct behaviour, not a bug.

Rule1 and Rule2 are split because a single rule set is limited to 511 bytes, and
because it keeps "is this reading real?" separate from "what should the heat do?".

### The failsafe

```
PulseTime1 700
```

This is the most important line in the project and the least obvious.

`PulseTime` is normally used to make a relay switch off automatically after a set time
— a stairwell-light timer. Values 112–64900 mean *seconds, offset by 100*, so **700
means 600 seconds**. (Values 1–111 mean tenths of a second, which is why the offset
exists.)

The behaviour that makes it a watchdog: **re-issuing `Power ON` while the relay is
already on restarts the countdown.** So every temperature reading that says "heat"
also refreshes the timer. As long as readings keep arriving, the countdown never
expires. The moment they stop — dead sensor, dead WiFi, dead broker, crashed HA — the
countdown runs out and the plug switches itself off.

It is a dead-man's switch: the heat stays on only while something keeps actively
asking for it.

`PulseTime` survives a reboot, and after a power cut the relay comes back **off** with
the countdown at zero, waiting for a fresh reading.

`PowerOnState 0` complements this: it stops the plug from booting the relay on. Without
it, a power cut would leave the belt heating unattended until the first reading arrived.

## Verifying it works

Watch the loop live:

```bash
watch -n5 'curl -s "http://192.168.0.64/cm?cmnd=Status%2010"; echo; \
           curl -s "http://192.168.0.58/cm?cmnd=Var1"; \
           curl -s "http://192.168.0.58/cm?cmnd=Power"; \
           curl -s "http://192.168.0.58/cm?cmnd=PulseTime1"'
```

A healthy system shows the plug's `Var1` tracking the sensor's temperature, and
`Remaining` sawtoothing — decaying to roughly 640 then jumping back to roughly 680 each
time a reading refreshes it. It never reaches the full 700, because the refresh happens
60 seconds after the last one. If `Remaining` counts steadily down through those values
without ever jumping back up, readings are not arriving.

`Var1` may lag the sensor by one reading (e.g. sensor 18.7, `Var1` 18.8). That is just
the 60-second telemetry beat, not a fault.

Confirm the belt is actually drawing power (the plug meters its own load):

```bash
curl -s "http://192.168.0.58/cm?cmnd=Status%208"
```

`Power` should read ~25W with the belt on, and 0W with it off.

### Testing the failsafe

**Disable the sensor's rule first** (`Rule1 0` on the sensor), or the test is
meaningless — see the gotchas. Then set a short timeout, trigger the heat, and watch:

```bash
curl -s "http://192.168.0.64/cm?cmnd=Rule1%200"          # silence the sensor
curl -s "http://192.168.0.58/cm?cmnd=PulseTime1%20130"   # 30s instead of 600s
curl -s --get "http://192.168.0.58/cm" --data-urlencode "cmnd=Event brewtemp=22.0"
# poll Power and PulseTime1 — the relay should switch itself off after ~30s

curl -s "http://192.168.0.58/cm?cmnd=PulseTime1%20700"   # restore
curl -s "http://192.168.0.64/cm?cmnd=Rule1%201"          # re-arm the sensor
```

## Home Assistant

Both devices already publish to the broker, so temperature, relay state, and the plug's
energy metering surface without extra work. `SetOption19` is **off** on both, which is
correct for HA's native Tasmota integration — do not turn it on unless you have
deliberately switched to legacy MQTT discovery.

Home Assistant is a **spectator**. It is not in the control path, and the thermostat
keeps working correctly with HA switched off entirely.

## Gotchas

Everything below was established empirically, mostly by getting it wrong first. Read
this section before extending the system.

### Device Groups cannot share sensor values, despite the documentation

The Tasmota docs state that device groups share "sensor values". **They do not.** The
`DevGroupItem` enum in `tasmota/include/tasmota.h` contains no temperature or sensor
item — `DGR_ITEM_ANALOG1..5` exist only as commented-out lines where someone started
the feature and abandoned it.

What actually works is `DGR_ITEM_EVENT` (**item 192**), which carries an arbitrary
string to every group member and fires it as an event. Hence `192=brewtemp=%value%`.
`DGR_ITEM_COMMAND` is item 193, matching the docs' `DevGroupSend 193=Buzzer\ 2,3`
example.

The item codes are not listed anywhere convenient; they are derived from the enum's
size boundaries (`DGR_ITEM_MAX_32BIT = 191`, so the first string item is 192).

### `DevGroupShare` reports in hex

Set `64,64` and it reports back `40`. That is not an error: `0x40` = 64 decimal. Set
`1,1` and it reports `1`. Confusing when you are checking your own work.

### Comparison operators parse junk as zero — so `<` is dangerous

`ON Event#x<40` **fires** when `%value%` is `abc` or empty, because a non-numeric
payload parses as `0`, and `0 < 40`. For a heater this is the worst possible failure:
a garbled reading looks like "freezing cold" and switches the belt on.

`ON Event#x>5` correctly rejects `abc`, empty, `-127.0` and `-127`.

**So gate on `>`, never `<`.** Let only a plausible value through and let everything
else fall to the safe state. This is why the sanity check is a positive whitelist.

### Things that are *not* true

Each of these was suspected, tested, and disproved. Don't waste time re-investigating:

- **"Only the first matching trigger per event name fires."** False. Multiple triggers
  can share an event name and all of them evaluate correctly.
- **"`%value%` doesn't survive a `Backlog` chain."** False. It propagates fine into a
  follow-on `Event`.
- **"Decimal thresholds don't work."** False. `>24.5` compares correctly.

### The testing trap that will bite you

Injecting synthetic values with `Event brewtemp=...` **while the sensor's broadcast
rule is armed** produces nonsense. Real readings arrive every 60 seconds and interleave
with the injected ones, overwriting them. This cost real debugging time: a "dead sensor"
test appeared to show the failsafe completely broken, when in fact the sensor was alive
and legitimately re-arming the watchdog throughout.

**Before testing the plug, disable the sensor's rule (`Rule1 0`) and confirm silence**
by checking that the plug's `Var1` stops changing.

Relatedly, a reading that is *rejected* leaves the relay in its previous state. If you
inject `-127` and see the heat still on, that is correct — nothing turned it on, and
the rejected reading is not a heartbeat, so `PulseTime` will kill it. Judge the failsafe
by `Remaining` counting down, not by the immediate relay state.

### `SetOption85` needs a restart

Setting it is not enough; device groups stay inert until the device reboots. Both
devices.

### Keep `TelePeriod` well below the failsafe window

`TelePeriod` is the heartbeat rate. At the default of 300s against a 600s failsafe you
get **two** heartbeats per window, and a single dropped multicast packet risks a
spurious cutout. 60s gives ten. If you ever lengthen `TelePeriod`, lengthen `PulseTime`
to match.

## Possible extensions

- **Cooling.** A second plug in the same device group could drive a fan, using a
  separate event stage and its own deadband.
- **A second sensor.** The plug's ESP8285 has ~370 bytes free in Rule1 and ~400 in
  Rule2; a redundant sensor with disagreement detection would likely need Rule3 or a
  move to a Berry-capable plug.
- **Ramp profiles.** Berry on the sensor (the ESP32 has it) could vary the setpoint over
  a fermentation schedule and broadcast the target alongside the temperature.
- **Alerting.** An HA automation on the plug's `LWT` or on a stale `Var1` would catch
  a failsafe cutout, which is otherwise silent by design.
