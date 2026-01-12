<#
.SYNOPSIS
    Log Management and Aggregation System
.DESCRIPTION
    This script provides centralized log management including log rotation, retention,
    aggregation, searching, and reporting. It manages logs from all migration scripts.
.PARAMETER Action
    Action to perform: Rotate, Cleanup, Aggregate, Search, Report, Archive
.PARAMETER LogDir
    Directory containing log files (default: ./logs)
.PARAMETER RetentionDays
    Number of days to retain logs (default: 30)
.PARAMETER ArchiveDir
    Directory for archived logs (default: ./logs/archive)
.PARAMETER SearchPattern
    Pattern to search for in logs
.PARAMETER SearchLevel
    Log level to filter (ERROR, WARNING, INFO, DEBUG, ALL)
.PARAMETER StartDate
    Start date for log search/report
.PARAMETER EndDate
    End date for log search/report
.PARAMETER OutputFormat
    Output format for reports (Console, CSV, JSON, HTML)
.EXAMPLE
    ./12-log-manager.ps1 -Action Rotate -RetentionDays 30
.EXAMPLE
    ./12-log-manager.ps1 -Action Search -SearchPattern "ERROR" -SearchLevel "ERROR"
.EXAMPLE
    ./12-log-manager.ps1 -Action Report -OutputFormat HTML -StartDate "2024-01-01"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Rotate", "Cleanup", "Aggregate", "Search", "Report", "Archive", "Stats")]
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [string]$LogDir = "./logs",

    [Parameter(Mandatory=$false)]
    [int]$RetentionDays = 30,

    [Parameter(Mandatory=$false)]
    [string]$ArchiveDir = "./logs/archive",

    [Parameter(Mandatory=$false)]
    [string]$MetricsDir = "./reports/metrics",

    [Parameter(Mandatory=$false)]
    [string]$SearchPattern = "",

    [Parameter(Mandatory=$false)]
    [ValidateSet("ERROR", "WARNING", "INFO", "DEBUG", "SUCCESS", "ALL")]
    [string]$SearchLevel = "ALL",

    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Console", "CSV", "JSON", "HTML")]
    [string]$OutputFormat = "Console",

    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "",

    [Parameter(Mandatory=$false)]
    [int]$MaxFileSizeMB = 100,

    [Parameter(Mandatory=$false)]
    [switch]$Compress,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# Set error handling
$ErrorActionPreference = "Continue"

# Create directories
@($LogDir, $ArchiveDir, $MetricsDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# Log manager's own log
$script:ManagerLog = Join-Path $LogDir "log-manager-$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-ManagerLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry -ForegroundColor $(switch ($Level) { "ERROR" { "Red" } "WARNING" { "Yellow" } default { "White" } })
    Add-Content -Path $script:ManagerLog -Value $logEntry
}

#region Log Rotation Functions

function Invoke-LogRotation {
    Write-ManagerLog "Starting log rotation..."

    $logFiles = Get-ChildItem -Path $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue

    foreach ($file in $logFiles) {
        $fileSizeMB = $file.Length / 1MB

        if ($fileSizeMB -gt $MaxFileSizeMB) {
            Write-ManagerLog "Rotating $($file.Name) (Size: $([Math]::Round($fileSizeMB, 2)) MB)"

            if (-not $DryRun) {
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $rotatedName = "$($file.BaseName).$timestamp$($file.Extension)"
                $rotatedPath = Join-Path $LogDir $rotatedName

                Move-Item -Path $file.FullName -Destination $rotatedPath -Force
                Write-ManagerLog "Rotated to: $rotatedName"

                if ($Compress) {
                    $compressedPath = "$rotatedPath.gz"
                    Compress-LogFile -SourcePath $rotatedPath -DestinationPath $compressedPath
                    Remove-Item $rotatedPath -Force
                    Write-ManagerLog "Compressed: $compressedPath"
                }
            }
            else {
                Write-ManagerLog "[DRY RUN] Would rotate: $($file.Name)"
            }
        }
    }

    Write-ManagerLog "Log rotation completed"
}

