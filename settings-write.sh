#!/usr/bin/env bash
# Config writer for io.github.katla50.nordpool-widget.
#
# The detail panel calls this once per setting change:
#   settings-write.sh <config-dir> <key> <value>
# Values arrive as strings and are typed here (true/false -> bool, digits ->
# number, anything else -> string) so config.json stays well-formed JSON and
# the reader in nordpool-watch.sh never has to guess. Unknown keys are refused
# rather than written, so a typo in the QML cannot corrupt the file.
#
# The write is atomic (mktemp + mv) because nordpool-watch.sh watches this
# file's mtime to decide when to re-poll.
set -u

CONFIG_DIR="${1:?usage: settings-write.sh <config-dir> <key> <value>}"
KEY="${2:?usage: settings-write.sh <config-dir> <key> <value>}"
VALUE="${3-}"

case "$KEY" in
  area|unit) ;;
  include_grid_tariff|include_vat) ;;
  grid_tariff_ore|vat_percent|cheapest_count|poll_interval_seconds) ;;
  *)
    echo "settings-write: refusing unknown key '$KEY'" >&2
    exit 2
    ;;
esac

mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.json"
[[ -f $CONFIG_FILE ]] || echo '{}' > "$CONFIG_FILE"

TMP_FILE="$(mktemp "$CONFIG_DIR/.config.XXXXXX")" || exit 1
if jq --arg k "$KEY" --arg v "$VALUE" '
      .[$k] = (if $v == "true" then true
               elif $v == "false" then false
               elif ($v | test("^-?[0-9]+(\\.[0-9]+)?$")) then ($v | tonumber)
               else $v end)
    ' "$CONFIG_FILE" > "$TMP_FILE"; then
  mv -f "$TMP_FILE" "$CONFIG_FILE"
else
  rm -f "$TMP_FILE"
  echo "settings-write: could not update $CONFIG_FILE" >&2
  exit 1
fi
