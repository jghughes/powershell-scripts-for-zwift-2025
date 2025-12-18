<#
.SYNOPSIS
    Analyzes Zwift log files to identify connection problems and other issues.

.DESCRIPTION
    Parses Zwift application log files, filters relevant connectivity events,
    and generates a diagnostic report distinguishing between clean rides
    and problematic rides with connection issues. Detects seamless server
    reconnections vs disruptive disconnects.
    
    Uses a hybrid workflow: reads from incoming folder, writes to processed folder
    organized by date. Original log file is copied (not moved) to processed folder
    alongside filtered and excluded outputs, allowing reprocessing if needed.

.PARAMETER ZwiftLogFileName
    Filename of the Zwift log file to analyze (e.g., "Log_2025-12-15_clean_ride.txt").
    The file must exist in the incoming folder: C:\Users\johng\holding_pen\StuffForZwiftLogs\incoming

.PARAMETER OutputDirectoryPath
    Optional output directory path. Defaults to processed folder with date subfolder (processed/YYYY-MM-DD/).
    Original log file is copied to this location alongside filtered and excluded outputs.

.PARAMETER Devices
    Optional array of device names/patterns to include in analysis. If specified, only these devices will be tracked.
    If not specified, all BLE devices in the log will be auto-detected.
    Examples: "Wahoo KICKR", "Tacx Neo", "HRM", "Garmin"

.PARAMETER ExcludeDevices
    Optional array of device name patterns to exclude from analysis. Only used when auto-detecting devices.
    Useful for focusing analysis by removing devices you're not interested in.
    Examples: "HRM", "Phone", "Cadence"

.PARAMETER Version
    Displays script version information and exits.

.PARAMETER Help
    Displays this help documentation. Beginner-friendly alternative to Get-Help.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_ride.txt"
    Auto-detects all BLE devices in the log and analyzes them.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_ride.txt" -Devices "Wahoo KICKR"
    Analyzes only Wahoo KICKR trainer, ignoring other devices.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_ride.txt" -Devices "Wahoo KICKR", "HRMPro"
    Analyzes both trainer and heart rate monitor.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_ride.txt" -ExcludeDevices "HRM"
    Auto-detects all devices but excludes heart rate monitors from analysis.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_ride.txt" -Verbose
    Shows detailed progress messages explaining what the script is doing at each step.
    Educational mode - excellent for learning how log analysis works.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_ride.txt" -Debug
    Shows diagnostic decision-making process: why events are classified certain ways,
    which disconnects are seamless vs problematic, and root cause analysis logic.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_ride.txt" -Verbose -Debug
    Combines both detailed progress and diagnostic output for maximum insight.

.NOTES
    Designed for Zwift cycling application logs with BLE device connections.
    
    VERSION: 1.0.0
    LAST MODIFIED: December 17, 2025
    
    COMMON PARAMETERS:
    -Verbose : Shows educational progress messages (108 verbose statements throughout)
    -Debug   : Shows diagnostic decision-making logic (40 debug statements)
    -WhatIf  : Not applicable (script only reads files, doesn't modify originals)
    -Confirm : Not applicable (no destructive operations)
#>

# Suppress PSScriptAnalyzer warning about Write-Host usage
# JUSTIFICATION: This is an interactive console script designed for direct user interaction.
# Write-Host is appropriate here because:
#   - We need colored output for readability (progress updates, warnings, results)
#   - Script output is meant for human consumption, not pipeline processing
#   - Using Write-Information would require users to understand $InformationPreference
#   - Write-Host behavior in PS 5.0+ is stable and suitable for this use case
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [Parameter(Mandatory=$false)]
    [string]$ZwiftLogFileName,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDirectoryPath,
    
    [Parameter(Mandatory=$false)]
    [string[]]$Devices,
    
    [Parameter(Mandatory=$false)]
    [string[]]$ExcludeDevices,
    
    [Parameter(Mandatory=$false)]
    [switch]$Version,
    
    [Parameter(Mandatory=$false)]
    [switch]$Help
)

# Handle -Help parameter (beginner-friendly)
if ($Help) {
    Get-Help $PSCommandPath -Full
    exit 0
}

# Handle -Version parameter
if ($Version) {
    Write-Host "`nZwift Log Analyzer" -ForegroundColor Cyan
    Write-Host "Version: 1.0.0" -ForegroundColor Green
    Write-Host "Last Modified: December 17, 2025" -ForegroundColor Gray
    Write-Host "`nFeatures:" -ForegroundColor Yellow
    Write-Host "  - Device-agnostic BLE connection analysis"
    Write-Host "  - Seamless reconnect detection"
    Write-Host "  - Root cause problem identification"
    Write-Host "`nUsage: Get-Help .\zlog.ps1 -Full" -ForegroundColor Gray
    exit 0
}

# Validate required parameter (ZwiftLogFileName is mandatory unless -Version or -Help is used)
if (-not $ZwiftLogFileName) {
    Write-Host "`n[ERROR] Missing required parameter: ZwiftLogFileName" -ForegroundColor Red
    Write-Host "Usage: .\zlog.ps1 <LogFileName> [-OutputDirectoryPath <path>] [-Devices <names>] [-ExcludeDevices <patterns>]" -ForegroundColor Yellow
    Write-Host "       .\zlog.ps1 -Help" -ForegroundColor Yellow
    Write-Host "       .\zlog.ps1 -Version" -ForegroundColor Yellow
    Write-Host "`nFor detailed help: .\zlog.ps1 -Help`n" -ForegroundColor Gray
    exit 1
}

# ===== GLOBAL VARIABLES=====
# Default device patterns (fallback if auto-detection finds nothing)
$DEFAULT_DEVICE_PATTERNS = @(
    "Wahoo KICKR",
    "HRMPro"
)
# ===== PRODUCTION FOLDER PATHS =====
# Default locations for input and output files in production workflow
$INCOMING_FOLDER = "C:\Users\johng\holding_pen\StuffForZwiftLogs\incoming"
$PROCESSED_FOLDER = "C:\Users\johng\holding_pen\StuffForZwiftLogs\processed"

# ===== CONSTANTS =====

# WHY 5 SECONDS? This is based on real-world testing. Zwift's server can briefly disconnect
# and reconnect without disrupting the ride. Anything faster than 5 seconds is "seamless"
# to the user - like a blink you don't notice. Longer disconnects cause problems.
$SEAMLESS_RECONNECT_THRESHOLD_SECONDS = 5

# WHY THIS WEIRD VALUE? "99:99:99" is impossible as a real time (there's no 99th hour!)
# We use it as a "flag" meaning "the app never shut down during this log file"
# It's like using -1 to mean "not found" - a special value outside normal range.
$SENTINEL_TIME_MAX = "99:99:99"

