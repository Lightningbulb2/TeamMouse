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

--- The mod's version, as reported in chat at the start of a game. Keep in
--- step with `version` in mod_info.lua (a test checks).
ModVersion = 1

--- Say in chat which version you and each teammate are on, and which
--- teammates don't have the mod (or only the old SharedMouse), once CheckDelay
--- seconds in. Local lines only.
VersionReport = {
    Enabled = true,
    CheckDelay = 5,
}

--- The panel listing the players whose cursors you can see: click a name to
--- hide or show that player's cursor for the rest of the game.
Panel = {
    Enabled = true,

    --- Where its top-left corner goes, as a fraction of the screen.
    X = 0.0,
    Y = 0.32,

    --- Start folded away to its tab.
    StartCollapsed = false,

    Depth = 60,
    BackColor = 'cc0a0e14',
}

--- Wire format version. Bump it whenever the format changes after release:
--- messages carrying a different version are ignored rather than mis-parsed,
--- so a mixed lobby degrades to "teammate's cursor doesn't show" instead of
--- erroring every beat. (The SharedMouse format is separate; see
--- legacyprotocol.lua.)
Protocol = 1

--- Writes extra detail to the game log. Leave off for normal play.
Debug = false

--==============================================================================
-- Networking
--==============================================================================
Network = {
    --- Don't send an update until the mouse has moved at least this far in
    --- world units. Roughly a third of a build square.
    MinMoveDistance = 0.1,

    --- ...but always send at least this often anyway, so that a player who
    --- parks their mouse still refreshes their state and someone who joins
    --- late gets a position. Anything that changes (movement, zoom, orders,
    --- drags, the camera) is sent at once regardless; this is only the
    --- keep-alive for a mouse at rest, and must stay well inside
    --- Smoothing.StaleTimeout.
    ForceResendInterval = 1.0,

    --- Longest wait between two runs of the send logic before the frame
    --- driver steps in, in seconds. Normally the beat sends ~10 times a
    --- second, but FAF drops a throttled beat that comes a hair early, and a
    --- slow sim spaces them out: without this, teammates' copy of your cursor
    --- stalls whenever a gap outlasts their render delay.
    MaxSendGap = 0.11,

    --- Positions are rounded to this many decimal places before sending.
    --- One decimal is well below a pixel at any usable zoom level.
    PositionPrecision = 1,

    --- Also transmit to spectators, so casters can see the team's cursors.
    --- Turn off if you would rather only your own team ever receives them.
    --- Opponents are never sent to either way.
    ShareWithObservers = true,

    --- Extra samples. The packet rate stays at the beat rate; instead the
    --- local pointer is also sampled every frame-ish between beats, and the
    --- samples gathered since the last packet ride along inside the next one,
    --- each tagged with how long before the packet it was taken. The receiver
    --- places them on its own timeline, so the interpolated cursor follows the
    --- real path of the pointer (curves, direction changes) rather than a
    --- straight line between two 100ms-apart points.
    ---
    --- This spends bandwidth (about 8 numbers per extra sample) rather than
    --- packet count. It only pays off because the receiver renders in the
    --- past by Smoothing.InterpolationDelay: an extra sample is older than
    --- the packet that carries it, so it is only useful if there is still a
    --- render delay for it to land inside. With InterpolationDelay at 0 the
    --- receiver would draw the newest sample and every extra would be stale on
    --- arrival. Keep InterpolationDelay at or above one beat (0.1s) for the
    --- full effect.
    ExtraSamples = {
        Enabled = true,

        --- Minimum time between samples taken between beats, in seconds.
        --- 1/30 gives about three extras per 100ms beat.
        Interval = 0.033,

        --- Most extras carried by one packet. Anything beyond this (a frame
        --- hitch, a lagging beat) is dropped oldest-first.
        MaxPerPacket = 8,

        --- Extras older than this at send time are not worth sending: by the
        --- time they arrive the receiver has already rendered past them.
        MaxAge = 0.5,
    },
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
    --- for a late packet. With Network.ExtraSamples on, each packet carries
    --- several samples, so this is sized for ~30 samples/second: 48 is about
    --- 1.6 seconds, the same span the old 16 covered at one sample per beat.
    BufferSize = 48,

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

    --- Opacity of a teammate's name. Never drawn fainter than their cursor,
    --- so it stays readable; your own mouse coming near fades it like the
    --- cursor (Proximity).
    LabelAlpha = 1.0,

    --- A bar in the player's colour under their name, showing how far THEY
    --- are zoomed: as wide as their name all the way in, NameBarMinWidth
    --- pixels all the way out, always centred. "All the way" is your camera's
    --- limits (the same map, so the same as theirs); NameBarZoomIn/Out are only
    --- used if those cannot be read.
    NameBar = true,
    NameBarHeight = 3,
    NameBarMinWidth = 4,
    NameBarZoomIn = 30,
    NameBarZoomOut = 600,

    --- A stroke around names and indicator text (an action, TEMPLATE), so they
    --- read over busy ground: its colour, its opacity relative to the text's,
    --- and its width in pixels. (Drawn as eight copies of the text around it:
    --- the game's text has no outline of its own.)
    TextStroke = true,
    TextStrokeColor = 'ffffffff',
    TextStrokeAlpha = 0.6,
    TextStrokeWidth = 1,

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
    MinScale = 0.8,
    MaxScale = 1.60,

    --- As *your* camera pulls back, teammates' cursors get easier to see, not
    --- harder: between FarStartZoom and FarEndZoom they grow towards fully
    --- opaque (FarAlpha), and the smallest they may be drawn rises to
    --- FarMinScale, so a teammate working close in doesn't shrink to a speck.
    FarStartZoom = 150,
    FarEndZoom = 420,
    FarAlpha = 1.0,
    FarMinScale = 1.0,
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

    --- A build template (several structures in a saved layout) shows only its
    --- first structure, with TEMPLATE above it: steady while it is in hand,
    --- flashing once placed. Seconds per flash; 0 for no flashing.
    TemplateFontSize = 12,
    TemplateFlashPeriod = 0.5,
}

--==============================================================================
-- Selection indicator
--==============================================================================
Selection = {
    Enabled = true,
    MaxDragSeconds = 20,

    --- Draw the actual rectangle a teammate is dragging
    ShowBox = true,
    BoxThickness = 2,

    --- Track the pointer during OUR OWN native map drag by tiling a grid of
    --- invisible cells over the screen and watching MouseEnter/MouseExit
    --- cross their boundaries -- GetMouseScreenPos/GetMouseWorldPos and every
    --- motion event both go silent for the length of a native drag, but a
    --- crossing between two hit-testable controls keeps firing regardless.
    DragTracking = true,

    --- Cell size in pixels. MouseEnter does not reliably carry a precise
    --- MouseX/MouseY of its own, so this cell size also doubles as the
    --- tracking resolution when it falls back to a cell's centre.
    DragCellSize = 45,

    --- Depth the overlay draws at. Below whatever real UI sits on top of it,
    --- it never wins the hit test and never sees a crossing at all -- this is
    --- what silently broke the very first version of this.
    DragOverlayDepth = 50,

    --- A teammate's selection box smaller than this many pixels in both
    --- directions is a click with a bit of jitter, not something to draw.
    MinBoxSize = 5,

    --- Tint the tracking grid so its coverage is visible (a faint wash over
    --- every cell, clear where the pointer currently is). For checking that
    --- the grid covers the whole view after a resize. Off for normal play.
    DebugGrid = false,

    --- How often, in seconds, the grid's footprint is compared with its
    --- view's, and rebuilt if the two have drifted apart (a window or UI
    --- resize). Never rebuilds mid-drag.
    GridRecheckInterval = 0.25,
}

