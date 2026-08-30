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

        Flow {
          width: parent.width
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
      }
    }
  }
}
