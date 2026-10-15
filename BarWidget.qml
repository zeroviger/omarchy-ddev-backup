import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "solla.ddev-backup"

  readonly property bool busy: panelLoader.item ? panelLoader.item.busy === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("host" in target) target.host = root
  }

  // KeyboardPanel chiude il popup chiamando owner.close() (owner = questo
  // widget). Senza questa funzione ripiega su "open = false", che rompe il
  // binding open: root.opened del pannello e non si riapre più.
  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    useActiveColor: false
    tooltipText: root.busy ? "DDEV Backup — operazione in corso…" : "DDEV Backup"
    onPressed: root.toggle()

    Rectangle {
      visible: root.busy
      width: Style.space(7)
      height: Style.space(7)
      radius: width / 2
      color: Color.accent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(2)
      anchors.topMargin: Style.space(2)
      border.color: Color.popups.background
      border.width: 1
    }
  }
}
