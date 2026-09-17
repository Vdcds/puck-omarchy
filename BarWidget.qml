import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "vedant.puck"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property int openCount: panelLoader.item ? panelLoader.item.openCount : 0
  readonly property bool needsCare: panelLoader.item ? panelLoader.item.needsCare : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: eyes.implicitWidth + Style.space(18)
    active: root.needsCare
    horizontalMargin: 7
    tooltipText: root.openCount > 0 ? root.openCount + " little promise(s) waiting — Puck is watching" : "Puck is watching, lovingly"
    onPressed: function(button) {
      if (button === Qt.MiddleButton && panelLoader.item) panelLoader.item.refresh()
      else root.togglePanel()
    }
    CuteEyes {
      id: eyes
      anchors.centerIn: parent
      alert: root.needsCare
    }
  }
}
