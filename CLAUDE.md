# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

A kombucha fermentation thermostat built entirely from **Tasmota configuration** — two
off-the-shelf devices, no custom firmware. There is almost no code here. The deliverable
is the configuration itself plus the documentation explaining it.

Consequently: **the documentation is the product.** If you change behaviour on a device,
the change is not finished until `README.md` reflects it. Paul's stated reason for the
docs is that he will need to repeat this in a few months having forgotten the details.

Read `README.md` before doing anything. Its **Gotchas** section records several firmware
behaviours that are counter-intuitive, undocumented, or actively contradicted by the
official Tasmota docs. They were expensive to establish. Do not re-derive them.

## Live hardware — this is not a sandbox

Every command in this repo targets **real devices on Paul's home network**, and the plug
switches a **mains heater** that will sit against a live fermentation vessel.

THE rig (group `brew2`) — as of 2026-09-11 this is the ONLY thermostat; the old
single-loop `brew` rig has been decommissioned (see below):
- Sensor `temp-probe-2A-98` — 192.168.0.91 (ESP32-C3, has Berry, 3x DS18B20 on GPIO5:
  mat=212DD2, belt=21A246, ambient=C97887). Runs `autoexec.be` broadcasting to `brew2`.
- Belt plug `plug-belt` — 192.168.0.57 (ESP8285, no Berry; formerly `tasmota1`).
  **LIVE: driving the real belt on the week-2 jar.** Verified regulating (heats, cuts at
  >26, watchdog clears on cutoff). Rule1 keyed to `Event#belt`.
- Mat plug `plug-mat` — 192.168.0.32 (ESP8285, no Berry; formerly `desk-lamp`).
  **LIVE since 2026-09-12: driving the real ~22W mat on the new week-1 jar.** Verified
  drawing ~22W when on (steady, no cutout). Rule1 keyed to `Event#mat`.

Current physical placement (2026-09-12): BOTH stations in use and both loops live —
week-1 jar on the mat (mat probe 212DD2), week-2 jar on the belt (belt probe 21A246),
ambient probe (C97887) in room air. The "New Rig Probes" panel shows three distinct lines
(mat/belt warm-ish, ambient cooler) with green (mat) / orange (belt) heater-ON bands.

DECOMMISSIONED (powered off, being removed — do NOT expect these to respond):
- Old sensor `temp-probe` 192.168.0.64 and old plug `tasmota2` 192.168.0.58 (the original
  single-loop `brew` rig — replaced by the brew2 rig above).
- Whole-house CT clamp formerly at 192.168.0.89.

**Other Tasmota devices on this LAN are in use — do not send commands to them:** `.53`,
`.52`, `.62` (`electric-chair`). (`.32`/`.57` are now the mat/belt plugs, ours; `.64`/
`.58`/`.89` are decommissioned.)

Reading state is free. Before *changing* device state, consider whether a batch is
fermenting — an unexpected heat cutout or an unwanted heating cycle affects a living
culture over hours. If in doubt, ask.

Devices are reachable over plain HTTP (SetOption128 ON allows header-less API):

```bash
curl -s "http://192.168.0.57/cm?cmnd=Status%200"                       # read (belt plug)
curl -s --get "http://192.168.0.57/cm" --data-urlencode "cmnd=Rule1 ON ..."   # write
```

Use `--data-urlencode` for anything containing spaces, `%`, `;` or `#`. Rule text is
full of all four.

MQTT broker `192.168.0.2:1883`, user `tasmota`. Ask Paul for the password if you need to
subscribe — it is deliberately not stored in this repo. You rarely need it: the broker is
**not** in the control path and is for observation only, so the thermostat can be worked
on and verified entirely over each device's HTTP API.

## The one thing that must not break

`PulseTime1 700` on the plug is the fail-safe: the relay switches itself off 600s after
the last `Power ON`, and the Rule2 **heartbeat lines** re-issue `Power on` on every
reading while the belt should be heating, refreshing that countdown. It is implemented in
the plug's own firmware, which is the entire point — it survives WiFi, broker, and Home
Assistant failure.

This is a **hard requirement**, not a nicety. Paul specified that the cutout must live
in the plug precisely because the network may be the thing that failed. Any redesign
that moves the failsafe into Home Assistant, or into anything reachable only over the
network, is wrong.

It is a **communication** watchdog (fires when readings stop), not a thermal-runaway
limit. It cannot protect against the sensor producing plausible-but-wrong low readings
(dangling in room air, belt outside the insulation) — those keep the heartbeat alive and
the belt on. Don't oversell it as thermal protection; the `>30` cutoff and the physical
setup (insulation pins the probe to the glass) are what guard those cases.

