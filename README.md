# Nordpool Strømpris — Omarchy bar widget

Day-ahead electricity prices from [Nord Pool](https://www.nordpoolgroup.com/) in
your Omarchy bar, for any Norwegian bidding zone, with your own nettleie and mva
added on top. Click the pill for an hourly panel covering today and tomorrow.
<img width="464" height="1035" alt="screenshot-2026-09-14_12-55-00" src="https://github.com/user-attachments/assets/1b5d4359-01c9-4309-bca3-3a7ae21174cd" />

```
⚡ 190.1 øre
```

## What it does

- **Current hour price** in the bar, coloured against today's average so an
  expensive hour reads at a glance (green = cheap, theme urgent = expensive).
- **Nettleie** added as a fixed øre/kWh amount, and **mva** as a percentage,
  both switchable and both editable from the panel.
- **Hourly panel**: a bar chart of today with the current hour highlighted and
  the daily average as a dashed line, the cheapest hours coming up, tomorrow's
  chart once Nord Pool publishes it, and a "next 24 hours" list.
- **Automatic updates**: the helper re-polls at the top of every hour, and on
  your configured interval in between. Config changes apply within seconds.
- **Degrades honestly**: a failed poll never blanks a working price — the pill
  dims and the tooltip says what went wrong.

## Install

```bash
omarchy plugin add https://github.com/katla50/omarchy-nordpool-widget --enable --yes
```

Or manually:

```bash
git clone https://github.com/katla50/omarchy-nordpool-widget \
  ~/.config/omarchy/plugins/io.github.katla50.nordpool-widget
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.katla50.nordpool-widget
```

Then click the pill and pick your price area (it starts on NO5).

## Requirements

Both ship with Omarchy, but the plugin will not fetch anything without them:

| Dependency | Used for |
|---|---|
| `curl` | the two GETs against the Nord Pool Data Portal |
| `jq` | JSON parsing, 15-minute → hourly aggregation, the tariff maths |

No API key and no account are needed — the Nord Pool Data Portal endpoint this
plugin uses is public.

## Configuration

There are two places to change things, and each setting lives in exactly one of
them.

### From the panel (writes `~/.config/nordpool-widget/config.json`)

| Key | Default | Meaning |
|---|---|---|
| `area` | `NO5` | Price area: `NO1` Oslo, `NO2` Kristiansand, `NO3` Trondheim, `NO4` Tromsø, `NO5` Bergen |
| `include_grid_tariff` | `true` | Add nettleie to the price |
| `grid_tariff_ore` | `18.6` | Nettleie in øre/kWh (varies by nettselskap, typically 15–25) |
| `include_vat` | `false` | Add mva on top of spot + nettleie |
| `vat_percent` | `25.0` | Mva rate (25 % in Norway) |
| `unit` | `ore` | Display unit: `ore` (øre/kWh) or `kr` (kr/kWh) |
| `cheapest_count` | `3` | How many upcoming hours to rank as cheapest |
| `poll_interval_seconds` | `900` | Re-poll interval; 900 is the recommended floor |

The panel writes this file for you through `settings-write.sh`, which types
values properly and refuses unknown keys. You can edit it by hand too — the
helper watches the file's mtime and re-polls as soon as it changes.

### From `~/.config/omarchy/shell.json` (the pill's appearance)

Set through the Omarchy settings UI, or by hand in the widget's layout entry:

| Key | Default | Meaning |
|---|---|---|
| `icon` | `⚡` | Glyph before the price; empty for none |
| `showUnit` | `true` | Show `øre`/`kr` beside the price |
| `compact` | `false` | `190` instead of `190.1` |
| `colorByLevel` | `true` | Colour the price against today's average |
| `lowColor` | `#2ea043` | Colour for a cheap hour |
| `highColor` | `""` | Colour for an expensive hour; empty uses the theme's urgent colour |

## How the price is calculated

Nord Pool publishes day-ahead prices **per MWh**, so:

```
spot øre/kWh  = NOK per MWh / 10
spot kr/kWh   = NOK per MWh / 1000
```

Since the 15-minute market time unit a delivery day holds 96 entries; an hourly
price is the mean of its four quarters. Timestamps are UTC and are bucketed into
local hours, so the DST transitions land in the right hour.

Nettleie is added to the spot first and mva applies to that sum — the order a
Norwegian bill uses:

```
total = (spot + nettleie) × (1 + mva / 100)
```

Both adjustments are off the moment you switch them off, so the pill can show
plain spot price too. **The spot price from Nord Pool excludes nettleie, taxes
and mva**; `forbruksavgift` (elavgift) is not included by this plugin — add it to
`grid_tariff_ore` if you want it in the total.

## Using it

| Action | Result |
|---|---|
| Left click the pill | Open the hourly panel |
| Middle click the pill | Open `config.json` in your editor |
| Scroll in the panel | Move through the sections |
| `j` / `k` or Up/Down | Walk the settings rows |
| `h` / `l` or Left/Right | Adjust the row under the cursor |
| Enter / Space | Activate the row under the cursor |
| Tab | Switch to the next bar panel |
| Escape | Close the panel |

The panel also answers to shell IPC:

```bash
omarchy-shell shell summon io.github.katla50.nordpool-widget '{}'   # open
omarchy-shell shell hide   io.github.katla50.nordpool-widget '{}'   # close
omarchy-shell shell call   io.github.katla50.nordpool-widget refresh # re-poll now
```

## Files

| File | Role |
|---|---|
| `manifest.json` | Plugin manifest: id, entry point, and the pill's settings schema |
| `BarWidget.qml` | The pill: price, colour, tooltip, panel lifecycle, IPC |
| `Panel.qml` | The detail popup: charts, lists, settings |
| `Feed.qml` | Thin parser over the helper's JSON stream |
| `Chart.qml` | Canvas bar chart for one delivery day |
| `Stepper.qml` | −/+ control for the nettleie and mva values |
| `nordpool-watch.sh` | Fetching, aggregation, tariff maths, cheapest-hour ranking |
| `settings-write.sh` | Atomic, typed writes to `config.json` |

All network access lives in `nordpool-watch.sh`, not in QML. The script polls,
prints one JSON line per poll on stdout, and `Feed.qml` parses that stream.

## Troubleshooting

**The pill shows `n/a` or `…`.** Check the tooltip. `Nord Pool request failed`
means the request itself failed — confirm `curl -sS "https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?date=$(date +%F)&market=DayAhead&deliveryArea=NO5&currency=NOK" | jq .areaAverages`
works. `no prices for today` means the endpoint answered but the day is empty.

**"I morgen" says it is not published yet.** That is correct before roughly
13:00 CET — Nord Pool publishes tomorrow's prices around then, and the endpoint
answers HTTP 204 with an empty body until it does. It appears on its own.

**The price looks about 25 % low.** Turn on mva in the panel; Nord Pool quotes
spot prices excluding VAT.

**Prices stopped updating.** Run the helper by hand to see what it says:

```bash
sh ~/.config/omarchy/plugins/io.github.katla50.nordpool-widget/nordpool-watch.sh \
   ~/.config/nordpool-widget
```

It prints a JSON line per poll and loops forever — Ctrl-C to stop.

**QML errors after an edit.** `omarchy restart shell`, then read the log:

```bash
qs log -p /usr/share/omarchy/shell --tail 200 | grep nordpool-widget
```

## Data source and credits

Prices come from the Nord Pool Data Portal
(`dataportal-api.nordpoolgroup.com/api/DayAheadPrices`), the same endpoint the
Home Assistant [nordpool](https://github.com/custom-components/nordpool)
integration uses. Area codes follow the
[Nord Pool region map](https://data.nordpoolgroup.com/map).

## License

MIT — see [LICENSE](LICENSE).
