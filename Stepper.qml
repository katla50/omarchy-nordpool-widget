import QtQuick
import qs.Commons
import qs.Ui

// Small −/+ stepper for the two numeric settings (nettleie in øre/kWh, mva in
// percent). NumberField in the kit is integer-only and a grid tariff is not, so
// this keeps its own decimal handling.
//
// Children are sized to the row height instead of anchored: a Row positions its
// children itself and QML rejects anchors on them, so centring is done by giving
// each child the full row height and letting its own content centre inside.
//
// The panel drives `cursorPart` (0 = minus, 1 = plus) so the panel keyboard
// cursor can highlight one half of the control; -1 means the mouse owns it.
Row {
  id: root

  property real value: 0
  property real step: 1
  property real from: 0
  property real to: 100
  property int decimals: 1
  property string suffix: ""
  property int cursorPart: -1

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  property real valueWidth: Style.space(78)
  readonly property real rowHeight: Style.spacing.controlHeight

  signal changed(real value)

  function format(value) {
    return Number(value).toFixed(root.decimals)
  }

  function nudge(delta) {
    var next = root.value + delta
    if (next < root.from) next = root.from
    if (next > root.to) next = root.to
    // Kill float drift from repeated 0.5 additions (18.6 -> 18.999999...).
    next = Math.round(next * 1000) / 1000
    if (next !== root.value) root.changed(next)
  }

  height: root.rowHeight
  spacing: Style.spacing.xs

  Button {
    height: root.rowHeight
    text: "−"
    fontFamily: root.fontFamily
    foreground: root.foreground
    accent: root.accent
    bordered: true
    focusable: false
    hasCursor: root.cursorPart === 0
    tooltipText: "Senk med " + root.format(root.step)
    onClicked: root.nudge(-root.step)
  }

  Text {
    height: root.rowHeight
    width: root.valueWidth
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    text: root.format(root.value) + (root.suffix !== "" ? " " + root.suffix : "")
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  Button {
    height: root.rowHeight
    text: "+"
    fontFamily: root.fontFamily
    foreground: root.foreground
    accent: root.accent
    bordered: true
    focusable: false
    hasCursor: root.cursorPart === 1
    tooltipText: "Øk med " + root.format(root.step)
    onClicked: root.nudge(root.step)
  }
}
