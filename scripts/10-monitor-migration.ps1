<#
.SYNOPSIS
    Automated Migration Monitoring System
.DESCRIPTION
    This script provides continuous monitoring of the migration process, tracking
    progress over time, detecting errors, and triggering alerts when issues occur.
    It can run as a background process or scheduled task.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER GhOrg
    GitHub organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER MonitoringInterval
    Interval between status checks in seconds (default: 300 = 5 minutes)
.PARAMETER AlertConfigPath
    Path to alert configuration file (default: ./templates/alert-config.json)
.PARAMETER EnableAlerts
    Enable alert notifications (default: $true)
.PARAMETER ContinuousMode
    Run continuously until stopped (default: $false)
.PARAMETER MaxRuntime
    Maximum runtime in hours for continuous mode (default: 24)
.PARAMETER HealthCheckInterval
    Interval for health checks in seconds (default: 60)
.EXAMPLE
    ./10-monitor-migration.ps1 -AdoOrg "myorg" -AdoPat "pat" -GhOrg "ghorg" -GhToken "token" -ContinuousMode
.EXAMPLE
    ./10-monitor-migration.ps1 -AdoOrg "myorg" -AdoPat "pat" -GhOrg "ghorg" -GhToken "token" -MonitoringInterval 600
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdoOrg,

    [Parameter(Mandatory=$true)]
    [string]$AdoPat,

    [Parameter(Mandatory=$true)]
    [string]$GhOrg,

    [Parameter(Mandatory=$true)]
    [string]$GhToken,

    [Parameter(Mandatory=$false)]
    [int]$MonitoringInterval = 300,

    [Parameter(Mandatory=$false)]
    [string]$AlertConfigPath = "./templates/alert-config.json",

    [Parameter(Mandatory=$false)]
    [bool]$EnableAlerts = $true,

    [Parameter(Mandatory=$false)]
    [switch]$ContinuousMode,

    [Parameter(Mandatory=$false)]
    [int]$MaxRuntime = 24,

    [Parameter(Mandatory=$false)]
    [int]$HealthCheckInterval = 60,

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "./logs",

    [Parameter(Mandatory=$false)]
    [string]$MetricsDir = "./reports/metrics"
)

# Set error handling
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Create directories
@($OutputDir, $MetricsDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

# Initialize structured logging
$script:LogFile = Join-Path $OutputDir "monitor-$(Get-Date -Format 'yyyy-MM-dd').log"
$script:JsonLogFile = Join-Path $OutputDir "monitor-$(Get-Date -Format 'yyyy-MM-dd').json"
$script:MetricsFile = Join-Path $MetricsDir "metrics-$(Get-Date -Format 'yyyy-MM-dd').json"

# Monitoring state
$script:MonitoringState = @{
    StartTime = Get-Date
    LastCheck = $null
    TotalChecks = 0
    Errors = @()
    Warnings = @()
    Metrics = @()
    AlertsSent = 0
    CurrentStatus = @{
        TotalRepos = 0
        MigratedRepos = 0
        PendingRepos = 0
        FailedRepos = 0
        InProgressRepos = 0
        ProgressPercent = 0
        EstimatedTimeRemaining = $null
    }
    HealthStatus = @{
        AdoApiHealth = "Unknown"
        GhApiHealth = "Unknown"
        NetworkHealth = "Unknown"
        LastHealthCheck = $null
    }
}

# Alert configuration
$script:AlertConfig = $null

#region Logging Functions

function Write-StructuredLog {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Component = "Monitor",
        [hashtable]$Data = @{}
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $correlationId = [guid]::NewGuid().ToString().Substring(0, 8)

    # Console output with color
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG" { "Gray" }
        default { "White" }
    }

    Write-Host "[$timestamp] [$Level] [$Component] $Message" -ForegroundColor $color

    # Plain text log
    $logEntry = "[$timestamp] [$Level] [$Component] [$correlationId] $Message"
    Add-Content -Path $script:LogFile -Value $logEntry

    # JSON structured log
    $jsonEntry = @{
        timestamp = $timestamp
        level = $Level
        component = $Component
        correlationId = $correlationId
        message = $Message
        data = $Data
        hostname = $env:COMPUTERNAME
        organization = $AdoOrg
    } | ConvertTo-Json -Compress

    Add-Content -Path $script:JsonLogFile -Value $jsonEntry
}

