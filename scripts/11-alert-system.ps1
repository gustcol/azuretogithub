<#
.SYNOPSIS
    Alert System for Migration Notifications
.DESCRIPTION
    This script provides a standalone alert system that can send notifications through
    multiple channels (Email, Slack, Teams, Console) based on migration events.
    It can be called by other scripts or run independently for manual alerts.
.PARAMETER AlertType
    Type of alert (MigrationStarted, MigrationComplete, MigrationFailed, HealthCheck, Custom)
.PARAMETER Severity
    Alert severity (Critical, High, Medium, Low, Info)
.PARAMETER Message
    Alert message content
.PARAMETER ConfigPath
    Path to alert configuration file
.PARAMETER Channel
    Specific channel to use (All, Email, Slack, Teams, Console)
.PARAMETER TestMode
    Send test alerts to verify configuration
.PARAMETER Data
    Additional data as JSON string
.EXAMPLE
    ./11-alert-system.ps1 -AlertType "MigrationFailed" -Severity "High" -Message "Repository xyz failed to migrate"
.EXAMPLE
    ./11-alert-system.ps1 -TestMode -Channel "Slack"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("MigrationStarted", "MigrationComplete", "MigrationFailed", "MigrationProgress", "HealthCheck", "HealthCheckFailed", "RateLimitWarning", "Custom")]
    [string]$AlertType = "Custom",

    [Parameter(Mandatory=$false)]
    [ValidateSet("Critical", "High", "Medium", "Low", "Info")]
    [string]$Severity = "Info",

    [Parameter(Mandatory=$false)]
    [string]$Message = "",

    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "./templates/alert-config.json",

    [Parameter(Mandatory=$false)]
    [ValidateSet("All", "Email", "Slack", "Teams", "Console")]
    [string]$Channel = "All",

    [Parameter(Mandatory=$false)]
    [switch]$TestMode,

    [Parameter(Mandatory=$false)]
    [string]$DataJson = "{}",

    [Parameter(Mandatory=$false)]
    [string]$Organization = "",

    [Parameter(Mandatory=$false)]
    [string]$LogDir = "./logs"
)

# Set error handling
$ErrorActionPreference = "Continue"

# Create log directory
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Initialize logging
$script:AlertLogFile = Join-Path $LogDir "alerts-$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-AlertLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:AlertLogFile -Value $logEntry
}

# Alert configuration
$script:AlertConfig = $null

#region Configuration Functions

