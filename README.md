# Zwift Tools 2025

PowerShell tools for analyzing Zwift application log files to diagnose connection and device issues.

## Tools

### zlog.ps1 - Zwift Log Analyzer

Analyzes Zwift log files to identify connection problems, device disconnections, and network issues. Filters thousands of log lines down to relevant diagnostic information.

**Features:**
- Detects trainer DirectConnect failures
- Identifies internet/DNS connectivity issues  
- Recognizes server reconnection patterns
- Extracts device details (firmware, hardware revision)
- Generates human-readable diagnostic reports

**Usage:**
```powershell
.\zlog.ps1 "path\to\logfile.txt"
```

**Optional Parameters:**
- `-OutDir` - Specify output directory for filtered/excluded files

**Output:**
- Console summary with session duration, problems detected, and diagnosis
- `*-filtered-*.txt` - Relevant log entries for analysis
- `*-excluded-*.txt` - Filtered out lines for reference

## Sample Logs

The `samples/` folder contains example Zwift log files demonstrating:
- Clean session (no problems)
- Trainer DirectConnect failures
- Internet dropout scenarios

## Configuration

**Device Patterns:** Edit the `$DEVICE_PATTERNS` array in `zlog.ps1` to match your devices:
```powershell
$DEVICE_PATTERNS = @(
    "Wahoo KICKR",
    "HRM",
    # Add your device names here
)
```

## Requirements

- Windows PowerShell 5.1 or later
- PowerShell Core 7+ recommended

## License

MIT License - Free to use and modify
