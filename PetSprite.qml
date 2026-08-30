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
  property string dir: "packs/default/sprites/"
  // Per-anim overrides from pack.json: { idle: { frames: [...], frameMs } }
  property var timings: ({})
  // Preferred: one object carrying both { dir, anims }.
  property var skin: null

  // Single source of truth for everything below: one object, read fresh at
  // each evaluation.
  readonly property var spec: skin ? skin : ({ dir: dir, anims: timings })
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
