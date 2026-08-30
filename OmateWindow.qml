import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// The mate's world: a transparent full-screen overlay it wanders along the
// bottom edge (above the bar's reserved strip). Everything is click-through
// except the mate itself (mask), so the desktop stays usable. Pick it up and
// toss it — gravity takes over; hold still and it purrs; poke it and it
// mews; right-click for a tiny menu.
PanelWindow {
  id: root

  required property var petService

  // The output named by the screen setting, if it is currently connected;
  // otherwise the largest one.
  readonly property string preferredScreenName: {
    var name = petService && petService.settings ? petService.settings.screen : ""
    return typeof name === "string" ? name : ""
  }
  // The settings/auto pick: named output, else the largest one.
  readonly property var autoScreen: {
    var screens = Quickshell.screens
    var i
    if (preferredScreenName !== "") {
      for (i = 0; i < screens.length; i++)
        if (screens[i].name === preferredScreenName) return screens[i]
      // Named screen unplugged: fall through rather than leave the mate homeless.
    }
    var best = null
    for (i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }
  // Runtime override: dragging, flinging or hopping across outputs moves
  // the whole overlay to the neighboring screen until settings say otherwise.
  property var screenTarget: null
  screen: screenTarget || autoScreen

  // Set while the surface is switching outputs mid-drag/migration, so
  // onScreenChanged keeps the in-flight position instead of re-grounding.
  property bool migrating: false

  anchors {
    left: true
    right: true
    top: true
    bottom: true
  }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.namespace: "omate"

  // Click-through everywhere except the mate — except while a press or the
  // menu is active, where the whole window catches input: on an empty
  // workspace Hyprland drops the implicit grab on layer surfaces, so a
  // cursor outrunning the sprite would leave the input region and freeze
  // the drag midair.
  mask: Region {
    item: menu.open || grab.pressed ? root.contentItem : petHitbox
  }

  readonly property int petScale: petService ? petService.petScale : 3
  // Pack canvas size; v2 packs may be non-square (anime frames).
  readonly property int baseW: petService && petService.pack
    ? (Math.round(Number(petService.pack.width)) > 0
       ? Math.round(Number(petService.pack.width))
       : Math.round(Number(petService.pack.spriteSize)) || 24) : 24
  readonly property int baseH: petService && petService.pack
    ? (Math.round(Number(petService.pack.height)) > 0
       ? Math.round(Number(petService.pack.height)) : baseW) : baseW
  readonly property int spriteW: baseW * petScale
  readonly property int spriteH: baseH * petScale
  // Packs may declare footY: the y of the actual feet inside the canvas.
  // Poses with content below their anchor would otherwise pad every frame
  // with empty rows and leave the mate hovering above the floor. footPad is
  // that invisible strip; visH is the height up to the visible feet.
  readonly property int footPad: {
    var fy = petService && petService.pack
      ? Number(petService.pack.footY) : 0
    if (!(fy > 0) || petScale <= 0) return 0
    return Math.max(0, Math.min(spriteH, spriteH - Math.round(fy * petScale)))
  }
  readonly property int visH: spriteH - footPad
  // Extra ring around the sprite that still counts as a grab.
  readonly property int grabMargin: 6
  // Headroom so the mate never pokes off-screen.
  readonly property int headroom: spriteH + 12

  readonly property var hyprMonitor: Hyprland.monitorFor(root.screen)

  // The bar's reserved strip, so the floor sits above a bottom bar.
  readonly property real floorY: {
    var ipc = hyprMonitor ? hyprMonitor.lastIpcObject : null
    var reservedBottom = ipc && ipc.reserved && ipc.reserved.length > 3
      ? Number(ipc.reserved[3]) : 0
    return height - reservedBottom
  }

  // The compositor only pushes monitor events on (un)plug and mode changes;
  // poll occasionally so a bar resize moves the floor too, and so a migrated
  // screen that got unplugged hands the mate back to the auto pick.
  Timer {
    interval: 15000
    running: root.visible
    repeat: true
    onTriggered: {
      if (root.screenTarget && Quickshell.screens.indexOf(root.screenTarget) < 0)
        root.screenTarget = null
      Hyprland.refreshMonitors()
      refreshDebounce.restart()
    }
  }

  // Window geometry drives the platform model, so every layout-relevant
  // event triggers a debounced refresh. lastIpcObject lands a moment after
  // the refresh request, hence the second delay before rebuilding.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      switch (event.name) {
      case "openwindow":
      case "closewindow":
      case "movewindow":
      case "movewindowv2":
      case "resizewindow":
      case "workspace":
      case "workspacev2":
      case "changefloatingmode":
      case "fullscreen":
      case "focusedmon":
        refreshDebounce.restart()
      }
    }
  }

  Timer {
    id: refreshDebounce
    interval: 250
    onTriggered: {
      Hyprland.refreshToplevels()
      rebuildDelay.restart()
    }
  }
  Timer {
    id: rebuildDelay
    interval: 350
    onTriggered: root.rebuildPlatforms()
  }
  // Fallback sweep for anything the event filter misses.
  Timer {
    interval: 7000
    running: root.visible
    repeat: true
    onTriggered: refreshDebounce.restart()
  }

  // --- world model --------------------------------------------------------------

  // Walkable surfaces: the tops of floating windows on this screen's active
  // workspace, as {x1, x2, y, address}. The floor is the implicit surface
  // behind them. The mate climbs up, rides windows as they move, and falls
  // when its perch closes, unfloats, or slides away.
  property var platforms: []
  // Current support: null = floor, else a platform object from `platforms`.
  property var support: null
  // Chosen climb target {wallX, platform} while walking to a wall.
  property var pendingClimb: null
  // Set while walking to a corner for a pee; consumed on arrival.
  property bool pendingPee: false

  function rebuildPlatforms() {
    if (!hyprMonitor) { platforms = []; validateSupport(); return }
    var ws = hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1
    var list = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      var ipc = toplevel.lastIpcObject
      if (!ipc || !ipc.at || !ipc.size) continue
      if (!toplevel.workspace || toplevel.workspace.id !== ws) continue
      if (ipc.hidden === true || ipc.mapped === false) continue
      if (ipc.fullscreen) continue
      if (ipc.floating !== true) continue
      var y = ipc.at[1] - hyprMonitor.y
      var x1 = ipc.at[0] - hyprMonitor.x
      var x2 = x1 + ipc.size[0]
      // Keep only tops the mate can stand on without leaving the screen,
      // and that are actually above the floor.
      if (y < root.headroom || y > root.floorY - 10) continue
      x1 = Math.max(0, x1)
      x2 = Math.min(root.width, x2)
      if (x2 - x1 < root.spriteW) continue
      list.push({ x1: x1, x2: x2, y: y, address: toplevel.address })
    }
    platforms = list
    validateSupport()
  }

  // The world changed under the mate's feet: follow the window it stands on
  // (windows are rideable!), or fall if it vanished, unfloat, or slid away.
  function validateSupport() {
    if (!support) return
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (p.address === support.address) {
        support = p
        if (action !== "climb" && action !== "fall") {
          petY = p.y
          if (petX < p.x1 || petX + spriteW > p.x2) startFall()
        }
        return
      }
    }
    support = null
    if (action !== "fall") startFall()
  }

  function currentSurfaceBounds() {
    return support
      ? { x1: support.x1, x2: support.x2 }
      : { x1: 0, x2: root.width }
  }

  // The highest surface below (x, fromY): a window top, else the floor.
  function landingBelow(x, fromY) {
    var best = { y: floorY, platform: null }
    var center = x + spriteW / 2
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (p.y > fromY + 1 && p.y < best.y && center >= p.x1 && center <= p.x2)
        best = { y: p.y, platform: p }
    }
    return best
  }

  // Climbable walls from here: edges of higher platforms whose base is
  // reachable by walking on the current surface.
  function climbCandidates() {
    var bounds = currentSurfaceBounds()
    var found = []
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (support && p.address === support.address) continue
      if (p.y >= petY - spriteH) continue
      if (p.x1 >= bounds.x1 && p.x1 <= bounds.x2 - spriteW)
        found.push({ wallX: p.x1, platform: p })
      else if (p.x2 - spriteW >= bounds.x1 && p.x2 <= bounds.x2)
        found.push({ wallX: p.x2 - spriteW, platform: p })
    }
    return found
  }

  // --- mate state --------------------------------------------------------------

  property real petX: 0
  property real petY: 0            // the mate's feet line
  property bool facingLeft: false
  property string action: "idle"   // idle | walk | climb | drag | fall | stunned | pee
  property real targetX: 0
  property real targetY: 0
  // Throw velocity from the last drag samples.
  property real vx: 0
  property real vy: 0
  property real fallStartY: 0
  // Startled pose right after a poke.
  property bool poked: false

  readonly property bool asleep: petService ? petService.sleeping : false
  // Deliberate trips (screen hops) land on their feet, however high —
  // only accidents leave the mate seeing stars.
  property bool gentleFall: false
  readonly property real walkSpeed: petScale * 26      // px/s
  readonly property real climbSpeed: petScale * 18     // px/s
  readonly property real gravity: petScale * 700       // px/s²
  readonly property real maxFallSpeed: petScale * 180
  // Falls past a third of the screen leave the mate seeing stars.
  readonly property real stunFallFraction: 0.33

  readonly property string rawAnim: {
    if (asleep) return "sleep"
    if (poked) return "poke"
    switch (action) {
    case "walk": return "walk"
    case "climb": return "climb"
    case "drag": return "drag"
    case "sit": return "sit"
    case "lie": return "lie"
    case "fall": return "fall"
    case "pee": return "pee"
    // Grounded as a result of the fall: the impact pose (frozen, since the
    // mate is dazed until the stun wears off).
    case "stunned": return "land"
    case "land": return "land"
    default: return "idle"
    }
  }
  // Packs without dedicated art (sleep/fall/poke…) fall back to the nearest
  // drawable animation instead of provoking the image loader.
  readonly property string currentAnim: {
    if (!petService) return rawAnim
    switch (rawAnim) {
    case "sleep": return petService.drawableAnim("sleep", ["idle"])
    case "poke": return petService.drawableAnim("poke", ["idle"])
    case "fall": return petService.drawableAnim("fall", ["drag", "idle"])
    case "climb": return petService.drawableAnim("climb", ["walk", "idle"])
    case "sit": return petService.drawableAnim("sit", ["idle"])
    case "lie": return petService.drawableAnim("lie", ["sit", "idle"])
    case "land": return petService.drawableAnim("land", ["fall", "idle"])
    case "pee": return petService.drawableAnim("pee", ["idle"])
    default: return petService.drawableAnim(rawAnim, ["idle"])
    }
  }

  function clampX(x) { return Math.max(0, Math.min(root.width - spriteW, x)) }
  function clampY(y) { return Math.max(root.headroom, Math.min(root.floorY, y)) }

  // The nearest output left or right of the current one.
  function neighborScreen(right) {
    var best = null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      if (!screen || s.name === screen.name) continue
      if (right ? s.x > screen.x : s.x < screen.x) {
        if (!best || Math.abs(s.x - screen.x) < Math.abs(best.x - screen.x))
          best = s
      }
    }
    return best
  }

  // Move the whole overlay to another output, keeping the mate at the given
  // local position. The layer surface itself migrates; if the compositor
  // drops the pointer grab while doing so, the drag's onCanceled turns the
  // trip into a drop on the new screen.
  function migrateTo(other, localX, localY) {
    if (!other || !screen || other.name === screen.name) return false
    support = null
    pendingClimb = null
    migrating = true
    screenTarget = other
    petX = clampX(localX)
    petY = clampY(localY)
    notePosition()
    return true
  }

  // Teleport to a named output: drop in from above, gently.
  function gotoScreen(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name !== name) continue
      var target = screens[i]
      gentleFall = true
      if (migrateTo(target, Math.max(0, target.width / 2 - spriteW / 2), headroom + 4))
        startFall()
      return true
    }
    return false
  }

  function startFall() {
    pendingClimb = null
    if (action !== "fall") fallStartY = petY
    action = "fall"
  }

  // Whether this pack actually ships pee frames. Deliberately NOT
  // petService.hasAnim("pee"): that answers true for any name on legacy a/b
  // packs, which would make Mochi mime the whole routine with its idle
  // sprite. Every bundled character is unaffected because none of them
  // declares a "pee" animation.
  function hasPeeArt() {
    var pack = petService ? petService.pack : null
    var a = pack && pack.anims ? pack.anims["pee"] : null
    return !!(a && a.frames && a.frames.length > 0)
  }

  // Idle, on the floor, awake, and drawable: the conditions for the brain to
  // pick a corner trip of its own accord.
  function canPee() {
    if (!petService || support || asleep || action !== "idle") return false
    return hasPeeArt()
  }

  // Trot to whichever end of the current surface is nearer, then go.
  // Reachable from the brain roll, the menu and IPC, so it guards itself
  // rather than trusting the caller.
  function startPeeTrip() {
    if (!hasPeeArt()) return
    if (action === "drag" || action === "fall" || action === "climb"
        || action === "stunned" || action === "pee") return
    if (petService) petService.wake(false)
    var bounds = currentSurfaceBounds()
    var leftX = bounds.x1
    var rightX = bounds.x2 - spriteW
    pendingPee = true
    startWalkTo((petX - leftX) <= (rightX - petX) ? leftX : rightX, null)
  }

  function startWalkTo(x, climb) {
    if (asleep && petService) petService.wake(false)
    var bounds = currentSurfaceBounds()
    targetX = Math.max(bounds.x1, Math.min(bounds.x2 - spriteW, x))
    pendingClimb = climb || null
    facingLeft = targetX < petX
    action = "walk"
  }

  function walkTo(x) {
    if (asleep && petService) petService.wake(false)
    targetX = clampX(x)
    facingLeft = targetX < petX
    action = "walk"
  }

  // Teleport onto a random floating window top (staying put is fine too);
  // with no windows around, take a leap of faith instead. Falls and rides
  // work as always afterwards.
  function hopToWindow() {
    if (action === "drag") return
    if (petService) {
      petService.wake(false)
      petService.noteInteraction()
      if (Math.random() < 0.5) petService.sayFrom("hop")
      petService.playSound("grab")
    }
    var candidates = []
    for (var i = 0; i < platforms.length; i++) {
      if (!support || platforms[i].address !== support.address) candidates.push(platforms[i])
    }
    if (candidates.length === 0) {
      // Nothing to land on: a little jump that ends in a tumble.
      support = null
      pendingClimb = null
      fallStartY = petY
      vy = -maxFallSpeed * 0.55
      vx = (Math.random() - 0.5) * petScale * 220
      startFall()
      return
    }
    var pick = candidates[Math.floor(Math.random() * candidates.length)]
    petX = clampX(pick.x1 + Math.random() * Math.max(1, pick.x2 - pick.x1 - spriteW))
    petY = pick.y
    support = pick
    pendingClimb = null
    vx = 0
    vy = 0
    facingLeft = Math.random() < 0.5
    action = "idle"
    notePosition()
  }

  Timer {
    id: peeTimer
    // Long enough to play the four frames through twice.
    interval: 2600
    onTriggered: if (root.action === "pee") root.action = "idle"
  }

  Timer {
    id: stunTimer
    interval: 1200
    onTriggered: if (root.action === "stunned") root.action = "idle"
  }

  Timer {
    id: pokeTimer
    interval: 550
    onTriggered: root.poked = false
  }

  // Ends a sitting/lying pose. Grabbing or anything else that changes the
  // action simply makes the tick a no-op.
  Timer {
    id: poseTimer
    onTriggered: if (root.action === "sit" || root.action === "lie")
                   root.action = "idle"
  }

  // Brief ground-impact beat after a fall (packs with impact art only).
  Timer {
    id: landTimer
    interval: 450
    onTriggered: if (root.action === "land") root.action = "idle"
  }

  // Settle into a resting pose for a while.
  function takePose(pose) {
    if (action !== "idle") return
    action = pose
    poseTimer.interval = 5000 + Math.floor(Math.random() * 9000)
    poseTimer.restart()
  }

  // --- physics -----------------------------------------------------------------

  Timer {
    id: physics
    interval: 40
    running: root.visible
    repeat: true
    onTriggered: {
      var dt = interval / 1000
      // Falling asleep mid-stride used to sleepwalk: the sleep pose played
      // while the walk kept sliding to its target. Asleep means standing
      // still — the sleep pose, or idle for packs without sleep art.
      if (root.asleep && (root.action === "walk" || root.action === "climb")) {
        root.pendingClimb = null
        root.pendingPee = false
        root.targetX = root.petX
        root.action = "idle"
      }
      if (root.action === "walk") {
        var step = root.walkSpeed * dt
        if (Math.abs(root.targetX - root.petX) <= step) {
          root.petX = root.targetX
          if (root.pendingClimb) {
            root.targetY = root.pendingClimb.platform.y
            root.action = "climb"
          } else if (root.pendingPee) {
            root.pendingPee = false
            // Turn tail to the wall: the sprite pees rearward, so face away
            // from whichever edge we just walked to.
            var mid = (root.currentSurfaceBounds().x1
                       + root.currentSurfaceBounds().x2) / 2
            root.facingLeft = root.petX > mid
            root.action = "pee"
            peeTimer.restart()
            if (root.petService) root.petService.sayFrom("pee")
          } else {
            root.action = "idle"
          }
          root.notePosition()
        } else {
          root.petX += root.petX < root.targetX ? step : -step
        }
      } else if (root.action === "climb") {
        var rise = root.climbSpeed * dt
        if (root.petY - root.targetY <= rise) {
          root.petY = root.targetY
          root.support = root.pendingClimb ? root.pendingClimb.platform : root.support
          root.pendingClimb = null
          root.action = "idle"
          root.notePosition()
        } else {
          root.petY -= rise
        }
      } else if (root.action === "fall") {
        var landing = root.landingBelow(root.petX, root.petY)
        var drop = Math.min(root.maxFallSpeed, root.vy + root.gravity * dt)
        root.vy = drop
        root.petY += drop * dt
        if (root.vx !== 0) {
          root.petX += root.vx * dt
          root.vx *= 0.985
          if (root.petX <= 0 || root.petX >= root.width - root.spriteW) {
            root.vx = -root.vx * 0.5
            root.petX = root.clampX(root.petX)
          }
        }
        if (root.petY >= landing.y) {
          root.petY = landing.y
          root.support = landing.platform
          var bigDrop = !root.gentleFall
            && root.petY - root.fallStartY > root.height * root.stunFallFraction
          root.gentleFall = false
          root.vx = 0
          root.vy = 0
          if (bigDrop) {
            root.action = "stunned"
            root.facingLeft = false
            // Freeze on the impact pose: a paused "flat on the ground"
            // beat instead of whatever frame the fall was on.
            sprite.restart()
            stunTimer.restart()
          } else if (root.petService && root.petService.hasAnim("land")) {
            // A short impact beat before carrying on.
            root.action = "land"
            landTimer.restart()
          } else {
            root.action = "idle"
          }
          if (root.petService) root.petService.landed(bigDrop)
          root.notePosition()
        }
      }
    }
  }

  // --- the wandering brain -------------------------------------------------------

  Timer {
    id: brain
    interval: 2500
    running: root.visible && root.action === "idle" && !root.asleep
      && root.petService && root.petService.roaming && !menu.open
    repeat: true
    onTriggered: {
      interval = 2500 + Math.floor(Math.random() * 5000)
      var roll = Math.random()
      var climbs = root.climbCandidates()

      if (roll < 0.07 && root.canPee()) {
        root.startPeeTrip()
      } else if (roll < 0.22 && climbs.length > 0) {
        var pick = climbs[Math.floor(Math.random() * climbs.length)]
        root.startWalkTo(pick.wallX, pick)
      } else if (roll < 0.34 && root.support) {
        // Hop off the current window.
        root.startFall()
      } else if (roll < 0.46 && root.petService.hasAnim("sit")) {
        root.takePose("sit")
      } else if (roll < 0.51 && root.petService.hasAnim("lie")) {
        root.takePose("lie")
      } else if (roll < 0.51 + root.petService.walkiness * 0.45) {
        var bounds = root.currentSurfaceBounds()
        var span = Math.max(0, bounds.x2 - bounds.x1 - root.spriteW)
        root.walkTo(bounds.x1 + Math.random() * span)
      }
      // else: lazing around is also living.
    }
  }

  // --- keeping the feet on the floor ----------------------------------------------

  function resetPosition() {
    support = null
    pendingClimb = null
    var w = width > 0 ? width : (screen ? screen.width : 0)
    var svc = petService
    if (svc && svc.petX >= 0 && svc.petX <= w - spriteW && w > 0) {
      petX = svc.petX
      petY = clampY(svc.petY)
    } else {
      petX = Math.max(0, w / 2 - spriteW / 2)
      petY = floorY
    }
    facingLeft = svc ? svc.facingLeft : false
    action = asleep ? "idle" : action
    refreshDebounce.restart()
  }

  function notePosition() {
    if (petService) petService.notePosition(petX, petY, facingLeft)
  }

  // The window can be born visible, so onVisibleChanged alone never fires;
  // and the real height only arrives once the surface is mapped, so the
  // floor glue keeps the mate grounded instead of hovering at y 0.
  Component.onCompleted: resetPosition()
  onVisibleChanged: if (visible) { resetPosition(); notePosition() }
  // Moving to another output: re-ground on the new monitor's floor — unless
  // a migration is carrying the mate over mid-flight.
  onScreenChanged: {
    if (!visible) return
    if (migrating) { migrating = false; return }
    resetPosition()
  }
  onFloorYChanged: {
    if ((action === "idle") && !support && Math.abs(petY - floorY) > 1) petY = floorY
  }

  // --- the mate --------------------------------------------------------------------

  // Hitbox: the sprite plus a small grab ring, so picking it up is easy.
  // visH measures down to the visible feet (pack.footY), so a footPad of
  // below-anchor canvas padding never reads as floating above the floor.
  Item {
    id: petHitbox
    x: root.petX - root.grabMargin
    y: root.petY - root.visH - root.grabMargin
    width: root.spriteW + root.grabMargin * 2
    height: root.visH + root.grabMargin * 2

    PetSprite {
      id: sprite
      x: root.grabMargin
      y: root.grabMargin
      width: root.spriteW
      height: root.spriteH
      skin: petService ? petService.skin : null
      anim: root.currentAnim
      // Falling reuses the dangling frames; sleeping falls back to plain
      // idle for packs without sleep art.
      fallbackAnim: root.asleep ? "idle"
        : (root.action === "fall" || root.action === "stunned") ? "drag" : "idle"
      frameMs: 500
      // A dazed mate lies still: cycling the fall frames on the ground reads
      // as "still falling", not as a stun.
      playing: root.action !== "stunned"
      mirrored: root.facingLeft
      // Climbing reuses the side-profile walk frames rotated nose-up — but
      // only when the pack has no real climb art (the resolved anim would
      // be "climb"). The sign has to match the mirror: rotating a
      // left-facing (mirrored) sprite by -90 would stand it on its head.
      rotation: root.action === "climb" && root.currentAnim !== "climb"
        ? (root.facingLeft ? 90 : -90) : 0
      Behavior on rotation { NumberAnimation { duration: 150 } }
    }

    // Press-and-hold = petting (purr + hearts); press-and-move = pick it up.
    // Once pressed, the Wayland implicit grab keeps pointer events coming to
    // this surface even when the cursor leaves the click mask, so the drag
    // survives crossing other windows.
    MouseArea {
      id: grab
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      enabled: root.action !== "stunned"
      cursorShape: root.action === "drag" ? Qt.ClosedHandCursor : Qt.PointingHandCursor

      property real grabDx: 0
      property real grabDy: 0
      property real pressX: 0
      property real pressY: 0
      property bool dragging: false
      // True between a left-button press and its release; right-button presses
      // open the menu instead and must never reach the drag/poke logic.
      property bool leftPress: false
      // Recent samples to derive throw velocity on release.
      property var samples: []

      onPressed: function(mouse) {
        if (mouse.button !== Qt.LeftButton) {
          menu.openAt(petHitbox.x + petHitbox.width, petHitbox.y)
          return
        }
        leftPress = true
        var p = mapToItem(root.contentItem, mouse.x, mouse.y)
        pressX = p.x
        pressY = p.y
        grabDx = p.x - root.petX
        grabDy = p.y - (root.petY - root.visH)
        dragging = false
        samples = [{ t: Date.now(), x: p.x, y: p.y }]
        holdTimer.restart()
      }

      onPositionChanged: function(mouse) {
        if (!pressed || !leftPress) return
        var p = mapToItem(root.contentItem, mouse.x, mouse.y)
        // Crossing to a neighboring output: the cursor well past this
        // window's edge is the cue. Compositors that clamp motion to the
        // surface will never see this; the fling path below still works.
        if (dragging && (p.x > root.width + 80 || p.x < -80)) {
          var dirRight = p.x > root.width
          var other = root.neighborScreen(dirRight)
          if (other) {
            var gX = (root.screen ? root.screen.x : 0) + (p.x - grabDx)
            var gY = (root.screen ? root.screen.y : 0) + (p.y - grabDy + root.visH)
            root.migrateTo(other, gX - other.x, gY - other.y)
          }
          return
        }
        if (!dragging) {
          if (Math.abs(p.x - pressX) < 8 && Math.abs(p.y - pressY) < 8) return
          dragging = true
          holdTimer.stop()
          if (petting.active) petting.stop()
          root.action = "drag"
          root.support = null
          root.pendingClimb = null
          root.pendingPee = false
          root.vx = 0
          root.vy = 0
          if (petService) petService.grabStart()
        }
        root.petX = root.clampX(p.x - grabDx)
        root.petY = root.clampY(p.y - grabDy + root.visH)
        var now = Date.now()
        samples.push({ t: now, x: p.x, y: p.y })
        if (samples.length > 4) samples.shift()
      }

      onReleased: {
        if (!leftPress) return
        leftPress = false
        holdTimer.stop()
        if (dragging) {
          dragging = false
          // A strong fling along the screen edge throws her across to the
          // neighboring output.
          var other = null
          if (root.vx > 350 && root.petX > root.width - root.spriteW * 2)
            other = root.neighborScreen(true)
          else if (root.vx < -350 && root.petX < root.spriteW * 2)
            other = root.neighborScreen(false)
          if (other && other.width > root.spriteW) {
            var entryX = root.vx > 0 ? 4 : other.width - root.spriteW - 4
            root.migrateTo(other, entryX, root.clampY(
              (root.screen ? root.screen.y : 0) + root.petY - other.y))
            root.startFall()
          } else {
            throwFromSamples()
          }
        } else if (petting.active) {
          petting.stop()
        } else {
          // A quick tap: a poke.
          root.poked = true
          pokeTimer.restart()
          if (petService) petService.pokeThePet()
        }
      }

      onCanceled: {
        leftPress = false
        holdTimer.stop()
        if (dragging) {
          dragging = false
          root.startFall()
        }
        if (petting.active) petting.stop()
      }

      function throwFromSamples() {
        var first = samples.length > 0 ? samples[0] : null
        var last = samples.length > 0 ? samples[samples.length - 1] : null
        if (first && last) {
          var dt = Math.max(0.01, (last.t - first.t) / 1000)
          var cap = root.petScale * 500
          root.vx = Math.max(-cap, Math.min(cap, (last.x - first.x) / dt))
          root.vy = Math.max(-cap, Math.min(cap, (last.y - first.y) / dt))
        } else {
          root.vx = 0
          root.vy = 0
        }
        // A small lift so a drop aimed at an edge lands on it instead of
        // slipping just past.
        root.petY = Math.max(root.headroom, root.petY - 6)
        root.startFall()
        notePosition()
      }
    }

    // Petting: the press survived 600 ms without becoming a drag. Every beat
    // purrs and pops a heart; a sleeping cat keeps sleeping through it.
    Timer {
      id: holdTimer
      interval: 600
      onTriggered: {
        if (grab.pressed && !grab.dragging) petting.start()
      }
    }

    QtObject {
      id: petting
      property bool active: false

      function start() {
        active = true
        beat()
        beatTimer.restart()
      }
      function stop() {
        active = false
        beatTimer.stop()
      }
      function beat() {
        if (petService) petService.petThePet()
        heart.pop()
      }
    }

    // The petting purr/heart beat.
    Timer {
      id: beatTimer
      interval: 900
      repeat: true
      running: petting.active
      onTriggered: petting.beat()
    }
  }

  // --- speech bubble -----------------------------------------------------------------

  property string bubbleText: ""
  readonly property bool bubbleVisible: bubbleText !== ""

  function say(text) {
    bubbleText = text
    bubbleHideTimer.interval = 2500 + Math.max(0, text.length) * 45
    bubbleHideTimer.restart()
  }

  Connections {
    target: petService
    function onSayRequested(text) {
      if (root.visible) root.say(text)
    }
    function onPetted() {
      if (root.visible) heart.pop()
    }
  }

  Timer {
    id: bubbleHideTimer
    onTriggered: root.bubbleText = ""
  }

  Item {
    id: bubble
    visible: root.bubbleVisible && root.action !== "drag"
    width: Math.min(bubbleLabel.implicitWidth, 170) + 14
    height: bubbleLabel.implicitHeight + 10
    x: Math.max(4, Math.min(root.width - width - 4,
      root.petX + root.spriteW / 2 - width / 2))
    y: Math.max(2, root.petY - root.spriteH - height - 8)

    Rectangle {
      id: bubbleBox
      anchors.fill: parent
      radius: 8
      color: Qt.rgba(0.14, 0.11, 0.08, 0.94)
      border.color: "#e8a355"
      border.width: 1

      Text {
        id: bubbleLabel
        anchors.centerIn: parent
        width: Math.min(implicitWidth, 170)
        wrapMode: Text.Wrap
        text: root.bubbleText
        color: "#f8f2e5"
        // Modest and capped: huge packs must not inflate the bubble.
        font.pixelSize: Math.min(13, Math.max(11, Math.round(root.spriteH * 0.08)))
        font.family: "sans-serif"
      }
    }
  }

  // --- little flourishes ---------------------------------------------------------------

  Text {
    id: heart
    text: "♥"
    color: "#ef6b95"
    font.pixelSize: Math.min(18, Math.max(14, Math.round(root.spriteH * 0.16)))
    x: root.petX + root.spriteW / 2 - width / 2
    opacity: 0

    property real rise: 0
    y: root.petY - root.spriteH - height - rise

    function pop() { heartAnimation.restart() }

    ParallelAnimation {
      id: heartAnimation
      NumberAnimation { target: heart; property: "rise"; from: 0; to: root.spriteH * 0.9; duration: 700 }
      SequentialAnimation {
        NumberAnimation { target: heart; property: "opacity"; from: 0; to: 1; duration: 150 }
        NumberAnimation { target: heart; property: "opacity"; to: 0; duration: 550 }
      }
    }
  }

  Text {
    text: "z z Z"
    visible: root.asleep
    color: "#cfc6b8"
    font.pixelSize: Math.min(16, Math.max(11, Math.round(root.spriteH * 0.12)))
    x: root.petX + root.spriteW
    y: root.petY - root.spriteH - height / 2

    SequentialAnimation on opacity {
      running: visible
      loops: Animation.Infinite
      NumberAnimation { from: 0.25; to: 1; duration: 1300 }
      NumberAnimation { from: 1; to: 0.25; duration: 1300 }
    }
  }

  // --- the menu --------------------------------------------------------------------------

  QtObject {
    id: menu

    property bool open: false
    property real x: 0
    property real y: 0
    // Rebuilt whenever the menu opens, so labels (Mute/Unmute, Nap/Wake…)
    // are current. Plain array model — no typed ListModel roles needed.
    property var entries: []

    function openAt(x, y) {
      var muted = petService && petService.soundVolume <= 0
      entries = [
        { label: "Settings…", action: () => petService && petService.panelRequested() },
        { label: "Window hop", action: () => root.hopToWindow() },
        ...(root.hasPeeArt()
            ? [{ label: "Find a corner", action: () => root.startPeeTrip() }] : []),
        { label: "Walk over", action: () => root.walkTo(Math.random() * Math.max(1, root.width - root.spriteW)) },
        { label: root.asleep ? "Wake up" : "Nap now", action: () => petService && (root.asleep ? petService.wake(true) : petService.doze()) },
        { label: muted ? "Unmute" : "Mute", action: () => petService && petService.setSoundVolume(petService.soundVolume > 0 ? 0 : 0.5) },
        { label: "Hide Omate", action: () => petService && petService.updateSettings({ visible: false }) }
      ]
      menu.x = Math.max(4, Math.min(root.width - menuBox.width - 4, x))
      menu.y = Math.max(4, Math.min(root.height - menuBox.height - 4, y))
      open = true
    }
    function close() { open = false }
  }

  // The menu makes the whole window grab input (see mask), so this backdrop
  // eats the click that dismisses it.
  MouseArea {
    anchors.fill: parent
    visible: menu.open
    onPressed: menu.close()
  }

  Item {
    id: menuBox
    parent: root.contentItem
    x: menu.x
    y: menu.y
    width: 120
    height: entriesColumn.height + 12
    visible: menu.open

    Rectangle {
      id: menuPanel
      anchors.fill: parent
      radius: 8
      color: Qt.rgba(0.14, 0.11, 0.08, 0.96)
      border.color: "#e8a355"
      border.width: 1

      Column {
        id: entriesColumn
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }

        Repeater {
          model: menu.entries

          Item {
            required property var modelData
            width: entriesColumn.width
            height: 26

            Rectangle {
              anchors.fill: parent
              radius: 5
              color: entryMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
            }

            Text {
              anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
              text: modelData.label
              color: "#f8f2e5"
              font.pixelSize: 12
            }

            MouseArea {
              id: entryMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                menu.close()
                modelData.action()
              }
            }
          }
        }
      }
    }
  }
}
