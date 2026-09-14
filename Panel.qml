import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Detail popup for io.github.katla50.nordpool-widget: the current hour, the
// shape of today (and tomorrow once Nord Pool publishes it around 13:00), the
// cheapest upcoming hours, and the settings that drive all of it.
//
// Two kinds of setting, deliberately separated:
//   * the data settings — area, nettleie, mva, unit, poll pace — live in
//     ~/.config/nordpool-widget/config.json and are written from here through
//     settings-write.sh. nordpool-watch.sh watches that file, so a change takes
//     effect within seconds without touching shell.json.
//   * the pill's presentation lives in this widget's shell.json entry (see
//     manifest.json), which is the Omarchy settings UI's job, not this panel's.
//
// Writes are optimistic: `pending` holds the value the user just picked and it
// takes precedence over the feed until the feed reports the same value, so the
// control never snaps back while the poll is in flight.
Panel {
  id: root
  moduleName: "io.github.katla50.nordpool-widget"
  ipcTarget: "io.github.katla50.nordpool-widget"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so the popout coordinator compares against that.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Injected by BarWidget so the panel and the pill never disagree.
  property var feed: null

  readonly property color textColor: Color.popups.text
  readonly property color mutedColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.55)
  readonly property color faintColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.35)
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: root.bar ? root.bar.urgent : Color.urgent
  readonly property color lowColor: "#2ea043"

  readonly property bool ready: root.feed !== null && root.feed.hasData
  readonly property var stats: root.feed !== null ? root.feed.todayStats : null
  readonly property var current: root.feed !== null ? root.feed.current : null
  readonly property string unitLabel: root.unitValue === "kr" ? "kr" : "øre"

  readonly property string configDir: Quickshell.env("HOME") + "/.config/nordpool-widget"
  readonly property string settingsScript: Qt.resolvedUrl("settings-write.sh").toString().replace("file://", "")

  property string writeError: ""

  // ---- Optimistic settings state, cleared implicitly once the feed agrees.
  property var pending: ({})
  readonly property bool gridOn: root.pendingOr("include_grid_tariff", root.feed !== null ? root.feed.includeGridTariff : false)
  readonly property bool vatOn: root.pendingOr("include_vat", root.feed !== null ? root.feed.includeVat : false)
  readonly property real gridOre: root.pendingOr("grid_tariff_ore", root.feed !== null ? root.feed.gridTariffOre : 0)
  readonly property real vatPercent: root.pendingOr("vat_percent", root.feed !== null ? root.feed.vatPercent : 0)
  readonly property string areaValue: root.pendingOr("area", root.feed !== null ? root.feed.area : "")
  readonly property string unitValue: root.pendingOr("unit", root.feed !== null ? root.feed.unit : "ore")

  readonly property var areaOptions: ["NO1", "NO2", "NO3", "NO4", "NO5"]
  readonly property var areaLabels: ["NO1", "NO2", "NO3", "NO4", "NO5"]
  readonly property var areaNames: ["Oslo", "Kristiansand", "Trondheim", "Tromsø", "Bergen"]
  readonly property var areaTooltips: [
    "NO1 Oslo / Østlandet",
    "NO2 Kristiansand / Sørlandet",
    "NO3 Trondheim / Midt-Norge",
    "NO4 Tromsø / Nord-Norge",
    "NO5 Bergen / Vestlandet"
  ]

  readonly property string areaName: {
    var index = root.areaOptions.indexOf(root.areaValue)
    return index < 0 ? "" : root.areaNames[index]
  }

  function pendingOr(key, actual) {
    var value = root.pending[key]
    return (value === undefined || value === actual) ? actual : value
  }

  function setPending(key, value) {
    var next = root.pending
    next[key] = value
    root.pending = next
  }

  // Formats øre/kWh for display. Reads `unitValue` (the optimistic value)
  // rather than the feed's own unit so a format change applies on click
  // instead of one poll later.
  function formatPrice(ore, shortForm) {
    if (ore === null || ore === undefined || isNaN(ore)) return "—"
    if (root.unitValue === "kr") {
      var kr = Number(ore) / 100
      return kr.toFixed(shortForm ? 2 : 3)
    }
    return shortForm ? String(Math.round(ore)) : Number(ore).toFixed(1)
  }

  function formatHour(hour) {
    return (hour < 10 ? "0" : "") + hour
  }

  function levelFor(total) {
    if (root.stats === null) return ""
    var avg = Number(root.stats.avg)
    var value = Number(total)
    if (!isFinite(avg) || avg <= 0 || !isFinite(value)) return ""
    var ratio = value / avg
    if (ratio <= 0.9) return "low"
    if (ratio >= 1.1) return "high"
    return "mid"
  }

  function levelColor(level) {
    if (level === "low") return root.lowColor
    if (level === "high") return root.urgentColor
    return root.textColor
  }

  function levelLabel(level) {
    if (level === "low") return "billig"
    if (level === "high") return "dyrt"
    if (level === "mid") return "normalt"
    return ""
  }

  // Bars for one delivery day. "past" bars are dimmed, the current hour is
  // painted in the accent colour so it stands out of its own chart.
  function seriesFor(list, isToday) {
    var out = []
    if (!list || list.length === 0) return out
    var hour = root.feed !== null ? root.feed.localHour : -1
    for (var i = 0; i < list.length; i++) {
      var state = "future"
      if (isToday && root.ready) {
        if (list[i].hour < hour) state = "past"
        else if (list[i].hour === hour) state = "current"
      }
      out.push({ value: Number(list[i].total), state: state })
    }
    return out
  }

  // Next 24 delivery hours, crossing midnight when tomorrow is published.
  function upcomingHours() {
    if (root.feed === null) return []
    var all = []
    var i
    for (i = 0; i < root.feed.today.length; i++) all.push(root.feed.today[i])
    for (i = 0; i < root.feed.tomorrow.length; i++) all.push(root.feed.tomorrow[i])
    var hour = root.feed.localHour
    var out = []
    for (i = 0; i < all.length; i++) {
      var isFuture = all[i].date > root.feed.localDate
        || (all[i].date === root.feed.localDate && all[i].hour >= hour)
      if (isFuture) out.push(all[i])
      if (out.length >= 24) break
    }
    return out
  }

  // The cheapest of the next 24 hours, for the "billigst" tag in the list.
  readonly property var cheapestKeys: {
    var keys = []
    if (root.feed === null) return keys
    for (var i = 0; i < root.feed.cheapest.length; i++) {
      var item = root.feed.cheapest[i]
      keys.push(item.date + "T" + item.hour)
    }
    return keys
  }

  function isCheapest(entry) {
    return root.cheapestKeys.indexOf(entry.date + "T" + entry.hour) >= 0
  }

  // ---- Keyboard cursor. A flat list of the interactive rows; j/k (or
  //      Up/Down) walks it, h/l adjusts whatever the current row holds. Built
  //      from a function rather than a property so the ids are resolved on
  //      demand instead of during root initialization.
  function cursorRows() {
    return [areaGroup, gridToggle, gridStepper, vatToggle, vatStepper, unitGroup, configLink]
  }

  property int cursorRow: -1

  function isCursorRow(item) {
    var rows = root.cursorRows()
    return root.cursorRow >= 0 && rows[root.cursorRow] === item
  }

  function focusRow(item) {
    var index = root.cursorRows().indexOf(item)
    if (index >= 0) root.cursorRow = index
  }

  function moveCursorRow(delta) {
    var rows = root.cursorRows()
    if (rows.length === 0) return
    var next = root.cursorRow < 0 ? (delta > 0 ? 0 : rows.length - 1) : root.cursorRow + delta
    if (next < 0) next = rows.length - 1
    if (next >= rows.length) next = 0
    root.cursorRow = next
    root.ensureVisible(rows[next])
  }

  function ensureVisible(item) {
    if (!item) return
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    if (top < scroll.contentY + 8) {
      scroll.contentY = Math.max(0, top - 8)
    } else if (bottom > scroll.contentY + scroll.height - 8) {
      scroll.contentY = Math.min(scroll.contentHeight - scroll.height, bottom - scroll.height + 8)
    }
  }

  function areaIndex() {
    var index = root.areaOptions.indexOf(root.areaValue)
    return index < 0 ? 0 : index
  }

  function cycleArea(delta) {
    var index = root.areaIndex() + delta
    if (index < 0) index = root.areaOptions.length - 1
    if (index >= root.areaOptions.length) index = 0
    root.writeSetting("area", root.areaOptions[index])
  }

  function cycleUnit(delta) {
    var options = ["ore", "kr"]
    var index = options.indexOf(root.unitValue)
    if (index < 0) index = 0
    index += delta
    if (index < 0) index = options.length - 1
    if (index >= options.length) index = 0
    root.writeSetting("unit", options[index])
  }

  function nudgeGrid(delta) {
    var next = Math.max(0, Math.min(100, Math.round((root.gridOre + delta) * 1000) / 1000))
    root.writeSetting("grid_tariff_ore", next)
  }

  function nudgeVat(delta) {
    var next = Math.max(0, Math.min(100, Math.round((root.vatPercent + delta) * 1000) / 1000))
    root.writeSetting("vat_percent", next)
  }

  function openConfig() {
    Quickshell.execDetached(["xdg-open", root.configDir + "/config.json"])
  }

  function writeSetting(key, value) {
    root.setPending(key, value)
    writer.pendingKey = key
    writer.pendingValue = String(value)
    writer.running = true
  }

  function open() {
    root.controller.show()
    root.cursorRow = -1
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Process {
    id: writer
    property string pendingKey: ""
    property string pendingValue: ""
    command: ["sh", root.settingsScript, root.configDir, writer.pendingKey, writer.pendingValue]
    onExited: function (code, status) {
      if (code !== 0) {
        root.writeError = "kunne ikke lagre " + writer.pendingKey
        return
      }
      root.writeError = ""
      // Re-poll immediately so the new setting lands without waiting out the
      // interval; the helper's own mtime watch is the fallback.
      if (root.hostWidget && typeof root.hostWidget.restartFeed === "function")
        root.hostWidget.restartFeed()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onActivateRequested: root.activateCursor()
      onMoveRequested: function (dx, dy) { root.handleMove(dx, dy) }

      Flickable {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(12)

          // ---------------------------------------------------------- header
          Item {
            width: parent.width
            height: titleLabel.implicitHeight

            Text {
              id: titleLabel
              anchors.left: parent.left
              width: parent.width - sourceLabel.implicitWidth - Style.space(12)
              text: "Strømpris " + (root.areaValue !== "" ? root.areaValue : "—")
                + (root.areaName !== "" ? " · " + root.areaName : "")
              color: root.textColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              id: sourceLabel
              anchors.right: parent.right
              anchors.baseline: titleLabel.baseline
              text: "Nord Pool"
              color: root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // ------------------------------------------------------ current hour
          Item {
            width: parent.width
            height: heroPrice.implicitHeight + heroNote.implicitHeight + Style.space(2)

            Text {
              id: heroPrice
              anchors.left: parent.left
              anchors.top: parent.top
              text: root.ready && root.current !== null
                ? root.formatPrice(root.current.total, false) + " " + root.unitLabel
                : (root.feed !== null && root.feed.error !== "" ? "n/a" : "—")
              color: root.ready && root.current !== null
                ? root.levelColor(root.levelFor(root.current.total))
                : root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
            }

            Text {
              id: levelBadge
              anchors.right: parent.right
              anchors.baseline: heroPrice.baseline
              text: {
                if (!root.ready || root.current === null) return ""
                var level = root.levelFor(root.current.total)
                return level === "" ? "" : root.levelLabel(level)
              }
              color: root.ready && root.current !== null
                ? root.levelColor(root.levelFor(root.current.total))
                : root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              id: heroNote
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: heroPrice.bottom
              wrapMode: Text.WordWrap
              text: {
                if (root.feed === null) return "laster…"
                if (!root.ready) return root.feed.error !== "" ? root.feed.error : "laster…"
                var lines = []
                if (root.current !== null) {
                  var add = []
                  if (root.gridOn) add.push("nettleie " + root.gridOre.toFixed(1))
                  if (root.vatOn) add.push("mva " + root.vatPercent.toFixed(0) + "%")
                  var breakdown = "Spot " + root.formatPrice(root.current.spot, false)
                  if (add.length > 0) breakdown += " + " + add.join(" + ")
                  lines.push("Nå kl. " + root.formatHour(root.current.hour) + "–"
                    + root.formatHour((root.current.hour + 1) % 24) + " · " + breakdown)
                }
                if (root.feed.ageSeconds >= 0)
                  lines.push("oppdatert for " + root.feed.ageSeconds + " s siden")
                return lines.join("\n")
              }
              color: root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ------------------------------------------------------- today stats
          Row {
            width: parent.width
            spacing: Style.space(12)
            visible: root.stats !== null

            Repeater {
              model: [
                { caption: "Lavest", value: root.stats !== null ? root.stats.min : NaN,
                  hour: root.stats !== null ? root.stats.minHour : -1 },
                { caption: "Snitt", value: root.stats !== null ? root.stats.avg : NaN, hour: -1 },
                { caption: "Høyest", value: root.stats !== null ? root.stats.max : NaN,
                  hour: root.stats !== null ? root.stats.maxHour : -1 }
              ]

              delegate: Column {
                required property var modelData
                width: (column.width - Style.space(24)) / 3
                spacing: Style.space(1)

                Text {
                  text: modelData.caption
                  color: root.faintColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  text: root.formatPrice(modelData.value, false)
                    + " " + root.unitLabel
                  color: root.textColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  text: modelData.hour >= 0 ? "kl. " + root.formatHour(modelData.hour) : "hele dagen"
                  color: root.faintColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.textColor
          }

          // ------------------------------------------------------- today chart
          PanelSectionHeader {
            text: "I dag"
            foreground: root.textColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Chart {
            width: parent.width
            height: Style.space(72)
            series: root.seriesFor(root.feed !== null ? root.feed.today : [], true)
            average: root.stats !== null ? root.stats.avg : NaN
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            barColor: root.textColor
            pastColor: root.textColor
            currentColor: root.accentColor
            averageColor: root.textColor
            labelColor: root.textColor
          }

          Text {
            width: parent.width
            visible: root.ready
            text: "Stiplet linje = dagsnitt · uthevet søyle = denne timen"
            color: root.faintColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          // -------------------------------------------------- cheapest upcoming
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.feed !== null && root.feed.cheapest.length > 0

            PanelSectionHeader {
              text: "Billigste timer framover"
              foreground: root.textColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Repeater {
              model: root.feed !== null ? root.feed.cheapest : []

              delegate: Item {
                required property var modelData
                width: column.width
                height: cheapestWhen.implicitHeight

                Text {
                  id: cheapestWhen
                  anchors.left: parent.left
                  text: (modelData.date === (root.feed !== null ? root.feed.localDate : "")
                    ? "I dag" : "I morgen")
                    + " kl. " + root.formatHour(modelData.hour) + "–"
                    + root.formatHour((modelData.hour + 1) % 24)
                  color: root.textColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  anchors.right: parent.right
                  anchors.baseline: cheapestWhen.baseline
                  text: root.formatPrice(modelData.total, false) + " " + root.unitLabel
                  color: root.lowColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.textColor
          }

          // ----------------------------------------------------------- tomorrow
          PanelSectionHeader {
            text: "I morgen"
            foreground: root.textColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Chart {
            width: parent.width
            height: Style.space(60)
            visible: root.feed !== null && root.feed.tomorrowAvailable
            series: root.seriesFor(root.feed !== null ? root.feed.tomorrow : [], false)
            average: {
              if (root.feed === null || !root.feed.tomorrowAvailable) return NaN
              var list = root.feed.tomorrow
              var sum = 0
              for (var i = 0; i < list.length; i++) sum += Number(list[i].total)
              return list.length > 0 ? sum / list.length : NaN
            }
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            barColor: root.textColor
            pastColor: root.textColor
            currentColor: root.accentColor
            averageColor: root.textColor
            labelColor: root.textColor
          }

          Text {
            width: parent.width
            visible: root.feed !== null && root.feed.tomorrowAvailable
            wrapMode: Text.WordWrap
            text: {
              if (root.feed === null || !root.feed.tomorrowAvailable) return ""
              var list = root.feed.tomorrow
              var min = Infinity
              var max = -Infinity
              var minHour = -1
              var maxHour = -1
              var sum = 0
              for (var i = 0; i < list.length; i++) {
                var value = Number(list[i].total)
                sum += value
                if (value < min) { min = value; minHour = list[i].hour }
                if (value > max) { max = value; maxHour = list[i].hour }
              }
              return "Min " + root.formatPrice(min, false) + " kl. " + root.formatHour(minHour)
                + " · snitt " + root.formatPrice(sum / list.length, false)
                + " · maks " + root.formatPrice(max, false) + " kl. " + root.formatHour(maxHour)
            }
            color: root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.feed !== null && !root.feed.tomorrowAvailable
            wrapMode: Text.WordWrap
            text: "Ikke publisert ennå — Nord Pool slipper morgendagens priser rundt kl. 13:00."
            color: root.mutedColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator {
            width: parent.width
            foreground: root.textColor
          }

          // -------------------------------------------------- upcoming hours
          PanelSectionHeader {
            text: "Neste 24 timer"
            foreground: root.textColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.upcomingHours()

              delegate: Item {
                required property var modelData
                width: column.width
                height: hourWhen.implicitHeight + Style.space(3)

                readonly property bool isNow: root.feed !== null && root.ready
                  && modelData.date === root.feed.localDate && modelData.hour === root.feed.localHour

                Text {
                  id: hourWhen
                  anchors.left: parent.left
                  text: (modelData.date === (root.feed !== null ? root.feed.localDate : "")
                    ? "" : "i morgen ")
                    + root.formatHour(modelData.hour) + "–"
                    + root.formatHour((modelData.hour + 1) % 24)
                    + (parent.isNow ? "  · nå" : "")
                    + (root.isCheapest(modelData) ? "  · billigst" : "")
                  color: parent.isNow ? root.accentColor
                    : (root.isCheapest(modelData) ? root.lowColor : root.textColor)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: parent.isNow
                }

                Text {
                  anchors.right: parent.right
                  anchors.baseline: hourWhen.baseline
                  text: root.formatPrice(modelData.total, false) + " " + root.unitLabel
                  color: root.mutedColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.textColor
          }

          // ---------------------------------------------------------- settings
          PanelSectionHeader {
            text: "Innstillinger"
            foreground: root.textColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Text {
            width: parent.width
            text: "Prisområde"
            color: root.textColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          ButtonGroup {
            id: areaGroup
            options: {
              var out = []
              for (var i = 0; i < root.areaOptions.length; i++)
                out.push({ value: root.areaOptions[i], label: root.areaLabels[i], tooltip: root.areaTooltips[i] })
              return out
            }
            value: root.areaValue
            foreground: root.textColor
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            cursorIndex: root.isCursorRow(areaGroup) ? root.areaIndex() : -1
            onChanged: function (value) { root.writeSetting("area", value) }
            onHovered: function (index, isHovered) { if (isHovered) root.focusRow(areaGroup) }
          }

          Toggle {
            id: gridToggle
            width: parent.width
            label: "Nettleie"
            description: "Fast påslag per kWh fra nettselskapet (varierer, typisk 15–25 øre)"
            checked: root.gridOn
            foreground: root.textColor
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            hasCursor: root.isCursorRow(gridToggle)
            onClicked: root.writeSetting("include_grid_tariff", !root.gridOn)
            onHovered: function (isHovered) { if (isHovered) root.focusRow(gridToggle) }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.gridOn

            Text {
              width: parent.width - Style.space(190)
              height: Style.spacing.controlHeight
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: "Nettleie"
              color: root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Stepper {
              id: gridStepper
              width: Style.space(182)
              value: root.gridOre
              step: 0.5
              from: 0
              to: 100
              decimals: 1
              suffix: "øre/kWh"
              cursorPart: root.isCursorRow(gridStepper) ? 0 : -1
              foreground: root.textColor
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onChanged: function (value) { root.writeSetting("grid_tariff_ore", value) }
            }
          }

          Toggle {
            id: vatToggle
            width: parent.width
            label: "Mva"
            description: "Legg på merverdiavgift på spot + nettleie (25 % i Norge)"
            checked: root.vatOn
            foreground: root.textColor
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            hasCursor: root.isCursorRow(vatToggle)
            onClicked: root.writeSetting("include_vat", !root.vatOn)
            onHovered: function (isHovered) { if (isHovered) root.focusRow(vatToggle) }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.vatOn

            Text {
              width: parent.width - Style.space(190)
              height: Style.spacing.controlHeight
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: "Mva-sats"
              color: root.mutedColor
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Stepper {
              id: vatStepper
              width: Style.space(182)
              value: root.vatPercent
              step: 1
              from: 0
              to: 100
              decimals: 0
              suffix: "%"
              cursorPart: root.isCursorRow(vatStepper) ? 0 : -1
              foreground: root.textColor
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onChanged: function (value) { root.writeSetting("vat_percent", value) }
            }
          }

          Text {
            width: parent.width
            text: "Visningsformat"
            color: root.textColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          ButtonGroup {
            id: unitGroup
            options: [
              { value: "ore", label: "øre/kWh" },
              { value: "kr", label: "kr/kWh" }
            ]
            value: root.unitValue
            foreground: root.textColor
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            cursorIndex: root.isCursorRow(unitGroup)
              ? (root.unitValue === "kr" ? 1 : 0) : -1
            onChanged: function (value) { root.writeSetting("unit", value) }
            onHovered: function (index, isHovered) { if (isHovered) root.focusRow(unitGroup) }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: {
              if (root.feed === null) return ""
              var parts = []
              parts.push("Kilde: Nord Pool day-ahead, " + (root.areaValue || "—") + " i NOK")
              parts.push("spotpris uten nettleie, avgifter og mva")
              if (root.feed.sourceUpdatedAt !== "")
                parts.push("Nord Pool oppdaterte " + root.feed.sourceUpdatedAt)
              return parts.join(" · ")
            }
            color: root.faintColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            id: configLink
            text: "Rediger config.json →"
            color: root.textColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.underline: configMouse.containsMouse || root.isCursorRow(configLink)

            MouseArea {
              id: configMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openConfig()
              onEntered: root.focusRow(configLink)
            }
          }

          Text {
            width: parent.width
            visible: root.writeError !== ""
            wrapMode: Text.WordWrap
            text: root.writeError
            color: root.urgentColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // h/l adjusts the row under the cursor; j/k (or Up/Down) walks the rows.
  function handleMove(dx, dy) {
    if (dy !== 0) {
      root.moveCursorRow(dy > 0 ? 1 : -1)
      return
    }
    if (dx === 0 || root.cursorRow < 0) return
    var row = root.cursorRows()[root.cursorRow]
    if (row === areaGroup) root.cycleArea(dx > 0 ? 1 : -1)
    else if (row === unitGroup) root.cycleUnit(dx > 0 ? 1 : -1)
    else if (row === gridStepper) root.nudgeGrid(dx > 0 ? 0.5 : -0.5)
    else if (row === vatStepper) root.nudgeVat(dx > 0 ? 1 : -1)
  }

  function activateCursor() {
    if (root.cursorRow < 0) return
    var row = root.cursorRows()[root.cursorRow]
    if (row === gridToggle) root.writeSetting("include_grid_tariff", !root.gridOn)
    else if (row === vatToggle) root.writeSetting("include_vat", !root.vatOn)
    else if (row === configLink) root.openConfig()
  }
}