# WHY CHECK NEARBY LINES? When we find a device connection, we look at the lines just
# before and after it to see if DirectConnect (Bluetooth over wired LAN) was involved.
# Think of it like checking the context of a sentence to understand its meaning.
$DIRECTCONNECT_CONTEXT_BEFORE = 10  # Lines to look before the connection event
$DIRECTCONNECT_CONTEXT_AFTER = 5    # Lines to look after the connection event

# WHY 120 SECONDS (2 MINUTES)? If a server reconnection happens within 2 minutes of a
# problem, they're probably related. It's like saying "events within 2 minutes of each
# other are part of the same incident." Adjust this based on your network conditions!
$PROBLEM_PROXIMITY_SECONDS = 120

# WHY TRUNCATE ERROR MESSAGES? Some errors are REALLY long (500+ characters) and make
# reports unreadable. We keep the first 250 chars which has all the important info.
# It's like reading a summary instead of a whole book - you get the main point!
$MAX_ERROR_DETAIL_LENGTH = 250

# Output file name fragments (constants)
$FILTERED_FRAGMENT = "filtered"
$EXCLUDED_FRAGMENT = "excluded"

# ===== FUNCTION DEFINITIONS =====
function Get-Timestamp($line) {
    if ($line -match '^\[(\d{2}:\d{2}:\d{2})\]') { return $matches[1] }
    return ""
}

function Get-LineColor($line) {
    if ($line -match "\[ERROR\]|Error receiving|Error connecting|Error shutting down|Disconnected|Timeout|Failed to connect|has new connection status: disconnected") { return "Red" }
    if ($line -match "Reconnecting|Connecting to|ConnectWFTNP|Start scanning") { return "Yellow" }
    if ($line -match "Connected|established|active|has new connection status: connected") { return "Green" }
    return "White"
}

function ConvertFrom-TimeString($timeString) {
     $parts = $timeString -split ':'
    return [int]$parts[0] * 3600 + [int]$parts[1] * 60 + [int]$parts[2]
}

function Format-Duration($seconds) {
    $hours = [math]::Floor($seconds / 3600)
    $minutes = [math]::Floor(($seconds % 3600) / 60)
    if ($hours -gt 0) {
        return "$hours hour(s) $minutes minute(s)"
    } else {
        return "$minutes minute(s)"
    }
}

function Get-TrainerInfo($logLines, $devicePatterns) {
    $trainerLines = @()
    
    # Build regex from detected device patterns to find ANY trainer
    $deviceRegex = ($devicePatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
    if (-not $deviceRegex) { return $trainerLines }  # No devices configured
    
    # Collect relevant log lines that contain trainer information
    foreach ($line in $logLines) {
        # Hardware revision
        if ($line -match '"([^"]+)" hardware revision number:' -and $matches[1] -match $deviceRegex) {
            $trainerLines += $line
        }
        # Firmware version
        elseif ($line -match '\[BLE\] "([^"]+)" firmware version:' -and $matches[1] -match $deviceRegex) {
            $trainerLines += $line
        }
        # Software version
        elseif ($line -match '\[BLE\] "([^"]+)" software version:' -and $matches[1] -match $deviceRegex) {
            $trainerLines += $line
        }
        # Serial number
        elseif ($line -match '\[ZwiftProtocol\] Device serial number:') {
            $trainerLines += $line
        }
        # Feature flags
        elseif ($line -match "\[BLE\] (?:$deviceRegex).* Features Supported:") {
            $trainerLines += $line
        }
        
        # Early exit once we have a reasonable amount of info
        if ($trainerLines.Count -ge 5) {
            break
        }
    }
    
    return $trainerLines
}

function Add-ProblemEntry($eventCollection, $formatScript) {
    $entries = @()
    foreach ($evt in $eventCollection) {
        $entry = & $formatScript $evt
        $entries += [PSCustomObject]@{ Time=$evt.Time; Entry=$entry }
    }
    return $entries
}

# ===========================
# MAIN SCRIPT EXECUTION START
#============================
# Verify incoming folder exists
if (-not (Test-Path $INCOMING_FOLDER)) {
    Write-Host ""
    Write-Host "Incoming folder does not exist: " -NoNewline -ForegroundColor Red
    Write-Host $INCOMING_FOLDER -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Options to resolve:" -ForegroundColor Cyan
    Write-Host "  1. Create the directory before running the script"
    Write-Host "  2. Verify the production folder structure is set up correctly"
    Write-Host ""
    Write-Host "Example folder creation:" -ForegroundColor Cyan
    Write-Host "  New-Item -ItemType Directory -Path `"$INCOMING_FOLDER`""
    Write-Host ""
    Write-Host ""
    Write-Host "Expected folder structure:" -ForegroundColor Cyan
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  C:\Users\johng\holding_pen\StuffForZwiftLogs\incoming\  " -NoNewline -ForegroundColor Green
    Write-Host "(log files to process)" -ForegroundColor DarkGray
    Write-Host "  C:\Users\johng\holding_pen\StuffForZwiftLogs\processed\ " -NoNewline -ForegroundColor Green
    Write-Host "(analyzed logs + filtered outputs by date)" -ForegroundColor DarkGray
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    
    throw "Incoming folder not found: $INCOMING_FOLDER"
}

# Build full path to log file in incoming folder
$ZwiftLogFilePath = Join-Path $INCOMING_FOLDER $ZwiftLogFileName

# Verify log file exists
if (-not (Test-Path $ZwiftLogFilePath -PathType Leaf)) {
    # Get list of available files in incoming folder
    $availableFiles = Get-ChildItem $INCOMING_FOLDER -File | Select-Object -ExpandProperty Name
    $fileList = if ($availableFiles) {
        ($availableFiles | ForEach-Object { "  $_" }) -join "`n"
    } else {
        "  (No files found)"
    }
    
    # Display formatted error message
    Write-Host ""
    Write-Host "Log file does not exist: " -NoNewline -ForegroundColor Red
    Write-Host $ZwiftLogFilePath -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Options to resolve:" -ForegroundColor Cyan
    Write-Host "  1. Verify the filename is correct (case-sensitive)"
    Write-Host "  2. Copy your log file to: " -NoNewline
    Write-Host $INCOMING_FOLDER -ForegroundColor Yellow
    Write-Host "  3. Use one of the available files listed below"
    Write-Host ""
    Write-Host "Example:" -ForegroundColor Cyan
    Write-Host "  .\zlog.ps1 `"Log_2025-12-15_clean_ride.txt`""
    Write-Host ""
    Write-Host ""
    Write-Host "Available files in incoming folder:" -ForegroundColor Cyan
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host $fileList -ForegroundColor Green
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    
    throw "Log file not found: $ZwiftLogFileName"
}

# Set output directory (default to processed folder with date subfolder)
if (-not $OutputDirectoryPath) {
    # Create date-based subfolder in processed folder (YYYY-MM-DD format for sorting)
    $dateFolder = Get-Date -Format "yyyy-MM-dd"
    $OutputDirectoryPath = Join-Path $PROCESSED_FOLDER $dateFolder
    
    # Create the date subfolder if it doesn't exist
    if (-not (Test-Path $OutputDirectoryPath)) {
        New-Item -ItemType Directory -Path $OutputDirectoryPath -Force | Out-Null
        Write-Verbose "Created output directory: $OutputDirectoryPath"
    }
} else {
    # If custom output path specified, verify it exists
    if (-not (Test-Path $OutputDirectoryPath)) {
        Write-Host ""
        Write-Host "Output directory does not exist: " -NoNewline -ForegroundColor Red
        Write-Host $OutputDirectoryPath -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Options to resolve:" -ForegroundColor Cyan
        Write-Host "  1. Create the directory before running the script"
        Write-Host "  2. Use the default output location (processed folder with date)"
        Write-Host ""
        Write-Host "Example with custom output directory:" -ForegroundColor Cyan
        Write-Host "  .\zlog.ps1 `"$ZwiftLogFileName`" -OutputDirectoryPath `"C:\Your\Custom\Path`""
        Write-Host ""
        throw "Output directory not found: $OutputDirectoryPath"
    }
}

