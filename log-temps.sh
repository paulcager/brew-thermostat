#!/usr/bin/env bash
#
# log-temps.sh — sample the brew2 two-loop thermostat, append tab-separated rows.
#
# One ESP32-C3 sensor board (temp-probe-2A-98) carries three DS18B20 on a 1-Wire
# bus, one per station: mat / belt / ambient. Two plugs each thermostat a jar:
# plug-mat and plug-belt. This logs, each tick:
#
#   time
#   mat_t    C3 mat probe   (DS18B20-1, ROM 212DD2)  live reading
#   mat_v1   plug-mat Var1  — the temp the mat plug last ACTED on (lags mat_t,
#            updates only on the 60s broadcast; gap shows which value tripped a rule)
#   mat_r    plug-mat relay ON/OFF
#   mat_w    plug-mat watts (mat = ~22W steady, NO cutout — so relay ON + 0W is a FAULT)
#   belt_t   C3 belt probe  (DS18B20-2, ROM 21A246)  live reading
#   belt_v1  plug-belt Var1
#   belt_r   plug-belt relay ON/OFF
#   belt_w   plug-belt watts (belt = ~32W, has its OWN internal cutout that self-cycles
#            ~1min on / ~1min off, so relay ON + 0W is NORMAL on the belt — not a fault.
#            The tell for a real fault: temperature NOT rising across the 0W stretch.)
#   amb_t    C3 ambient probe (DS18B20-3, ROM C97887) — room reference, no plug
#
# This fast (~10s) sampling is the tool that reveals what Grafana's 30-60s steps
# alias away — the belt's ~1min self-cutout, the exact value at a switch-off.
#
# Usage:
#   ./log-temps.sh                 # print + append to ./temps.log
#   ./log-temps.sh -i 5            # sample every 5s instead of 10
#   ./log-temps.sh -o /tmp/t.log   # log elsewhere
#   Ctrl-C to stop.

set -u

SENSOR=192.168.0.91          # temp-probe-2A-98 (ESP32-C3, 3x DS18B20)
MAT=192.168.0.32             # plug-mat
BELT=192.168.0.57            # plug-belt
INTERVAL=10
OUT="$(dirname "$0")/temps.log"

while getopts "i:o:s:h" opt; do
  case "$opt" in
    i) INTERVAL="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    s) SENSOR="$OPTARG" ;;
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

# Round a value to 1 dp; pass non-numbers (e.g. "?") through unchanged.
round1() {  # value
  printf '%s' "$1" | jq -Rr 'if test("^-?[0-9.]+$") then (tonumber*10|round/10) else . end' 2>/dev/null || printf '%s' "$1"
}

header=$'time    \tmat_t\tmat_v1\tmat_r\tmat_w\tbelt_t\tbelt_v1\tbelt_r\tbelt_w\tamb_t'
echo "$header"
# Only add a header to the file if it's new/empty.
[ -s "$OUT" ] || echo "$header" >> "$OUT"

trap 'echo; echo "stopped. log: $OUT" >&2; exit 0' INT

while true; do
  ts=$(date +%T)
  # one sensor read for all three probes (indexed DS18B20-1/2/3 on the C3)
  sns=$(curl -s --max-time 4 "http://$SENSOR/cm?cmnd=Status%2010" 2>/dev/null)
  # round temps to 1 dp in the jq filter (non-numbers fall through to "?")
  rt='(.StatusSNS."%s".Temperature | if type=="number" then (.*10|round/10) else . end) // "?"'
  mat_t=$(echo "$sns"  | jq -r "$(printf "$rt" DS18B20-1)" 2>/dev/null || echo "?")
  belt_t=$(echo "$sns" | jq -r "$(printf "$rt" DS18B20-2)" 2>/dev/null || echo "?")
  amb_t=$(echo "$sns"  | jq -r "$(printf "$rt" DS18B20-3)" 2>/dev/null || echo "?")

  mat_v1=$(round1 "$(fetch "$MAT"  "Var1" '.Var1')")
  mat_r=$(fetch  "$MAT"  "Power"      '.POWER')
  mat_w=$(fetch  "$MAT"  "Status%208" '.StatusSNS.ENERGY.Power')

  belt_v1=$(round1 "$(fetch "$BELT" "Var1" '.Var1')")
  belt_r=$(fetch  "$BELT" "Power"      '.POWER')
  belt_w=$(fetch  "$BELT" "Status%208" '.StatusSNS.ENERGY.Power')

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$mat_t" "$mat_v1" "$mat_r" "$mat_w" \
    "$belt_t" "$belt_v1" "$belt_r" "$belt_w" "$amb_t" | tee -a "$OUT"
  sleep "$INTERVAL"
done
