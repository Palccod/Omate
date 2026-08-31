# Omate

A lightweight desktop mate for Omarchy: a little pixel cat that roams your
screen, rides along when you pick it up, purrs when you pet it, naps when
you ignore it, and drops by with messages. Pure QML on Quickshell — no AI,
no network, no dependencies beyond the shell you already run.

Inspired by [Mate-Engine](https://github.com/shinyflvre/Mate-Engine)'s
interaction model.

![Omate's settings panel: skin picker with twelve character previews over
the behavior controls, Miku window-sitting on the right](preview.png)

| Settings panel | Sitting on floating windows | Natural sizes |
|---|---|---|
| ![The settings panel: skin picker, power switch, behavior controls](settings.png) | ![Miku sitting on a floating terminal](on-window.png) | ![Miku at 1x size on the desktop floor](custom-size.png) |

Sitting works on any floating window — and she falls off when it closes.
Sizes range from the 24px cat up to 250px Totoro, settable per pack.

## Requirements

- [Omarchy](https://omarchy.org) with its Quickshell shell (the default)
- Hyprland (window tracking for window-sitting; the default)
- PipeWire's `pw-play` for sound effects (stock on Omarchy; mute in the
  panel)
- Optional, only for the character converters in `tools/`: `python3`
  (plus `pillow` for the GIF importer). The plugin itself never runs
  Python.

## Features

- **Crosses monitors**: drag her past a screen edge and the whole overlay
  follows to the neighboring output; a strong flung toss near an edge
  throws her across too. Falls, window-sitting and hopping all work on
  whichever screen she's on. If the screen she's on gets unplugged, she
  returns to the auto-picked home output.
- **Roams** the bottom edge of your screen (walks on top of the bar's
  reserved strip, never covers your work).
- **Sits on floating windows**: climbs up onto the tops of floating
  windows, rides along when you move them, and falls when the window
  closes, unfloats, or slides out from under it.
- **Drag & throw**: pick it up and toss it — real gravity, soft landings
  on window tops or the floor, and it gets dizzy if you drop it too far.
- **Pet it**: hold the mouse still on it for a moment — purrs and hearts.
  Petting a sleeping cat keeps it asleep.
- **Poke it**: a quick tap gets a mew and a startled face.
- **Sleeps** after 10 idle minutes (configurable), wakes when grabbed.
- **Corner trips**: a pack that ships a `corner` animation will occasionally
  wander to the nearest edge of whatever it is standing on, turn around and
  play that pose before carrying on. Packs without that art never do it, so
  none of the bundled characters are affected.
- **Chase the cursor** (off by default): switch it on and the mate stalks
  your mouse pointer, hauls it in when it strays close, bites it, and hands
  it straight back to where it picked it up. It can never keep the pointer —
  every pull is capped and always ends by returning it — so you win a tug of
  war just by out-lasting it. Switching it *on* lives only in the settings
  panel, next to the cadence — every ten seconds through twice an hour — so
  it cannot be armed by a stray click; the right-click menu only ever stops
  it. The chomp is played with the pack's `poke` pose, so a character that
  ships no `poke` art is never offered the chase at all — the pointer would be
  hauled in and nothing would visibly happen.
- **Speech bubbles**: idle chatter, event reactions, and any message you
  send it.
- **Sounds**: tiny synthesized blips (grab, purr, poke, thud, zzz, wake).
- **Menu**: right-click the cat for settings / window-hop / walk / nap /
  mute / hide (plus "Find a corner" for packs with `corner` art, and
  "Stop chasing" while a chase is armed).
- **Settings panel**: click the bar button (or the cat's "Settings…" menu
  entry) for a popup card styled like the plugin manager's rows — an
  animated sprite in the header, an enable/disable power switch in the top
  right, a **skin picker where every installed pack previews its own idle
  animation**, and live controls for roaming, volume, size, walkiness,
  home screen, nap/chatter cadence, and the cursor chase.
- **Eighteen characters bundled** — Pikachu, Miku, Totoro, SpongeBob,
  Spider-Man, Deadpool, Luffy, Dieter the cat, Hornet, Gojo, Rem,
  Mitsuri, a fox, an akita, a panda, a turtle, a rubber duck, and Mochi
  the cat; import your own with the built-in converters.
- **Full behavior set where the art allows it** — besides walking,
  roaming and napping, characters with the right frames sit down, lie
  down, and hit a ground-impact pose after a fall (sleep uses the lying
  pose whenever a pack ships one, and pokes get a stumble reaction);
  every shimeji import maps those animations automatically. Name an
  import's impact sprite `land_00.png` (or let the converter take the
  bounce action) and it plays on every landing.
