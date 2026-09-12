# brew-thermostat

Fail-safe thermostats for kombucha fermentation jars, built entirely from **Tasmota
configuration** on off-the-shelf devices — no custom firmware, no server, and no
dependency on Home Assistant or MQTT for the control loop.

One ESP32-C3 sensor board reads three DS18B20 probes and broadcasts each temperature
over the LAN (Tasmota Device Groups, UDP multicast). Two smart plugs each drive a heater
on a jar — a seedling **mat** and a **belt** — and each plug decides for itself whether
to switch on. Crucially, each plug switches itself **off** if the readings ever stop
arriving, using a failsafe in the plug's own firmware.

> **History:** the project began (Jul 2026) as a single loop — one ESP32 sensor and one
> plug driving one belt. It was rebuilt (Sep 2026) into the two-loop rig described here;
> the original rig is decommissioned. The git history and the gotchas below carry the
> hard-won lessons from that first version — most of which shaped the current design.

## Status

Fully live on real hardware since 2026-09-12: both loops driving real heaters on real
jars (mat on the week-1 jar, belt on the week-2 jar). Each loop holds its jar near
setpoint with long, lazy pulses and a 2.5°C deadband that does not chatter.

The probes read the glass, not the liquid; the glass leads the bulk liquid, so the liquid
runs a little below the glass reading. Fine for kombucha (it brews well from 21°C). With
insulation the steady-state offset is small.

## How the brewing runs

Two ~3 L jars, start days offset by a week, each fermenting ~2 weeks. Physical jars are
labelled A/B/C (a spare eases decanting starter). Weekly: the week-2 jar is bottled, the
week-1 jar becomes week-2, and a new jar starts as week-1. **Both** jars are heated —
week-1 on the mat, week-2 on the belt. Expect a brief discontinuity in the cycle pattern
at each weekly rotation (a cold jar arriving), which is a jar swap, not a fault.

Stations are fixed; jars move between them. The sensor probes are labelled per **station**
(mat / belt / ambient), not per jar — so a dashboard line always means "the mat station",
regardless of which jar is currently there.

## Hardware

| Role | Name | IP | Chip | FW | Notes |
|---|---|---|---|---|---|
| Sensor | `temp-probe-2A-98` | 192.168.0.91 | ESP32-C3 | 15.6.0 | 3× DS18B20 on GPIO5; **has Berry** |
| Mat plug | `plug-mat` | 192.168.0.32 | ESP8285 | 15.6.0 | drives the ~22 W seedling mat; no Berry |
| Belt plug | `plug-belt` | 192.168.0.57 | ESP8285 | 15.6.0 | drives the ~25 W belt; no Berry |

The plugs have no Berry, so all plug-side logic is in the Rules engine. The sensor has
Berry and runs `autoexec.be` (in this repo) to read the probes and broadcast them.

The three DS18B20 are on one 1-Wire bus, each identified by a permanent ROM ID and
assigned to a station:

| Station | ROM ID | Heater |
|---|---|---|
| `mat` | `000000212DD2` | seedling mat (~22 W, constant, no cutout) |
| `belt` | `00000021A246` | brew belt (~25 W, has its own thermal cutout — see gotchas) |
| `ambient` | `000000C97887` | none (room reference) |

Broker: `192.168.0.2:1883`, user `tasmota`, used for observation only (Home Assistant +
Grafana). The control loop does not depend on it. Decommissioned: the old single-loop
sensor (192.168.0.64) and plug (192.168.0.58), and a whole-house CT clamp (192.168.0.89).

## Setpoints

Both plugs use the same setpoints (keyed to their own station event):

| Parameter | Value | Reason |
|---|---|---|
| Heat on below | 23.5°C | |
| Heat off above | 26.0°C | Glass reads high on heating spikes; 26 lets the liquid reach range |
| Hard cutoff | 30°C | Well clear of ~35°C, which kills the SCOBY |
| Sanity floor | 5°C | At/below ⇒ treated as a broken sensor |
| Sanity ceiling | 40°C | Above ⇒ treated as a broken sensor |
| Failsafe timeout | 600 s (10 min) | No readings for 10 min ⇒ heat off |
| Sensor telemetry | 60 s | Ten heartbeats per failsafe window |