--==============================================================================
-- Structure drag line
--==============================================================================
--
-- Dragging in build mode lays a line of structures. Teammates see that as a
-- dotted line from where the drag started to where it currently is, with the
-- cursor riding the live end.
Line = {
    Enabled = true,

    --- Dot size and spacing on screen, in pixels.
    DotSize = 4,
    DotSpacing = 12,

    --- Hard cap on dots per line. Spacing widens to fit when a long line
    --- would need more. Dots are created lazily, on the first line drawn.
    MaxDots = 40,

    --- Drags shorter than this many pixels are a plain click, not a line.
    MinLength = 8,

    --- Opacity relative to the cursor's own.
    Alpha = 0.9,

    --- Draw one framed icon for every structure the line will hold, where the
    --- game will put it, instead of a single icon beside the cursor. How many
    --- fit is worked out from the structure's skirt size, as the game lays a
    --- row out: one per skirt along the longer axis. Also used for a row
    --- once it has been placed. Icon size and frame follow
    --- Orders.BuildIconSize / Orders.BuildFrame.
    ShowStructures = true,
    --- Most icons drawn for one row. A longer row is shown with this many,
    --- spread evenly from the first structure to the last.
    MaxStructures = 24,
    --- Zoomed out, a row's icons shrink so they don't pile up on each other,
    --- down to this many pixels and no smaller.
    MinStructureIcon = 10,
}