**The heartbeat is easy to break by accident.** It must fire in every state where the
belt should stay on — including the deadband, where the on/off rules are deliberately
silent. A control rule alone is not enough to feed it. This exact trap cut the belt every
~10 minutes for a week; see README's "heartbeat starvation bug". If you touch Rule2,
re-verify BOTH that in-deadband readings keep the belt alive AND that stopped readings
still kill it.

Related invariants:

- `PowerOnState 0` on the plug — a power cut must not boot the belt into heating. The
  Rule2 latch (`Var4`) also does not survive reboot, so a boot mid-heat stays off until a
  genuine below-23.5 reading.
- Sensor `TelePeriod` must stay well below the `PulseTime` window (currently 60s vs
  600s). Lengthening one without the other breaks the heartbeat margin.

## Config commands: what not to break

README.md annotates every setup command in full. The non-obvious rationale, so you
don't "tidy" these into breakage:

- **`DevGroupShare` (the Event bit, 64) — direction matters, and got asymmetric on the
  brew2 rig.** `64` = the `Event` item (the only thing shared); the default `-1,-1` shares
  *everything* incl. power state, which must never be used here.
  - The SENSOR (C3) uses `64,64` (in,out) — it broadcasts events out.
  - Both PLUGS use **`64,0`** — receive events, send NONE.
  WHY the plugs must NOT send (the fix for a real chatter bug, 2026-09-11): with two plugs
  in one group both set to `64,64`, each plug re-broadcast its OWN internal pipeline events
  (`s1`/`s2`/`hb` — the rule chain's intermediate stages) back into brew2. The other plug's
  rules (`Event#s2>26`, the `hb` heartbeat) then fired on the FIRST plug's s2/hb, so the
  two plugs cross-triggered each other's hysteresis — the belt switched on/off based on the
  MAT jar's temperature, chattering every ~1-2 min. This did NOT show in single-plug
  isolation testing; it only appears with ≥2 plugs sharing the event namespace. Fix:
  `DevGroupShare 64,0` on every plug so internal events stay local. Persists across reboot.
  (The DevGroupSend from the sensor still reaches the plugs via their In=64.)
- **`DevGroupName1 brew` must match byte-for-byte, case-sensitive, on both devices.** A
  mismatch fails silently: no error, just no data crossing. The `1` is the group slot,
  unrelated to the item number `192` in the rules.
- **`SetOption85 1` needs a `Restart` to activate.** Setting it alone does nothing; a
  device that "won't join the group" has usually just not been restarted.
- **`SetOption19` stays OFF.** It is correct off for HA's native Tasmota integration.
  Turning it on switches to deprecated legacy MQTT discovery — do not enable it as a
  "fix" for a Home Assistant issue.
- **A freshly-flashed Tasmota (>=15.6) needs `SetOption128 1` before the HTTP API works.**
  Without it, `/cm?cmnd=...` calls with no `Referer` header (i.e. all `curl`/script access)
  are silently denied — the device serves its web UI fine but every command returns an
  empty reply, and the console logs `HTP: Referer '' denied. Use 'SO128 1' for HTTP API`.
  The existing devices already have it ON (set long ago), which is why they answer freely;
  a new/replacement device comes up with it OFF at the firmware default. Also needs
  `WebServer 2` (admin mode) enabled. This cost real time on 2026-09-09 setting up the
  ESP32-C3. It must be set from the device's own console (you can't reach `/cm` to set it
  remotely until it is set — chicken-and-egg).

## Rules engine: read this before writing a rule

The full reasoning is in README.md's Gotchas. The short version:

- **Gate on `>`, never `<`.** Non-numeric and empty payloads parse as `0`, so
  `ON Event#x<40` fires for `abc`. For a heater that means junk reads as "cold" and
  switches the belt on. Sanity checks must be positive whitelists.
- **Device Groups cannot share sensor values**, whatever the docs say. Use
  `DGR_ITEM_EVENT` (item **192**) to carry a value as an event payload.
- **`DevGroupShare` reports in hex** — `64,64` reads back as `40`. Easy to misread when
  checking your own config.
- Rule sets are capped at **511 bytes** each; Rule1/Rule2/Rule3 are separate budgets.

## Testing: the trap

