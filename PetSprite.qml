import QtQuick

// One animated sprite. Two pack formats are supported:
//
// - Frame lists (imported packs): timings[anim].frames is an array of file
//   names relative to `dir`, cycled in order.
// - Legacy a/b pairs: frames are named <form>_<anim>_<a|b>.png and swapped.
//
// If an animation's frames are missing, it falls back (to `fallbackAnim`,
// then to idle, which always exists) — so sprite sets can be extended or
// partially converted without ever breaking a view.
//
// Pass a `skin` object ({ dir, anims }) when the pack can change at
// runtime. The image source is computed from that ONE object in a single
// binding, so a pack swap swaps directory and frames together; going
// through the separate dir/timings properties lets a frame paint with one
// pack's frames under another pack's directory.
Item {
  id: root

  property string form: "cat"
  property string anim: "idle"
  // What to try when `anim`'s frames are missing (e.g. "idle" for a pose a
  // custom pack doesn't ship).
  property string fallbackAnim: "idle"
  // URL prefix ending in "/" for the sprite directory. Relative paths
  // resolve against this file; absolute file:// paths work for user packs.
  property string dir: "packs/totoro/sprites/"
  // Per-anim overrides from pack.json: { idle: { frames: [...], frameMs } }
  property var timings: ({
    idle: {
      frames: [
        "idle_00.png", "idle_01.png", "idle_02.png", "idle_03.png",
        "idle_04.png", "idle_05.png", "idle_06.png", "idle_07.png",
        "idle_08.png", "idle_09.png", "idle_10.png", "idle_11.png",
        "idle_12.png", "idle_13.png", "idle_14.png", "idle_15.png",
        "idle_16.png", "idle_17.png", "idle_18.png", "idle_19.png",
        "idle_20.png", "idle_21.png", "idle_22.png", "idle_23.png",
        "idle_24.png", "idle_25.png", "idle_26.png", "idle_27.png",
        "idle_28.png", "idle_29.png", "idle_30.png", "idle_31.png",
        "idle_32.png", "idle_33.png", "idle_34.png", "idle_35.png",
        "idle_36.png", "idle_37.png", "idle_38.png", "idle_39.png",
        "idle_40.png", "idle_41.png", "idle_42.png", "idle_43.png",
        "idle_44.png", "idle_45.png", "idle_46.png", "idle_47.png",
        "idle_48.png", "idle_49.png", "idle_50.png", "idle_51.png",
        "idle_52.png", "idle_53.png", "idle_54.png", "idle_55.png"
      ],
      frameMs: 100
    },
    walk: { frames: ["walk_00.png", "walk_01.png"], frameMs: 400 },
    sleep: { frames: ["sleep_00.png", "sleep_01.png", "sleep_02.png", "sleep_03.png"], frameMs: 250 },
    fall: { frames: ["fall_00.png"], frameMs: 400 },
    climb: { frames: ["climb_00.png", "climb_01.png", "climb_02.png", "climb_03.png", "climb_04.png", "climb_05.png", "climb_06.png"], frameMs: 350 }
  })
  // Preferred: one object carrying both { dir, anims }.
  property var skin: null

  // Single source of truth for everything below: one object, read fresh at
  // each evaluation. If skin is provided but anims is null/empty, fall back
  // to the component's default timings (legacy a/b pairs) so the sprite never
  // breaks while the service loads the real pack.json asynchronously.
  readonly property var spec: skin
    ? ({ dir: skin.dir, anims: (skin.anims && Object.keys(skin.anims).length > 0) ? skin.anims : timings })
    : ({ dir: dir, anims: timings })
  property int frameMs: 500
  property bool playing: true
  property bool mirrored: false

  property int frame: 0
  // The animation actually shown once fallbacks are applied.
  property string resolvedAnim: anim

  function framesFor(t, animName) {
    var a = t ? t[animName] : null
    return a && a.frames && a.frames.length > 0 ? a.frames : []
  }

  // Mirror of what the image is cycling (frame-list mode only); feeds the
  // frame timer. The image binding computes its own list so the two can
  // never disagree.
  readonly property var frameList: framesFor(spec.anims, resolvedAnim)

  function restart() {
    resolvedAnim = anim
    frame = 0
  }

  function applyFallback() {
    if (image.status !== Image.Error) return
    if (resolvedAnim !== fallbackAnim) resolvedAnim = fallbackAnim
    else if (resolvedAnim !== "idle") resolvedAnim = "idle"
  }

  onAnimChanged: restart()
  onFrameListChanged: frame = 0

  Image {
    id: image
    anchors.fill: parent
    source: {
      var list = root.framesFor(root.spec.anims, root.resolvedAnim)
      var d = root.spec.dir
      return list.length > 0
        ? d + list[Math.min(root.frame, list.length - 1)]
        : d + root.form + "_" + root.resolvedAnim + "_"
          + (root.frame % 2 === 0 ? "a" : "b") + ".png"
    }
    // Nearest-neighbour scaling keeps the pixels crisp.
    smooth: false
    mipmap: false
    fillMode: Image.PreserveAspectFit
    mirror: root.mirrored

    // Deferred: writing resolvedAnim during the source evaluation that
    // triggered the status change would be a binding loop.
    onStatusChanged: if (status === Image.Error) Qt.callLater(root.applyFallback)
  }

  Timer {
    id: frameTimer
    interval: {
      var override = root.spec.anims ? root.spec.anims[root.resolvedAnim] : null
      return override && override.frameMs ? override.frameMs : root.frameMs
    }
    running: root.playing && root.visible && root.frameList.length !== 1
    repeat: true
    onTriggered: {
      var n = root.frameList.length > 0 ? root.frameList.length : 2
      root.frame = (root.frame + 1) % n
    }
  }
}
