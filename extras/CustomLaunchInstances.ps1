param (
    [int]$players = 2,  # Default to 2 instances (1 host, 1 client)
    [string]$map = "/maps/setons_clutch_-_faf_version.v0004/setons_clutch_-_faf_version_scenario.lua",  # Default map: Seton's Clutch
    [int]$port = 15000,  # Default port for hosting the game
    [int]$teams = 2,  # Default to two teams, 0 for FFA
    [switch]$toLobby, # launches into custom lobby
    [switch]$keepOpen # Keeps the command prompt window open after startup if specified
)

# ==========================================
# MOD INJECTION LOGIC (Game.prefs)s
# ==========================================
# Define ALL the Mod UIDs you want active here.
#
#"mouse-1-0-0",
#"reui-1.2.0",
#"reui-actionspanel-1.1.3",
#"ReUI.Construction-1.1.1",
#"reui-economy-1.2.0",
#"missile-panel-v3",
#"reui-reclaim-1.2.1",
#"reui-score-1.2.3",
#
$targetMods = @(
    "TeamMouseV1"
    "SimSpeedBalancerUIV20"
)

$prefsPath = Join-Path $env:LOCALAPPDATA "Gas Powered Games\Supreme Commander Forged Alliance\Game.prefs"
$backupPrefsPath = "$prefsPath.bak"

if (Test-Path $prefsPath) {
    # Backup the clean prefs file
    if (-not (Test-Path $backupPrefsPath)) {
        Copy-Item -Path $prefsPath -Destination $backupPrefsPath
    }

    $prefsContent = Get-Content $prefsPath -Raw

    # Build the mod block dynamically
    $newModBlock = "active_mods = {`r`n"
    foreach ($mod in $targetMods) {
        $newModBlock += "            ['$mod'] = true,`r`n"
    }
    $newModBlock += "        }"

    # Regex to find and replace the active_mods block
    $regexExistingMods = '(?s)active_mods\s*=\s*\{.*?\}'

    if ($prefsContent -match $regexExistingMods) {
        $prefsContent = $prefsContent -replace $regexExistingMods,$newModBlock
        Set-Content -Path $prefsPath -Value $prefsContent
        Write-Host "Successfully injected target mods into Game.prefs"
    } else {
        Write-Host "WARNING: 'active_mods' block not found in Game.prefs. Launch the game normally and enable a mod first."
    }
} else {
    Write-Host "Could not find Game.prefs at $prefsPath"
}


# ==========================================
# GAME SETUP
# ==========================================

# Base path to the bin directory
$binPath = "C:\ProgramData\FAForever\bin"

# Paths to the potential executables within the base path
$debuggerExecutable = Join-Path $binPath "FAFDebugger.exe"
$regularExecutable = Join-Path $binPath "ForgedAlliance.exe"

# Check for the existence of the executables and choose accordingly
if (Test-Path $debuggerExecutable) {
    $gameExecutable =$debuggerExecutable
    Write-Output "Using debugger executable: $gameExecutable"
} elseif (Test-Path $regularExecutable) {
    $gameExecutable =$regularExecutable
    Write-Output "Debugger not found, using regular executable: $gameExecutable"
} else {
    Write-Output "Neither debugger nor regular executable found in $binPath. Exiting script."
    exit 1
}

# Command-line arguments common for all instances
$baseArguments = '/init "init_local_development.lua" /EnableDiskWatch /nomovie /debugLobby /gameoptions CheatsEnabled:true GameSpeed:adjustable Victory:sandbox'

# Add the players argument if we want to use autolobby
if (-not $toLobby) {
    $baseArguments += " /players $players"
}

# Game-specific settings
$hostProtocol = "udp"
$hostPlayerName = "HostPlayer_1"
$gameName = "MyGame"

# Array of player data to choose from
$factions = @("UEF", "Seraphim", "Cybran", "Aeon")
$clans = @("Yps", "Nom", "Cly", "Mad", "Gol", "Kur", "Row", "Jip", "Bal", "She")
$divisions = @("bronze", "silver", "gold", "diamond", "master", "grandmaster", "unlisted")
$subdivisions = @("I", "II", "III", "IV", "V")

# Get the screen resolution (for placing and resizing the windows)
Add-Type -AssemblyName System.Windows.Forms
$screenWidth = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width
$screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height

# Calculate the number of rows and columns for the grid layout
$columns = [math]::Ceiling([math]::Sqrt($players)); $rows = [math]::Ceiling($players / $columns)

