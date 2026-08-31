import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
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
  // Set while walking to a corner; consumed on arrival.
  property bool pendingCorner: false

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
  property string action: "idle"   // idle | walk | climb | drag | fall | stunned
                                   //        | corner | chase | pull
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
    case "corner": return "corner"
    // Stalking and hauling both read as walking; the chomp itself reuses
    // the existing `poked` pose, which is already the startled/bite art.
    case "chase": return "walk"
    case "pull": return "walk"
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
    case "corner": return petService.drawableAnim("corner", ["idle"])
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

  // Whether this pack actually ships corner-trip frames. Deliberately NOT
  // petService.hasAnim("corner"): that answers true for any name on legacy
  // a/b packs, which would make Mochi mime the whole routine with its idle
  // sprite. Every bundled character is unaffected because none of them
  // declares a "corner" animation.
  function hasCornerArt() {
    var pack = petService ? petService.pack : null
    var a = pack && pack.anims ? pack.anims["corner"] : null
    return !!(a && a.frames && a.frames.length > 0)
  }

  // Idle, on the floor, awake, and drawable: the conditions for the brain to
  // pick a corner trip of its own accord.
  function canVisitCorner() {
    if (!petService || support || asleep || action !== "idle") return false
    return hasCornerArt()
  }

  // Trot to whichever end of the current surface is nearer, then go.
  // Reachable from the brain roll, the menu and IPC, so it guards itself
  // rather than trusting the caller.
  function startCornerTrip() {
    if (!hasCornerArt()) return
    if (action === "drag" || action === "fall" || action === "climb"
        || action === "stunned" || action === "corner") return
    if (petService) petService.wake(false)
    var bounds = currentSurfaceBounds()
    var leftX = bounds.x1
    var rightX = bounds.x2 - spriteW
    pendingCorner = true
    startWalkTo((petX - leftX) <= (rightX - petX) ? leftX : rightX, null)
  }

  // --- cursor chase ------------------------------------------------------
  //
  // Reads the pointer over Hyprland's IPC socket and, when it strays close
  // enough, drags it to the mate's mouth and bites it.
  //
  // Two rules shape the whole thing. It is OFF unless the user turns it on,
  // because it is the only behaviour that moves something outside the mate's
  // own window. And it can never trap the pointer: `maxPullMs` is a hard
  // ceiling on any single pull, the pointer is flung clear afterwards, and
  // every pull is followed by a cooldown, so the user always wins a tug of
  // war by simply out-lasting it.

  readonly property bool chaseEnabled: petService ? petService.cursorChase : false
  property int cursorX: -99999      // pointer, in Hyprland's global coords
  property int cursorY: -99999
  property string cursorBuf: ""
  // Hyprland 0.5x takes `hl.dsp.cursor.move({x = , y = })`; older releases
  // take `movecursor X Y`. Probed once, with a no-op warp to where the
  // pointer already is.
  property bool cursorLegacy: false
  property bool cursorProbed: false
  property int pullElapsed: 0
  property bool chaseResting: false
  // Where the pointer was when the haul started, so it can be handed back.
  property int pullOriginX: 0
  property int pullOriginY: 0
  property int chaseElapsed: 0

  // The reach is sprite-relative, so a bigger character has a slightly longer
  // one -- but CLAMPED, because unclamped it made the same setting mean wildly
  // different things. Akita (348px sprite) noticed the pointer from ~1560px
  // away, three quarters of a 2048px screen, while Mochi (72px) barely noticed
  // it at 324px: near-constant harassment for one character and near-inert for
  // another. The band keeps every pack inside roughly 2x of each other.
  function clampRadius(v, lo, hi) {
    return Math.round(Math.max(lo, Math.min(hi, v)))
  }

  // Starts a chase. Generous, because the pointer spends most of its life
  // nowhere near the floor the mate walks on -- but never more than a fraction
  // of the display, so a small screen does not become one big trigger zone.
  readonly property int noticeRadius: clampRadius(spriteW * 4.5, 380,
    Math.max(380, Math.min(720, width * 0.45)))
  // Abandons one. Deliberately far larger than noticeRadius: with a single
  // threshold the mate sets off, the pointer drifts a little, and it gives up
  // mid-approach -- it would spend all its time starting chases and none
  // finishing them.
  readonly property int giveUpRadius: Math.round(noticeRadius * 1.8)
  // Start hauling from well out. Tuned up from 1.7 body-lengths after watching
  // it: the mate would trot all the way over and only then tug the last ~80px,
  // so the haul was invisible and it just looked like a walk. Held below
  // noticeRadius so it can never out-reach the thing that starts the chase.
  readonly property int pullRadius: Math.min(
    clampRadius(spriteW * 3.0, 260, 520), Math.round(noticeRadius * 0.7))
  readonly property int biteRadius: clampRadius(spriteW * 0.5, 40, 110)
  // Strong enough to close a long haul before maxPullMs runs out. At 0.15 a
  // pull from across the screen timed out every time, which left the pointer
  // stranded halfway -- the exact "it ended up somewhere I never put it"
  // problem the hand-back is meant to avoid.
  readonly property real pullStrength: 0.25
  readonly property int maxPullMs: 4000
  // A chase that never gets anywhere is dropped, so the mate cannot end up
  // trailing the pointer around forever.
  readonly property int maxChaseMs: 14000

  // Where the teeth are, in global coords.
  readonly property real mouthGX: (hyprMonitor ? hyprMonitor.x : 0)
    + petX + (facingLeft ? spriteW * 0.24 : spriteW * 0.76)
  readonly property real mouthGY: (hyprMonitor ? hyprMonitor.y : 0)
    + petY - visH * 0.45

  function cursorDistance() {
    if (cursorX < -9999) return Number.POSITIVE_INFINITY
    var dx = cursorX - mouthGX
    var dy = cursorY - mouthGY
    return Math.sqrt(dx * dx + dy * dy)
  }

  // Chasing is for an awake mate standing on the floor. Riding a window is
  // left alone: hauling the pointer from up there would need the fall logic
  // to agree, and the joke is not worth the edge cases.
  //
  // A plain wander IS interruptible -- a mate that only noticed the pointer
  // while standing perfectly still would almost never notice it at all, since
  // wandering is its default state. A walk that is on its way somewhere
  // specific (a climb approach) is left to finish.
  function chaseAllowed() {
    if (!chaseEnabled || asleep || chaseResting || menu.open || support)
      return false
    if (!hasBiteArt()) return false
    if (action === "idle" || action === "chase" || action === "pull") return true
    return action === "walk" && !pendingClimb
  }

  // The chomp is played with the existing `poked` pose, so a pack without one
  // mimes the whole catch with its idle sprite: the pointer is hauled in and
  // then nothing visibly happens. Better not to chase at all than to chase
  // and have the payoff missing.
  //
  // hasAnim() is the right check: `poke` is an animation the engine already
  // knows, so it resolves correctly for legacy a/b packs (Mochi declares
  // `poke` with no frame list) as well as for frame-list packs.
  function hasBiteArt() {
    return petService ? petService.hasAnim("poke") : false
  }

  function warpCursor(x, y) {
    var gx = Math.round(x), gy = Math.round(y)
    Hyprland.dispatch(cursorLegacy
      ? ("movecursor " + gx + " " + gy)
      : ("hl.dsp.cursor.move({x = " + gx + ", y = " + gy + "})"))
  }

  function endChase(rest) {
    if (action === "chase" || action === "pull") action = "idle"
    pullElapsed = 0
    chaseElapsed = 0
    if (rest) { chaseResting = true; chaseRestTimer.restart() }
  }

  function biteCursor() {
    poked = true
    pokeTimer.restart()
    if (petService) {
      petService.playSound("poke")
      petService.sayFrom("bite")
    }
    // Hold it in its teeth for a beat before handing it back, so the chomp
    // is actually visible. Returning it instantly reads as a glitch: the
    // pointer snaps home before the bite pose has even drawn.
    biteHoldTimer.restart()
    endChase(true)
  }

  Timer {
    id: biteHoldTimer
    // Shorter than pokeTimer's 550ms, so the pointer is back before the bite
    // pose finishes and the mate is never left chewing on nothing.
    interval: 420
    onTriggered: root.warpCursor(root.pullOriginX, root.pullOriginY)
  }

  Timer {
    id: chaseRestTimer
    interval: (petService ? petService.chaseCooldownSec : 60) * 1000
    onTriggered: root.chaseResting = false
  }

  Socket {
    id: cursorSocket
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr/"
      + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket.sock"
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        // The plain `cursorpos` reply has no trailing newline, so SplitParser
        // would never fire; `j/cursorpos` is newline-terminated JSON.
        root.cursorBuf += line
        if (root.cursorBuf.indexOf("}") < 0) return
        try {
          var p = JSON.parse(root.cursorBuf)
          if (isFinite(p.x) && isFinite(p.y)) { root.cursorX = p.x; root.cursorY = p.y }
        } catch (e) { /* a partial or malformed reply: just skip this tick */ }
        root.cursorBuf = ""
      }
    }
  }

  // Hyprland closes the socket after every reply, so each poll reconnects.
  // Slow while merely watching, fast only while actually hauling.
  Timer {
    id: cursorPoll
    // hasBiteArt() is in the running condition, not just in chaseAllowed(),
    // so a pack that can never chase does not pay for a socket round-trip
    // every tick.
    running: root.visible && root.chaseEnabled && !root.asleep
      && !root.chaseResting && root.hasBiteArt()
    repeat: true
    // Two rates, and the split matters more than it looks. This timer runs
    // for as long as the feature is armed, so the watching rate is what the
    // feature actually costs when nothing is happening -- which is nearly
    // always. Noticing that the pointer has come near is a cheap question
    // that does not need asking eleven times a second; a quarter-second is
    // imperceptible for that. Once a chase is on, smoothness is the whole
    // point, and 90ms is what makes the haul read as a pull rather than a
    // series of jumps.
    //
    // Keyed on the chase, not on the pull: switching only when the pull began
    // left the approach on the slow tick and made the haul lurch. Both the
    // approach and the haul run at the fast rate, so `chaseElapsed` and
    // `pullElapsed` always accumulate the interval they were measured at.
    interval: (root.action === "chase" || root.action === "pull") ? 90 : 260
    onTriggered: {
      root.cursorBuf = ""
      cursorSocket.connected = true
      cursorSocket.write("j/cursorpos")
      cursorSocket.flush()
      root.tickChase()
    }
  }

  function tickChase() {
    if (!chaseAllowed()) { endChase(false); return }
    if (cursorX < -9999) return
    // Only bother with a pointer on this mate's own output.
    if (hyprMonitor) {
      var lx = cursorX - hyprMonitor.x, ly = cursorY - hyprMonitor.y
      if (lx < 0 || ly < 0 || lx > width || ly > height) { endChase(false); return }
    }
    if (!cursorProbed) probeCursorSyntax()

    var d = cursorDistance()

    if (action === "pull") {
      pullElapsed += cursorPoll.interval
      if (d < biteRadius) { biteCursor(); return }
      // Hard ceiling, and a bail-out if the user has dragged it well clear.
      // Two different ways to stop, and they deserve different endings.
      // If the user dragged the pointer clear, they are holding it: let go
      // where it is, and do not yank it back. But a plain timeout is the
      // mate's failure, not theirs, so put the pointer back where it was
      // picked up rather than abandoning it halfway across the screen.
      if (d > noticeRadius * 1.6) { endChase(true); return }
      if (pullElapsed > maxPullMs) {
        warpCursor(pullOriginX, pullOriginY)
        endChase(true)
        return
      }
      warpCursor(cursorX + (mouthGX - cursorX) * pullStrength,
                 cursorY + (mouthGY - cursorY) * pullStrength)
      return
    }

    if (d < pullRadius) {
      action = "pull"
      pullElapsed = 0
      pullOriginX = cursorX
      pullOriginY = cursorY
      if (petService) petService.sayFrom("chase")
      return
    }

    // Hysteresis: it takes noticeRadius to start caring, but giveUpRadius to
    // stop, so a pointer that drifts while the mate is walking over does not
    // call the whole thing off.
    var chasing = action === "chase"
    if (d < noticeRadius || (chasing && d < giveUpRadius)) {
      if (chasing) {
        chaseElapsed += cursorPoll.interval
        if (chaseElapsed > maxChaseMs) { endChase(true); return }
      } else {
        chaseElapsed = 0
      }
      action = "chase"
      facingLeft = cursorX < mouthGX
      targetX = clampX(cursorX - (hyprMonitor ? hyprMonitor.x : 0) - spriteW / 2)
      return
    }

    if (chasing) endChase(false)
  }

  // One no-op warp to the pointer's current position tells us whether this
  // Hyprland speaks the new dispatch syntax, without moving anything.
  function probeCursorSyntax() {
    cursorProbed = true
    probeSocket.connected = true
    probeSocket.write("dispatch hl.dsp.cursor.move({x = " + cursorX
                      + ", y = " + cursorY + "})")
    probeSocket.flush()
  }

  Socket {
    id: probeSocket
    path: cursorSocket.path
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function (reply) {
        if (reply.indexOf("ok") !== 0) root.cursorLegacy = true
      }
    }
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
    id: cornerTimer
    // Long enough to play a short frame set through twice.
    interval: 2600
    onTriggered: if (root.action === "corner") root.action = "idle"
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
      if (root.asleep && (root.action === "chase" || root.action === "pull"))
        root.endChase(false)
      if (root.asleep && (root.action === "walk" || root.action === "climb")) {
        root.pendingClimb = null
        root.pendingCorner = false
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
          } else if (root.pendingCorner) {
            root.pendingCorner = false
            // The pose plays rearward, so turn away from whichever edge we
            // just walked to and put the pet's back to the wall.
            var mid = (root.currentSurfaceBounds().x1
                       + root.currentSurfaceBounds().x2) / 2
            root.facingLeft = root.petX > mid
            root.action = "corner"
            cornerTimer.restart()
            if (root.petService) root.petService.sayFrom("corner")
          } else {
            root.action = "idle"
          }
          root.notePosition()
        } else {
          root.petX += root.petX < root.targetX ? step : -step
        }
      } else if (root.action === "chase") {
        // Same stepping as a walk, but the target keeps moving and arriving
        // is not the end of anything.
        var cstep = root.walkSpeed * dt
        if (Math.abs(root.targetX - root.petX) > cstep)
          root.petX += root.petX < root.targetX ? cstep : -cstep
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

      if (roll < 0.07 && root.canVisitCorner()) {
        root.startCornerTrip()
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
          root.pendingCorner = false
          root.endChase(true)
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
    // The point the menu was asked to open at, NOT where it ends up. Keeping
    // the raw request here lets menuBox clamp it against its own real height
    // as a binding -- see below for why that matters.
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
        ...(root.hasCornerArt()
            ? [{ label: "Find a corner", action: () => root.startCornerTrip() }] : []),
        { label: "Walk over", action: () => root.walkTo(Math.random() * Math.max(1, root.width - root.spriteW)) },
        // Only ever the *off* switch. Chasing is the one behaviour that
        // reaches out and moves something the user owns, so arming it stays in
        // the settings panel, next to the cadence and the sentence explaining
        // what it does -- a right-click menu sat between "Walk over" and "Nap
        // now" is too easy to arm by accident, and someone who does that has
        // no idea why their pointer started moving on its own. Turning it off
        // has no such cost, so that stays one click away from the mate itself.
        ...(root.chaseEnabled
            ? [{ label: "Stop chasing",
                 action: () => petService && petService.setCursorChase(false) }]
            : []),
        { label: root.asleep ? "Wake up" : "Nap now", action: () => petService && (root.asleep ? petService.wake(true) : petService.doze()) },
        { label: muted ? "Unmute" : "Mute", action: () => petService && petService.setSoundVolume(petService.soundVolume > 0 ? 0 : 0.5) },
        { label: "Hide Omate", action: () => petService && petService.updateSettings({ visible: false }) }
      ]
      // Store the raw point and let menuBox do the clamping. Clamping here
      // read menuBox.height one line after assigning `entries`, before the
      // column had been laid out again -- so it used the PREVIOUS menu's
      // height (or 0 on the very first open). The menu was then placed too
      // low and its bottom entries ran off the screen, intermittently,
      // depending on what the height happened to be last time.
      menu.x = x
      menu.y = y
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
    width: 120
    height: entriesColumn.height + 12
    // Clamped as bindings, so they re-evaluate the moment `height` settles
    // after the entry list changes. The mate lives on the floor, so a menu
    // opened at the pointer would otherwise always hang off the bottom edge.
    x: Math.max(4, Math.min(root.width - width - 4, menu.x))
    y: Math.max(4, Math.min(root.height - height - 4, menu.y))
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