function Compress-LogFile {
    param([string]$SourcePath, [string]$DestinationPath)

    try {
        $sourceStream = [System.IO.File]::OpenRead($SourcePath)
        $destStream = [System.IO.File]::Create($DestinationPath)
        $gzipStream = New-Object System.IO.Compression.GZipStream($destStream, [System.IO.Compression.CompressionMode]::Compress)

        $sourceStream.CopyTo($gzipStream)

        $gzipStream.Close()
        $destStream.Close()
        $sourceStream.Close()

        return $true
    }
    catch {
        Write-ManagerLog "Failed to compress $SourcePath : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

#endregion

#region Cleanup Functions

function Invoke-LogCleanup {
    Write-ManagerLog "Starting log cleanup (retention: $RetentionDays days)..."

    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
    $logFiles = Get-ChildItem -Path $LogDir -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoffDate }

    $totalSize = 0
    $fileCount = 0

    foreach ($file in $logFiles) {
        $totalSize += $file.Length
        $fileCount++

        if (-not $DryRun) {
            Write-ManagerLog "Deleting: $($file.Name) (Last modified: $($file.LastWriteTime))"
            Remove-Item $file.FullName -Force
        }
        else {
            Write-ManagerLog "[DRY RUN] Would delete: $($file.Name)"
        }
    }

    $totalSizeMB = [Math]::Round($totalSize / 1MB, 2)
    Write-ManagerLog "Cleanup completed: $fileCount files, $totalSizeMB MB freed"
}

#endregion

#region Archive Functions

function Invoke-LogArchive {
    Write-ManagerLog "Starting log archival..."

    $archiveDate = Get-Date -Format "yyyy-MM-dd"
    $archiveName = "logs-archive-$archiveDate.zip"
    $archivePath = Join-Path $ArchiveDir $archiveName

    # Get files older than 7 days
    $cutoffDate = (Get-Date).AddDays(-7)
    $filesToArchive = Get-ChildItem -Path $LogDir -Filter "*.log" -File |
                      Where-Object { $_.LastWriteTime -lt $cutoffDate }

    if ($filesToArchive.Count -eq 0) {
        Write-ManagerLog "No files to archive"
        return
    }

    if (-not $DryRun) {
        # Create archive
        $filesToArchive | Compress-Archive -DestinationPath $archivePath -Force

        # Remove archived files
        $filesToArchive | Remove-Item -Force

        Write-ManagerLog "Archived $($filesToArchive.Count) files to: $archiveName"
    }
    else {
        Write-ManagerLog "[DRY RUN] Would archive $($filesToArchive.Count) files"
    }
}

#endregion

#region Aggregation Functions

function Invoke-LogAggregation {
    Write-ManagerLog "Starting log aggregation..."

    $aggregatedFile = Join-Path $LogDir "aggregated-$(Get-Date -Format 'yyyy-MM-dd').log"
    $jsonAggregatedFile = Join-Path $LogDir "aggregated-$(Get-Date -Format 'yyyy-MM-dd').json"

    $logFiles = Get-ChildItem -Path $LogDir -Filter "*.log" -File |
                Where-Object { $_.Name -notlike "aggregated-*" -and $_.Name -notlike "log-manager-*" }

    $allEntries = @()

    foreach ($file in $logFiles) {
        Write-ManagerLog "Processing: $($file.Name)"

        $content = Get-Content $file.FullName -ErrorAction SilentlyContinue

        foreach ($line in $content) {
            if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[(\w+)\]') {
                $entry = @{
                    timestamp = $matches[1]
                    level = $matches[2]
                    source = $file.BaseName
                    message = $line
                }
                $allEntries += $entry
            }
        }
    }

    # Sort by timestamp
    $sortedEntries = $allEntries | Sort-Object { [datetime]$_.timestamp }

    if (-not $DryRun) {
        # Write aggregated log file
        $sortedEntries | ForEach-Object { $_.message } | Out-File $aggregatedFile -Encoding UTF8

        # Write JSON format
        $sortedEntries | ConvertTo-Json -Depth 5 | Out-File $jsonAggregatedFile -Encoding UTF8

        Write-ManagerLog "Aggregated $($allEntries.Count) entries to: $aggregatedFile"
    }
    else {
        Write-ManagerLog "[DRY RUN] Would aggregate $($allEntries.Count) entries"
    }
}

#endregion

#region Search Functions

