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

- Sensor `temp-probe` — 192.168.0.64 (ESP32, has Berry)
- Plug `tasmota2` — 192.168.0.58 (ESP8285, **no Berry** — plug logic must use Rules)

**Other Tasmota devices on this LAN are in use.** Do not send commands to `.57`, `.62`,
`.32`, `.53`, `.52`, or `.89`. `.89` is a whole-house CT clamp; `.62` is `electric-chair`.

Reading state is free. Before *changing* device state, consider whether a batch is
fermenting — an unexpected heat cutout or an unwanted heating cycle affects a living
culture over hours. If in doubt, ask.

Devices are reachable over plain HTTP with no auth:

```bash
curl -s "http://192.168.0.58/cm?cmnd=Status%200"                       # read
curl -s --get "http://192.168.0.58/cm" --data-urlencode "cmnd=Rule1 ON ..."   # write
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

- **`DevGroupShare 64,64` is intentionally not the default.** `64` is the `Event` bit,
  the only thing the two devices share. The default shares *everything*, which includes
  power state — the plug's relay toggling would then try to drag the sensor along. Do
  not widen it to `-1,-1` or similar.
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
curl -s "http://192.168.0.58/cm?cmnd=Status%208"   # heater on / 0W off
```

NOTE: the live heater is now the ~22W seedling mat (constant power, no cutout), not the
old 25W belt. So watts should be a steady ~22W while on — the belt's ~1min on/off
self-cycling described below does NOT apply to the mat. Much of README still says "belt"
as accurate history; the multi-loop rebuild will have both a mat and a belt.

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

## Planned architecture (2-loop, not yet built as of 2026-09-09)

Goal: heat BOTH jars independently. New parallel rig, built and tested in isolation, then
hot-swapped for the current single-loop setup (which stays configured as documented
rollback). Nothing below is live yet.

- **1 new ESP32-C3 sensor board** `temp-probe-2A-98` (192.168.0.91, Tasmota 15.6.0, Berry
  present, MQTT up, SO128 on). Three DS18B20 on one 1-Wire bus (GPIO TBD): `mat`, `belt`,
  `ambient`. Third is future-extensibility / ambient reference for now. NOT yet soldered.
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

Build order: (0) new board on API+Berry+MQTT [done]; (1) solder 3 probes, confirm, pin
with DS18Alias; (2) design+isolation-test each plug's rules (relay driving nothing,
synthetic injection, sensor silenced, BOTH failsafe properties per plug); (3) integrate
heaters, watch real cycles; (4) hot-swap; (5) README rework for the multi-loop design.

## Current state

Verified working end-to-end 2026-07-16; driving the real brew belt since 2026-07-18.
Steady state is ~10 min of heating every 2-3 hours; the belt is idle ~90% of the time,
so it has ample headroom. The deadband (now 2.5C, on 23.5 / off 26.0) does NOT cause chatter.

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
