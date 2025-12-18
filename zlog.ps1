<#
.SYNOPSIS
    Analyzes Zwift log files to identify connection problems and session issues.

.DESCRIPTION
    Parses Zwift application log files, filters relevant connectivity events,
    and generates a diagnostic report distinguishing between clean sessions
    and problematic sessions with connection issues. Detects seamless server
    reconnections vs disruptive disconnects.
    
    Uses a hybrid workflow: reads from incoming folder, writes to processed folder
    organized by date. Original log file is copied (not moved) to processed folder
    alongside filtered and excluded outputs, allowing reprocessing if needed.

.PARAMETER ZwiftLogFileName
    Filename of the Zwift log file to analyze (e.g., "Log_2025-12-15_clean_session.txt").
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
    .\zlog.ps1 "Log_2025-12-15_clean_session.txt"
    Auto-detects all BLE devices in the log and analyzes them.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_session.txt" -Devices "Wahoo KICKR"
    Analyzes only Wahoo KICKR trainer, ignoring other devices.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_session.txt" -Devices "Wahoo KICKR", "HRMPro"
    Analyzes both trainer and heart rate monitor.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_session.txt" -ExcludeDevices "HRM"
    Auto-detects all devices but excludes heart rate monitors from analysis.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_session.txt" -Verbose
    Shows detailed progress messages explaining what the script is doing at each step.
    Educational mode - excellent for learning how log analysis works.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_session.txt" -Debug
    Shows diagnostic decision-making process: why events are classified certain ways,
    which disconnects are seamless vs problematic, and root cause analysis logic.

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15_clean_session.txt" -Verbose -Debug
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

    === PROGRAMMING CONCEPTS DEMONSTRATED ===
    This script teaches several important programming concepts:
    
    1. PARAMETERS & VALIDATION (lines 25-32)
       - How to accept user input and validate it
       - Making scripts reusable with different inputs
    
    2. CONSTANTS (lines 44-49)
       - Why we use named constants instead of "magic numbers"
       - Making code maintainable and self-documenting
    
    3. FUNCTIONS (lines 95-125, 164-171)
       - Breaking complex tasks into reusable pieces
       - The "Don't Repeat Yourself" (DRY) principle
    
    4. ARRAYS & COLLECTIONS (lines 38-41, throughout)
       - Storing multiple related values together
       - Processing collections with loops
    
    5. CONDITIONAL LOGIC (lines 300-315)
       - Making decisions based on data
       - If/else statements and boolean expressions
    
    6. PATTERN MATCHING (lines 95-110)
       - Using regular expressions to find patterns in text
       - More powerful than simple text comparison
    
    7. FILE I/O (lines 58, 200+)
       - Reading data from files
       - Writing results to new files
    
    8. DATA PIPELINE (lines 195-230)
       - Transforming data step-by-step
       - Filtering, sorting, and grouping information
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
    [Parameter(Mandatory=$false, Position=0)]
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
    Write-Host "  - Educational verbose mode (108 messages)"
    Write-Host "  - Diagnostic debug mode (40 messages)"
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

# =================================================================================
# ===== DEVICE DETECTION & FILTERING =====
# ==================================================================================
# This section handles device pattern configuration. Three modes available:
#   1. AUTO-DETECT: No -Devices parameter = detect all BLE devices from log
#   2. EXPLICIT: -Devices parameter = only track specified devices
#   3. AUTO + EXCLUDE: -ExcludeDevices = auto-detect but exclude certain patterns
#
# WHY AUTO-DETECT? So the script works for anyone's hardware without editing!
# WHY EXPLICIT? To focus analysis on specific devices when troubleshooting.
# WHY EXCLUDE? To filter out noise from devices you're not interested in.
#
# Examples:
#   .\zlog.ps1 "log.txt"                                    # Auto-detect all
#   .\zlog.ps1 "log.txt" -Devices "Wahoo KICKR"            # Only trainer
#   .\zlog.ps1 "log.txt" -ExcludeDevices "HRM", "Phone"    # All except HRM & Phone
# =================================================================================

# Default device patterns (fallback if auto-detection finds nothing)
$DEFAULT_DEVICE_PATTERNS = @(
    "Wahoo KICKR",
    "HRMPro"
)