function Write-MetricLog {
    param(
        [string]$MetricName,
        [double]$Value,
        [string]$Unit = "",
        [hashtable]$Tags = @{}
    )

    $metric = @{
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
        name = $MetricName
        value = $Value
        unit = $Unit
        tags = $Tags
    }

    $script:MonitoringState.Metrics += $metric

    # Append to metrics file
    $metric | ConvertTo-Json -Compress | Add-Content -Path $script:MetricsFile
}

#endregion

#region API Functions

function Get-AdoAuthHeader {
    return @{
        "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
        "Content-Type" = "application/json"
    }
}

function Get-GhAuthHeader {
    return @{
        "Authorization" = "token $GhToken"
        "Accept" = "application/vnd.github.v3+json"
        "Content-Type" = "application/json"
    }
}

function Invoke-ApiWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = "GET",
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -lt $MaxRetries) {
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec 30
            $stopwatch.Stop()

            Write-MetricLog -MetricName "api_response_time_ms" -Value $stopwatch.ElapsedMilliseconds -Unit "ms" -Tags @{uri = $Uri}

            return @{
                Success = $true
                Data = $response
                ResponseTime = $stopwatch.ElapsedMilliseconds
            }
        }
        catch {
            $attempt++
            $lastError = $_
            Write-StructuredLog "API call failed (attempt $attempt/$MaxRetries): $Uri" "WARNING" "API" @{error = $_.Exception.Message}

            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds ($RetryDelaySeconds * $attempt)
            }
        }
    }

    return @{
        Success = $false
        Error = $lastError.Exception.Message
        ResponseTime = -1
    }
}

#endregion

#region Health Check Functions

function Test-AdoApiHealth {
    Write-StructuredLog "Checking Azure DevOps API health..." "DEBUG" "HealthCheck"

    $result = Invoke-ApiWithRetry -Uri "https://dev.azure.com/$AdoOrg/_apis/projects?`$top=1&api-version=7.1-preview.1" -Headers (Get-AdoAuthHeader)

    if ($result.Success) {
        $script:MonitoringState.HealthStatus.AdoApiHealth = "Healthy"
        Write-MetricLog -MetricName "ado_api_health" -Value 1 -Tags @{status = "healthy"}
        return $true
    }
    else {
        $script:MonitoringState.HealthStatus.AdoApiHealth = "Unhealthy"
        Write-MetricLog -MetricName "ado_api_health" -Value 0 -Tags @{status = "unhealthy"; error = $result.Error}
        return $false
    }
}

function Test-GhApiHealth {
    Write-StructuredLog "Checking GitHub API health..." "DEBUG" "HealthCheck"

    $result = Invoke-ApiWithRetry -Uri "https://api.github.com/orgs/$GhOrg" -Headers (Get-GhAuthHeader)

    if ($result.Success) {
        $script:MonitoringState.HealthStatus.GhApiHealth = "Healthy"
        Write-MetricLog -MetricName "gh_api_health" -Value 1 -Tags @{status = "healthy"}
        return $true
    }
    else {
        $script:MonitoringState.HealthStatus.GhApiHealth = "Unhealthy"
        Write-MetricLog -MetricName "gh_api_health" -Value 0 -Tags @{status = "unhealthy"; error = $result.Error}
        return $false
    }
}

function Test-NetworkHealth {
    Write-StructuredLog "Checking network connectivity..." "DEBUG" "HealthCheck"

    $endpoints = @(
        "https://dev.azure.com",
        "https://api.github.com",
        "https://github.com"
    )

    $healthyCount = 0
    foreach ($endpoint in $endpoints) {
        try {
            $response = Invoke-WebRequest -Uri $endpoint -Method HEAD -TimeoutSec 10 -UseBasicParsing
            if ($response.StatusCode -eq 200) {
                $healthyCount++
            }
        }
        catch {
            Write-StructuredLog "Network check failed for $endpoint" "WARNING" "HealthCheck"
        }
    }

    $healthPercent = ($healthyCount / $endpoints.Count) * 100

    if ($healthPercent -ge 100) {
        $script:MonitoringState.HealthStatus.NetworkHealth = "Healthy"
    }
    elseif ($healthPercent -ge 50) {
        $script:MonitoringState.HealthStatus.NetworkHealth = "Degraded"
    }
    else {
        $script:MonitoringState.HealthStatus.NetworkHealth = "Unhealthy"
    }

    Write-MetricLog -MetricName "network_health_percent" -Value $healthPercent -Unit "percent"

    return $healthPercent -ge 50
}