--==============================================================================
-- Drawing (right button held with nothing selected)
--==============================================================================
--
-- The path of the pointer while a teammate draws, as a fading dotted trail
-- pinned to the map.
Draw = {
    Enabled = true,

    --- New trail point every time the pointer has moved this far, world units.
    MinStep = 1.5,

    --- Points kept. The oldest go first.
    MaxPoints = 100,

    --- Dots that draw the trail (created on first use), their size and spacing
    --- on screen in pixels. Spacing widens to keep the whole trail in the pool.
    MaxDots = 80,
    DotSize = 3,
    DotSpacing = 8,

    --- Seconds the finished trail takes to fade away once the button is up.
    FadeTime = 2.0,

    --- A stroke shorter than this many pixels on screen is a click.
    MinLength = 8,
}

--==============================================================================
-- Actions
--==============================================================================
--
-- Stop, toggling repeat build, and pausing or resuming units don't happen
-- anywhere on the map. When a teammate does one, a short label ("STOP",
-- "REPEAT ON", "PAUSED", ...) shows by their cursor and fades.
Actions = {
    Enabled = true,

    --- Also send them. Off: see teammates' without showing your own.
    Share = true,

    --- Seconds shown: solid for FadeHold, then fading out.
    Lifetime = 1.6,
    FadeHold = 0.6,

    --- Pixels above the tip of the arrow.
    OffsetY = 18,

    FontSize = 12,

    --- Most actions sent in one packet. Only the last is shown.
    MaxPerPacket = 4,
}

