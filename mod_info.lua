name = "TeamMouse"
uid = "TeamMouseV1"
description =
"Notice: AI was used for developing this mod. \nShow your teammates what you are doing. Shares mouse position, order cursor, build selection and drag-selections with your team, with smooth interpolation, zoom-aware scaling, and a HUD indicator \nhttps://github.com/Lightningbulb2/TeamMouse"
copyright = "Licensed under the FAF Vault License. Free to use and modify."
author = "Lightningbulb & HotCheese | KasperAUS | Eternal-"
url = "https://github.com/Lightningbulb2/TeamMouse"
icon = "/mods/TeamMouse/logo.png"
version = 1
exclusive = false

ui_only = true

before = { "CHEESEBERRY-a1e2-c4t4-scfa-ssbmod-v0200" } -- run before Supreme Scoreboard breaks the UI loading in co-op missions

--[[

V1:

Upgrades over shared mouse:

• show Teammate building placements

• show Teammate dragbox selection and current unit selection

• show Teammate orders

• show when Teammate is hovering HUD

• Teammate cursor zoom indicator

• better zoom scaling and opacity so things are visible, but not in the way

• take extra samples between ticks for smoother movement

• full replay support that allows you to see everyone's actions

• (optional) show  camera perspective of your teammates

• (optional) follow player perspective and selections --- (for observer and replays)

• show drawings earlier before it's applied to the simulation

]]
