name = "TeamMouse"
uid = "TeamMouseV6"
description =
"AI is used to help with upgrading the old SharedMouse mod into TeamMouse. \nShow your teammates what you are doing. Shares mouse position, order cursor, build selection and drag-selections with your team, with smooth interpolation, zoom-aware scaling, and a HUD indicator so you can tell when someone has stepped off the map into their interface. v6: fixes a crash in v5."
copyright = "Licensed under the FAF Vault License. Free to use and modify."
author = "Eternal- & KasperAUS & Lightningbulb"
url = "https://github.com/Lightningbulb2/TeamMouse"
icon = "/mods/TeamMouse/logo.png"
version = 6
exclusive = false

ui_only = true

--[[

### Changelog

## v6

Hotfix for a crash reported on v5, plus a hardening pass. Reported log:
"attempt to perform arithmetic on field 't' (a nil value)" in Interpolate,
and "Attempt to set attribute 't' on nil" out of ReceiveChat.

Root cause
  * Forged Alliance runs Lua 5.0, where table.insert / table.remove /
    table.getn maintain a hidden 'n' field on the table. The sample buffer
    cleared itself on a large cursor jump by assigning nil to its entries;
    that desynchronises 'n' from the real contents, so table.getn later
    reports a count larger than the array, and table.remove(samples, 1) then
    hands back nil off an array it still considers non-empty -- which is
    exactly the crash. The buffer is now managed with an explicit integer
    count and direct indexing, never touching those three functions.
  * The test suite ran on Lua 5.1, where all three use the # operator and
    have no hidden field, so it could not see this. mock_fa.lua now
    reimplements 5.0's table semantics faithfully, and the crash reproduces
    and is caught by re-running the old implementation against it.

Also fixed
  * Team colour mode handed back engine colour names ('RoyalBlue', 'DarkGreen')
    instead of a palette hex string, which fell through to the neutral arrow
    for every player using it. Colours are now parsed with the game's own
    colour parser and matched to the nearest arrow actually shipped; a
    genuinely unparseable colour still falls back cleanly, and every SetColor
    / SetSolidColor call is now guarded against receiving one.
  * OnReceive was not wrapped in pcall. gamemain.ReceiveChat does not guard
    the handlers it dispatches to, so a single malformed or out-of-range field
    in a teammate's packet would abort the rest of that chat message's
    processing -- potentially other mods' handlers too. Every wire field is
    now type- and range-validated, including a NaN check, before use.
  * The local mouse position is validated before it is ever sent: a partially
    populated or non-finite vector from the engine could otherwise propagate
    a NaN into every teammate's interpolation and layout.
  * The frame driver no longer permanently disables itself after a handful of
    errors. A transient fault -- a view being torn down mid-frame, say -- was
    silently killing the mod for the rest of the session with no way back; it
    now keeps running and rate-limits the log instead.
  * The recipient list assumed client index equals army index. AI and
    civilian armies can push the two out of step, so a client is now checked
    both by index and by nickname, and excluded if either indicates an
    opponent. Added Network.ShareWithObservers (on by default, matching the
    base game's own casting-mouse feature) to control whether spectators
    receive positions at all.
  * A selection drag whose ButtonRelease is consumed by something else (a
    dialog opening over the view, say) no longer sticks on forever; it clears
    itself after Selection.MaxDragSeconds.
  * Zoom now persists across a trip into the HUD instead of dropping to zero,
    so a teammate's cursor does not snap to unit scale every time they glance
    at their own interface.
  * A view narrower or shorter than the HUD panel no longer fights its own
    edge clamp; the panel centres instead.
  * The per-frame render loop now checks that a visual's view is still the
    live one before projecting against it, closing a window of up to one beat
    after the engine replaces a view where a cursor could project against an
    already-destroyed control.
  * Disabling Hud.Enabled now falls back to the plain order cursor rather than
    leaving a cursor frozen half-updated.

Testing
  * mock_fa.lua rewritten to emulate Lua 5.0 table semantics faithfully
    (table.getn/insert/remove maintaining a hidden 'n' the way 5.0 does), and
    to raise on a Bitmap left without a texture or an invalid colour passed to
    SetColor / SetSolidColor, both of which the real engine only logs.
  * Regression tests added for the exact crash (buffer driven past capacity
    both before and after a jump, repeated jump cycles, a live frame loop
    throughout), for malformed and adversarial packets, for every visual state
    against the untextured-bitmap check, for exotic and unparseable colours,
    and for the other fixes above.
  * A randomised fuzz harness (extras/test_fuzz.lua) added: malformed packets,
    view swaps, layout churn, zoom extremes, degenerate mouse positions and
    unbalanced mouse events, interleaved with frame ticks, asserting only that
    the mod never raises and never logs an error. Clean across 40 seeds.

## v5

Rewrite. The previous release did not run at all: the cursor class, the view
synchronisation and the teardown were all inside an unterminated block comment,
so InitTeamMouse called a nil SyncViews and threw during CreateUI.

Fixes
  * RegisterChatFunc was called as a bare global. It lives in the gamemain
    module table, not _G, so receiving never worked. Now imported properly.
  * The send loop declared its comparison state inside the beat callback, so
    it reset every call and transmitted on every beat regardless of movement.
  * SyncViews returned from inside its inner loop, so only one player got a
    cursor and splitscreen never worked. It also could not notice that the
    engine had replaced a view on a layout change.
  * Observers crashed on startup reading armies[-1].nickname.
  * The recipient list was built sparse, which SessionSendChatMessage cannot
    take reliably.
  * Cursor names were parsed with a magic offset that worked for animated
    cursors and corrupted static ones, against a pattern where the dot was a
    wildcard. Now derived from the game's own cursor table.
  * Cursors were drawn centred, but the arrow textures have their tip at
    pixel (0,0), so every remote cursor sat 13px off. Hotspots are now honoured
    for the stock order cursors too.
  * Teardown wrapped a gamemain OnDestroy that does not exist; now uses
    AddOnUIDestroyedFunction.

Features
  * Splitscreen support via the live world view registry, with per-view culling
    so cursors no longer bleed across the divider.
  * Timestamped interpolation buffer with a short render delay, replacing the
    lerp-toward-latest that stuttered at the network update rate.
  * Cursor scale reflects the ratio of a teammate's zoom to yours; cursors also
    fade as your own camera pulls back, and as your mouse approaches them.
  * Build ghost showing the structure a teammate has on their cursor.
  * Selection ring while a teammate drags a selection box, with updates
    streamed throughout the drag.
  * HUD ghost: a stylised panel shown when a teammate's mouse leaves the map
    for their own interface, so a parked cursor no longer reads as them
    staring at a spot. Config.Hud.Detail switches between 'simple' and 'full'.
  * Optional replay encoding of coordinates into the commander name using
    zero-width characters. Off by default; see Config.ReplayCodec.

Performance
  * One frame callback for the whole mod instead of one per cursor, with view
    bounds, camera zoom and mouse position read once per frame.
  * Per-frame LayoutHelpers.AtLeftTopIn calls replaced with direct lazy var
    writes against a pinned anchor.
  * Scale quantised, textures and alphas only pushed on change, and no table
    allocation in the steady state for either sending or interpolation.

]]
