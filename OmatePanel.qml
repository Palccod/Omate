pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Omate's settings card, styled after the plugin-manager row it opens from:
// an animated sprite thumbnail, the name with a status line under it, and a
// power button in the top-right that enables or disables the mate. Below sit
// the skin picker (every pack previews its own idle animation) and the
// behavior controls.
Panel {
  id: root
  moduleName: "palccod.omate"

  // One panel instance exists per bar; only the largest screen's instance
  // claims the IPC target, so `omarchy-shell palccod.omate toggle` acts on a
  // predictable panel.
  readonly property var panelScreen: anchorItem && anchorItem.QsWindow.window
    ? anchorItem.QsWindow.window.screen : null
  readonly property var mainScreen: {
    var best = null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }
  ipcTarget: panelScreen && panelScreen === mainScreen ? moduleName : ""

  property var anchorItem: null
  property var hostWidget: null
  property var petService: null
  readonly property var barIdentity: hostWidget || root

  readonly property bool ready: !!petService && petService.initialized === true
  readonly property bool enabledMate: ready && petService.settings.visible === true
  readonly property color foreground: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string statusLabel: !ready ? "Waking up…"
    : !enabledMate ? "Disabled"
    : petService.sleeping ? "Sleeping" : "Enabled"
  readonly property color statusColor: !ready || !enabledMate
    ? Qt.alpha(foreground, 0.55) : Color.accent

  // Two-page card: the main page or the reminders page (see contentColumn).
  // Closing always lands back on the main card, so reopening starts at the
  // top instead of wherever the last visit ended.
  property bool remindersPageOpen: false
  onOpenedChanged: if (!opened) remindersPageOpen = false

  // Live add-form numbers. NumberField's own `value` keeps its initial
  // binding when the user edits the inner SpinBox — only `modified` carries
  // the typed value out — so the Add handlers read these instead of a value
  // that would still be the day's default.
  property int newTimerMinutes: 25
  property int newAlarmHour: 9
  property int newAlarmMinute: 30
  property bool newAlarmPm: new Date().getHours() >= 12

  // Alarm times are 12-hour by design: the hour field always runs 1–12 with
  // an AM/PM toggle beside it, and every clock label carries an AM/PM
  // suffix regardless of the system locale.
  readonly property string clockFormat: "h:mm AP"

  // "in 12m" / "in 1h 20m" — the same shape the window menu uses for
  // countdowns, so a 7-day timer does not read "in 10080m".
  function fmtIn(ms) {
    var mins = Math.max(0, Math.round((ms - Date.now()) / 60000))
    if (mins < 1) return "now"
    if (mins < 60) return "in " + mins + "m"
    var h = Math.floor(mins / 60)
    var m = mins % 60
    return m === 0 ? "in " + h + "h" : "in " + h + "h " + m + "m"
  }

  // "in 12m" / "14:30 daily" / "rang 14:30" for a reminder row. `tick` is
  // the binding's dependency on the wall clock: the countdown labels would
  // otherwise sit frozen until the list itself changes.
  function reminderDueLabel(r, tick) {
    if (!r.enabled) return "paused"
    var now = Date.now()
    if (r.dueMs <= now)
      return "rang " + Qt.formatTime(new Date(r.lastFiredMs || r.dueMs), root.clockFormat)
    if (r.daily) return Qt.formatTime(new Date(r.dueMs), root.clockFormat) + " daily"
    return fmtIn(r.dueMs)
  }

  // Advances `clockTick` every 30s while the reminders page is on screen
  // and there is something to count down.
  property int clockTick: 0
  Timer {
    interval: 30000
    running: root.opened && root.ready && root.remindersPageOpen
      && root.petService.reminders.length > 0
    repeat: true
    onTriggered: root.clockTick++
  }

  readonly property string reminderCountLabel: {
    if (!ready) return ""
    var n = 0
    var list = petService.reminders || []
    for (var i = 0; i < list.length; i++)
      if (list[i].enabled) n++
    return n === 1 ? "1 armed" : n + " armed"
  }

  // Screen picker options: auto plus every connected output.
  readonly property var screenOptions: {
    var opts = [{ value: "", label: "Auto (largest)" }]
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      opts.push({ value: screens[i].name, label: screens[i].name })
    return opts
  }

  // Chase cadences. The value is the cooldown in seconds; "off" switches the
  // whole feature off. Short chip labels so all five fit one row inside the
  // card; the long-form name of the current setting sits beside the row label
  // and the full sentence is on each chip's tooltip.
  readonly property var chaseOptions: [
    { value: "off",  label: "Off",
      tooltip: "The pointer is left alone" },
    { value: "10",   label: "10s",
      tooltip: "Playful - a go at the pointer every 10 seconds" },
    { value: "60",   label: "1 min",
      tooltip: "Now and then - once a minute" },
    { value: "300",  label: "5 min",
      tooltip: "Occasional - once every five minutes" },
    { value: "1800", label: "30 min",
      tooltip: "Rare - twice an hour" }
  ]
  readonly property string chaseValue: ready && petService.cursorChase
    ? String(petService.chaseCooldownSec) : "off"
  // Named for the cadences the chips offer, but a cooldown set from the IPC
  // (`setChaseCooldown 600`) is a legitimate value with no chip of its own, so
  // it gets spelled out rather than silently leaving the row looking unset.
  readonly property string chaseDescription: {
    if (!ready || !petService.cursorChase) return "Off"
    switch (petService.chaseCooldownSec) {
      case 10: return "Playful"
      case 60: return "Now and then"
      case 300: return "Occasional"
      case 1800: return "Rare"
    }
    return "Every " + petService.chaseCooldownSec + "s"
  }

  // The mate's right-click menu opens the panel on the main screen's bar.
  Connections {
    target: root.petService
    function onPanelRequested() {
      if (root.panelScreen === root.mainScreen) root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    padding: Style.space(14)
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Seeds the initial card height from the open page; see cardHeightSync
    // below for why this binding alone cannot be trusted to keep it true.
    contentHeight: panel.fittedContentHeight(
      headerCard.height + Style.space(12)
      + (root.remindersPageOpen ? remindersPage.implicitHeight : mainPage.implicitHeight)
      + Style.space(16))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // --- header ------------------------------------------------------

        Rectangle {
          id: headerCard
          width: parent.width
          height: Style.space(68)
          radius: Style.cornerRadius > 0 ? Style.space(10) : 0
          color: Qt.alpha(Color.accent, root.enabledMate ? 0.10 : 0.04)
          border.width: 1
          border.color: Qt.alpha(Color.accent, root.enabledMate ? 0.30 : 0.12)

          Behavior on color { ColorAnimation { duration: 200 } }
          Behavior on border.color { ColorAnimation { duration: 200 } }

          // The live sprite, exactly what the bar button shows.
          Rectangle {
            id: thumb
            anchors.left: parent.left
            anchors.leftMargin: Style.space(11)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(46)
            height: Style.space(46)
            radius: Style.space(9)
            color: Qt.alpha(root.foreground, 0.06)
            clip: true

            PetSprite {
              anchors.fill: parent
              anchors.margins: Style.space(3)
              skin: root.ready ? root.petService.skin : null
              anim: root.ready && root.petService.sleeping ? "sleep" : "idle"
              fallbackAnim: "idle"
              frameMs: 600
            }
          }

          Column {
            anchors.left: thumb.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Omate"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              renderType: Text.NativeRendering
            }
            Text {
              text: root.statusLabel
              // statusLabel echoes the pack name, which setPack lets a
              // caller choose; render it literally.
              textFormat: Text.PlainText
              color: root.statusColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }

          // Power: enable or disable the mate altogether (same as the
          // show/hide IPC; the mate keeps its position either way).
          PanelActionButton {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            iconText: String.fromCodePoint(0xF0425)
            tooltipText: root.enabledMate ? "Disable the mate" : "Enable the mate"
            fontFamily: root.fontFamily
            foreground: root.enabledMate ? Color.accent : Qt.alpha(root.foreground, 0.55)
            bordered: true
            enabled: root.ready
            opacity: enabled ? 1 : 0.4
            onClicked: if (root.ready) root.petService.toggleMateVisible()
          }
        }

        // Two pages under the header: the main card and the reminders page.
        // A page hidden through a visibility binding still occupies space in
        // the positioner's implicit height (measured: contentColumn came out
        // at 851 with the 771-tall main page counted while hidden), so each
        // page also yields its height when it is not the one on screen. The
        // card height bound to contentColumn therefore follows the open page.
        Column {
          id: mainPage
          width: parent.width
          spacing: Style.space(12)
          visible: !root.remindersPageOpen
          height: visible ? implicitHeight : 0


          // Reminders live on their own page; this row just opens it. The
          // count on the right tells whether anything is armed without
          // leaving the main card.
          Item {
            width: parent.width
            height: Style.space(30)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Reminders"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(40)
              anchors.verticalCenter: parent.verticalCenter
              text: root.reminderCountLabel
              visible: root.ready && root.petService.reminders.length > 0
              color: Qt.alpha(root.foreground, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: String.fromCodePoint(0xF0142)
              tooltipText: "Open reminders"
              fontFamily: root.fontFamily
              foreground: root.foreground
              bordered: true
              enabled: root.ready
              opacity: enabled ? 1 : 0.4
              onClicked: root.remindersPageOpen = true
            }
          }

          // --- skins ---------------------------------------------------------

          PanelSectionHeader {
            text: "Skins"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // The picker shows three rows and scrolls past that, so the panel
          // stays a popup instead of growing with the pack roster. The height
          // is a constant on purpose: deriving it from contentHeight lets the
          // transient 0 at popup construction breathe the whole card.
          Item {
            id: skinViewport
            width: parent.width
            height: Style.space(300)

            Flickable {
              id: skinGrid
              anchors.fill: parent
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              contentHeight: skinFlow.implicitHeight
              contentWidth: width

              Flow {
                id: skinFlow
                width: skinGrid.width
                spacing: Style.space(8)

                Repeater {
                  model: root.petService ? root.petService.packList : []
                  Rectangle {
                    id: card
                    required property var modelData

                    readonly property bool selected: root.ready
                      && root.petService.packName === modelData.name

                    width: Math.floor((parent.width - Style.space(16)) / 3)
                    height: cardColumn.implicitHeight + Style.space(18)
                    radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                    color: selected ? Qt.alpha(Color.accent, 0.14)
                                    : Qt.alpha(root.foreground, 0.05)
                    border.width: 1
                    border.color: selected ? Color.accent
                                           : Qt.alpha(root.foreground, 0.14)

                    Behavior on color { ColorAnimation { duration: 150 } }
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.ready) root.petService.selectPack(card.modelData.name)
                    }

                    Column {
                      id: cardColumn
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(9)
                      anchors.horizontalCenter: parent.horizontalCenter
                      spacing: Style.space(6)

                      // Each pack previews its own idle animation, so the picker
                      // reads like a character select screen.
                      Item {
                        width: card.width - Style.space(16)
                        height: Style.space(44)

                        PetSprite {
                          anchors.fill: parent
                          // One object per card: dir + anims swap atomically.
                          skin: {
                            var packData = card.modelData.pack
                            return {
                              dir: card.modelData.dir,
                              anims: packData ? packData.anims : null
                            }
                          }
                          anim: "idle"
                          fallbackAnim: "idle"
                          frameMs: 500
                        }
                      }

                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: card.width - Style.space(10)
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: card.modelData.title
                        // Pack titles come from third-party pack.json files;
                        // render literally, never as rich text.
                        textFormat: Text.PlainText
                        color: card.selected ? Color.accent
                                             : Qt.alpha(root.foreground, 0.75)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        renderType: Text.NativeRendering
                      }
                    }
                  }
                }
              }
            }

            // Slim scroll indicator while the grid overflows. The thumb math
            // is guarded against the transient 0 contentHeight at popup
            // construction (division would read as Infinity) and clamped so
            // overscroll can never push it outside the viewport.
            Rectangle {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(2)
              width: 3
              radius: 1.5
              visible: skinGrid.contentHeight > skinGrid.height + 1
              color: Qt.alpha(root.foreground, 0.25)
              height: visible && skinGrid.contentHeight > 0
                ? Math.max(Style.space(30),
                           skinGrid.height * skinGrid.height / skinGrid.contentHeight)
                : 0
              y: Math.max(0, Math.min(skinGrid.height - height,
                                      skinGrid.visibleArea.yPosition * skinGrid.height))
            }
          }

          // Pointer to importing more characters (see the README).
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "bring your own — import shimeji & GIF pets, see the README"
            color: Qt.alpha(root.foreground, 0.45)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
          }

          // --- behavior --------------------------------------------------------

          PanelSectionHeader {
            text: "Behavior"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Roaming on/off.
          Item {
            width: parent.width
            height: Style.space(30)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Roaming"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            ToggleSwitch {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.enabledMate && root.petService.roaming
              enabled: root.ready
              foreground: root.foreground
              onToggled: if (root.ready) root.petService.setRoaming(!checked)
            }
          }

          // Sound effects volume.
          Item {
            width: parent.width
            height: Style.space(30)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Effects volume"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelSlider {
                id: volumeSlider
                bar: root.bar
                width: Style.space(150)
                anchors.verticalCenter: parent.verticalCenter
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.ready ? root.petService.soundVolume : 0.5
                enabled: root.ready
                // Persist on release, and let it be heard right away.
                onReleased: function(v) {
                  if (!root.ready) return
                  root.petService.updateSettings({ soundVolume: v })
                  Qt.callLater(function() { root.petService.playSound("pet") })
                }
                onRightClicked: if (root.ready) root.petService.setSoundVolume(
                  root.petService.soundVolume > 0 ? 0 : 0.5)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(36)
                horizontalAlignment: Text.AlignRight
                text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue
                  : volumeSlider.value) * 100) + "%"
                color: Qt.alpha(root.foreground, 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                renderType: Text.NativeRendering
              }
            }
          }

          // Sprite magnification.
          Item {
            width: parent.width
            height: Style.space(30)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Size"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelSlider {
                id: sizeSlider
                bar: root.bar
                width: Style.space(150)
                anchors.verticalCenter: parent.verticalCenter
                minimum: 1
                maximum: 6
                step: 1
                value: root.ready ? root.petService.petScale : 3
                enabled: root.ready
                onReleased: function(v) {
                  if (root.ready) root.petService.updateSettings({ scale: Math.round(v) })
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(36)
                horizontalAlignment: Text.AlignRight
                text: "×" + (sizeSlider.dragging ? Math.round(sizeSlider.liveValue)
                  : sizeSlider.value)
                color: Qt.alpha(root.foreground, 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                renderType: Text.NativeRendering
              }
            }
          }

          // How adventurous the wandering is.
          Item {
            width: parent.width
            height: Style.space(30)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Walkiness"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelSlider {
                id: walkSlider
                bar: root.bar
                width: Style.space(150)
                anchors.verticalCenter: parent.verticalCenter
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.ready ? root.petService.walkiness : 0.6
                enabled: root.ready
                onReleased: function(v) {
                  if (root.ready) root.petService.updateSettings({ walkiness: v })
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(36)
                horizontalAlignment: Text.AlignRight
                text: Math.round((walkSlider.dragging ? walkSlider.liveValue
                  : walkSlider.value) * 100) + "%"
                color: Qt.alpha(root.foreground, 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                renderType: Text.NativeRendering
              }
            }
          }

          // Home screen.
          Item {
            width: parent.width
            height: screenDropdown.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Screen"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            Dropdown {
              id: screenDropdown
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(194)
              showLabel: false
              value: root.ready && typeof root.petService.settings.screen === "string"
                ? root.petService.settings.screen : ""
              options: root.screenOptions
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.ready
              onChanged: function(v) {
                if (root.ready) root.petService.applyScreenChoice(v)
              }
            }
          }

          // What the mate calls you in some time-of-day lines. The field
          // enforces letters-and-digits, 20 characters at most; Service
          // re-sanitizes on read, so a hand-edited settings file cannot
          // smuggle anything longer or stranger through.
          Item {
            width: parent.width
            height: Math.max(nameLabel.implicitHeight, nameField.implicitHeight)

            Text {
              id: nameLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Your name"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            TextField {
              id: nameField
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(150)
              verticalPadding: 2
              enabled: root.ready
              placeholderText: "optional"
              maximumLength: 20
              validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9]*/ }
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              foreground: root.foreground
              text: root.ready ? String(root.petService.settings.userName || "") : ""
              onEditingFinished: {
                if (root.ready) root.petService.updateSettings({ userName: text.trim() })
              }
            }
          }

          // Nap and chatter cadence.
          Item {
            width: parent.width
            height: Math.max(napField.implicitHeight, chatField.implicitHeight)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Naps / chatter"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              NumberField {
                id: napField
                anchors.verticalCenter: parent.verticalCenter
                value: root.ready ? Math.round(root.petService.settings.sleepMinutes) : 10
                from: 0
                to: 120
                stepSize: 1
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                enabled: root.ready
                onModified: function(v) {
                  if (root.ready) root.petService.updateSettings({ sleepMinutes: v })
                }
              }
              NumberField {
                id: chatField
                anchors.verticalCenter: parent.verticalCenter
                value: root.ready ? Math.round(root.petService.settings.chatterMinutes) : 4
                from: 1
                to: 60
                stepSize: 1
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                enabled: root.ready
                onModified: function(v) {
                  if (root.ready) root.petService.updateSettings({ chatterMinutes: v })
                }
              }
            }
          }

          // Cursor chasing. One control for both the on/off and the cadence:
          // the interesting choice is not "should it happen" but "how often",
          // and "every ten seconds" vs "twice an hour" is the difference
          // between a toy people keep and one they switch off on day two.
          //
          // Chips rather than a dropdown. This is the last row in the panel and
          // Dropdown's popup always opens downward from its trigger with no
          // flip-up fallback, so on a 1080p screen the card is tall enough that
          // the list ran off the bottom of the display: "Rare - 30 min" was
          // drawn past the screen edge and could not be picked at all. Chips are
          // laid out inside the card, so every cadence is reachable at any
          // resolution, and switching the chase on becomes a deliberate click on
          // a named cadence rather than a pick from a list that unfurls under
          // the pointer.
          Item {
            width: parent.width
            height: chaseLabel.implicitHeight

            Text {
              id: chaseLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Chase cursor"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.chaseDescription
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }

          ButtonGroup {
            width: parent.width
            options: root.chaseOptions
            value: root.chaseValue
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) {
              if (!root.ready) return
              if (v === "off") { root.petService.setCursorChase(false); return }
              root.petService.setChaseCooldown(Number(v))
              root.petService.setCursorChase(true)
            }
          }

        }


        // --- reminders page --------------------------------------------------

        Column {
          id: remindersPage
          width: parent.width
          spacing: Style.space(12)
          visible: root.remindersPageOpen
          height: visible ? implicitHeight : 0

          // Page title with the way back.
          Item {
            width: parent.width
            height: Style.space(30)

            PanelActionButton {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: String.fromCodePoint(0xF0141)
              tooltipText: "Back"
              fontFamily: root.fontFamily
              foreground: root.foreground
              bordered: true
              onClicked: root.remindersPageOpen = false
            }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(44)
              anchors.verticalCenter: parent.verticalCenter
              text: "Reminders"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              renderType: Text.NativeRendering
            }
          }

          // New one-shot timer: name + minutes. The name field flexes;
          // the minutes slot and the Add button are fixed widths shared
          // with the alarm row below, so the two rows line up column for
          // column.
          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: timerName
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(96) - Style.space(72) - Style.space(16)
              placeholderText: "New timer name"
              maximumLength: 30
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              foreground: root.foreground
              enabled: root.ready
            }
            NumberField {
              id: timerMinutes
              anchors.verticalCenter: parent.verticalCenter
              fieldWidth: Style.space(96)
              value: 25
              from: 1
              to: 10080
              stepSize: 5
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              enabled: root.ready
              onModified: function(v) { root.newTimerMinutes = v }
            }
            Button {
              id: timerAdd
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(72)
              text: "Add"
              fontSize: Style.font.bodySmall
              fontFamily: root.fontFamily
              foreground: Color.accent
              bordered: true
              enabled: root.ready && timerName.text.trim() !== ""
              onClicked: {
                if (!root.ready) return
                root.petService.addReminderTimer(timerName.text, root.newTimerMinutes)
                timerName.text = ""
              }
            }
          }

          // New daily alarm: same geometry. Hour + minute split the same
          // 96px slot the minutes field occupies above, so both name fields
          // and both Add buttons sit on the same columns. At 44 units the
          // stock up/down indicators would crowd out the digits, so they are
          // hidden — the fields stay editable and still step via arrow keys
          // and the mouse wheel. Hours are 12-hour with an AM/PM toggle;
          // the toggle's width comes out of the name field.
          Row {
            width: parent.width
            spacing: Style.space(8)

            Component.onCompleted: {
              if (alarmHour.field.up.indicator) alarmHour.field.up.indicator.visible = false
              if (alarmHour.field.down.indicator) alarmHour.field.down.indicator.visible = false
              if (alarmMinute.field.up.indicator) alarmMinute.field.up.indicator.visible = false
              if (alarmMinute.field.down.indicator) alarmMinute.field.down.indicator.visible = false
            }

            TextField {
              id: alarmName
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - alarmFields.width - alarmAdd.width - Style.space(16)
              placeholderText: "New daily alarm name"
              maximumLength: 30
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              foreground: root.foreground
              enabled: root.ready
            }
            Row {
              id: alarmFields
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              NumberField {
                id: alarmHour
                anchors.verticalCenter: parent.verticalCenter
                fieldWidth: Style.space(44)
                value: 9
                from: 1
                to: 12
                stepSize: 1
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                enabled: root.ready
                onModified: function(v) { root.newAlarmHour = v }
              }
              NumberField {
                id: alarmMinute
                anchors.verticalCenter: parent.verticalCenter
                fieldWidth: Style.space(44)
                value: 30
                from: 0
                to: 59
                stepSize: 5
                fontSize: Style.font.bodySmall
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                enabled: root.ready
                onModified: function(v) { root.newAlarmMinute = v }
              }
              Button {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                text: root.newAlarmPm ? "PM" : "AM"
                fontSize: Style.font.caption
                fontFamily: root.fontFamily
                foreground: root.foreground
                bordered: true
                onClicked: root.newAlarmPm = !root.newAlarmPm
              }
            }
            Button {
              id: alarmAdd
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(72)
              text: "Add"
              fontSize: Style.font.bodySmall
              fontFamily: root.fontFamily
              foreground: Color.accent
              bordered: true
              enabled: root.ready && alarmName.text.trim() !== ""
              onClicked: {
                if (!root.ready) return
                var h = root.newAlarmHour
                if (h === 12) h = root.newAlarmPm ? 12 : 0
                else if (root.newAlarmPm) h += 12
                root.petService.addDailyAlarm(alarmName.text, h, root.newAlarmMinute)
                alarmName.text = ""
              }
            }
          }

          // The list. Scrollable past four rows so a full roster cannot
          // push the card past the screen; empty state tells the user the
          // other ways in. With no reminders the hint's own wrapped height
          // sizes the slot — a fixed slot let the long line overflow and
          // overlap whatever sat under it.
          Item {
            width: parent.width
            height: root.petService && root.petService.reminders.length > 0
              ? Style.space(170) : emptyHint.implicitHeight + Style.space(12)

            Flickable {
              id: reminderScroll
              anchors.fill: parent
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              contentHeight: reminderList.implicitHeight
              contentWidth: width

              Column {
                id: reminderList
                width: reminderScroll.width
                spacing: Style.space(4)

                Repeater {
                  model: root.ready ? root.petService.reminders : []

                  Item {
                    required property var modelData
                    width: parent.width
                    height: Style.space(30)

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.right: reminderDue.left
                      anchors.rightMargin: Style.space(8)
                      elide: Text.ElideRight
                      text: modelData.name + (modelData.daily ? "  (daily)" : "")
                      color: modelData.enabled ? root.foreground : Qt.alpha(root.foreground, 0.45)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      renderType: Text.NativeRendering
                    }
                    Text {
                      id: reminderDue
                      anchors.right: reminderSnooze.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.reminderDueLabel(modelData, root.clockTick)
                      color: Qt.alpha(root.foreground, 0.55)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      renderType: Text.NativeRendering
                    }
                    PanelActionButton {
                      id: reminderSnooze
                      anchors.right: reminderDelete.left
                      anchors.rightMargin: Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: String.fromCodePoint(0xF009E)
                      tooltipText: "Snooze 10 min"
                      fontFamily: root.fontFamily
                      foreground: root.foreground
                      enabled: root.ready
                      opacity: enabled ? 1 : 0.4
                      onClicked: root.petService.snoozeReminder(modelData.id, 10)
                    }
                    PanelActionButton {
                      id: reminderDelete
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: String.fromCodePoint(0xF01B4)
                      tooltipText: "Delete"
                      fontFamily: root.fontFamily
                      foreground: Qt.alpha(root.foreground, 0.55)
                      enabled: root.ready
                      opacity: enabled ? 1 : 0.4
                      onClicked: root.petService.removeReminder(modelData.id)
                    }
                  }
                }
              }
            }

            Text {
              id: emptyHint
              anchors.fill: parent
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              wrapMode: Text.WordWrap
              visible: !root.ready || root.petService.reminders.length === 0
              text: "No reminders yet. Add one above, or right-click the mate \u2192 Reminders."
              color: Qt.alpha(root.foreground, 0.45)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
            }
          }
        }
      }
    }
  }

  // Caps the card at the usable screen height minus a generous allowance
  // for the bar strip. panel.availableCardHeight cannot be used for this:
  // it subtracts the anchor window's height, and the bar's layer surface
  // expands to full-screen after startup (1920x1080), which collapsed the
  // cap to 120 and left the list spilling onto the desktop with no card
  // behind it.
  function usableCardCap() {
    var cap = panel.screenH - 120
    return cap > 0 ? cap : 0
  }

  function fittedCardHeight(pageHeight) {
    var desired = headerCard.height + Style.space(12) + pageHeight
      + Style.space(16) + panel.verticalContentInset
    var cap = usableCardCap()
    return Math.round(cap > 0 ? Math.min(desired, cap) : desired)
  }

  // Keeps the card height honest. A declarative chain here — through
  // contentColumn.implicitHeight or the pages directly — froze at its
  // first evaluation in practice, leaving the card sized for whatever was
  // on screen when the panel was built (dead space under the reminders
  // list). The binding above seeds the initial value; this timer owns it
  // from the first open onwards. Runs only while the panel is open and
  // the write is a no-op when nothing changed.
  Timer {
    id: cardHeightSync
    interval: 250
    running: root.opened
    repeat: true
    onTriggered: {
      var want = root.fittedCardHeight(
        root.remindersPageOpen ? remindersPage.implicitHeight : mainPage.implicitHeight)
      if (panel.contentHeight !== want) panel.contentHeight = want
    }
  }
}
