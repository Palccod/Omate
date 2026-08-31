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
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(16))

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
    }
  }
}
