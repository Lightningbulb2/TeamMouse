### Notice: Claude AI was used with this project.

# TeamMouse

Built on top of the SharedMouse mod by Eternal- that was cleaned up by KasperAUS

### Upgrades over shared mouse:

• show Teammate building placements

• show Teammate dragbox selection and current unit selection

• show Teammate orders

• show when Teammate is hovering HUD

• Teammate cursor zoom indicator

• better zoom scaling and opacity so things are visible, but not in the way

• take extra samples between ticks for smoother movement

• full replay support that allows you to see everyone's actions

• (optional) toggle specific player's cursors

• (optional) show camera perspective of your teammates

• (optional) follow player perspective and selections --- (for observer and replays)

• show drawings earlier before it's applied to the simulation

• backwards compatible with SharedMouse

## Development

Set the location of your local [fa-lua-addon](https://github.com/speed2CZ/fa-lua-addon) in your vscode settings to something like
`  "Lua.runtime.plugin": "YOUR/PATH/TO/fa-lua-addon/plugin.lua",`

Junction the source folder into the mods directory so edits are live:

```
Windows:

mklink /J "C:\ProgramData\FAForever\user\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\TeamMouse" "PATH/TO/YOUR/REPO/TeamMouse"
```

Many mod flags in `config.lua`

Note that FA runs Lua 5.0.1. Subtly: `table.insert`, `table.remove`
and `table.getn` maintain a hidden `n` field in 5.0 that plain `nil`-assignment
does not update — clearing entries that way desyncs the count from the real
data.

Also, from the notes: never `LOG` a raw engine object. It hangs the game.

## Layout

```
mod_info.lua                        mod manifest
hook/lua/ui/game/gamemain.lua       entry points: init, beat, layout, teardown
hook/lua/ui/game/unitview.lua       commander cache, only used by the replay codec
modules/config.lua                  every tunable and feature flag
modules/cursordata.lua              cursor name <-> wire index <-> texture, colours
modules/remotecursor.lua            the visual for one player in one view
modules/hudghost.lua                the stylised panel shown when someone is in their UI
modules/replaycodec.lua             zero-width encoding for replay playback
modules/teammouse.lua             session setup, send, receive, view sync
extras/mock_fa.lua                  mock game environment for tests (Lua 5.0 table semantics)
extras/test_integration.lua         111+ tests over the whole pipeline, including regressions
extras/test_replaycodec.lua         17 tests over the codec
extras/test_visibility.lua          cursor pieces when a teammate enters or re-enters your view
extras/test_fuzz.lua                randomised stress test; never raise, never log an error
```

Data flow:

```
OnBeat (10/s)  ->  read local state  ->  SessionSendChatMessage to allies
OnReceive      ->  push a timestamped sample into that player's buffer
OnFrame (60/s) ->  interpolate every buffer, then place every visual
```

There is exactly one frame callback for the whole mod. It reads each view's
bounds, camera zoom and the local mouse position once, then hands that to every
cursor. That's deliberate — the previous version's per-cursor `OnFrame` with
per-frame `LayoutHelpers.AtLeftTopIn` calls was the source of the slowdown.

### Replay encoding

```lua
ReplayCodec = {
    Enabled  = true,
    Alphabet = { ... },   -- the invisible characters the position is written in
    ...
}
```

Chat messages are not recorded into replays, but a unit's custom name is. So
the pointer's position is appended to your commander's name in characters the
game draws nothing for: the name still reads as yours. Every write re-reads the
name, so renaming your commander mid-game is kept. Drags (box, line, drawing)
and time on the interface are recorded too. In a replay, cursors are drawn
more opaque and larger (`CursorAlpha`, `CursorScale`), and every player's is
shown, including your own when watching your own game.

### HUD ghost

While a teammate's pointer is on their interface, their cursor is shown over a
small picture of the interface (`UICutout.png`), slid so that the spot they are
pointing at is at its centre. It fades in and out (`Hud.FadeSpeed`) and jumps
rather than slides across the screen (`Hud.JumpDistance`).

### Extra samples

```lua
Network.ExtraSamples = { Enabled = true, Interval = 0.033, MaxPerPacket = 8, MaxAge = 0.5 }
```

The packet rate stays at the beat rate. Between beats the pointer is also
sampled about every 33ms, and those samples ride along in the next packet, each
tagged with how long before the packet it was taken. The receiver places them
on its own timeline, so a cursor follows the real path of the pointer instead of
a straight line between two points 100ms apart. It costs bandwidth (nine
numbers per sample), not packets.

It only works because remote cursors are drawn `Smoothing.InterpolationDelay`
in the past: an extra sample is older than the packet carrying it, and would be
stale on arrival if the receiver drew the newest data. Keep the delay at or
above one beat (0.1s).

### Structure lines and right-click orders

While a teammate drags in build mode, you see a dotted line from where the drag
started to the cursor (`Line`). When they right-click with units selected you
see a marker fade out at the destination in their colour, with the order's
cursor beside it, plus a line for a right-drag formation (`Orders`).

### Right-click drawing

A right-drag is shown while it is being drawn, and stays up after the release
until the order has reached the sim.

### State is drawn from the moment being drawn

Positions are drawn `Smoothing.InterpolationDelay` in the past. So is everything
that decides how to draw them (on the interface, dragging a box / line / order):
it rides on each sample and is read at render time.

### Drag overlay

The invisible grid that tracks your pointer during a native drag is lifted off
the screen while the right mouse button is down (it used to cancel right-drag
formations) and is rebuilt whenever its view is resized. Set
`Selection.DebugGrid = true` to tint it and check its coverage.

### Player panel

A panel on the left edge lists every player whose cursor you can see. Untick a
player to hide everything of theirs -- cursor, orders, lines, trails -- and
tick them again to bring it back. It folds away to its tab with the arrow, and hides in
screen capture mode. Position and starting state are under `Panel`.

### Versions in chat

At the start of a game TeamMouse says in your chat which version you and each
teammate are on, and after a few seconds who doesn't have it or is only on the
old SharedMouse (`VersionReport`). Only you see these lines.

### Actions

When a teammate stops units, toggles repeat build, pauses or resumes units,
or copies or distributes orders, a short label (STOP, REPEAT ON, PAUSED,
COPY, DISTRIBUTE ORDERS, ...) shows above their cursor and
fades (`Actions`). Orders given by left-clicking in an order mode -- patrol,
attack-move, reclaim -- show on the ground like right-click orders. A teammate
dragging one of their orders to a new spot carries its icon in their hand,
with a line back to where it was (`Orders.ShowGrabs`).

### Bandwidth

While your pointer moves, each teammate receives about 430 B/s from you
(about 30 B/s while it's still; ~660 B/s panning the camera), estimated with
extras/bandwidth_report.lua. Each packet travels as one short string
(modules/wirecodec.lua) that decodes to exactly the packet it was, about a
third of its size as a table; teammates on an older TeamMouse are sent the
table instead. Fields with nothing to say are left out, and the old
SharedMouse packet only goes to teammates who use it. With replays on, the
copy that goes through the sim (to every player) is the same short string.

## Tests

Run every suite on Lua 5.0 (the game's version) as well as 5.1; see
extras/references/testing-workflow.md.

```
lua5.1 extras/test_integration.lua
lua5.1 extras/test_replaycodec.lua
lua5.1 extras/test_visibility.lua
lua5.1 extras/test_fuzz.lua [seed] [iterations]
```

They run outside the game against `extras/mock_fa.lua`. Worth running after any
change to the send/receive path — the bugs that stopped v4 working, and the
crash reported against v5, are all covered, and re-introducing any of them
fails the suite.

`mock_fa.lua` emulates Lua 5.0's table semantics faithfully (`table.insert` /
`table.remove` / `table.getn` maintaining a hidden `n` field the way 5.0 does),
because the v5 crash was exactly a place where 5.1 and 5.0 disagree: 5.1's `#`
operator hides a class of bug that 5.0's hidden-field bookkeeping does not.
**Never test this mod's table-handling logic under stock Lua 5.1 assumptions**
— if a data structure is cleared or shuffled by assigning `nil` to entries
rather than through `table.remove`, it will pass under 5.1 and crash under
5.0. The fuzz harness throws malformed packets, view swaps, layout churn, zoom
extremes and unbalanced mouse events at the mod across many random seeds and
asserts only that it never raises and never logs an error — run it with a new
seed after any change that touches shared per-player state.

`mock_fa.lua` also cascades `Show()` into children the way the engine does, so
a child you hid individually comes back when its parent is shown. Judge what
would actually be drawn with `Mock.IsVisible`, not `IsHidden()`, which is only
one control's own flag. `test_visibility.lua` covers the cursor pieces that
used to reappear this way.
