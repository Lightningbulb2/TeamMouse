--******************************************************************************
--** TeamMouse -- lua/AI/LobbyOptions/lobbyoptions.lua
--**
--** FAF's lobby (lua/ui/lobby/lobby.lua, ImportModAIOptions) reads AIOpts from
--** this path in every installed mod and lists them with the other game
--** options; the host chooses, and the choice reaches every player as
--** SessionGetScenarioInfo().Options[key] -- and is kept in the replay. An
--** option from a mod the host does not have enabled is dropped at launch, and
--** then Config.ReplayCodec.Enabled decides as before.
--**
--** Read by modules/replaycodec.lua (IsEnabled) and modules/observerteam.lua
--** (Forced). Keep the keys in step with OPTION_KEY there.
--******************************************************************************

AIOpts = {
    {
        default = 2,
        label = "TeamMouse: cursors in replay",
        help = "Record TeamMouse players' cursors into the replay, through the sim, "
            .. "so they can be watched back. Adds a small amount of replay data.",
        key = 'TeamMouseReplay',
        values = {
            {
                text = "Off",
                help = "Cursors are only shared live, and are not in the replay",
                key = 'off',
            },
            {
                text = "On",
                help = "Cursors are recorded into the replay",
                key = 'on',
            },
        },
    },
    {
        default = 1,
        label = "TeamMouse: observers watch",
        help = "Keep observers to one team: their view stays on that team's armies, and they can only "
            .. "follow and coach its players (players on other teams send them nothing).",
        key = 'TeamMouseObserverTeam',
        values = {
            {
                text = "Any team",
                help = "Observers can watch every team",
                key = 'any',
            },
            {
                text = "Team 1",
                help = "Observers only watch team 1: their view is kept on it, and only its players are listed",
                key = '1',
            },
            {
                text = "Team 2",
                help = "Observers only watch team 2: their view is kept on it, and only its players are listed",
                key = '2',
            },
            {
                text = "Team 3",
                help = "Observers only watch team 3: their view is kept on it, and only its players are listed",
                key = '3',
            },
            {
                text = "Team 4",
                help = "Observers only watch team 4: their view is kept on it, and only its players are listed",
                key = '4',
            },
            {
                text = "Team 5",
                help = "Observers only watch team 5: their view is kept on it, and only its players are listed",
                key = '5',
            },
            {
                text = "Team 6",
                help = "Observers only watch team 6: their view is kept on it, and only its players are listed",
                key = '6',
            },
            {
                text = "Team 7",
                help = "Observers only watch team 7: their view is kept on it, and only its players are listed",
                key = '7',
            },
            {
                text = "Team 8",
                help = "Observers only watch team 8: their view is kept on it, and only its players are listed",
                key = '8',
            },
        },
    },
}
