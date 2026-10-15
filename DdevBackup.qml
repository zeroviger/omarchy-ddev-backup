import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Icona nella barra + popup. Estende Panel di Omarchy, che gestisce lo stato
// aperto/chiuso (PanelController) e l'IPC:
//   qs -p /usr/share/omarchy/shell ipc call mcp64.ddev-backup toggle
Panel {
  id: root

  moduleName: "mcp64.ddev-backup"
  ipcTarget: "mcp64.ddev-backup"

  // Panel è un Item senza dimensioni proprie: senza queste la barra gli dà
  // larghezza zero e l'icona non è cliccabile.
  readonly property int barSlot: Style.bar.iconFont + Style.space(10)
  readonly property real openPanelIndicatorWidth: Style.bar.iconFont
  readonly property real openPanelIndicatorHeight: Style.bar.iconFont
  implicitWidth: bar && bar.vertical ? bar.barSize : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  readonly property string cli: Qt.resolvedUrl("bin/ddev-backup").toString().replace(/^file:\/\//, "")

  property var projects: []
  property var orphans: []
  property string backupDir: ""
  property var expanded: ({})
  property bool loaded: false

  // Una sola operazione alla volta (backup, restore o delete).
  property bool busy: false
  property string busyName: ""
  property string busyKind: ""
  property string statusText: ""
  property string errorText: ""
  property string doneText: ""

  // Conferma esplicita prima di restore e delete:
  // { kind: "restore"|"delete", path, name, title, message }
  property var pendingConfirm: null

  readonly property int maxListBytes: 5 * 1024 * 1024
  readonly property int maxLineLength: 300

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int totalBackups: {
    var n = 0
    for (var i = 0; i < projects.length; i++) n += projects[i].backups.length
    for (var j = 0; j < orphans.length; j++) n += orphans[j].backups.length
    return n
  }

  onOpenedChanged: {
    if (opened) root.reload()
    else root.pendingConfirm = null
  }

  function reload() {
    if (!listProc.running) listProc.running = true
  }

  function clip(s) {
    s = String(s)
    return s.length > root.maxLineLength ? s.slice(0, root.maxLineLength) + "…" : s
  }

  function applyListing(obj) {
    root.backupDir = String(obj.backupDir || "")
    var list = (obj.projects || []).slice()
    list.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
    root.projects = list
    root.orphans = obj.orphans || []
    root.loaded = true
  }

  function formatSize(bytes) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var v = Number(bytes) || 0
    var i = 0
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
    return (i === 0 ? v : v.toFixed(1)) + " " + units[i]
  }

  function formatDate(mtime) {
    return Qt.formatDateTime(new Date(mtime * 1000), "dd/MM/yyyy HH:mm")
  }

  function backupTitle(b) {
    return root.formatDate(b.mtime) + (b.file.indexOf("-pre-restore") !== -1 ? "  · pre-restore" : "")
  }

  function toggleExpanded(name) {
    var e = JSON.parse(JSON.stringify(root.expanded))
    e[name] = !e[name]
    root.expanded = e
  }

  function run(kind, name, args) {
    if (root.busy) return
    root.busy = true
    root.busyKind = kind
    root.busyName = name
    root.errorText = ""
    root.doneText = ""
    root.statusText = kind === "backup" ? "Backup di " + name + "…"
      : kind === "restore" ? "Ripristino di " + name + "…"
      : "Eliminazione…"
    opProc.command = ["/usr/bin/timeout", "3600", root.cli].concat(args)
    opProc.running = false
    opProc.running = true
  }

  function backup(name) {
    root.run("backup", name, ["backup", name])
  }

  function askRestore(name, b, registered) {
    root.pendingConfirm = {
      kind: "restore",
      path: b.path,
      name: name,
      title: "Ripristinare " + name + "?",
      message: "Verranno ripristinati file e database al " + root.formatDate(b.mtime) + ". "
        + (registered
          ? "Lo stato attuale viene salvato prima in un backup di sicurezza."
          : "Il progetto verrà ricreato nella sua cartella originale.")
    }
  }

  function askRestoreFile(path) {
    var file = path.split("/").pop()
    root.pendingConfirm = {
      kind: "restore",
      path: path,
      name: file,
      title: "Ripristinare " + file + "?",
      message: "Il progetto verrà ripristinato nella sua cartella originale. Se esiste già, lo stato attuale viene salvato prima."
    }
  }

  function askDelete(name, b) {
    root.pendingConfirm = {
      kind: "delete",
      path: b.path,
      name: name,
      title: "Eliminare il backup?",
      message: name + " — " + root.backupTitle(b) + " (" + root.formatSize(b.size) + "). L'operazione non è reversibile."
    }
  }

  function confirmPending() {
    var c = root.pendingConfirm
    root.pendingConfirm = null
    if (!c) return
    if (c.kind === "restore") root.run("restore", c.name, ["restore", c.path, "--force"])
    else if (c.kind === "delete") root.run("delete", c.name, ["delete", c.path])
  }

  function pickFile() {
    if (root.busy || pickProc.running) return
    pickProc.running = true
  }

  function openBackupDir() {
    if (root.backupDir) Qt.openUrlExternally(Util.fileUrl(root.backupDir))
  }

  Process {
    id: listProc
    command: ["/usr/bin/timeout", "60", "/usr/bin/bash", "-c",
      root.shQuote(root.cli) + " list | /usr/bin/head -c " + root.maxListBytes]
    stdout: SplitParser {
      onRead: data => {
        try {
          const obj = JSON.parse(data)
          if (obj) root.applyListing(obj)
        } catch (e) {}
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.loaded) root.errorText = "Impossibile leggere i progetti DDEV — Docker è attivo?"
    }
  }

  function shQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  Process {
    id: opProc
    stdout: SplitParser {
      onRead: data => {
        if (data.indexOf("STEP: ") === 0) root.statusText = root.clip(data.slice(6))
        else if (data.indexOf("DONE: ") === 0) root.doneText = root.clip(data.slice(6))
      }
    }
    stderr: SplitParser {
      onRead: data => {
        var line = data.indexOf("ERROR: ") === 0 ? data.slice(7) : data
        if (line.trim() === "") return
        root.errorText = root.clip(root.errorText === "" ? line : root.errorText + "\n" + line)
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.statusText = root.busyKind === "backup" ? "Backup completato: " + root.doneText.split("/").pop()
          : root.busyKind === "restore" ? "Restore completato in " + root.doneText
          : "Backup eliminato"
      } else {
        root.statusText = ""
        if (root.errorText === "") root.errorText = "Operazione fallita (exit " + exitCode + ")"
      }
      root.busy = false
      root.busyKind = ""
      root.busyName = ""
      root.reload()
    }
  }

  Process {
    id: pickProc
    command: ["omarchy", "file", "select", "--title", "Scegli un backup DDEV", "--extensions", "zip"]
    stdout: SplitParser {
      onRead: data => {
        var path = data.trim()
        if (path.indexOf("file://") === 0) path = decodeURIComponent(path.slice(7))
        if (path !== "") root.askRestoreFile(path)
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    text: ""
    useActiveColor: false
    tooltipText: root.busy ? "DDEV Backup — " + root.statusText : "DDEV Backup"
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

  KeyboardPanel {
    id: popupPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popupPanel.fittedContentWidth(Style.space(440))
    contentHeight: popupPanel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.pendingConfirm ? root.pendingConfirm = null : root.close()

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: parent.width
          spacing: Style.space(10)

          PanelHero {
            title: "DDEV Backup"
            meta: root.loaded ? (root.projects.length + " progetti · " + root.totalBackups + " backup") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: ""
                  tooltipText: "Apri la cartella dei backup"
                  foreground: root.foreground
                  enabled: root.backupDir !== ""
                  onClicked: root.openBackupDir()
                }

                PanelActionButton {
                  iconText: ""
                  tooltipText: "Ripristina da un file .zip…"
                  foreground: root.foreground
                  enabled: !root.busy
                  onClicked: root.pickFile()
                }

                PanelActionButton {
                  iconText: "↻"
                  tooltipText: "Aggiorna"
                  foreground: root.foreground
                  onClicked: root.reload()
                }
              }
            }
          }

          // Conferma per restore / delete.
          Rectangle {
            visible: root.pendingConfirm !== null
            width: parent.width
            implicitHeight: confirmColumn.implicitHeight + Style.space(20)
            height: implicitHeight
            radius: Style.cornerRadius
            color: Util.alpha(Color.urgent, 0.08)
            border.color: Util.alpha(Color.urgent, 0.5)
            border.width: 1

            Column {
              id: confirmColumn
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: root.pendingConfirm ? root.pendingConfirm.title : ""
                font.bold: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width
                elide: Text.ElideRight
              }

              Text {
                text: root.pendingConfirm ? root.pendingConfirm.message : ""
                width: parent.width
                wrapMode: Text.WordWrap
                color: Util.alpha(root.foreground, 0.8)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                spacing: Style.space(8)
                layoutDirection: Qt.RightToLeft
                width: parent.width

                Button {
                  text: root.pendingConfirm && root.pendingConfirm.kind === "delete" ? "Elimina" : "Ripristina"
                  bordered: true
                  foreground: Color.urgent
                  onClicked: root.confirmPending()
                }

                Button {
                  text: "Annulla"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.pendingConfirm = null
                }
              }
            }
          }

          Row {
            visible: root.statusText !== ""
            width: parent.width
            spacing: Style.space(6)

            Text {
              id: spinner
              visible: root.busy
              text: "↻"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              RotationAnimation on rotation {
                running: root.busy
                from: 0
                to: 360
                duration: 1000
                loops: Animation.Infinite
              }
            }

            Text {
              width: parent.width - (spinner.visible ? spinner.width + Style.space(6) : 0)
              text: root.statusText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.foreground, 0.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: Color.urgent
            wrapMode: Text.WrapAnywhere
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.loaded && root.projects.length === 0 && root.orphans.length === 0
            width: parent.width
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Nessun progetto DDEV trovato."
            color: Util.alpha(root.foreground, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.projects
            delegate: projectCard
          }

          PanelSectionHeader {
            visible: root.orphans.length > 0
            width: parent.width
            text: "Progetti non più registrati — " + root.orphans.length
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.orphans
            delegate: projectCard
          }

          Text {
            visible: root.backupDir !== ""
            width: parent.width
            text: "Backup in " + root.backupDir
            color: Util.alpha(root.foreground, 0.45)
            elide: Text.ElideMiddle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Usato sia per i progetti registrati sia per quelli "orfani" (hanno solo
  // name e backups: niente status/approot, niente pulsante Backup).
  Component {
    id: projectCard

    Rectangle {
      id: card
      required property var modelData
      readonly property bool registered: modelData.approot !== undefined
      readonly property bool isRunning: modelData.status === "running"
      readonly property bool isBusy: root.busy && root.busyName === modelData.name
      readonly property bool isExpanded: root.expanded[modelData.name] === true
      readonly property var latest: modelData.backups.length > 0 ? modelData.backups[0] : null

      width: column.width
      implicitHeight: cardColumn.implicitHeight + Style.space(16)
      height: implicitHeight
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, cardHover.hovered ? 0.06 : 0.03)
      border.color: Util.alpha(root.foreground, 0.12)
      border.width: 1

      HoverHandler { id: cardHover }

      Column {
        id: cardColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(8)
        spacing: Style.space(6)

        RowLayout {
          width: parent.width
          spacing: Style.space(10)

          Rectangle {
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            Layout.alignment: Qt.AlignVCenter
            color: !card.registered ? "transparent" : (card.isRunning ? Color.accent : Color.muted)
            border.color: Color.muted
            border.width: card.registered ? 0 : 1
          }

          Column {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              text: card.modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.bold: true
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: card.isBusy ? root.statusText
                : (card.latest
                  ? card.modelData.backups.length + " backup · ultimo " + root.formatDate(card.latest.mtime)
                  : "nessun backup")
              color: Util.alpha(root.foreground, 0.65)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          PanelActionButton {
            visible: card.modelData.backups.length > 0
            iconText: card.isExpanded ? "▾" : "▸"
            tooltipText: card.isExpanded ? "Nascondi i backup" : "Mostra i backup"
            foreground: root.foreground
            onClicked: root.toggleExpanded(card.modelData.name)
          }

          PanelActionButton {
            visible: card.registered
            iconText: card.isBusy && root.busyKind === "backup" ? "…" : ""
            tooltipText: card.isRunning ? "Crea un backup ora"
              : "Crea un backup ora (il progetto viene avviato e poi fermato)"
            foreground: root.foreground
            enabled: !root.busy
            onClicked: root.backup(card.modelData.name)
          }
        }

        Column {
          visible: card.isExpanded
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: card.isExpanded ? card.modelData.backups : []

            delegate: Rectangle {
              id: backupRow
              required property var modelData
              width: parent.width
              implicitHeight: backupLayout.implicitHeight + Style.space(6)
              height: implicitHeight
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, rowHover.hovered ? 0.06 : 0)

              HoverHandler { id: rowHover }

              RowLayout {
                id: backupLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(18)
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: root.backupTitle(backupRow.modelData)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  text: root.formatSize(backupRow.modelData.size)
                  color: Util.alpha(root.foreground, 0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                PanelActionButton {
                  iconText: ""
                  tooltipText: "Ripristina questo backup"
                  foreground: root.foreground
                  enabled: !root.busy
                  onClicked: root.askRestore(card.modelData.name, backupRow.modelData, card.registered)
                }

                PanelActionButton {
                  iconText: ""
                  tooltipText: "Elimina questo backup"
                  foreground: root.foreground
                  hoverColor: Color.urgent
                  enabled: !root.busy
                  onClicked: root.askDelete(card.modelData.name, backupRow.modelData)
                }
              }
            }
          }
        }
      }
    }
  }
}
