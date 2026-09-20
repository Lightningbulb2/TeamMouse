--******************************************************************************
--** TeamMouse -- modules/config.lua
--**
--** Every tunable value and feature flag lives here. Nothing else in the mod
--** should contain a magic number.
--**
--** Anything under Network or Protocol MUST match across every player in the
--** game. Everything else is purely local and can be changed freely without
--** desyncing the display.
--******************************************************************************

--- Chat identifier. gamemain.ReceiveChat dispatches on this, so it must be
--- unique across every mod in the game and identical for every player.
ChatIdentifier = 'TeamMouse'

--- Bumped whenever the wire format changes. Messages carrying a different
--- version are ignored rather than mis-parsed, so mixed lobbies degrade to
--- "teammate's cursor doesn't show" instead of erroring every beat.
Protocol = 5

--- Writes extra detail to the game log. Leave off for normal play.
Debug = false

--==============================================================================
-- Networking
--==============================================================================
Network = {
    --- Throttle the beat callback to ~10 updates/second. Without this the
    --- callback fires on every sim beat, which at +10 sim speed or during
    --- replay fast-forward is a great deal of redundant traffic.
    Throttle = false,

    --- Don't send an update until the mouse has moved at least this far in
    --- world units. Roughly a third of a build square.
    MinMoveDistance = 0.1,

    --- ...but always send at least this often anyway, so that a player who
    --- parks their mouse still refreshes their state (zoom, order, flags) and
    --- so that someone who joins the view late gets a position.
    ForceResendInterval = 0.5,

    --- Positions are rounded to this many decimal places before sending.
    --- One decimal is well below a pixel at any usable zoom level.
    PositionPrecision = 1,

    --- Also transmit to spectators, so casters can see the team's cursors.
    --- Turn off if you would rather only your own team ever receives them.
    --- Opponents are never sent to either way.
    ShareWithObservers = true,
}

--==============================================================================
-- Motion smoothing
--==============================================================================
Smoothing = {
    --- Render remote cursors this many seconds in the past. Updates arrive
    --- about every 100ms with jitter, so holding a small buffer lets us
    --- interpolate between two real samples instead of chasing the newest one.
    --- Raise if cursors stutter, lower if they feel laggy.
    InterpolationDelay = 0.13,

    --- How many samples to keep. Needs to cover InterpolationDelay with room
    --- for a late packet; 16 samples is about 1.6 seconds.
    BufferSize = 16,

    --- If two consecutive samples are further apart than this (world units),
    --- treat it as a jump rather than movement and snap instead of sliding
    --- the cursor across the map.
    SnapDistance = 540,

    --- Seconds without an update before a cursor is considered stale and
    --- faded out entirely.
    StaleTimeout = 5.0,

    --- Alpha crossfade rate for mode changes (world <-> HUD), per second.
    FadeSpeed = 6.0,
}

--==============================================================================
-- Appearance
--==============================================================================
Appearance = {
    --- Size of the coloured arrow textures in textures/cursors. These are
    --- 26x26 with the arrow tip at pixel (0,0).
    ArrowSize = 26,
    ArrowHotspotX = 0,
    ArrowHotspotY = 0,

    --- Size the stock game order cursors are drawn at. The real ones are
    --- 32x32; their hotspots come from cursordata.lua.
    OrderIconSize = 32,

    ShowLabels = true,
    LabelSize = 11,
    LabelOffset = 3,

    --- Base opacity before zoom and proximity fading are applied.
    BaseAlpha = 0.85,

    --- Don't bother pushing a new alpha to the engine for changes smaller
    --- than this. Avoids a pile of redundant SetAlpha calls every frame.
    AlphaEpsilon = 0.02,

    --- Icon scale is quantised to this step before being applied, so that a
    --- slow zoom doesn't trigger a re-layout on every single frame.
    ScaleQuantum = 0.05,

    --- Extra pixels beyond the view edge before a cursor is culled. Keeps a
    --- cursor from popping as it crosses the splitscreen divider.
    CullMargin = 48,
}

--==============================================================================
-- Zoom response
--==============================================================================
Zoom = {
    Enabled = true,

    --- Remote cursors are scaled by (theirZoom / yourZoom) ^ Exponent.
    --- A teammate zoomed further out than you draws larger, because they are
    --- working over a wider area than your view covers, and vice versa.
    --- Exponent softens the effect; 1.0 would be literal, 0 disables it.
    Exponent = 0.5,
    MinScale = 0.55,
    MaxScale = 1.60,

    --- Independently of the above, fade cursors out as *your* camera pulls
    --- back, so a fully zoomed out strategic view doesn't fill with icons.
    FadeStartZoom = 150,
    FadeEndZoom = 420,
    MinZoomAlpha = 0.25,
}