# Build output file paths (numbered prefixes preserve logical sort order)
$analysisDate = Get-Date -Format "yyyy-MM-dd"  # Used for analysis date footer
$inputFileName = [System.IO.Path]::GetFileNameWithoutExtension($ZwiftLogFilePath)

$ReportPath    = Join-Path $OutputDirectoryPath ("$inputFileName`_1_report.txt")
$TimelinePath  = Join-Path $OutputDirectoryPath ("$inputFileName`_2_${FILTERED_FRAGMENT}.txt")
$ExcludedPath  = Join-Path $OutputDirectoryPath ("$inputFileName`_3_${EXCLUDED_FRAGMENT}.txt")


Write-Verbose "Reading from incoming folder: $INCOMING_FOLDER"
Write-Verbose "File: $ZwiftLogFileName"
Write-Verbose "Full path: $ZwiftLogFilePath"


# Read file line by line, count only non-blank lines
$allLines = Get-Content -Path $ZwiftLogFilePath
$allLines = $allLines | Where-Object { $_.Trim() -ne "" }

$totalLines = $allLines.Count

Write-Verbose "[OK] Successfully read $totalLines lines into memory"
Write-Verbose "  Memory used: approximately $([math]::Round($totalLines * 80 / 1MB, 2)) MB (assuming ~80 chars/line)"
Write-Verbose ""

# =================================================================================
# DEVICE PATTERN RESOLUTION (Smart Configuration)
# =================================================================================
# Determine which device patterns to use based on parameters provided

if ($Devices) {
    # EXPLICIT MODE: User specified exact devices to track
    $DEVICE_PATTERNS = $Devices
    Write-Verbose "==========================================================================="
    Write-Verbose " DEVICE MODE: Explicit (user-specified)"
    Write-Verbose "==========================================================================="
    Write-Verbose "Tracking only these devices: $($DEVICE_PATTERNS -join ', ')"
    Write-Verbose ""
} else {
    # AUTO-DETECT MODE: Scan log for BLE device connection status changes
    Write-Verbose "==========================================================================="
    Write-Verbose " DEVICE MODE: Auto-detect from log file"
    Write-Verbose "==========================================================================="
    Write-Verbose "Scanning for BLE devices with connection status changes..."
    
    # Extract device names from connection status lines
    $detectedDevices = $allLines | 
        Select-String 'Device: "([^"]+)" has new connection status' | 
        ForEach-Object { $_.Matches.Groups[1].Value } | 
        Select-Object -Unique
    
    if ($detectedDevices) {
        Write-Verbose "[OK] Found $($detectedDevices.Count) unique BLE device(s):"
        foreach ($device in $detectedDevices) {
            Write-Verbose "  - $device"
        }
        
        # Apply exclusions if specified
        if ($ExcludeDevices) {
            Write-Verbose ""
            Write-Verbose "Applying exclusion filters: $($ExcludeDevices -join ', ')"
            $beforeCount = $detectedDevices.Count
            $excludePattern = ($ExcludeDevices | ForEach-Object { [regex]::Escape($_) }) -join '|'
            $detectedDevices = $detectedDevices | Where-Object { $_ -notmatch $excludePattern }
            $afterCount = $detectedDevices.Count
            Write-Verbose "[OK] Excluded $($beforeCount - $afterCount) device(s), keeping $afterCount"
        }
        
        $DEVICE_PATTERNS = $detectedDevices
    } else {
        # Fallback to defaults if nothing detected
        Write-Verbose "[WARNING] No BLE devices detected in log file"
        Write-Verbose "   Using default patterns: $($DEFAULT_DEVICE_PATTERNS -join ', ')"
        $DEVICE_PATTERNS = $DEFAULT_DEVICE_PATTERNS
    }
    Write-Verbose ""
}

# Define search patterns (consolidated for maintainability)
$searchPatterns = @(
    # Connectivity patterns
    "\bUDP\b","\bTCP\b","\bSocket\b","\bmDNS\b","\bDirectConnect\b","\bConnectionManager\b",
    "\bWiFi\b","\bBLE\b","\bBTLE\b","\bBluetooth\b","\bANT\+\b","\bLAN Exercise Device\b",
    # Shutdown indicators
    "shutdown","gracefully","destroyed","ZWATCHDOG"
) + $DEVICE_PATTERNS  # Add resolved device patterns


# Collect filtered lines (process in-memory to avoid reading file twice)
$filtered = $allLines | Select-String -Pattern $searchPatterns |
    Where-Object {
        $line = $_.Line
        
        # -----------------------------------------------------------------------------
        # STAGE 2: High-priority exclusions (always exclude)
        # -----------------------------------------------------------------------------
        # These patterns appear THOUSANDS of times and are NEVER useful for diagnosis.
        # We check them FIRST (before doing more expensive checks) for speed.
        # Example: "advertising characteristic" appears 5000+ times per ride!
        if ($line -match "advertising characteristic|battery level:") { return $false }
        
        # -----------------------------------------------------------------------------
        # STAGE 3a: Must-include patterns (always include - user-configured device patterns)
        # -----------------------------------------------------------------------------
        # If a line mentions YOUR specific devices (Wahoo KICKR, HRM, etc.), we ALWAYS
        # keep it. These are the devices you care about! User configured at top of script.
        $devicePatternRegex = ($DEVICE_PATTERNS -join "|")
        if ($line -match $devicePatternRegex) { return $true }
        
        # Also always keep shutdown events - they tell us how the ride ended
        if ($line -match "Gracefully Shutdown|ZWATCHDOG.*Destroyed|\[OS\].*Shutdown|\[GAME\].*Shutdown|RubberbandingConfig shutdown|AutoSteeringConfig shutdown") { return $true }
        
        # -----------------------------------------------------------------------------
        # STAGE 3b: Standard exclusion filters (remove noise)
        # -----------------------------------------------------------------------------
        # These are Zwift subsystems that are noisy but not related to connection issues.
        # [CoffeeStop] = in-game rest stops, [STEERING] = steering hardware, etc.
        # We exclude them to keep the report focused on CONNECTION problems.
        $exclusionPatterns = @(
            "Auxiliary Controller", "AssetPatching", "XMLDoc", "virtualPath",
            "\[Experiment\]", "\[LOADER\]", "Loading WAD file", "\[VIDEO_CAPTURE\]",
            "\[CoffeeStop\]", "\[Group Events\]", "Notable Moment", "\[STEERING\]",
            "\[IMAGE_LOADING\]", "\[ExploitTracker\]"
        )
        # This check says: "Keep the line ONLY IF it does NOT match any exclusion patterns"
        # (The -notmatch means "doesn't match")
        $line -notmatch ($exclusionPatterns -join "|")
    }