--==============================================================================
-- Right-click orders
--==============================================================================
--
-- When a player right-clicks to order their selected units somewhere, allies
-- see a marker fade out at the destination, in that player's colour, with the
-- order's own cursor icon when it is something other than a plain move. A
-- right-drag (a formation line) shows the line as well.
--
-- Sent once, as part of the next packet, so it costs nothing while nobody is
-- issuing orders. The wire carries positions only: it never says which units
-- were selected or what they are.
Orders = {
    Enabled = true,

    --- Also send them. Turn off to receive without ever revealing your own.
    Share = true,

    --- Show upgrades: the upgraded building's icon, in a gold frame, on the
    --- building being upgraded.
    ShowUpgrades = true,
    UpgradeColor = 'ffffc020',
    --- Structures you selected are watched this many seconds after, at most
    --- this many, for an upgrade starting (however it was ordered).
    UpgradeWatchSeconds = 20,
    UpgradeWatchMax = 40,

    --- Seconds a marker stays up: solid for the first FadeHold of it, then
    --- fading to nothing.
    Lifetime = 2.0,
    FadeHold = 0.6,

    --- Most markers alive per teammate per view at once. The oldest is
    --- reused when a new one arrives and all slots are taken.
    MaxMarkers = 4,

    --- Most orders carried by one packet (shift-queued clicks in one beat).
    MaxPerPacket = 4,

    MarkerSize = 12,
    IconSize = 24,

    --- Orders given by left-clicking in an order mode -- patrol, attack-move,
    --- reclaim, and so on -- show the same way, with that order's own icon.
    ShowModeOrders = true,

    --- A teammate dragging one of their orders to a new spot (Shift shows
    --- them; grab one and move it): the order's icon moves with their hand,
    --- with a line back to where it was, and lands like a new order.
    ShowGrabs = true,
    --- A drag is only taken for a grab if the hand shows within this many
    --- pixels of where it began: a box drag that passes over an order later
    --- (Shift shows them) stays a box.
    GrabStartPixels = 12,

    --- Structures a teammate places show the same way: the structure's icon
    --- on the spot, framed in their colour (a row of them, with its line).
    ShowBuilds = true,
    --- Only show a structure once the game has actually issued its build
    --- order. A placement the game refuses (a bad spot, overlapping another
    --- building, ...) issues nothing, and then nothing is shown. Needs the
    --- hook in hook/lua/ui/game/commandmode.lua; without it (or until the hook
    --- has seen any command at all this session) every placement is shown.
    BuildConfirm = true,
    --- Seconds after the release to wait for the game's build orders before
    --- deciding the placement failed.
    BuildConfirmTimeout = 0.5,
    --- Once build orders have started arriving, how long a lull means the
    --- whole row has arrived. (They come together, as one burst.)
    BuildSettle = 0.05,
    BuildIconSize = 28,
    BuildFrame = 2,

    --- Dots along a formation line. Same look as the structure line.
    MaxLineDots = 24,

    --- A right-drag shorter than this many world units is a click.
    MinDragWorld = 2,

    --- Seconds a right-press may stay open before it is abandoned.
    MaxPressSeconds = 20,

    --- The pointer can only be followed during a native drag through the
    --- tracking grid (see engine-gotchas.md): it is the one thing that keeps
    --- reporting while the engine freezes everything else. So the grid has to
    --- stay up for the length of a right press if teammates are to see where
    --- it goes. Whether that is safe depends on what the press is:
    ---
    --- TrackDrawing: right press with nothing selected (drawing). There is no
    --- formation to cancel, so the grid stays up and the pointer and the
    --- stroke are shared. If the game's own drawing stops working with this on,
    --- turn it off: teammates then see the pointer stand still while you draw.
    TrackDrawing = true,

    --- A right press with units selected (an order, a formation) always lifts
    --- the grid: a grid under a held formation cancels it the moment the
    --- pointer crosses a cell. Teammates get the finished line on release.

    --- The native formation line only appears once the button has been held
    --- for a moment (the order itself has a delay). Ours follows it: the line
    --- is not shown to teammates, and a right-drag is not announced as a
    --- formation, until the button has been down this long.
    LineDelay = 0.5,

    --- Show the line of a right-drag (a formation) to teammates while it is
    --- being drawn, and keep it up after the release until the order has
    --- actually reached the sim -- then drop it, since from that point the
    --- game's own feedback (the units moving, their command lines) takes over.
    ShowLiveLine = true,

    --- How the sender decides that its order has reached the sim: the command
    --- queue of the first selected unit stops looking the way it did at the
    --- press. Whichever comes first of that and this many seconds, the order
    --- is reported as applied.
    ApplyTimeout = 0.8,

    --- Receiver-side backstop for the same thing: the line goes after this
    --- long even if no "applied" report ever arrives (a lost packet, say).
    PreviewMax = 1.5,
}

