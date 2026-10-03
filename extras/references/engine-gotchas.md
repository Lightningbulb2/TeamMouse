# Forged Alliance Engine Gotchas

Everything below was learned the hard way, over many rounds of shipping something
reasonable-looking that failed in a specific way, diagnosing it, and confirming the
real fix. Where a fact was directly confirmed (by the user testing in the live
game, or by a real Lua 5.0 interpreter run against this project) it's stated
plainly. Where it's still a working hypothesis, that's said explicitly. Don't
upgrade a hypothesis to a fact without re-confirming it.

## Lua 5.0 / LuaPlus quirks

### The 32-upvalue limit is real and is a load-time failure

Forged Alliance runs Lua 5.0, which allows a function **at most 32 upvalues** --
every module-level local that the function, or anything nested inside it, refers
to. Exceeding it throws `too many upvalues (limit=32)` at **load time**, which
takes the _whole file_ down, and every hook/global function it was supposed to
provide (`InitTeamMouse`, `SyncViews`, etc.) then fails as "nonexistent global
variable" wherever something else tries to call it.

`modules/teammouse.lua`'s `OnBeat` is the closure most at risk -- it's the send
loop, and it tends to accumulate a reference to nearly everything. When adding
state that a function inside `OnBeat` needs, prefer bundling related fields into
one table (`sendState`, `worldHold`, `pointerMap`, `dragOverlays`, etc. already
exist for exactly this reason) over adding a new bare module-level local, since a
table counts as one upvalue no matter how many fields it has.

**Lua 5.1, which is what the test suite runs on, allows 60.** This means the mock
suite can pass cleanly on a version of the file that will not load in the actual
game. `extras/check_upvalues.py` gives an estimate (it matched the real compiler
exactly the one time this bit us, at 33), but the authoritative check is loading
the file with a real Lua 5.0 interpreter -- see testing-workflow.md.

### Hand-rolled ring buffers: never mix table.insert/remove/getn with direct indexing

`table.insert`, `table.remove`, and `table.getn` maintain a hidden `n` field on
the table in this Lua version. `PushSample`'s ring buffer manages its `samples`
array with an **explicit count and direct indexing only**, on purpose -- an
earlier version that cleared old entries with `samples[i] = nil` left the hidden
`n` pointing past the real data, and `table.getn` then reported a count larger
than the array. The resulting crash surfaced two different ways depending on
where it happened: `Attempt to set attribute 't' on nil` from `table.remove`
itself, and a completely unrelated-looking `arithmetic on field 't' is a nil
value` deep inside `Interpolate`, because LuaPlus returns nil rather than raising
when you read an attribute off nil, so the hole propagates silently until
something finally does arithmetic on it. If you ever touch this buffer, keep the
explicit-count-and-direct-indexing discipline; don't reach for the standard
table library functions on it.

### `import()` and circular dependency

`import(path)` runs the target file's top-level chunk immediately -- it is not a
lazy, cache-only reference. If file A is still mid-load (its own top-level chunk
hasn't finished executing) and it imports file B, and B's own import chain
reaches back to A at any depth while A is still "in progress," the loader throws
`circular dependency` and refuses to continue (rather than deadlocking).

`/lua/ui/controls.lua` (`Get()`) is a real, engine-provided **shared, global**
control registry -- multiple core UI files (`score.lua`, `construction.lua`, and
presumably others) hold a bare global `controls = import(...).Get()` and stash
their own screens' controls into different top-level keys on that one persistent
table (evidenced by patterns like `controls.tabs = controls.tabs or {}`). It is
heavily imported, which makes it a risky thing to import from a file that is
itself already mid-load and already imports something equally central --
`teammouse.lua` imports `gamemain.lua` at its own top level, and adding a fresh
top-level `import('/lua/ui/controls.lua')` on top of that produced exactly this
error. If you don't specifically need the shared registry (you rarely do -- most
of the time you just want somewhere of your own to stash control references),
use a private `local controls = {}` instead. It adds zero new import edges and
therefore cannot create a cycle, and there's no risk of a key colliding with
some other file's use of the same shared table.

### Hook files: what actually gets loaded

A mod's `hook/lua/path/to/file.lua` is not a separate module the engine calls
into -- its contents are **concatenated onto the end of** the engine's own
`lua/path/to/file.lua` before that combined file is loaded as one chunk. Code
placed in a hook file executes as literal continued top-level code of that
_engine_ file, at that engine file's own load time. This matters for reasoning
about import cycles: anything a hook file imports becomes part of the dependency
graph of the engine file it's attached to, not just part of the mod's own graph.

## LazyVar / control layout

### The circular-dependency-in-lazy-evaluation trap

A freshly constructed `Group` or `Bitmap`'s `Left`/`Right` and `Top`/`Bottom`
default to self-referential formulas (`Right` computed from `Left + Width`,
`Left` computed from `Right - Width`, and the same for `Top`/`Bottom`). This is
harmless _as long as something eventually pins one side of each pair to a real
value_ -- resolving the other side off that real value works fine. The moment
the control actually needs to be drawn (in practice: the moment it has visible
content, e.g. a real child), if **neither** side of the `Left`/`Right` pair (and
independently, neither side of `Top`/`Bottom`) has ever been pinned via
`:SetValue(x)` or `LayoutHelpers.AtLeftTopIn(...)` against an _already-resolved_
parent, resolving it walks straight back into itself with no base case, and the
engine throws `WARNING: Evaluating LazyVar failed: ... circular dependency in
lazy evaluation`.

**`Width`/`Height` are a completely separate pair from `Left`/`Top`.** Pinning
only `Width:Set(1)` / `Height:Set(1)` (a common pattern for an invisible anchor
control) does nothing to break a `Left`/`Top` cycle. An empty, childless control
can get away with never resolving its position at all, since nothing forces
resolution if there's nothing to actually draw -- this is why the frame driver's
`Group` (deliberately empty, `Width:Set(1)`/`Height:Set(1)` only) works fine with
no explicit position, while the same pattern on a group that _does_ have children
throws the moment the renderer needs to know where to draw them.

**Fix pattern:** either `LayoutHelpers.AtLeftTopIn(control, alreadyResolvedParent,
dx, dy)`, or a direct `control.Left:SetValue(x)` / `control.Top:SetValue(y)` with
a real number, on both controls in the parent/child relationship as needed. Doing
this for a permanent anchor control every frame (as `RemoteCursor` does via
`self.Left:SetValue(absX)`) is a valid, equally-good alternative to
`AtLeftTopIn`.

### `DisableHitTest` is not reliably toggleable; `Hide()`/`Show()` is

`:DisableHitTest(true)` applied **once, permanently, at construction** works
fine and is used throughout this mod for purely decorative pieces that should
never intercept a click (the build-ghost frame, label text,
etc.).

**Confirmed by live testing:** calling `:DisableHitTest(false)` to re-enable a
previously-disabled control, intending to toggle it back and forth as the mouse
moves between cells of a tracking grid, works exactly once. On revisiting that
same control a second time, the engine silently stops delivering further events
to it at all -- not an error, just quiet non-delivery. The correct way to toggle
hit-test participation repeatedly on the same control is `:Hide()` /
`:Show()`, which was confirmed to work reliably across arbitrarily many
revisits. If a cell/control needs to be invisible either way (as with the
transparent tracking grid described below), `Hide()`/`Show()` costs nothing
extra over `DisableHitTest` for the visual side and actually works for the
interactive side.