function Invoke-LogSearch {
    Write-ManagerLog "Searching logs..."

    $searchResults = @()

    $logFiles = Get-ChildItem -Path $LogDir -Filter "*.log" -File -Recurse

    # Apply date filter to files
    if ($StartDate) {
        $logFiles = $logFiles | Where-Object { $_.LastWriteTime -ge $StartDate }
    }
    if ($EndDate) {
        $logFiles = $logFiles | Where-Object { $_.LastWriteTime -le $EndDate }
    }

    foreach ($file in $logFiles) {
        $lineNumber = 0
        $content = Get-Content $file.FullName -ErrorAction SilentlyContinue

        foreach ($line in $content) {
            $lineNumber++

            # Check level filter
            if ($SearchLevel -ne "ALL") {
                if ($line -notmatch "\[$SearchLevel\]") {
                    continue
                }
            }

            # Check pattern filter
            if ($SearchPattern -and $line -notmatch $SearchPattern) {
                continue
            }

            # Parse timestamp if present
            $timestamp = $null
            if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $timestamp = [datetime]$matches[1]

                # Apply date filters to entries
                if ($StartDate -and $timestamp -lt $StartDate) { continue }
                if ($EndDate -and $timestamp -gt $EndDate) { continue }
            }

            $searchResults += [PSCustomObject]@{
                File = $file.Name
                Line = $lineNumber
                Timestamp = $timestamp
                Content = $line
            }
        }
    }

    Write-ManagerLog "Found $($searchResults.Count) matching entries"

    # Output results
    switch ($OutputFormat) {
        "Console" {
            $searchResults | Format-Table -AutoSize
        }
        "CSV" {
            $outputPath = if ($OutputFile) { $OutputFile } else { Join-Path $LogDir "search-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv" }
            $searchResults | Export-Csv -Path $outputPath -NoTypeInformation
            Write-ManagerLog "Results saved to: $outputPath"
        }
        "JSON" {
            $outputPath = if ($OutputFile) { $OutputFile } else { Join-Path $LogDir "search-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').json" }
            $searchResults | ConvertTo-Json -Depth 5 | Out-File $outputPath
            Write-ManagerLog "Results saved to: $outputPath"
        }
        "HTML" {
            $outputPath = if ($OutputFile) { $OutputFile } else { Join-Path $LogDir "search-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').html" }
            Export-HtmlReport -Data $searchResults -Title "Log Search Results" -OutputPath $outputPath
            Write-ManagerLog "Results saved to: $outputPath"
        }
    }

    return $searchResults
}

#endregion

#region Report Functions