# Calculate the size of each window based on the grid
$windowWidth = [math]::Max([math]::Floor($screenWidth / $columns), 1024)
$windowHeight = [math]::Max([math]::Floor($screenHeight / $rows), 768)

# ==========================================
# FUNCTIONS
# ==========================================

function Launch-GameInstance {
    param (
        [int]$instanceNumber,
        [int]$xPos,
        [int]$yPos,
        [string]$arguments
    )

    # Add window position and size arguments
    $arguments += " /position $xPos $yPos /size $windowWidth $windowHeight"

    try {
        Start-Process -FilePath $gameExecutable -ArgumentList $arguments -NoNewWindow
        Write-Host "Launched instance $instanceNumber at position ($xPos, $yPos) with size ($windowWidth, $windowHeight) and arguments:$arguments"
    } catch {
        Write-Host "Failed to launch instance ${instanceNumber}:$_"
    }
}

function Get-DivisionArgText {
    $division = $($divisions | Get-Random)
    $argText = "/division $division"
    if ($division -ne "unlisted" -and $division -ne "grandmaster") {
        $argText += " /subdivision $($subdivisions | Get-Random)"
    }
    return $argText
}

# ==========================================
# LAUNCH LOGIC
# ==========================================

if ($players -eq 1 -and -not $toLobby) {$logFile = "dev.log"
    Launch-GameInstance -instanceNumber 1 -xPos 0 -yPos 0 -arguments "/log $logFile /showlog /map $map $baseArguments"
} else {
    # --- HOST (Instance 1) ---
    $hostLogFile = "host_dev_1.log"

    # HARDCODE HOST SETTINGS HERE
    $hostFaction = "UEF"          # UEF, Cybran, Aeon, or Seraphim
    $hostTeam = "/team 3"         # Team 1 (Engine adds +1)
    $hostSpot = "/startspot 1"    # Start spot 1

    $divisionArgText = Get-DivisionArgText
    $hostArguments = "/log $hostLogFile /showlog /hostgame $hostProtocol $port $hostPlayerName $gameName $map $hostSpot /$hostFaction $hostTeam $baseArguments $divisionArgText /clan $($clans | Get-Random)"

    # Launch host game instance
    Launch-GameInstance -instanceNumber 1 -xPos 0 -yPos 0 -arguments $hostArguments

    # --- CLIENTS ---
    for ($i = 1; $i -lt $players; $i++) {

        $row = [math]::Floor($i / $columns)
        $col = $i % $columns
        $xPos =$col * $windowWidth
        $yPos = $row * $windowHeight

        $clientLogFile = "client_dev_$($i + 1).log"
        $clientPlayerName = "ClientPlayer_$($i + 1)"
        $divisionArgText = Get-DivisionArgText

        # HARDCODE SPECIFIC CLIENT SETTINGS BY INSTANCE NUMBER
        $instanceNum =$i + 1
        switch ($instanceNum) {             2 {$clientFaction = "Cybran"
                $clientTeam = "/team 3"      # Team 2
                $clientSpot = "/startspot 3"
            }
            3 {
                $clientFaction = "Aeon"
                $clientTeam = "/team 3"      # Team 2
                $clientSpot = "/startspot 5"
            }
            default {
                # Fallback for any instances beyond 3
                $clientFaction = "Seraphim"
                $clientTeam = "/team 4"      # Team 3
                $clientSpot = "/startspot $instanceNum"
            }
        }

        $clientArguments = "/log $clientLogFile /joingame $hostProtocol localhost:$port $clientPlayerName $clientSpot /$clientFaction $clientTeam $baseArguments $divisionArgText /clan $($clans | Get-Random)"

        Launch-GameInstance -instanceNumber $instanceNum -xPos $xPos -yPos $yPos -arguments $clientArguments
    }
}

Write-Host "$players instance(s) of the game launched. Host is running at port $port."

# === NEW: Clean up Game.prefs ===
Write-Host "Waiting 10 seconds for instances to read Game.prefs..."
Start-Sleep -Seconds 10

if (Test-Path $backupPrefsPath) {
    Copy-Item -Path $backupPrefsPath -Destination $prefsPath -Force
    Remove-Item -Path $backupPrefsPath -Force
    Write-Host "CLEANUP: Restored original Game.prefs."
}

# Auto-close window unless -keepOpen flag is set
if (-not $keepOpen) {
    Stop-Process -Id $PID
}
