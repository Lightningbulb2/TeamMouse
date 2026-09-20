# TeamMouse

Shows your teammates what you're doing: mouse position, order cursor, the
building you have on your cursor, and your drag-selections.

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
    Enabled = false,   -- master switch, off by default
    Write   = true,    -- write coordinates into the commander name during play
    Read    = true,    -- read them back during replay playback
    ...
}
```

`Enabled = false` means the codec is compiled but never called — no sim
traffic, no renaming, nothing. Set it to `true` on every client that should
record. `Write` and `Read` let you split the two halves, so you can record
without paying the playback polling cost or vice versa.

Read the comment block above it before turning it on; the costs and the
partial-coverage limitation are documented there.

### HUD detail

```lua
Hud = {
    Enabled = true,
    Detail  = 'simple',   -- or 'full'
    ...
}
```

`'simple'` draws the screen outline, the resource strip, the bottom command
band, the minimap block and the cursor dot — six bitmaps, reads clearly at a
glance. `'full'` adds the build grid, the order button row, the score panel
and the side rail, about eighteen bitmaps per teammate per view.

It's a silhouette, not a capture. We can't see another client's framebuffer.
The point is only to make it unambiguous that someone has stepped off the map
into their interface, rather than leaving their cursor frozen on a spot they
aren't actually looking at.

## Tests

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
