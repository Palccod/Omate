import QtQuick
import Quickshell
import Quickshell.Io

// Omate's headless brain: settings and pet state, the sleep cycle, the
// message engine, sounds and the IPC surface. Loaded once at shell startup,
// independent of the bar widget. The roaming window is a static child so it
// survives plugin reloads without leaking a layer surface.
//
// Everything is offline and self-contained: sounds are bundled WAVs played
// through pw-play, messages come from a user-editable JSON pool, and state
// lives in two small JSON files under ~/.local/state/omarchy/.
//
// Commands executed (all fixed argv, no interpolation): pw-play <file>
Item {
  id: root

  property var shell: null
  property var manifest: null

  // --- paths -----------------------------------------------------------------

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy"
  readonly property string settingsPath: stateDir + "/omate-settings.json"
  readonly property string petPath: stateDir + "/omate-state.json"
  // Extra character packs (e.g. anime sprites imported with
  // tools/import-spritesheet.py) live outside the repo so third-party art
  // never lands in git.
  readonly property string userPacksDir: stateDir + "/omate-packs"

  readonly property string repoPacksRoot: "packs/"
  readonly property string defaultPack: "default"

  // --- pack ------------------------------------------------------------------

  // The selected pack by directory name. Repo packs and user packs share the
  // namespace; a user pack with the same name wins.
  property string packName: defaultPack
  // pack.json of the selected pack. Embedded defaults keep the pet alive
  // even if every pack file is missing or corrupt. Two sprite formats are
  // supported: legacy a/b frame pairs sized `spriteSize`, and frame lists
  // sized `width` x `height` (imported packs).
  property var pack: ({
    spriteSize: 24,
    anims: { idle: { frameMs: 600 }, walk: { frameMs: 200 },
      sleep: { frameMs: 1100 }, drag: { frameMs: 260 },
      fall: { frameMs: 200 }, poke: { frameMs: 250 } }
  })
  // messages.json from the selected pack: what the mate says. Same deal —
  // the file is the user-editable copy of these defaults.
  property var messages: ({
    greet: ["I'm up! Did you miss me?"],
    idle: ["psst... pet me.", "*tail flick*", "this floor? immaculate."],
    drag: ["Whoa— put me down!"],
    pet: ["purrrrrr"],
    poke: ["boop."],
    land: ["oof."],
    dizzy: ["...the floor attacked."],
    sleep: ["nap time..."],
    wake: ["I'm awake! I'm awake."],
    hop: ["warp!", "poof!", "yeet."]
  })

  // Sprite URL prefix for the selected pack (PetSprite prepends frame
  // names). Absolute for user packs, plugin-relative for repo packs.
  // Views must read dir + anims from the atomic `skin` snapshot below, not
  // from `spriteDir`/`pack` separately: those update in two notifications,
  // and a frame painted in between would mix one pack's frames with
  // another pack's directory.
  property string spriteDir: repoPacksRoot + defaultPack + "/sprites/"
  // One-object snapshot of the active pack's sprite source, written in a
  // single assignment when a pack lands. Deliberately NOT a binding over
  // `pack`: a binding re-evaluates the moment pack changes, while spriteDir
  // still holds the previous pack's directory — a frame list under the
  // wrong directory. anims null renders legacy a/b sprites until the first
  // real pack lands.
  property var skin: ({ dir: repoPacksRoot + defaultPack + "/sprites/", anims: null })
  // Frame-list packs (imported anime sprites) list exactly the animations
  // they ship; legacy packs name a/b files by convention.
  readonly property bool packUsesFrameLists: Number(pack.width) > 0

  // Whether an animation name is actually drawable with the current pack,
  // so views can fall back without provoking the image loader.
  function hasAnim(anim) {
    var a = pack && pack.anims ? pack.anims[anim] : null
    if (a) return !packUsesFrameLists || !!(a.frames && a.frames.length > 0)
    if (!packUsesFrameLists) {
      // Legacy a/b pack: an anims entry, when present, names exactly the
      // pairs on disk; with no anims object at all every name is worth a
      // try (PetSprite's error fallback catches the misses).
      var anims = pack && pack.anims ? pack.anims : null
      return !anims || Object.keys(anims).length === 0
    }
    return false
  }

  // The nearest drawable animation for a requested one.
  function drawableAnim(requested, fallbacks) {
    if (hasAnim(requested)) return requested
    var list = fallbacks || ["idle"]
    for (var i = 0; i < list.length; i++)
      if (hasAnim(list[i])) return list[i]
    return "idle"
  }
  readonly property int spriteW: {
    var v = Number(pack.width) > 0 ? Number(pack.width) : Number(pack.spriteSize)
    return v > 0 ? Math.round(v) : 24
  }
  readonly property int spriteH: {
    var v = Number(pack.height) > 0 ? Number(pack.height) : spriteW
    return v > 0 ? Math.round(v) : spriteW
  }

  // --- settings --------------------------------------------------------------

  readonly property var defaultSettings: ({
    // Show the mate at all (bar widget's right/middle click toggles this).
    visible: true,
    // Let it wander on its own; off, it stays put but stays pettable.
    roamEnabled: true,
    // Which character pack to use (directory name under packs/ or
    // ~/.local/state/omarchy/omate-packs/).
    pack: defaultPack,
    // Sprite magnification, 1-6.
    scale: 3,
    // How adventurous the wandering is, 0 (lap cat) to 1 (zoomies).
    walkiness: 0.6,
    // Which output to live on, as Hyprland names it (e.g. "DP-1").
    // Empty picks the largest screen.
    screen: "",
    soundVolume: 0.5,
    // Minutes of being ignored before a nap.
    sleepMinutes: 10,
    // Chase and grab the mouse pointer. OFF by default and deliberately so:
    // this is the one behaviour that reaches outside the mate's own window
    // and moves something the user owns.
    cursorChase: false,
    // Seconds of peace after each bite. Five minutes by default: often
    // enough that someone who switches chasing on sees it happen, rare
    // enough that it never becomes the thing they notice all day. "Every ten
    // seconds" is delightful for an afternoon and unbearable for a working
    // week, and that second group does not go looking for the dial -- they
    // turn the whole feature off and never come back.
    chaseCooldownSec: 300,
    // Roughly one idle line every N minutes while awake.
    chatterMinutes: 4
  })
  property var settings: defaultSettings
  readonly property real soundVolume: {
    var v = Number(settings.soundVolume)
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : 0.5
  }
  readonly property int petScale: {
    var v = Number(settings.scale)
    return v >= 1 && v <= 6 ? Math.round(v) : 3
  }
  readonly property real walkiness: {
    var v = Number(settings.walkiness)
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : 0.6
  }

  // --- persistent pet facts ----------------------------------------------------

  // Last known spot, in window coordinates (feet line, left edge). -1 means
  // "no memory yet": spawn centered on the floor.
  property real petX: -1
  property real petY: -1
  property bool facingLeft: false
  property bool sleeping: false
  property int petCount: 0

  // --- runtime -----------------------------------------------------------------

  property double lastInteractionMs: 0
  property bool initialized: false
  // State files are read through `head -c` so a huge or symlinked file can
  // never be pulled whole into the shell; the plugin writes a few hundred
  // bytes, anything hitting the cap is treated as corrupt.
  readonly property int maxStateBytes: 65536
  property bool settingsFileLoaded: false
  property bool petFileLoaded: false
  property string loadedSettingsText: ""
  property string loadedPetText: ""
  // pack.json/messages.json of the selected pack, from the user pack dir
  // and the repo pack dir. The user copy wins whenever it exists.
  property string loadedUserPackText: ""
  property string loadedRepoPackText: ""
  property string loadedUserMessagesText: ""
  property string loadedRepoMessagesText: ""
  // Set by setPack so the next pack load adopts the pack's default scale.
  property bool pendingDefaultScale: false

  // Reads in flight for the current pack launch. applyPackIfReady stays
  // silent until all four landed: a messages file arriving early must not
  // recompute the sprite dir from another pack's stale pack.json text.
  property int packReadsPending: 0

  readonly property string effectivePackText:
    loadedUserPackText !== "" ? loadedUserPackText : loadedRepoPackText
  readonly property string effectiveMessagesText:
    loadedUserMessagesText !== "" ? loadedUserMessagesText : loadedRepoMessagesText

  readonly property bool roaming: settings.roamEnabled === true
  readonly property bool cursorChase: settings.cursorChase === true
  readonly property int chaseCooldownSec: {
    var v = Number(settings.chaseCooldownSec)
    return isFinite(v) ? Math.max(5, Math.min(3600, Math.round(v))) : 300
  }
  // What the bar widget should show.
  readonly property string barAnim: sleeping ? drawableAnim("sleep", ["idle"]) : "idle"
  readonly property string moodLabel: sleeping ? "Omate — sleeping" : "Omate"

  signal sayRequested(string text)
  signal petted()
  // The mate's right-click menu asks for the settings panel; the bar's
  // main-screen panel instance answers this (see OmatePanel).
  signal panelRequested()

  // --- sounds ------------------------------------------------------------------

  // One short clip per event, named after the event so better sounds can be
  // dropped in without touching code. All generated, see CREDITS.md.
  readonly property var eventSounds: ({
    grab: "grab.wav",
    pet: "pet.wav",
    poke: "poke.wav",
    land: "land.wav",
    zzz: "zzz.wav",
    wake: "wake.wav"
  })

  // pw-play wants a filesystem path, not a file:// URL.
  function pluginFile(relativePath) {
    var url = Qt.resolvedUrl(relativePath).toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  function playSound(event) {
    if (soundVolume <= 0) return
    var file = eventSounds[event]
    if (Array.isArray(file)) file = file[Math.floor(Math.random() * file.length)]
    if (!file) return
    // --playback explicitly: some pw-play builds (and sandboxed argv[0])
    // don't infer the mode from the program name.
    Quickshell.execDetached(["pw-play", "--playback", "--volume",
      soundVolume.toFixed(2), pluginFile("sounds/" + file)])
  }

  // --- messages ----------------------------------------------------------------

  function pick(pool) {
    var list = messages[pool]
    if (!list || list.length === 0) return ""
    return list[Math.floor(Math.random() * list.length)]
  }

  function say(text) {
    if (typeof text !== "string" || text === "") return
    sayRequested(text)
  }

  function sayFrom(pool) {
    say(pick(pool))
  }

  // --- actions -----------------------------------------------------------------

  function noteInteraction() {
    lastInteractionMs = Date.now()
  }

  // Petting a sleeping cat is allowed and does not wake it — it just purrs
  // in its sleep. Waking is for grabs and pokes.
  function petThePet() {
    noteInteraction()
    petCount += 1
    playSound("pet")
    // Not every purr needs a speech bubble; roughly every other pet.
    if (!sleeping && Math.random() < 0.4) sayFrom("pet")
    petted()
    flushPetSoon()
  }

  // --- actions (shared by the IPC surface, panel and menu) ----------------------

  function setMateVisible(visible) {
    updateSettings({ visible: visible === true })
  }

  function toggleMateVisible() {
    setMateVisible(settings.visible !== true)
  }

  function setRoaming(enabled) {
    updateSettings({ roamEnabled: enabled === true })
  }

  function setCursorChase(enabled) {
    updateSettings({ cursorChase: enabled === true })
  }

  function setChaseCooldown(seconds) {
    var v = Number(seconds)
    updateSettings({ chaseCooldownSec:
      isFinite(v) ? Math.max(5, Math.min(3600, Math.round(v))) : 300 })
  }

  function setSoundVolume(volume) {
    var v = Number(volume)
    updateSettings({ soundVolume: isFinite(v) ? Math.max(0, Math.min(1, v)) : 0.5 })
  }

  function pokeThePet() {
    noteInteraction()
    wake(false)
    playSound("poke")
    if (Math.random() < 0.5) sayFrom("poke")
    flushPetSoon()
  }

  function grabStart() {
    noteInteraction()
    wake(false)
    playSound("grab")
    if (Math.random() < 0.5) sayFrom("drag")
  }

  function landed(bigDrop) {
    noteInteraction()
    playSound("land")
    if (bigDrop) {
      sayFrom("dizzy")
    } else if (Math.random() < 0.3) {
      sayFrom("land")
    }
  }

  function wake(greet) {
    if (!sleeping) return
    sleeping = false
    noteInteraction()
    if (greet === true) {
      playSound("wake")
      sayFrom("wake")
    }
    flushPet()
  }

  function doze() {
    if (sleeping) return
    sleeping = true
    playSound("zzz")
    sayFrom("sleep")
    flushPet()
  }

  // Position bookkeeping from the roaming window; flushed on a delay so a
  // walk across the screen doesn't cause a write per frame.
  property bool positionDirty: false
  function notePosition(x, y, left) {
    petX = x
    petY = y
    facingLeft = left
    positionDirty = true
  }

  // --- timers --------------------------------------------------------------------

  // Nap check: ignored for long enough? Lights out.
  Timer {
    interval: 15000
    running: root.initialized
    repeat: true
    onTriggered: {
      if (root.sleeping || root.lastInteractionMs <= 0) return
      var minutes = Number(root.settings.sleepMinutes)
      if (!isFinite(minutes) || minutes <= 0) return
      if (Date.now() - root.lastInteractionMs >= minutes * 60000) root.doze()
    }
  }

  // Deferred position writes.
  Timer {
    interval: 45000
    running: root.initialized
    repeat: true
    onTriggered: {
      if (root.positionDirty) root.flushPet()
    }
  }

  // Idle chatter: one line every chatterMinutes (± a minute of jitter),
  // only while the mate is out and awake.
  function chatterInterval() {
    var minutes = Number(settings.chatterMinutes)
    if (!isFinite(minutes) || minutes <= 1) minutes = 4
    return Math.round((minutes + Math.random() * 2 - 1) * 60000)
  }

  Timer {
    interval: root.chatterInterval()
    running: root.initialized
    repeat: true
    onTriggered: {
      interval = root.chatterInterval()
      if (root.sleeping || root.settings.visible !== true) return
      if (Math.random() < 0.75) root.sayFrom("idle")
    }
  }

  // --- persistence -------------------------------------------------------------

  function flushPet() {
    positionDirty = false
    petFile.setText(JSON.stringify({
      petX: petX,
      petY: petY,
      facingLeft: facingLeft,
      sleeping: sleeping,
      petCount: petCount,
      lastInteractionMs: lastInteractionMs
    }, null, 2) + "\n")
  }

  function flushPetSoon() {
    if (!flushSoonTimer.running) flushSoonTimer.restart()
  }
  Timer {
    id: flushSoonTimer
    interval: 1500
    onTriggered: if (root.initialized) root.flushPet()
  }

  function updateSettings(patch) {
    var merged = {}
    for (var key in defaultSettings) merged[key] = defaultSettings[key]
    for (var current in settings) if (current in merged) merged[current] = settings[current]
    for (var change in patch) if (change in merged) merged[change] = patch[change]
    settings = merged
    settingsFile.setText(JSON.stringify(settings, null, 2) + "\n")
  }

  // --- init --------------------------------------------------------------------

  function initializeIfReady() {
    if (initialized || !settingsFileLoaded || !petFileLoaded) return

    try {
      var parsedSettings = loadedSettingsText !== "" ? JSON.parse(loadedSettingsText) : {}
      var merged = {}
      for (var key in defaultSettings) merged[key] = defaultSettings[key]
      for (var loaded in parsedSettings) if (loaded in merged) merged[loaded] = parsedSettings[loaded]
      settings = merged
    } catch (error) {
      console.warn("omate: settings file unreadable (" + error + "), using defaults")
      settings = defaultSettings
    }

    // Persisted numbers must be finite; anything else reads as "no memory".
    function num(v) { var n = Number(v); return isFinite(n) ? n : -1 }
    try {
      var pet = loadedPetText !== "" ? JSON.parse(loadedPetText) : {}
      petX = num(pet.petX)
      petY = num(pet.petY)
      facingLeft = pet.facingLeft === true
      sleeping = pet.sleeping === true
      petCount = Math.max(0, Math.round(num(pet.petCount)))
      lastInteractionMs = num(pet.lastInteractionMs)
    } catch (error) {
      petX = -1; petY = -1
      console.warn("omate: state file unreadable (" + error + "), starting fresh")
    }

    initialized = true

    // The pack readers started before settings existed (and thus read the
    // default pack); if the saved pack differs, read again with the real name.
    var savedPack = typeof settings.pack === "string" && settings.pack !== ""
      ? settings.pack : defaultPack
    if (savedPack !== packName) reloadPack()

    applyPackIfReady()

    // A hello from the new shift, once the surface has settled.
    greetTimer.restart()
  }

  // Adopt a pack's suggested scale once, right after a setPack switch.
  function maybeApplyDefaultScale() {
    if (!pendingDefaultScale) return
    pendingDefaultScale = false
    var s = Number(pack.defaultScale)
    if (s >= 1 && s <= 6) updateSettings({ scale: Math.round(s) })
  }

  // Switch character pack — the settings panel and the IPC share this path.
  function selectPack(name) {
    if (typeof name !== "string" || name === "") return
    pendingDefaultScale = true
    updateSettings({ pack: name })
    reloadPack()
  }

  // Persist a home-screen choice and drop any runtime hop — panel + IPC.
  function applyScreenChoice(screen) {
    if (typeof screen !== "string") return
    if (mateWindow) mateWindow.screenTarget = null
    updateSettings({ screen: screen })
  }

  // Re-read the selected pack's files (also the entry point after setPack).
  // The four readers are single Process objects, so a pack switch while a
  // read is still in flight must NOT relaunch over it — the old run would
  // exit later and apply the old pack's text under the new pack's name.
  // tryLoadPack defers the launch until every reader is idle.
  function reloadPack() {
    packName = typeof settings.pack === "string" && settings.pack !== ""
      ? settings.pack : defaultPack
    tryLoadPack()
  }

  function tryLoadPack() {
    if (userPackReader.running || repoPackReader.running
        || userMessagesReader.running || repoMessagesReader.running) {
      packLoadRetry.restart()
      return
    }
    var repoPackJson = pluginFile(repoPacksRoot + packName + "/pack.json")
    userPackReader.command = ["head", "-c", String(maxStateBytes),
                              userPacksDir + "/" + packName + "/pack.json"]
    repoPackReader.command = ["head", "-c", String(maxStateBytes), repoPackJson]
    userMessagesReader.command = ["head", "-c", String(maxStateBytes),
                                  userPacksDir + "/" + packName + "/messages.json"]
    repoMessagesReader.command = ["head", "-c", String(maxStateBytes),
                                  pluginFile(repoPacksRoot + packName + "/messages.json")]
    packReadsPending = 4
    userPackReader.running = true
    repoPackReader.running = true
    userMessagesReader.running = true
    repoMessagesReader.running = true
  }

  Timer {
    id: packLoadRetry
    interval: 200
    onTriggered: root.tryLoadPack()
  }

  // True when a reader's command still targets the currently selected pack.
  // A straggler from an earlier launch (pack switched while it read) must
  // apply nothing: its texts are for a pack that is no longer selected, and
  // its landing would otherwise complete the current launch's read count.
  function readerIsCurrent(reader) {
    var path = reader.command[reader.command.length - 1]
    return typeof path === "string" && path.indexOf("/" + packName + "/") !== -1
  }

  // Called by every pack/messages reader as it lands; applies whichever
  // copies exist — but only once the whole launch is in (see
  // packReadsPending). During startup this feeds initializeIfReady instead.
  function applyPackIfReady() {
    if (!initialized || packReadsPending > 0) return
    if (effectivePackText !== "") {
      try {
        var parsedPack = JSON.parse(effectivePackText)
        if (parsedPack && (Number(parsedPack.spriteSize) > 0
                           || Number(parsedPack.width) > 0))
          pack = parsedPack
      } catch (error) {
        console.warn("omate: pack '" + packName + "' unreadable, keeping current")
      }
    }
    if (effectiveMessagesText !== "") {
      try {
        var parsedMessages = JSON.parse(effectiveMessagesText)
        if (parsedMessages) messages = parsedMessages
      } catch (error) {
        console.warn("omate: messages for '" + packName + "' unreadable, keeping current")
      }
    }
    // A user pack shadows a repo pack of the same name. Until some pack
    // file actually arrives, keep the previous dir (startup default).
    if (effectivePackText !== "") {
      spriteDir = loadedUserPackText !== ""
        ? "file://" + userPacksDir + "/" + packName + "/sprites/"
        : repoPacksRoot + packName + "/sprites/"
    }
    // The atomic hand-off: views swap frames and directory in one step.
    skin = { dir: spriteDir, anims: pack.anims }
    maybeApplyDefaultScale()
  }

  Timer {
    id: greetTimer
    interval: 5000
    onTriggered: root.sayFrom("greet")
  }

  // --- bounded reads -------------------------------------------------------------

  function boundedText(collector, exitCode) {
    if (exitCode !== 0) return ""
    var text = collector.text
    return text.length >= maxStateBytes ? "" : text
  }

  Process {
    id: settingsReader
    command: ["head", "-c", String(root.maxStateBytes), root.settingsPath]
    running: true
    stdout: StdioCollector { id: settingsOut }
    onExited: function(exitCode) {
      root.loadedSettingsText = root.boundedText(settingsOut, exitCode)
      root.settingsFileLoaded = true
      root.initializeIfReady()
    }
  }

  Process {
    id: petReader
    command: ["head", "-c", String(root.maxStateBytes), root.petPath]
    running: true
    stdout: StdioCollector { id: petOut }
    onExited: function(exitCode) {
      root.loadedPetText = root.boundedText(petOut, exitCode)
      root.petFileLoaded = true
      root.initializeIfReady()
    }
  }

  Process {
    id: userPackReader
    stdout: StdioCollector { id: userPackOut }
    onExited: function(exitCode) {
      if (!root.readerIsCurrent(userPackReader)) return
      root.loadedUserPackText = root.boundedText(userPackOut, exitCode)
      root.packReadsPending = Math.max(0, root.packReadsPending - 1)
      root.applyPackIfReady()
      root.initializeIfReady()
    }
  }

  Process {
    id: repoPackReader
    stdout: StdioCollector { id: repoPackOut }
    onExited: function(exitCode) {
      if (!root.readerIsCurrent(repoPackReader)) return
      root.loadedRepoPackText = root.boundedText(repoPackOut, exitCode)
      root.packReadsPending = Math.max(0, root.packReadsPending - 1)
      root.applyPackIfReady()
      root.initializeIfReady()
    }
  }

  Process {
    id: userMessagesReader
    stdout: StdioCollector { id: userMessagesOut }
    onExited: function(exitCode) {
      if (!root.readerIsCurrent(userMessagesReader)) return
      root.loadedUserMessagesText = root.boundedText(userMessagesOut, exitCode)
      root.packReadsPending = Math.max(0, root.packReadsPending - 1)
      root.applyPackIfReady()
      root.initializeIfReady()
    }
  }

  Process {
    id: repoMessagesReader
    stdout: StdioCollector { id: repoMessagesOut }
    onExited: function(exitCode) {
      if (!root.readerIsCurrent(repoMessagesReader)) return
      root.loadedRepoMessagesText = root.boundedText(repoMessagesOut, exitCode)
      root.packReadsPending = Math.max(0, root.packReadsPending - 1)
      root.applyPackIfReady()
      root.initializeIfReady()
    }
  }

  Component.onCompleted: reloadPack()

  // Write-only views: preload off, text() is never called, so the shell
  // never maps these files itself.
  FileView {
    id: settingsFile
    path: root.settingsPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: petFile
    path: root.petPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // --- IPC -----------------------------------------------------------------------

  // Drive the mate from anywhere:
  //   omarchy-shell omate say "Time to stretch!"
  IpcHandler {
    target: "omate"

    function say(text: string): void { root.say(text) }
    function pet(): void { root.petThePet() }
    function poke(): void { root.pokeThePet() }
    function wake(): void { root.wake(true) }
    function doze(): void { root.doze() }
    function toggleRoam(): void { root.setRoaming(!root.roaming) }
    function setRoam(enabled: bool): void { root.setRoaming(enabled) }
    function show(): void { root.setMateVisible(true) }
    function hide(): void { root.setMateVisible(false) }
    function toggleVisible(): void { root.toggleMateVisible() }
    function setVolume(volume: real): void { root.setSoundVolume(volume) }
    function setScale(scale: int): void {
      root.updateSettings({ scale: Math.max(1, Math.min(6, scale)) })
    }
    // Move the mate to another output, as Hyprland names it; empty = largest.
    // Changes the home screen persistently and clears any runtime hop.
    function setScreen(screen: string): void { root.applyScreenChoice(screen) }
    // Immediate one-off trip: drop in from the top of the named output.
    function gotoScreen(screen: string): bool {
      return mateWindow ? mateWindow.gotoScreen(screen) : false
    }
    // Character packs: switch, or list what's installed.
    function setPack(pack: string): void { root.selectPack(pack) }
    function packs(): string { return root.knownPacks }
    // Teleport onto a random floating window (or leap if there is none).
    function hop(): void { mateWindow.hopToWindow() }
    function corner(): void { mateWindow.startCornerTrip() }
    function setCursorChase(enabled: bool): void { root.setCursorChase(enabled) }
    function toggleCursorChase(): void { root.setCursorChase(!root.cursorChase) }
    // Seconds between chases, 5-3600.
    function setChaseCooldown(seconds: int): void { root.setChaseCooldown(seconds) }
    function status(): string {
      return (root.sleeping ? "sleeping" : "awake")
        + " pack=" + root.packName
        + " pets=" + root.petCount
        + " vol=" + root.soundVolume.toFixed(2)
        + " scale=" + root.petScale
        + " windows=" + (mateWindow ? mateWindow.platforms.length : -1)
        + " floor=" + (mateWindow ? Math.round(mateWindow.floorY) : -1)
        + " chase=" + (root.cursorChase ? "on/" + root.chaseCooldownSec + "s" : "off")
    }
  }

  // --- pack directory --------------------------------------------------------------

  // Every installed pack, parsed for the settings panel's skin picker:
  // [{ name, title, dir, pack }] — `dir` a sprite URL prefix, `pack` the
  // parsed pack.json (null if unreadable). The user dir is scanned first, so
  // it shadows repo packs of the same name.
  property var packList: []
  property string knownPacks: defaultPack

  Process {
    id: packLister
    // One bounded read per pack: a marker line with the directory, then the
    // pack.json body. Globs keep missing directories harmless ([ -f ] skips
    // them), and 20 KB covers any sane pack.json.
    command: ["sh", "-c",
      'for d in "$1"/*/ "$2"/*/; do [ -f "$d/pack.json" ] || continue; echo "@@$d"; head -c 20000 "$d/pack.json"; echo; done',
      "sh", root.userPacksDir, root.pluginFile(root.repoPacksRoot)]
    stdout: StdioCollector { id: packListOut }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var records = []
      var current = null
      var lines = packListOut.text.split("\n")
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].indexOf("@@") === 0) {
          current = { path: lines[i].substring(2), json: "" }
          records.push(current)
        } else if (current !== null && lines[i] !== "") {
          current.json += (current.json === "" ? "" : "\n") + lines[i]
        }
      }
      var seen = {}
      var list = []
      var names = []
      for (var r = 0; r < records.length; r++) {
        // Globbed paths carry a trailing slash, so the pack name is the
        // second-to-last segment.
        var parts = records[r].path.split("/")
        var name = parts.length >= 2 ? parts[parts.length - 2] : ""
        if (name === "" || seen[name]) continue
        seen[name] = true
        var packData = null
        try { packData = JSON.parse(records[r].json) } catch (error) { packData = null }
        var dir
        if (records[r].path.indexOf(root.userPacksDir + "/") === 0)
          dir = "file://" + records[r].path + "sprites/"
        else
          dir = root.repoPacksRoot + name + "/sprites/"
        list.push({
          name: name,
          title: packData && typeof packData.name === "string" && packData.name !== ""
            ? packData.name : name,
          dir: dir,
          pack: packData
        })
        names.push(name)
      }
      list.sort(function(a, b) {
        if (a.name === root.defaultPack) return -1
        if (b.name === root.defaultPack) return 1
        return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
      })
      root.packList = list
      root.knownPacks = names.length > 0 ? names.join(",") : defaultPack
    }
  }
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: packLister.running = true
  }

  // --- the mate itself -------------------------------------------------------------

  // Deliberately a static window with a visibility binding, not a Loader:
  // dynamically created windows leak a zombie layer surface across the
  // shell's plugin hot-reload, which then wedges screencopy (grim) on that
  // output.
  OmateWindow {
    id: mateWindow
    petService: root
    visible: root.initialized && root.settings.visible === true
  }
}