Deadband is 2.5°C (widened from 1°C in stages — see git history). The off threshold sits
at 26 rather than 24 because the glass probe leads the liquid on each heating spike;
letting the glass run to 26 lifts the liquid trough into range.

## How it works

```
  temp-probe-2A-98 (ESP32-C3)              Device Groups "brew2"
  ┌──────────────────────────┐            (UDP multicast)         ┌──────────────┐
  │ 3× DS18B20 on 1-Wire bus  │ ── mat=24.1 ───────────────────►  │   plug-mat   │ ─► mat
  │ autoexec.be reads each by │ ── belt=23.8 ──────────────────►  │   plug-belt  │ ─► belt
  │ ROM ID, broadcasts every  │ ── ambient=19.9 ──(no plug)       └──────────────┘
  │ 60 s, staggered           │
  └──────────────────────────┘   each plug: Rule1 sanity + Rule2 hysteresis + PulseTime
```

Each plug is an independent control loop. For a station, there are three layers of
protection, each distrusting the one above:

1. **Sanity gate** — a reading must look like a real temperature before it influences
   anything.
2. **Hysteresis + hard cutoff** — decides heat on/off, refuses to heat above 30°C.
3. **`PulseTime` failsafe** — in the plug's own firmware. If readings stop for any reason,
   the relay switches itself off unprompted.

Layer 3 is the one that matters: it runs on the plug, so it still works when WiFi, the
broker, Home Assistant, or the sensor is the thing that failed. This is why the failsafe
could not live in Home Assistant.

Only the **sensor** broadcasts; the plugs only receive. This matters — see
"Plug-to-plug event leak" in the gotchas.

## Setup from scratch

Commands go into each device's Tasmota console (**Consoles → Console**) or via
`http://<ip>/cm?cmnd=<command>` (needs `SetOption128 1` — see gotchas). A captured
snapshot of the live config is in [`config/captured-config.txt`](config/captured-config.txt);
the broadcaster script is [`autoexec.be`](autoexec.be).

### Sensor (192.168.0.91)

```
SetOption128 1          # allow header-less HTTP API (fresh 15.6 flashes default this off)
DevGroupName1 brew2
DevGroupShare 64,64     # sensor broadcasts events out
SetOption85 1
TelePeriod 60
Restart 1
```

Then upload `autoexec.be` (web UI → Consoles → **Manage File system**, or the `/ufsu`
endpoint) and `Restart 1`. It auto-runs at boot, reads all three probes by ROM ID, and
broadcasts `mat` / `belt` / `ambient` events every telemetry cycle.

### Each plug (mat 192.168.0.32 / belt 192.168.0.57)

Identical except the station name in Rule1 (`mat` vs `belt`):

```
SetOption128 1
DevGroupName1 brew2
DevGroupShare 64,0      # plugs RECEIVE events, send NONE (see gotchas)
SetOption85 1
PowerOnState 0
PulseTime1 700
Rule1 ON Event#mat DO Backlog Var1 %value%; Event s1=%value% ENDON ON Event#s1>5 DO Event s2=%value% ENDON ON Event#s2>40 DO Power1 off ENDON
Rule2 ON Event#s2>30 DO Backlog Var4 0; Power1 off ENDON ON Event#s2<23.5 DO Backlog Var4 1; Power1 on ENDON ON Event#s2>26 DO Backlog Var4 0; Power1 off ENDON ON Event#s2>0 DO RuleTimer1 1 ENDON ON Rules#Timer=1 DO Event hb=%var4% ENDON ON Event#hb>0 DO Power1 on ENDON
Rule1 1
Rule2 1
Restart 1
```

For the belt plug, change `Event#mat` to `Event#belt` in Rule1. Everything else is the
same. `SetOption85` only takes effect after the restart.

## The configuration commands, annotated