# Print to console with colors
$printIndex = 0
$printTotal = $filtered.Count
foreach ($entry in $filtered) {
    $printIndex++
    # Update progress every 100 lines
    if ($printIndex % 100 -eq 0 -or $printIndex -eq $printTotal) {
        $percentComplete = [int](($printIndex / $printTotal) * 100)
        Write-Progress -Activity "Displaying Filtered Log" `
                       -Status "Printing line $printIndex of $printTotal" `
                       -PercentComplete $percentComplete `
                       -CurrentOperation "Learning: Color-coding log entries by severity (red=error, yellow=connecting, green=success)"
    }
    
    $color = Get-LineColor $entry.Line
    if ($color -eq "White") {
        Write-Host $entry.Line
    } else {
        Write-Host $entry.Line -ForegroundColor $color
    }
}
Write-Progress -Activity "Displaying Filtered Log" -Completed

# Prepare data for saving (plain text, no colors)
$filteredLines = $filtered | ForEach-Object { $_.Line }
$excludedLines = $allLines | Where-Object { $_ -notin $filteredLines }

# Calculate line counts
$filteredCount = $filteredLines.Count
$excludedCount = $excludedLines.Count

# =================================================================================
# STEP 2: BUILD EVENT TIMELINE (Convert Lines to Structured Events)
# =================================================================================
# Now we have filtered lines, but they're still just text strings. We need to
# CATEGORIZE them into EVENT TYPES (connected, disconnected, error, etc.)
#
# WHY? Because "has new connection status: connected" is a CONNECTION EVENT,
# while "TCP disconnected" is a DISCONNECTION EVENT. By categorizing, we can
# analyze patterns like "how many disconnects happened?" or "when did errors occur?"
#
# WHAT'S A TIMELINE? It's an array of objects where each object has:
#   - Time: When it happened (HH:MM:SS)
#   - Event: What type of event ("BLE Connected", "Connection Error", etc.)
#   - Details: Extra info (device name, error message, etc.)
#
# This is like converting this:
#   "[18:51:05] Device 'Wahoo KICKR' has new connection status: connected"
# Into this:
#   {Time: "18:51:05", Event: "BLE Connected", Details: "Wahoo KICKR"}
#
# WHY USE OBJECTS? So we can later GROUP BY event type, SORT by time, etc.
# =================================================================================

# Parse timeline events from filtered lines
$timeline = @()
$filteredTotal = $filteredLines.Count
for ($i = 0; $i -lt $filteredLines.Count; $i++) {
    # Update progress every 50 lines
    if ($i % 50 -eq 0 -or $i -eq ($filteredTotal - 1)) {
        $percentComplete = [int](($i / $filteredTotal) * 100)
        Write-Progress -Activity "Parsing Timeline Events" `
                       -Status "Processing line $($i + 1) of $filteredTotal" `
                       -PercentComplete $percentComplete `
                       -CurrentOperation "Learning: Converting text strings into structured data objects for analysis"
    }
    
    $line = $filteredLines[$i]
    $time = Get-Timestamp $line  # Extract timestamp like "18:51:05" from "[18:51:05] ..."
    if (-not $time) { continue }  # Skip lines without timestamps (shouldn't happen but be safe)
    
    # ---------------------------------------------------------------------------------
    # Pattern matching: identify and categorize events
    # ---------------------------------------------------------------------------------
    # This SWITCH statement is like a "pattern recognition engine":
    #   - It looks at the line text
    #   - Matches it against patterns (using regular expressions)
    #   - Creates the appropriate event object
    #
    # DYNAMIC DEVICE DETECTION: We build regex patterns from $DEVICE_PATTERNS so this
    # works with ANY device brand (Wahoo, Tacx, Saris, Elite, etc.)
    # ---------------------------------------------------------------------------------
    
    # Build dynamic regex pattern from detected/configured devices
    $deviceRegex = ($DEVICE_PATTERNS | ForEach-Object { [regex]::Escape($_) }) -join '|'
    
    # Build regex patterns with device patterns embedded
    $connectedPattern = 'Device: "((DEVICEREGEX)[^"]*?)" has new connection status: connected'.Replace('DEVICEREGEX', $deviceRegex)
    $disconnectedPattern = 'Device: "((DEVICEREGEX)[^"]*?)" has new connection status: disconnected'.Replace('DEVICEREGEX', $deviceRegex)
    $errorPattern = '\[ERROR\].*(Error receiving|Error connecting).*((DEVICEREGEX)[^"]*?)'.Replace('DEVICEREGEX', $deviceRegex)
    
    switch -Regex ($line) {
        { $_ -match $connectedPattern } {
            $device = $matches[1]
            # Detect DirectConnect by searching a window of nearby lines for LAN connection indicators
            # This works because DirectConnect events appear close to the connection status change
            $contextStart = [Math]::Max(0, $i - $DIRECTCONNECT_CONTEXT_BEFORE)
            $contextEnd = [Math]::Min($filteredLines.Count - 1, $i + $DIRECTCONNECT_CONTEXT_AFTER)
            $context = $filteredLines[$contextStart..$contextEnd] -join " "
            $connType = if ($context -match "\[$time\].*(BLE \(LAN\)|LAN Exercise Device.*$device)") { "via DirectConnect" } else { "via BLE" }
            $timeline += [PSCustomObject]@{ Time=$time; Event="BLE Connected"; Details="$device $connType" }
        }
        { $_ -match $disconnectedPattern } {
            $timeline += [PSCustomObject]@{ Time=$time; Event="BLE Disconnected"; Details=$matches[1] }
        }
        { $_ -match $errorPattern } {
            $timeline += [PSCustomObject]@{ Time=$time; Event="Connection Error"; Details=$line.Substring(0, [Math]::Min($MAX_ERROR_DETAIL_LENGTH, $line.Length)) }
        }
        '\[INFO\] TCP disconnected' {
            $timeline += [PSCustomObject]@{ Time=$time; Event="TCP Disconnected"; Details="Zwift server connection lost" }
        }
        'Could not resolve hostname' {
            $timeline += [PSCustomObject]@{ Time=$time; Event="DNS Error"; Details="DNS resolution failed" }
        }
        'TCP connection timed out owing to inactivity' {
            $timeline += [PSCustomObject]@{ Time=$time; Event="Connection Timeout"; Details="TCP connection inactive" }
        }
        'Saying hello to TCP server' {
            $timeline += [PSCustomObject]@{ Time=$time; Event="Server Hello"; Details="Connected to Zwift server" }
        }
        '\[GameState\] Logout Successful.*shutdown: true' {
            $timeline += [PSCustomObject]@{ Time=$time; Event="Shutdown Started"; Details="Graceful shutdown initiated" }
        }
    }
}
Write-Progress -Activity "Parsing Timeline Events" -Completed

