# brew-thermostat

A fail-safe thermostat for a kombucha fermentation vessel, built from two Tasmota
devices talking directly to each other. No custom hardware, no code running on a
server, and no dependency on Home Assistant or MQTT for the control loop.

A DS18B20 sensor multicasts its temperature to a smart plug over the LAN. The plug
decides for itself whether to switch a 25W brew belt on, and — crucially — switches
itself **off** if the readings ever stop arriving.

## Status

Verified working on real hardware, and driving the brew belt against a live vessel
since 2026-07-18. In steady state the belt pulses for ~10 minutes roughly every 2-3
hours to hold the vessel near setpoint, cutting out correctly at the off threshold. The
deadband (now 1.5C) does not cause relay chatter.

Note the probe reads the glass ~8cm above the belt, and the glass leads the bulk liquid
by around 1C — so the liquid runs slightly below the 24C target. This is expected and
fine for kombucha (it brews well from 21C); see the dashboard notes if you want to
compensate.

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
| Heat off above | 25.0C | Widened from 24.5C on 2026-07-26 to reduce relay cycling |
| Hard cutoff | 30C | Well clear of ~35C, which kills the SCOBY |
| Sanity floor | 5C | Anything at or below this is treated as a broken sensor |
| Sanity ceiling | 40C | Anything above is treated as a broken sensor |
| Failsafe timeout | 600s (10 min) | No readings for 10 minutes ⇒ heat off |
| Sensor telemetry | 60s | Ten heartbeats per failsafe window |

The deadband is 1.5C (widened from an initial 1C). A 25W belt heating a large, slow
thermal mass produces long, lazy cycles; it has not caused relay chatter.

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
Rule2 ON Event#s2>30 DO Backlog Var4 0; Power1 off ENDON ON Event#s2<23.5 DO Backlog Var4 1; Power1 on ENDON ON Event#s2>25 DO Backlog Var4 0; Power1 off ENDON ON Event#s2>0 DO RuleTimer1 1 ENDON ON Rules#Timer=1 DO Event hb=%var4% ENDON ON Event#hb>0 DO Power1 on ENDON
Rule1 1
Rule2 1
Restart 1
```

`SetOption85` does not take effect until the device restarts. Both devices need it.

A working snapshot of this configuration is captured in
[`config/captured-config.txt`](config/captured-config.txt).

## The configuration commands, annotated

The rules are explained further down; these are the non-rule setup commands.

| Command | What it does |
|---|---|
| `DevGroupName1 brew` | Puts the device in device group **1**, named `brew`. Both devices must use the **exact same, case-sensitive** name to talk to each other. The `1` is the group slot (a device can be in up to four groups); it is unrelated to the item number `192` used in the rule. |
| `DevGroupShare 64,64` | Selects which kinds of item this device will **receive,send** over the group, as a bitmask. `64` is the `Event` bit — the only thing we share. Sharing everything (the default) would also sync power state, so if you toggled the plug's relay the sensor would try to follow; restricting to `64` prevents that. **Gotcha:** it reports back in hex, so `64,64` reads as `40,40`. See the gotchas section. |
| `SetOption85 1` | Master switch for the whole device-groups feature. Off by default. **Needs a restart** before it takes effect — setting it alone does nothing. Required on both devices. |
| `TelePeriod 60` | How often (seconds) the sensor emits the telemetry reading that triggers its broadcast rule. This is the **heartbeat rate**, and it must stay well under the plug's `PulseTime` window — see the failsafe section. Only meaningful on the sensor; the plug's own `TelePeriod` is just housekeeping. |
| `PowerOnState 0` | On the plug: boot the relay **off**. The default (`1`) would switch the belt on at power-up, so a power cut would leave it heating unattended until the first reading arrived. Safety setting — see the failsafe section. |
| `PulseTime1 700` | The failsafe. `700` = 600 seconds. Fully explained under "The failsafe" below — it is the single most important line in the setup. |
| `Restart 1` | Reboots the device, which is what actually activates `SetOption85`. |

One relevant `SetOption` we **leave alone**: `SetOption19` is **off** on both devices.
That is correct for Home Assistant's native Tasmota integration; turning it on switches
to the deprecated legacy MQTT auto-discovery. See the Home Assistant section.

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

### Plug Rule2 — hysteresis, cutoff, and heartbeat

```
ON Event#s2>30   DO Backlog Var4 0; Power1 off ENDON
ON Event#s2<23.5 DO Backlog Var4 1; Power1 on  ENDON
ON Event#s2>25   DO Backlog Var4 0; Power1 off ENDON
ON Event#s2>0    DO RuleTimer1 1 ENDON
ON Rules#Timer=1 DO Event hb=%var4% ENDON
ON Event#hb>0    DO Power1 on ENDON
```

`Var4` is a **software latch**: `1` means "the belt should be heating", `0` means it
should not. It is the memory that lets the deadband work without starving the failsafe
(see below for why that matters).

| Line | Meaning |
|---|---|
| `ON Event#s2>30 DO Backlog Var4 0; Power1 off` | Hard safety cutoff, checked before anything else. Clears the latch and cuts power. Redundant with the `>25` line for *turning off*, but kept as a separate, explicit safety limit so tuning the setpoint can never accidentally disable it. |
| `ON Event#s2<23.5 DO Backlog Var4 1; Power1 on` | Too cold — set the latch and heat. |
| `ON Event#s2>25 DO Backlog Var4 0; Power1 off` | Warm enough — clear the latch and stop. |
| `ON Event#s2>0 DO RuleTimer1 1` | **Every** valid reading arms a 1-second timer. (Temperature is always > 0 after the `>5` sanity gate, so this fires on every reading.) |
| `ON Rules#Timer=1 DO Event hb=%var4%` | When that timer expires, emit a heartbeat event carrying the current latch value. The 1-second delay is essential: it lets the `Backlog Var4 ...` from the decision lines commit *before* the latch is read, avoiding a race. |
| `ON Event#hb>0 DO Power1 on` | If the latch is set, re-issue `Power on`. This refreshes the `PulseTime` countdown (see below) without changing the relay if it is already on. |