| Command | What it does |
|---|---|
| `SetOption128 1` | Allow HTTP API calls that arrive with no `Referer` header (i.e. all `curl`/script access). Fresh Tasmota ≥15.6 defaults this **off** and silently denies the API — see gotchas. |
| `DevGroupName1 brew2` | Joins device group **1**, named `brew2`. All members must use the **exact same, case-sensitive** name. The `1` is the group slot (up to four); unrelated to item number `192` in the rules. |
| `DevGroupShare <in>,<out>` | Bitmask of which item types to **receive,send**. `64` = the `Event` bit (the only item we use). **Sensor uses `64,64`** (broadcasts out); **plugs use `64,0`** (receive only, send nothing) so their internal rule events don't leak to each other — see gotchas. Reports back in hex: `64` reads as `40`. |
| `SetOption85 1` | Master switch for device groups. **Needs a `Restart`** to take effect; setting it alone does nothing. All devices. |
| `TelePeriod 60` | Sensor telemetry rate = the broadcast/heartbeat rate. Must stay well under the plug's `PulseTime` window (600 s). Only meaningful on the sensor. |
| `PowerOnState 0` | Plug boots its relay **off**. The default (`1`) would energise the heater at power-up. Safety setting. |
| `PulseTime1 700` | The failsafe. `700` = 600 seconds. See "The failsafe" below — the single most important line. |

`SetOption19` is left **off** on all devices — correct for Home Assistant's native
Tasmota integration; enabling it switches to deprecated legacy MQTT discovery.

## The rules, annotated

### Sensor: the Berry broadcaster (`autoexec.be`)

Instead of a Rule, the C3 uses a Berry script (it has Berry; the old single-sensor ESP32
used a Rule). It reads all three DS18B20 **by ROM ID** (not by `DS18B20-N` index, which
can reorder), and broadcasts each as a station event. The full annotated script is in
[`autoexec.be`](autoexec.be); the essentials:

- Triggered by `Tele#DS18B20-1#Temperature` — the telemetry event, once per `TelePeriod`.
- For each station it sends `DevGroupSend1 192=<station>=<temp>` (item 192 = the Event
  item; see gotchas).
- The three sends are **staggered ~300 ms apart**, not fired in a tight loop — see
  "Transient events collide" in the gotchas.
- A missing/failed probe broadcasts **nothing** for that station, so that station's plug
  gets no heartbeat and its `PulseTime` failsafe trips — correct fail-safe behaviour.

So every 60 s, "here is each station's temperature" goes out to the group, and each plug
picks up its own.

### Plug Rule1 — sanity gate

```
ON Event#<station> DO Backlog Var1 %value%; Event s1=%value% ENDON
ON Event#s1>5      DO Event s2=%value%                          ENDON
ON Event#s2>40     DO Power1 off                                ENDON
```

`<station>` is `mat` or `belt` depending on the plug.

| Line | Meaning |
|---|---|
| `ON Event#<station>` | Catches this plug's station event, broadcast by the sensor. |
| `Var1 %value%` | Stashes the reading in `Var1`. **Nothing reads it** — pure observability (visible in console / Home Assistant / `log-temps.sh`). |
| `Event s1=%value%` | Re-fires the value as event `s1`, passing it to the next stage. Chaining builds a multi-step decision. |
| `ON Event#s1>5` | **The sanity gate.** Only a value above 5°C passes to `s2`. Junk, empty, and the DS18B20 `-127` error all fail this and stop here. |
| `ON Event#s2>40` | Above 40°C is implausible (the DS18B20 reports `85` on error) — treat as broken and cut power. |

A **whitelist**, not a blacklist: only a plausible value earns a decision; everything
else falls through to the safe state. Why in the gotchas.

### Plug Rule2 — hysteresis, cutoff, and heartbeat

```
ON Event#s2>30   DO Backlog Var4 0; Power1 off ENDON
ON Event#s2<23.5 DO Backlog Var4 1; Power1 on  ENDON
ON Event#s2>26   DO Backlog Var4 0; Power1 off ENDON
ON Event#s2>0    DO RuleTimer1 1 ENDON
ON Rules#Timer=1 DO Event hb=%var4% ENDON
ON Event#hb>0    DO Power1 on ENDON
```

`Var4` is a **software latch**: `1` = "this heater should be on". It lets the deadband
work without starving the failsafe.

| Line | Meaning |
|---|---|
| `ON Event#s2>30 DO Backlog Var4 0; Power1 off` | Hard safety cutoff, checked first. Redundant with `>26` for turning off, but kept as a separate explicit limit so tuning the setpoint can't accidentally disable it. |
| `ON Event#s2<23.5 DO Backlog Var4 1; Power1 on` | Too cold — set latch, heat. |
| `ON Event#s2>26 DO Backlog Var4 0; Power1 off` | Warm enough — clear latch, stop. |
| `ON Event#s2>0 DO RuleTimer1 1` | **Every** valid reading arms a 1-second timer (temp is always > 0 after the `>5` gate). |
| `ON Rules#Timer=1 DO Event hb=%var4%` | 1 s later, emit a heartbeat carrying the latch. The delay is essential: it lets the decision lines' `Backlog Var4 ...` commit *before* the latch is read (avoids a race — see gotchas). |
| `ON Event#hb>0 DO Power1 on` | If the latch is set, re-issue `Power on` — refreshes `PulseTime` without changing an already-on relay. |