# =================================================================================
# STEP 3: ANALYZE THE TIMELINE (Find Patterns and Problems)
# =================================================================================
# Now we have a timeline of events, but we need to UNDERSTAND what happened.
#
# The analysis happens in FOUR PHASES:
#   Phase A: Organize events by type (connections, errors, etc.)
#   Phase B: Identify ride boundaries (when did it start/end?)
#   Phase C: Filter out pre-ride noise (ignore startup events)
#   Phase D: Detect problems and classify them
#
# WHY PHASE BY PHASE? Each phase builds on the previous one. We need to know
# when the ride started (Phase B) before we can filter pre-ride events (Phase C).
# =================================================================================

# Build narrative summary
$narrative = @()

# ---------------------------------------------------------------------------------
# PHASE A: Organize Events by Type (Grouping)
# ---------------------------------------------------------------------------------
# We have a big list of events in time order. But to analyze, we need them
# ORGANIZED by TYPE. It's like sorting a deck of cards by suit!
#
# Group-Object creates a "hash table" (dictionary) where:
#   Key = Event type ("BLE Connected", "Connection Error", etc.)
#   Value = Array of all events of that type
# ---------------------------------------------------------------------------------
$eventsByType = $timeline | Group-Object -Property Event -AsHashTable

# Extract each event type into its own array for easy access
# The @() wrapper ensures we always get an array (even if empty or single item)
$connectionEvents = @($eventsByType["BLE Connected"])
$disconnectionEvents = @($eventsByType["BLE Disconnected"])
$errorEvents = @($eventsByType["Connection Error"])
$tcpDisconnects = @($eventsByType["TCP Disconnected"])
$dnsErrors = @($eventsByType["DNS Error"])
$timeouts = @($eventsByType["Connection Timeout"])
$serverHellos = @($eventsByType["Server Hello"])
$shutdownStarted = @($eventsByType["Shutdown Started"])

# ---------------------------------------------------------------------------------
# PHASE B: Identify ride Boundaries
# ---------------------------------------------------------------------------------
# A Zwift log file might contain events from BEFORE the actual ride started
# (app launching, initializing, etc.). We only care about events that happened
# DURING THE ACTUAL ride. So we need to find:
#   - When did the ride START? (first "Server Hello" = connected to game)
#   - When did the ride END? ("Shutdown Started" = user exited)
# ---------------------------------------------------------------------------------

# ride START = first time we connected to Zwift's game server
$ridestartTime = if ($serverHellos.Count -gt 0) { $serverHellos[0].Time } else { "00:00:00" }

# ride END = when graceful shutdown began (or sentinel value if no shutdown found)
# TEACHING MOMENT: The sentinel value (99:99:99) is an "impossible time" that means
# "this never happened". It's like using -1 to mean "not found" in array searches.
$shutdownTime = $SENTINEL_TIME_MAX
if ($shutdownStarted.Count -gt 0) { $shutdownTime = $shutdownStarted[0].Time }

# ---------------------------------------------------------------------------------
# PHASE C: Filter to Post-ride-Start Events Only
# ---------------------------------------------------------------------------------
# WHY? Because errors during app startup aren't interesting. We only care about
# errors that happened DURING THE RIDE. It's like ignoring pre-game warmup and
# only analyzing the actual game.
#
# We filter ONCE here and store the results, rather than filtering repeatedly
# later in the code. This is a PERFORMANCE OPTIMIZATION - filter once, use many times!
# ---------------------------------------------------------------------------------
$postStartErrors = $errorEvents | Where-Object { $_.Time -gt $ridestartTime }
$postStartTimeouts = $timeouts | Where-Object { $_.Time -gt $ridestartTime }
$postStartDnsErrors = $dnsErrors | Where-Object { $_.Time -gt $ridestartTime }

# ---------------------------------------------------------------------------------
# PHASE D: Detect Problems and Classify Them
# ---------------------------------------------------------------------------------
# Not all disconnections are problems! Some are expected/harmless:
#   - Device disconnects at shutdown (user is exiting anyway)
#   - TCP disconnect followed by instant reconnect (< 5 sec = seamless server switch)
#
# Our goal: Separate REAL problems from routine events
# ---------------------------------------------------------------------------------

# Filter to disconnects that happened DURING the ride (not at shutdown)
$problematicTcpDisconnects = $tcpDisconnects | Where-Object { $_.Time -gt $ridestartTime }
$problematicDisconnections = $disconnectionEvents | Where-Object { $_.Time -lt $shutdownTime }

Write-Debug " DECISION: Filtering disconnects to find problems"
Write-Debug "  Total TCP disconnects: $($tcpDisconnects.Count)"
Write-Debug "  TCP disconnects during ride: $($problematicTcpDisconnects.Count)"
Write-Debug "  Device disconnections before shutdown: $($problematicDisconnections.Count)"
Write-Debug "  LOGIC: Ignoring shutdown events - users expect disconnects when exiting"