function Invoke-HealthChecks {
    Write-StructuredLog "Running health checks..." "INFO" "HealthCheck"

    $adoHealth = Test-AdoApiHealth
    $ghHealth = Test-GhApiHealth
    $networkHealth = Test-NetworkHealth

    $script:MonitoringState.HealthStatus.LastHealthCheck = Get-Date

    $overallHealth = $adoHealth -and $ghHealth -and $networkHealth

    if (-not $overallHealth) {
        $unhealthyServices = @()
        if (-not $adoHealth) { $unhealthyServices += "Azure DevOps API" }
        if (-not $ghHealth) { $unhealthyServices += "GitHub API" }
        if (-not $networkHealth) { $unhealthyServices += "Network" }

        Write-StructuredLog "Health check failed for: $($unhealthyServices -join ', ')" "ERROR" "HealthCheck"

        if ($EnableAlerts) {
            Send-Alert -AlertType "HealthCheckFailed" -Severity "High" -Message "Health check failed for: $($unhealthyServices -join ', ')" -Data @{services = $unhealthyServices}
        }
    }
    else {
        Write-StructuredLog "All health checks passed" "SUCCESS" "HealthCheck"
    }

    return $overallHealth
}

#endregion

#region Migration Status Functions

function Get-MigrationStatus {
    Write-StructuredLog "Fetching migration status..." "INFO" "Status"

    # Get ADO repositories
    $adoRepos = @()
    $projectsResult = Invoke-ApiWithRetry -Uri "https://dev.azure.com/$AdoOrg/_apis/projects?api-version=7.1-preview.1" -Headers (Get-AdoAuthHeader)

    if ($projectsResult.Success) {
        foreach ($project in $projectsResult.Data.value) {
            $reposResult = Invoke-ApiWithRetry -Uri "https://dev.azure.com/$AdoOrg/$($project.name)/_apis/git/repositories?api-version=7.1-preview.1" -Headers (Get-AdoAuthHeader)
            if ($reposResult.Success) {
                foreach ($repo in $reposResult.Data.value) {
                    if (-not $repo.isDisabled) {
                        $adoRepos += @{
                            Project = $project.name
                            Name = $repo.name
                            Id = $repo.id
                        }
                    }
                }
            }
        }
    }

    # Get GitHub repositories
    $ghRepos = @()
    $page = 1
    do {
        $ghResult = Invoke-ApiWithRetry -Uri "https://api.github.com/orgs/$GhOrg/repos?per_page=100&page=$page" -Headers (Get-GhAuthHeader)
        if ($ghResult.Success -and $ghResult.Data.Count -gt 0) {
            $ghRepos += $ghResult.Data | ForEach-Object { $_.name }
            $page++
        }
        else {
            break
        }
    } while ($ghResult.Data.Count -eq 100)

    # Calculate migration status
    $totalRepos = $adoRepos.Count
    $migratedRepos = 0
    $pendingRepos = 0

    foreach ($adoRepo in $adoRepos) {
        if ($ghRepos -contains $adoRepo.Name) {
            $migratedRepos++
        }
        else {
            $pendingRepos++
        }
    }

    $progressPercent = if ($totalRepos -gt 0) { [Math]::Round(($migratedRepos / $totalRepos) * 100, 2) } else { 0 }

    # Update state
    $script:MonitoringState.CurrentStatus.TotalRepos = $totalRepos
    $script:MonitoringState.CurrentStatus.MigratedRepos = $migratedRepos
    $script:MonitoringState.CurrentStatus.PendingRepos = $pendingRepos
    $script:MonitoringState.CurrentStatus.ProgressPercent = $progressPercent

    # Log metrics
    Write-MetricLog -MetricName "total_repositories" -Value $totalRepos
    Write-MetricLog -MetricName "migrated_repositories" -Value $migratedRepos
    Write-MetricLog -MetricName "pending_repositories" -Value $pendingRepos
    Write-MetricLog -MetricName "migration_progress_percent" -Value $progressPercent -Unit "percent"

    Write-StructuredLog "Migration status: $migratedRepos/$totalRepos ($progressPercent%)" "INFO" "Status" @{
        total = $totalRepos
        migrated = $migratedRepos
        pending = $pendingRepos
        progress = $progressPercent
    }

    return $script:MonitoringState.CurrentStatus
}

