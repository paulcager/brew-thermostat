#!/usr/bin/env bash
#
# log-temps.sh — sample the brew thermostat and append tab-separated rows.
#
# Columns: time  sensor_live  plug_var1  relay  watts
#   sensor_live  the DS18B20's current reading, polled straight from the sensor
#   plug_var1    the last temperature the PLUG actually acted on (its Var1) —
#                updates only when the sensor broadcasts, so it lags sensor_live
#   relay        the plug's relay state, ON/OFF
#   watts        the plug's measured load (belt draws ~30W on, 0W off) — ground
#                truth that the belt is really drawing current, not just the
#                relay's claimed state. relay=ON with watts=0 means no load.
#
# The sensor_live vs plug_var1 gap is the point: the plug's hysteresis decides
# from plug_var1, not from what the sensor reads at that instant. Watching both
# through a switch-off shows exactly which value tripped the rule.
#
# Usage:
#   ./log-temps.sh                 # print to screen and append to ./temps.log
#   ./log-temps.sh -i 5            # sample every 5s instead of 10
#   ./log-temps.sh -o /tmp/t.log   # log somewhere else
#   Ctrl-C to stop.

set -u

SENSOR=192.168.0.64          # temp-probe
PLUG=192.168.0.58            # tasmota2
INTERVAL=10
OUT="$(dirname "$0")/temps.log"

while getopts "i:o:s:p:h" opt; do
  case "$opt" in
    i) INTERVAL="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    s) SENSOR="$OPTARG" ;;
    p) PLUG="$OPTARG" ;;
    h) grep '^#' "$0" | cut -c3-; exit 0 ;;
    *) echo "try -h" >&2; exit 2 ;;
  esac
done

command -v jq  >/dev/null || { echo "need jq"  >&2; exit 1; }
command -v curl >/dev/null || { echo "need curl" >&2; exit 1; }

# One field from a Tasmota cmnd, or "?" on any failure (never abort the loop).
fetch() {  # host  cmnd  jq-filter
  curl -s --max-time 4 "http://$1/cm?cmnd=$2" 2>/dev/null | jq -r "$3 // \"?\"" 2>/dev/null || echo "?"
}

header=$'time\tsensor_live\tplug_var1\trelay\twatts'
echo "$header"
# Only add a header to the file if it's new/empty.
[ -s "$OUT" ] || echo "$header" >> "$OUT"

trap 'echo; echo "stopped. log: $OUT" >&2; exit 0' INT

while true; do
  ts=$(date +%T)
  live=$(fetch "$SENSOR" "Status%208" '.StatusSNS.DS18B20.Temperature')
  var1=$(fetch "$PLUG"   "Var1"        '.Var1')
  relay=$(fetch "$PLUG"  "Power"       '.POWER')
  watts=$(fetch "$PLUG"  "Status%208"  '.StatusSNS.ENERGY.Power')
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$live" "$var1" "$relay" "$watts" | tee -a "$OUT"
  sleep "$INTERVAL"
done