### Every `Bitmap` needs a texture or a solid colour

A `Bitmap` with neither logs `GetResource: Invalid name` warnings. This is easy
to miss on a piece that's built conditionally (e.g. `HudGhost`'s background
panel, which shipped with a configured `Config.Hud.BackColor` that was simply
never applied) or that only accumulates a large count under specific conditions
that a quick manual test won't exercise (a fuzz test surfaced this one at
hundreds of instances once other, louder crashes stopped masking it -- see
testing-workflow.md). A fully transparent solid colour (`'00ffffff'`) satisfies
the requirement for anything that must exist but must never actually be visible,
such as the drag-tracking grid below.

## Hit-testing and input dispatch

This section is the product of many wrong guesses before the picture below held
up under direct, repeated testing. If new behaviour doesn't fit this account,
get a diagnostic (a targeted `LOG`, or an isolated test) before assuming a fix --
see the "Required workflow" note in SKILL.md.

### The native drag capture

When the engine's own map interaction (box-select, a drag order, etc.) is active:

- `GetMouseScreenPos()` and `GetMouseWorldPos()` **freeze** at the position they
  had when the drag/capture began, and don't update again until it ends.
- Ordinary `MouseMotion` events **stop reaching** the world view and the root
  frame entirely.
- **`MouseEnter`/`MouseExit` crossings between separate hit-testable controls
  keep firing anyway.** This is the one gap that makes tracking the pointer
  during a native drag possible at all -- everything else is built on it.
- A `Dragger` posted via `PostDragger` for that same press is cancelled
  immediately (`OnCancel` fires right after `OnPress`) -- the engine has
  already taken the capture by the time Lua's dragger tries to attach one of
  its own.
- Returning `true` from a view's own `HandleEvent` for the `ButtonPress`
  **does** prevent the engine's native drag/selection from starting at all for
  that press. This hands Lua full manual control over that press, at the cost
  of also disabling everything the engine would otherwise have done with it
  (selection, command-mode orders, ...) -- anything built this way has to
  reimplement whatever native behaviour it doesn't want to lose.

### Raw click dispatch has no implicit "mouse capture"

A raw `ButtonPress`/`ButtonRelease` is delivered to whichever hit-testable
control is spatially topmost at that exact screen pixel **at the moment the
event fires** -- not necessarily the control that received the original press.
If something else becomes topmost at that pixel between press and release (a
different control appearing, or -- as below -- a tracking grid's own cell), the
release can go to that control instead of wherever the press went.

**A `HandleEvent` returning `false` ("did not consume") does not mean the event
also falls through to whatever is spatially underneath.** Dispatch appears to
pick exactly one topmost hit-testable control and stop there; the
`originalHandleEvent(self, event)` chaining pattern used throughout this mod's
hooks is a _different_ mechanism entirely (calling a wrapped function's own
previous definition on the _same_ control), not spatial propagation to a
sibling or something visually beneath it. If code needs an event that landed on
one control to also reach something else, it has to forward it explicitly --
e.g. `otherControl:HandleEvent(event)` -- there is no free fallthrough.

**A hit-testable control genuinely blocks clicks meant for whatever's beneath
it.** This is confirmed in both directions: a full-screen tracking grid that
was accidentally left hit-testable blocked ordinary map clicking entirely, and
`:DisableHitTest(true)` on that same grid's _container_ (while its individual
cells stayed hit-testable) restored ordinary clicking without affecting the
cells' own ability to track crossings -- i.e. `DisableHitTest` on a parent does
not prevent its children from being independently hit-tested.

### `IsKeyDown('LBUTTON')`

Reads the real, current hardware button state, independent of any specific
event's own `Modifiers` field. Useful as a confirmation check: a `MouseMotion`
event's `Modifiers.Left` has been observed to read `false` even while the button
is still physically held, specifically around a hit-test boundary crossing
(exactly the situation the tracking grid below creates constantly). Don't trust
`Modifiers.Left` alone to mean "button is up" in code that also does its own
hit-test grid tricks; confirm with `IsKeyDown` before acting on it.

### The pointer-tracking grid (why it looks the way it does)

