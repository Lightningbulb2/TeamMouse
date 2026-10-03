---
name: teammouse-dev
description: >
  Architecture reference and required workflow for TeamMouse, a Forged Alliance
  Forever (Supreme Commander) UI mod that shares a player's mouse position, cursor
  state, and build selection with teammates and draws their cursors on the map.
  Use this skill whenever working on TeamMouse: modules/teammouse.lua,
  remotecursor.lua, cursordata.lua, hudghost.lua, config.lua, replaycodec.lua,
  legacyprotocol.lua, or its extras/ mock test harness -- adding a feature, fixing
  a bug, touching input handling, drag/selection tracking, cursor rendering, or
  anything that creates or toggles engine UI controls (Group, Bitmap, LazyVar
  Left/Top/Width/Height). Also use it before trusting a change against this
  engine's Lua 5.0 runtime, since the mock test suite alone (Lua 5.1) can hide
  real load-time failures. Load references/engine-gotchas.md before writing code
  that creates a control, toggles hit-testing/visibility, or reads mouse position
  during a native engine drag; load references/testing-workflow.md before
  delivering any change.
---

# TeamMouse Development Reference

## What this mod does

TeamMouse runs as UI-side Lua inside Forged Alliance Forever (an actively
maintained community fork of Supreme Commander: Forged Alliance, itself running
an old, customized Lua 5.0 / LuaPlus). Ten times a second it reads the local
player's mouse position, cursor icon, and build selection, and broadcasts it to
allies over the game's chat channel. On receipt, it interpolates each peer's
position and draws a cursor (arrow, name label, selection, build ghost, drag
box, or a stylised "HUD ghost" panel while they're on their own interface) into
every local world view, sixty times a second.

```
OnBeat   (10/s)  local state -> SessionSendChatMessage to allies
OnReceive        push a timestamped sample into that player's buffer
OnFrame  (60/s)  interpolate every buffer, then place every visual
```

Everything here is **UI-side only**. There is no sim-side access without an
explicit `SimCallback` round trip (not currently used), and no access to any
other player's real client state beyond what they choose to broadcast.

## File map

| File                                                                                          | Role                                                                                                                                                                    |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `modules/teammouse.lua`                                                                       | Session setup, send/receive, local input tracking, drag detection, view sync. The biggest and most upvalue-constrained file -- see engine-gotchas.md.                   |
| `modules/remotecursor.lua`                                                                    | The visual for one peer in one world view: arrow, label, build ghost, drag box, HUD-ghost hookup. One instance per (peer, view).                                        |
| `modules/cursordata.lua`                                                                      | Cursor texture name <-> wire index <-> display texture, and army-colour <-> arrow-texture resolution. Pure data/lookup, no engine control creation.                     |
| `modules/hudghost.lua`                                                                        | The panel drawn when a peer is on their own interface rather than the map.                                                                                              |
| `modules/config.lua`                                                                          | Every tunable and feature flag. Check here first before assuming a magic number is hardcoded elsewhere.                                                                 |
| `modules/replaycodec.lua`                                                                     | Records every packet into the replay through the sim (FAF query system) and hands them back during playback; the lobby option decides.                         |
| `modules/legacyprotocol.lua`                                                                  | A compact fallback wire format for teammates on an older/incompatible version of the mod.                                                                               |
| `modules/options.lua`, `modules/optionswindow.lua`, `Main.lua`, `Options.lua`               | Optional ReUI settings, all about what you are SHOWN (sending never depends on them). options.lua is the one list (label, tooltip, control, Config field); optionswindow.lua is TeamMouse's own window in ReUI's list (tooltips, scrollbar); the two root files are ReUI's entry points. See "ReUI options" in engine-gotchas.md for ReUI's real OptionVar API. |
| `modules/wirecodec.lua`                                                                       | The compact wire format: the packet table as one string, decoding to exactly the same table (self-checked; nil means send the table). See "Wire format" in engine-gotchas.md. |
| `extras/bandwidth_report.lua`                                                                 | Bytes per second to each teammate in ordinary situations, by field. Run it before and after any change to what is sent.                                                  |
| `extras/frame_report.lua`                                                                     | The mod's own garbage and Lua instructions per frame with three teammates (at rest, moving, busy, splitscreen); `busy 20` adds the top functions. Run it before and after any change to per-frame code. |
| `hook/lua/ui/game/*.lua`                                                                      | Engine hook files -- see "Hook files" in engine-gotchas.md before adding one. commandmode.lua passes every issued command to teammouse.lua (placement confirmation); gamemain.lua starts the mod. |
| `lua/AI/LobbyOptions/lobbyoptions.lua`                                                        | The lobby option that switches the replay codec on ("Lobby option" in engine-gotchas.md).                                                                              |
| `extras/mock_fa.lua`                                                                          | A from-scratch simulation of the engine's UI primitives, used by every test file. Not a real engine -- see testing-workflow.md for exactly what it can and can't prove. |
| `extras/test_integration.lua`, `test_visibility.lua`, `test_replaycodec.lua`, `test_fuzz.lua` | The test suite. Run all four before delivering any change.                                                                                                              |
| `extras/check_upvalues.py`                                                                    | Estimates per-function upvalue counts against Lua 5.0's 32-per-function limit. An estimate only -- see testing-workflow.md for the authoritative check.                 |

## Core mechanisms, briefly

- **Peer records** (`CreateRecord` in teammouse.lua): one per visible ally, holding
  a ring buffer of timestamped position samples and every piece of state a
  `RemoteCursor` needs to render them. The ring buffer (`PushSample`/`Interpolate`)
  is hand-rolled with an explicit count and direct indexing -- see
  engine-gotchas.md before touching it, the reason is not optional.
- **Local input tracking**: two event hooks feed a shared `localMouse` state --
  `HookViewEvents` (per world view) and `HookRootFrame` (the whole screen, needed
  because the view alone stops receiving ordinary motion once the engine's native
  drag capture engages). Getting this interaction right is the single hardest part
  of this codebase; read engine-gotchas.md's hit-testing section before changing
  either hook.
- **Drag/box-select tracking**: the engine freezes normal mouse-position polling
  during a native map drag, so a per-view grid of invisible controls, raised only for
  the length of a drag, is used to keep tracking the pointer via crossing events, which keep firing even
  during that freeze. This is the most delicate mechanism in the mod --
  engine-gotchas.md has the full account of what was tried and what actually
  worked.
- **Coordinate calibration**: `UnProject`'s exact coordinate convention
  (view-relative vs. absolute screen) is undocumented and is calibrated at
  runtime against `GetMouseWorldPos()` rather than assumed -- see
  `CalibratePointerMap` in teammouse.lua.

## Required workflow

Before treating any change as done:

1. Load `references/testing-workflow.md` and follow it exactly -- in particular,
   **the mock test suite runs on Lua 5.1 and will not catch several classes of
   real Lua 5.0 failure** (the upvalue limit chief among them). A change that
   passes every mock test can still fail to load in the real game.
2. Load `references/engine-gotchas.md` before writing any code that creates a
   `Group`/`Bitmap`, toggles hit-testing or visibility, reads mouse position, or
   hooks a `HandleEvent`. Nearly everything in it was learned by shipping
   something reasonable-looking that failed in a specific, non-obvious way.
3. When a bug report describes engine behaviour that doesn't match anything in
   engine-gotchas.md, don't assume the existing account is wrong -- add a
   _diagnostic_ first (a targeted `LOG` or a test that isolates the claim) and
   get real data before writing a fix. This codebase's history is full of
   multi-round detours from plausible-sounding guesses about this specific
   engine; the gotchas file exists to stop that from happening twice for the
   same fact.