Between 23.5 and 26.0 **no on/off decision fires** and the relay holds state — that gap
is the deadband, and it stops chatter. **But** the heartbeat lines still run every
reading, so the `PulseTime` countdown keeps refreshing while heating through the deadband.
This is the fix for the heartbeat-starvation bug (gotchas). Cooling back down does not
re-fire: once `>26` clears the latch, a 25.9 reading on the way down leaves it cleared
until the temperature falls below 23.5. The latch does not survive a reboot (comes back 0),
so a power cut boots the heater off — complementing `PowerOnState 0`.

Rule1/Rule2 are split because a rule set is capped at 511 bytes, and it separates "is this
reading real?" from "what should the heat do?".

### The failsafe

```
PulseTime1 700
```

The most important line, and the least obvious. `PulseTime` normally makes a relay switch
off after a set time (a stairwell timer). Values 112–64900 mean *seconds offset by 100*,
so **700 = 600 seconds**.

What makes it a watchdog: **re-issuing `Power ON` while the relay is already on restarts
the countdown.** The Rule2 heartbeat does exactly that on every reading while the heater
should be on. As long as readings keep arriving, the countdown never expires; the moment
they stop — dead sensor, dead WiFi, dead broker, crashed HA — it runs out and the plug
switches itself off. A dead-man's switch: heat stays on only while something keeps asking.

**What it does and does not protect against.** It is a *communication* watchdog — it fires
when readings *stop*. It is **not** a thermal-runaway limit. A sensor producing
plausible-but-wrong *low* readings (dangling in room air, or a heater fitted outside the
insulation so the glass never warms) keeps the heartbeat alive and the heater on;
lengthening `PulseTime` wouldn't help. A single-sensor-per-station thermostat cannot defend
against its sensor lying plausibly. The `>30` cutoff is a partial backstop; physical
mitigations (insulation pressing the probe to the glass so it can't dangle) matter more.

`PulseTime` survives a reboot and comes back with the relay **off**, waiting for a fresh
reading. `PowerOnState 0` complements it.

## Verifying it works

Use [`log-temps.sh`](log-temps.sh) — it polls the sensor and both plugs every ~10 s and
logs one row per tick (time, each station's temp, each plug's `Var1`/relay/watts). This
fast sampling is the tool that reveals what the Grafana dashboard's 30–60 s steps alias
away (the belt's self-cutout, the exact value at a switch-off).

A healthy loop: a plug's `Var1` tracks its station's temperature (a one-reading lag is
normal), and its `PulseTime1` `Remaining` sawtooths — decaying then jumping back up each
time a reading refreshes it, never quite reaching 700. If `Remaining` counts steadily down
with no jump-back, readings aren't arriving.

Confirm a heater actually draws power (the plugs meter their own load):

```bash
curl -s "http://192.168.0.32/cm?cmnd=Status%208"   # mat: ~22W steady when on
curl -s "http://192.168.0.57/cm?cmnd=Status%208"   # belt: ~32W, self-cycling (see gotchas)
```

### Testing the failsafe

**Disable the sensor's broadcast first** or the test is meaningless — the broadcaster's
real readings interleave with your synthetic ones and silently re-arm the watchdog (see
gotchas). On the C3, remove the broadcast rule, then inject and watch:

```bash
# silence the C3 broadcaster (Berry):
curl -s --get "http://192.168.0.91/cm" --data-urlencode 'cmnd=Br tasmota.remove_rule("Tele#DS18B20-1#Temperature")'
curl -s "http://192.168.0.32/cm?cmnd=PulseTime1%20130"                       # 30s instead of 600s
curl -s --get "http://192.168.0.32/cm" --data-urlencode "cmnd=Event mat=22.0"  # drive it on
# poll Power + PulseTime1 — relay should switch itself off after ~30s
curl -s "http://192.168.0.32/cm?cmnd=PulseTime1%20700"                       # restore
curl -s "http://192.168.0.91/cm?cmnd=Restart%201"                            # reboot C3 to reload autoexec
```

## Home Assistant & Grafana

All devices publish to the broker, so each station's temperature, relay state, and plug
energy surface without extra work. `SetOption19` is **off** (correct for HA's native
Tasmota integration). Home Assistant is a **spectator** — not in the control path; the
thermostats keep working with it switched off.

The Grafana dashboard ([`temp-dashboard.json`](temp-dashboard.json)) has a "Fermentation
Temperatures" panel showing the three probes with shaded heater-on bands per station, plus
a generic "Probe Temperature" panel for any other DS18B20. It is edited via the Grafana
API (the token lives in `.grafana-token`, gitignored) because pasting into the web editor
hangs the browser.

## Gotchas

Everything below was established empirically, mostly by getting it wrong first. Read this
before extending the system.

### Fresh Tasmota ≥15.6 needs `SetOption128 1` before the HTTP API works

Without it, `/cm?cmnd=...` calls with no `Referer` header (all `curl`/script access) are
silently denied — the web UI serves fine but every command returns an empty reply, and the
console logs `HTP: Referer '' denied`. Also needs `WebServer 2` (admin mode). Must be set
from the device's own console (chicken-and-egg: you can't reach `/cm` to set it remotely).

### Device Groups cannot share sensor values, despite the documentation

The docs claim device groups share "sensor values". **They do not.** The `DevGroupItem`
enum in `tasmota/include/tasmota.h` has no temperature item (`DGR_ITEM_ANALOG1..5` exist
only as commented-out lines). What works is `DGR_ITEM_EVENT` (**item 192**), an arbitrary
string fired as an event on every member — hence `192=<station>=%value%`. Item codes are
derived from the enum's size boundaries (`DGR_ITEM_MAX_32BIT = 191`, so the first string
item is 192).

