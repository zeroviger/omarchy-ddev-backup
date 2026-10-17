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

  // Form "ripristina come copia", aperto su un backup completo (path dello zip).
  property string copyFormFor: ""
  property string copyName: ""
  property string copyDir: ""
  property bool copyDirEdited: false
  property string copyParent: ""
  property string copyError: ""

  // Lettura del manifest di uno zip scelto dal file chooser (per l'anteprima).
  property string inspectPath: ""
  property string inspectBuffer: ""

  // Progetto per cui è aperto il form "backup del database" (nota facoltativa).
  property string dbFormFor: ""
  property string dbLabel: ""

  // Vista impostazioni: valori in modifica, copiati da `settings` all'apertura
  // e salvati con `omarchy bar set` nella voce del widget in shell.json (dove
  // li legge anche bin/ddev-backup). I default coincidono con il manifest.
  property bool showSettings: false
  property string draftBackupDir: ""
  property int draftKeep: 10
  property int draftKeepDb: 20
  property string draftExclude: ""
  property bool draftNotify: true
  property string settingsError: ""

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
    if (opened) {
      root.reload()
    } else {
      root.pendingConfirm = null
      root.dbFormFor = ""
      root.copyFormFor = ""
      root.showSettings = false
    }
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
    return root.formatDate(b.mtime)
      + (b.kind === "database" ? "  · solo DB" : "")
      + (b.safety ? "  · pre-restore" : "")
  }

  function toggleExpanded(name) {
    var e = JSON.parse(JSON.stringify(root.expanded))
    e[name] = !e[name]
    root.expanded = e
  }

  function run(kind, name, args) {
    root.runCommand(kind, name, ["/usr/bin/timeout", "3600", root.cli].concat(args))
  }

  function runCommand(kind, name, command) {
    if (root.busy) return
    root.busy = true
    root.busyKind = kind
    root.busyName = name
    root.errorText = ""
    root.doneText = ""
    root.statusText = kind === "backup" ? "Backup di " + name + "…"
      : kind === "restore" ? "Ripristino di " + name + "…"
      : kind === "start" ? "Avvio di " + name + "…"
      : kind === "stop" ? "Arresto di " + name + "…"
      : "Eliminazione…"
    opProc.command = command
    opProc.running = false
    opProc.running = true
  }

  // ddev scrive l'avanzamento su stderr: lo si scarta e in caso di errore si
  // emette una sola riga ERROR, come fa bin/ddev-backup.
  function startStop(p) {
    var action = p.status === "running" ? "stop" : "start"
    // -y (salta le conferme) esiste solo per start: ddev stop lo rifiuta.
    var args = action === "start" ? ["start", "-y", p.name] : ["stop", p.name]
    root.runCommand(action, p.name, ["/usr/bin/timeout", "300", "/usr/bin/bash", "-c",
      "ddev \"$@\" >/dev/null 2>&1 || { echo \"ERROR: ddev $1 ${@: -1} non riuscito (Docker è attivo?)\" >&2; exit 1; }",
      "_"].concat(args))
  }

  function openTerminal(p) {
    if (!p.approot) return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--dir=" + p.approot])
    root.close()
  }

  function backup(name) {
    root.run("backup", name, ["backup", name])
  }

  function openDbForm(name) {
    root.dbFormFor = root.dbFormFor === name ? "" : name
    root.dbLabel = ""
  }

  function backupDatabase(name) {
    var args = ["backup", name, "--db-only"]
    var label = root.dbLabel.trim()
    if (label !== "") args = args.concat(["--label", label])
    root.dbFormFor = ""
    root.dbLabel = ""
    root.run("backup", name, args)
  }

  function askRestore(name, b, registered) {
    var dbOnly = b.kind === "database"
    var message
    if (dbOnly) {
      message = "Verranno ripristinati solo i database (" + (b.databases || []).join(", ") + ") al "
        + root.formatDate(b.mtime) + ". I file non vengono toccati. "
        + (registered
          ? "I database attuali vengono salvati prima in un backup di sicurezza."
          : "Serve un progetto DDEV esistente con questo nome.")
    } else {
      message = "Verranno ripristinati file e database al " + root.formatDate(b.mtime) + ". "
        + (registered
          ? "Lo stato attuale viene salvato prima in un backup di sicurezza."
          : "Il progetto verrà ricreato nella sua cartella originale.")
    }
    root.pendingConfirm = {
      kind: "restore",
      path: b.path,
      name: name,
      title: (dbOnly ? "Ripristinare il database di " : "Ripristinare ") + name + "?",
      message: message,
      details: root.backupDetails(b)
    }
  }

  function isRegistered(name) {
    for (var i = 0; i < root.projects.length; i++) if (root.projects[i].name === name) return true
    return false
  }

  // Righe [etichetta, valore] mostrate nel riquadro di conferma del restore.
  function backupDetails(b) {
    var rows = []
    var created = b.created ? new Date(b.created) : new Date(b.mtime * 1000)
    rows.push(["Data", Qt.formatDateTime(created, "dd/MM/yyyy HH:mm:ss")])
    rows.push(["Tipo", b.kind === "database" ? "Solo database" : "Completo (file + database)"])
    if (b.label) rows.push(["Nota", b.label])
    var dbs = (b.databases || []).join(", ")
    rows.push(["Database", (b.dbType ? b.dbType + " " + b.dbVersion : "—") + (dbs ? " · " + dbs : "")])
    if (b.git && b.git.commit) {
      rows.push(["Git", (b.git.branch || "(detached)") + " @ " + String(b.git.commit).slice(0, 8)
        + (b.git.dirty ? " · con modifiche non committate" : "")])
    } else {
      rows.push(["Git", "nessun repository"])
    }
    if (b.kind !== "database" && b.approot) rows.push(["Cartella", b.approot])
    rows.push(["Origine", (b.host || "?") + (b.ddevVersion ? " · DDEV " + b.ddevVersion : "")])
    if (b.size !== undefined) rows.push(["Dimensione", root.formatSize(b.size)])
    return rows
  }

  // Manifest letto con `ddev-backup inspect` -> stessa forma delle voci di `list`.
  function backupFromManifest(m, path) {
    return {
      path: path,
      mtime: Date.parse(m.created) / 1000 || 0,
      kind: m.kind || "full",
      label: m.label === "pre-restore" ? "" : (m.label || ""),
      safety: m.safety === true || m.label === "pre-restore",
      databases: ((m.database && m.database.databases) || []).map(function(d) { return d.name }),
      created: m.created || "",
      host: m.host || "",
      approot: (m.project && m.project.approot) || "",
      projectType: (m.project && m.project.type) || "",
      ddevVersion: (m.project && m.project.ddevVersion) || "",
      dbType: (m.database && m.database.type) || "",
      dbVersion: (m.database && m.database.version) || "",
      git: m.git || null
    }
  }

  function askRestoreFile(path) {
    if (inspectProc.running) return
    root.errorText = ""
    root.inspectPath = path
    root.inspectBuffer = ""
    inspectProc.command = ["/usr/bin/timeout", "30", root.cli, "inspect", path]
    inspectProc.running = true
  }

  function openCopyForm(name, b) {
    if (root.copyFormFor === b.path) { root.copyFormFor = ""; return }
    var approot = b.approot || ""
    root.copyParent = approot ? approot.slice(0, approot.lastIndexOf("/")) : ""
    root.copyDirEdited = false
    root.copyError = ""
    root.copyName = name + "-copia"
    root.copyDir = root.copyParent ? root.copyParent + "/" + root.copyName : ""
    root.dbFormFor = ""
    root.copyFormFor = b.path
  }

  function setCopyName(text) {
    root.copyName = text
    if (!root.copyDirEdited && root.copyParent) root.copyDir = root.copyParent + "/" + text
  }

  function createCopy(path) {
    var name = root.copyName.trim()
    var dir = root.copyDir.trim()
    if (!/^[A-Za-z0-9][A-Za-z0-9-]*$/.test(name)) {
      root.copyError = "Nome non valido: solo lettere, cifre e trattini."
      return
    }
    if (root.isRegistered(name)) {
      root.copyError = "Esiste già un progetto DDEV chiamato " + name + "."
      return
    }
    if (dir.indexOf("~/") === 0) dir = Quickshell.env("HOME") + dir.slice(1)
    if (dir.indexOf("/") !== 0) {
      root.copyError = "La cartella deve essere un percorso assoluto."
      return
    }
    root.copyFormFor = ""
    // Niente --force: se la cartella esiste e non è vuota lo script rifiuta.
    root.run("restore", name, ["restore", path, "--to", dir, "--name", name])
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

  function openSettings() {
    root.draftBackupDir = String(root.setting("backupDir", "~/Backups/ddev"))
    root.draftKeep = Number(root.setting("keep", 10))
    root.draftKeepDb = Number(root.setting("keepDb", 20))
    var exclude = root.setting("exclude", "node_modules")
    root.draftExclude = Array.isArray(exclude) ? exclude.join(", ") : String(exclude)
    root.draftNotify = root.setting("notify", true) !== false
    root.settingsError = ""
    root.pendingConfirm = null
    root.dbFormFor = ""
    root.showSettings = true
  }

  function saveSettings() {
    var dir = root.draftBackupDir.trim()
    if (dir.indexOf("/") !== 0 && dir.indexOf("~/") !== 0) {
      root.settingsError = "La cartella dei backup deve essere un percorso assoluto (es. ~/Backups/ddev)."
      return
    }
    root.settingsError = ""
    // Valori passati come argomenti ($1…$5), mai interpolati nello script.
    var id = "mcp64.ddev-backup"
    settingsProc.command = ["/usr/bin/bash", "-c",
      "omarchy bar set " + id + " backupDir \"$1\" >/dev/null"
      + " && omarchy bar set " + id + " keep \"$2\" --json >/dev/null"
      + " && omarchy bar set " + id + " keepDb \"$3\" --json >/dev/null"
      + " && omarchy bar set " + id + " exclude \"$4\" >/dev/null"
      + " && omarchy bar set " + id + " notify \"$5\" --json >/dev/null",
      "_", dir, String(root.draftKeep), String(root.draftKeepDb),
      root.draftExclude.trim(), root.draftNotify ? "true" : "false"]
    settingsProc.running = false
    settingsProc.running = true
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
          : root.busyKind === "start" ? root.busyName + " avviato"
          : root.busyKind === "stop" ? root.busyName + " fermato"
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
    id: settingsProc
    stderr: SplitParser {
      onRead: data => { if (data.trim() !== "") root.settingsError = root.clip(data) }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.showSettings = false
        root.statusText = "Impostazioni salvate"
        root.reload()
      } else if (root.settingsError === "") {
        root.settingsError = "Salvataggio non riuscito (exit " + exitCode + ")"
      }
    }
  }

  Process {
    id: inspectProc
    stdout: SplitParser {
      onRead: data => {
        if (root.inspectBuffer.length < 1024 * 1024) root.inspectBuffer += data + "\n"
      }
    }
    stderr: SplitParser {
      onRead: data => {
        if (data.indexOf("ERROR: ") === 0) root.errorText = root.clip(data.slice(7))
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (root.errorText === "") root.errorText = "Impossibile leggere il backup " + root.inspectPath
        return
      }
      try {
        var m = JSON.parse(root.inspectBuffer)
        var name = (m.project && m.project.name) || ""
        var b = root.backupFromManifest(m, root.inspectPath)
        root.askRestore(name, b, root.isRegistered(name))
      } catch (e) {
        root.errorText = "Manifest non valido in " + root.inspectPath
      }
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
      // Esc chiude prima la cosa più interna: conferma, impostazioni, form DB.
      onCloseRequested: {
        if (root.pendingConfirm) root.pendingConfirm = null
        else if (root.showSettings) root.showSettings = false
        else if (root.dbFormFor !== "") root.dbFormFor = ""
        else if (root.copyFormFor !== "") root.copyFormFor = ""
        else root.close()
      }

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
                textFormat: Text.PlainText
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
                  iconText: "\uf013"
                  tooltipText: root.showSettings ? "Chiudi le impostazioni" : "Impostazioni"
                  foreground: root.foreground
                  onClicked: root.showSettings ? root.showSettings = false : root.openSettings()
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

          // Impostazioni (sostituiscono la lista dei progetti finché aperte).
          Rectangle {
            visible: root.showSettings
            width: parent.width
            implicitHeight: settingsColumn.implicitHeight + Style.space(20)
            height: implicitHeight
            radius: Style.cornerRadius
            color: Util.alpha(root.foreground, 0.03)
            border.color: Util.alpha(root.foreground, 0.12)
            border.width: 1

            Column {
              id: settingsColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                text: "Impostazioni"
                font.bold: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Cartella dei backup"
                  color: Util.alpha(root.foreground, 0.75)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  width: parent.width
                  text: root.draftBackupDir
                  placeholderText: "~/Backups/ddev"
                  onTextChanged: root.draftBackupDir = text
                }
              }

              NumberField {
                width: parent.width
                label: "Backup completi da tenere per progetto (0 = tutti)"
                from: 0
                to: 100
                value: root.draftKeep
                foreground: root.foreground
                fontFamily: root.fontFamily
                onModified: function(value) { root.draftKeep = value }
              }

              NumberField {
                width: parent.width
                label: "Backup del solo database da tenere (0 = tutti)"
                from: 0
                to: 200
                value: root.draftKeepDb
                foreground: root.foreground
                fontFamily: root.fontFamily
                onModified: function(value) { root.draftKeepDb = value }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Escludi dai backup (separati da virgola)"
                  color: Util.alpha(root.foreground, 0.75)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  width: parent.width
                  text: root.draftExclude
                  placeholderText: "node_modules, vendor"
                  onTextChanged: root.draftExclude = text
                }
              }

              Toggle {
                width: parent.width
                label: "Notifiche"
                description: "Avvisa a fine backup e restore"
                checked: root.draftNotify
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.draftNotify = !root.draftNotify
              }

              Text {
                textFormat: Text.PlainText
                visible: root.settingsError !== ""
                width: parent.width
                text: root.settingsError
                color: Color.urgent
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                spacing: Style.space(8)
                layoutDirection: Qt.RightToLeft
                width: parent.width

                Button {
                  text: settingsProc.running ? "Salvataggio…" : "Salva"
                  bordered: true
                  foreground: Color.accent
                  enabled: !settingsProc.running
                  onClicked: root.saveSettings()
                }

                Button {
                  text: "Annulla"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.showSettings = false
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
                textFormat: Text.PlainText
                text: root.pendingConfirm ? root.pendingConfirm.title : ""
                font.bold: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                width: parent.width
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                text: root.pendingConfirm ? root.pendingConfirm.message : ""
                width: parent.width
                wrapMode: Text.WordWrap
                color: Util.alpha(root.foreground, 0.8)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Anteprima del backup: dati dal manifest.
              Column {
                visible: !!(root.pendingConfirm && root.pendingConfirm.details)
                width: parent.width
                spacing: Style.space(2)

                Repeater {
                  model: root.pendingConfirm && root.pendingConfirm.details ? root.pendingConfirm.details : []

                  delegate: Row {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      textFormat: Text.PlainText
                      id: detailKey
                      width: Style.space(80)
                      text: modelData[0]
                      color: Util.alpha(root.foreground, 0.55)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      width: parent.width - detailKey.width - Style.space(8)
                      text: modelData[1]
                      textFormat: Text.PlainText
                      wrapMode: Text.WrapAnywhere
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              width: parent.width - (spinner.visible ? spinner.width + Style.space(6) : 0)
              text: root.statusText
              wrapMode: Text.WordWrap
              color: Util.alpha(root.foreground, 0.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: Color.urgent
            wrapMode: Text.WrapAnywhere
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.showSettings && root.loaded && root.projects.length === 0 && root.orphans.length === 0
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
            model: root.showSettings ? [] : root.projects
            delegate: projectCard
          }

          PanelSectionHeader {
            visible: !root.showSettings && root.orphans.length > 0
            width: parent.width
            text: "Progetti non più registrati — " + root.orphans.length
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.showSettings ? [] : root.orphans
            delegate: projectCard
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.showSettings && root.backupDir !== ""
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
              textFormat: Text.PlainText
              text: card.modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.bold: true
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
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

          // Nascosto ma presente anche senza backup, così i pulsanti restano in
          // colonna tra una scheda e l'altra.
          PanelActionButton {
            opacity: card.modelData.backups.length > 0 ? 1 : 0
            enabled: card.modelData.backups.length > 0
            iconText: card.isExpanded ? "\uf078" : "\uf054"
            tooltipText: card.isExpanded ? "Nascondi i backup" : "Mostra i backup"
            foreground: root.foreground
            onClicked: root.toggleExpanded(card.modelData.name)
          }

          PanelActionButton {
            visible: card.registered
            iconText: "\uf120"
            tooltipText: "Apri un terminale nella cartella del progetto"
            foreground: root.foreground
            enabled: (card.modelData.approot || "") !== ""
            onClicked: root.openTerminal(card.modelData)
          }

          PanelActionButton {
            visible: card.registered
            iconText: card.isBusy && (root.busyKind === "start" || root.busyKind === "stop") ? "…"
              : (card.isRunning ? "\uf04d" : "\uf04b")
            tooltipText: card.isRunning ? "Ferma il progetto (ddev stop)" : "Avvia il progetto (ddev start)"
            foreground: root.foreground
            hoverColor: card.isRunning ? Color.urgent : root.foreground
            enabled: !root.busy
            onClicked: root.startStop(card.modelData)
          }

          PanelActionButton {
            visible: card.registered
            iconText: "\uf1c0"
            tooltipText: "Backup del solo database (con nota facoltativa)"
            foreground: root.dbFormFor === card.modelData.name ? Color.accent : root.foreground
            enabled: !root.busy
            onClicked: root.openDbForm(card.modelData.name)
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

        // Form "backup del database": nota facoltativa + conferma.
        Row {
          visible: root.dbFormFor === card.modelData.name
          width: parent.width
          spacing: Style.space(8)

          TextField {
            width: parent.width - dbSaveButton.width - Style.space(8)
            text: root.dbLabel
            placeholderText: "Nota (es. prima della migrazione)"
            onTextChanged: root.dbLabel = text
            onAccepted: root.backupDatabase(card.modelData.name)
            onVisibleChanged: if (visible) forceActiveFocus()
          }

          Button {
            id: dbSaveButton
            text: "Backup DB"
            bordered: true
            foreground: Color.accent
            enabled: !root.busy
            onClicked: root.backupDatabase(card.modelData.name)
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
              readonly property bool copyOpen: root.copyFormFor === modelData.path
              width: parent.width
              implicitHeight: backupColumn.implicitHeight + Style.space(6)
              height: implicitHeight
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, rowHover.hovered || copyOpen ? 0.06 : 0)

              HoverHandler { id: rowHover }

              Column {
                id: backupColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(18)
                spacing: Style.space(6)

                RowLayout {
                  id: backupLayout
                  width: parent.width
                  spacing: Style.space(8)

                  Column {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: root.backupTitle(backupRow.modelData)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: (backupRow.modelData.label || "") !== ""
                      width: parent.width
                      text: backupRow.modelData.label || ""
                      textFormat: Text.PlainText
                      color: Util.alpha(root.foreground, 0.6)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.italic: true
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.formatSize(backupRow.modelData.size)
                    color: Util.alpha(root.foreground, 0.6)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  PanelActionButton {
                    visible: backupRow.modelData.kind !== "database"
                    iconText: "\uf0c5"
                    tooltipText: "Ripristina come copia (nuovo progetto)"
                    foreground: backupRow.copyOpen ? Color.accent : root.foreground
                    enabled: !root.busy
                    onClicked: root.openCopyForm(card.modelData.name, backupRow.modelData)
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

                // Form "ripristina come copia": nome e cartella del nuovo progetto.
                Column {
                  visible: backupRow.copyOpen
                  width: parent.width - Style.space(8)
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: "Nome del nuovo progetto"
                    color: Util.alpha(root.foreground, 0.75)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  TextField {
                    width: parent.width
                    text: backupRow.copyOpen ? root.copyName : ""
                    placeholderText: "mioprogetto-copia"
                    onTextChanged: if (backupRow.copyOpen && text !== root.copyName) root.setCopyName(text)
                    onAccepted: root.createCopy(backupRow.modelData.path)
                    onVisibleChanged: if (visible) forceActiveFocus()
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Cartella"
                    color: Util.alpha(root.foreground, 0.75)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  TextField {
                    width: parent.width
                    text: backupRow.copyOpen ? root.copyDir : ""
                    placeholderText: "~/Projects/mioprogetto-copia"
                    onTextChanged: {
                      if (!backupRow.copyOpen || text === root.copyDir) return
                      root.copyDir = text
                      root.copyDirEdited = true
                    }
                    onAccepted: root.createCopy(backupRow.modelData.path)
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.copyError !== ""
                    width: parent.width
                    text: root.copyError
                    color: Color.urgent
                    wrapMode: Text.WordWrap
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Row {
                    spacing: Style.space(8)
                    layoutDirection: Qt.RightToLeft
                    width: parent.width

                    Button {
                      text: "Crea copia"
                      bordered: true
                      foreground: Color.accent
                      enabled: !root.busy
                      onClicked: root.createCopy(backupRow.modelData.path)
                    }

                    Button {
                      text: "Annulla"
                      bordered: true
                      foreground: root.foreground
                      onClicked: root.copyFormFor = ""
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