Between 23.5 and 25.0 **no on/off decision fires**, and the relay keeps its current state.
That gap *is* the deadband: it is what stops the relay chattering around the setpoint. A
reading of 24.0 doing nothing to the relay is correct. **But** the heartbeat lines still
run on every reading, so while the belt is heating through the deadband the `PulseTime`
countdown keeps being refreshed. This is the fix for a bug where the belt cut out every
~10 minutes — see "The heartbeat starvation bug" in the gotchas.

Cooling back down does not re-fire the belt: once the `>25` line clears the latch, a
reading of 24.9 on the way down leaves it cleared (`hb>0` is false), so the belt stays off
until the temperature falls below 23.5. The latch does not survive a reboot — it comes
back empty (0), so a power cut boots the belt off and keeps it off until a genuine
below-23.5 reading, complementing `PowerOnState 0`.

The off threshold was widened from 24.5 to 25.0 on 2026-07-26 to cut the number of relay
cycles (about 13/day) as the weather cooled. A wider deadband means fewer, longer pulses
for the same total heat. Because the glass probe leads the bulk liquid, letting the glass
run a little warmer also nudges the liquid closer to the 24C target.

Rule1 and Rule2 are split because a single rule set is limited to 511 bytes, and because
it keeps "is this reading real?" separate from "what should the heat do?".

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
already on restarts the countdown.** The heartbeat lines in Rule2 do exactly that on
every reading while the belt should be heating (whether the reading is below the on
threshold or sitting in the deadband). As long as readings keep arriving, the countdown
never expires. The moment they stop — dead sensor, dead WiFi, dead broker, crashed HA —
the countdown runs out and the plug switches itself off.

It is a dead-man's switch: the heat stays on only while something keeps actively
asking for it.

**What `PulseTime` does and does not protect against.** It is a *communication*
watchdog: it fires when readings *stop*. It is **not** a thermal-runaway limit. If the
sensor keeps producing plausible-but-wrong low readings — e.g. it falls off the vessel
and measures cooler room air, or the belt is fitted outside the insulation so the glass
never warms — the rule correctly says "heat", the heartbeat keeps arriving, and the belt
stays on. Lengthening `PulseTime` would not help; the readings are valid, just wrong. A
single-sensor thermostat cannot defend against its one sensor lying plausibly. The `>30`
cutoff is a partial backstop, and physical mitigations (the insulation presses the probe
against the glass so it cannot dangle) matter more here than any rule.

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