**Disable the sensor's broadcast rule (`Rule1 0`) before injecting synthetic values at
the plug.** Otherwise real readings arrive every 60s, interleave with your test values,
and silently invalidate the result. This previously produced a convincing but entirely
false "the failsafe is broken" conclusion — the sensor was alive and re-arming the
watchdog throughout. Confirm silence by watching the plug's `Var1` stop changing, then
test, then re-arm with `Rule1 1`.

When judging the failsafe, watch `PulseTime1`'s `Remaining` count down — not the
immediate relay state. A rejected reading correctly leaves the relay as it was; it is
the absent heartbeat, not the rejection, that cuts the power.

Never leave a device with a shortened `PulseTime` or a disabled rule. Restore
`PulseTime1 700` and `Rule1 1` at the end of any test, and verify.

## Verifying real behaviour

The plug meters its own load, so you can confirm the heater is genuinely drawing power
rather than trusting the relay state:

```bash
curl -s "http://192.168.0.57/cm?cmnd=Status%208"   # belt plug: heater on / 0W off
```

NOTE: there are now TWO heaters, one per station, with DIFFERENT wattage signatures:
- BELT (on plug-belt .57): the original ~25W belt with its own internal thermal cutout,
  so while our relay is ON it self-cycles ~1min at ~32W / ~1min at 0W. `watts=0` with
  relay ON is NORMAL here (see "belt's own internal cutout" below).
- MAT (on plug-mat .32): a ~22W seedling mat, constant power, NO cutout — steady ~22W
  while on, so relay ON + watts 0 WOULD be a real fault on the mat.
(README still describes a single-belt setup as accurate history for that period; it gets
reworked for the 2-loop rig at Phase 5.)

A healthy loop: the plug's `Var1` tracks the sensor's temperature (a one-reading lag is
normal), and `PulseTime1`'s `Remaining` sawtooths — decaying to ~640, jumping back to
~680 as each reading refreshes it. It never reaches 700.

## Conventions

- Setpoints live in the plug's Rule2 and in README.md's table. Change both together.
- `Var1` on the plug is written but never read by the rules — deliberate observability
  (last temperature seen), not dead code. Don't "optimise" it away.
- `Var4` on the plug IS load-bearing: it is the heartbeat latch (1 = belt should heat).
  Rule2 depends on it. Not observability — do not repurpose it.
- Capture config snapshots to `config/captured-config.txt`.
- Rule text in docs should be annotated. Paul explicitly asked for command-by-command
  explanations; a bare rule string is not adequate documentation here.
- `log-temps.sh` polls sensor/plug every ~10s (time, sensor, plug Var1, relay, watts) to
  `temps.log` (gitignored). This fast sampling is the tool that reveals what Grafana's
  30-60s steps alias away — the belt's ~1min self-cutout, the exact value at a switch-off.
  Reach for it, not the dashboard, when debugging cycle-level behaviour.

## How it's used

Two-jar setup: two ~3L jars, start days offset by a week, each fermenting ~2 weeks. Jars
are physically labelled A/B/C (three exist so a spare eases decanting starter liquid;
only two ferment at once). Every ~week the week-2 jar leaves for bottling, the week-1 jar
becomes week-2, and a new jar enters as week-1. Expect a brief discontinuity in the cycle
pattern at each rotation — it is a jar swap, not a fault. (The 2L batch seen around
2026-08-07 was a one-off bootstrap from a new culture; normal batches are 3L. Setpoints
were left as tuned for that batch.)

HEATING CHANGED 2026-09: the single 25W brew belt was replaced by a ~22W **seedling mat**
(gentler, more uniform, constant power, NO internal cutout — unlike the belt). The mat
does not quite wrap the glass (~1cm short), and the probe sits in that uncovered gap so it
is not reading the hot element directly. The belt is being repurposed to heat the *second*
jar (see planned architecture below). Insulation is still a work in progress.

## Planned architecture (2-loop, in progress — sensors built, not yet live)

Goal: heat BOTH jars independently. New parallel rig, built and tested in isolation, then
hot-swapped for the current single-loop setup (which stays configured as documented
rollback). Nothing below is live yet.