# +---------------------------------------------------------------------------------+
# | [TIP] PROGRAMMING CONCEPT: Dynamic Configuration                                |
# +---------------------------------------------------------------------------------+
# | Instead of hardcoding device names, we use PARAMETERS to make the script       |
# | flexible. This is called "parameterization" - a key principle in writing       |
# | reusable code that adapts to different situations without modification.        |
# |                                                                                 |
# | THREE STRATEGIES:                                                               |
# | 1. Explicit (-Devices): User knows exactly what they want                      |
# | 2. Auto-detect: Script figures it out from the data                            |
# | 3. Hybrid (-ExcludeDevices): Auto-detect but let user filter results           |
# |                                                                                 |
# | This pattern appears everywhere in software: web forms, database queries,      |
# | search engines - any time you want flexibility without changing code!          |
# +---------------------------------------------------------------------------------+

# ===== PRODUCTION FOLDER PATHS =====
# Default locations for input and output files in production workflow
$INCOMING_FOLDER = "C:\Users\johng\holding_pen\StuffForZwiftLogs\incoming"
$PROCESSED_FOLDER = "C:\Users\johng\holding_pen\StuffForZwiftLogs\processed"

# ===== CONSTANTS =====
# Thresholds and configuration values - these are like the "settings" for our script
# WHY USE CONSTANTS? They make it easy to change behavior without hunting through code!
# Instead of writing "5" everywhere, we write $SEAMLESS_RECONNECT_THRESHOLD_SECONDS
# If we need to change it later, we only change it in ONE place!

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

# +---------------------------------------------------------------------------------+
# | [WARNING] COMMON MISTAKE: Hardcoding magic numbers throughout your code!        |
# +---------------------------------------------------------------------------------+
# | Bad:  if ($timeDiff -le 5) { ... }    (What does 5 mean? Why 5?)              |
# | Good: if ($timeDiff -le $SEAMLESS_RECONNECT_THRESHOLD_SECONDS) { ... }        |
# |                                                                                 |
# | WHY IT MATTERS: If you decide to change 5 to 10, you'd have to find and       |
# | update EVERY place you wrote "5". With constants, change it ONCE at the top!  |
# +---------------------------------------------------------------------------------+
#
# +---------------------------------------------------------------------------------+
# | [TIP] TRY THIS! Experiment with different threshold values                      |
# +---------------------------------------------------------------------------------+
# | 1. Change $SEAMLESS_RECONNECT_THRESHOLD_SECONDS from 5 to 10                   |
# |    Run the script and see if more reconnections are now classified as seamless |
# |                                                                                 |
# | 2. Change $MAX_ERROR_DETAIL_LENGTH from 250 to 100                             |
# |    Notice how error messages in the report become shorter                      |
# |                                                                                 |
# | 3. Add your own constant: $MINIMUM_SESSION_DURATION = 300  (5 minutes)         |
# |    Then add code to warn if sessions are shorter than this!                    |
# +---------------------------------------------------------------------------------+

# +================================================================================+
# |                          DATA FLOW VISUALIZATION                               |
# |                   How this script transforms log data                          |
# +================================================================================+
#
#  Raw Log File              Filter Lines           Group Events         Analyze
#  +----------+             +----------+           +----------+        +----------+
#  | 20,350   |------------>|  1,280   |---------->| Errors:5 |------->| Report:  |
#  |  lines   |  Remove     |  lines   |  Identify | Warns: 8 |  Find  | Problems |
#  |          |  noise      |          |  patterns | Info:1000|  root  | Detected |
#  +----------+             +----------+           +----------+  cause +----------+
#       ^                        ^                      ^              ^
#       |                        |                      |              |
#   Everything            Only relevant          Group by type    Smart analysis
#   in the file         device/connection       & timestamp      finds the story
#                         events                                 behind the data
#
# EXAMPLE TRANSFORMATION:
# Before: "[18:51:07] Process discovery for Wahoo KICKR 5404._wahoo-fitness..."
# After:  EXCLUDED (happens 1000s of times, not useful for diagnosis)
#
# Before: "[18:50:50] [ERROR] LAN Exercise Device: Error connecting to..."
# After:  KEPT & HIGHLIGHTED - This is a problem we need to investigate!
#
# The goal: Turn 20,000 lines of technical logs into a 1-page human-readable diagnosis

# ================================================================================