function Get-MigrationRate {
    $metrics = $script:MonitoringState.Metrics | Where-Object { $_.name -eq "migrated_repositories" }

    if ($metrics.Count -lt 2) {
        return $null
    }

    $firstMetric = $metrics | Select-Object -First 1
    $lastMetric = $metrics | Select-Object -Last 1

    $timeDiff = ([datetime]$lastMetric.timestamp - [datetime]$firstMetric.timestamp).TotalHours
    $reposDiff = $lastMetric.value - $firstMetric.value

    if ($timeDiff -gt 0) {
        $rate = $reposDiff / $timeDiff
        Write-MetricLog -MetricName "migration_rate_per_hour" -Value $rate -Unit "repos/hour"
        return $rate
    }

    return $null
}

function Get-EstimatedTimeRemaining {
    $rate = Get-MigrationRate

    if ($null -eq $rate -or $rate -le 0) {
        return $null
    }

    $pendingRepos = $script:MonitoringState.CurrentStatus.PendingRepos
    $hoursRemaining = $pendingRepos / $rate

    $script:MonitoringState.CurrentStatus.EstimatedTimeRemaining = $hoursRemaining

    Write-MetricLog -MetricName "estimated_hours_remaining" -Value $hoursRemaining -Unit "hours"

    return $hoursRemaining
}

#endregion

#region Alert Functions

function Initialize-AlertConfig {
    if (Test-Path $AlertConfigPath) {
        try {
            $script:AlertConfig = Get-Content $AlertConfigPath -Raw | ConvertFrom-Json
            Write-StructuredLog "Alert configuration loaded from $AlertConfigPath" "INFO" "Alerts"
        }
        catch {
            Write-StructuredLog "Failed to load alert config: $($_.Exception.Message)" "WARNING" "Alerts"
            $script:AlertConfig = Get-DefaultAlertConfig
        }
    }
    else {
        Write-StructuredLog "Alert config not found, using defaults" "INFO" "Alerts"
        $script:AlertConfig = Get-DefaultAlertConfig
    }
}

function Get-DefaultAlertConfig {
    return @{
        enabled = $true
        channels = @{
            email = @{
                enabled = $false
                smtpServer = ""
                smtpPort = 587
                from = ""
                to = @()
                useSsl = $true
            }
            slack = @{
                enabled = $false
                webhookUrl = ""
            }
            teams = @{
                enabled = $false
                webhookUrl = ""
            }
            console = @{
                enabled = $true
            }
        }
        thresholds = @{
            failureRatePercent = 10
            stalledMinutes = 60
            healthCheckFailures = 3
        }
        alertCooldownMinutes = 15
    }
}

function Send-Alert {
    param(
        [string]$AlertType,
        [string]$Severity,
        [string]$Message,
        [hashtable]$Data = @{}
    )

    if (-not $EnableAlerts -or -not $script:AlertConfig.enabled) {
        return
    }

    $alert = @{
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        type = $AlertType
        severity = $Severity
        message = $Message
        organization = $AdoOrg
        data = $Data
    }

    Write-StructuredLog "ALERT [$Severity]: $Message" "WARNING" "Alerts" $Data

    # Send to configured channels
    if ($script:AlertConfig.channels.console.enabled) {
        Send-ConsoleAlert -Alert $alert
    }

    if ($script:AlertConfig.channels.slack.enabled -and $script:AlertConfig.channels.slack.webhookUrl) {
        Send-SlackAlert -Alert $alert
    }

    if ($script:AlertConfig.channels.teams.enabled -and $script:AlertConfig.channels.teams.webhookUrl) {
        Send-TeamsAlert -Alert $alert
    }

    if ($script:AlertConfig.channels.email.enabled) {
        Send-EmailAlert -Alert $alert
    }

    $script:MonitoringState.AlertsSent++
    Write-MetricLog -MetricName "alerts_sent" -Value 1 -Tags @{type = $AlertType; severity = $Severity}
}