function Get-LogStatistics {
    Write-ManagerLog "Calculating log statistics..."

    $stats = @{
        TotalFiles = 0
        TotalSizeMB = 0
        TotalEntries = 0
        EntriesByLevel = @{
            ERROR = 0
            WARNING = 0
            INFO = 0
            DEBUG = 0
            SUCCESS = 0
            Other = 0
        }
        EntriesByDay = @{}
        EntriesBySource = @{}
        OldestEntry = $null
        NewestEntry = $null
    }

    $logFiles = Get-ChildItem -Path $LogDir -Filter "*.log" -File -Recurse -ErrorAction SilentlyContinue

    $stats.TotalFiles = $logFiles.Count
    $stats.TotalSizeMB = [Math]::Round(($logFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)

    foreach ($file in $logFiles) {
        $content = Get-Content $file.FullName -ErrorAction SilentlyContinue

        foreach ($line in $content) {
            $stats.TotalEntries++

            # Count by level
            if ($line -match '\[(ERROR)\]') { $stats.EntriesByLevel.ERROR++ }
            elseif ($line -match '\[(WARNING)\]') { $stats.EntriesByLevel.WARNING++ }
            elseif ($line -match '\[(INFO)\]') { $stats.EntriesByLevel.INFO++ }
            elseif ($line -match '\[(DEBUG)\]') { $stats.EntriesByLevel.DEBUG++ }
            elseif ($line -match '\[(SUCCESS)\]') { $stats.EntriesByLevel.SUCCESS++ }
            else { $stats.EntriesByLevel.Other++ }

            # Count by day
            if ($line -match '^\[(\d{4}-\d{2}-\d{2})') {
                $day = $matches[1]
                if (-not $stats.EntriesByDay.ContainsKey($day)) {
                    $stats.EntriesByDay[$day] = 0
                }
                $stats.EntriesByDay[$day]++

                # Track oldest/newest
                $entryDate = [datetime]$day
                if ($null -eq $stats.OldestEntry -or $entryDate -lt $stats.OldestEntry) {
                    $stats.OldestEntry = $entryDate
                }
                if ($null -eq $stats.NewestEntry -or $entryDate -gt $stats.NewestEntry) {
                    $stats.NewestEntry = $entryDate
                }
            }

            # Count by source
            $source = $file.BaseName -replace '-\d{4}-\d{2}-\d{2}.*', ''
            if (-not $stats.EntriesBySource.ContainsKey($source)) {
                $stats.EntriesBySource[$source] = 0
            }
            $stats.EntriesBySource[$source]++
        }
    }

    return $stats
}

function Export-HtmlReport {
    param(
        [object]$Data,
        [string]$Title,
        [string]$OutputPath
    )

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$Title</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background-color: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #007bff; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 30px; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #007bff; color: white; }
        tr:hover { background-color: #f5f5f5; }
        .error { color: #dc3545; font-weight: bold; }
        .warning { color: #ffc107; }
        .info { color: #17a2b8; }
        .success { color: #28a745; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin: 20px 0; }
        .stat-card { background-color: #f8f9fa; padding: 20px; border-radius: 8px; text-align: center; }
        .stat-value { font-size: 36px; font-weight: bold; color: #007bff; }
        .stat-label { color: #666; margin-top: 5px; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>$Title</h1>
        <p>Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
"@

    if ($Data -is [hashtable] -and $Data.TotalFiles) {
        # Statistics report
        $html += @"
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-value">$($Data.TotalFiles)</div>
                <div class="stat-label">Log Files</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">$($Data.TotalSizeMB) MB</div>
                <div class="stat-label">Total Size</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">$($Data.TotalEntries)</div>
                <div class="stat-label">Total Entries</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" style="color: #dc3545;">$($Data.EntriesByLevel.ERROR)</div>
                <div class="stat-label">Errors</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" style="color: #ffc107;">$($Data.EntriesByLevel.WARNING)</div>
                <div class="stat-label">Warnings</div>
            </div>
        </div>

        <h2>Entries by Level</h2>
        <table>
            <tr><th>Level</th><th>Count</th><th>Percentage</th></tr>
"@
        foreach ($level in $Data.EntriesByLevel.GetEnumerator() | Sort-Object Value -Descending) {
            $pct = if ($Data.TotalEntries -gt 0) { [Math]::Round(($level.Value / $Data.TotalEntries) * 100, 1) } else { 0 }
            $html += "<tr><td>$($level.Key)</td><td>$($level.Value)</td><td>$pct%</td></tr>"
        }
        $html += "</table>"

        $html += @"
        <h2>Entries by Source</h2>
        <table>
            <tr><th>Source</th><th>Count</th></tr>
"@
        foreach ($source in $Data.EntriesBySource.GetEnumerator() | Sort-Object Value -Descending) {
            $html += "<tr><td>$($source.Key)</td><td>$($source.Value)</td></tr>"
        }
        $html += "</table>"
    }
    else {
        # Search results
        $html += @"
        <table>
            <tr><th>File</th><th>Line</th><th>Timestamp</th><th>Content</th></tr>
"@
        foreach ($entry in $Data) {
            $levelClass = ""
            if ($entry.Content -match '\[ERROR\]') { $levelClass = "error" }
            elseif ($entry.Content -match '\[WARNING\]') { $levelClass = "warning" }
            elseif ($entry.Content -match '\[INFO\]') { $levelClass = "info" }
            elseif ($entry.Content -match '\[SUCCESS\]') { $levelClass = "success" }

            $html += "<tr class='$levelClass'><td>$($entry.File)</td><td>$($entry.Line)</td><td>$($entry.Timestamp)</td><td>$([System.Web.HttpUtility]::HtmlEncode($entry.Content))</td></tr>"
        }
        $html += "</table>"
    }

    $html += @"
        <div class="footer">
            Generated by Migration Log Manager | Azure DevOps to GitHub Migration Factory
        </div>
    </div>
</body>
</html>
"@

    $html | Out-File $OutputPath -Encoding UTF8
}

function Invoke-LogReport {
    Write-ManagerLog "Generating log report..."

    $stats = Get-LogStatistics

    switch ($OutputFormat) {
        "Console" {
            Write-Host ""
            Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "║                        LOG STATISTICS                             ║" -ForegroundColor Cyan
            Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Total Log Files:    $($stats.TotalFiles)"
            Write-Host "  Total Size:         $($stats.TotalSizeMB) MB"
            Write-Host "  Total Entries:      $($stats.TotalEntries)"
            Write-Host ""
            Write-Host "  Entries by Level:" -ForegroundColor Yellow
            Write-Host "    ERROR:   $($stats.EntriesByLevel.ERROR)" -ForegroundColor Red
            Write-Host "    WARNING: $($stats.EntriesByLevel.WARNING)" -ForegroundColor Yellow
            Write-Host "    INFO:    $($stats.EntriesByLevel.INFO)" -ForegroundColor White
            Write-Host "    DEBUG:   $($stats.EntriesByLevel.DEBUG)" -ForegroundColor Gray
            Write-Host "    SUCCESS: $($stats.EntriesByLevel.SUCCESS)" -ForegroundColor Green
            Write-Host ""
            Write-Host "  Date Range: $($stats.OldestEntry) to $($stats.NewestEntry)"
            Write-Host ""
        }
        "CSV" {
            $outputPath = if ($OutputFile) { $OutputFile } else { Join-Path $LogDir "log-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv" }

            $reportData = @(
                [PSCustomObject]@{ Metric = "TotalFiles"; Value = $stats.TotalFiles }
                [PSCustomObject]@{ Metric = "TotalSizeMB"; Value = $stats.TotalSizeMB }
                [PSCustomObject]@{ Metric = "TotalEntries"; Value = $stats.TotalEntries }
                [PSCustomObject]@{ Metric = "Errors"; Value = $stats.EntriesByLevel.ERROR }
                [PSCustomObject]@{ Metric = "Warnings"; Value = $stats.EntriesByLevel.WARNING }
                [PSCustomObject]@{ Metric = "Info"; Value = $stats.EntriesByLevel.INFO }
            )

            $reportData | Export-Csv -Path $outputPath -NoTypeInformation
            Write-ManagerLog "Report saved to: $outputPath"
        }
        "JSON" {
            $outputPath = if ($OutputFile) { $OutputFile } else { Join-Path $LogDir "log-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json" }
            $stats | ConvertTo-Json -Depth 10 | Out-File $outputPath
            Write-ManagerLog "Report saved to: $outputPath"
        }
        "HTML" {
            $outputPath = if ($OutputFile) { $OutputFile } else { Join-Path $LogDir "log-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html" }
            Export-HtmlReport -Data $stats -Title "Migration Log Statistics Report" -OutputPath $outputPath
            Write-ManagerLog "Report saved to: $outputPath"
        }
    }

    return $stats
}

function Show-LogStats {
    $stats = Get-LogStatistics

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                           LOG MANAGEMENT STATISTICS                           ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║                                                                               ║" -ForegroundColor Cyan
    Write-Host "║  Log Directory: $($LogDir.PadRight(60))║" -ForegroundColor Cyan
    Write-Host "║                                                                               ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  Total Files:     $($stats.TotalFiles.ToString().PadLeft(10))                                          ║" -ForegroundColor White
    Write-Host "║  Total Size:      $("$($stats.TotalSizeMB) MB".PadLeft(10))                                          ║" -ForegroundColor White
    Write-Host "║  Total Entries:   $($stats.TotalEntries.ToString().PadLeft(10))                                          ║" -ForegroundColor White
    Write-Host "║                                                                               ║" -ForegroundColor White
    Write-Host "║  Errors:          $($stats.EntriesByLevel.ERROR.ToString().PadLeft(10))                                          ║" -ForegroundColor Red
    Write-Host "║  Warnings:        $($stats.EntriesByLevel.WARNING.ToString().PadLeft(10))                                          ║" -ForegroundColor Yellow
    Write-Host "║  Info:            $($stats.EntriesByLevel.INFO.ToString().PadLeft(10))                                          ║" -ForegroundColor White
    Write-Host "║  Debug:           $($stats.EntriesByLevel.DEBUG.ToString().PadLeft(10))                                          ║" -ForegroundColor Gray
    Write-Host "║  Success:         $($stats.EntriesByLevel.SUCCESS.ToString().PadLeft(10))                                          ║" -ForegroundColor Green
    Write-Host "║                                                                               ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

#endregion

#region Main Execution

try {
    Write-ManagerLog "=== Log Manager Started - Action: $Action ==="

    switch ($Action) {
        "Rotate" {
            Invoke-LogRotation
        }
        "Cleanup" {
            Invoke-LogCleanup
        }
        "Archive" {
            Invoke-LogArchive
        }
        "Aggregate" {
            Invoke-LogAggregation
        }
        "Search" {
            Invoke-LogSearch
        }
        "Report" {
            Invoke-LogReport
        }
        "Stats" {
            Show-LogStats
        }
    }

    Write-ManagerLog "=== Log Manager Completed ==="

}
catch {
    Write-ManagerLog "Log manager error: $($_.Exception.Message)" "ERROR"
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

#endregion