function Get-DefaultAlertConfig {
    return @{
        enabled = $true
        channels = @{
            email = @{
                enabled = $false
                smtpServer = "smtp.example.com"
                smtpPort = 587
                useSsl = $true
                from = "migration-alerts@example.com"
                to = @("admin@example.com")
                username = ""
                password = ""
            }
            slack = @{
                enabled = $false
                webhookUrl = ""
                channel = "#migration-alerts"
                username = "Migration Bot"
                iconEmoji = ":robot_face:"
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
        suppressDuplicates = $true
        duplicateWindowMinutes = 30
        severityFilter = @("Critical", "High", "Medium", "Low", "Info")
        quietHours = @{
            enabled = $false
            start = "22:00"
            end = "07:00"
            allowCritical = $true
        }
    }
}

function Initialize-AlertConfig {
    if (Test-Path $ConfigPath) {
        try {
            $script:AlertConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
            Write-AlertLog "Alert configuration loaded from $ConfigPath"
        }
        catch {
            Write-AlertLog "Failed to load alert config: $($_.Exception.Message)" "ERROR"
            $script:AlertConfig = Get-DefaultAlertConfig
        }
    }
    else {
        Write-AlertLog "Alert config not found at $ConfigPath, using defaults" "WARNING"
        $script:AlertConfig = Get-DefaultAlertConfig
    }
}

function Save-DefaultConfig {
    param([string]$Path)

    $config = Get-DefaultAlertConfig
    $configJson = $config | ConvertTo-Json -Depth 10

    # Ensure directory exists
    $dir = Split-Path $Path -Parent
    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $configJson | Out-File $Path -Encoding UTF8
    Write-Host "Default configuration saved to: $Path" -ForegroundColor Green
}

#endregion

#region Alert Sending Functions

function Test-QuietHours {
    if (-not $script:AlertConfig.quietHours.enabled) {
        return $false
    }

    $now = Get-Date
    $start = [datetime]::ParseExact($script:AlertConfig.quietHours.start, "HH:mm", $null)
    $end = [datetime]::ParseExact($script:AlertConfig.quietHours.end, "HH:mm", $null)

    $currentTime = Get-Date -Hour $now.Hour -Minute $now.Minute -Second 0

    $inQuietHours = $false
    if ($start -gt $end) {
        # Overnight quiet hours (e.g., 22:00 - 07:00)
        $inQuietHours = ($currentTime -ge $start) -or ($currentTime -lt $end)
    }
    else {
        $inQuietHours = ($currentTime -ge $start) -and ($currentTime -lt $end)
    }

    if ($inQuietHours -and $script:AlertConfig.quietHours.allowCritical -and $Severity -eq "Critical") {
        return $false
    }

    return $inQuietHours
}

function Send-ConsoleAlert {
    param([hashtable]$Alert)

    $color = switch ($Alert.severity) {
        "Critical" { "Red" }
        "High" { "Yellow" }
        "Medium" { "Cyan" }
        "Low" { "White" }
        default { "Gray" }
    }

    $icon = switch ($Alert.severity) {
        "Critical" { "🚨" }
        "High" { "⚠️" }
        "Medium" { "ℹ️" }
        "Low" { "📝" }
        default { "💬" }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor $color
    Write-Host "║  $icon ALERT                                                                   ║" -ForegroundColor $color
    Write-Host "╠══════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor $color
    Write-Host "║  Type:        $($Alert.type.PadRight(62))║" -ForegroundColor $color
    Write-Host "║  Severity:    $($Alert.severity.PadRight(62))║" -ForegroundColor $color
    Write-Host "║  Time:        $($Alert.timestamp.PadRight(62))║" -ForegroundColor $color

    if ($Alert.organization) {
        Write-Host "║  Organization: $($Alert.organization.PadRight(61))║" -ForegroundColor $color
    }

    Write-Host "╠══════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor $color

    # Word wrap message
    $maxWidth = 74
    $words = $Alert.message -split '\s+'
    $lines = @()
    $currentLine = ""

    foreach ($word in $words) {
        if (($currentLine + " " + $word).Length -gt $maxWidth) {
            if ($currentLine) { $lines += $currentLine }
            $currentLine = $word
        }
        else {
            if ($currentLine) {
                $currentLine += " " + $word
            }
            else {
                $currentLine = $word
            }
        }
    }
    if ($currentLine) { $lines += $currentLine }

    foreach ($line in $lines) {
        Write-Host "║  $($line.PadRight(74))║" -ForegroundColor $color
    }

    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor $color
    Write-Host ""

    return $true
}

function Send-SlackAlert {
    param([hashtable]$Alert)

    $config = $script:AlertConfig.channels.slack

    if (-not $config.webhookUrl) {
        Write-AlertLog "Slack webhook URL not configured" "WARNING"
        return $false
    }

    $color = switch ($Alert.severity) {
        "Critical" { "#FF0000" }
        "High" { "#FFA500" }
        "Medium" { "#FFFF00" }
        "Low" { "#00FF00" }
        default { "#808080" }
    }

    $icon = switch ($Alert.severity) {
        "Critical" { ":rotating_light:" }
        "High" { ":warning:" }
        "Medium" { ":information_source:" }
        "Low" { ":memo:" }
        default { ":speech_balloon:" }
    }

    $payload = @{
        channel = $config.channel
        username = $config.username
        icon_emoji = $config.iconEmoji
        attachments = @(
            @{
                color = $color
                pretext = "$icon Migration Alert"
                title = $Alert.type
                text = $Alert.message
                fields = @(
                    @{ title = "Severity"; value = $Alert.severity; short = $true }
                    @{ title = "Time"; value = $Alert.timestamp; short = $true }
                )
                footer = "ADO to GitHub Migration"
                ts = [int][double]::Parse((Get-Date -UFormat %s))
            }
        )
    }

    if ($Alert.organization) {
        $payload.attachments[0].fields += @{ title = "Organization"; value = $Alert.organization; short = $true }
    }

    if ($Alert.data -and $Alert.data.Count -gt 0) {
        $dataText = ($Alert.data.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "`n"
        $payload.attachments[0].fields += @{ title = "Details"; value = "```$dataText```"; short = $false }
    }

    try {
        $jsonPayload = $payload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $config.webhookUrl -Method POST -Body $jsonPayload -ContentType "application/json"
        Write-AlertLog "Slack alert sent successfully"
        return $true
    }
    catch {
        Write-AlertLog "Failed to send Slack alert: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Send-TeamsAlert {
    param([hashtable]$Alert)

    $config = $script:AlertConfig.channels.teams

    if (-not $config.webhookUrl) {
        Write-AlertLog "Teams webhook URL not configured" "WARNING"
        return $false
    }

    $themeColor = switch ($Alert.severity) {
        "Critical" { "FF0000" }
        "High" { "FFA500" }
        "Medium" { "FFFF00" }
        "Low" { "00FF00" }
        default { "808080" }
    }

    $facts = @(
        @{ name = "Severity"; value = $Alert.severity }
        @{ name = "Time"; value = $Alert.timestamp }
    )

    if ($Alert.organization) {
        $facts += @{ name = "Organization"; value = $Alert.organization }
    }

    if ($Alert.data -and $Alert.data.Count -gt 0) {
        foreach ($item in $Alert.data.GetEnumerator()) {
            $facts += @{ name = $item.Key; value = $item.Value.ToString() }
        }
    }

    $payload = @{
        "@type" = "MessageCard"
        "@context" = "http://schema.org/extensions"
        themeColor = $themeColor
        summary = "Migration Alert: $($Alert.type)"
        sections = @(
            @{
                activityTitle = "🔔 Migration Alert: $($Alert.type)"
                activitySubtitle = $Alert.timestamp
                activityImage = "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png"
                facts = $facts
                text = $Alert.message
                markdown = $true
            }
        )
        potentialAction = @(
            @{
                "@type" = "OpenUri"
                name = "View Dashboard"
                targets = @(
                    @{ os = "default"; uri = "https://github.com/$($Alert.organization)" }
                )
            }
        )
    }

    try {
        $jsonPayload = $payload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $config.webhookUrl -Method POST -Body $jsonPayload -ContentType "application/json"
        Write-AlertLog "Teams alert sent successfully"
        return $true
    }
    catch {
        Write-AlertLog "Failed to send Teams alert: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Send-EmailAlert {
    param([hashtable]$Alert)

    $config = $script:AlertConfig.channels.email

    if (-not $config.smtpServer -or -not $config.from -or $config.to.Count -eq 0) {
        Write-AlertLog "Email configuration incomplete" "WARNING"
        return $false
    }

    $priorityMap = @{
        "Critical" = "High"
        "High" = "High"
        "Medium" = "Normal"
        "Low" = "Low"
        "Info" = "Low"
    }

    $subject = "[$($Alert.severity)] Migration Alert: $($Alert.type)"

    $bodyHtml = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .alert-box { border: 2px solid #ccc; border-radius: 8px; padding: 20px; max-width: 600px; }
        .critical { border-color: #FF0000; background-color: #FFE0E0; }
        .high { border-color: #FFA500; background-color: #FFF0E0; }
        .medium { border-color: #FFFF00; background-color: #FFFFE0; }
        .low { border-color: #00FF00; background-color: #E0FFE0; }
        .info { border-color: #808080; background-color: #F0F0F0; }
        .header { font-size: 18px; font-weight: bold; margin-bottom: 15px; }
        .field { margin: 10px 0; }
        .field-label { font-weight: bold; color: #333; }
        .message { background-color: #f5f5f5; padding: 15px; border-radius: 4px; margin: 15px 0; }
        .footer { font-size: 12px; color: #666; margin-top: 20px; border-top: 1px solid #ccc; padding-top: 10px; }
    </style>
</head>
<body>
    <div class="alert-box $($Alert.severity.ToLower())">
        <div class="header">🔔 Migration Alert: $($Alert.type)</div>

        <div class="field">
            <span class="field-label">Severity:</span> $($Alert.severity)
        </div>

        <div class="field">
            <span class="field-label">Time:</span> $($Alert.timestamp)
        </div>

        $(if ($Alert.organization) { "<div class='field'><span class='field-label'>Organization:</span> $($Alert.organization)</div>" })

        <div class="message">
            <span class="field-label">Message:</span><br>
            $($Alert.message)
        </div>

        $(if ($Alert.data -and $Alert.data.Count -gt 0) {
            "<div class='field'><span class='field-label'>Additional Details:</span><br><pre>" +
            (($Alert.data.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "`n") +
            "</pre></div>"
        })

        <div class="footer">
            This alert was generated by the Azure DevOps to GitHub Migration System.<br>
            To configure alerts, edit the alert-config.json file.
        </div>
    </div>
</body>
</html>
"@

    try {
        $mailParams = @{
            SmtpServer = $config.smtpServer
            Port = $config.smtpPort
            From = $config.from
            To = $config.to
            Subject = $subject
            Body = $bodyHtml
            BodyAsHtml = $true
            Priority = $priorityMap[$Alert.severity]
        }

        if ($config.useSsl) {
            $mailParams.UseSsl = $true
        }

        if ($config.username -and $config.password) {
            $securePassword = ConvertTo-SecureString $config.password -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($config.username, $securePassword)
            $mailParams.Credential = $credential
        }

        Send-MailMessage @mailParams
        Write-AlertLog "Email alert sent successfully to: $($config.to -join ', ')"
        return $true
    }
    catch {
        Write-AlertLog "Failed to send email alert: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Send-Alert {
    param([hashtable]$Alert)

    # Check if alerts are enabled
    if (-not $script:AlertConfig.enabled) {
        Write-AlertLog "Alerts are disabled in configuration"
        return
    }

    # Check severity filter
    if ($script:AlertConfig.severityFilter -and $Alert.severity -notin $script:AlertConfig.severityFilter) {
        Write-AlertLog "Alert filtered out by severity filter: $($Alert.severity)"
        return
    }

    # Check quiet hours
    if (Test-QuietHours) {
        Write-AlertLog "Alert suppressed during quiet hours: $($Alert.type)"
        return
    }

    $results = @{
        Console = $false
        Slack = $false
        Teams = $false
        Email = $false
    }

    # Send to appropriate channels
    $channels = if ($Channel -eq "All") {
        @("Console", "Slack", "Teams", "Email")
    }
    else {
        @($Channel)
    }

    foreach ($ch in $channels) {
        $channelConfig = $script:AlertConfig.channels.($ch.ToLower())

        if ($channelConfig -and $channelConfig.enabled) {
            switch ($ch) {
                "Console" { $results.Console = Send-ConsoleAlert -Alert $Alert }
                "Slack" { $results.Slack = Send-SlackAlert -Alert $Alert }
                "Teams" { $results.Teams = Send-TeamsAlert -Alert $Alert }
                "Email" { $results.Email = Send-EmailAlert -Alert $Alert }
            }
        }
    }

    # Log alert
    Write-AlertLog "Alert sent - Type: $($Alert.type), Severity: $($Alert.severity), Channels: $($results.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key } | Join-String -Separator ', ')"

    return $results
}

#endregion

#region Test Functions

function Send-TestAlerts {
    Write-Host "Sending test alerts to configured channels..." -ForegroundColor Cyan
    Write-Host ""

    $testAlert = @{
        type = "TestAlert"
        severity = "Info"
        message = "This is a test alert from the Migration Alert System. If you receive this message, your alert configuration is working correctly."
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        organization = $Organization
        data = @{
            testId = [guid]::NewGuid().ToString()
            configFile = $ConfigPath
        }
    }

    $results = Send-Alert -Alert $testAlert

    Write-Host ""
    Write-Host "Test Results:" -ForegroundColor Cyan
    Write-Host "  Console: $(if ($results.Console) { '✓ Sent' } else { '✗ Not sent/disabled' })" -ForegroundColor $(if ($results.Console) { 'Green' } else { 'Yellow' })
    Write-Host "  Slack:   $(if ($results.Slack) { '✓ Sent' } else { '✗ Not sent/disabled' })" -ForegroundColor $(if ($results.Slack) { 'Green' } else { 'Yellow' })
    Write-Host "  Teams:   $(if ($results.Teams) { '✓ Sent' } else { '✗ Not sent/disabled' })" -ForegroundColor $(if ($results.Teams) { 'Green' } else { 'Yellow' })
    Write-Host "  Email:   $(if ($results.Email) { '✓ Sent' } else { '✗ Not sent/disabled' })" -ForegroundColor $(if ($results.Email) { 'Green' } else { 'Yellow' })
}

#endregion

#region Main Execution

try {
    # Initialize configuration
    Initialize-AlertConfig

    if ($TestMode) {
        Send-TestAlerts
        exit 0
    }

    if (-not $Message) {
        Write-Host "Error: Message is required when not in test mode" -ForegroundColor Red
        exit 1
    }

    # Parse additional data
    $data = @{}
    if ($DataJson -and $DataJson -ne "{}") {
        try {
            $data = $DataJson | ConvertFrom-Json -AsHashtable
        }
        catch {
            Write-AlertLog "Failed to parse data JSON: $($_.Exception.Message)" "WARNING"
        }
    }

    # Build alert object
    $alert = @{
        type = $AlertType
        severity = $Severity
        message = $Message
        timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        organization = $Organization
        data = $data
    }

    # Send alert
    $results = Send-Alert -Alert $alert

    # Return success if at least one channel sent
    $anySuccess = $results.Values | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
    exit $(if ($anySuccess -gt 0) { 0 } else { 1 })

}
catch {
    Write-AlertLog "Alert system error: $($_.Exception.Message)" "ERROR"
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

#endregion
