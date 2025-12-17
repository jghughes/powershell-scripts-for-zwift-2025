<#
.SYNOPSIS
    Analyzes Zwift log files to identify connection problems and session issues.

.DESCRIPTION
    Parses Zwift application log files, filters relevant connectivity events,
    and generates a diagnostic report distinguishing between clean sessions
    and problematic sessions with connection issues. Detects seamless server
    reconnections vs disruptive disconnects.

.PARAMETER LogPath
    Path to the Zwift log file to analyze (required).

.PARAMETER OutDir
    Output directory for filtered logs (optional, defaults to same directory as input).

.EXAMPLE
    .\zlog.ps1 "Log_2025-12-15.txt"
    Analyzes the specified log file and creates filtered output in the same directory.

.NOTES
    Designed for Zwift cycling application logs with BLE device connections.

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

param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$LogPath,
    
    [Parameter(Mandatory=$false)]
    [string]$OutDir
)

# ===== USER CONFIGURATION =====
# MODIFY THESE PATTERNS TO MATCH YOUR DEVICES
# Add or change device names/patterns as needed - these are used to filter relevant log lines
# Examples: "Wahoo KICKR", "Tacx", "Saris", "Elite", "HRM", "Garmin", etc.
$DEVICE_PATTERNS = @(
    "Wahoo KICKR",
    "HRMPro"
)

# ┌─────────────────────────────────────────────────────────────────────────────────┐
# │ 💡 TRY THIS! Customize for your own devices                                    │
# ├─────────────────────────────────────────────────────────────────────────────────┤
# │ 1. Add your trainer: "Tacx Neo", "Saris H3", "Elite Suito"                    │
# │ 2. Add your sensors: "Garmin", "Polar", "Stages"                               │
# │ 3. Use partial matches: "KICKR" matches both "KICKR V5" and "KICKR CORE"      │
# │ 4. Be specific if needed: "Wahoo KICKR 5404" matches only that serial number   │
# │                                                                                 │
# │ EXPERIMENT: Remove "HRMPro" and run the script. Notice how heart rate monitor  │
# │ events disappear from the filtered output! This shows how filtering works.     │
# └─────────────────────────────────────────────────────────────────────────────────┘

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
# before and after it to see if DirectConnect (Wahoo's ethernet feature) was involved.
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

# ┌─────────────────────────────────────────────────────────────────────────────────┐
# │ ⚠️  COMMON MISTAKE: Hardcoding magic numbers throughout your code!              │
# ├─────────────────────────────────────────────────────────────────────────────────┤
# │ Bad:  if ($timeDiff -le 5) { ... }    (What does 5 mean? Why 5?)              │
# │ Good: if ($timeDiff -le $SEAMLESS_RECONNECT_THRESHOLD_SECONDS) { ... }        │
# │                                                                                 │
# │ WHY IT MATTERS: If you decide to change 5 to 10, you'd have to find and       │
# │ update EVERY place you wrote "5". With constants, change it ONCE at the top!  │
# └─────────────────────────────────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────────────────────────────────┐
# │ 💡 TRY THIS! Experiment with different threshold values                         │
# ├─────────────────────────────────────────────────────────────────────────────────┤
# │ 1. Change $SEAMLESS_RECONNECT_THRESHOLD_SECONDS from 5 to 10                   │
# │    Run the script and see if more reconnections are now classified as seamless │
# │                                                                                 │
# │ 2. Change $MAX_ERROR_DETAIL_LENGTH from 250 to 100                             │
# │    Notice how error messages in the report become shorter                      │
# │                                                                                 │
# │ 3. Add your own constant: $MINIMUM_SESSION_DURATION = 300  (5 minutes)         │
# │    Then add code to warn if sessions are shorter than this!                    │
# └─────────────────────────────────────────────────────────────────────────────────┘

# ╔════════════════════════════════════════════════════════════════════════════════╗
# ║                          DATA FLOW VISUALIZATION                               ║
# ║                   How this script transforms log data                          ║
# ╚════════════════════════════════════════════════════════════════════════════════╝
#
#  Raw Log File              Filter Lines           Group Events         Analyze
#  ┌──────────┐             ┌──────────┐           ┌──────────┐        ┌──────────┐
#  │ 20,350   │────────────>│  1,280   │──────────>│ Errors:5 │───────>│ Report:  │
#  │  lines   │  Remove     │  lines   │  Identify │ Warns: 8 │  Find  │ Problems │
#  │          │  noise      │          │  patterns │ Info:1000│  root  │ Detected │
#  └──────────┘             └──────────┘           └──────────┘  cause └──────────┘
#       ↑                        ↑                      ↑              ↑
#       │                        │                      │              │
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

# ════════════════════════════════════════════════════════════════════════════════

# Resolve full path and derive output directory
$LogPath = Resolve-Path $LogPath | Select-Object -ExpandProperty Path
if (-not $OutDir) {
    # Default to production reports folder instead of input file location
    $OutDir = "C:\Users\johng\holding_pen\StuffForZwiftLogs\reports"
    # Create the directory if it doesn't exist
    if (-not (Test-Path $OutDir)) {
        New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
    }
}

# Timestamp for run
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$inputFileName = [System.IO.Path]::GetFileNameWithoutExtension($LogPath)
$OutPath = Join-Path $OutDir ("$inputFileName-filtered-$timestamp.txt")
$OutPathExcluded = Join-Path $OutDir ("$inputFileName-excluded-$timestamp.txt")