### Plug-to-plug event leak — plugs must use `DevGroupShare 64,0`

With two plugs in one group both set to `64,64`, each plug **re-broadcast its own internal
pipeline events** (`s1`/`s2`/`hb` — the rule chain's intermediate stages) back into the
group, and the other plug's rules fired on them. Result: the belt switched on/off based on
the *mat* jar's temperature, chattering every 1–2 minutes. This did **not** show in
single-plug testing — it needs ≥2 plugs sharing the event namespace. Fix: plugs use
`DevGroupShare 64,0` (receive events, send none); only the sensor broadcasts. Persists
across reboot. (A longer-term fix for a bigger rig would be station-prefixed internal event
names, e.g. `belt_s2`.)

### Transient events collide — stagger multi-station broadcasts

Device-group Event items are fire-and-forget (unlike power/light state, which is synced
and retransmitted). Three events fired back-to-back in a tight loop **collide and are
silently dropped** — the receiver's `Var1` never updates, even though the sender logs all
three `DevGroupSend`s and the group shows sequence-synced. A single send always lands. Fix
in `autoexec.be`: stagger the three sends ~300 ms apart via `set_timer`. Diagnostic that
cracked it: watch the *receiver's* own `stat/.../RESULT` — silence there means the event
never arrived.

### `DevGroupShare` reports in hex

Set `64,64`, it reports `40`. Not an error: `0x40` = 64. Set `1,1`, it reports `1`.
Confusing when checking your own work.

### Comparison operators parse junk as zero — so `<` is dangerous

`ON Event#x<40` **fires** when `%value%` is `abc` or empty, because a non-numeric payload
parses as `0` and `0 < 40`. For a heater this is the worst failure: junk looks like
"freezing" and switches the heat on. `ON Event#x>5` correctly rejects `abc`, empty, and
`-127`. **So gate on `>`, never `<`** — a positive whitelist.

### The heartbeat starvation bug (a deadband can starve the failsafe)

The reason Rule2 has the latch and heartbeat lines. Originally the failsafe and the
thermostat shared one signal: `Power on`, issued only by the "too cold" line. Once the
temperature climbed into the deadband, **no rule fired**, so the heartbeat stopped
refreshing *even though readings kept arriving* — and after 600 s the firmware cut the
heater. Symptom: the heater appeared to "turn off at 24.5°C" with **no rule trigger in the
log**, because it was the watchdog timing out, not a threshold; every pulse capped at ~10
min regardless of temperature. Fix (2026-07-27): a latch (`Var4`) plus heartbeat lines that
re-issue `Power on` on **every** reading while the latch is set. **Lesson: if a failsafe
heartbeat is driven by a control rule, make sure it still fires in the states where the
control rule is deliberately silent.** A deadband is exactly such a state.

There's an evaluation-order race too: the heartbeat reads the latch via `Event hb=%var4%`,
which must expand *after* the decision lines commit their `Backlog Var4 ...`. The 1-second
`RuleTimer` guarantees this; firing it inline reads the stale latch and cancels the
power-off at the off transition.

### The belt has its own internal cutout — 0W with the relay ON is normal

The brew **belt** (not the mat) contains its own bimetallic thermal cutout. While our
relay is ON it self-cycles: ~32 W for ~1 min, then its cutout opens and it draws **0 W for
~1 min**, repeating. This is **not a fault**, but looks exactly like an intermittent open
circuit (`watts`/current drop to a clean 0, `ENERGY.Today` freezes, relay still ON). The
tell that it's the cutout: the **temperature keeps rising** across the 0 W stretch, and
current is clean full-on/full-off, never partial. Only visible if you sample faster than
~1 min; the Grafana dashboard's 30–60 s steps alias it to a flat 32 W. The **mat** has no
cutout — steady ~22 W — so for the mat, relay-ON + 0 W *would* be a real fault.

If you ever suspect a genuine intermittent connection (arcing is a mains hazard): a real
open circuit will **not** show the temperature still climbing, and shows erratic/partial
current rather than a clean ~1-min on/off rhythm.

### The testing trap that will bite you

Injecting synthetic `Event <station>=...` values **while the sensor broadcaster is running**
produces nonsense: real readings arrive every 60 s and overwrite your injected ones. This
cost real debugging time — a "dead sensor" test appeared to show the failsafe broken when
the sensor was alive and re-arming the watchdog throughout. **Disable the broadcaster first**
(remove the Berry rule) and confirm the plug's `Var1` stops changing. Also: a *rejected*
reading leaves the relay in its previous state — judge the failsafe by `PulseTime`
`Remaining` counting down, not by the immediate relay state.

### Things that are *not* true

Each suspected, tested, disproved — don't re-investigate:

- "Only the first matching trigger per event name fires." False — multiple triggers share
  an event name and all evaluate.
- "`%value%` doesn't survive a `Backlog` chain." False — it propagates into a follow-on
  `Event`.
- "Decimal thresholds don't work." False — `>24.5` compares correctly.

### Berry notes (sensor side)

- Telemetry trigger is `Tele#DS18B20-1#Temperature`. `Tele-...` (the Rules-era prefix)
  never fires on 15.6; the bare `DS18B20-1#Temperature` fires on every raw read (~1.4 Hz, a
  flood), not once per `TelePeriod`.
- `import string` is required before `string.format`, or `load()` fails silently
  (`'string' undeclared`, and `load()` returns false).
- Match probes by ROM `Id`, never by the `DS18B20-N` index (which can reorder if sensors
  change). `DS18Alias` is not in this build.
- A self-rescheduling `set_timer` did **not** survive reboot reliably; hook the telemetry
  event instead.

### Keep `TelePeriod` well below the failsafe window

`TelePeriod` is the heartbeat rate. At 300 s against a 600 s failsafe you get only two
heartbeats per window and a dropped packet risks a spurious cutout. 60 s gives ten. If you
lengthen `TelePeriod`, lengthen `PulseTime` to match.

## Possible extensions

- **Move control logic into Berry.** The cramped plug-side Rules caused most of this
  project's bugs; the Berry-capable C3 already has every temperature. A proposed redesign
  (see `CLAUDE.md`) would have Berry make the decision in readable code and broadcast a
  pre-decided on/off command, leaving the plug to keep only `PulseTime`. Not built.
- **Cooling.** A fan plug in the same group, on its own station event and deadband.
- **Ramp profiles.** Berry on the C3 could vary the setpoint over a fermentation schedule.
- **Alerting.** An HA automation on a plug's `LWT` or a stale `Var1` would catch a failsafe
  cutout, which is otherwise silent by design.
