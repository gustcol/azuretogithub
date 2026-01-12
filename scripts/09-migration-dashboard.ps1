<#
.SYNOPSIS
    Migration Dashboard and Prioritization Tool
.DESCRIPTION
    This script provides a dashboard view of the migration process, displays repository
    counts and migration status, and allows creating prioritization orders for migration.
    It can be run interactively or generate priority lists for batch migration.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER GhOrg
    GitHub organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER OutputDir
    Directory for generated reports (default: ./reports)
.PARAMETER PriorityMode
    Prioritization mode: Activity, Size, Complexity, Custom, or Interactive
.PARAMETER CustomPriorityFile
    Path to custom priority CSV file (for Custom mode)
.PARAMETER ShowDashboard
    Display interactive dashboard (default: $true)
.PARAMETER GeneratePriorityList
    Generate a prioritized migration list file
.PARAMETER IncludeInactive
    Include inactive repositories in priority list (default: $false)
.EXAMPLE
    ./09-migration-dashboard.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -GhOrg "ghorg" -GhToken "gh-pat"
.EXAMPLE
    ./09-migration-dashboard.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -PriorityMode "Activity" -GeneratePriorityList
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdoOrg,

    [Parameter(Mandatory=$true)]
    [string]$AdoPat,

    [Parameter(Mandatory=$false)]
    [string]$GhOrg = "",

    [Parameter(Mandatory=$false)]
    [string]$GhToken = "",

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "./reports",

    [Parameter(Mandatory=$false)]
    [ValidateSet("Activity", "Size", "Complexity", "Custom", "Interactive")]
    [string]$PriorityMode = "Interactive",

    [Parameter(Mandatory=$false)]
    [string]$CustomPriorityFile = "",

    [Parameter(Mandatory=$false)]
    [bool]$ShowDashboard = $true,

    [Parameter(Mandatory=$false)]
    [switch]$GeneratePriorityList,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeInactive,

    [Parameter(Mandatory=$false)]
    [string]$ActivityReportPath = "",

    [Parameter(Mandatory=$false)]
    [int]$RefreshIntervalSeconds = 30
)

# Set error handling
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Create output directory if it doesn't exist
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $OutputDir "dashboard-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $logFile -Value $logEntry
}

# Azure DevOps API configuration
$adoBaseUrl = "https://dev.azure.com/$AdoOrg"
$apiVersion = "7.1-preview.1"

# Authentication headers
$adoAuthHeader = @{
    "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
    "Content-Type" = "application/json"
}

$ghAuthHeader = @{}
if ($GhToken) {
    $ghAuthHeader = @{
        "Authorization" = "token $GhToken"
        "Accept" = "application/vnd.github.v3+json"
        "Content-Type" = "application/json"
    }
}

# Global state for dashboard
$script:DashboardState = @{
    TotalRepos = 0
    ActiveRepos = 0
    InactiveRepos = 0
    MigratedRepos = 0
    PendingRepos = 0
    FailedRepos = 0
    InProgressRepos = 0
    Repositories = @()
    LastRefresh = $null
    MigrationStartTime = $null
}

# Function to make API calls with error handling
function Invoke-ApiCall {
    param(
        [string]$Url,
        [hashtable]$Headers,
        [string]$Method = "GET",
        [int]$RetryCount = 3
    )

    $attempt = 0
    while ($attempt -lt $RetryCount) {
        try {
            $response = Invoke-RestMethod -Uri $Url -Method $Method -Headers $Headers -TimeoutSec 60
            return $response
        }
        catch {
            $attempt++
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds 2
            }
            else {
                Write-Log "API call failed: $Url - $($_.Exception.Message)" "ERROR"
                return $null
            }
        }
    }
}

