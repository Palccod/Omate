import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "bridge" as OmateBridge

// Bar button: the mate's face, animated with the current skin. Left click
// opens its settings panel (skins, behavior, the enable/disable power
// switch); middle click is a quick pet on the head.
BarWidget {
  id: root
  moduleName: "palccod.omate"

  // Primary path: the bar host's scoped facade. The first-party bar scopes
  // it to this plugin, so serviceFor() reaches our own live service.
  // Fallback: the engine-wide bridge singleton. Replacement bars (e.g.
  // ruixen.bar) are handed a facade whose serviceFor() is a deliberate null
  // stub -- Omarchy never exposes service resolution to them -- so widgets
  // they host would otherwise never get past "Waking up…". Re-evaluates on
  // its own when the service publishes itself (or is torn down).
  readonly property var petService: {
    var viaHost = bar && bar.shell && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor(moduleName)
      : null
    return viaHost || OmateBridge.Bridge.service
  }
  readonly property bool serviceReady: !!petService && petService.initialized === true

  // Panel lifecycle forwarding, required by the bar's popout switching.
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false
  readonly property real openPanelIndicatorWidth: content.implicitWidth
  readonly property real openPanelIndicatorHeight: content.implicitHeight

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("petService" in target) target.petService = root.petService
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: Qt.callLater(injectPanel)
  onSettingsChanged: Qt.callLater(injectPanel)
  onPetServiceChanged: Qt.callLater(injectPanel)
  Component.onCompleted: Qt.callLater(injectPanel)

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("OmatePanel.qml")
    visible: false
    onLoaded: root.injectPanel()
  }

  IpcHandler {
    target: "palccod.omate"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.serviceReady
    tooltipText: root.serviceReady
      ? (root.petService.settings.visible === true
         ? "Omate — left: settings, middle: pet"
         : "Omate (disabled) — left: settings")
      : "Omate"
    fixedWidth: root.vertical ? -1 : Math.round(content.implicitWidth + scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.round(content.implicitHeight + scaledVerticalPadding * 2) : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton && root.serviceReady) root.petService.petThePet()
    }

    Item {
      id: content
      anchors.centerIn: parent
      implicitWidth: Style.bar.iconCanvas
      implicitHeight: Style.bar.iconCanvas

      PetSprite {
        anchors.fill: parent
        form: "cat"
        skin: root.serviceReady ? root.petService.skin : null
        anim: root.serviceReady ? root.petService.barAnim : "idle"
        frameMs: root.serviceReady && root.petService.sleeping ? 1100 : 600
      }
    }
  }
}