# Verify incoming folder exists
if (-not (Test-Path $INCOMING_FOLDER)) {
    # Display formatted error message
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
    Write-Host "  .\zlog.ps1 `"Log_2025-12-15_clean_session.txt`""
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
$ReportPath = Join-Path $OutputDirectoryPath ("$inputFileName`_1_report.txt")
$TimelinePath = Join-Path $OutputDirectoryPath ("$inputFileName`_2_timeline.txt")
$ExcludedPath = Join-Path $OutputDirectoryPath ("$inputFileName`_3_excluded.txt")

# =================================================================================
# [DOCS] VERBOSE MODE: Educational progress messages for learning
# =================================================================================
# Run with -Verbose flag to see step-by-step explanations of what's happening!
# Example: .\zlog.ps1 "logfile.txt" -Verbose
# =================================================================================

Write-Verbose "==========================================================================="
Write-Verbose " LESSON: Reading the log file into memory"
Write-Verbose "==========================================================================="
Write-Verbose "WHY? We read the ENTIRE file at once instead of line-by-line because:"
Write-Verbose "  - Faster: One disk read vs. thousands of small reads"
Write-Verbose "  - Easier: We can process the data multiple times without re-reading"
Write-Verbose "  - Trade-off: Uses more RAM (20MB file = 20MB RAM)"
Write-Verbose ""
Write-Verbose "Reading from incoming folder: $INCOMING_FOLDER"
Write-Verbose "File: $ZwiftLogFileName"
Write-Verbose "Full path: $ZwiftLogFilePath"

# Read all lines once for efficiency
$allLines = Get-Content -Path $ZwiftLogFilePath
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

# =================================================================================
# STEP 1: FILTER THE LOG FILE (Remove the Noise)
# =================================================================================
# This is where we decide what log lines are useful and what's just clutter.
# Think of it like highlighting important sentences in a textbook!
#
# The filtering happens in THREE STAGES (like a funnel with 3 levels):
#   Stage 1: Cast a wide net - Find lines with ANY connection/device keywords
#   Stage 2: Force-exclude - Remove lines that are ALWAYS useless (battery level, etc)
#   Stage 3: Smart filtering - Keep important stuff, exclude noise
#
# WHY THIS ORDER? We want to be efficient! First we quickly grab candidates (Stage 1),
# then immediately throw out the worst noise (Stage 2), then carefully decide on the
# rest (Stage 3). It's faster than checking every line against every rule!
# =================================================================================

Write-Verbose "==========================================================================="
Write-Verbose " LESSON: Filtering log lines (removing noise)"
Write-Verbose "==========================================================================="
Write-Verbose "STRATEGY: 3-stage filtering process"
Write-Verbose "  Stage 1: Quick search for ANY connection/device keywords"
Write-Verbose "  Stage 2: Force-exclude high-noise patterns (battery, advertising)"
Write-Verbose "  Stage 3: Smart filtering (device-specific + exclusion rules)"
Write-Verbose ""
Write-Verbose "Processing $totalLines lines through the filter pipeline..."

# Collect filtered lines (process in-memory to avoid reading file twice)
$filtered = $allLines | Select-String -Pattern $searchPatterns |
    Where-Object {
        $line = $_.Line
        
        # -----------------------------------------------------------------------------
        # STAGE 2: High-priority exclusions (always exclude)
        # -----------------------------------------------------------------------------
        # These patterns appear THOUSANDS of times and are NEVER useful for diagnosis.
        # We check them FIRST (before doing more expensive checks) for speed.
        # Example: "advertising characteristic" appears 5000+ times per session!
        if ($line -match "advertising characteristic|battery level:") { return $false }
        
        # -----------------------------------------------------------------------------
        # STAGE 3a: Must-include patterns (always include - user-configured device patterns)
        # -----------------------------------------------------------------------------
        # If a line mentions YOUR specific devices (Wahoo KICKR, HRM, etc.), we ALWAYS
        # keep it. These are the devices you care about! User configured at top of script.
        $devicePatternRegex = ($DEVICE_PATTERNS -join "|")
        if ($line -match $devicePatternRegex) { return $true }
        
        # Also always keep shutdown events - they tell us how the session ended
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

# Helper functions
function Get-Timestamp($line) {
    if ($line -match '^\[(\d{2}:\d{2}:\d{2})\]') { return $matches[1] }
    return ""
}

function Get-LineColor($line) {
    # +-----------------------------------------------------------------------------+
    # | [TIP] TRY THIS! Customize the color coding                                 |
    # +-----------------------------------------------------------------------------+
    # | 1. Change "Yellow" to "Cyan" for connection attempts                       |
    # | 2. Add "Magenta" for warnings: if ($line -match "\[WARN\]") { "Magenta" } |
    # | 3. Make DNS errors stand out: if ($line -match "DNS") { "Red" }           |
    # | 4. Available colors: Black, DarkBlue, DarkGreen, DarkCyan, DarkRed,        |
    # |    DarkMagenta, DarkYellow, Gray, DarkGray, Blue, Green, Cyan,            |
    # |    Red, Magenta, Yellow, White                                             |
    # +-----------------------------------------------------------------------------+
    if ($line -match "\[ERROR\]|Error receiving|Error connecting|Error shutting down|Disconnected|Timeout|Failed to connect|has new connection status: disconnected") { return "Red" }
    if ($line -match "Reconnecting|Connecting to|ConnectWFTNP|Start scanning") { return "Yellow" }
    if ($line -match "Connected|established|active|has new connection status: connected") { return "Green" }
    return "White"
}

function ConvertFrom-TimeString($timeString) {
    # +-----------------------------------------------------------------------------+
    # | [WARNING] COMMON MISTAKE: Not validating input before parsing!              |
    # +-----------------------------------------------------------------------------+
    # | This function assumes $timeString is always "HH:MM:SS" format.             |
    # | What if it's empty? What if it's "invalid"? The script would CRASH!        |
    # |                                                                             |
    # | SAFER VERSION would add: if (-not $timeString) { return 0 }                |
    # | Or check: if ($timeString -notmatch '^\d{2}:\d{2}:\d{2}$') { return 0 }  |
    # |                                                                             |
    # | FOR THIS SCRIPT: We're safe because we ONLY call this with validated times |
    # | from Get-Timestamp function. But in real-world code, ALWAYS VALIDATE!      |
    # +-----------------------------------------------------------------------------+
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

Write-Verbose "[OK] Filtering complete!"
Write-Verbose "  Kept: $filteredCount lines ($([math]::Round($filteredCount/$totalLines*100, 1))%)"
Write-Verbose "  Removed: $excludedCount lines ($([math]::Round($excludedCount/$totalLines*100, 1))%)"
Write-Verbose ""
Write-Verbose "[STATS] LEARNING POINT: We removed $([math]::Round($excludedCount/$totalLines*100, 1))% of the file!"
Write-Verbose "   This is why filtering is important - most log data is noise."
Write-Verbose "   Focus on the signal (relevant events) not the noise (routine operations)."
Write-Verbose ""

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

Write-Verbose "==================================================================="
Write-Verbose "[TIME] LESSON: Parsing timeline (converting text to data structures)"
Write-Verbose "==================================================================="
Write-Verbose "WHY? Text is for humans to read. Data structures are for programs to process."
Write-Verbose ""
Write-Verbose "We're converting lines like:"
Write-Verbose "   '[18:51:05] Device connected' (text)"
Write-Verbose "Into objects like:"
Write-Verbose "   {Time:'18:51:05', Event:'Connection', Details:'...'} (data)"
Write-Verbose ""
Write-Verbose "[STATS] LEARNING POINT: Once in object/data form, we can:"
Write-Verbose "   - Sort events by time to see the sequence"
Write-Verbose "   - Group events by type (all errors together)"
Write-Verbose "   - Search for patterns (multiple errors in a row)"
Write-Verbose "   - Calculate time gaps (how long between events)"
Write-Verbose ""
Write-Verbose "Parsing $($filteredLines.Count) lines into timeline events..."
Write-Verbose ""

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
    # TEACHING MOMENT: The -Regex flag tells PowerShell to use regular expressions.
    # Regular expressions are like "super powerful text search" - way more flexible
    # than simple text matching! Example: 'Error.*connecting' matches both
    # "Error connecting" AND "Error while connecting to device"
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

Write-Verbose "[OK] Timeline parsing complete!"
Write-Verbose "  Created $($timeline.Count) timeline events from $($filteredLines.Count) lines"
Write-Verbose ""
Write-Verbose "[STATS] LEARNING POINT: From $($filteredLines.Count) lines of text, we extracted $($timeline.Count) meaningful events."
Write-Verbose "   This shows the power of data structures - we can now ANALYZE patterns"
Write-Verbose "   instead of just READING text. Programming is all about transforming"
Write-Verbose "   unstructured data (text) into structured data (objects) for analysis."
Write-Verbose ""

# =================================================================================
# STEP 3: ANALYZE THE TIMELINE (Find Patterns and Problems)
# =================================================================================
# Now we have a timeline of events, but we need to UNDERSTAND what happened.
# This is like a detective analyzing clues to solve a case!
#
# The analysis happens in FOUR PHASES:
#   Phase A: Organize events by type (connections, errors, etc.)
#   Phase B: Identify session boundaries (when did it start/end?)
#   Phase C: Filter out pre-session noise (ignore startup events)
#   Phase D: Detect problems and classify them
#
# WHY PHASE BY PHASE? Each phase builds on the previous one. We need to know
# when the session started (Phase B) before we can filter pre-session events (Phase C).
# =================================================================================

# Build narrative summary
$narrative = @()

Write-Verbose "==================================================================="
Write-Verbose " LESSON: Analyzing the timeline (pattern recognition)"
Write-Verbose "==================================================================="
Write-Verbose "WHY? We have events, but need to UNDERSTAND what they mean."
Write-Verbose ""
Write-Verbose "ANALYSIS STRATEGY: 4-phase approach"
Write-Verbose "   Phase A: Group events by type (connections, errors, etc.)"
Write-Verbose "   Phase B: Find session boundaries (start/end times)"
Write-Verbose "   Phase C: Filter pre-session noise (ignore startup)"
Write-Verbose "   Phase D: Detect problems and diagnose root causes"
Write-Verbose ""
Write-Verbose "[STATS] LEARNING POINT: This is like detective work!"
Write-Verbose "   We look for PATTERNS, SEQUENCES, and ANOMALIES to understand"
Write-Verbose "   what happened and WHY. Programming often involves this kind"
Write-Verbose "   of logical reasoning and root cause analysis."
Write-Verbose ""

# ---------------------------------------------------------------------------------
# PHASE A: Organize Events by Type (Grouping)
# ---------------------------------------------------------------------------------
# We have a big list of events in time order. But to analyze, we need them
# ORGANIZED by TYPE. It's like sorting a deck of cards by suit!
#
# Group-Object creates a "hash table" (dictionary) where:
#   Key = Event type ("BLE Connected", "Connection Error", etc.)
#   Value = Array of all events of that type
#
# This is MUCH faster than searching the entire timeline multiple times!
# Instead of "loop through 1000 events to find errors" (1000 checks),
# we do "get the 'Connection Error' group" (1 check).
# ---------------------------------------------------------------------------------
$eventsByType = $timeline | Group-Object -Property Event -AsHashTable

# Extract each event type into its own array for easy access
# The @() wrapper ensures we always get an array (even if empty or single item)
# +---------------------------------------------------------------------------------+
# | [WARNING] COMMON MISTAKE: Forgetting to check if arrays are empty!             |
# +---------------------------------------------------------------------------------+
# | If we write: $firstError = $errorEvents[0]                                     |
# | And $errorEvents is empty, PowerShell returns $null (not an error, but wrong!) |
# |                                                                                 |
# | SAFER: Always check .Count first:                                              |
# |   if ($errorEvents.Count -gt 0) { $firstError = $errorEvents[0] }             |
# |                                                                                 |
# | We use @() wrapper to ensure these are ALWAYS arrays (even if null/single)    |
# | Without @(), a single item wouldn't have .Count property!                      |
# +---------------------------------------------------------------------------------+
$connectionEvents = @($eventsByType["BLE Connected"])
$disconnectionEvents = @($eventsByType["BLE Disconnected"])
$errorEvents = @($eventsByType["Connection Error"])
$tcpDisconnects = @($eventsByType["TCP Disconnected"])
$dnsErrors = @($eventsByType["DNS Error"])
$timeouts = @($eventsByType["Connection Timeout"])
$serverHellos = @($eventsByType["Server Hello"])
$shutdownStarted = @($eventsByType["Shutdown Started"])

# ---------------------------------------------------------------------------------
# PHASE B: Identify Session Boundaries
# ---------------------------------------------------------------------------------
# A Zwift log file might contain events from BEFORE the actual ride started
# (app launching, initializing, etc.). We only care about events that happened
# DURING THE ACTUAL SESSION. So we need to find:
#   - When did the session START? (first "Server Hello" = connected to game)
#   - When did the session END? ("Shutdown Started" = user exited)
# ---------------------------------------------------------------------------------

# Session START = first time we connected to Zwift's game server
$sessionStartTime = if ($serverHellos.Count -gt 0) { $serverHellos[0].Time } else { "00:00:00" }

# Session END = when graceful shutdown began (or sentinel value if no shutdown found)
# TEACHING MOMENT: The sentinel value (99:99:99) is an "impossible time" that means
# "this never happened". It's like using -1 to mean "not found" in array searches.
$shutdownTime = $SENTINEL_TIME_MAX
if ($shutdownStarted.Count -gt 0) { $shutdownTime = $shutdownStarted[0].Time }

# ---------------------------------------------------------------------------------
# PHASE C: Filter to Post-Session-Start Events Only
# ---------------------------------------------------------------------------------
# WHY? Because errors during app startup aren't interesting. We only care about
# errors that happened DURING THE RIDE. It's like ignoring pre-game warmup and
# only analyzing the actual game.
#
# We filter ONCE here and store the results, rather than filtering repeatedly
# later in the code. This is a PERFORMANCE OPTIMIZATION - filter once, use many times!
# ---------------------------------------------------------------------------------
$postStartErrors = $errorEvents | Where-Object { $_.Time -gt $sessionStartTime }
$postStartTimeouts = $timeouts | Where-Object { $_.Time -gt $sessionStartTime }
$postStartDnsErrors = $dnsErrors | Where-Object { $_.Time -gt $sessionStartTime }

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
$problematicTcpDisconnects = $tcpDisconnects | Where-Object { $_.Time -gt $sessionStartTime }
$problematicDisconnections = $disconnectionEvents | Where-Object { $_.Time -lt $shutdownTime }

Write-Debug " DECISION: Filtering disconnects to find problems"
Write-Debug "  Total TCP disconnects: $($tcpDisconnects.Count)"
Write-Debug "  TCP disconnects during session: $($problematicTcpDisconnects.Count)"
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
# TEACHING MOMENT: This is an example of TIME-BASED ANALYSIS. We're not just
# counting events, we're measuring the TIME BETWEEN them to determine impact.
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

# Calculate session duration for narrative section (before building narrative)
$sessionDurationLine = ""
if ($serverHellos.Count -gt 0) {
    $startTime = $serverHellos[0].Time
    # Reuse the shutdownTime calculation from earlier (if not sentinel value)
    $endTime = if ($shutdownTime -ne $SENTINEL_TIME_MAX) { $shutdownTime } else { $null }
    
    if ($endTime) {
        $durationSeconds = (ConvertFrom-TimeString $endTime) - (ConvertFrom-TimeString $startTime)
        $sessionDurationLine = "- Session duration was " + (Format-Duration $durationSeconds)
    }
}

# =================================================================================
# STEP 4: BUILD THE DIAGNOSIS (Tell the Story)
# =================================================================================
# Now we've organized, filtered, and classified events. Time to build the
# human-readable narrative that explains what happened during the session.
#
# NARRATIVE STRUCTURE:
#   1. When did the session start?
#   2. Did any problems occur? If so, WHAT and WHEN?
#   3. Can we DIAGNOSE the root cause?
#   4. How did the session end?
#
# This is where we transform DATA into UNDERSTANDING!
# =================================================================================

if ($serverHellos.Count -gt 0) {
    $firstHello = $serverHellos[0]
    $narrative += "WHAT HAPPENED:"
    $narrative += "- Session started at $($firstHello.Time) - Connected to Zwift server"
    
    # Add duration if available
    if ($sessionDurationLine) {
        $narrative += $sessionDurationLine
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
    
    Write-Debug " DECISION: Does this session have problems?"
    Write-Debug "  Post-start errors: $($postStartErrors.Count)"
    Write-Debug "  Post-start timeouts: $($postStartTimeouts.Count)"
    Write-Debug "  Disruptive TCP disconnects: $($disruptiveTcpDisconnects.Count)"
    Write-Debug "  Device disconnections: $($problematicDisconnections.Count)"
    Write-Debug "  VERDICT: $(if ($hasProblems) { 'YES - Problems detected!' } else { 'NO - Clean session' })"
    
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
        # No problems detected = clean session! Good news!
        $narrative += "- Session ran without connection issues"
    }
    
    # Determine how session ended (reuse already-calculated shutdownTime)
    if ($shutdownStarted.Count -gt 0) {
        $narrative += "- Session ended at $($shutdownStarted[0].Time) - Graceful shutdown initiated"
    } else {
        $narrative += "- Session ended without graceful shutdown - May have crashed or been terminated"
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

# Resolution - only show for problematic sessions
if ($hasProblems -and $firstProblemTime) {
    $narrative += ""
    $narrative += "RESOLUTION:"
    
    # Check for recovery after the problem started
    $postProblemServerHellos = $serverHellos | Where-Object { $_.Time -gt $firstProblemTime }
    $postProblemConnections = $connectionEvents | Where-Object { $_.Time -gt $firstProblemTime }
    
    Write-Debug " DECISION: Looking for recovery after problem at $firstProblemTime"
    Write-Debug "  Server hellos after problem: $($postProblemServerHellos.Count)"
    Write-Debug "  Device connections after problem: $($postProblemConnections.Count)"
    
    # If the problem was internet-related (post-session DNS errors), report server reconnection
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
        $narrative += "- No recovery detected - session may have ended with errors"
    }
    
    # Add conclusions section for broader context
    $narrative += ""
    $narrative += "CONCLUSIONS:"
    
    # Provide context based on the type of problem encountered
    $postStartDnsErrors = $dnsErrors | Where-Object { $_.Time -gt $sessionStartTime }
    if ($postStartDnsErrors.Count -gt 0) {
        $narrative += "- Internet connectivity was lost during the session, causing DNS resolution failures"
        $narrative += "- This is typically caused by router issues, ISP problems, or local network disruption"
        $narrative += "- The problem is external to Zwift and the trainer - check your internet connection"
    } elseif ($problemType -eq "LAN device connection error") {
        # Check if we have the specific "actively refused" error
        $postStartErrors = $errorEvents | Where-Object { $_.Time -gt $sessionStartTime }
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
            $narrative += "- User must manually reconnect the trainer via standard BLE to continue the session"
            $narrative += "- Recommended actions: Power cycle the trainer, check for firmware updates, or contact manufacturer support"
            $narrative += "- Note: Automatic BLE fallback may be added in future firmware updates"
        } else {
            $narrative += "- DirectConnect (BLE/LAN) connection to the trainer failed during the session"
            $narrative += "- DirectConnect is a Bluetooth over wired LAN technology designed to avoid wireless interference"
            $narrative += "- Current firmware does NOT automatically fall back to standard BLE radio connection"
            $narrative += "- User intervention required: manually reconnect the trainer via Bluetooth to continue"
            $narrative += "- Possible causes: WiFi signal strength, router configuration, or trainer firmware issues"
            $narrative += "- Consider checking network setup, router placement, or updating trainer firmware"
        }
        
        # Note: Trainer details are now in the header section, not duplicated here in narrative
    } elseif ($problemType -match "Disruptive.*disconnection") {
        $narrative += "- Connection to Zwift servers was disrupted during the session"
        $narrative += "- This may be due to server maintenance, internet instability, or network congestion"
        $narrative += "- Session was able to reconnect, but temporary data loss may have occurred"
    } elseif ($problemType -match "TCP connection timeout") {
        $narrative += "- Communication with Zwift servers timed out during the session"
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

Write-Verbose "==================================================================="
Write-Verbose "[NOTE] LESSON: Generating final report (communicating results)"
Write-Verbose "==================================================================="
Write-Verbose "WHY? Analysis is useless if we can't explain our findings!"
Write-Verbose ""
Write-Verbose "REPORT STRUCTURE:"
Write-Verbose "   1. Summary: Quick overview (times, durations, statistics)"
Write-Verbose "   2. Narrative: Story of what happened (timeline)"
Write-Verbose "   3. Problems: Issues detected with root cause analysis"
Write-Verbose "   4. Recommendations: Actionable solutions"
Write-Verbose ""
Write-Verbose "Found $($narrative.Count) narrative points to include in report"
Write-Verbose ""
Write-Verbose "[STATS] LEARNING POINT: Good programming includes good communication!"
Write-Verbose "   The best analysis is worthless if users can't understand it."
Write-Verbose "   Always think about your AUDIENCE when formatting output."
Write-Verbose ""

$logFileName = Split-Path $ZwiftLogFilePath -Leaf
$filterEffectiveness = [math]::Round(($excludedCount / $totalLines) * 100, 1)

# Format numbers with comma separators for readability
$totalLinesFormatted = $totalLines.ToString("N0")
$filteredCountFormatted = $filteredCount.ToString("N0")
$excludedCountFormatted = $excludedCount.ToString("N0")

# Build formatted summary header with aligned columns
$summaryHeader = @"
===== Zwift Session Summary =====
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