### The heartbeat starvation bug (a deadband can starve the failsafe)

This one ran undetected for over a week and is the reason Rule2 looks the way it does.

The failsafe (`PulseTime`) and the thermostat originally shared one signal: `Power on`.
The heartbeat was only refreshed by the "too cold" line (`Event#s2<23.5 DO Power1 on`).
That is fine while the belt is warming from below the setpoint — but the moment the
temperature climbs into the deadband (23.5–25.0), **no rule fired**, so no `Power on` was
issued, so the heartbeat stopped being refreshed *even though readings were still
arriving every 60s*. After 600s the firmware cut the belt.

The symptom was maddening: the belt appeared to "turn off at 24.5C" with **no rule
trigger in the plug's log** — because it was the watchdog timing out, not a threshold.
Widening the off threshold did nothing, because the belt never reached it; it timed out
first. Every pulse was capped at ~10 minutes regardless of temperature. It only became
visible when cooler weather made the heating phase long enough to sit in the deadband
past the 600s window.

The fix (deployed 2026-07-27): a software latch (`Var4`) remembers "the belt should be
heating", and dedicated heartbeat lines re-issue `Power on` on **every** reading while
the latch is set — refreshing the countdown through the deadband without re-triggering
the relay. The lesson: **if a failsafe heartbeat is driven by a control rule, make sure
the heartbeat still fires in the states where the control rule is deliberately silent.**
A deadband is exactly such a state.

Watch out for the evaluation-order race, too: the heartbeat reads the latch via
`Event hb=%var4%`, and that `%var4%` must be expanded *after* the decision lines have
committed their `Backlog Var4 ...`. Emitting the heartbeat through a 1-second `RuleTimer`
guarantees this; firing it inline in the same reading-pass reads the stale latch and, at
the off transition, cancels the power-off.

### The belt has its own internal cutout — 0W with the relay ON is normal

The brew belt contains its **own** thermal cutout (a bimetallic switch), independent of
anything in this project. So while our relay is ON, the belt self-cycles: it draws its
normal ~32W for roughly a minute, its internal cutout opens, it draws **0W for roughly a
minute**, then closes again — repeating on a ~1–2 minute period for the whole time our
relay holds it on. An owner review of the belt confirms it: *"It does turn itself on and
off perhaps every few minutes."*

This is **not a fault.** But it looks exactly like one, and it caused a genuine scare:
- `watts` (or `Status 8` Current/Power) drops to a clean **0.000 A / 0 W** while `relay`
  stays **ON**, and the `ENERGY.Today` counter **freezes** during those windows. That is
  indistinguishable, from the electrical data alone, from an intermittent open circuit
  (a failing lead or connection). The tell that it is the belt's cutout and not a fault:
  the **glass temperature keeps rising** across the 0W stretch, and the current is a clean
  full-on/full-off (0.125A / 0.000A), never a marginal in-between.
- It is only visible if you sample **faster than the belt's cycle** — every few seconds.
  Coarser sampling (the Grafana dashboard's 30–60s steps) aliases the cycling into what
  looks like a steady 32W, which is why we thought the belt drew constant power for weeks.

Consequence for the design: there are effectively **two thermostats in series** — the
belt's crude internal one (cycling on its own surface temperature, ~1 min period) and
ours (cycling on the glass probe, hours-long period). They do not fight: ours gates the
mains supply and sets the setpoint; the belt's cutout just makes delivery gentler and
self-limiting within each of our ON windows. It also partly explains the "hot fast then
cooler while powered" feel of the belt — that is partly the glass-vs-liquid gradient and
partly the belt genuinely cycling its own output.

If you ever *do* suspect a real intermittent connection (arcing at a joint is a genuine
mains hazard), the distinguishing check is: a real open circuit will **not** show the
temperature still climbing, and will often show erratic/partial current rather than a
clean 0.000A on a regular ~1-minute rhythm.

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