function Send-ConsoleAlert {
    param([hashtable]$Alert)

    $color = switch ($Alert.severity) {
        "Critical" { "Red" }
        "High" { "Yellow" }
        "Medium" { "Cyan" }
        default { "White" }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor $color
    Write-Host "║                           ALERT                                   ║" -ForegroundColor $color
    Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor $color
    Write-Host "║  Type:     $($Alert.type.PadRight(54))║" -ForegroundColor $color
    Write-Host "║  Severity: $($Alert.severity.PadRight(54))║" -ForegroundColor $color
    Write-Host "║  Message:  $($Alert.message.Substring(0, [Math]::Min(54, $Alert.message.Length)).PadRight(54))║" -ForegroundColor $color
    Write-Host "║  Time:     $($Alert.timestamp.PadRight(54))║" -ForegroundColor $color
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor $color
    Write-Host ""
}

function Send-SlackAlert {
    param([hashtable]$Alert)

    $color = switch ($Alert.severity) {
        "Critical" { "#FF0000" }
        "High" { "#FFA500" }
        "Medium" { "#FFFF00" }
        default { "#00FF00" }
    }

    $payload = @{
        attachments = @(
            @{
                color = $color
                title = "Migration Alert: $($Alert.type)"
                text = $Alert.message
                fields = @(
                    @{ title = "Severity"; value = $Alert.severity; short = $true }
                    @{ title = "Organization"; value = $Alert.organization; short = $true }
                    @{ title = "Timestamp"; value = $Alert.timestamp; short = $true }
                )
                footer = "Azure DevOps to GitHub Migration Monitor"
            }
        )
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri $script:AlertConfig.channels.slack.webhookUrl -Method POST -Body $payload -ContentType "application/json"
        Write-StructuredLog "Slack alert sent successfully" "DEBUG" "Alerts"
    }
    catch {
        Write-StructuredLog "Failed to send Slack alert: $($_.Exception.Message)" "ERROR" "Alerts"
    }
}

function Send-TeamsAlert {
    param([hashtable]$Alert)

    $themeColor = switch ($Alert.severity) {
        "Critical" { "FF0000" }
        "High" { "FFA500" }
        "Medium" { "FFFF00" }
        default { "00FF00" }
    }

    $payload = @{
        "@type" = "MessageCard"
        "@context" = "http://schema.org/extensions"
        themeColor = $themeColor
        summary = "Migration Alert: $($Alert.type)"
        sections = @(
            @{
                activityTitle = "Migration Alert: $($Alert.type)"
                activitySubtitle = $Alert.timestamp
                facts = @(
                    @{ name = "Severity"; value = $Alert.severity }
                    @{ name = "Organization"; value = $Alert.organization }
                    @{ name = "Message"; value = $Alert.message }
                )
                markdown = $true
            }
        )
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri $script:AlertConfig.channels.teams.webhookUrl -Method POST -Body $payload -ContentType "application/json"
        Write-StructuredLog "Teams alert sent successfully" "DEBUG" "Alerts"
    }
    catch {
        Write-StructuredLog "Failed to send Teams alert: $($_.Exception.Message)" "ERROR" "Alerts"
    }
}

function Send-EmailAlert {
    param([hashtable]$Alert)

    $emailConfig = $script:AlertConfig.channels.email

    if (-not $emailConfig.smtpServer -or -not $emailConfig.from -or $emailConfig.to.Count -eq 0) {
        Write-StructuredLog "Email configuration incomplete, skipping email alert" "WARNING" "Alerts"
        return
    }

    $subject = "[$($Alert.severity)] Migration Alert: $($Alert.type)"
    $body = @"
Migration Alert

Type: $($Alert.type)
Severity: $($Alert.severity)
Organization: $($Alert.organization)
Timestamp: $($Alert.timestamp)

Message:
$($Alert.message)

Data:
$($Alert.data | ConvertTo-Json -Depth 5)

---
Azure DevOps to GitHub Migration Monitor
"@

    try {
        $mailParams = @{
            SmtpServer = $emailConfig.smtpServer
            Port = $emailConfig.smtpPort
            From = $emailConfig.from
            To = $emailConfig.to
            Subject = $subject
            Body = $body
            UseSsl = $emailConfig.useSsl
        }

        Send-MailMessage @mailParams
        Write-StructuredLog "Email alert sent successfully" "DEBUG" "Alerts"
    }
    catch {
        Write-StructuredLog "Failed to send email alert: $($_.Exception.Message)" "ERROR" "Alerts"
    }
}

#endregion

#region Monitoring Loop Functions

function Show-MonitoringDashboard {
    $status = $script:MonitoringState.CurrentStatus
    $health = $script:MonitoringState.HealthStatus

    Clear-Host

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    MIGRATION MONITORING DASHBOARD                             ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  Organization: $($AdoOrg.PadRight(62))║" -ForegroundColor Cyan
    Write-Host "║  Monitoring Since: $($script:MonitoringState.StartTime.ToString('yyyy-MM-dd HH:mm:ss').PadRight(58))║" -ForegroundColor Cyan
    Write-Host "║  Last Check: $($script:MonitoringState.LastCheck.ToString('yyyy-MM-dd HH:mm:ss').PadRight(64))║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    # Health Status
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│                              HEALTH STATUS                                   │" -ForegroundColor White
    Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White

    $adoHealthColor = if ($health.AdoApiHealth -eq "Healthy") { "Green" } else { "Red" }
    $ghHealthColor = if ($health.GhApiHealth -eq "Healthy") { "Green" } else { "Red" }
    $netHealthColor = if ($health.NetworkHealth -eq "Healthy") { "Green" } elseif ($health.NetworkHealth -eq "Degraded") { "Yellow" } else { "Red" }

    Write-Host "│   Azure DevOps API: " -NoNewline; Write-Host "$($health.AdoApiHealth.PadRight(15))" -ForegroundColor $adoHealthColor -NoNewline; Write-Host "                                      │"
    Write-Host "│   GitHub API:       " -NoNewline; Write-Host "$($health.GhApiHealth.PadRight(15))" -ForegroundColor $ghHealthColor -NoNewline; Write-Host "                                      │"
    Write-Host "│   Network:          " -NoNewline; Write-Host "$($health.NetworkHealth.PadRight(15))" -ForegroundColor $netHealthColor -NoNewline; Write-Host "                                      │"
    Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White

    # Migration Progress
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│                           MIGRATION PROGRESS                                 │" -ForegroundColor White
    Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White

    $barWidth = 50
    $filledWidth = [Math]::Floor(($status.ProgressPercent / 100) * $barWidth)
    $emptyWidth = $barWidth - $filledWidth
    $progressBar = "█" * $filledWidth + "░" * $emptyWidth

    Write-Host "│   Progress: [$progressBar] $($status.ProgressPercent)%   │" -ForegroundColor White
    Write-Host "│                                                                              │" -ForegroundColor White
    Write-Host "│   Total Repositories:    $($status.TotalRepos.ToString().PadLeft(6))                                          │" -ForegroundColor White
    Write-Host "│   Migrated:              $($status.MigratedRepos.ToString().PadLeft(6))                                          │" -ForegroundColor Green
    Write-Host "│   Pending:               $($status.PendingRepos.ToString().PadLeft(6))                                          │" -ForegroundColor Yellow
    Write-Host "│   Failed:                $($status.FailedRepos.ToString().PadLeft(6))                                          │" -ForegroundColor Red

    $rate = Get-MigrationRate
    $eta = Get-EstimatedTimeRemaining

    if ($null -ne $rate) {
        Write-Host "│                                                                              │" -ForegroundColor White
        Write-Host "│   Migration Rate:        $([Math]::Round($rate, 2).ToString().PadLeft(6)) repos/hour                              │" -ForegroundColor Cyan
    }

    if ($null -ne $eta) {
        $etaFormatted = if ($eta -lt 1) { "$([Math]::Round($eta * 60, 0)) minutes" } else { "$([Math]::Round($eta, 1)) hours" }
        Write-Host "│   Estimated Remaining:   $($etaFormatted.PadLeft(20))                         │" -ForegroundColor Cyan
    }

    Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White

    # Statistics
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│                              STATISTICS                                      │" -ForegroundColor White
    Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White
    Write-Host "│   Total Checks:     $($script:MonitoringState.TotalChecks.ToString().PadLeft(10))                                       │" -ForegroundColor White
    Write-Host "│   Alerts Sent:      $($script:MonitoringState.AlertsSent.ToString().PadLeft(10))                                       │" -ForegroundColor White
    Write-Host "│   Errors Logged:    $($script:MonitoringState.Errors.Count.ToString().PadLeft(10))                                       │" -ForegroundColor White
    Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White

    Write-Host ""
    Write-Host "  Next check in $MonitoringInterval seconds... Press Ctrl+C to stop." -ForegroundColor Gray
}

function Invoke-MonitoringCycle {
    $script:MonitoringState.TotalChecks++
    $script:MonitoringState.LastCheck = Get-Date

    Write-StructuredLog "Starting monitoring cycle #$($script:MonitoringState.TotalChecks)" "INFO" "Monitor"

    # Health checks
    $healthOk = Invoke-HealthChecks

    if (-not $healthOk) {
        Write-StructuredLog "Health checks failed, some features may be limited" "WARNING" "Monitor"
    }

    # Get migration status
    $status = Get-MigrationStatus

    # Check for issues
    $previousProgress = $script:MonitoringState.Metrics |
        Where-Object { $_.name -eq "migration_progress_percent" } |
        Select-Object -Last 2 -Skip 1

    if ($previousProgress -and $previousProgress.value -eq $status.ProgressPercent) {
        $stalledMinutes = $script:AlertConfig.thresholds.stalledMinutes
        Write-StructuredLog "Migration progress has not changed since last check" "WARNING" "Monitor"

        # Check if stalled for too long
        $stalledMetrics = $script:MonitoringState.Metrics |
            Where-Object { $_.name -eq "migration_progress_percent" -and $_.value -eq $status.ProgressPercent }

        if ($stalledMetrics.Count -gt ($stalledMinutes / ($MonitoringInterval / 60))) {
            Send-Alert -AlertType "MigrationStalled" -Severity "High" -Message "Migration has been stalled at $($status.ProgressPercent)% for over $stalledMinutes minutes" -Data @{
                progress = $status.ProgressPercent
                stalledMinutes = $stalledMinutes
            }
        }
    }

    # Check for completion
    if ($status.ProgressPercent -eq 100 -and $status.PendingRepos -eq 0) {
        Send-Alert -AlertType "MigrationComplete" -Severity "Low" -Message "Migration completed successfully! All $($status.TotalRepos) repositories have been migrated." -Data @{
            totalRepos = $status.TotalRepos
            duration = ((Get-Date) - $script:MonitoringState.StartTime).TotalHours
        }
    }

    # Display dashboard
    Show-MonitoringDashboard

    Write-StructuredLog "Monitoring cycle #$($script:MonitoringState.TotalChecks) completed" "INFO" "Monitor"
}

#endregion

#region Main Execution

try {
    Write-StructuredLog "=== Migration Monitoring System Started ===" "INFO" "Main"
    Write-StructuredLog "Organization: $AdoOrg -> $GhOrg" "INFO" "Main"
    Write-StructuredLog "Monitoring Interval: $MonitoringInterval seconds" "INFO" "Main"
    Write-StructuredLog "Continuous Mode: $ContinuousMode" "INFO" "Main"

    # Initialize alert configuration
    Initialize-AlertConfig

    # Initial status check
    Invoke-MonitoringCycle

    if ($ContinuousMode) {
        $endTime = (Get-Date).AddHours($MaxRuntime)

        Write-StructuredLog "Entering continuous monitoring mode (max runtime: $MaxRuntime hours)" "INFO" "Main"

        while ((Get-Date) -lt $endTime) {
            Start-Sleep -Seconds $MonitoringInterval
            Invoke-MonitoringCycle
        }

        Write-StructuredLog "Maximum runtime reached, stopping monitoring" "INFO" "Main"
    }

    # Generate final summary
    $summary = @{
        MonitoringStartTime = $script:MonitoringState.StartTime
        MonitoringEndTime = Get-Date
        TotalDuration = ((Get-Date) - $script:MonitoringState.StartTime).TotalMinutes
        TotalChecks = $script:MonitoringState.TotalChecks
        AlertsSent = $script:MonitoringState.AlertsSent
        FinalStatus = $script:MonitoringState.CurrentStatus
        HealthStatus = $script:MonitoringState.HealthStatus
    }

    $summaryPath = Join-Path $OutputDir "monitoring-summary-$(Get-Date -Format 'yyyy-MM-dd-HHmm').json"
    $summary | ConvertTo-Json -Depth 10 | Out-File $summaryPath

    Write-StructuredLog "Monitoring summary saved to: $summaryPath" "INFO" "Main"
    Write-StructuredLog "=== Migration Monitoring System Stopped ===" "INFO" "Main"

}
catch {
    Write-StructuredLog "Critical error in monitoring system: $($_.Exception.Message)" "ERROR" "Main"
    Send-Alert -AlertType "MonitoringFailure" -Severity "Critical" -Message "Monitoring system encountered a critical error: $($_.Exception.Message)"
    exit 1
}

#endregion
