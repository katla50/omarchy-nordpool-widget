---
name: nordpool-widget
description: Use when working on the io.github.katla50.nordpool-widget Omarchy plugin — Nord Pool day-ahead electricity prices in the bar.
---

# Nordpool Strømpris (Omarchy bar widget)

Plugin id `io.github.katla50.nordpool-widget`. Nord Pool day-ahead prices for a
Norwegian bidding zone in the bar, with nettleie and mva added on top, and an
hourly panel for today and tomorrow.

## Layout

| File | Role |
|---|---|
| `manifest.json` | id, entry point, and the **pill's** settings schema |
| `BarWidget.qml` | pill, colour, tooltip, panel lifecycle, `IpcHandler` |
| `Panel.qml` | detail popup: charts, lists, settings controls |
| `Feed.qml` | parser over the helper's JSON stream |
| `Chart.qml` | Canvas bar chart for one delivery day |
| `Stepper.qml` | −/+ control for nettleie and mva |
| `nordpool-watch.sh` | all network access, aggregation, tariff maths |
| `settings-write.sh` | atomic, typed writes to `config.json` |

Two config surfaces, each setting in exactly one of them:

- `~/.config/nordpool-widget/config.json` — data: `area`, `include_grid_tariff`,
  `grid_tariff_ore`, `include_vat`, `vat_percent`, `unit`, `cheapest_count`,
  `poll_interval_seconds`. Written from the panel via `settings-write.sh`.
- the widget's `shell.json` entry — pill appearance: `icon`, `showUnit`,
  `compact`, `colorByLevel`, `lowColor`, `highColor`.

## Data source

`https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?date=YYYY-MM-DD&market=DayAhead&deliveryArea=NO5&currency=NOK`
— the same endpoint the Home Assistant `nordpool` integration uses. Public, no
key. Areas `NO1`–`NO5`.

Facts that shape the code, all verified against the live endpoint:

- Prices come back **per MWh**, so `øre/kWh = NOK_per_MWh / 10` and
  `kr/kWh = NOK_per_MWh / 1000`. Do not display the raw value.
- Since the 15-minute market time unit a delivery day holds **96 entries**; an
  hourly price is the mean of its four quarters.
- Timestamps are UTC. Bucket them into local hours with jq's `localtime`
  (`TZ` is respected) — a hardcoded `+7200` is wrong half the year.
- **Tomorrow answers HTTP 204 with an empty body** until roughly 13:00 CET.
  That is not an error; it means "not published yet". `curl -f` does not fail on
  204, so an empty body is the signal to check.
- A past date returns HTTP 401, so the endpoint is not usable for history.

## Pitfalls

- **`0` and `false` are truthy traps in jq.** Only `false` and `null` are falsy,
  so `if $flag then … end` fires for `0`. Pass flags as 0/1 and compare
  `$flag == 1`. Likewise `false // true` evaluates to `true` — use
  `if .key == null then <default> else .key end` when a config value can
  legitimately be `false`.
- **A deliberate `Process.running = false` emits `exited` exactly like a crash
  does.** Without a `restarting` flag, every settings write surfaces as
  "prisvakt stoppet" and dims the pill. Set the flag before stopping, and let
  the restart path revive the process on a short timer (50 ms), reserving the
  longer backoff (5 s) for real exits.
- **`Date.now()` is not a notifyable property**, so a binding that reads only it
  is evaluated once and frozen. Age/staleness displays need a 1 s timer bumping
  a `tick` property that the binding also reads.
- **Row/Column reject anchors on their children.** Centre by giving each child
  the full row height and letting its own content centre, not with
  `anchors.verticalCenter`. Also avoid a child's width binding to a sibling's
  width inside a Row — that is a layout loop; use a fixed width instead.
- **`qs.Ui` `Toggle` and `ButtonGroup` do not mutate their own `checked`/`value`
  on click** — they only emit `clicked`/`changed`. So `checked:`/`value:` can
  stay bound to the feed, but selection must be written back explicitly.
- **Panel keyboard navigation is the panel's job.** `PanelKeyCatcher` has
  `Keys.priority: Keys.BeforeItem` and consumes Tab, so inner controls never get
  `activeFocus` and `ButtonGroup`'s built-in h/l never runs. Drive
  `ButtonGroup.cursorIndex` and `Toggle.hasCursor` from the panel's own cursor,
  and handle h/l yourself.
- **`omarchy-shell shell call <id> <method> <arg>` only reaches standalone
  `panel` plugins** (`panelLoaders[id]`), so it returns `unknown` for a
  bar-widget panel. Use `summon`/`hide`/`toggle`, or address the widget's
  `IpcHandler` directly with
  `qs ipc -p /usr/share/omarchy/shell call <plugin-id> refresh`.
- **Panel content taller than the screen is clamped, not scrolled.** Put the
  content in a `Flickable` with `contentHeight: <column>.implicitHeight` and let
  `fittedContentHeight` clamp the frame; otherwise the bottom settings are
  unreachable. `PanelKeyCatcher` has no `MouseArea`, so wheel events do reach it.
- **Verify a panel's real geometry with a runtime probe, not a guess.** Log
  `contentHeight`, `height` and `contentY` from a temporary timer, read them with
  `qs log -p /usr/share/omarchy/shell`, then delete the probe. A crop guess from
  a screenshot wastes rounds.
- **`qmllint` cannot resolve `qs.Commons`/`qs.Ui`** and floods warnings about
  unresolved imports, inheritance cycles and unqualified access. Compare its
  error-class output against an already-working plugin before chasing anything.
- **`set -e` plus `grep -c` is a trap in verification scripts**: a clean result
  (0 matches) exits 1 and aborts the rest of the checks. Expect it, or avoid
  `set -e` for those.