# Function to get ADO projects and repositories
function Get-AdoRepositories {
    Write-Log "Fetching Azure DevOps repositories..."

    $allRepos = @()

    # Get projects
    $projectsUrl = "$adoBaseUrl/_apis/projects?api-version=$apiVersion"
    $projects = Invoke-ApiCall -Url $projectsUrl -Headers $adoAuthHeader

    if ($null -eq $projects) {
        return @()
    }

    foreach ($project in $projects.value) {
        $reposUrl = "$adoBaseUrl/$($project.name)/_apis/git/repositories?api-version=$apiVersion"
        $repos = Invoke-ApiCall -Url $reposUrl -Headers $adoAuthHeader

        if ($null -ne $repos) {
            foreach ($repo in $repos.value) {
                if (-not $repo.isDisabled) {
                    $allRepos += [PSCustomObject]@{
                        ProjectName = $project.name
                        RepoName = $repo.name
                        RepoId = $repo.id
                        Size = $repo.size
                        SizeMB = [Math]::Round($repo.size / 1MB, 2)
                        DefaultBranch = $repo.defaultBranch
                        WebUrl = $repo.webUrl
                        Status = "Pending"
                        Priority = 0
                        ActivityStatus = "Unknown"
                        LastCommitDate = $null
                        CommitCount = 0
                        PipelineCount = 0
                        MigrationStarted = $null
                        MigrationCompleted = $null
                        ErrorMessage = ""
                    }
                }
            }
        }
    }

    return $allRepos
}

