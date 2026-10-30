name = "TeamMouse"
uid = "team-mouse-v4"
description =
"Notice: AI was used for developing this mod. \nShow your teammates what you are doing. Shares mouse position, order cursor, build selection and drag-selections with your team, with smooth interpolation, zoom-aware scaling, and a HUD indicator \nhttps://github.com/Lightningbulb2/TeamMouse"
copyright = "Licensed under the FAF Vault License. Free to use and modify."
author = "Lightningbulb & HotCheese | KasperAUS | Eternal-"
url = "https://github.com/Lightningbulb2/TeamMouse"
icon = "/mods/TeamMouse/logo.png"
version = 5
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


v3:

• add drag support for the UI panel to change where on your screen it is.

• the player panel shows in solo games while TeamMouse's options window is open, so it can be placed.

• fix UID capitalization causing deselect every game launch

• truncate names and hover for full names in the UI panel

V4:

• Fix: upgrade ReUI support to latest version

• add coaching: click a player's name in the panel to follow their view (teammates too, not just observers and replays); click it again to go back to where you were looking, or scroll to break free

• while following someone, your clicks stay your own (select, build, order your units); a right-drag with nothing selected draws straight on their screen instead (over their interface, never in the game or the replay), fading after a second, and a single right click there is a ghost order

• add TeamMouse panel hovering for versions

• observers are listed in the panel now that they can follow and coach players

• lobby option "TeamMouse: observers watch": keep observers to one team (default any)

• a dead teammate has a red line through their name, on the panel and on their cursor; "show dead cursors" box (ReUI option to start it ticked)

• less garbage per frame receiving teammates' cursors (about a third of before), and a lighter panel

• following someone, their panel's ticks show as green outlines round your boxes (not "all"; their box for you round their own row)

• observers: a "coach" box per player sends your cursor to that player alone, copies their selection, and draws your map drawings on their map, fading after 2 seconds

• coaching observers: focus locks to the coached army, and your selection boxes, build drags, placements and move orders show for the player as a teammate's would (following them too: your cursor shows only while you hold a building, drag, click or draw, unless "Always show a following coach's cursor" is on)

• observers coach whoever they last followed (ReUI option, on by default)

• observers' build placements, move orders and upgrades never reach the game (no "trying to cheat" message), and neither do their keyboard orders (stop, pause, fire states, ...); placements and orders still go to the coached player, and show on the observer's own screen

• teammates' drawings show while they draw as solid lines on the map, like the game's own, instead of dots

V5:

• add split screen support for coaching

• following goes on your second monitor if you have one (else the main view, or the splitscreen)

• Shift-click a second name to follow two players side by side: the splitscreen opens for it, or with two monitors the second one is halved (ReUI option)

• Ctrl-click a name to follow that player in splitscreen mode



]]
