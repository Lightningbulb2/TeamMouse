name = "TeamMouse"
uid = "TeamMouseV2"
description =
"Notice: AI was used for developing this mod. \nShow your teammates what you are doing. Shares mouse position, order cursor, build selection and drag-selections with your team, with smooth interpolation, zoom-aware scaling, and a HUD indicator \nhttps://github.com/Lightningbulb2/TeamMouse"
copyright = "Licensed under the FAF Vault License. Free to use and modify."
author = "Lightningbulb & HotCheese | KasperAUS | Eternal-"
url = "https://github.com/Lightningbulb2/TeamMouse"
icon = "/mods/TeamMouse/logo.png"
version = 2
exclusive = false

ui_only = true

-- Optional: with ReUI installed, TeamMouse's settings show in its options
-- window (Main.lua, Options.lua, modules/options.lua). Not required.
ReUI = "TeamMouse=1.0.0"

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


V2:

• Add: ReUI integration ported from HotCheese fork

• Add: removed chat version reporting and moved it to the UI panel

• Add: only show cursor toggles in the replay for people that actually have data encoded to their commander

• Add: Hud hovered indicator is now colored based on their faction

• Add: ability to break free from following player in replay by scrolling quickly

---

• Change: building upgrade icons now have a gold diamond background instead of making them completely gold

• Change: following a player in the replay prefers the larger axis of their view (to deal with aspect ratio differences)

---

• Fix upgrades flashing again when selecting them after a period of time

• Fix click pulse not displaying when directly swapping between selections rather than deselecting first.

• Fix frozen mouse when teammate's box selection is disabled.


]]