- **1 new ESP32-C3 sensor board** `temp-probe-2A-98` (192.168.0.91, Tasmota 15.6.0, Berry
  present, MQTT up, SO128 on). Three DS18B20 soldered on one 1-Wire bus on **GPIO5**
  (component DS18x20/1312, single 4.7k pull-up to 3V3). All three confirmed reporting and
  stable 2026-09-10. ROM ID -> station mapping (verified by warming each probe and watching
  which ID rose; physical labels attached to match):
    - `000000212DD2` -> **mat**
    - `00000021A246` -> **belt**
    - `000000C97887` -> **ambient**
  NOTE: `DS18Alias`/`DS18Sens` are NOT compiled into this build (both return Unknown). The
  reported DS18B20-1/2/3 index order happens to match ROM-ID sort order and is stable while
  these exact 3 sensors stay on the bus, but DO NOT rely on index — bind by ROM ID. Berry
  is present, so the sensor-side plan is a Berry script that reads each probe BY ROM ID and
  broadcasts it under its station event name (mat/belt/ambient). This is more robust than
  index-based Rules and the reason the ROM-ID table above is load-bearing.
- **2 new Tasmota plugs** (identical to current, ESP8285/no-Berry expected): one drives the
  mat, one the belt. Each needs its OWN latch + heartbeat + `PulseTime` (all the
  heartbeat-starvation lessons apply per plug).
- **Device group `brew2`** (deliberately NOT `brew` — isolates the test rig from the live
  loop during parallel running; `brew2` = v2 of the system, leaves room for `brew3`).
- **Event names are STATION-based, not jar-based:** `mat`, `belt`, `ambient`. Jar identity
  (A/B/C) churns weekly and would clash with the physical labels and lie after rotation.
  Station names never lie: `mat` always means "the jar currently under the mat".
- **Sensors stay with STATIONS, not jars** (decided over the software-remap alternative).
  Probes get physical labels ("mat sensor" etc). At rotation you physically move the mat
  and belt probes onto the jars now at those stations; `ambient` never moves; NO rule edit
  ever. This keeps Grafana series continuous (a `mat` line always means the mat station)
  and makes the weekly step self-checking (labelled probe -> labelled station). The moment
  of risk is a probe left dangling/mis-seated mid-swap — reseat carefully, glance at the
  dashboard after; the `>30` cutoff and insulation are partial guards.
- **`DS18Alias`** pins each ROM ID to a fixed station name so index order (`-1`/`-2`) can
  never silently reorder and cross a sensor to the wrong station's heater.
- One-plug bodge (both heaters off one plug) was considered and rejected: the two jars are
  at different fermentation stages and want different heat, so each needs its own loop.

Build order: (0) new board on API+Berry+MQTT [done]; (1) solder 3 probes, confirm, map
ROM IDs to stations [done 2026-09-10 — board awaits a project box before install]; (1b)
Berry broadcast script [done 2026-09-10 — `autoexec.be`, see below]; (2) design+
isolation-test each plug's rules (relay driving nothing, synthetic injection, sensor
silenced, BOTH failsafe properties per plug) [DONE 2026-09-10 — both plugs verified
end-to-end]; (3) integrate heaters, watch real cycles [DONE 2026-09-12 — both loops driving
real heaters: belt ~32W self-cycling, mat verified ~22W steady]; (4) hot-swap [DONE — old
rig decommissioned 2026-09-11, brew2 is sole]; (5) README rework for the multi-loop design
[TODO — README still documents the old single-belt setup; this is the last remaining task].

Both plugs (ESP8285/no-Berry, group brew2, verified 2026-09-10):
- Mat plug `plug-mat` 192.168.0.32 (formerly `desk-lamp`) — Rule1 keyed to `Event#mat`.
- Belt plug `plug-belt` 192.168.0.57 (formerly `tasmota1`) — Rule1 keyed to `Event#belt`.
Each: Rule1 = `ON Event#<station> DO Backlog Var1 %value%; Event s1=%value% ENDON ON
Event#s1>5 DO Event s2=%value% ENDON ON Event#s2>40 DO Power1 off ENDON`; Rule2 = the
standard latch+heartbeat (on<23.5 / off>26 / cutoff>30, Var4 latch, RuleTimer1 heartbeat),
identical across mat/belt/live — only Rule1's trigger event differs. PulseTime1 700,
PowerOnState 0 on both. Verified: 3 devices in brew2 (C3 + 2 plugs), each plug tracks its
OWN station with no cross-talk, both heartbeats refresh, both failsafe properties hold.

The sensor broadcast script is `autoexec.be` (in the repo; uploaded to the C3 via the
web file-manager `/ufsu`, auto-runs at boot). It reads all three DS18B20 by ROM ID and
broadcasts each as a `brew2` event `mat`/`belt`/`ambient`. Berry gotchas learned building
it (2026-09-10), all verified on the live board:
- **Telemetry trigger is `Tele#DS18B20-1#Temperature`.** `Tele-...` (the old Rules-era
  prefix) never fires on this 15.6 build; the bare `DS18B20-1#Temperature` fires on every
  raw read (~1.4 Hz — a broadcast flood), NOT once per TelePeriod. Only `Tele#` gives the
  per-TelePeriod cadence we want.
