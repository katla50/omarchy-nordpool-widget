import QtQuick
import qs.Commons

// Hourly price bar chart for one Nord Pool delivery day.
//
// `series` is an array of { value, state } where state is "past", "current" or
// "future". Bars are scaled to the day's own maximum, so the chart shows the
// shape of the day rather than an absolute scale — the panel states min/avg/max
// in text, and the dashed line marks the daily average.
Canvas {
  id: chart

  property var series: []
  property real average: NaN
  property int labelEvery: 6
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption

  property color barColor: Color.foreground
  property color pastColor: Color.foreground
  property real pastAlpha: 0.3
  property color currentColor: Color.accent
  property color averageColor: Color.foreground
  property real averageAlpha: 0.5
  property color labelColor: Color.foreground

  // Room under the bars for the hour ticks.
  property int labelGutter: 14
  property real barGap: 2

  onSeriesChanged: requestPaint()
  onAverageChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  function barState(index) {
    var item = series[index]
    if (!item) return "future"
    return item.state === "past" || item.state === "current" ? item.state : "future"
  }

  function colorFor(index) {
    var state = barState(index)
    if (state === "current") return currentColor
    if (state === "past") return Qt.rgba(pastColor.r, pastColor.g, pastColor.b, pastAlpha)
    return barColor
  }

  function fontSpec() {
    var family = String(fontFamily || "")
    if (family.indexOf(" ") >= 0) family = "\"" + family + "\""
    return Math.max(8, Math.round(fontSize)) + "px " + family
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()

    var data = chart.series || []
    if (data.length === 0 || width <= 0 || height <= 0) return

    var plotHeight = Math.max(1, height - chart.labelGutter)
    var max = -Infinity
    var min = Infinity
    for (var i = 0; i < data.length; i++) {
      var v = Number(data[i].value)
      if (!isFinite(v)) continue
      if (v > max) max = v
      if (v < min) min = v
    }
    if (!isFinite(max)) return
    // A flat day would divide by zero; fall back to the magnitude so the bars
    // render as a full-height block instead of nothing.
    if (max <= 0) max = 1
    if (min > 0) min = 0

    var slot = width / data.length
    var barWidth = Math.max(1, slot - chart.barGap)

    for (var b = 0; b < data.length; b++) {
      var value = Number(data[b].value)
      if (!isFinite(value)) value = 0
      var barHeight = Math.max(1, (value / max) * plotHeight)
      ctx.fillStyle = chart.colorFor(b)
      ctx.fillRect(b * slot + chart.barGap / 2, plotHeight - barHeight, barWidth, barHeight)
    }

    if (!isNaN(chart.average) && chart.average > 0) {
      var avgY = plotHeight - (chart.average / max) * plotHeight
      ctx.save()
      ctx.setLineDash([3, 3])
      ctx.strokeStyle = Qt.rgba(chart.averageColor.r, chart.averageColor.g, chart.averageColor.b, chart.averageAlpha)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, avgY)
      ctx.lineTo(width, avgY)
      ctx.stroke()
      ctx.restore()
    }

    if (chart.labelEvery > 0) {
      ctx.font = chart.fontSpec()
      ctx.fillStyle = Qt.rgba(chart.labelColor.r, chart.labelColor.g, chart.labelColor.b, 0.55)
      ctx.textBaseline = "top"
      for (var h = 0; h < data.length; h += chart.labelEvery) {
        var label = (h < 10 ? "0" : "") + h
        var x = h * slot + slot / 2
        if (x > width - 14) x = width - 14
        ctx.fillText(label, x, plotHeight + 2)
      }
    }
  }
}
