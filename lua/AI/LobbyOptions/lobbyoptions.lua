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
--** Read by modules/replaycodec.lua (IsEnabled). Keep the key in step with
--** OPTION_KEY there.
--******************************************************************************

AIOpts = {
    {
        default = 2,
        label = "TeamMouse: cursors in replay",
        help = "Record TeamMouse players' cursors into the replay, hidden in each commander's name, "
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
}