- Click-through everywhere except the cat itself — your desktop stays
  fully usable.

## Install

One command — no build steps, no extra setup:

```bash
omarchy plugin add https://github.com/Palccod/Omate.git --enable
```

That's the whole setup: a bar button appears in the right section, the
mate walks in on your desktop, and all eighteen characters are bundled —
left click opens her settings, middle click pets the bar sprite. Future
updates bring new packs and fixes through the same update command; her
position, settings, and any characters you imported yourself live
outside the plugin folder and survive updates.

## Enable / disable

```bash
omarchy plugin enable palccod.omate     # bar widget + roaming mate return
omarchy plugin disable palccod.omate    # both disappear; files stay put
omarchy plugin list                     # see what's installed and enabled
```

The mate's own power switch in the settings panel only hides her —
disabling the plugin unloads the service itself.

## Update

```bash
omarchy plugin update palccod.omate
```

If the shell somehow keeps running old code after an update,
`omarchy restart shell`.

## Uninstall

```bash
omarchy plugin remove palccod.omate     # disables + deletes the plugin
```

Your mate's memory lives outside the plugin folder — remove these too if
you want a clean break:

```bash
rm -rf ~/.local/state/omarchy/omate-packs/   # characters you imported
rm ~/.local/state/omarchy/omate-settings.json
rm ~/.local/state/omarchy/omate-state.json
```

## Characters

Everything works out of the box: the eighteen bundled characters need no
setup at all. This section is only for adding an **nineteenth** of your
own — the converters take three formats, all offline.

**MikuPet-style** (a directory with `character.json` + sprite strips):

```sh
python3 tools/import-spritesheet.py ~/Downloads/miku-char \
  ~/.local/state/omarchy/omate-packs/mine "My Character"
```

**Shimeji** (`img/shime*.png` + `conf/` — the classic desktop-shimeji
zips; both the English shimeji-ee and the original Japanese conf formats
work, and sit/lie/jump animations are mapped automatically):

```sh
unzip ~/Downloads/some-shimeji.zip -d /tmp/pet
python3 tools/import-shimeji.py /tmp/pet \
  ~/.local/state/omarchy/omate-packs/pet "Pet Name"
```