--==============================================================================
-- HUD ghost
--==============================================================================
--
-- When a teammate's pointer leaves the map for their own interface, their
-- cursor is swapped for a small picture of the interface, centred on the spot
-- they are pointing at, so it reads as "clicking buttons" rather than "staring
-- at that spot on the map".
--
Hud = {
    Enabled = true,

    --- Width of the panel in pixels.
    Width = 148,

    --- Height is derived from Width by this ratio; roughly 16:10 so it reads
    --- as a screen regardless of anyone's actual resolution.
    AspectRatio = 0.625,

    Alpha = 0.8,

    --- Keep the panel this many pixels inside the view edge, so a teammate
    --- working near the screen border doesn't push it out of sight.
    EdgePadding = 8,

    --- While a player's pointer is on their interface, keep sending the map
    --- position behind it (the world point under the pointer, seen through
    --- their camera), so their ghost travels across the map with the pointer.
    --- When off, the ghost parks where they last touched the map.
    ---
    --- This is sender-side only and does not change the wire format. It relies
    --- on UnProject, whose coordinate convention is checked against
    --- GetMouseWorldPos whenever the pointer rests on the map; if the two do
    --- not agree, this quietly stays off and the ghost parks as before.
    FollowPointer = true,

    --- The pointer's position on the interface, as a fraction of the screen,
    --- moving further than this between two samples is a jump (hovering one
    --- side of the UI, then the opposite side) and not a slide: the image
    --- steps to the new spot instead of sliding across, and the ghost fades
    --- in again there. Also used for the ghost when entering the interface,
    --- which always steps into place.
    JumpDistance = 0.3,

    --- Opacity change per second as the ghost fades in on reaching the
    --- interface and out on leaving it.
    FadeSpeed = 8.0,
}

--==============================================================================
-- Teammates' selections
--==============================================================================
--
-- The units each teammate has selected get a light blue box, so you can see
-- what they are working with (your own selection keeps the game's white).
-- Drawn by the game (UI_DrawRect), sized in pixels whatever the zoom.
--
TeamSelection = {
    --- Send your selection, and show theirs.
    Enabled = true,
    --- Most unit ids sent (and boxes drawn) for one player.
    MaxSend = 60,
    --- Resend it this often anyway, in seconds; a change is sent at once.
    ResendInterval = 5,
    --- Very faint (a quarter opaque), so it does not get in the way.
    Color = '4066ccff',
    --- Each box is the unit's size (the biggest of its skirt, footprint and
    --- body: a factory's whole pad) plus Margin world units, but never
    --- smaller on screen than IconSize pixels (about a strategic icon), so
    --- zoomed out the boxes stay icon sized rather than shrinking to dots.
    Margin = 0.6,
    IconSize = 16,
    --- The ids go when the selection changes, with where each unit is at that
    --- moment. An observer (or a replay) looks the units up by id and tracks
    --- them; a player in a live game cannot look a teammate's units up (an
    --- engine rule), so their boxes show where the units were when selected
    --- and fade like any other marker (Orders.FadeHold / Lifetime).
    SendPositions = true,
    --- Two boxes whose centres are closer than this share of the bigger one's
    --- size are drawn as one (units bunched up, zoomed out).
    MergeWithin = 0.5,
    --- More selected than MaxSend: rectangles round the bunches instead of a
    --- box each, at most MaxRects of them. Units are grouped in cells of
    --- ClusterCell world units, the cells doubling (up to ClusterMaxCell)
    --- while that still leaves too many; at most MaxCluster units are looked
    --- at. Shown where they were, fading, like live boxes.
    MaxRects = 60,
    ClusterCell = 12,
    ClusterMaxCell = 96,
    MaxCluster = 500,
    --- UI_DrawRect's position is taken as the square's corner, so each box is
    --- moved back by half its size to sit centred on the unit. (If boxes sit
    --- off the units by half their size, set this false.)
    RectAnchoredAtCorner = true,
    --- Line width in pixels (UI_DrawRect takes world units; converted).
    Thickness = 3,
}

