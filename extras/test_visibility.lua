--******************************************************************************
--** TeamMouse -- extras/test_visibility.lua
--**
--**     lua5.1 extras/test_visibility.lua
--**
--** Regression test for a teammate's cursor showing the wrong pieces when it
--** (re)appears in your view: the selection ring while they aren't selecting,
--** the HUD ghost while they're on the map, the arrow on top of the HUD ghost,
--** a stale build ghost.
--**
--** Cause: SetVisible(true) calls Group:Show(), which the engine cascades to
--** every child -- including children RemoteCursor had hidden individually.
--** The cached flags (ringShown, hudShown, buildShown) never heard about it,
--** and the Apply* methods return early when their flag is unchanged, so the
--** wrong pieces stayed up until the teammate's state next flipped.
--**
--** mock_fa.lua's Show() cascades like the engine's, and everything here is
--** judged with Mock.IsVisible -- what would actually be drawn -- rather than
--** IsHidden(), which is only a control's own flag.
--**
--** Every way a cursor can go from hidden to shown is covered: leaving and
--** re-entering the view's bounds, and going stale then resuming.
--******************************************************************************

local Mock = dofile('extras/mock_fa.lua')

local passed, failed = 0, 0

local function Check(name, condition, detail)
    if condition then
        passed = passed + 1
        print(string.format('  pass  %s', name))
    else
        failed = failed + 1
        print(string.format('  FAIL  %s   %s', name, tostring(detail or '')))
    end
end

local function Section(title)
    print('')
    print(title)
end

--------------------------------------------------------------------------------
-- The mock itself
--
-- If Show() ever stops cascading, every check below would still pass while the
-- bug it exists to catch went unnoticed -- which is how this shipped in the
-- first place. Pin the behaviour down.
--------------------------------------------------------------------------------
Section('mock: Show() cascades like the engine')
do
    local env = Mock.CreateEnvironment({})
    local Group = env.import('/lua/maui/group.lua').Group
    local Bitmap = env.import('/lua/maui/bitmap.lua').Bitmap

    local parent = Group(env.__frame, 'parent')
    local child = Bitmap(parent)
    local grandchild = Bitmap(child)

    child:Hide()
    parent:Hide()
    Check('a hidden parent hides its subtree', not Mock.IsVisible(grandchild))

    parent:Show()
    Check('Show() re-shows a child that was hidden individually',
        Mock.IsVisible(child))
    Check('Show() reaches grandchildren too', Mock.IsVisible(grandchild))

    local vetoed = Bitmap(parent)
    vetoed.OnHide = function(self, hidden)
        if not hidden then return true end
    end
    vetoed:Hide()
    parent:Hide()
    parent:Show()
    Check('a child whose OnHide(false) returns true stays hidden',
        not Mock.IsVisible(vetoed))
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local function Armies()
    return {
        [1] = { nickname = 'Me',   human = true, color = 'ff436eee', team = 1, armyIndex = 1 },
        [2] = { nickname = 'Mate', human = true, color = 'FFe80a0a', team = 1, armyIndex = 2 },
    }
end

local function Clients()
    return {
        [1] = { name = 'Me', ['local'] = true },
        [2] = { name = 'Mate' },
    }
end

-- The mock projects world x to screen x * 2 on a 1920 wide view, so x = 100 is
-- comfortably on screen and x = 1200 (screen 2400) is far outside it.
local ON_SCREEN = 100
local OFF_SCREEN = 1200

--- One session with one teammate, and helpers to drive them.
local function NewPeer()
    local env = Mock.CreateEnvironment({
        armies = Armies(), clients = Clients(), focusArmy = 1,
        blueprints = { ueb0101 = { Display = { IconName = 'ueb0101' } } },
    })
    local SM = env.import(_G.TeamMousePath .. '/modules/teammouse.lua')
    local Config = env.import(_G.TeamMousePath .. '/modules/config.lua')
    SM.InitTeamMouse(false)
    local receive = env.__chatFuncs['TeamMouse']

    local peer = {}

    local function Frame()
        env.__clock.t = env.__clock.t + 0.2
        Mock.FindDriver(env):OnFrame(0.016)
    end

    --- The teammate sits in this state for a while: a packet and a frame, four
    --- times over, so the interpolated position has caught up with the target
    --- and every transition that state implies has had time to happen.
    ---@param x number       # world x
    ---@param onMap boolean  # false = their mouse is on their HUD
    ---@param selecting boolean
    ---@param build string | nil
    function peer.Settle(x, onMap, selecting, build)
        for _ = 1, 4 do
            receive('Mate', {
                v = Config.Protocol, a = 2, p = { x, 0, 100 }, o = 0, z = 60,
                w = onMap, s = selecting or false, b = build,
                hx = 0.5, hy = 0.5,
            })
            Frame()
        end
    end

    --- Frames with no packets, long enough for the peer to be dropped as stale.
    function peer.GoQuiet()
        local frames = math.ceil((Config.Smoothing.StaleTimeout + 1) / 0.2)
        for _ = 1, frames do Frame() end
    end

    --- What the player would actually see of this cursor right now.
    function peer.Seen()
        local c = Mock.FindCursors(env, 'WorldCamera')[1]
        return {
            cursor = Mock.IsVisible(c),
            arrow = Mock.IsVisible(c.icon),
            ring = (c.ring and Mock.IsVisible(c.ring)) or false,
            hud = (c.hud and Mock.IsVisible(c.hud)) or false,
            build = (c.buildIcon and Mock.IsVisible(c.buildIcon)) or false,
            buildFrame = (c.buildFrame and Mock.IsVisible(c.buildFrame)) or false,
        }
    end

    return peer