**Animated-GIF pets** (one `<anim>.gif` per animation, like the
[vscode-pets](https://github.com/tonybaloney/vscode-pets) media files;
needs Pillow):

```sh
python3 tools/import-gifpet.py ~/Downloads/pet-gifs \
  ~/.local/state/omarchy/omate-packs/pet2 "Pet Name" --flip
```

Imported packs live in `~/.local/state/omarchy/omate-packs/<name>/` (so
your characters survive plugin updates) and shadow bundled packs of the
same name. Each carries its own `messages.json` and `pack.json`. Good
hunting grounds: [shimeji.org](https://shimeji.org/), the
[DeviantArt shimeji tag](https://www.deviantart.com/tag/shimeji), and
[MikuPet releases](https://github.com/CharlesWiiFlowers/MikuPet).

Characters are fan art of copyrighted characters: fine for personal
offline use, don't redistribute. Every pack keeps its author credit in
its own `pack.json`; the eighteen bundled ones are inventoried in
[THIRD_PARTY.md](THIRD_PARTY.md).

## Command line (IPC)

```sh
omarchy-shell omate say "Time to stretch!"
omarchy-shell omate pet
omarchy-shell omate poke
omarchy-shell omate wake          # or: doze
omarchy-shell omate setRoam false # or: toggleRoam
omarchy-shell omate hide          # or: show, toggleVisible
omarchy-shell omate setVolume 0.3
omarchy-shell omate setScale 4    # 1-6
omarchy-shell omate setScreen DP-1  # home output; "" = largest
omarchy-shell omate gotoScreen DP-1 # one-off trip: drop in from the top
omarchy-shell omate setPack miku   # or: setPack default
omarchy-shell omate packs          # list installed character packs
omarchy-shell omate corner         # wander to the nearest corner (packs
                                   # with "corner" art only)
omarchy-shell omate setCursorChase true   # chase the mouse pointer
omarchy-shell omate toggleCursorChase
omarchy-shell omate setChaseCooldown 300  # seconds between chases, 5-3600
omarchy-shell omate hop            # teleport onto a random floating window
                                   # (or leap for joy if none are around)
omarchy-shell omate status
omarchy-shell palccod.omate toggle # open/close the settings panel
```

## Customize

Everything lives in plain files; edit and run `omarchy restart shell`.

- **Messages** — `packs/default/messages.json`: pools of lines the cat
  picks from (`greet`, `idle`, `drag`, `pet`, `poke`, `land`, `dizzy`,
  `sleep`, `wake`, `corner`, `chase`, `bite`).
- **Settings** — `~/.local/state/omarchy/omate-settings.json`:
  `visible`, `roamEnabled`, `cursorChase` (off by default),
  `chaseCooldownSec` (5–3600, default 300), `scale` (1–6),
  `walkiness` (0–1), `screen`
  (Hyprland output name, empty = largest), `soundVolume`, `sleepMinutes`,
  `chatterMinutes`. Every one of these is editable live from the settings
  panel; the file is just where they persist.
- **Sprites** — 24×24 PNGs in `packs/default/sprites/`, generated from
  ASCII grids in `tools/gen-sprites.py` (edit the grids, rerun the
  script). Missing animations fall back to idle, so you can add frames
  gradually.
- **Sounds** — WAV files in `sounds/`, named after events
  (`grab`, `pet`, `poke`, `land`, `zzz`, `wake`). Replace freely.

## Files

```
manifest.json          Omarchy plugin manifest (service + bar-widget)
Service.qml            Brain: settings, persistence, sleep, messages, sounds, IPC
OmateWindow.qml        Roaming overlay: physics, interactions, bubble, menu
OmatePanel.qml         Settings card: skin picker with previews, power switch
BarWidget.qml          Bar button (opens the panel, middle-click pets)
PetSprite.qml          Frame-by-frame sprite animator
packs/default/         Sprites, pack.json (sizes/timings), messages.json
sounds/                Synthesized event blips
tools/                 Sprite & sound generators (pure Python stdlib)
```

State (position, nap status) persists in
`~/.local/state/omarchy/omate-state.json` and is restored on login.

## Privacy & security

- **No network access** — fully offline; nothing is ever downloaded or
  phoned home
- **No privileged behavior** — no sudo, pkexec, systemctl, or services
- **Pointer control** — only if you turn on cursor chasing, which is off by
  default. It reads the pointer position from Hyprland's IPC socket and, while
  actively hauling, moves the pointer through Hyprland's own dispatcher. Each
  pull is capped in duration, always ends by releasing the pointer clear of
  the mate, and is followed by a cooldown; nothing about it can hold the
  pointer against you. Turn it off and none of that code runs.
- **File access** — reads and writes only its own state under
  `~/.local/state/omarchy/`: `omate-settings.json`, `omate-state.json`,
  and `omate-packs/` (characters you import yourself). Writes are atomic;
  reads are size-capped
- **Process execution** — exactly two things, always with fixed argument
  arrays: `pw-play` for the bundled sound effects, and `head -c` for
  bounded reads of its own state and pack files. Nothing is executed at
  install time and nothing is downloaded
- **No data collection** — no telemetry, no clipboard access, no
  credentials

## Notes

- The mate lives on the `Top` layer-shell layer: above your windows,
  below fullscreen apps (a fullscreen app covers it — same as the bar).
- Like every Omarchy shell plugin it runs inside the main shell instance;
  restart the shell after changing files.

## Development

Contributors only — users never need this. Clone or link the repo into
`~/.config/omarchy/plugins/palccod.omate/`, then run
`omarchy plugin enable palccod.omate` (or
`omarchy-shell shell rescanPlugins`) and `omarchy restart shell` after
editing files. Lint with `qmllint -I /usr/share/omarchy/shell *.qml`,
validate with `omarchy plugin validate .`