--==============================================================================
-- Proximity fading
--==============================================================================
Proximity = {
    --- Fade a remote cursor when your own mouse gets near it, so it never
    --- sits on top of the thing you are trying to click.
    Enabled = true,

    --- Screen pixels. Full fade at 0, no fade at or beyond this distance.
    FadeRadius = 110,
    MinAlpha = 0.12,
}

--==============================================================================
-- Build ghost
--==============================================================================
Build = {
    --- Show what a teammate currently has queued on their cursor in build
    --- mode, as the unit's build icon with a ghost frame around it.
    Enabled = true,

    IconSize = 30,

    --- Offset from the cursor hotspot, so the icon sits beside the arrow
    --- rather than under it.
    OffsetX = 16,
    OffsetY = 10,

    --- The icon is drawn at this fraction of the cursor's current alpha.
    GhostAlpha = 0.72,

    --- Thickness in pixels of the coloured frame that marks it as a ghost
    --- rather than a real placed building.
    FrameThickness = 2,
    FrameAlpha = 0.9,
}

--==============================================================================
-- Selection indicator
--==============================================================================
Selection = {
    --- Show a ring around a teammate's cursor while they are dragging a
    --- selection box, and keep transmitting throughout the drag.
    Enabled = true,

    RingSize = 38,
    RingAlpha = 0.65,

    --- Ring pulse in cycles per second. 0 for a static ring.
    PulseRate = 1.4,
    PulseDepth = 0.18,

    --- Safety valve: a drag lasting longer than this is assumed to have had
    --- its ButtonRelease consumed by something else, and is cleared.
    MaxDragSeconds = 20,
}

--==============================================================================
-- HUD ghost
--==============================================================================
--
-- When a teammate's mouse leaves the world and moves onto their own interface,
-- the last world position they were over becomes meaningless -- they aren't
-- pointing at it any more, they're clicking a button. Previously the cursor
-- just froze there, which reads as "my teammate is staring at that spot".
--
-- Instead we freeze the position but swap the cursor for a small stylised
-- panel showing roughly where on their screen they are. It is deliberately
-- an impression of a HUD, not a copy of one: we cannot see another client's
-- framebuffer, and transmitting one would be absurd. The point is only to
-- make it unambiguous that they are in their interface, not on the map.
--
Hud = {
    Enabled = true,

    --- 'simple' -- screen outline, top resource strip, bottom command band,
    ---             minimap block, and the cursor dot. Reads clearly at a
    ---             glance and costs six bitmaps.
    --- 'full'   -- adds the build grid, the order button row, the top-right
    ---             score panel and the side panels. Closer to the real
    ---             layout, about eighteen bitmaps per teammate per view.
    Detail = 'full',

    Width = 148,

    --- Height is derived from Width by this ratio; roughly 16:10 so it reads
    --- as a screen regardless of anyone's actual resolution.
    AspectRatio = 0.625,

    Alpha = 0.8,

    --- Panel and accent colours. The cursor dot always uses the player's
    --- army colour so you can still tell teammates apart.
    BackColor = 'aa0a0e14',
    EdgeColor = 'cc8496a8',
    PanelColor = 'cc26313d',
    DotSize = 5,

    --- Keep the panel this many pixels inside the view edge, so a teammate
    --- working near the screen border doesn't push it out of sight.
    EdgePadding = 8,
}

--==============================================================================
-- Replay encoding (experimental)
--==============================================================================
--
-- Mouse traffic is sent over the chat channel, which is NOT recorded into the
-- replay file. This feature smuggles the coordinates into the commander's
-- custom name using zero-width Unicode characters, which IS recorded, so that
-- replays can play back mouse activity afterwards.
--
-- It is off by default and you should understand the costs before enabling:
--
--   * It renames the ACU through the sim command path at the send rate. That
--     is real sim traffic and real replay growth for every player running it.
--   * Custom names render as green text above the unit. Zero-width characters
--     should be invisible, but font handling is not guaranteed and a client
--     may render boxes.
--   * It overwrites the nickname that gamemain.OnFirstUpdate puts on the ACU.
--   * Reading back during playback needs the commander object. In a replay we
--     can only reliably reach the focused army's avatar, plus whatever
--     hook/unitview.lua has cached from units you have moused over, so
--     coverage is partial.
--
-- The codec itself is self-contained and round-trip tested; enabling this only
-- changes whether teammouse.lua calls into it.
--
ReplayCodec = {
    --- Master switch. Set true to write coordinates into the commander name
    --- during live play and to read them back during replay playback.
    Enabled = true,

    --- Write side only. Lets you record without paying the playback polling
    --- cost, or vice versa.
    Write = true,
    Read = true,

    --- Marker prefixed to the encoded payload so we never mistake an ordinary
    --- custom name (or the nickname the base game sets) for our data.
    Marker = 'SM:',

    --- How often to poll commanders during replay playback, in seconds.
    PollInterval = 0.1,

    --- Writes are rate limited independently of the send loop, because this
    --- one costs sim bandwidth rather than chat bandwidth.
    WriteInterval = 0.1,
}