end

local function Describe(s)
    return string.format('cursor=%s arrow=%s ring=%s hud=%s build=%s',
        tostring(s.cursor), tostring(s.arrow), tostring(s.ring),
        tostring(s.hud), tostring(s.build))
end

--- Teammate is working the map: just the arrow, nothing else.
local function ExpectPlainArrow(name, s)
    Check(name,
        s.cursor and s.arrow and not s.ring and not s.hud
            and not s.build and not s.buildFrame,
        Describe(s))
end

--- Teammate is on their HUD: just the HUD ghost.
local function ExpectHudOnly(name, s)
    Check(name,
        s.cursor and s.hud and not s.arrow and not s.ring
            and not s.build and not s.buildFrame,
        Describe(s))
end

--------------------------------------------------------------------------------
Section('a teammate who is just on the map')
--------------------------------------------------------------------------------
do
    local peer = NewPeer()

    peer.Settle(ON_SCREEN, true, false)
    ExpectPlainArrow('first appearance shows only the arrow', peer.Seen())

    peer.Settle(OFF_SCREEN, true, false)
    Check('leaving the view hides the cursor', not peer.Seen().cursor)

    peer.Settle(ON_SCREEN, true, false)
    ExpectPlainArrow('re-entering the view shows only the arrow', peer.Seen())
end

--------------------------------------------------------------------------------
Section('HUD ghost and arrow after a trip to the HUD')
--------------------------------------------------------------------------------
do
    local peer = NewPeer()

    peer.Settle(ON_SCREEN, true, false)
    peer.Settle(ON_SCREEN, false, false)
    ExpectHudOnly('on their HUD: ghost shown, arrow gone', peer.Seen())

    peer.Settle(ON_SCREEN, true, false)
    ExpectPlainArrow('back on the map: arrow shown, ghost gone', peer.Seen())

    -- The ghost now exists and is hidden, which is the state that used to
    -- reappear when the cursor next came into view.
    peer.Settle(OFF_SCREEN, true, false)
    peer.Settle(ON_SCREEN, true, false)
    ExpectPlainArrow('re-entering after a HUD visit does not bring the ghost back',
        peer.Seen())
end

--------------------------------------------------------------------------------
Section('selection ring')
--------------------------------------------------------------------------------
do
    local peer = NewPeer()

    peer.Settle(ON_SCREEN, true, true)
    Check('ring shows while they are selecting', peer.Seen().ring)

    peer.Settle(OFF_SCREEN, true, true)
    peer.Settle(ON_SCREEN, true, true)
    Check('ring is still there after re-entering mid-selection', peer.Seen().ring,
        Describe(peer.Seen()))

    peer.Settle(ON_SCREEN, true, false)
    Check('ring goes when they stop selecting', not peer.Seen().ring)

    peer.Settle(OFF_SCREEN, true, false)
    peer.Settle(ON_SCREEN, true, false)
    Check('ring stays away after re-entering when not selecting',
        not peer.Seen().ring, Describe(peer.Seen()))
end

--------------------------------------------------------------------------------
Section('build ghost')
--------------------------------------------------------------------------------
do
    local peer = NewPeer()

    peer.Settle(ON_SCREEN, true, false, 'ueb0101')
    local s = peer.Seen()
    Check('build ghost shows while they hold a build', s.build and s.buildFrame,
        Describe(s))

    peer.Settle(OFF_SCREEN, true, false, 'ueb0101')
    peer.Settle(ON_SCREEN, true, false, 'ueb0101')
    s = peer.Seen()
    Check('build ghost survives re-entering while still building',
        s.build and s.buildFrame, Describe(s))

    peer.Settle(ON_SCREEN, true, false, nil)
    s = peer.Seen()
    Check('build ghost goes when they put it down', not s.build and not s.buildFrame,
        Describe(s))

    peer.Settle(OFF_SCREEN, true, false, nil)
    peer.Settle(ON_SCREEN, true, false, nil)
    ExpectPlainArrow('a finished build ghost stays gone after re-entering', peer.Seen())
end

--------------------------------------------------------------------------------
Section('coming back from stale')
--------------------------------------------------------------------------------
do
    -- Culling is one way to go hidden -> shown. Going quiet past the stale
    -- timeout and then resuming is another, and takes the same path.
    local peer = NewPeer()

    peer.Settle(ON_SCREEN, true, false)
    peer.Settle(ON_SCREEN, false, false)
    peer.Settle(ON_SCREEN, true, false)
    peer.GoQuiet()
    Check('a silent teammate is dropped', not peer.Seen().cursor)

    peer.Settle(ON_SCREEN, true, false)
    ExpectPlainArrow('resuming on the map shows only the arrow', peer.Seen())

    -- The reverse mistake: arrow reappearing on top of the HUD ghost.
    peer.Settle(ON_SCREEN, false, false)
    peer.GoQuiet()
    peer.Settle(ON_SCREEN, false, false)
    ExpectHudOnly('resuming on their HUD shows the ghost with no arrow over it',
        peer.Seen())
end

--------------------------------------------------------------------------------
print('')
print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then
    os.exit(1)
end
