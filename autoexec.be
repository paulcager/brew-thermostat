# brew-thermostat sensor broadcaster (ESP32-C3, temp-probe-2A-98)
#
# Reads each DS18B20 BY ROM ID (not by index, which can reorder) and broadcasts
# its temperature into device group "brew2" as a station-named event:
#   mat / belt / ambient
# Each plug in brew2 listens for its own station event. This also serves as the
# failsafe HEARTBEAT for the plugs, so it must fire well inside each plug's
# PulseTime window (plugs use 600s); driven here by the sensor telemetry cycle,
# so keep TelePeriod well below 600 (currently 60s => 10x margin).
#
# Trigger: the "Tele#" DS18B20-1 telemetry event, which Tasmota fires once per
# TelePeriod. The "Tele#" prefix is essential and was verified empirically on
# this build (2026-09-10):
#   Tele#DS18B20-1#Temperature  -> fires on telemetry only (what we want)
#   DS18B20-1#Temperature       -> fires on EVERY raw read (~1.4 Hz, a flood)
#   Tele-DS18B20-1#Temperature  -> never fires on this build (older syntax)
# Hooking telemetry (rather than a self-rescheduling Berry timer, which did not
# survive reboot reliably) means Tasmota's own telemetry cycle drives the
# broadcast — nothing to re-arm, rate controlled by TelePeriod (keep << 600s).
#
# Station -> ROM ID map (verified 2026-09-10 by warming each probe):
#   mat     000000212DD2
#   belt    00000021A246
#   ambient 000000C97887

import json
import string

var STATIONS = [
  ["mat",     "000000212DD2"],
  ["belt",    "00000021A246"],
  ["ambient", "000000C97887"],
]

# Temperature for a given ROM id from the live sensor JSON, or nil.
def temp_by_id(sensors, romid)
  for k: sensors.keys()
    var v = sensors[k]
    if type(v) == 'instance' && v.contains('Id') && v['Id'] == romid
      return v['Temperature']
    end
  end
  return nil
end

# Read all sensors once, broadcast each station that has a valid reading.
#
# The three sends are STAGGERED ~300ms apart via set_timer, NOT fired in a tight
# loop. Device-group Event items (item 192) are transient/fire-and-forget: three
# sent back-to-back collide and get silently dropped by the receiver (verified
# 2026-09-10 — a tight-loop burst left the plug's Var1 unchanged while a single
# send always landed). Spacing them lets each event transmit cleanly.
def broadcast_all()
  var raw = tasmota.read_sensors()
  if raw == nil return end
  var sensors = json.load(raw)
  if sensors == nil return end
  var slot = 0
  for st: STATIONS
    var t = temp_by_id(sensors, st[1])
    # Only broadcast a real number. A missing/failed sensor sends NOTHING, so
    # that station's plug gets no heartbeat and its PulseTime failsafe trips.
    if t != nil && type(t) == 'real'
      # capture st/t per iteration (Berry gives each loop pass its own binding)
      tasmota.set_timer(slot * 300, def()
        tasmota.cmd(string.format("DevGroupSend1 192=%s=%s", st[0], str(t)), true)
      end)
      slot += 1
    end
  end
end

# Broadcast once per sensor-telemetry cycle (Tele# = telemetry, not every read).
tasmota.add_rule("Tele#DS18B20-1#Temperature", /-> broadcast_all())