--==============================================================================
-- Clicks
--==============================================================================
--
-- A ring pulses out from the tip of a teammate's cursor when a left click of
-- theirs selects something (not drags, not clicking the ground, not the
-- right button), in their colour. Drawn by the game (UI_DrawCircle), sized in
-- pixels whatever the zoom.
--
ClickPulse = {
    --- Send your clicks, and show theirs.
    Enabled = true,
    --- Seconds a pulse lasts, and how wide it grows, in pixels.
    Duration = 0.45,
    Radius = 22,
    --- Line width in pixels (UI_DrawCircle takes world units; converted).
    Thickness = 1.5,
    --- Several clicks in one packet: this many seconds apart.
    Stagger = 0.08,
    --- A click moves no more than this many pixels between press and release
    --- (more is a drag), and counts if the selection changes within this many
    --- seconds of it.
    MaxMove = 5,
    SelectWindow = 0.5,
}

--==============================================================================
-- Teammates' views
--==============================================================================
--
-- The outline of what a teammate's camera sees, drawn on the map in their
-- colour, for each teammate whose "view" box is ticked in the TeamMouse panel.
-- Zooming in, it thickens and fades a little. Four lines, drawn by the game
-- (UI_DrawLine).
--
Viewport = {
    --- Send your own view's outline (its four corners on the map) to
    --- teammates, for them to show if they want to. Only when it moves.
    Share = true,

    --- Whether each player's "view" box starts ticked.
    Show = false,

    --- Line thickness as UI_DrawLine takes it (FAF's own painting uses 0..1;
    --- 0 is its thinnest), zoomed out and zoomed in.
    Thickness = 0.5,
    NearThickness = 2,

    --- Zooming in, from this fraction of the way in to this one, the lines
    --- thicken to NearThickness and fade to NearAlpha.
    NearStart = 0.35,
    NearEnd = 0.85,
    NearAlpha = 0.2,

    --- Resend your outline when a corner has moved this far, in world units.
    MinChange = 1,

    --- ...and, with the camera still, refresh it this often anyway (it is the
    --- largest part of a packet, and cannot have changed).
    ResendInterval = 5,
}

--==============================================================================
-- Following a player (replays and observers)
--==============================================================================
--
-- Watching a replay, or observing a live game, the panel's "follow" box on a
-- player makes your camera follow theirs: where they look, how far in, at
-- what angle.
--
Follow = {
    Enabled = true,

    --- In a replay, while you follow a player, select what they select.
    CopySelection = true,

    --- How quickly your camera catches up with theirs: the share of the way
    --- it moves each second is about 1 - e^-Rate. Higher is tighter but
    --- shows their camera's updates as small steps; lower is smoother but
    --- trails behind.
    Rate = 8,
}

--==============================================================================
-- Replays
--==============================================================================
--
-- Cursors travel to teammates over chat, which is NOT recorded into the
-- replay. So, when the game has it on, every packet teammates are sent is also
-- sent into the sim, which is: the replay then has everything a teammate saw
-- (position, drags, orders, structures, actions), and plays it back through
-- the same code. See modules/replaycodec.lua.
--
-- On or off for the whole game is the host's lobby option "TeamMouse: cursors
-- in replay" (off unless the host turns it on). Enabled below only decides for
-- a game without that option.
--
-- Costs:
--
--   * Replay size: a packet each time one goes out (about ten a second while
--     the mouse moves, none while it rests), from each player running the mod.
--   * Everything in the sim reaches every player's interface, enemies too:
--     while this is on, a mod on an opponent's side could read the cursor as
--     it happens.
--
ReplayCodec = {
    --- For a game without the lobby option only.
    Enabled = false,

    --- Either half on its own: record without playing back, or the reverse.
    Write = true,
    Read = true,

    --- How cursors look when watching a replay. Nobody is playing, so there is
    --- nothing for them to get in the way of: they are more opaque, larger,
    --- and don't fade near your own pointer.
    CursorAlpha = 1.0,
    CursorScale = 1.2,
}