The mechanism used in `teammouse.lua` to keep tracking the pointer during a
native drag: one permanent grid of invisible `Bitmap` cells per world view,
covering the whole view, each reporting `MouseEnter`/`MouseMotion` (which, per
above, keeps firing during a native drag even though ordinary motion to the view
itself doesn't). Getting this right took several wrong turns worth knowing about
so they aren't repeated:

- **A grid that's hit-testable everywhere blocks every click landing on it.**
  The fix is not "leave a static hole where the press happened" (that only
  protects one fixed pixel) -- it's making exactly one cell, wherever the
  pointer currently rests, the one with hit-testing/visibility off at any given
  moment, so the hole tracks the cursor everywhere on the map, not just near
  wherever a drag started.
- **Toggling that per-cell, per-crossing, via `DisableHitTest`, breaks on
  revisit** (see above) -- use `Hide()`/`Show()`.
- **The grid is only up during a drag (current design).** Up permanently,
  every cell but the hole is hit-testable, so an ordinary swing across the
  map crosses a cell every 45px: each crossing is a cell event, a hit-test
  toggle, and a copy bubbled to the root frame, and the view only hears the
  pointer between crossings. Reported as the pointer stuttering, with the
  frame/TPS counter dropping, while swinging the mouse. The grid is now
  built hidden; `SyncOverlays` raises it for a left press (or a right press
  it tracks, a drawing) and lowers it once the press is over (see below). `Selection.DebugGrid` also costs frame time: it makes every cell a
  drawn bitmap. Keep it off outside coverage checks.
- **Raised AT the press, lowered AT the release.** Two things learned the
  hard way:
  - Raising it later -- once a press looked like a drag (a few pixels of
    movement, or held past a click's length) -- broke drag tracking entirely
    (reported: "dragging is not tracked anymore"). Most likely, once the game
    has taken a drag over it holds the pointer, and a grid shown under it then
    never hears it cross a cell. **Do not raise it mid-drag.** The mock cannot
    model this (it delivers cell events regardless), so no test can catch it.
  - Lowering it on the frame after the release left the first click's grid up
    when the second click of a double-click came (reported: double-clicking
    air units sometimes did nothing). When the release reaches the view itself,
    `LowerGridNow` takes the grid down right there. A release that comes in
    through a cell (`DragCellEvent` sets `overlay.forwarding` around handing it
    on) still leaves it to the frame: the grid is not changed from inside its
    own child's handler.
  **Needs confirming in game:** that double-clicks now work every time.
- **A raw click on a unit causing noticeable lag, worsening to a near-halt
  under rapid repeated clicks, was eventually traced to `WARNING: Evaluating
LazyVar failed` errors** (see above) firing repeatedly and generating very
  verbose, multi-traceback log output each time -- the string
  formatting/logging cost of the error report itself, not the grid mechanism,
  was the actual expense. **If a performance report correlates with clicking or
  any repeated action, check the game's log for `LazyVar failed` warnings
  first** -- they're distinctive, and they name the exact file and line of the
  control whose layout never got pinned (see the circular-dependency section
  above). Don't assume a plausible-sounding mechanism (hide/show frequency, in
  this case) without checking the log for a much simpler, unrelated
  explanation.
- **A release landing on a cell rather than the view** (which per the dispatch
  rules above will happen whenever the grid is covering that exact pixel at the
  moment of release) needs a small defensive forward --
  `cell.dragOverlayRef.view:HandleEvent(event)` -- so the view's own release
  bookkeeping still runs. Do **not** have that forwarded handling destroy the
  grid synchronously: doing so from inside a call stack that started as one of
  that same grid's own children's event handler left the grid half-destroyed
  (invisible but still occupying the hit-test tree) rather than fully gone,
  until some unrelated later event happened to clean it up. If a component
  needs tearing down in response to its own child's event, defer the actual
  `:Destroy()` to a fresh call stack (`ForkThread(function() control:Destroy()
end)`), or, better, avoid needing to destroy anything on that path at all by
  keeping the grid permanent and only hiding/showing it.

### Interpolation discontinuities across a state transition

When a peer's drag ends, the position field they broadcast jumps from "held at
the press point for the whole drag" to "a fresh live position" in one packet.
The receiving smoothing buffer (`Interpolate` in teammouse.lua) has no way to
know this is a discontinuity rather than ordinary movement, and will ease across
it over the usual interpolation delay -- visibly, this reads as the cursor
sliding from the drag's start corner to wherever it's ending up, when it should
already have been sitting there and simply stay. The fix is to force the same
"large jump, snap instead of sliding" mechanism the buffer already has
(`record.sampleCount = 0`, dropping history so the next sample becomes the sole
starting point) explicitly on the transition, regardless of actual distance --
the discontinuity is in what the position field _means_, not in how far the
pointer physically moved.

### Right mouse button and the grid (CONFIRMED for formations by report)

Right-drag formations were being cancelled while the grid was up. The working
explanation, consistent with the dispatch rules above: a right-drag is a native
capture like a left drag, and as the pointer crosses cell boundaries the
"topmost hit-testable control" changes from the view to a cell, so the press
(or the release) is delivered to a different control than the gesture began on
and the engine abandons the formation. Confirmed in practice: when a bad
release check brought the grid back under a held formation, the formation was
cancelled as soon as the pointer left the one cell it was in. The fix does not
depend on the exact cause: the grid only exists to
follow a LEFT drag, so `HandleRightButton` hides every grid group from a right
press until its release, with a backstop (`Orders.MaxPressSeconds`), a left-press
escape, and a re-opened hole under the pointer on return. If formations still
cancel, the cause is elsewhere -- add a LOG in the view's HandleEvent for
ButtonPress/ButtonRelease with `event.Modifiers` before changing anything else.

**Never show the grid while a right button may still be held.** It comes back
only on a real release event, a left press, or the backstop -- never on an
inference.

### The grid does not resize itself

It is built once out of a fixed number of cells for the view's size at that
moment. Cell positions are absolute screen coordinates, so they must include the
view's own Left/Top (the original omitted this, which only worked for a view at
the screen origin). `RefreshOverlayGeometry` compares a footprint string
(view rect + root frame size) on the beat and rebuilds once a new value has been
seen twice in a row. It never rebuilds mid-drag or mid-right-press. A resize
that changes neither the view rect nor the frame size would go unnoticed;
`Selection.DebugGrid` tints the cells so coverage can be checked by eye.

### Anything that decides how to draw a position must come from the same moment

Positions are drawn `InterpolationDelay` behind the clock, so the packet that
says "the drag ended" arrives ahead of the moment it should be drawn. State read
from the latest packet (`record.selecting`, `record.onHud`) therefore disagrees
with the drawn position for that long at every transition: the arrow fell back
to a drag's anchor while the position was still sliding away from it, and the
HUD panel appeared before the pointer got there. State is stored per sample
(`slot.hud`, `slot.drag`) and read by Interpolate as a step
(`record.renderHud`, `record.renderDrag`). Orders are held the same way
(`slot.t = arrival + delay`). Do not add new draw-time state to the record from
the packet directly. `hudSnap` / `posSnap` on a sample mean "hold the earlier
sample until this one's time, then step".

### A right press needs the grid too (CONFIRMED by the frozen-cursor report)

With the grid lifted for every right press, a right-drag with nothing selected
(drawing) showed a frozen cursor to teammates: the engine freezes
`GetMouseWorldPos` and view motion for a held right button exactly as for a
left one, and nothing else was left to report. So the grid stays up for a
drawing press. It is always lifted for an order: a grid under a held
formation cancels it (see above).

### A right release is not always delivered (CONFIRMED by report)

Like a left drag's, a right drag's release is kept by the engine: the drawing
trail only stopped at the next left click, which was the only other thing that
ended a right press.

### Ending a right drag: what the engine does and doesn't tell you (CONFIRMED by Debug log)

From a real right-drag drawing, with the grid up:

- The release event never reaches Lua (the press was ended by the next left click).
- `IsKeyDown('RBUTTON')` reads **false even at the press**. 'RButton' and
  'Rbutton' also read false; 'MOUSE2' and 'RMB' error. No name tried reads the
  right button. (`IsKeyDown('LBUTTON')` does read the left one.)