# ---------------------------------------------------------------------------------
# SEAMLESS vs DISRUPTIVE Reconnections (The Smart Part!)
# ---------------------------------------------------------------------------------
# Zwift's servers sometimes switch you between machines for load balancing.
# If done quickly (< 5 seconds), you won't even notice - this is SEAMLESS.
# If it takes longer, or fails to reconnect, that's DISRUPTIVE.
#
# ALGORITHM:
#   For each TCP disconnect:
#     1. Look for a "Server Hello" after it
#     2. Calculate time difference
#     3. If <= 5 seconds = seamless (ignore it)
#     4. If > 5 seconds or no reconnect = disruptive (report it!)
#
# ---------------------------------------------------------------------------------
$disruptiveTcpDisconnects = @()
$seamlessReconnectTimes = @()
foreach ($disconnect in $problematicTcpDisconnects) {
    # Convert time string to TimeSpan for math: "18:51:05" -> 18h 51m 5s
    $disconnectTime = [TimeSpan]::ParseExact($disconnect.Time, "hh\:mm\:ss", $null)
    $hasQuickReconnect = $false
    
    # Only check server hellos that occur AFTER this disconnect (efficiency!)
    # No point checking hellos that happened before the disconnect
    foreach ($hello in ($serverHellos | Where-Object { $_.Time -ge $disconnect.Time })) {
        $helloTime = [TimeSpan]::ParseExact($hello.Time, "hh\:mm\:ss", $null)
        # Calculate seconds between disconnect and reconnect
        $timeDiff = ($helloTime - $disconnectTime).TotalSeconds
        
        # Did we reconnect within the threshold? (5 seconds by default)
        if ($timeDiff -le $SEAMLESS_RECONNECT_THRESHOLD_SECONDS) {
            $hasQuickReconnect = $true
            $seamlessReconnectTimes += $disconnect.Time
            Write-Debug "  [OK] SEAMLESS: Disconnect at $($disconnect.Time) reconnected in $([math]::Round($timeDiff, 1))s - ignoring (load balancing)"
            break
        }
        if ($timeDiff -gt $SEAMLESS_RECONNECT_THRESHOLD_SECONDS) { break }  # No point checking later hellos
    }
    if (-not $hasQuickReconnect) {
        $disruptiveTcpDisconnects += $disconnect
        Write-Debug "  [WARNING] DISRUPTIVE: Disconnect at $($disconnect.Time) - no quick reconnect found (PROBLEM!)"
    }
}

Write-Debug " ANALYSIS RESULT:"
Write-Debug "  Seamless reconnects (ignored): $($seamlessReconnectTimes.Count)"
Write-Debug "  Disruptive disconnects (problems): $($disruptiveTcpDisconnects.Count)"

# Calculate ride duration for narrative section (before building narrative)
$rideDurationLine = ""
if ($serverHellos.Count -gt 0) {
    $startTime = $serverHellos[0].Time
    # Reuse the shutdownTime calculation from earlier (if not sentinel value)
    $endTime = if ($shutdownTime -ne $SENTINEL_TIME_MAX) { $shutdownTime } else { $null }
    
    if ($endTime) {
        $durationSeconds = (ConvertFrom-TimeString $endTime) - (ConvertFrom-TimeString $startTime)
        $rideDurationLine = "- ride duration was " + (Format-Duration $durationSeconds)
    }
}

# =================================================================================
# STEP 4: BUILD THE DIAGNOSIS (Tell the Story)
# =================================================================================
# Now we've organized, filtered, and classified events. Time to build the
# human-readable narrative that explains what happened during the ride.
#
# NARRATIVE STRUCTURE:
#   1. When did the ride start?
#   2. Did any problems occur? If so, WHAT and WHEN?
#   3. Can we DIAGNOSE the root cause?
#   4. How did the ride end?
#
# =================================================================================

if ($serverHellos.Count -gt 0) {
    $firstHello = $serverHellos[0]
    $narrative += "WHAT HAPPENED:"
    $narrative += "- ride started at $($firstHello.Time) - Connected to Zwift server"
    
    # Add duration if available
    if ($rideDurationLine) {
        $narrative += $rideDurationLine
    }
    
    # Identify first problem if any
    $firstProblemTime = $null
    $problemType = ""
    
    # ---------------------------------------------------------------------------------
    # PROBLEM DETECTION: Do we have any issues?
    # ---------------------------------------------------------------------------------
    # We combine all our filtered problem arrays and check if ANY exist.
    # This is BOOLEAN LOGIC: If (errors OR timeouts OR disconnects) then hasProblems = true
    # ---------------------------------------------------------------------------------
    $allProblems = @($postStartErrors) + @($postStartTimeouts) + @($disruptiveTcpDisconnects) + @($problematicDisconnections)
    $hasProblems = $allProblems.Count -gt 0
    
    Write-Debug " DECISION: Does this ride have problems?"
    Write-Debug "  Post-start errors: $($postStartErrors.Count)"
    Write-Debug "  Post-start timeouts: $($postStartTimeouts.Count)"
    Write-Debug "  Disruptive TCP disconnects: $($disruptiveTcpDisconnects.Count)"
    Write-Debug "  Device disconnections: $($problematicDisconnections.Count)"
    Write-Debug "  VERDICT: $(if ($hasProblems) { 'YES - Problems detected!' } else { 'NO - Clean ride' })"
    
    if ($hasProblems) {
        # ---------------------------------------------------------------------------------
        # FIND THE FIRST PROBLEM (Root Cause Analysis)
        # ---------------------------------------------------------------------------------
        # Often, the FIRST problem causes a cascade of other issues. So we need to find
        # which problem happened EARLIEST. This is like being a detective looking for
        # the "original crime" that set everything else in motion!
        #
        # ALGORITHM:
        #   1. Collect all problem types with their timestamps
        #   2. Sort by time (earliest first)
        #   3. The first one is likely the root cause
        # ---------------------------------------------------------------------------------
        $problemCandidates = @()
        
        # Collect each type of problem with a descriptive label
        if ($postStartErrors.Count) { $problemCandidates += @{Time=$postStartErrors[0].Time; Type="LAN device connection error"} }
        if ($postStartTimeouts.Count) { $problemCandidates += @{Time=$postStartTimeouts[0].Time; Type="TCP connection timeout"} }
        if ($disruptiveTcpDisconnects.Count) { $problemCandidates += @{Time=$disruptiveTcpDisconnects[0].Time; Type="Disruptive Zwift server disconnection"} }
        
        # Find the earliest problem (sort by time, take first)
        # TEACHING MOMENT: Sort-Object with a script block {$_.Time} sorts by the Time property
        if ($problemCandidates.Count) {
            Write-Debug " DECISION: Finding root cause (earliest problem)"
            Write-Debug "  Problem candidates found: $($problemCandidates.Count)"
            foreach ($candidate in $problemCandidates) {
                Write-Debug "    - $($candidate.Time): $($candidate.Type)"
            }
            $earliestProblem = $problemCandidates | Sort-Object {$_.Time} | Select-Object -First 1
            $firstProblemTime = $earliestProblem.Time
            $problemType = $earliestProblem.Type
            Write-Debug "  ROOT CAUSE: $problemType at $firstProblemTime (earliest event)"
        }
        
        $narrative += "- System ran normally until $firstProblemTime"
        $narrative += "- First problem encountered: $problemType"
        
        # ---------------------------------------------------------------------------------
        # DIAGNOSIS: What's the root cause?
        # ---------------------------------------------------------------------------------
        # Based on the problem type and patterns, we provide a SPECIFIC diagnosis.
        # This is CONDITIONAL LOGIC: if-elseif-else chains to determine the cause.
        # ---------------------------------------------------------------------------------
        Write-Debug " DIAGNOSIS: Determining root cause"
        if ($postStartDnsErrors.Count -gt 0) {
            # DNS errors = can't convert domain names to IP addresses = no internet!
            Write-Debug "  DIAGNOSIS: Internet connectivity failure"
            Write-Debug "  EVIDENCE: DNS resolution errors detected"
            Write-Debug "  MEANING: Can't translate domain names to IP addresses = no internet"
            $narrative += "- DIAGNOSIS: Internet connectivity lost (DNS resolution failures detected)"
        } elseif ($problemType -eq "LAN device connection error") {
            # LAN errors could be general connection failures OR specific "actively refused"
            # We check the error details to be more specific
            Write-Debug "  DIAGNOSIS: LAN device connection error"
            Write-Debug "  Checking for specific 'actively refused' pattern..."
            $activelyRefusedError = $postStartErrors | Where-Object { $_.Details -match "actively refused" -and $_.Details -match "LAN Exercise Device" }
            Write-Debug "  'Actively refused' errors found: $($activelyRefusedError.Count)"
            if ($activelyRefusedError) {
                # "Actively refused" = the trainer REJECTED the connection (firmware bug)
                $narrative += "- DIAGNOSIS: Trainer's DirectConnect service rejected connection attempts (firmware/service failure)"
            } else {
                # Generic LAN/DirectConnect failure
                $narrative += "- DIAGNOSIS: DirectConnect (BLE/LAN) connection failure with trainer"
            }
        }
    } else {
        # No problems detected = clean ride! Good news!
        $narrative += "- ride ran without connection issues"
    }
    
    # Determine how ride ended (reuse already-calculated shutdownTime)
    if ($shutdownStarted.Count -gt 0) {
        $narrative += "- ride ended at $($shutdownStarted[0].Time) - Graceful shutdown initiated"
    } else {
        $narrative += "- ride ended without graceful shutdown - May have crashed or been terminated"
    }
    
    # Only show server reconnections if they're relevant (close to a problem)
    # Server reconnections are usually routine maintenance/load balancing - only interesting if near an issue
    if ($seamlessReconnectTimes.Count -gt 0 -and $hasProblems) {
        $problemTime = $null
        if ($postStartErrors.Count -gt 0) {
            $problemTime = [TimeSpan]::ParseExact($postStartErrors[0].Time, "hh\:mm\:ss", $null)
        }
        
        # Filter to reconnections within 2 minutes of the problem
        $relevantReconnects = @()
        if ($null -ne $problemTime) {
            Write-Debug " DECISION: Finding server reconnects near problem time"
            Write-Debug "  Problem occurred at: $($postStartErrors[0].Time)"
            Write-Debug "  Checking $($seamlessReconnectTimes.Count) seamless reconnects for proximity"
            foreach ($reconnectTime in $seamlessReconnectTimes) {
                $reconTime = [TimeSpan]::ParseExact($reconnectTime, "hh\:mm\:ss", $null)
                $timeDiff = [Math]::Abs(($reconTime - $problemTime).TotalSeconds)
                if ($timeDiff -le $PROBLEM_PROXIMITY_SECONDS) {  # Within 2 minutes of problem
                    $relevantReconnects += $reconnectTime
                    Write-Debug "  [OK] Reconnect at $reconnectTime is within $([math]::Round($timeDiff))s of problem (RELEVANT)"
                } else {
                    Write-Debug "  [X] Reconnect at $reconnectTime is $([math]::Round($timeDiff))s away (too far)"
                }
            }
            Write-Debug "  RESULT: $($relevantReconnects.Count) relevant reconnections to report"
        }
        
        # Only show if there are relevant reconnections near the problem
        if ($relevantReconnects.Count -gt 0) {
            if ($relevantReconnects.Count -eq 1) {
                $narrative += "- Server reconnection at $($relevantReconnects[0]) (possibly related to connection issue)"
            } else {
                $narrative += "- $($relevantReconnects.Count) server reconnections near problem time:"
                foreach ($time in $relevantReconnects) {
                    $narrative += "  - Reconnected at $time"
                }
            }
        }
    }
}