- **A self-rescheduling Berry timer (`set_timer` re-arming itself) did NOT survive reboot
  reliably** — it ran once at boot then stopped. Hooking the telemetry event instead means
  Tasmota's own cycle drives it; nothing to re-arm. Broadcast rate = TelePeriod (60s).
- **Device-group Event items (item 192) are TRANSIENT — three sent back-to-back collide
  and are silently dropped.** This was the single worst bug of the 2-loop build (2026-09-10,
  ~an hour). Symptom: the plug's Var1 never updated from the auto broadcast, even though
  the C3's MQTT log showed all three DevGroupSend commands executing every 60s and
  `DevGroupStatus` showed the group fully sequence-synced. A SINGLE manual DevGroupSend
  always landed; the tight-loop burst of 3 (mat/belt/ambient) always lost them. Unlike
  power/light state (which is synced/retransmitted-until-acked), an Event is fire-and-forget
  — if the receiver isn't ready in that instant it's gone, and rapid succession makes that
  the norm. FIX: stagger the sends ~300ms apart via `tasmota.set_timer(slot*300, def() ...`
  rather than a tight for-loop. Verified: staggered => all three land reliably across
  reboots. If you add a 4th station later, keep the stagger. Diagnostic that cracked it:
  watch the RECEIVER's own stat/.../RESULT — silence there means the event never arrived,
  vs the rule firing but not updating.
- **`import string` is required** before `string.format` — otherwise `load()` fails with
  "'string' undeclared" and the whole script silently doesn't load (`load()` returns false).
- Berry lambdas are expression-only: `/-> foo()` is fine, `/-> (x=x+1)` is a syntax error.
  Use a named `def` for anything with a statement body.
- Read sensors with `tasmota.read_sensors()` (returns the sensor JSON string); parse with
  `json.load`; each `DS18B20-N` entry is an instance with `.contains('Id')` / `['Id']` /
  `['Temperature']`. Match by `Id`, never by the `-N` index.
- A missing/failed sensor broadcasts NOTHING for that station (guarded by the real-number
  check), so that station's plug gets no heartbeat and its PulseTime failsafe trips — which
  is the correct fail-safe behaviour, per-station.
- Multi-line Berry can't be pasted as one space-joined line via `Br ...` (syntax errors on
  `def`/`end`); develop in a file and `load()` it, or upload and reboot.

## PROPOSED redesign: move control logic into Berry (NOT built — design note only)

Motivation (Paul, 2026-09-11): the plug-side Rules are necessarily cramped and hard to
reason about, and have caused most of this project's bugs (the `<`-parses-junk trap, the
deadband heartbeat starvation, the RuleTimer latch race, the plug-to-plug event leak). The
ESP32-C3 sensor has full Berry and already reads every temperature — so it can make the
decision in readable code, and the plug can become almost brainless. This is a direction
to take WHEN we choose to; nothing below is implemented.

Principle Paul set: **keep it simple and obvious.** The plug keeps ONLY the `PulseTime`
failsafe — "no command for 10 min => turn off." It does NOT get a temperature cutoff or
any hysteresis. The plug never reasons about temperature at all; it just obeys on/off and
dies on silence. The 30C hard cutoff does not disappear — it MOVES into Berry as one more
`if` alongside the rest of the decision.

Proposed shape:
- **Berry on the C3 decides.** It already has mat/belt/ambient. A readable function per
  station: sanity-reject implausible readings, hard-cutoff >30, hysteresis (on <23.5 /
  off >26 with the in-deadband "leave as-is"). Real if/elif, variables, comments — versus
  the current 6-line event chain.
- **Plug obeys a pre-decided command, not a temperature.** Berry broadcasts a DECISION
  (e.g. event `belt_cmd=on` / `belt_cmd=off`), not a temperature. Preferred over sending
  raw `Power` because (a) it reuses the transient-Event transport we already understand and
  the `64,0` leak fix still applies, and (b) `Power` is a *synced* device-group item with
  different (unverified) two-plug semantics. Plug rule becomes trivial:
  `ON Event#belt_cmd=on DO Power1 on ENDON  ON Event#belt_cmd=off DO Power1 off ENDON`.
