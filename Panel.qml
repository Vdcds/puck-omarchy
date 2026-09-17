import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Puck is deliberately compact: a keyboard-friendly, always-local little
// companion that lives behind one top-bar pill. The store script owns JSON
// writes so state stays safe even if the shell reloads while a click is in
// flight.
Panel {
  id: root
  moduleName: "vedant.puck"
  ipcTarget: "vedant.puck"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property var storeState: ({ todos: [], links: [], activity: {}, openCount: 0, doneCount: 0, totalCount: 0, doneToday: 0 })
  property bool addingLink: false
  property bool nudgeRunning: false
  property bool volumeCheckRunning: false
  property bool screensaverLaunching: false
  property bool screensaverResultReceived: false
  property var queuedStoreRequest: null
  property string pendingFeedback: ""
  property string toastMessage: ""

  readonly property string storeScript: Qt.resolvedUrl("puck-store.sh").toString().replace("file://", "")
  readonly property int openCount: Number(storeState.openCount || 0)
  readonly property int doneCount: Number(storeState.doneCount || 0)
  readonly property int totalCount: Number(storeState.totalCount || 0)
  readonly property int doneToday: Number(storeState.doneToday || 0)
  readonly property var activity: storeState.activity || ({})
  readonly property int waterToday: Number(activity.waterToday || 0)
  readonly property int waterCheckinsToday: checkedInToday("water") ? waterToday : 0
  readonly property bool screensaverActive: storeState.screensaverActive === true
  readonly property var codex: storeState.codex || ({ available: false })
  readonly property int codexPrimary: Number(codex.primary || 0)
  readonly property int codexSecondary: Number(codex.secondary || 0)
  readonly property bool codexWarm: codex.available === true && (codexPrimary >= 80 || codexSecondary >= 80)
  readonly property bool needsCare: totalCount > 0 && doneToday === 0
  readonly property real completion: totalCount > 0 ? doneCount / totalCount : 0
  readonly property string companionLine: totalCount === 0
    ? "A blank list can be a soft place to begin."
    : (openCount === 0 ? "Look at you — every little promise is complete. ✦" : openCount + " little promise" + (openCount === 1 ? "" : "s") + " waiting. One is enough.")

  function randomLine(lines) { return lines[Math.floor(Math.random() * lines.length)] }
  function checkedInToday(kind) {
    var timestamp = Number(activity[kind] || 0)
    if (timestamp <= 0) return false
    var then = new Date(timestamp * 1000)
    var today = new Date()
    return then.getFullYear() === today.getFullYear()
      && then.getMonth() === today.getMonth()
      && then.getDate() === today.getDate()
  }
  function showFeedback(kind) {
    var lines = {
      todo: ["Task adopted. I will stare at it with you.", "Added. Tiny bureaucracy defeated.", "A new quest has entered the chat."],
      complete: ["HECK YES. Confetti is happening internally.", "Done! Your future self has stopped glaring.", "Task bonked. Nicely done."],
      water: ["Glug glug. Your organs have submitted a positive review.", "Hydration acquired. You remain delightfully non-crispy.", "Bottle approved. Tiny aquatic victory."],
      walk: ["Screensaver deployed. Go be a mysterious outdoor creature.", "Walk mode: on. Your chair is processing the breakup.", "Legs activated. The pixels can survive without you."],
      saverOff: ["Screensaver dismissed. Welcome back, earthling."],
      headphones: ["Ears respected. The tiny hairs inside them are relieved.", "Volume break logged. Future-you says thank you, probably.", "Your eardrums have been granted diplomatic immunity."],
      nightlight: ["Night Light toggled. Your eyeballs may now exhale.", "Orange mode engaged. Very cozy, very responsible."]
    }
    toastMessage = randomLine(lines[kind] || ["Puck noted that."])
    toastTimer.restart()
  }

  function parseState(raw) {
    try {
      var next = JSON.parse(String(raw || "{}"))
      if (next && typeof next === "object" && next.todos !== undefined) storeState = next
      if (pendingFeedback !== "") {
        var feedback = pendingFeedback
        pendingFeedback = ""
        showFeedback(feedback)
      }
    } catch (error) {
      console.warn("Puck could not read its state:", error)
    }
    if (queuedStoreRequest) {
      var request = queuedStoreRequest
      queuedStoreRequest = null
      Qt.callLater(function() { root.startStore(request.args, request.feedback) })
    }
  }

  function startStore(args, feedback) {
    pendingFeedback = feedback || ""
    storeProc.command = ["bash", storeScript].concat(args)
    storeProc.running = true
  }
  function runStore(args, feedback) {
    if (storeProc.running) {
      // The panel refreshes as it opens. Keeping the newest action means an
      // eager bottle click is never lost to that refresh.
      queuedStoreRequest = { args: args, feedback: feedback || "" }
      return
    }
    startStore(args, feedback)
  }

  function refresh() { runStore(["status"]) }
  function addTodo() {
    var title = todoField.text.trim()
    if (title === "") return
    todoField.text = ""
    runStore(["add-todo", title], "todo")
  }
  function toggleTodo(todo) { if (todo) runStore(["toggle-todo", todo.id], todo.done ? "" : "complete") }
  function removeTodo(todo) { if (todo) runStore(["remove-todo", todo.id]) }
  function addLink() {
    var url = urlField.text.trim()
    if (url === "") return
    var label = linkLabelField.text.trim()
    linkLabelField.text = ""
    urlField.text = ""
    addingLink = false
    runStore(["add-link", label, url], "todo")
  }
  function removeLink(link) { if (link) runStore(["remove-link", link.id]) }
  function checkin(kind) {
    if (kind === "walk") {
      launchScreensaver()
      return
    }
    runStore(["checkin", kind], kind)
  }
  function launchScreensaver() {
    if (screensaverLaunching || saverProc.running) return
    screensaverLaunching = true
    screensaverResultReceived = false
    saverProc.command = ["bash", storeScript, "toggle-screensaver"]
    saverProc.running = true
  }
  function handleScreensaverResult(raw) {
    screensaverResultReceived = true
    screensaverLaunching = false
    try {
      var result = JSON.parse(String(raw || "{}"))
      if (result.ok === true) {
        if (result.active === true) {
          runStore(["checkin", "walk"], "")
          showFeedback("walk")
          notifyPuck("Puck started the screensaver", "Walk mode is on. Move the mouse or press a key when you are back.")
        } else {
          showFeedback("saverOff")
          notifyPuck("Puck dismissed the screensaver", "Welcome back.")
        }
        refresh()
      } else {
        var reason = result.error || "The screensaver could not start."
        toastMessage = reason
        toastTimer.restart()
        notifyPuck("Puck could not start the screensaver", reason)
      }
    } catch (error) {
      toastMessage = "The screensaver did not return a usable status."
      toastTimer.restart()
    }
  }
  function toggleNightlight() {
    if (bar) bar.run("omarchy toggle nightlight")
    showFeedback("nightlight")
  }

  function notifyPuck(title, body) {
    if (notificationProc.running) return
    notificationProc.command = ["notify-send", "-a", "Puck", "-t", "7000", title, body]
    notificationProc.running = true
  }

  function open() {
    controller.show()
    refresh()
  }
  function close() {
    addingLink = false
    controller.hide()
  }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  Process {
    id: storeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseState(text)
    }
  }

  Process {
    id: saverProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleScreensaverResult(text)
    }
    onExited: function(exitCode, exitStatus) {
      // StdioCollector flushes at process exit. Let it deliver its JSON before
      // treating a non-zero command as a no-result failure.
      Qt.callLater(function() {
        if (!root.screensaverResultReceived) {
          root.screensaverLaunching = false
          root.toastMessage = "The screensaver could not start (exit " + exitCode + ")."
          root.toastTimer.restart()
        }
      })
    }
  }

  Process {
    id: volumeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.volumeCheckRunning = false
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var message = JSON.parse(raw)
          if (message.title && message.body) root.notifyPuck(message.title, message.body)
        } catch (error) { console.warn("Puck volume check failed:", error) }
      }
    }
  }

  Process {
    id: nudgeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.nudgeRunning = false
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var message = JSON.parse(raw)
          if (!message.title || !message.body) return
          root.notifyPuck(message.title, message.body)
        } catch (error) { console.warn("Puck nudge failed:", error) }
      }
    }
  }

  Process { id: notificationProc }

  Timer {
    id: toastTimer
    interval: 5200
    onTriggered: root.toastMessage = ""
  }

  Timer {
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.nudgeRunning || nudgeProc.running) return
      root.nudgeRunning = true
      nudgeProc.command = ["bash", root.storeScript, "nudge",
        String(root.setting("waterMinutes", 60)),
        String(root.setting("walkMinutes", 120)),
        String(root.setting("headphoneMinutes", 90)),
        String(root.setting("nightlightHour", 20))]
      nudgeProc.running = true
      if (!volumeProc.running && !root.volumeCheckRunning) {
        root.volumeCheckRunning = true
        volumeProc.command = ["bash", root.storeScript, "volume-check"]
        volumeProc.running = true
      }
    }
  }

  Timer {
    interval: 90 * 1000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470), Style.space(510))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: todoField.activeFocus || linkLabelField.activeFocus || urlField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(key) {
        if (key === "a" || key === "A") todoField.forceActiveFocus()
        else if (key === "w" || key === "W") root.checkin("water")
        else if (key === "b" || key === "B") root.checkin("walk")
        else if (key === "e" || key === "E") root.checkin("headphones")
        else if (key === "n" || key === "N") root.toggleNightlight()
        else if (key === "r" || key === "R") root.refresh()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Puck"
            meta: root.totalCount === 0 ? "YOUR GENTLE CORNER" : root.doneCount + " OF " + root.totalCount + " COMPLETE"
            detail: root.openCount === 0 && root.totalCount > 0 ? "all clear" : root.openCount + " open"
            iconComponent: Component {
              CuteEyes { alert: root.needsCare || root.codexWarm }
            }
          }

          BorderSurface {
            visible: root.toastMessage !== ""
            width: parent.width
            implicitHeight: toastText.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.13)
            borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
            Text {
              id: toastText
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(9); anchors.rightMargin: Style.space(9)
              text: "Puck: " + root.toastMessage
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              text: root.companionLine
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(Color.foreground, 1.25)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Rectangle {
              width: parent.width
              height: Style.space(5)
              radius: height / 2
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
              Rectangle {
                width: parent.width * root.completion
                height: parent.height
                radius: height / 2
                color: Color.accent
                Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
              }
            }
          }

          BorderSurface {
            visible: root.codex.available === true
            width: parent.width
            implicitHeight: codexText.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: root.codexWarm
              ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.13)
              : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
            borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
            Text {
              id: codexText
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(9); anchors.rightMargin: Style.space(9)
              text: root.codexWarm
                ? "󰚩  Codex heads-up: " + root.codexPrimary + "% short window · " + root.codexSecondary + "% long window"
                : "󰚩  Codex: " + root.codexPrimary + "% short window · " + root.codexSecondary + "% long window"
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.codexWarm ? Color.accent : Qt.darker(Color.foreground, 1.35)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            Button {
              text: root.waterCheckinsToday > 0 ? "󰂰  bottle  ✓" : "󰂰  bottle"
              tooltipText: root.waterCheckinsToday > 0
                ? root.waterCheckinsToday + " bottle check-in" + (root.waterCheckinsToday === 1 ? "" : "s") + " today"
                : "Log a bottle of water"
              onClicked: root.checkin("water")
            }
            Button {
              text: root.screensaverLaunching ? "󰆰  starting…" : (root.screensaverActive ? "󰆰  stop saver" : "󰆰  walk")
              tooltipText: root.screensaverActive ? "Dismiss the fullscreen screensaver" : "Log a walk and start the fullscreen screensaver"
              enabled: !root.screensaverLaunching
              onClicked: root.checkin("walk")
            }
            Button { text: "󰕾  ears"; tooltipText: "I gave my ears a volume break"; onClicked: root.checkin("headphones") }
            Item { width: Math.max(0, parent.width - parent.children[0].width - parent.children[1].width - parent.children[2].width - parent.children[4].width - Style.space(24)); height: 1 }
            Button { text: "󰖔"; tooltipText: "Toggle Night Light"; onClicked: root.toggleNightlight() }
          }

          PanelSeparator { foreground: Color.foreground }

          PanelSectionHeader { text: "TODAY'S LITTLE PROMISES"; foreground: Color.foreground }

          Row {
            width: parent.width
            spacing: Style.space(8)
            TextField {
              id: todoField
              width: parent.width - addTodoButton.width - Style.space(8)
              placeholderText: "Add one small thing…  (A)"
              onAccepted: root.addTodo()
            }
            Button {
              id: addTodoButton
              text: "+"
              bordered: true
              tooltipText: "Add todo"
              onClicked: root.addTodo()
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(5)
            Repeater {
              model: root.storeState.todos || []
              delegate: BorderSurface {
                id: todoDelegate
                required property var modelData
                width: parent.width
                implicitHeight: todoRow.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: modelData.done ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.11) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.045)
                borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
                Row {
                  id: todoRow
                  anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(5)
                  spacing: Style.space(8)
                  Button {
                    text: todoDelegate.modelData.done ? "󰄬" : "󰄱"
                    iconText: ""
                    horizontalPadding: Style.space(2)
                    verticalPadding: Style.space(2)
                    tooltipText: todoDelegate.modelData.done ? "Mark unfinished" : "Mark complete"
                    onClicked: root.toggleTodo(todoDelegate.modelData)
                  }
                  Text {
                    width: Math.max(0, parent.width - parent.children[0].width - parent.children[2].width - Style.space(16))
                    anchors.verticalCenter: parent.verticalCenter
                    text: todoDelegate.modelData.title
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: todoDelegate.modelData.done ? Qt.darker(Color.foreground, 1.55) : Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.strikeout: todoDelegate.modelData.done
                  }
                  Button {
                    text: "×"
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(2)
                    tooltipText: "Remove todo"
                    onClicked: root.removeTodo(todoDelegate.modelData)
                  }
                }
              }
            }
            Text {
              visible: root.totalCount === 0
              text: "No pressure. Add a task when it wants to exist."
              color: Qt.darker(Color.foreground, 1.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
          }

          PanelSeparator { foreground: Color.foreground }

          Row {
            width: parent.width
            PanelSectionHeader { text: "POCKET LINKS"; foreground: Color.foreground; width: parent.width - linkToggle.width - Style.space(8) }
            Button {
              id: linkToggle
              text: root.addingLink ? "close" : "+ link"
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(3)
              onClicked: root.addingLink = !root.addingLink
            }
          }

          Column {
            visible: root.addingLink
            width: parent.width
            spacing: Style.space(6)
            TextField { id: linkLabelField; width: parent.width; placeholderText: "Label (optional)"; onAccepted: urlField.forceActiveFocus() }
            Row {
              width: parent.width
              spacing: Style.space(8)
              TextField { id: urlField; width: parent.width - saveLinkButton.width - Style.space(8); placeholderText: "https://a-link-you-want-to-keep"; onAccepted: root.addLink() }
              Button { id: saveLinkButton; text: "save"; bordered: true; onClicked: root.addLink() }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.storeState.links || []
              delegate: Row {
                id: linkRow
                required property var modelData
                width: parent.width
                spacing: Style.space(6)
                Button {
                  text: "󰌷  " + linkRow.modelData.label
                  width: Math.max(80, parent.width - linkDelete.width - Style.space(6))
                  leftAlign: true
                  tooltipText: linkRow.modelData.url
                  onClicked: Qt.openUrlExternally(linkRow.modelData.url)
                }
                Button { id: linkDelete; text: "×"; tooltipText: "Remove link"; onClicked: root.removeLink(linkRow.modelData) }
              }
            }
            Text {
              visible: (root.storeState.links || []).length === 0
              text: "Keep a reading list, a map, or one good rabbit hole here."
              color: Qt.darker(Color.foreground, 1.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
          }

          Text {
            width: parent.width
            text: "Keys: A add · W bottle · B walk + saver · E ears · N night light · R refresh · Esc close"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(Color.foreground, 1.65)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