# Function to check if repository exists in GitHub
function Test-GitHubRepoExists {
    param([string]$RepoName)

    if (-not $GhToken -or -not $GhOrg) {
        return $false
    }

    $url = "https://api.github.com/repos/$GhOrg/$RepoName"
    try {
        $response = Invoke-RestMethod -Uri $url -Method GET -Headers $ghAuthHeader -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# Function to load activity analysis data
function Import-ActivityData {
    param([string]$ActivityFile)

    if ($ActivityFile -and (Test-Path $ActivityFile)) {
        Write-Log "Loading activity data from: $ActivityFile"
        return Import-Csv $ActivityFile
    }

    # Try to find the most recent activity analysis file
    $activityFiles = Get-ChildItem -Path $OutputDir -Filter "activity-analysis-full-*.csv" -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending

    if ($activityFiles.Count -gt 0) {
        Write-Log "Loading activity data from: $($activityFiles[0].FullName)"
        return Import-Csv $activityFiles[0].FullName
    }

    return $null
}

# Function to merge activity data with repository list
function Merge-ActivityData {
    param(
        [array]$Repositories,
        [array]$ActivityData
    )

    if ($null -eq $ActivityData) {
        return $Repositories
    }

    foreach ($repo in $Repositories) {
        $activity = $ActivityData | Where-Object {
            $_.ProjectName -eq $repo.ProjectName -and $_.RepoName -eq $repo.RepoName
        }

        if ($activity) {
            $repo.ActivityStatus = $activity.Status
            $repo.LastCommitDate = $activity.LastCommitDate
            $repo.CommitCount = [int]$activity.CommitCount
            $repo.PipelineCount = [int]$activity.PipelineCount
        }
    }

    return $Repositories
}

# Function to calculate priority score
function Get-PriorityScore {
    param(
        [PSCustomObject]$Repo,
        [string]$Mode
    )

    switch ($Mode) {
        "Activity" {
            # Higher activity = higher priority
            $score = $Repo.CommitCount * 10 + $Repo.PipelineCount * 5
            if ($Repo.ActivityStatus -eq "Active") { $score += 1000 }
            return $score
        }
        "Size" {
            # Smaller repos = higher priority (faster migration)
            return [Math]::Max(0, 10000 - $Repo.SizeMB)
        }
        "Complexity" {
            # Lower complexity = higher priority
            $score = 10000
            $score -= $Repo.PipelineCount * 100
            $score -= $Repo.SizeMB
            return [Math]::Max(0, $score)
        }
        default {
            return 0
        }
    }
}

# Function to apply prioritization
function Set-RepositoryPriority {
    param(
        [array]$Repositories,
        [string]$Mode
    )

    Write-Log "Applying prioritization mode: $Mode"

    if ($Mode -eq "Custom" -and $CustomPriorityFile -and (Test-Path $CustomPriorityFile)) {
        $customPriority = Import-Csv $CustomPriorityFile
        $priority = 1
        foreach ($item in $customPriority) {
            $repo = $Repositories | Where-Object {
                $_.ProjectName -eq $item.ProjectName -and $_.RepoName -eq $item.RepoName
            }
            if ($repo) {
                $repo.Priority = $priority++
            }
        }
        # Assign remaining repos lower priority
        $unprioritized = $Repositories | Where-Object { $_.Priority -eq 0 }
        foreach ($repo in $unprioritized) {
            $repo.Priority = $priority++
        }
    }
    else {
        # Calculate scores and sort
        foreach ($repo in $Repositories) {
            $repo.Priority = Get-PriorityScore -Repo $repo -Mode $Mode
        }

        # Convert scores to rankings
        $sorted = $Repositories | Sort-Object Priority -Descending
        $rank = 1
        foreach ($repo in $sorted) {
            $repo.Priority = $rank++
        }
    }

    return $Repositories
}

# Function to update migration status from GitHub
function Update-MigrationStatus {
    param([array]$Repositories)

    if (-not $GhToken -or -not $GhOrg) {
        return $Repositories
    }

    Write-Log "Updating migration status from GitHub..."

    foreach ($repo in $Repositories) {
        $exists = Test-GitHubRepoExists -RepoName $repo.RepoName
        if ($exists) {
            if ($repo.Status -eq "Pending") {
                $repo.Status = "Migrated"
                $repo.MigrationCompleted = Get-Date
            }
        }
    }

    return $Repositories
}

# Function to display dashboard
function Show-Dashboard {
    param([array]$Repositories)

    Clear-Host

    # Calculate statistics
    $total = $Repositories.Count
    $migrated = ($Repositories | Where-Object { $_.Status -eq "Migrated" }).Count
    $pending = ($Repositories | Where-Object { $_.Status -eq "Pending" }).Count
    $inProgress = ($Repositories | Where-Object { $_.Status -eq "InProgress" }).Count
    $failed = ($Repositories | Where-Object { $_.Status -eq "Failed" }).Count
    $active = ($Repositories | Where-Object { $_.ActivityStatus -eq "Active" }).Count
    $inactive = ($Repositories | Where-Object { $_.ActivityStatus -eq "Inactive" }).Count

    $percentComplete = if ($total -gt 0) { [Math]::Round(($migrated / $total) * 100, 1) } else { 0 }

    # Header
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    AZURE DEVOPS TO GITHUB MIGRATION DASHBOARD                 ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  Organization: $($AdoOrg.PadRight(62))║" -ForegroundColor Cyan
    Write-Host "║  Last Refresh: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss').PadRight(62))║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # Repository Statistics
    Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│                           REPOSITORY STATISTICS                              │" -ForegroundColor White
    Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White
    Write-Host "│                                                                              │" -ForegroundColor White
    Write-Host "│   Total Repositories:     $($total.ToString().PadLeft(6))                                            │" -ForegroundColor White
    Write-Host "│   Active (last 12 mo):    $($active.ToString().PadLeft(6))    $(('(' + [Math]::Round(($active/$total)*100,1) + '%)').PadRight(10))                        │" -ForegroundColor Green
    Write-Host "│   Inactive:               $($inactive.ToString().PadLeft(6))    $(('(' + [Math]::Round(($inactive/$total)*100,1) + '%)').PadRight(10))                        │" -ForegroundColor Yellow
    Write-Host "│                                                                              │" -ForegroundColor White
    Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White
    Write-Host ""

    # Migration Status
    Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│                            MIGRATION STATUS                                  │" -ForegroundColor White
    Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White
    Write-Host "│                                                                              │" -ForegroundColor White

    # Progress bar
    $barWidth = 50
    $filledWidth = [Math]::Floor(($percentComplete / 100) * $barWidth)
    $emptyWidth = $barWidth - $filledWidth
    $progressBar = "█" * $filledWidth + "░" * $emptyWidth

    Write-Host "│   Progress: [$progressBar] $percentComplete%   │" -ForegroundColor White
    Write-Host "│                                                                              │" -ForegroundColor White
    Write-Host "│   ✓ Migrated:    $($migrated.ToString().PadLeft(6))                                                 │" -ForegroundColor Green
    Write-Host "│   ⟳ In Progress: $($inProgress.ToString().PadLeft(6))                                                 │" -ForegroundColor Yellow
    Write-Host "│   ○ Pending:     $($pending.ToString().PadLeft(6))                                                 │" -ForegroundColor White
    Write-Host "│   ✗ Failed:      $($failed.ToString().PadLeft(6))                                                 │" -ForegroundColor Red
    Write-Host "│                                                                              │" -ForegroundColor White
    Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor White
    Write-Host ""

    # Top Priority Repositories
    Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor White
    Write-Host "│                        TOP 10 PRIORITY REPOSITORIES                          │" -ForegroundColor White
    Write-Host "├─────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor White
    Write-Host "│  #  │ Project/Repository                    │ Status     │ Size    │ Commits │" -ForegroundColor White
    Write-Host "├─────┼───────────────────────────────────────┼────────────┼─────────┼─────────┤" -ForegroundColor White

    $topRepos = $Repositories | Sort-Object Priority | Select-Object -First 10
    foreach ($repo in $topRepos) {
        $name = "$($repo.ProjectName)/$($repo.RepoName)"
        if ($name.Length -gt 37) { $name = $name.Substring(0, 34) + "..." }

        $statusColor = switch ($repo.Status) {
            "Migrated" { "Green" }
            "InProgress" { "Yellow" }
            "Failed" { "Red" }
            default { "White" }
        }

        $statusIcon = switch ($repo.Status) {
            "Migrated" { "✓" }
            "InProgress" { "⟳" }
            "Failed" { "✗" }
            default { "○" }
        }

        Write-Host ("│ " + $repo.Priority.ToString().PadLeft(3) + " │ " + $name.PadRight(37) + " │ " + "$statusIcon $($repo.Status)".PadRight(10) + " │ " + "$($repo.SizeMB)MB".PadLeft(7) + " │ " + $repo.CommitCount.ToString().PadLeft(7) + " │") -ForegroundColor $statusColor
    }

    Write-Host "└─────┴───────────────────────────────────────┴────────────┴─────────┴─────────┘" -ForegroundColor White
    Write-Host ""

    # Menu
    Write-Host "┌─────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "│  [R] Refresh  [P] Change Priority  [E] Export List  [S] Start Migration  [Q] Quit  │" -ForegroundColor Cyan
    Write-Host "└─────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
}

# Function to show priority selection menu
function Show-PriorityMenu {
    Write-Host ""
    Write-Host "Select Prioritization Mode:" -ForegroundColor Cyan
    Write-Host "  [1] Activity - Prioritize most active repositories"
    Write-Host "  [2] Size - Prioritize smallest repositories (faster migration)"
    Write-Host "  [3] Complexity - Prioritize simpler repositories"
    Write-Host "  [4] Custom - Use custom priority file"
    Write-Host "  [5] Cancel"
    Write-Host ""

    $choice = Read-Host "Enter choice (1-5)"

    switch ($choice) {
        "1" { return "Activity" }
        "2" { return "Size" }
        "3" { return "Complexity" }
        "4" { return "Custom" }
        default { return $null }
    }
}

# Function to export priority list
function Export-PriorityList {
    param(
        [array]$Repositories,
        [string]$OutputPath
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
    $filename = Join-Path $OutputPath "migration-priority-list-$timestamp.csv"

    $exportData = $Repositories | Sort-Object Priority | Select-Object `
        Priority,
        ProjectName,
        RepoName,
        RepoId,
        Status,
        ActivityStatus,
        SizeMB,
        CommitCount,
        PipelineCount,
        LastCommitDate,
        WebUrl

    $exportData | Export-Csv -Path $filename -NoTypeInformation

    Write-Host "Priority list exported to: $filename" -ForegroundColor Green
    Write-Log "Priority list exported to: $filename"

    return $filename
}

# Function to generate migration summary
function Get-MigrationSummary {
    param([array]$Repositories)

    $summary = [PSCustomObject]@{
        GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Organization = $AdoOrg
        TotalRepositories = $Repositories.Count
        ActiveRepositories = ($Repositories | Where-Object { $_.ActivityStatus -eq "Active" }).Count
        InactiveRepositories = ($Repositories | Where-Object { $_.ActivityStatus -eq "Inactive" }).Count
        MigratedRepositories = ($Repositories | Where-Object { $_.Status -eq "Migrated" }).Count
        PendingRepositories = ($Repositories | Where-Object { $_.Status -eq "Pending" }).Count
        FailedRepositories = ($Repositories | Where-Object { $_.Status -eq "Failed" }).Count
        TotalSizeMB = [Math]::Round(($Repositories | Measure-Object -Property SizeMB -Sum).Sum, 2)
        TotalCommits = ($Repositories | Measure-Object -Property CommitCount -Sum).Sum
        PriorityMode = $PriorityMode
    }

    return $summary
}

# Main execution
try {
    Write-Log "=== Migration Dashboard Started ==="
    Write-Log "Organization: $AdoOrg"
    Write-Log "Priority Mode: $PriorityMode"

    # Fetch repositories
    Write-Host "Fetching repositories from Azure DevOps..." -ForegroundColor Cyan
    $repositories = Get-AdoRepositories

    if ($repositories.Count -eq 0) {
        Write-Host "No repositories found." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Found $($repositories.Count) repositories." -ForegroundColor Green

    # Load activity data
    $activityData = Import-ActivityData -ActivityFile $ActivityReportPath
    if ($activityData) {
        $repositories = Merge-ActivityData -Repositories $repositories -ActivityData $activityData
        Write-Host "Activity data merged for $($activityData.Count) repositories." -ForegroundColor Green
    }
    else {
        Write-Host "No activity data found. Run 08-analyze-activity.ps1 first for better prioritization." -ForegroundColor Yellow
    }

    # Filter inactive if requested
    if (-not $IncludeInactive) {
        $beforeCount = $repositories.Count
        $repositories = $repositories | Where-Object { $_.ActivityStatus -ne "Inactive" }
        if ($beforeCount -ne $repositories.Count) {
            Write-Host "Excluded $($beforeCount - $repositories.Count) inactive repositories." -ForegroundColor Yellow
        }
    }

    # Apply initial prioritization
    if ($PriorityMode -ne "Interactive") {
        $repositories = Set-RepositoryPriority -Repositories $repositories -Mode $PriorityMode
    }
    else {
        # Default to Activity mode for initial display
        $repositories = Set-RepositoryPriority -Repositories $repositories -Mode "Activity"
    }

    # Update migration status from GitHub
    if ($GhToken -and $GhOrg) {
        $repositories = Update-MigrationStatus -Repositories $repositories
    }

    # Generate priority list if requested
    if ($GeneratePriorityList) {
        Export-PriorityList -Repositories $repositories -OutputPath $OutputDir

        # Also save summary
        $summary = Get-MigrationSummary -Repositories $repositories
        $summaryPath = Join-Path $OutputDir "migration-summary-$(Get-Date -Format 'yyyy-MM-dd-HHmm').json"
        $summary | ConvertTo-Json -Depth 10 | Out-File $summaryPath
        Write-Host "Summary saved to: $summaryPath" -ForegroundColor Green
    }

    # Show interactive dashboard
    if ($ShowDashboard -and $PriorityMode -eq "Interactive") {
        $running = $true

        while ($running) {
            Show-Dashboard -Repositories $repositories

            $key = Read-Host "Enter command"

            switch ($key.ToUpper()) {
                "R" {
                    Write-Host "Refreshing..." -ForegroundColor Cyan
                    if ($GhToken -and $GhOrg) {
                        $repositories = Update-MigrationStatus -Repositories $repositories
                    }
                }
                "P" {
                    $newMode = Show-PriorityMenu
                    if ($newMode) {
                        $repositories = Set-RepositoryPriority -Repositories $repositories -Mode $newMode
                        Write-Host "Priority updated to: $newMode" -ForegroundColor Green
                        Start-Sleep -Seconds 1
                    }
                }
                "E" {
                    Export-PriorityList -Repositories $repositories -OutputPath $OutputDir
                    Read-Host "Press Enter to continue"
                }
                "S" {
                    Write-Host ""
                    Write-Host "To start migration, run:" -ForegroundColor Yellow
                    Write-Host "  ./scripts/03-migrate-repos.ps1 -PriorityFile <exported-priority-file>" -ForegroundColor Cyan
                    Write-Host ""
                    Read-Host "Press Enter to continue"
                }
                "Q" {
                    $running = $false
                }
            }
        }
    }
    elseif ($ShowDashboard) {
        # Non-interactive display
        Show-Dashboard -Repositories $repositories
    }

    # Final summary
    $summary = Get-MigrationSummary -Repositories $repositories

    Write-Log "=== Migration Dashboard Summary ==="
    Write-Log "Total Repositories: $($summary.TotalRepositories)"
    Write-Log "Active Repositories: $($summary.ActiveRepositories)"
    Write-Log "Inactive Repositories: $($summary.InactiveRepositories)"
    Write-Log "Total Size: $($summary.TotalSizeMB) MB"
    Write-Log "=== Dashboard Session Ended ==="

}
catch {
    Write-Log "Dashboard error: $($_.Exception.Message)" "ERROR"
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