# ═════════════════════════════════════════════════════════════════════════════════
# 📚 VERBOSE MODE: Educational progress messages for learning
# ═════════════════════════════════════════════════════════════════════════════════
# Run with -Verbose flag to see step-by-step explanations of what's happening!
# Example: .\zlog.ps1 "logfile.txt" -Verbose
# ═════════════════════════════════════════════════════════════════════════════════

Write-Verbose "═══════════════════════════════════════════════════════════════════════════"
Write-Verbose "📖 LESSON: Reading the log file into memory"
Write-Verbose "═══════════════════════════════════════════════════════════════════════════"
Write-Verbose "WHY? We read the ENTIRE file at once instead of line-by-line because:"
Write-Verbose "  • Faster: One disk read vs. thousands of small reads"
Write-Verbose "  • Easier: We can process the data multiple times without re-reading"
Write-Verbose "  • Trade-off: Uses more RAM (20MB file = 20MB RAM)"
Write-Verbose ""
Write-Verbose "Reading from: $LogPath"

# Read all lines once for efficiency
$allLines = Get-Content -Path $LogPath
$totalLines = $allLines.Count

Write-Verbose "✓ Successfully read $totalLines lines into memory"
Write-Verbose "  Memory used: approximately $([math]::Round($totalLines * 80 / 1MB, 2)) MB (assuming ~80 chars/line)"
Write-Verbose ""

# Define search patterns (consolidated for maintainability)
$searchPatterns = @(
    # Connectivity patterns
    "\bUDP\b","\bTCP\b","\bSocket\b","\bmDNS\b","\bDirectConnect\b","\bConnectionManager\b",
    "\bWiFi\b","\bBLE\b","\bBTLE\b","\bBluetooth\b","\bANT\+\b","\bLAN Exercise Device\b",
    # Shutdown indicators
    "shutdown","gracefully","destroyed","ZWATCHDOG"
) + $DEVICE_PATTERNS  # Add user-configured device patterns

# ═════════════════════════════════════════════════════════════════════════════════
# STEP 1: FILTER THE LOG FILE (Remove the Noise)
# ═════════════════════════════════════════════════════════════════════════════════
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
# ═════════════════════════════════════════════════════════════════════════════════

Write-Verbose "═══════════════════════════════════════════════════════════════════════════"
Write-Verbose "🔍 LESSON: Filtering log lines (removing noise)"
Write-Verbose "═══════════════════════════════════════════════════════════════════════════"
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
        
        # ─────────────────────────────────────────────────────────────────────────────
        # STAGE 2: High-priority exclusions (always exclude)
        # ─────────────────────────────────────────────────────────────────────────────
        # These patterns appear THOUSANDS of times and are NEVER useful for diagnosis.
        # We check them FIRST (before doing more expensive checks) for speed.
        # Example: "advertising characteristic" appears 5000+ times per session!
        if ($line -match "advertising characteristic|battery level:") { return $false }
        
        # ─────────────────────────────────────────────────────────────────────────────
        # STAGE 3a: Must-include patterns (always include - user-configured device patterns)
        # ─────────────────────────────────────────────────────────────────────────────
        # If a line mentions YOUR specific devices (Wahoo KICKR, HRM, etc.), we ALWAYS
        # keep it. These are the devices you care about! User configured at top of script.
        $devicePatternRegex = ($DEVICE_PATTERNS -join "|")
        if ($line -match $devicePatternRegex) { return $true }
        
        # Also always keep shutdown events - they tell us how the session ended
        if ($line -match "Gracefully Shutdown|ZWATCHDOG.*Destroyed|\[OS\].*Shutdown|\[GAME\].*Shutdown|RubberbandingConfig shutdown|AutoSteeringConfig shutdown") { return $true }
        
        # ─────────────────────────────────────────────────────────────────────────────
        # STAGE 3b: Standard exclusion filters (remove noise)
        # ─────────────────────────────────────────────────────────────────────────────
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
    # ┌─────────────────────────────────────────────────────────────────────────────┐
    # │ 💡 TRY THIS! Customize the color coding                                    │
    # ├─────────────────────────────────────────────────────────────────────────────┤
    # │ 1. Change "Yellow" to "Cyan" for connection attempts                       │
    # │ 2. Add "Magenta" for warnings: if ($line -match "\[WARN\]") { "Magenta" } │
    # │ 3. Make DNS errors stand out: if ($line -match "DNS") { "Red" }           │
    # │ 4. Available colors: Black, DarkBlue, DarkGreen, DarkCyan, DarkRed,        │
    # │    DarkMagenta, DarkYellow, Gray, DarkGray, Blue, Green, Cyan,            │
    # │    Red, Magenta, Yellow, White                                             │
    # └─────────────────────────────────────────────────────────────────────────────┘
    if ($line -match "\[ERROR\]|Error receiving|Error connecting|Error shutting down|Disconnected|Timeout|Failed to connect|has new connection status: disconnected") { return "Red" }
    if ($line -match "Reconnecting|Connecting to|ConnectWFTNP|Start scanning") { return "Yellow" }
    if ($line -match "Connected|established|active|has new connection status: connected") { return "Green" }
    return "White"
}

