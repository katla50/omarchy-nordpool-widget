import QtQuick
import Quickshell
import Quickshell.Io

// Nord Pool day-ahead prices, fed line by line from nordpool-watch.sh.
//
// The helper owns everything that should not run inside the long-lived shell
// process: reading ~/.config/nordpool-widget/config.json, the two GETs against
// the Nord Pool Data Portal, 15-minute -> hourly aggregation, the nettleie/mva
// maths and the cheapest-hour ranking. It prints one JSON object per poll, so
// this file is a thin parser over that stream.
//
// All prices this file exposes are in **øre/kWh** regardless of the configured
// display unit; `unit` is just the label the pill should use. Converting in one
// place keeps the panel and the pill from disagreeing.
//
// A failed poll never blanks a working price: `error` is set, the last good
// arrays stay, and `hasData` keeps telling the truth.
Item {
  id: feed

  // ---- Config echo, straight from config.json via the helper. The panel and
  //      the pill read these rather than the file, so they can never drift.
  property string area: ""
  property string unit: "ore"
  property bool includeGridTariff: false
  property real gridTariffOre: 0
  property bool includeVat: false
  property real vatPercent: 0
  property int cheapestCount: 3
  property int pollIntervalSeconds: 900

  // ---- Prices, all in øre/kWh.
  property var today: []
  property var tomorrow: []
  property var current: null
  property var todayStats: null
  property var cheapest: []
  property bool tomorrowAvailable: false
  property int localHour: -1
  property string localDate: ""
  property string sourceUpdatedAt: ""

  property string error: ""
  property var lastSuccessAt: null

  readonly property bool hasData: today !== null && today.length > 0
  readonly property bool adjustmentsOn: includeGridTariff || includeVat

  // `Date.now()` is not a notifyable property, so a binding that reads only it
  // is evaluated once and then frozen — the panel's "oppdatert for N s siden"
  // would sit at 0 forever. `tick` is bumped by a timer to drive re-evaluation.
  property int tick: 0
  readonly property int ageSeconds: {
    var beat = tick
    if (lastSuccessAt === null) return -1
    return Math.max(0, Math.round((Date.now() - lastSuccessAt) / 1000))
  }

  readonly property string configDir: Quickshell.env("HOME") + "/.config/nordpool-widget"
  readonly property string scriptPath: Qt.resolvedUrl("nordpool-watch.sh").toString().replace("file://", "")

  // The panel restarts the watcher right after it writes a setting so the new
  // area/tariff lands immediately instead of on the next poll interval. The
  // helper also re-polls on a config mtime change, so this is belt and braces.
  //
  // `restarting` marks a deliberate bounce: stopping the process makes
  // Quickshell emit `exited` just like a crash does, and without the flag that
  // would surface as "prisvakt stoppet" and dim the pill on every settings
  // change. The revive is a quick bounce rather than the crash backoff.
  property bool restarting: false

  function restart() {
    feed.restarting = true
    watcher.running = false
    reviveTimer.interval = 50
    reviveTimer.restart()
  }

  function revive(afterMs) {
    reviveTimer.interval = afterMs
    reviveTimer.restart()
  }

  function handleLine(line) {
    var doc
    try {
      doc = JSON.parse(line)
    } catch (e) {
      return
    }

    if (typeof doc.error === "string" && doc.error !== "") {
      feed.error = doc.error
      return
    }
    if (typeof doc.area !== "string") return

    feed.area = doc.area
    feed.unit = doc.unit === "kr" ? "kr" : "ore"
    feed.includeGridTariff = doc.includeGridTariff === true
    feed.gridTariffOre = Number(doc.gridTariffOre) || 0
    feed.includeVat = doc.includeVat === true
    feed.vatPercent = Number(doc.vatPercent) || 0
    feed.cheapestCount = Number(doc.cheapestCount) || 3
    feed.pollIntervalSeconds = Number(doc.pollIntervalSeconds) || 900

    feed.today = Array.isArray(doc.today) ? doc.today : []
    feed.tomorrow = Array.isArray(doc.tomorrow) ? doc.tomorrow : []
    feed.current = doc.current && typeof doc.current === "object" ? doc.current : null
    feed.todayStats = doc.todayStats && typeof doc.todayStats === "object" ? doc.todayStats : null
    feed.cheapest = Array.isArray(doc.cheapest) ? doc.cheapest : []
    feed.tomorrowAvailable = doc.tomorrowAvailable === true
    feed.localHour = Number(doc.localHour)
    feed.localDate = typeof doc.localDate === "string" ? doc.localDate : ""
    feed.sourceUpdatedAt = typeof doc.sourceUpdatedAt === "string" ? doc.sourceUpdatedAt : ""

    feed.error = ""
    feed.lastSuccessAt = Date.now()
  }

  Process {
    id: watcher
    running: true
    command: ["sh", feed.scriptPath, feed.configDir]

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { feed.handleLine(line) }
    }

    // The helper owns its own retry pace; if it ever dies (config dir removed
    // mid-run, killed process) bring it back after a short beat. A deliberate
    // bounce sets `restarting` first and is revived by restart() itself.
    onExited: function (code, status) {
      if (feed.restarting) return
      feed.error = "prisvakt stoppet (exit " + code + ")"
      feed.revive(5000)
    }
  }

  Timer {
    id: reviveTimer
    interval: 5000
    onTriggered: {
      feed.restarting = false
      watcher.running = true
    }
  }

  // Drives ageSeconds' re-evaluation once a second.
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: feed.tick++
  }
}