- `GetMouseWorldPos` is **not** frozen during a right drag: it kept moving.
  (Unlike a left drag's box-select.)
- The view keeps receiving `MouseMotion` (87 events in 3.2 s).

So a right press ends the way a left drag does: on a motion event reaching the
view without `Modifiers.Right` (see the view hook). There is no IsKeyDown to
confirm it with, as the left drag has. CONFIRMED working in game.

### The middle button (camera pan) and the grid

Like a formation, a middle-drag pan is ended by crossing a hit-testable grid
cell. The grid is lifted from a middle press until a motion event without
`Modifiers.Middle` (a real field: FAF's recall.lua, avatars.lua read it), a
release, a left press, or the backstop.

### Beats are not a clock (CONFIRMED by report: random stutter)

`OnBeat` runs when the sim syncs, and a function added with throttle = true is
SKIPPED whenever a beat comes under 0.1s of wall time after the last one
(gamemain.OnBeat). Sim beats come every ~0.1s, so one arriving a hair early is
dropped, and the next packet leaves ~0.2s after the previous one -- longer than
teammates render behind (InterpolationDelay 0.13), so their copy stalls. A
slow sim spaces beats further. The frame driver now runs the send logic
whenever `Network.MaxSendGap` (0.11s) has passed without it.

### Knowing which order a waypoint is

`GetHighlightCommand()` (engine/User.lua) returns the command under the
cursor: `{ x, y, z, commandType, commandId, blueprintId?, targetId? }`.
commandType is taken to use the sim's numbering (FAF's UnitQueueDataToCommand,
lua/sim/commands/shared.lua: 2 Move, 10 Attack, 16 Patrol, 19 Reclaim, ...);
UNVERIFIED that the UI numbering matches.

### Grid cells bubble their events up to the root frame (CONFIRMED by report)

The root frame takes events that don't match the map's last position as the
pointer leaving the map. The grid lies over the map AND over parts of the
interface (at depth 50 it has to, to win the hit test). So a cell crossing is
evidence of neither:

- Taken as "the interface": a fast swing crosses two cells between the view's
  own motion events, and the pointer was reported on the HUD for a beat -- a
  stutter for teammates.
- Taken as "the map": hovering the interface, the pointer flipped to the map at
  every cell, and the HUD ghost snapped about.

A cell notes where it saw the pointer (`localMouse.cellX/cellY`) and the root
frame ignores the bubbled copy. Map = the view's own events; interface = the
root frame's events that came from real interface controls.

### Hooking key actions

FAF's keybinds run `import(file).Function()` when they fire, so replacing the
function in the module table catches both the key and the button that calls
it. Found in FAF's lua/keymap/keyactions.lua: 'stop' -> orders.Stop,
'soft_stop' -> orders.SoftStop (which calls Stop itself), 'toggle_repeat_build'
-> misckeyactions.ToggleRepeatBuild, 'abort_navigation' ("Interrupt pathfinding
of engineers") -> misckeyactions.AbortNavigation, 'pause_unit' and friends ->
construction.ToggleUnitPause / ToggleUnitPauseAll / ToggleUnitUnpauseAll, which
end in the engine global `SetPaused(units, paused)`. Wrapping the global
SetPaused did NOT catch the pause keys in game (reported), so the construction
functions are hooked directly; SetPaused stays hooked for the pause button. 'pause' is the game pause (tabs.TogglePause).
Repeat state must be read BEFORE the toggle: `IsRepeatQueue()` only changes
once the sim has processed `ProcessInfo('SetRepeatQueue', ...)`. See
actions.lua; everything is restored on teardown.

### The game's cursor flickers while a waypoint is dragged (CONFIRMED by report)

It alternates between the hand (`waypoint-drag`) and the arrow. Anything read
from the cursor during a drag has to be latched, not sampled: see
`sendState.waypoint` and `CurrentOrderIndex`.

### Right-drag preview (UNVERIFIED engine behaviour)

The live order line needs the pointer while the right button is held, with the
grid lifted. If the engine freezes MouseMotion and GetMouseWorldPos for the
length of a native right-drag, the line has zero length and nothing is drawn.
Run with `Config.Debug = true` and read the "right press ended" log line.
"Reached the sim" is inferred from `GetCommandQueue()` changing on the first
selected unit; its shape (a list of `{type, position}`) is assumed.

### Lua 5.0: closures in loops (CONFIRMED in game)

A function created inside a `for` loop that refers to the loop variable sees
the variable itself, and after the loop it is nil -- every panel checkbox's
OnCheck found `record == nil`. Copy it into a local inside the body. Run the
suites on Lua 5.0 and extras/check_loop_closures.py (see testing-workflow.md).

### Wire format (Protocol 1)

The packet is the table described below (Protocol 1). Bump `Config.Protocol`
for any change to it after release. SharedMouse's own format is separate
(legacyprotocol.lua).

**On the wire it is normally one string** (wirecodec.lua), sent as
`{ TeamMouse = <string> }`: no Identifier, no `v`. FAF's
`gamemain.ReceiveChat` (lua/ui/game/gamemain.lua) dispatches a message
without an Identifier by looking each registered identifier up as a key
(its "legacy" loop), so the key itself routes it to the same handler. An
older TeamMouse gets it too and ignores it (no `v`). The receiver decodes the
string back to the table and carries on exactly as for a table.

- **Exact, or not at all.** `Encode` decodes its own string and compares it
  with the packet before handing it out; a packet it cannot carry exactly (a
  NaN, a field it does not know, a selection string not written the way
  Base36 writes it) gives nil, and that packet goes as the table. A number
  that is not a whole number of its unit (a drag anchor straight from the
  engine) goes as the shortest text that reads back as exactly it.
- **Who gets which.** Everyone gets the table until they say they read the
  string: `{ Identifier = 'TeamMouse', tmc = 1 }` (1 = wirecodec.FORMAT),
  sent once on the first beat to every other client, and again (three times
  at most, 2 s apart) to anyone still sending us tables -- a word sent before
  their side was listening is lost. A compact packet from someone counts as
  their word too. Lists by format: `sendState.teamC/teamP/specC/specP` and
  `allC/allP` (teammates and observers together: one message when the
  observers' copy has no camera to add).
- **Lua 5.0's `n`.** A list built with `table.insert` may carry an `n` field
  (the mock models it as a real field); the codec carries it along, one bit
  in the list's length, so the copy is exact either way.
- **32-bit floats.** Whole numbers above 2^23 go as text; the self-check is
  what guarantees it, run in whatever number type the game has. The suites
  run on a float build of Lua 5.0 too (testing-workflow.md).
- **UNVERIFIED in game:** that FAF's ReceiveChat still has the legacy loop
  (it does in the FAF repository as of this change), and that the engine
  delivers a table holding one string as it does any other.

The replay gets the very same packet (replaycodec.lua): see "Replay
recording and playback" below.

Every field but `Identifier`, `v`, `a`, `p`, `o` is LEFT OUT when it has
nothing to say, and a missing field reads as its default (`w` true, flags
false, `hx`/`hy` 0.5/0.9, `bx`/`bz` the position). Zoom `z` is only sent
when it changes (and every ForceResendInterval), and the receiver keeps the
last one. Extra samples `e` are one packed string (wirepack.lua), not a table
of numbers. The SharedMouse-format packet only goes to teammates seen sending
genuine SharedMouse packets (TeamMouse's own copies carry a `mouseProtocol`
marker and are not counted). Measured with extras/wire_size.lua: ~4.7 KB/s
per recipient while moving before, ~1.2 KB/s after; ~470 B/s idle before,
~170 after.

`p` position, `o` cursor order index, `z` zoom, `w` over the map, `hx`/`hy`
position on the interface, `b` blueprint in build mode, `bx`/`bz` a drag's live
end. What a drag is: `s` selection box, `l` structure line, `r` order line,
`d` 1 drawing / 2 "follow" (the pointer moves, nothing drawn between: an order
before its line is due, or a waypoint being moved). `e` extra samples (stride
9, the last being a flags number: 1 hud, 2 box, 4 line, 8 order line, 16 draw,
32 follow -- as unpacked; on the wire it is the wirepack.lua string), `mo` right-click orders and placed structures (stride 7, the last a
sequence number), `mob` the structure's blueprint for each `mo` entry that
placed one (false otherwise; left out when none did), `mot` which `mo`
entries (1-based, in this packet) were build templates (left out when none),
`bt` true while the build in hand (`b`) is a template, `cam` (in the replay's copy and the copy sent to observers, never to teammates) the sender's camera as `SaveSettings` gives it, six numbers: focus x/y/z, heading, pitch (radians), zoom; `ck` clicks on the map since the last packet (1..9), `sel` the sender's selected unit ids, packed: base 36, comma-separated, one string (sent on change and every `TeamSelection.ResendInterval`; an empty list means nothing selected, absent means no change), `mou` which `mo` entries (1-based) are upgrades, `ss` the selected units' sizes (each doubled, base 36, comma-separated, with `sel`), `sr` with more selected than `TeamSelection.MaxSend`, rectangles round the bunches instead (x1,z1,x2,z2 in quarter units and y whole, base 36, `;` between; `sq` is then left out), `sq` where those units were when selected (x and z in quarter world units, y whole, base 36, `x,z,y` per unit, `;` between, empty where unknown; only with a change of selection, not with the periodic resend of `sel`), `vp` the sender's main view outline on the map (12 numbers: four corners, x/y/z, clockwise from top left; sent when a corner moves `Viewport.MinChange`, and with the periodic resend),
`oa` highest order sequence number now applied, `ac` actions (codes, see
actions.lua), `gk` the order being dragged (cursor index) during a waypoint
drag. A one-off message `{ tmo = 0|1, ta = army }` says the sender has hidden (0) or shown again (1) army `ta`'s cursor; it goes to every other client and only that army's player acts on it, leaving the sender's client out of (or back in) its sends. A separate one-off message `{ tmv = ModVersion }` announces the
sender's version (version.lua) and is handled before the protocol check. Everything is validated field by
field on receive; arrays are read by stride until the first nil and capped by
config, never with `table.getn`.

## `UnProject`

A **global** function (not a method on the view): `UnProject(view, Vector2) ->
Vector`. Whether the point is expected relative to the view's own top-left, or
in absolute screen coordinates, is undocumented, and the two conventions only
differ once a view doesn't start at the screen origin (splitscreen). Don't
assume either -- calibrate at runtime by trying both interpretations against a
resting pointer and comparing to `GetMouseWorldPos()`'s own reading for that
same instant, keeping whichever agrees within a loose tolerance, and disabling
anything that depends on it if neither agrees (see `CalibratePointerMap` in
teammouse.lua for the exact implementation).

**Only a view that does not start at the origin can settle the convention.**
On the origin view both readings are identical, so resting there first used to
"decide" relative by a tie, for the whole session. With an engine that wants
screen coordinates, everything on the right-hand splitscreen view then came out
a whole view-width to the left, and the receiver's HUD-panel clamp pinned the
ghost to the left edge of its view (CONFIRMED by report). The origin view now
only verifies UnProject; an offset view is not projected through at all until a
resting pointer on it has settled the convention (`UnProjectAt`).

### Knowing a structure was really placed (UNVERIFIED in game)

FAF's `/lua/ui/game/commandmode.lua` defines `OnCommandIssued(command)`,
called by the engine for each command the player issues: `CommandType`
('BuildMobile' for a structure), `Blueprint`, `Target.Position`, `Units`.
FAF's own per-structure feedback blips are drawn from it, which is the basis
for taking it as **one call per structure** in a row, and **no call** for a
placement the engine refuses. Hooked by `hook/lua/ui/game/commandmode.lua`,
which imports nothing (a hook file's imports join the engine file's chain) and
hands each command to a listener teammouse.lua parks on `_G`, inside pcall. A
build release waits `Orders.BuildConfirmTimeout` for them; until the hook has
seen any command at all in the session, silence is not trusted and the drag is
announced as before. With `Config.Debug` each build logs how many orders came.

### How many structures a row holds (UNVERIFIED in game)

Taken as the game appears to lay a drag: one per `Physics.SkirtSizeX/Z` along
the axis the drag covers more of, the other axis following in whole skirts.
While dragging, the far end only gains a structure once the pointer reaches
that structure's centre, the midpoint of its width (floor, not round -- the
game's behaviour as reported). A placed row runs between two real centres and
is rounded. A screenshot of a T1 power generator row (skirt 2) fits this;
other shapes (walls, large skirts) are untested.

### Build templates

A template is put in hand as ordinary build mode for its first structure plus
`SetActiveBuildTemplate(templateData)`; `GetActiveBuildTemplate()` returns it
(`[1]`/`[2]` size, `[3]..` `{ bp, order, x, z }`) and is cleared on cancel and
whenever a single structure is picked (commandmode.lua, construction.lua,
hotbuild.lua in FAF). TeamMouse also requires `[3][1]` to match the build
mode, against a leftover. Its structures are several kinds in their own
layout, so only the first is shown, flagged (`mot`, `bt`), with TEMPLATE above
it: steady in hand, flashing once placed. No row is drawn for one.

### Replay recording and playback (UNVERIFIED in game)

Chat (`SessionSendChatMessage`) is not recorded; everything that goes through
the sim is. FAF's query system is a way through it for plain Lua data:
`SimCallback { Func = 'OnPlayerQuery', Args = t }` reaches the sim
(SimCallbacks.lua, no validation, no throttle), which puts `t` in
`Sync.PlayerQueries`; UserSync hands those to `/lua/userplayerquery.lua`
`ProcessQueries`, which calls whoever `AddQueryListener`ed for `t.Name`. The
sim adds `FromCommandSource`. A replay reruns the sim, so the same tables come
back up to the viewer at the same game time.

So `Transmit` sends every packet teammates get into the sim as well (`Record`,
`Name = 'TeamMouse'`, packet in `M`, deep-copied since the sender reuses its
packet table), with or without teammates; playback `Listen`s and hands each to
`ProcessMessage(false, msg)`, which finds the player by `msg.a`. A live game
does not listen.

- **Every player's interface gets it, enemies too**, live, without needing
  vision. A UI mod on an opponent's side could read the cursor as it happens.
  Unavoidable for anything a replay records; it is why this is a lobby
  option, off unless the host turns it on.
- Cost: one sim command per packet (about 10/s while the mouse moves, none at
  rest) per player running the mod, into the replay and the lockstep stream.
- Replaced (and why): writing a few fields into the commander's custom name.
  Replay cursors were missing and off their real spot. The name held only
  position, flags and a small event; height had to be squeezed in (the UI
  cannot look terrain height up -- `GetTerrainHeight` is sim-only); only the
  focused army's commander was reachable without hovering others
  (`GetArmyAvatars`), and name length limits were never known. The name
  codec, hook/lua/ui/game/unitview.lua and the commander search are gone.
- **Needs confirming in game:** that the queries do come back up during
  replay playback, and at the right moments.

### Lobby option (UNVERIFIED that UI mods are scanned)

FAF's lobby (lua/ui/lobby/lobby.lua, `ImportModAIOptions`) reads `AIOpts` from
`<mod>/lua/AI/LobbyOptions/lobbyoptions.lua` for every mod `AllMods()` returns,
lists them with the other game options, and at launch drops options whose mods
the host has not selected (`Mods.GetSelectedMods()`, which does include the
host's UI mods). In game the choice is `SessionGetScenarioInfo().Options[key]`,
kept in the replay too. TeamMouse's key is `TeamMouseReplay` ('on'/'off'); read
once by `ReplayCodec.IsEnabled`, falling back to `Config.ReplayCodec.Enabled`
when absent. `mods.lua` (and so `AllMods`) is not in the FAF repository; that it
includes UI mods is assumed -- if the option never shows in the lobby, that is
why.

### Cursors, the name bar, teammates' views

- **A paused replay sends nothing** (no sim, no recorded packets), so every
  cursor used to go stale and fade. `HoldWhilePaused` moves each record's
  `lastUpdate` on by the frame's time while `SessionIsPaused()` (User.lua) is
  true in a replay.
- **The name bar shows THEIR zoom** (`msg.z`): as wide as their name all the
  way in, `Appearance.NameBarMinWidth` all the way out, centred with a lazy
  Left. **On a log scale**: a straight line from zoom to width put almost all
  of the change at the far end (reported: "doesn't change much until I zoom
  all the way out"); zooming feels proportional. The range is the local
  camera's `CameraImpl:GetMinZoom()` / `GetMaxZoom()` (FAF
  engine/User/CameraImpl.lua; the map sets the far end, and both players share
  it), read per view each frame in pcall; `NameBarZoomIn/Out` otherwise.
- **Text has no outline.** CMauiText (FAF engine/User/CMauiText.lua) offers
  only `SetDropShadow`, which is black. The white stroke on names and
  indicators is eight copies of the text in white, one `TextStrokeWidth` off
  in each direction, under it, positions bound lazily to the text's; the
  text's own drop shadow is turned off (it muddied the stroke).
- **Lines in the world: `UI_DrawLine(p1, p2, color, thickness)`**, only from
  within a world view's `OnRenderWorld`. FAF's world views mix in
  `WorldViewShapeComponent` (lua/ui/controls/components/): `AddShape(shape,
  id)` turns on `SetCustomRender(true)` and calls `shape:Render(delta)` every
  frame; `RemoveShape(id)` turns it off when none are left. It relies on FAF
  binary patches (FA-Binary-Patches #47, #111, #112). A shape needs `Render`,
  `OnRender` and `Destroy`; the component keeps it in a TrashBag, so keep a
  reference. Colours are `'AARRGGBB'`: fade a line through its alpha byte.
  **UNVERIFIED: what `thickness` measures.** FAF's painting passes 0..1 (0 at
  normal UI scale) and its strokes look the same on screen at any zoom, which
  suggests screen-space; `Viewport.Thickness/NearThickness` may need tuning.
- The view outline: one shape per cursor (`'TeamMouseView' .. army`), added
  once and hidden/shown through `Hidden`, removed in `OnDestroy`. `UpdateFrame`
  computes the points; `Render` only draws. Four lines in their colour (a
  white line outside them was tried and dropped). Corners come
  from `UnProjectAt` on the sender's 'WorldCamera' view (needs the pointer map
  verified; nothing is sent before). Lines are straight between the corners,
  so they can dip under hills. **Needs confirming in game:** a steeply tilted
  camera, where corners can land very far away.

### Following a player's camera (replays; UNVERIFIED in game)

- `CameraImpl:SaveSettings()` returns `{ Focus, Heading, Pitch, Zoom }` and
  `RestoreSettings(t)` applies one (FAF engine/User/CameraImpl.lua); FAF's own
  chat camera links round-trip exactly these. Angles are radians (default
  heading pi). The sender reads it each beat, only when recording, and adds
  it as `cam` to the packet it records -- not to the one sent over chat, to
  keep live packets small (the size budget test caught it).
- `FollowPass` (in `ReplayFrame`, with the pause hold, so `UpdateFrame`'s
  upvalue count did not grow) calls `RestoreSettings` every frame, moving
  `1 - e^(-Follow.Rate * dt)` of the way to the player's last camera: heading
  the short way round, zoom on a log scale. It keeps its own running state
  rather than reading the camera back, so nothing drifts. An older recording
  (no `cam`) follows the middle of the view outline at their zoom.
- **Needs confirming in game:** that `RestoreSettings` every frame is smooth,
  and what happens if the viewer scrolls or zooms while following (it will
  be pulled back; there may be a visible tug).

### Bandwidth and per-frame cost (measured in the mock)

Measured with a mock session (wire_size.lua's estimate for bytes; counts of
lazy-var sets, visibility, alpha and Project calls for per-frame work):

- At rest a player sends only the keep-alive (`Network.ForceResendInterval`,
  1 s; the stale timeout is 5 s). The view outline, the biggest thing in a
  packet, has its own slower refresh (`Viewport.ResendInterval`, 5 s); both it
  and zoom are sent at once when they change. Idle went from ~360 to ~105 B/s,
  moving from ~1380 to ~1160 B/s. Replays shrink the same way.
- The compact string (wirecodec.lua) then took, per teammate
  (extras/bandwidth_report.lua, model A): at rest ~104 -> ~31 B/s, sweeping
  the map ~1180 -> ~430, on the interface ~1560 -> ~540, panning the camera
  ~2440 -> ~660, box-dragging ~1550 -> ~660 (float Lua), orders ~1450 -> ~470;
  the replay copy through the sim ~1980 -> ~860 B/s. Numbers are written as
  differences from something close by (the pointer, the previous sample,
  the previous corner), so most take one or two characters.
- Deliberately kept, though they cost bytes: `v` (protocol check), `a` (the
  fallback for matching a packet to a player; replays depend on it), `o` every
  packet (older receivers read a missing `o` as 0), and the `Identifier` FAF
  chat routing needs.
- A cursor costs about two lazy-var sets and one Project per frame. Structure
  icon rows (`SetIconRow`) only write positions and visibility that changed;
  a still row costs nothing (was ~25 sets and ~10 visibility calls a frame).
  Spare pool icons are still re-hidden every frame: a parent's Show() reveals
  them without telling us.
- Zoom limits (`GetMinZoom`/`GetMaxZoom`) are read once a second per view
  (kept on the view as `TeamMouseZoomLimits`), not every frame.
- **Garbage is frame time.** Lua 5.0's collector is not incremental: it stops
  everything to collect. extras/frame_report.lua measures the mod's own
  garbage and instructions per frame (three teammates; at rest / moving /
  busy / splitscreen); a test holds the busy case to a budget. Taken out:
  a digits table per packed number (wirepack `Put`), tables per decoded
  sample, the decoder's reader and context, a closure per packet for the
  extra samples (`UnpackSamples` passes a `ctx` through), a state table per
  `ReadLocalState`, a colour string per line shape per frame (`WithAlpha` is
  memoized), corner tables per selection rectangle per frame, a table per
  frame to project a drag's live end, a closure per beat for the camera.
  Busy went from ~3340 to ~700 bytes a frame.
- **Interpolate searches from the newest end.** The target is
  InterpolationDelay behind the clock, so its pair is among the last few of
  BufferSize (48). Sample times never decrease (PushSample and PushExtras
  only add later ones), which makes the last sample before the target and
  the one after it exactly the pair an oldest-first search finds. If
  anything ever adds a sample out of time order, that no longer holds.
- Also skipped when nothing changed: the view outline's corners (copied
  again only when `record.vpVersion` moves) and the name bar's log scale
  (worked out again only when their zoom or our zoom range changes).
- Left alone: PushSample still shifts the whole buffer down when full (a
  ring buffer would change the layout every reader and test relies on);
  the decoder still builds the extra-samples string the receiver then reads
  (the price of decoding to exactly the table that was sent).

### Upgrades, selections, clicks (UNVERIFIED in game)

- **Upgrades** cannot be caught by wrapping alone. Three engine globals
  issue them (`IssueBlueprintCommand`, `...ToUnits`, `...ToUnit` with
  `'UNITCOMMAND_Upgrade'`), and FAF modules look globals up in `_G` at call
  time (lua/system/import.lua: module metatable `__index = _G`), so the build
  menu and commandmode's auto-upgrade are caught -- but the upgrade hotkey
  (lua/ui/game/hotkeys/upgrade-structure.lua) keeps `local
  IssueBlueprintCommandToUnit = IssueBlueprintCommandToUnit` from load time,
  before the mod starts, and is never seen (reported: no upgrade markers at
  all). So structures from recent selections are also watched
  (`CheckUpgrades`, `Orders.UpgradeWatchSeconds`): one that starts building a
  STRUCTURE in place (`UserUnit:GetFocus()`, the new unit's `GetUnitId()`)
  is upgrading. Told once per upgrade: whichever path tells first marks it;
  it resets once that upgrade is seen to end, or 10 s after an ordered one
  never starts. Marked with `mou`; drawn in a gold frame, fading like any
  structure marker.
- **Selection**: FAF's `gamemain.ObserveSelection:AddObserver(fn, name)`
  gets `{ oldSelection, newSelection, added, removed }` ("GetSelectedUnits
  is nil within OnSelectionChanged": use `newSelection`). Where it is missing,
  `GetSelectedUnits()` is polled each beat. Ids from `UserUnit:GetEntityId()`.
  Teammates look them up with `GetUnitById` (Core, so UI-side too) when the
  list changes, and draw `UI_DrawRect` boxes; allied units should be
  reachable, fogged enemy units are not the case here.
- **Clicks**: only a left click that selects something pulses: a left
  press (or double-click) the pointer does not then move `ClickPulse.MaxMove`
  pixels from, followed within `SelectWindow` by the selection changing to
  something non-empty. **When a click selects a unit, its release does not
  reach the view's Lua handler** (single clicks never pulsed; double-clicks,
  with their own event, did), so nothing waits for the release. A drag the
  view never heard move is caught by the grid's last position. Sent as
  `ck`, drawn with `UI_DrawCircle(pos, radius, color,
  thickness)`; its size is a world-unit radius (FAF's painting brush passes
  3, or 2% of zoom). Radius and box size are set in pixels and converted with how
  far one world unit spans on screen at that spot (two `Project` calls).
  **UNVERIFIED:** whether `UI_DrawCircle`/`UI_DrawRect` lie on the ground
  plane (they take a single world position and size).
- **Replays and observers following**: while following in a replay the
  viewer's selection becomes the player's (`SelectUnits`, when it changes).
  Live observers get the camera in their own copy of each packet (players
  send teammates and observers separately: `sendState.teamTo` / `specTo`),
  and may follow; they do not take selections.

- **Selection boxes** (`UI_DrawRect(pos, size, color, thickness)`):
  - **Thickness is in world units** (like size). With a fixed 1 it filled
    small boxes zoomed in and vanished around big ones zoomed out (reported
    with a screenshot). It is now `TeamSelection.Thickness` pixels, converted
    like the size. `UI_DrawCircle` is taken to be the same.
  - **Where the square is anchored: UNVERIFIED.** Boxes were off-centre with
    `pos` as the centre; `pos` is now taken as a corner
    (`RectAnchoredAtCorner`), and they were reported sitting on the units.
  - **A player cannot look up a teammate's units by id in a live game; an
    observer can** (an engine rule, confirmed by the author; FAF's own ally
    overlay sends positions for the same reason). So: live, the sender sends
    where its selected units are at the moment of selecting (`sq`), and a
    teammate draws the boxes there and fades them like any other marker
    (`Orders.FadeHold` / `Lifetime`); a repeat of the same selection (the
    periodic resend) does not bring them back. Observers and replays look the
    units up and track them every frame, for as long as they are selected.
    (Streaming positions as units moved, with interpolation, was tried and
    dropped: too much machinery for what it gave.) Bunched boxes, nearly on
    top of each other, are drawn once (`MergeWithin`).
  - **Size**: the biggest of the blueprint's `Physics.SkirtSize`,
    `Footprint.Size` and `SizeX/Z` (a factory: skirt 8, footprint 5, body
    4.2), worked out by the sender and sent (`ss`), plus `Margin`; at least
    `IconSize` pixels on screen.
  - Ids go as one base-36 string, capped at `MaxSend` (40).
- **COPY**: copying orders (the copy-orders hotkey, ctrl-assisting an
  engineer) ends in `SimCallback { Func = 'CopyOrders' }`; actions.lua wraps
  `SimCallback` and reports it as the COPY action. ReplayCodec.Record also
  calls `SimCallback`, which passes straight through.
- **DISTRIBUTE ORDERS**: every distribute key ('spreadattack',
  'shift_spreadattack' and their `_context` variants, FAF
  lua/ui/game/hotkeys/distribute-queue.lua) ends in
  `SimCallback({ Func = 'DistributeOrders', ... }, true)`, and only when the
  chosen unit has orders to give out, so the same wrap reports it (action 8).
  UNVERIFIED in game.

- **A plain right click is a move.** Its cursor index is 0 (no command
  cursor) or `selectable`/`selectable-invalid` (over a unit you could select);
  the order is sent with the `move` index so teammates see the move icon.

- **No compatibility with earlier TeamMouse builds** (unreleased): one wire
  format. The order cursor `o` goes only when it changes and with the
  keep-alive (a missing `o` means unchanged). Compatibility is kept only with
  the legacy SharedMouse mod (legacyprotocol.lua).
- **A box drag is never re-declared a grab once under way.** The hand
  (waypoint-drag) cursor shows whenever the pointer is over an order with
  Shift held, so a Shift box drag passing over one used to turn into dragging
  it (reported). It now only counts within `Orders.GrabStartPixels` of where
  the drag began; and while a box drag is in progress the pointer is reported
  as plain, whatever the game's cursor flickers to.

- **Over the cap: rectangles round the bunches.** More units selected than
  `TeamSelection.MaxSend` (40) used to mean only the first 40 got boxes.
  Now the sender groups every selected unit (up to `MaxCluster`) into grid
  cells of `ClusterCell` world units, one rectangle per cell padded by the
  units' sizes, merges overlapping rectangles, and doubles the cell size
  while that leaves more than `MaxRects` -- but not past `ClusterMaxCell`,
  so far-apart units are never lumped into one huge box (beyond it, the
  first `MaxRects` go). The change-detection key includes how many are
  selected, since past the cap more units change the rectangles but not the
  ids. Drawn with `UI_DrawLine` (rectangles are not square; `UI_DrawRect`
  only does squares), fading like live boxes, for observers too.

- **Hiding a cursor stops it being sent.** Unticking a player in the panel
  (or "all") sends `tmo = 0` naming their army; they drop our client from
  their sends (`sendState.muted`, `teamLive` / `specLive`), and with nobody
  left to send to (and no replay being recorded) do not even build a packet.
  `tmo = 1` undoes it. Still receiving from a player we hid means they missed
  it (or started after): it is said again, at most every 5 s. Observers hide
  players the same way. Not in replays (nobody to tell); the replay copy is
  recorded regardless. Lets anyone switch the mod's traffic off for
  themselves, both ends, if it is ever a strain.

### ReUI options (checked against ReUI's source; UNVERIFIED in game)

Read from 4z0t/FAF-UI-Mods (mods/ReUI): ReUI's gamemain hook loads every
`ui_only` mod whose mod_info has a `ReUI` field (`"TeamMouse=1.0.0"`), finds
`/mods/TeamMouse/TeamMouse.lua` or else `Main.lua`, and calls its `Main` before
the interface is built. `ReUI.Options.Mods['TeamMouse']`, first read, imports
`/mods/TeamMouse/Options.lua`, whose assignment to `Mods['TeamMouse']` turns
every value (an `Opt(v)` or a plain value) into an **OptionVar**: read by
**calling** it, `:Set(v)` (calls `self:OnChange()`), `:Save()` (profile),
`:Reset()` (back to the saved value). It has **no** `:Get()` and **no**
`OnChanged:Add` -- the shape the Mouse mod (Mouse-main) was written against,
and the previous TeamMouse copy of it, which would have failed on the current
ReUI (`OptionValue` is nil there). options.lua reads and watches both shapes
(`Read`, and OnChange chained, keeping any earlier one).

`Builder.AddOptions(key, title, build)` takes a table (ReUI's own window: no
tooltips, no scrollbar) or a function `(parent) -> window`, called when the
mod is picked in ReUI's list (Selector.lua: `iscallable(self.data[2])`). With
`Opt` present TeamMouse passes a function: modules/optionswindow.lua builds a
game `Window` with a `Grid` of rows and `UIUtil.CreateVertScrollbarFor` (as
FAF's own lua/ui/dialogs/options.lua), and `Tooltip.CreateMouseoverDisplay(ctrl,
{ text, body }, delay, true)` on each row. Rows pass the wheel to the
scrollbar. OK saves each OptionVar, Cancel / the close button reset them,
Defaults sets config.lua's shipped values (taken when options.lua first
loads, before ReUI's are written in). Settings read only when a cursor is
built still go through `_G.TeamMouseRebuild`. **Needs confirming in game:**
the window's look and layout, and the scrollbar.

### The panel in a replay; versions

- A replay's panel only lists a player once their recorded data has arrived
  (`record.hasData`, which never goes back to false): Panel.Create keeps its
  source list, and `Panel.Sync` (each replay frame, and each beat) rebuilds
  when the count changes. Folded state and per-record choices survive the
  rebuild; any row reference held across one is stale (look it up again).
- `{ tmv }` is also recorded into the replay once, with `a` (the army), by a
  recording player (`Version.SetRecorder`); playback has no sender, so
  ProcessMessage names it from `msg.a`. Older replays show `?`.
- `Version.Heard` keeps every version it hears (observers too) for the panel's
  column. The chat report is gone; `Version.Start` still sends our version to
  teammates and observers and starts the `none` timer (`VersionReport.CheckDelay`).
  A teammate seen sending SharedMouse packets shows as `old`.

### Upgrade markers

The frame stays in the player's colour; a gold diamond texture
(`textures/upgrade_diamond.png`, `Orders.UpgradeDiamondScale` of the frame's
width) is drawn behind it, so an upgrade differs by shape, not only colour
(a yellow player's frame was indistinguishable from the old gold one). The
frame's Depth is raised above the diamond's when the diamond is first built.

### Showing is local; sending is everything

Every show/hide setting (`Orders.Enabled`, `ShowBuilds`, `ShowUpgrades`,
`ShowGrabs`, `TeamSelection.Enabled`, `ClickPulse.Enabled`, `Actions.Enabled`,
`Build.Enabled`, `Line.Enabled`, `Draw.Enabled`, ...) gates only what is DRAWN.
The sender never reads them (only the config-level `Share` flags, which ReUI
does not offer), and the receiver stores what arrives either way, so a setting
switched on mid-game shows what is already there. `RemoteCursor` always calls
ApplyOrders/ApplyTrail and each hides what is up when its setting is off.
Still sender-side, deliberately: `Orders.ShowModeOrders`, `Orders.ShowLiveLine`,
`Selection.Enabled` (the drag grid), `Viewport.Share`, `Hud.FollowPointer`.

### Click pulse on a change of selection (HYPOTHESIS, needs confirming)

Reported: no pulse when clicking a unit with something already selected. Taken
to be the selection passing through empty on its way to the new one (an empty
selection used to cancel the pending click; with nothing selected before, there
is no empty step to see). An empty selection no longer cancels it; the
`SelectWindow` ends it. With `Config.Debug` each selection change logs its size
and how long after the click it came -- if it still fails, read those lines: a
change logged BEFORE the press would mean the press reaches Lua late instead.

### Interface ghost per faction

`GetArmiesTable().armiesTable[i].faction` (0 UEF, 1 Aeon, 2 Cybran,
3 Seraphim) picks `textures/hud/UICutout-<faction>.png`; anything else
(Nomads, missing) gets the original `textures/UICutout.png`. UNVERIFIED that
the field is present for every army in a live game (it is in FAF's lobby
data and scoreboard code).

### Upgrades told once (by the building being built)

The watch on selected structures (`sendState.watch`) lets one go after
`Orders.UpgradeWatchSeconds` without being selected (selection changes only),
so selecting it again mid-upgrade made a fresh watch and told the upgrade
again (reported: upgrades flashing again on reselecting). Told upgrades are now
kept by the entity id of the unit being built (`GetFocus():GetEntityId()`) in
`sendState.upgradeTold`, which outlives the watch; a later upgrade builds a
new unit and is told. Cleared at 200 entries and on teardown.

### A hidden selection box still moves the arrow

`DragShape` returns `follow` (not false) for a box drag when
`Selection.ShowBox` is off: the arrow rides the live end without a box. False
meant no drag at all, so the arrow sat at the press point and jumped at the
release.

### Following fits their view by its larger axis (UNVERIFIED in game)

Their window and ours rarely have the same shape, so their zoom alone cut a
wider view of theirs off at the sides. `FollowFit` projects the middle of each
edge of their view outline (`vp`) through our camera and compares the spans
with our view's size. Spans shrink in proportion as the camera pulls back, so
`need * ourZoom / theirZoom` is the multiplier that makes the larger axis fill
our view, whatever zoom it was measured at: it is used as is, NOT eased
(an earlier version eased it in once the camera had arrived at their plain
zoom -- reported as a weird second zoom). It is only measured while our
camera looks where theirs does (focus within 5% of their zoom, pitch and
heading within 0.05); otherwise the last value for that player
(`record.followFit`) is used, so following them again is right at once.
`Follow.FitView = false`: their zoom as before. Needs `vp` in the recording.

### Scrolling out of a follow

FAF's WorldView.HandleEvent sees `WheelRotation` (lua/ui/controls/worldview.lua
sets `self.zoomed` from it), and so does our view hook: `NoteFollowScroll`
counts notches (|WheelRotation| / 120, at least 1 per event) while following;
`Follow.BreakScrolls` of them within `Follow.BreakWindow` seconds stop the
follow and untick its box (`Panel.SyncFollow`). Fewer are undone by the
follow putting the camera back. 0 disables it. UNVERIFIED: the notch size
(120) on every system.
