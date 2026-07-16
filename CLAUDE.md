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
the last `Power ON`, and each temperature reading refreshes that countdown. It is
implemented in the plug's own firmware, which is the entire point — it survives WiFi,
broker, and Home Assistant failure.

This is a **hard requirement**, not a nicety. Paul specified that the cutout must live
in the plug precisely because the network may be the thing that failed. Any redesign
that moves the failsafe into Home Assistant, or into anything reachable only over the
network, is wrong.

Related invariants:

- `PowerOnState 0` on the plug — a power cut must not boot the belt into heating.
- Sensor `TelePeriod` must stay well below the `PulseTime` window (currently 60s vs
  600s). Lengthening one without the other breaks the heartbeat margin.

## Rules engine: read this before writing a rule

The full reasoning is in README.md's Gotchas. The short version:

- **Gate on `>`, never `<`.** Non-numeric and empty payloads parse as `0`, so
  `ON Event#x<40` fires for `abc`. For a heater that means junk reads as "cold" and
  switches the belt on. Sanity checks must be positive whitelists.
- **Device Groups cannot share sensor values**, whatever the docs say. Use
  `DGR_ITEM_EVENT` (item **192**) to carry a value as an event payload.
- **`DevGroupShare` reports in hex** — `64,64` reads back as `40`.
- **`SetOption85` needs a restart** to take effect.
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

The plug meters its own load, so you can confirm the belt is genuinely drawing power
rather than trusting the relay state:

```bash
curl -s "http://192.168.0.58/cm?cmnd=Status%208"   # ~25W belt on, 0W off
```

A healthy loop: the plug's `Var1` tracks the sensor's temperature (a one-reading lag is
normal), and `PulseTime1`'s `Remaining` sawtooths — decaying to ~640, jumping back to
~680 as each reading refreshes it. It never reaches 700.

## Conventions

- Setpoints live in the plug's Rule2 and in README.md's table. Change both together.
- `Var1` on the plug is written but never read — it is deliberate observability, not
  dead code. Don't "optimise" it away.
- Capture config snapshots to `config/captured-config.txt`.
- Rule text in docs should be annotated. Paul explicitly asked for command-by-command
  explanations; a bare rule string is not adequate documentation here.

## Current state

Verified working end-to-end 2026-07-16. The brew belt had not yet arrived, so the loop
has never actually driven a heater — the first real heating cycle is still pending, and
with it the first real evidence about whether the 1C deadband causes relay chatter.

The remote `origin` (github.com, user `paulcager`) is not yet created.
