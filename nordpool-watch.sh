#!/usr/bin/env bash
# Data helper for io.github.katla50.nordpool-widget.
#
# The QML side spawns this once with the plugin's config directory as its only
# argument and reads one JSON line per poll from stdout. Everything that should
# not run inside the long-lived shell process lives here: reading
# ~/.config/nordpool-widget/config.json, the two GETs against the Nord Pool
# Data Portal, 15-minute -> hourly aggregation, tariff/VAT maths, and the
# cheapest-hour ranking. Read-only: the only network calls are two GETs.
#
# Notes on the upstream data:
#   * DayAheadPrices is published per MWh in the requested currency, so
#     NOK/MWh / 10 == øre/kWh and NOK/MWh / 1000 == kr/kWh.
#   * Since the 15-minute market time unit the day holds 96 entries; an hourly
#     price is the mean of its four quarters.
#   * Tomorrow's prices are published around 13:00 CET and the endpoint answers
#     HTTP 204 with an empty body until then.
#   * Timestamps are UTC; jq's `localtime` buckets them into local hours so DST
#     transitions land in the right bucket without hardcoded offsets.
set -u

CONFIG_DIR="${1:?usage: nordpool-watch.sh <config-dir>}"
API="https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_AGENT="io.github.katla50.nordpool-widget/1.0 (+https://github.com/katla50/omarchy-nordpool-widget)"
SLEEP_SLICE=5

mkdir -p "$CONFIG_DIR"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nordpool-widget.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

# Default config on first run so the user has something concrete to edit.
if [[ ! -f $CONFIG_FILE ]]; then
  cat > "$CONFIG_FILE" <<'JSON'
{
  "area": "NO5",
  "include_grid_tariff": true,
  "grid_tariff_ore": 18.6,
  "include_vat": false,
  "vat_percent": 25.0,
  "unit": "ore",
  "cheapest_count": 3,
  "poll_interval_seconds": 900
}
JSON
fi

read_config() {
  jq -r '
    [
      (if (.area // "") == "" then "NO5" else (.area | tostring) end),
      (if .include_grid_tariff == null then true else .include_grid_tariff end
        | if . then 1 else 0 end | tostring),
      (.grid_tariff_ore // 0 | tonumber | tostring),
      (if .include_vat == null then false else .include_vat end
        | if . then 1 else 0 end | tostring),
      (.vat_percent // 0 | tonumber | tostring),
      ([.cheapest_count // 3, 1] | max | floor | tostring),
      ([.poll_interval_seconds // 900, 60] | max | floor | tostring),
      (if (.unit == "kr") then "kr" else "ore" end)
    ] | @tsv' "$CONFIG_FILE" 2>/dev/null
}

# One day of DayAheadPrices, or empty when the day is not published yet
# (HTTP 204) / the request failed.
fetch_day() { # $1 = YYYY-MM-DD
  curl -fsS --max-time 15 -H "User-Agent: $USER_AGENT" \
    "$API?date=$1&market=DayAhead&deliveryArea=$2&currency=NOK" 2>/dev/null || true
}

JQ_PROGRAM='
def buckets($area):
  [ .multiAreaEntries[]
    | select(.entryPerArea[$area] != null)
    | { key: (.deliveryStart | fromdateiso8601 | localtime | strftime("%Y-%m-%dT%H")),
        price: (.entryPerArea[$area] | tonumber) }
  ]
  | group_by(.key)
  | map({ date: .[0].key[0:10],
          hour: (.[0].key[11:13] | tonumber),
          spot: (([.[].price] | add / length) / 10) })
  | sort_by(.date, .hour);

# tariff is added to the spot first, then VAT applies to that sum — the order a
# Norwegian bill uses. All values stay in øre/kWh. The flags arrive as 0/1
# because jq treats only false and null as falsy (0 is truthy), so compare
# explicitly rather than testing the number directly.
def enrich($grid; $ig; $vatp; $iv):
  map( (.spot + (if $ig == 1 then $grid else 0 end)) as $sub
       | { date, hour, spot,
           grid: (if $ig == 1 then $grid else 0 end),
           vat: (if $iv == 1 then ($sub * $vatp / 100) else 0 end) }
       | . + { total: ((.spot + .grid + .vat) * 100 | round) / 100 } );

def rounded: map(. + { spot: ((.spot * 100 | round) / 100) });

def stats:
  if length == 0 then null
  else {
    min: (map(.total) | min), max: (map(.total) | max),
    avg: ((map(.total) | add / length) * 100 | round) / 100,
    minHour: (min_by(.total) | .hour), maxHour: (max_by(.total) | .hour),
    spotMin: (map(.spot) | min), spotMax: (map(.spot) | max),
    spotAvg: ((map(.spot) | add / length) * 100 | round) / 100
  } end;

(now | localtime | strftime("%Y-%m-%dT%H")) as $nowKey
| (now | localtime | strftime("%Y-%m-%d")) as $today
| (now | localtime | strftime("%Y-%m-%dT%H:00")) as $nowStamp
| ($t[0] | if . == null then [] else buckets($area) end | rounded | enrich($grid; $ig; $vatp; $iv)) as $td
| ($m[0] | if . == null then [] else buckets($area) end | rounded | enrich($grid; $ig; $vatp; $iv)) as $tm
| ($td + $tm | unique_by(.date + "T" + (.hour | tostring))) as $all
| ($all | map(select((.date + "T" + (if .hour < 10 then "0" else "" end) + (.hour | tostring)) >= $nowKey))) as $upcoming
| {
    area: $area,
    currency: "NOK",
    unit: $unit,
    fetchedAt: (now | floor),
    localDate: $today,
    localHour: ($nowKey[11:13] | tonumber),
    includeGridTariff: ($ig == 1),
    gridTariffOre: $grid,
    includeVat: ($iv == 1),
    vatPercent: $vatp,
    pollIntervalSeconds: $poll,
    cheapestCount: $cc,
    sourceUpdatedAt: ($t[0].updatedAt // null),
    tomorrowAvailable: ($tm | length) > 0,
    today: $td,
    tomorrow: $tm,
    current: ($td | map(select(.hour == ($nowKey[11:13] | tonumber))) | .[0] // null),
    todayStats: ($td | stats),
    cheapest: ($upcoming | sort_by(.total) | .[0:$cc] | map({ date, hour, spot, total })),
    error: (if ($td | length) == 0 then "no prices for today" else "" end)
  }
'

emit_error() {
  jq -cn --arg e "$1" '{error: $e}'
}

# Emit once per poll; returns 0 when prices were produced.
poll_once() {
  local area ig grid iv vatp cc poll unit today tomorrow t_doc m_doc
  read -r area ig grid iv vatp cc poll unit < <(read_config)
  [[ -n ${area:-} && -n ${grid:-} ]] || { area="NO5"; ig=1; grid=0; iv=0; vatp=0; cc=3; poll=900; unit="ore"; }

  today="$(date +%F)"
  tomorrow="$(date -d 'tomorrow' +%F 2>/dev/null || true)"

  t_doc="$(fetch_day "$today" "$area")"
  if [[ -z ${t_doc:-} ]]; then
    emit_error "Nord Pool request failed (area $area)"
    return 1
  fi
  m_doc=""
  if [[ -n ${tomorrow:-} ]]; then
    m_doc="$(fetch_day "$tomorrow" "$area")"
  fi

  printf '%s' "${t_doc:-null}" > "$TMP_DIR/today.json"
  printf '%s' "${m_doc:-null}" > "$TMP_DIR/tomorrow.json"

  jq -cn \
    --slurpfile t "$TMP_DIR/today.json" \
    --slurpfile m "$TMP_DIR/tomorrow.json" \
    --arg area "$area" \
    --argjson ig "$ig" \
    --argjson grid "$grid" \
    --argjson iv "$iv" \
    --argjson vatp "$vatp" \
    --argjson cc "$cc" \
    --argjson poll "$poll" \
    --arg unit "$unit" \
    "$JQ_PROGRAM" || emit_error "could not parse the Nord Pool response"
}

# Sleep in short slices, waking early on a config edit or a new hour so the
# pill is never stale across the top of the hour and a settings change in the
# panel shows up within seconds instead of a full poll interval.
sleep_until_next() { # $1 = poll interval, $2 = the hour we fetched in
  local interval="$1" fetched_hour="$2" waited=0 stamp now_hour
  stamp="$(config_mtime)"
  while (( waited < interval )); do
    sleep "$SLEEP_SLICE"
    waited=$(( waited + SLEEP_SLICE ))
    now_hour="$(date +%H)"
    [[ $now_hour != "$fetched_hour" ]] && return 0
    [[ "$(config_mtime)" != "$stamp" ]] && return 0
  done
  return 0
}

config_mtime() {
  stat -c '%Y.%s' "$CONFIG_FILE" 2>/dev/null || echo missing
}

while true; do
  poll_once
  interval="$(read_config | cut -f7)"
  [[ -n ${interval:-} ]] || interval=900
  sleep_until_next "$interval" "$(date +%H)"
done