function ConvertFrom-TimeString($timeString) {
    # ┌─────────────────────────────────────────────────────────────────────────────┐
    # │ ⚠️  COMMON MISTAKE: Not validating input before parsing!                    │
    # ├─────────────────────────────────────────────────────────────────────────────┤
    # │ This function assumes $timeString is always "HH:MM:SS" format.             │
    # │ What if it's empty? What if it's "invalid"? The script would CRASH!        │
    # │                                                                             │
    # │ SAFER VERSION would add: if (-not $timeString) { return 0 }                │
    # │ Or check: if ($timeString -notmatch '^\d{2}:\d{2}:\d{2}$') { return 0 }  │
    # │                                                                             │
    # │ FOR THIS SCRIPT: We're safe because we ONLY call this with validated times │
    # │ from Get-Timestamp function. But in real-world code, ALWAYS VALIDATE!      │
    # └─────────────────────────────────────────────────────────────────────────────┘
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

function Get-TrainerInfo($logLines) {
    $info = @{
        DeviceName = ""
        HardwareRev = ""
        FirmwareVer = ""
        SerialNumber = ""
        Features = ""
    }
    
    foreach ($line in $logLines) {
        if ($line -match '"(Wahoo KICKR [^"]+)" hardware revision number: (.+)') {
            $info.DeviceName = $matches[1]
            $info.HardwareRev = $matches[2]
        }
        if ($line -match '\[BLE\] "(Wahoo KICKR [^"]+)" firmware version: (.+)') {
            $info.FirmwareVer = $matches[2]
        }
        if ($line -match '\[ZwiftProtocol\] Device serial number: (.+)') {
            $info.SerialNumber = $matches[1]
        }
        if ($line -match '\[BLE\] Wahoo KICKR Features Supported: (\d+) Enabled: (\d+)') {
            $info.Features = "Supported: $($matches[1]), Enabled: $($matches[2])"
        }
        
        # Early exit optimization: stop searching once all fields are populated
        if ($info.DeviceName -and $info.HardwareRev -and $info.FirmwareVer -and $info.SerialNumber -and $info.Features) {
            break
        }
    }
    
    return $info
}

function Add-ProblemEntries($eventCollection, $formatScript) {
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

# Save filtered lines to file (plain text, no colors)
$filteredLines = $filtered | ForEach-Object { $_.Line }
$filteredLines | Out-File -FilePath $OutPath -Encoding utf8

# Save excluded lines to separate file
$excludedLines = $allLines | Where-Object { $_ -notin $filteredLines }
$excludedLines | Out-File -FilePath $OutPathExcluded -Encoding utf8

# Calculate line counts
$filteredCount = $filteredLines.Count
$excludedCount = $excludedLines.Count

Write-Verbose "✓ Filtering complete!"
Write-Verbose "  Kept: $filteredCount lines ($([math]::Round($filteredCount/$totalLines*100, 1))%)"
Write-Verbose "  Removed: $excludedCount lines ($([math]::Round($excludedCount/$totalLines*100, 1))%)"
Write-Verbose ""
Write-Verbose "📊 LEARNING POINT: We removed $([math]::Round($excludedCount/$totalLines*100, 1))% of the file!"
Write-Verbose "   This is why filtering is important - most log data is noise."
Write-Verbose "   Focus on the signal (relevant events) not the noise (routine operations)."
Write-Verbose ""

# ═════════════════════════════════════════════════════════════════════════════════
# STEP 2: BUILD EVENT TIMELINE (Convert Lines to Structured Events)
# ═════════════════════════════════════════════════════════════════════════════════
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
# ═════════════════════════════════════════════════════════════════════════════════

Write-Verbose "═══════════════════════════════════════════════════════════════════"
Write-Verbose "⏱️ LESSON: Parsing timeline (converting text to data structures)"
Write-Verbose "═══════════════════════════════════════════════════════════════════"
Write-Verbose "WHY? Text is for humans to read. Data structures are for programs to process."
Write-Verbose ""
Write-Verbose "We're converting lines like:"
Write-Verbose "   '[18:51:05] Device connected' (text)"
Write-Verbose "Into objects like:"
Write-Verbose "   {Time:'18:51:05', Event:'Connection', Details:'...'} (data)"
Write-Verbose ""
Write-Verbose "📊 LEARNING POINT: Once in object/data form, we can:"
Write-Verbose "   • Sort events by time to see the sequence"
Write-Verbose "   • Group events by type (all errors together)"
Write-Verbose "   • Search for patterns (multiple errors in a row)"
Write-Verbose "   • Calculate time gaps (how long between events)"
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
    
    # ─────────────────────────────────────────────────────────────────────────────────
    # Pattern matching: identify and categorize events
    # ─────────────────────────────────────────────────────────────────────────────────
    # This SWITCH statement is like a "pattern recognition engine":
    #   - It looks at the line text
    #   - Matches it against patterns (using regular expressions)
    #   - Creates the appropriate event object
    #
    # TEACHING MOMENT: The -Regex flag tells PowerShell to use regular expressions.
    # Regular expressions are like "super powerful text search" - way more flexible
    # than simple text matching! Example: 'Error.*connecting' matches both
    # "Error connecting" AND "Error while connecting to device"
    # ─────────────────────────────────────────────────────────────────────────────────
    switch -Regex ($line) {
        'Device: "(Wahoo KICKR \d+|HRMPro\+:\d+)" has new connection status: connected' {
            $device = $matches[1]
            # Detect DirectConnect by searching a window of nearby lines for LAN connection indicators
            # This works because DirectConnect events appear close to the connection status change
            $contextStart = [Math]::Max(0, $i - $DIRECTCONNECT_CONTEXT_BEFORE)
            $contextEnd = [Math]::Min($filteredLines.Count - 1, $i + $DIRECTCONNECT_CONTEXT_AFTER)
            $context = $filteredLines[$contextStart..$contextEnd] -join " "
            $connType = if ($context -match "\[$time\].*(BLE \(LAN\)|LAN Exercise Device.*$device)") { "via DirectConnect" } else { "via BLE" }
            $timeline += [PSCustomObject]@{ Time=$time; Event="BLE Connected"; Details="$device $connType" }
        }
        'Device: "(Wahoo KICKR \d+|HRMPro\+:\d+)" has new connection status: disconnected' {
            $timeline += [PSCustomObject]@{ Time=$time; Event="BLE Disconnected"; Details=$matches[1] }
        }
        '\[ERROR\].*(Error receiving|Error connecting).*Wahoo KICKR' {
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

Write-Verbose "✓ Timeline parsing complete!"
Write-Verbose "  Created $($timeline.Count) timeline events from $($filteredLines.Count) lines"
Write-Verbose ""
Write-Verbose "📊 LEARNING POINT: From $($filteredLines.Count) lines of text, we extracted $($timeline.Count) meaningful events."
Write-Verbose "   This shows the power of data structures - we can now ANALYZE patterns"
Write-Verbose "   instead of just READING text. Programming is all about transforming"
Write-Verbose "   unstructured data (text) into structured data (objects) for analysis."
Write-Verbose ""

# ═════════════════════════════════════════════════════════════════════════════════
# STEP 3: ANALYZE THE TIMELINE (Find Patterns and Problems)
# ═════════════════════════════════════════════════════════════════════════════════
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
# ═════════════════════════════════════════════════════════════════════════════════

# Build narrative summary
$narrative = @()

Write-Verbose "═══════════════════════════════════════════════════════════════════"
Write-Verbose "🔬 LESSON: Analyzing the timeline (pattern recognition)"
Write-Verbose "═══════════════════════════════════════════════════════════════════"
Write-Verbose "WHY? We have events, but need to UNDERSTAND what they mean."
Write-Verbose ""
Write-Verbose "ANALYSIS STRATEGY: 4-phase approach"
Write-Verbose "   Phase A: Group events by type (connections, errors, etc.)"
Write-Verbose "   Phase B: Find session boundaries (start/end times)"
Write-Verbose "   Phase C: Filter pre-session noise (ignore startup)"
Write-Verbose "   Phase D: Detect problems and diagnose root causes"
Write-Verbose ""
Write-Verbose "📊 LEARNING POINT: This is like detective work!"
Write-Verbose "   We look for PATTERNS, SEQUENCES, and ANOMALIES to understand"
Write-Verbose "   what happened and WHY. Programming often involves this kind"
Write-Verbose "   of logical reasoning and root cause analysis."
Write-Verbose ""

# ─────────────────────────────────────────────────────────────────────────────────
# PHASE A: Organize Events by Type (Grouping)
# ─────────────────────────────────────────────────────────────────────────────────
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
# ─────────────────────────────────────────────────────────────────────────────────
$eventsByType = $timeline | Group-Object -Property Event -AsHashTable

# Extract each event type into its own array for easy access
# The @() wrapper ensures we always get an array (even if empty or single item)
# ┌─────────────────────────────────────────────────────────────────────────────────┐
# │ ⚠️  COMMON MISTAKE: Forgetting to check if arrays are empty!                   │
# ├─────────────────────────────────────────────────────────────────────────────────┤
# │ If we write: $firstError = $errorEvents[0]                                     │
# │ And $errorEvents is empty, PowerShell returns $null (not an error, but wrong!) │
# │                                                                                 │
# │ SAFER: Always check .Count first:                                              │
# │   if ($errorEvents.Count -gt 0) { $firstError = $errorEvents[0] }             │
# │                                                                                 │
# │ We use @() wrapper to ensure these are ALWAYS arrays (even if null/single)    │
# │ Without @(), a single item wouldn't have .Count property!                      │
# └─────────────────────────────────────────────────────────────────────────────────┘
$connectionEvents = @($eventsByType["BLE Connected"])
$disconnectionEvents = @($eventsByType["BLE Disconnected"])
$errorEvents = @($eventsByType["Connection Error"])
$tcpDisconnects = @($eventsByType["TCP Disconnected"])
$dnsErrors = @($eventsByType["DNS Error"])
$timeouts = @($eventsByType["Connection Timeout"])
$serverHellos = @($eventsByType["Server Hello"])
$shutdownStarted = @($eventsByType["Shutdown Started"])

# ─────────────────────────────────────────────────────────────────────────────────
# PHASE B: Identify Session Boundaries
# ─────────────────────────────────────────────────────────────────────────────────
# A Zwift log file might contain events from BEFORE the actual ride started
# (app launching, initializing, etc.). We only care about events that happened
# DURING THE ACTUAL SESSION. So we need to find:
#   - When did the session START? (first "Server Hello" = connected to game)
#   - When did the session END? ("Shutdown Started" = user exited)
# ─────────────────────────────────────────────────────────────────────────────────

# Session START = first time we connected to Zwift's game server
$sessionStartTime = if ($serverHellos.Count -gt 0) { $serverHellos[0].Time } else { "00:00:00" }

# Session END = when graceful shutdown began (or sentinel value if no shutdown found)
# TEACHING MOMENT: The sentinel value (99:99:99) is an "impossible time" that means
# "this never happened". It's like using -1 to mean "not found" in array searches.
$shutdownTime = $SENTINEL_TIME_MAX
if ($shutdownStarted.Count -gt 0) { $shutdownTime = $shutdownStarted[0].Time }

# ─────────────────────────────────────────────────────────────────────────────────
# PHASE C: Filter to Post-Session-Start Events Only
# ─────────────────────────────────────────────────────────────────────────────────
# WHY? Because errors during app startup aren't interesting. We only care about
# errors that happened DURING THE RIDE. It's like ignoring pre-game warmup and
# only analyzing the actual game.
#
# We filter ONCE here and store the results, rather than filtering repeatedly
# later in the code. This is a PERFORMANCE OPTIMIZATION - filter once, use many times!
# ─────────────────────────────────────────────────────────────────────────────────
$postStartErrors = $errorEvents | Where-Object { $_.Time -gt $sessionStartTime }
$postStartTimeouts = $timeouts | Where-Object { $_.Time -gt $sessionStartTime }
$postStartDnsErrors = $dnsErrors | Where-Object { $_.Time -gt $sessionStartTime }

# ─────────────────────────────────────────────────────────────────────────────────
# PHASE D: Detect Problems and Classify Them
# ─────────────────────────────────────────────────────────────────────────────────
# Not all disconnections are problems! Some are expected/harmless:
#   - Device disconnects at shutdown (user is exiting anyway)
#   - TCP disconnect followed by instant reconnect (< 5 sec = seamless server switch)
#
# Our goal: Separate REAL problems from routine events
# ─────────────────────────────────────────────────────────────────────────────────

# Filter to disconnects that happened DURING the ride (not at shutdown)
$problematicTcpDisconnects = $tcpDisconnects | Where-Object { $_.Time -gt $sessionStartTime }
$problematicDisconnections = $disconnectionEvents | Where-Object { $_.Time -lt $shutdownTime }

Write-Debug "🔍 DECISION: Filtering disconnects to find problems"
Write-Debug "  Total TCP disconnects: $($tcpDisconnects.Count)"
Write-Debug "  TCP disconnects during session: $($problematicTcpDisconnects.Count)"
Write-Debug "  Device disconnections before shutdown: $($problematicDisconnections.Count)"
Write-Debug "  LOGIC: Ignoring shutdown events - users expect disconnects when exiting"

# ─────────────────────────────────────────────────────────────────────────────────
# SEAMLESS vs DISRUPTIVE Reconnections (The Smart Part!)
# ─────────────────────────────────────────────────────────────────────────────────
# Zwift's servers sometimes switch you between machines for load balancing.
# If done quickly (< 5 seconds), you won't even notice - this is SEAMLESS.
# If it takes longer, or fails to reconnect, that's DISRUPTIVE.
#
# ALGORITHM:
#   For each TCP disconnect:
#     1. Look for a "Server Hello" after it
#     2. Calculate time difference
#     3. If ≤ 5 seconds = seamless (ignore it)
#     4. If > 5 seconds or no reconnect = disruptive (report it!)
#
# TEACHING MOMENT: This is an example of TIME-BASED ANALYSIS. We're not just
# counting events, we're measuring the TIME BETWEEN them to determine impact.
# ─────────────────────────────────────────────────────────────────────────────────
$disruptiveTcpDisconnects = @()
$seamlessReconnectTimes = @()
foreach ($disconnect in $problematicTcpDisconnects) {
    # Convert time string to TimeSpan for math: "18:51:05" → 18h 51m 5s
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
            Write-Debug "  ✓ SEAMLESS: Disconnect at $($disconnect.Time) reconnected in $([math]::Round($timeDiff, 1))s - ignoring (load balancing)"
            break
        }
        if ($timeDiff -gt $SEAMLESS_RECONNECT_THRESHOLD_SECONDS) { break }  # No point checking later hellos
    }
    if (-not $hasQuickReconnect) {
        $disruptiveTcpDisconnects += $disconnect
        Write-Debug "  ⚠️ DISRUPTIVE: Disconnect at $($disconnect.Time) - no quick reconnect found (PROBLEM!)"
    }
}

Write-Debug "🔍 ANALYSIS RESULT:"
Write-Debug "  Seamless reconnects (ignored): $($seamlessReconnectTimes.Count)"
Write-Debug "  Disruptive disconnects (problems): $($disruptiveTcpDisconnects.Count)"

# ═════════════════════════════════════════════════════════════════════════════════
# STEP 4: BUILD THE DIAGNOSIS (Tell the Story)
# ═════════════════════════════════════════════════════════════════════════════════
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
# ═════════════════════════════════════════════════════════════════════════════════

if ($serverHellos.Count -gt 0) {
    $firstHello = $serverHellos[0]
    $narrative += "WHAT HAPPENED:"
    $narrative += "• Session started at $($firstHello.Time) - Connected to Zwift server"
    
    # Identify first problem if any
    $firstProblemTime = $null
    $problemType = ""
    
    # ─────────────────────────────────────────────────────────────────────────────────
    # PROBLEM DETECTION: Do we have any issues?
    # ─────────────────────────────────────────────────────────────────────────────────
    # We combine all our filtered problem arrays and check if ANY exist.
    # This is BOOLEAN LOGIC: If (errors OR timeouts OR disconnects) then hasProblems = true
    # ─────────────────────────────────────────────────────────────────────────────────
    $allProblems = @($postStartErrors) + @($postStartTimeouts) + @($disruptiveTcpDisconnects) + @($problematicDisconnections)
    $hasProblems = $allProblems.Count -gt 0
    
    Write-Debug "🔍 DECISION: Does this session have problems?"
    Write-Debug "  Post-start errors: $($postStartErrors.Count)"
    Write-Debug "  Post-start timeouts: $($postStartTimeouts.Count)"
    Write-Debug "  Disruptive TCP disconnects: $($disruptiveTcpDisconnects.Count)"
    Write-Debug "  Device disconnections: $($problematicDisconnections.Count)"
    Write-Debug "  VERDICT: $(if ($hasProblems) { 'YES - Problems detected!' } else { 'NO - Clean session' })"
    
    if ($hasProblems) {
        # ─────────────────────────────────────────────────────────────────────────────────
        # FIND THE FIRST PROBLEM (Root Cause Analysis)
        # ─────────────────────────────────────────────────────────────────────────────────
        # Often, the FIRST problem causes a cascade of other issues. So we need to find
        # which problem happened EARLIEST. This is like being a detective looking for
        # the "original crime" that set everything else in motion!
        #
        # ALGORITHM:
        #   1. Collect all problem types with their timestamps
        #   2. Sort by time (earliest first)
        #   3. The first one is likely the root cause
        # ─────────────────────────────────────────────────────────────────────────────────
        $problemCandidates = @()
        
        # Collect each type of problem with a descriptive label
        if ($postStartErrors.Count) { $problemCandidates += @{Time=$postStartErrors[0].Time; Type="LAN device connection error"} }
        if ($postStartTimeouts.Count) { $problemCandidates += @{Time=$postStartTimeouts[0].Time; Type="TCP connection timeout"} }
        if ($disruptiveTcpDisconnects.Count) { $problemCandidates += @{Time=$disruptiveTcpDisconnects[0].Time; Type="Disruptive Zwift server disconnection"} }
        
        # Find the earliest problem (sort by time, take first)
        # TEACHING MOMENT: Sort-Object with a script block {$_.Time} sorts by the Time property
        if ($problemCandidates.Count) {
            Write-Debug "🔍 DECISION: Finding root cause (earliest problem)"
            Write-Debug "  Problem candidates found: $($problemCandidates.Count)"
            foreach ($candidate in $problemCandidates) {
                Write-Debug "    - $($candidate.Time): $($candidate.Type)"
            }
            $earliestProblem = $problemCandidates | Sort-Object {$_.Time} | Select-Object -First 1
            $firstProblemTime = $earliestProblem.Time
            $problemType = $earliestProblem.Type
            Write-Debug "  ROOT CAUSE: $problemType at $firstProblemTime (earliest event)"
        }
        
        $narrative += "• System ran normally until $firstProblemTime"
        $narrative += "• First problem encountered: $problemType"
        
        # ─────────────────────────────────────────────────────────────────────────────────
        # DIAGNOSIS: What's the root cause?
        # ─────────────────────────────────────────────────────────────────────────────────
        # Based on the problem type and patterns, we provide a SPECIFIC diagnosis.
        # This is CONDITIONAL LOGIC: if-elseif-else chains to determine the cause.
        # ─────────────────────────────────────────────────────────────────────────────────
        Write-Debug "🔍 DIAGNOSIS: Determining root cause"
        if ($postStartDnsErrors.Count -gt 0) {
            # DNS errors = can't convert domain names to IP addresses = no internet!
            Write-Debug "  DIAGNOSIS: Internet connectivity failure"
            Write-Debug "  EVIDENCE: DNS resolution errors detected"
            Write-Debug "  MEANING: Can't translate domain names to IP addresses = no internet"
            $narrative += "• DIAGNOSIS: Internet connectivity lost (DNS resolution failures detected)"
        } elseif ($problemType -eq "LAN device connection error") {
            # LAN errors could be general connection failures OR specific "actively refused"
            # We check the error details to be more specific
            Write-Debug "  DIAGNOSIS: LAN device connection error"
            Write-Debug "  Checking for specific 'actively refused' pattern..."
            $activelyRefusedError = $postStartErrors | Where-Object { $_.Details -match "actively refused" -and $_.Details -match "LAN Exercise Device" }
            Write-Debug "  'Actively refused' errors found: $($activelyRefusedError.Count)"
            if ($activelyRefusedError) {
                # "Actively refused" = the trainer REJECTED the connection (firmware bug)
                $narrative += "• DIAGNOSIS: Trainer's DirectConnect service rejected connection attempts (firmware/service failure)"
            } else {
                # Generic LAN/DirectConnect failure
                $narrative += "• DIAGNOSIS: DirectConnect (BLE/LAN) connection failure with trainer"
            }
        }
    } else {
        # No problems detected = clean session! Good news!
        $narrative += "• Session ran without connection issues"
    }
    
    # Determine how session ended (reuse already-calculated shutdownTime)
    if ($shutdownStarted.Count -gt 0) {
        $narrative += "• Session ended at $($shutdownStarted[0].Time) - Graceful shutdown initiated"
    } else {
        $narrative += "• Session ended without graceful shutdown - May have crashed or been terminated"
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
            Write-Debug "🔍 DECISION: Finding server reconnects near problem time"
            Write-Debug "  Problem occurred at: $($postStartErrors[0].Time)"
            Write-Debug "  Checking $($seamlessReconnectTimes.Count) seamless reconnects for proximity"
            foreach ($reconnectTime in $seamlessReconnectTimes) {
                $reconTime = [TimeSpan]::ParseExact($reconnectTime, "hh\:mm\:ss", $null)
                $timeDiff = [Math]::Abs(($reconTime - $problemTime).TotalSeconds)
                if ($timeDiff -le $PROBLEM_PROXIMITY_SECONDS) {  # Within 2 minutes of problem
                    $relevantReconnects += $reconnectTime
                    Write-Debug "  ✓ Reconnect at $reconnectTime is within $([math]::Round($timeDiff))s of problem (RELEVANT)"
                } else {
                    Write-Debug "  ✗ Reconnect at $reconnectTime is $([math]::Round($timeDiff))s away (too far)"
                }
            }
            Write-Debug "  RESULT: $($relevantReconnects.Count) relevant reconnections to report"
        }
        
        # Only show if there are relevant reconnections near the problem
        if ($relevantReconnects.Count -gt 0) {
            if ($relevantReconnects.Count -eq 1) {
                $narrative += "• Server reconnection at $($relevantReconnects[0]) (possibly related to connection issue)"
            } else {
                $narrative += "• $($relevantReconnects.Count) server reconnections near problem time:"
                foreach ($time in $relevantReconnects) {
                    $narrative += "  - Reconnected at $time"
                }
            }
        }
    }
}

# Problems section - only show if problems exist
if ($hasProblems) {
    $narrative += ""
    $narrative += "PROBLEMS DETECTED:"
    $narrative += "The following log entries indicated problems during the session:"
    $narrative += ""
    
    # Collect all problem events with their original log entries using helper function
    $allProblems = @()
    $allProblems += Add-ProblemEntries $postStartErrors { param($e) $e.Details }
    $allProblems += Add-ProblemEntries $disruptiveTcpDisconnects { param($e) "[$($e.Time)] [INFO] TCP disconnected" }
    $allProblems += Add-ProblemEntries $postStartDnsErrors { param($e) "[$($e.Time)] [ERROR] Could not resolve hostname" }
    $allProblems += Add-ProblemEntries $problematicDisconnections { param($e) "[$($e.Time)] [BLE] Device: `"$($e.Details)`" has new connection status: disconnected" }
    
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
    
    Write-Debug "🔍 DECISION: Looking for recovery after problem at $firstProblemTime"
    Write-Debug "  Server hellos after problem: $($postProblemServerHellos.Count)"
    Write-Debug "  Device connections after problem: $($postProblemConnections.Count)"
    
    # If the problem was internet-related (post-session DNS errors), report server reconnection
    if ($postStartDnsErrors.Count -gt 0 -and $postProblemServerHellos.Count -gt 0) {
        $reconnectTime = $postProblemServerHellos[0].Time
        $narrative += "• Connection automatically restored at $reconnectTime when internet connectivity returned"
    } 
    # For device connection issues (like BLE/LAN or DirectConnect failures), show device reconnection
    elseif ($postProblemConnections.Count -gt 0) {
        # Find trainer connections if the problem was a LAN device error
        $trainerConnections = $postProblemConnections | Where-Object { $_.Details -match "Wahoo KICKR" }
        
        if ($trainerConnections.Count -gt 0 -and $problemType -match "LAN device") {
            # For trainer LAN/DirectConnect issues, show trainer reconnection
            $recoveryConnect = $trainerConnections[0]
            $narrative += "• Trainer reconnected at $($recoveryConnect.Time) - $($recoveryConnect.Details)"
            
            # Check if DirectConnect was abandoned for standard BLE
            if ($recoveryConnect.Details -match "via BLE" -and $recoveryConnect.Details -notmatch "DirectConnect") {
                $narrative += "• DirectConnect (BLE/LAN) failed - switched to standard BLE radio connection"
            }
        } else {
            # For other device issues, show first reconnection
            $recoveryConnect = $postProblemConnections[0]
            $narrative += "• Device reconnected at $($recoveryConnect.Time) - $($recoveryConnect.Details)"
        }
    } else {
        $narrative += "• No recovery detected - session may have ended with errors"
    }
    
    # Add conclusions section for broader context
    $narrative += ""
    $narrative += "CONCLUSIONS:"
    
    # Provide context based on the type of problem encountered
    $postStartDnsErrors = $dnsErrors | Where-Object { $_.Time -gt $sessionStartTime }
    if ($postStartDnsErrors.Count -gt 0) {
        $narrative += "• Internet connectivity was lost during the session, causing DNS resolution failures"
        $narrative += "• This is typically caused by router issues, ISP problems, or local network disruption"
        $narrative += "• The problem is external to Zwift and the trainer - check your internet connection"
    } elseif ($problemType -eq "LAN device connection error") {
        # Check if we have the specific "actively refused" error
        $postStartErrors = $errorEvents | Where-Object { $_.Time -gt $sessionStartTime }
        $activelyRefusedError = $postStartErrors | Where-Object { $_.Details -match "actively refused" -and $_.Details -match "LAN Exercise Device" }
        
        # Extract trainer hardware/software details for support ticket
        $trainerInfo = Get-TrainerInfo $allLines
        
        if ($activelyRefusedError) {
            Write-Debug "🔍 DIAGNOSIS: DirectConnect service failure detected"
            Write-Debug "  EVIDENCE: 'actively refused' error in LAN Exercise Device messages"
            Write-Debug "  CONCLUSION: Trainer DirectConnect firmware/service crashed"
            Write-Debug "  RECOMMENDATION: Manual BLE reconnection required"
            $narrative += "• The trainer was reachable on the network but its DirectConnect service rejected connections"
            $narrative += "• DirectConnect is Wahoo's wired ethernet technology designed to eliminate wireless interference"
            $narrative += "• This specific error indicates the trainer's DirectConnect firmware/service crashed or malfunctioned"
            $narrative += "• IMPORTANT: Current firmware does NOT automatically fall back to Bluetooth - manual intervention required"
            $narrative += "• User must manually reconnect the trainer via standard BLE to continue the session"
            $narrative += "• Recommended actions: Power cycle the trainer, check for firmware updates, or contact Wahoo support"
            $narrative += "• Note: Automatic BLE fallback may be added in future firmware updates"
        } else {
            $narrative += "• DirectConnect (BLE/LAN) connection to the trainer failed during the session"
            $narrative += "• DirectConnect is Wahoo's wired ethernet technology designed to avoid wireless interference"
            $narrative += "• Current firmware does NOT automatically fall back to standard BLE radio connection"
            $narrative += "• User intervention required: manually reconnect the trainer via Bluetooth to continue"
            $narrative += "• Possible causes: WiFi signal strength, router configuration, or trainer firmware issues"
            $narrative += "• Consider checking network setup, router placement, or updating trainer firmware"
        }
        
        # Add trainer hardware/software details if available
        if ($trainerInfo.DeviceName -or $trainerInfo.SerialNumber) {
            $narrative += ""
            $narrative += "TRAINER DETAILS (for Wahoo support ticket):"
            if ($trainerInfo.DeviceName) { $narrative += "• Device: $($trainerInfo.DeviceName)" }
            if ($trainerInfo.SerialNumber) { $narrative += "• Serial Number: $($trainerInfo.SerialNumber)" }
            if ($trainerInfo.HardwareRev) { $narrative += "• Hardware Revision: $($trainerInfo.HardwareRev)" }
            if ($trainerInfo.FirmwareVer) { $narrative += "• Firmware Version: $($trainerInfo.FirmwareVer)" }
            if ($trainerInfo.Features) { $narrative += "• Features: $($trainerInfo.Features)" }
        }
    } elseif ($problemType -match "Disruptive.*disconnection") {
        $narrative += "• Connection to Zwift servers was disrupted during the session"
        $narrative += "• This may be due to server maintenance, internet instability, or network congestion"
        $narrative += "• Session was able to reconnect, but temporary data loss may have occurred"
    } elseif ($problemType -match "TCP connection timeout") {
        $narrative += "• Communication with Zwift servers timed out during the session"
        $narrative += "• This typically indicates network latency or packet loss issues"
        $narrative += "• Check your internet connection quality and router performance"
    }
}

# Build summary footer text
$narrativeText = if ($narrative.Count -gt 0) { "`n" + ($narrative -join "`n") + "`n" } else { "" }

Write-Verbose "═══════════════════════════════════════════════════════════════════"
Write-Verbose "📝 LESSON: Generating final report (communicating results)"
Write-Verbose "═══════════════════════════════════════════════════════════════════"
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
Write-Verbose "📊 LEARNING POINT: Good programming includes good communication!"
Write-Verbose "   The best analysis is worthless if users can't understand it."
Write-Verbose "   Always think about your AUDIENCE when formatting output."
Write-Verbose ""

# Calculate session duration
$durationText = ""
if ($serverHellos.Count -gt 0) {
    $startTime = $serverHellos[0].Time
    # Reuse the shutdownTime calculation from earlier (if not sentinel value)
    $endTime = if ($shutdownTime -ne $SENTINEL_TIME_MAX) { $shutdownTime } else { $null }
    
    if ($endTime) {
        $durationSeconds = (ConvertFrom-TimeString $endTime) - (ConvertFrom-TimeString $startTime)
        $durationText = "Session Duration: " + (Format-Duration $durationSeconds)
    }
}

$logFileName = Split-Path $LogPath -Leaf
$filterEffectiveness = [math]::Round(($excludedCount / $totalLines) * 100, 1)
$footer = @"

===== Session Summary =====
Log File: $logFileName
Run at: $timestamp
Total Lines: $totalLines | Filtered: $filteredCount | Excluded: $excludedCount ($filterEffectiveness% filtered out)
$durationText
$narrativeText==============================
"@

# Print summary footer to console
Write-Host $footer -ForegroundColor Cyan

# Append summary footer to file
Add-Content -Path $OutPath -Value $footer

Write-Host "Filtered log written to $OutPath" -ForegroundColor Cyan
Write-Host "Excluded lines written to $OutPathExcluded" -ForegroundColor Cyan