- **Failsafe unchanged in behaviour.** `PulseTime1 700` stays on the plug. Every "on"
  command refreshes it exactly as the heartbeat does now; every reading cycle that decides
  "stay on" must re-send "on" to keep feeding it (so Berry sends on every cycle while
  heating, not just on the on-edge — same lesson as the deadband heartbeat bug, but now
  in legible Berry). Silence (C3 dead / WiFi down / Berry errored) => no commands =>
  PulseTime trips => heat off. Identical dead-man's-switch property, just a different
  sender.

Accepted trade-off: this centralises the "brain" in the C3. A DEAD C3 still fails safe
(PulseTime). A C3 running BUGGY logic could drive a plug wrongly, and — per Paul's choice —
there is deliberately NO independent plug-side temperature backstop; correctness rests on
the Berry logic (which, being readable and unit-testable, is the point). PulseTime only
guards silence, not wrong-but-live commands.

Gotchas this retires (plug side): the `s1/s2` event chain, the `>`-only sanity gating, the
Var4 latch, the RuleTimer heartbeat race, and most of the plug-to-plug leak surface —
because the plug stops doing pipeline work. The Berry-side gotchas already documented
above (Tele# trigger, import string, staggered sends, match-by-ROM-ID) still apply.

Build approach when pursued: prototype on the MAT loop first (idle, drives nothing — zero
risk), prove Berry-decides / plug-obeys / PulseTime-still-trips end-to-end (re-verify BOTH
failsafe properties), then roll to the belt. Consider station-prefixed internal event
names if any future device needs to broadcast.

## Current state

As of 2026-09-12 the two-loop `brew2` rig is fully live and is the only thermostat: one
ESP32-C3 sensor (3 probes) broadcasting to two dumb-Rules plugs, mat + belt, each on its
own jar, each verified drawing real power and regulating on its own station. The old
single-loop rig is decommissioned. Build is complete except the README rework (task 5).
Setpoints on both plugs: on <23.5 / off >26 / cutoff >30, deadband 2.5C, PulseTime 700.

The history below is from the ORIGINAL single-belt rig (Jul–Aug 2026). It is kept because
its hard-won bug fixes (heartbeat latch, `>`-only sanity gating, etc.) were carried
verbatim into the new plugs' Rule2 — so the reasoning still applies.

Verified working end-to-end 2026-07-16; drove the real brew belt from 2026-07-18.
Steady state was ~10 min of heating every 2-3 hours; the belt idle ~90% of the time,
so ample headroom. The deadband (2.5C, on 23.5 / off 26.0) does NOT cause chatter.

On 2026-07-27 fixed a significant latent bug: the `PulseTime` heartbeat starved whenever
the belt was heating in the deadband, cutting the belt every ~10 min regardless of
temperature (it was the watchdog timing out, not a rule). Rule2 now carries a latch
(`Var4`) and heartbeat lines. See README's "heartbeat starvation bug". Off threshold
widened 24.5 -> 25.0 on 2026-07-26 (that change did nothing at the time because the belt
was timing out before reaching any threshold — only the bug fix made it effective).

Learned from running it:
- The probe (glass, ~8cm above the belt) leads the bulk liquid by ~1C, so the liquid
  sits a little below the 24C target. Fine for kombucha; the `scoby-death` dashboard
  line at 30C matches the plug's hard cutoff. Left uncompensated by choice.
- Each pulse redistributes internally before the vessel cools to the room: after
  belt-off the probe overshoots ~4 min, decays fast to ~24.1 (local pocket equalising
  with the bulk), then decays slowly for hours (whole vessel losing heat to the room).
- Belt rewound from two wraps to one on ~2026-07-20 to lower watts/cm2 and avoid a hot
  spot; the rise-rate got gentler as intended (partly confounded by a cooler room).
- The belt has its OWN internal thermal cutout. While our relay is ON it self-cycles
  ~1min at 32W / ~1min at 0W. So `watts=0` with `relay=ON` is NORMAL — do not mistake it
  for an intermittent connection fault (it looked exactly like one and cost a scare on
  2026-07-28). Only visible if you sample faster than ~1min; Grafana's 30-60s steps alias
  it to a flat 32W. See README "The belt has its own internal cutout".

None of these needed a config change — re-tuning the physical heat delivery, the loop
just adapts, because everything keys off the probe.

The repo is public at github.com/paulcager/brew-thermostat. The Grafana dashboard is
edited via the API (see git history) because pasting into the web editor hangs the
browser; the token lives in `.grafana-token` (gitignored, never commit it).