# Extract trainer info once for reuse throughout narrative and header
$trainerInfo = Get-TrainerInfo $allLines $DEVICE_PATTERNS

# Problems section - only show if problems exist
if ($hasProblems) {
    $narrative += ""
    $narrative += "PROBLEMS DETECTED:"
    
    # Collect all problem events with their original log entries using helper function
    $allProblems = @()
    $allProblems += Add-ProblemEntry $postStartErrors { param($e) $e.Details }
    $allProblems += Add-ProblemEntry $disruptiveTcpDisconnects { param($e) "[$($e.Time)] [INFO] TCP disconnected" }
    $allProblems += Add-ProblemEntry $postStartDnsErrors { param($e) "[$($e.Time)] [ERROR] Could not resolve hostname" }
    $allProblems += Add-ProblemEntry $problematicDisconnections { param($e) "[$($e.Time)] [BLE] Device: `"$($e.Details)`" has new connection status: disconnected" }
    
    # Sort all problems by time and display
    $allProblems = $allProblems | Sort-Object Time
    foreach ($problem in $allProblems) {
        $narrative += $problem.Entry
    }
}

# Resolution - only show for problematic rides
if ($hasProblems -and $firstProblemTime) {
    $narrative += ""
    $narrative += "RESOLUTION:"
    
    # Check for recovery after the problem started
    $postProblemServerHellos = $serverHellos | Where-Object { $_.Time -gt $firstProblemTime }
    $postProblemConnections = $connectionEvents | Where-Object { $_.Time -gt $firstProblemTime }
    
    Write-Debug " DECISION: Looking for recovery after problem at $firstProblemTime"
    Write-Debug "  Server hellos after problem: $($postProblemServerHellos.Count)"
    Write-Debug "  Device connections after problem: $($postProblemConnections.Count)"
    
    # If the problem was internet-related (post-ride DNS errors), report server reconnection
    if ($postStartDnsErrors.Count -gt 0 -and $postProblemServerHellos.Count -gt 0) {
        $reconnectTime = $postProblemServerHellos[0].Time
        $narrative += "- Connection automatically restored at $reconnectTime when internet connectivity returned"
    } 
    # For device connection issues (like BLE/LAN or DirectConnect failures), show device reconnection
    elseif ($postProblemConnections.Count -gt 0) {
        # Find trainer connections if the problem was a LAN device error
        # Assume first device in pattern is the trainer (typically trainers are listed first)
        if ($DEVICE_PATTERNS.Count -gt 0) {
            $firstDevice = [regex]::Escape($DEVICE_PATTERNS[0])
            $trainerConnections = $postProblemConnections | Where-Object { $_.Details -match $firstDevice }
        } else {
            $trainerConnections = @()
        }
        
        if ($trainerConnections.Count -gt 0 -and $problemType -match "LAN device") {
            # For trainer LAN/DirectConnect issues, show trainer reconnection
            $recoveryConnect = $trainerConnections[0]
            $narrative += "- Trainer reconnected at $($recoveryConnect.Time) - $($recoveryConnect.Details)"
            
            # Check if DirectConnect was abandoned for standard BLE
            if ($recoveryConnect.Details -match "via BLE" -and $recoveryConnect.Details -notmatch "DirectConnect") {
                $narrative += "- DirectConnect (BLE/LAN) failed - switched to standard BLE radio connection"
            }
        } else {
            # For other device issues, show first reconnection
            $recoveryConnect = $postProblemConnections[0]
            $narrative += "- Device reconnected at $($recoveryConnect.Time) - $($recoveryConnect.Details)"
        }
    } else {
        $narrative += "- No recovery detected - ride may have ended with errors"
    }
    
    # Add conclusions section for broader context
    $narrative += ""
    $narrative += "CONCLUSIONS:"
    
    # Provide context based on the type of problem encountered
    $postStartDnsErrors = $dnsErrors | Where-Object { $_.Time -gt $ridestartTime }
    if ($postStartDnsErrors.Count -gt 0) {
        $narrative += "- Internet connectivity was lost during the ride, causing DNS resolution failures"
        $narrative += "- This is typically caused by router issues, ISP problems, or local network disruption"
        $narrative += "- The problem is external to Zwift and the trainer - check your internet connection"
    } elseif ($problemType -eq "LAN device connection error") {
        # Check if we have the specific "actively refused" error
        $postStartErrors = $errorEvents | Where-Object { $_.Time -gt $ridestartTime }
        $activelyRefusedError = $postStartErrors | Where-Object { $_.Details -match "actively refused" -and $_.Details -match "LAN Exercise Device" }
        
        if ($activelyRefusedError) {
            Write-Debug " DIAGNOSIS: DirectConnect service failure detected"
            Write-Debug "  EVIDENCE: 'actively refused' error in LAN Exercise Device messages"
            Write-Debug "  CONCLUSION: Trainer DirectConnect firmware/service crashed"
            Write-Debug "  RECOMMENDATION: Manual BLE reconnection required"
            $narrative += "- The trainer was reachable on the network but its DirectConnect service rejected connections"
            $narrative += "- DirectConnect is a Bluetooth over wired LAN technology designed to eliminate wireless interference"
            $narrative += "- This specific error indicates the trainer's DirectConnect firmware/service crashed or malfunctioned"
            $narrative += "- IMPORTANT: Current firmware does NOT automatically fall back to Bluetooth - manual intervention required"
            $narrative += "- User must manually reconnect the trainer via standard BLE to continue the ride"
            $narrative += "- Recommended actions: Power cycle the trainer, check for firmware updates, or contact manufacturer support"
            $narrative += "- Note: Automatic BLE fallback may be added in future firmware updates"
        } else {
            $narrative += "- DirectConnect (BLE/LAN) connection to the trainer failed during the ride"
            $narrative += "- DirectConnect is a Bluetooth over wired LAN technology designed to avoid wireless interference"
            $narrative += "- Current firmware does NOT automatically fall back to standard BLE radio connection"
            $narrative += "- User intervention required: manually reconnect the trainer via Bluetooth to continue"
            $narrative += "- Possible causes: WiFi signal strength, router configuration, or trainer firmware issues"
            $narrative += "- Consider checking network setup, router placement, or updating trainer firmware"
        }
        
        # Note: Trainer details are now in the header section, not duplicated here in narrative
    } elseif ($problemType -match "Disruptive.*disconnection") {
        $narrative += "- Connection to Zwift servers was disrupted during the ride"
        $narrative += "- This may be due to server maintenance, internet instability, or network congestion"
        $narrative += "- ride was able to reconnect, but temporary data loss may have occurred"
    } elseif ($problemType -match "TCP connection timeout") {
        $narrative += "- Communication with Zwift servers timed out during the ride"
        $narrative += "- This typically indicates network latency or packet loss issues"
        $narrative += "- Check your internet connection quality and router performance"
    }
}

# Build trainer details section for header (always include if available)
$trainerDetailsText = ""
if ($trainerInfo -and $trainerInfo.Count -gt 0) {
    $trainerDetails = @()
    $trainerDetails += ""
    $trainerDetails += "TRAINER DETAILS:"
    $trainerDetails += $trainerInfo
    $trainerDetailsText = "`n" + ($trainerDetails -join "`n")
}

# Build summary footer text
$narrativeText = if ($narrative.Count -gt 0) { "`n" + ($narrative -join "`n") + "`n" } else { "" }


$logFileName = Split-Path $ZwiftLogFilePath -Leaf
$filterEffectiveness = [math]::Round(($excludedCount / $totalLines) * 100, 1)

# Format numbers with comma separators for readability
$totalLinesFormatted = $totalLines.ToString("N0")
$filteredCountFormatted = $filteredCount.ToString("N0")
$excludedCountFormatted = $excludedCount.ToString("N0")

# Build formatted summary header with aligned columns
$summaryHeader = @"
===== Zwift ride Summary =====
Log File:        $logFileName
Total Lines:     $totalLinesFormatted log entries
Kept:            $filteredCountFormatted log entries (relevant for analysis)
Excluded:        $excludedCountFormatted log entries ($filterEffectiveness% - debug noise, routine operations, telemetry, non-selected devices)
"@

# Add trainer details if available
if ($trainerDetailsText) {
    $summaryHeader += $trainerDetailsText
}

# Build complete footer with Generated By line at the end
$footer = $summaryHeader + "`n" + $narrativeText + "`nAnalysis Date:   $analysisDate`nGenerated by:    Zwift Log Analyzer v1.0.0 (December 17, 2025)`nAuthor:          John Hughes`n"

# Print summary footer to console
Write-Host $footer -ForegroundColor Cyan
Write-Host ""

# Write files in logical sequence for easier folder scanning
# 1. Copy original log file first (source material)
$originalLogInProcessed = Join-Path $OutputDirectoryPath $ZwiftLogFileName
Copy-Item -Path $ZwiftLogFilePath -Destination $originalLogInProcessed -Force
Write-Host "Original:  $originalLogInProcessed" -ForegroundColor Cyan

# 2. Save report (client-facing summary)
$footer | Out-File -FilePath $ReportPath -Encoding utf8
Write-Host "Report:    $ReportPath" -ForegroundColor Cyan

# 3. Save timeline (supporting evidence)
$filteredLines | Out-File -FilePath $TimelinePath -Encoding utf8
Write-Host "Timeline:  $TimelinePath" -ForegroundColor Cyan

# 4. Save excluded lines (debug/validation)
$excludedLines | Where-Object { $_.Trim() -ne "" } | Out-File -FilePath $ExcludedPath -Encoding utf8
Write-Host "Excluded:  $ExcludedPath" -ForegroundColor Cyan
