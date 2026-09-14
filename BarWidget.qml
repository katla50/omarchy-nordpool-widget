import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Nord Pool day-ahead electricity price for the current hour, in the bar.
//
// The pill shows the effective price — spot plus whatever nettleie/mva the user
// switched on in the panel — coloured against today's average so "expensive
// right now" reads at a glance. Left click opens the hourly panel, middle click
// opens config.json.
//
// Presentation settings (icon, unit suffix, compact, colours) come from this
// widget's shell.json entry via the manifest schema. The data settings (area,
// nettleie, mva, poll pace) live in ~/.config/nordpool-widget/config.json and
// are edited from the panel, so there is exactly one place to change each.
BarWidget {
  id: root
  moduleName: "io.github.katla50.nordpool-widget"

  // Manifest barWidget.defaults are merged into `settings` before the widget
  // sees them; the fallbacks only cover a hand-written shell.json entry.
  readonly property string icon: setting("icon", "⚡")
  readonly property bool showUnit: setting("showUnit", true)
  readonly property bool compact: setting("compact", false)
  readonly property bool colorByLevel: setting("colorByLevel", true)
  readonly property string lowColorSetting: setting("lowColor", "#2ea043")
  readonly property string highColorSetting: setting("highColor", "")

  readonly property var feed: feedLoader.item
  readonly property bool feedReady: feed !== null && feed.hasData
  readonly property bool feedFailed: feed !== null && feed.error !== "" && !feed.hasData
  readonly property bool feedStale: feed !== null && feed.error !== "" && feed.hasData

  // "ore" or "kr"; the feed echoes it from config.json.
  readonly property string unit: feed !== null && feed.unit === "kr" ? "kr" : "ore"
  readonly property string unitLabel: unit === "kr" ? "kr" : "øre"

  readonly property var current: feed !== null ? feed.current : null
  readonly property real currentTotal: current !== null ? Number(current.total) : NaN

  readonly property color baseForeground: bar ? bar.barForeground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color lowColor: lowColorSetting !== "" ? lowColorSetting : Color.accent
  readonly property color highColor: highColorSetting !== "" ? highColorSetting : urgentColor

  // Cheap / normal / expensive relative to today's average. The band is ±10 %,
  // the same cut the Nordpool Home Assistant integration uses for low_price.
  readonly property string level: {
    if (feed === null || !feed.hasData || current === null || feed.todayStats === null) return ""
    var avg = Number(feed.todayStats.avg)
    var total = Number(current.total)
    if (!isFinite(avg) || avg <= 0 || !isFinite(total)) return ""
    var ratio = total / avg
    if (ratio <= 0.9) return "low"
    if (ratio >= 1.1) return "high"
    return "mid"
  }

  readonly property string levelLabel: level === "low" ? "billig"
    : level === "high" ? "dyrt"
    : level === "mid" ? "normalt" : ""

  readonly property color pillColor: {
    if (feedFailed) return urgentColor
    if (feedStale) return Qt.rgba(baseForeground.r, baseForeground.g, baseForeground.b, 0.6)
    if (!colorByLevel) return baseForeground
    if (level === "low") return lowColor
    if (level === "high") return highColor
    return baseForeground
  }

  readonly property string priceText: {
    if (feedFailed) return "n/a"
    if (!feedReady) return "…"
    if (vertical) return formatPrice(currentTotal, true)
    return formatPrice(currentTotal, false)
  }

  readonly property string configDir: Quickshell.env("HOME") + "/.config/nordpool-widget"

  // `ore` values are øre/kWh; "kr" divides by 100. Kept here so the pill and the
  // panel format identically.
  function formatPrice(ore, shortForm) {
    if (ore === null || ore === undefined || isNaN(ore)) return "—"
    if (unit === "kr") {
      var kr = Number(ore) / 100
      return kr.toFixed(shortForm || compact ? 2 : 3)
    }
    return (shortForm || compact) ? String(Math.round(ore)) : Number(ore).toFixed(1)
  }

  function formatHour(hour) {
    return (hour < 10 ? "0" : "") + hour
  }

  function openConfig() {
    Quickshell.execDetached(["xdg-open", configDir + "/config.json"])
  }

  function restartFeed() {
    if (feed !== null && typeof feed.restart === "function") feed.restart()
  }

  readonly property string tooltip: {
    if (feed === null) return "Nord Pool: laster…"
    if (feed.error !== "" && !feed.hasData) return "Nord Pool: " + feed.error
    if (!feed.hasData) return "Nord Pool: laster…"

    var parts = []
    parts.push("Strømpris " + feed.area + " (Nord Pool)")
    if (current !== null) {
      parts.push("nå " + formatHour(current.hour) + "–" + formatHour((current.hour + 1) % 24)
        + ": " + formatPrice(current.total, false) + " " + unitLabel + "/kWh")
      if (feed.adjustmentsOn) {
        var add = []
        if (feed.includeGridTariff) add.push("nettleie " + feed.gridTariffOre.toFixed(1))
        if (feed.includeVat) add.push("mva " + feed.vatPercent.toFixed(0) + "%")
        parts.push("spot " + formatPrice(current.spot, false) + " + " + add.join(" + "))
      }
    }
    if (feed.todayStats !== null) {
      parts.push("i dag: min " + formatPrice(feed.todayStats.min, false) + " kl. " + formatHour(feed.todayStats.minHour)
        + " · snitt " + formatPrice(feed.todayStats.avg, false)
        + " · maks " + formatPrice(feed.todayStats.max, false) + " kl. " + formatHour(feed.todayStats.maxHour))
    }
    if (feed.cheapest.length > 0) {
      var best = feed.cheapest[0]
      var when = best.date === feed.localDate ? "kl. " + formatHour(best.hour) : "i morgen kl. " + formatHour(best.hour)
      parts.push("billigst nå: " + when + " (" + formatPrice(best.total, false) + ")")
    }
    if (feedStale) parts.push("siste oppdatering feilet: " + feed.error)
    return parts.join(" · ")
  }

  // ---- Panel lifecycle. Shape contract for shell summon/hide routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar root.
  readonly property bool opened: panelLoader.item !== null && panelLoader.item.opened === true
  readonly property bool popoutSwitchClosing: panelLoader.item !== null && panelLoader.item.popoutSwitchClosing === true

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("feed" in target) target.feed = Qt.binding(function () { return feedLoader.item })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: feedLoader
    active: true
    source: Qt.resolvedUrl("Feed.qml")
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.katla50.nordpool-widget"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.restartFeed() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    foreground: root.pillColor
    text: (root.icon !== "" ? root.icon + " " : "")
      + root.priceText
      + (root.showUnit && !root.vertical && root.feedReady ? " " + root.unitLabel : "")
    labelVisible: true
    tooltipText: root.tooltip
    onPressed: function (b) {
      if (b === Qt.MiddleButton)
        root.openConfig()
      else
        root.togglePanel()
    }
  }
}
