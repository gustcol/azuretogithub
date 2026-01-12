<#
.SYNOPSIS
    Repository Activity Analysis Tool for Azure DevOps Migration
.DESCRIPTION
    This script analyzes repository activity (commits, pipeline runs) over the last 12 months
    to identify inactive repositories before migration. It helps prioritize migration efforts
    and identify candidates for archival instead of migration.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER OutputDir
    Directory for generated reports (default: ./reports)
.PARAMETER InactivityMonths
    Number of months to consider for inactivity (default: 12)
.PARAMETER IncludeCommits
    Include commit activity analysis (default: $true)
.PARAMETER IncludePipelines
    Include pipeline run analysis (default: $true)
.PARAMETER ExcludeInactive
    Generate a list of active repos only for migration (default: $false)
.PARAMETER MinCommits
    Minimum commits in period to be considered active (default: 1)
.PARAMETER MinPipelineRuns
    Minimum pipeline runs in period to be considered active (default: 0)
.EXAMPLE
    ./08-analyze-activity.ps1 -AdoOrg "myorg" -AdoPat "ado-pat"
.EXAMPLE
    ./08-analyze-activity.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -InactivityMonths 6 -ExcludeInactive
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdoOrg,

    [Parameter(Mandatory=$true)]
    [string]$AdoPat,

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "./reports",

    [Parameter(Mandatory=$false)]
    [int]$InactivityMonths = 12,

    [Parameter(Mandatory=$false)]
    [bool]$IncludeCommits = $true,

    [Parameter(Mandatory=$false)]
    [bool]$IncludePipelines = $true,

    [Parameter(Mandatory=$false)]
    [switch]$ExcludeInactive,

    [Parameter(Mandatory=$false)]
    [int]$MinCommits = 1,

    [Parameter(Mandatory=$false)]
    [int]$MinPipelineRuns = 0,

    [Parameter(Mandatory=$false)]
    [string]$ProjectFilter = "",

    [Parameter(Mandatory=$false)]
    [string]$RepoFilter = ""
)

# Set error handling
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Create output directory if it doesn't exist
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $OutputDir "activity-analysis-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

# Azure DevOps API configuration
$adoBaseUrl = "https://dev.azure.com/$AdoOrg"
$apiVersion = "7.1-preview.1"

# Authentication header
$authHeader = @{
    "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
    "Content-Type" = "application/json"
}

# Calculate cutoff date
$cutoffDate = (Get-Date).AddMonths(-$InactivityMonths)
$cutoffDateString = $cutoffDate.ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Log "=== Repository Activity Analysis Started ==="
Write-Log "Organization: $AdoOrg"
Write-Log "Inactivity Period: $InactivityMonths months"
Write-Log "Cutoff Date: $cutoffDate"
Write-Log "Minimum Commits for Active: $MinCommits"
Write-Log "Minimum Pipeline Runs for Active: $MinPipelineRuns"

# Function to make ADO API calls with error handling
function Invoke-AdoApi {
    param(
        [string]$Url,
        [string]$Method = "GET",
        [int]$RetryCount = 3
    )

    $attempt = 0
    while ($attempt -lt $RetryCount) {
        try {
            $response = Invoke-RestMethod -Uri $Url -Method $Method -Headers $authHeader -TimeoutSec 60
            return $response
        }
        catch {
            $attempt++
            if ($attempt -lt $RetryCount) {
                Write-Log "API call failed (attempt $attempt): $Url - retrying in 5 seconds..." "WARNING"
                Start-Sleep -Seconds 5
            }
            else {
                Write-Log "API call failed after $RetryCount attempts: $Url - $($_.Exception.Message)" "ERROR"
                return $null
            }
        }
    }
}

# Function to get all projects
function Get-AdoProjects {
    Write-Log "Fetching Azure DevOps projects..."
    $url = "$adoBaseUrl/_apis/projects?api-version=$apiVersion"
    $projects = Invoke-AdoApi -Url $url

    if ($null -eq $projects) {
        Write-Log "Failed to fetch projects" "ERROR"
        return @()
    }

    $projectList = $projects.value

    # Apply project filter if specified
    if ($ProjectFilter) {
        $projectList = $projectList | Where-Object { $_.name -like "*$ProjectFilter*" }
        Write-Log "Filtered to $($projectList.Count) projects matching: $ProjectFilter"
    }

    Write-Log "Found $($projectList.Count) projects"
    return $projectList
}

# Function to get repositories for a project
function Get-AdoRepositories {
    param([string]$ProjectName)

    $url = "$adoBaseUrl/$ProjectName/_apis/git/repositories?api-version=$apiVersion"
    $repos = Invoke-AdoApi -Url $url

    if ($null -eq $repos) {
        return @()
    }

    $repoList = $repos.value

    # Apply repo filter if specified
    if ($RepoFilter) {
        $repoList = $repoList | Where-Object { $_.name -like "*$RepoFilter*" }
    }

    return $repoList
}

# Function to get commit activity for a repository
function Get-CommitActivity {
    param(
        [string]$ProjectName,
        [string]$RepoId,
        [string]$RepoName
    )

    Write-Log "Analyzing commits for: $ProjectName/$RepoName" "INFO"

    # Get commits since cutoff date
    $url = "$adoBaseUrl/$ProjectName/_apis/git/repositories/$RepoId/commits?searchCriteria.fromDate=$cutoffDateString&api-version=$apiVersion"
    $commits = Invoke-AdoApi -Url $url

    if ($null -eq $commits) {
        return @{
            CommitCount = 0
            LastCommitDate = $null
            Authors = @()
            HasRecentActivity = $false
        }
    }

    $commitList = $commits.value
    $commitCount = $commitList.Count

    # Get unique authors
    $authors = @()
    if ($commitCount -gt 0) {
        $authors = $commitList | ForEach-Object { $_.author.email } | Select-Object -Unique
    }

    # Get last commit date
    $lastCommitDate = $null
    if ($commitCount -gt 0) {
        $lastCommitDate = ($commitList | Sort-Object { [datetime]$_.committer.date } -Descending | Select-Object -First 1).committer.date
    }

    return @{
        CommitCount = $commitCount
        LastCommitDate = $lastCommitDate
        Authors = $authors
        HasRecentActivity = ($commitCount -ge $MinCommits)
    }
}

# Function to get pipeline runs for a repository
function Get-PipelineActivity {
    param(
        [string]$ProjectName,
        [string]$RepoId,
        [string]$RepoName
    )

    Write-Log "Analyzing pipelines for: $ProjectName/$RepoName" "INFO"

    # Get build definitions for this repository
    $url = "$adoBaseUrl/$ProjectName/_apis/build/definitions?repositoryId=$RepoId&repositoryType=TfsGit&api-version=$apiVersion"
    $definitions = Invoke-AdoApi -Url $url

    $totalRuns = 0
    $successfulRuns = 0
    $failedRuns = 0
    $lastRunDate = $null
    $pipelineNames = @()

    if ($null -ne $definitions -and $definitions.value.Count -gt 0) {
        foreach ($definition in $definitions.value) {
            $pipelineNames += $definition.name

            # Get builds for this definition since cutoff date
            $buildsUrl = "$adoBaseUrl/$ProjectName/_apis/build/builds?definitions=$($definition.id)&minTime=$cutoffDateString&api-version=$apiVersion"
            $builds = Invoke-AdoApi -Url $buildsUrl

            if ($null -ne $builds -and $builds.value.Count -gt 0) {
                $totalRuns += $builds.value.Count
                $successfulRuns += ($builds.value | Where-Object { $_.result -eq "succeeded" }).Count
                $failedRuns += ($builds.value | Where-Object { $_.result -eq "failed" }).Count

                # Track last run date
                $latestBuild = $builds.value | Sort-Object { [datetime]$_.finishTime } -Descending | Select-Object -First 1
                if ($null -ne $latestBuild -and $null -ne $latestBuild.finishTime) {
                    $buildDate = [datetime]$latestBuild.finishTime
                    if ($null -eq $lastRunDate -or $buildDate -gt $lastRunDate) {
                        $lastRunDate = $buildDate
                    }
                }
            }
        }
    }

    return @{
        PipelineCount = $definitions.value.Count
        PipelineNames = $pipelineNames
        TotalRuns = $totalRuns
        SuccessfulRuns = $successfulRuns
        FailedRuns = $failedRuns
        LastRunDate = $lastRunDate
        HasRecentActivity = ($totalRuns -ge $MinPipelineRuns)
    }
}

# Function to determine overall activity status
function Get-ActivityStatus {
    param(
        [hashtable]$CommitActivity,
        [hashtable]$PipelineActivity
    )

    $hasCommitActivity = $CommitActivity.HasRecentActivity
    $hasPipelineActivity = $PipelineActivity.HasRecentActivity

    if ($IncludeCommits -and $IncludePipelines) {
        # Both must be checked - active if either has activity
        if ($hasCommitActivity -or $hasPipelineActivity) {
            return "Active"
        }
        else {
            return "Inactive"
        }
    }
    elseif ($IncludeCommits) {
        return if ($hasCommitActivity) { "Active" } else { "Inactive" }
    }
    elseif ($IncludePipelines) {
        return if ($hasPipelineActivity) { "Active" } else { "Inactive" }
    }
    else {
        return "Unknown"
    }
}

# Main execution
try {
    # Get all projects
    $projects = Get-AdoProjects

    if ($projects.Count -eq 0) {
        Write-Log "No projects found to analyze" "WARNING"
        exit 0
    }

    # Initialize results
    $activityResults = @()
    $totalRepos = 0
    $activeRepos = 0
    $inactiveRepos = 0

    # Process each project
    foreach ($project in $projects) {
        Write-Log "Processing project: $($project.name)"

        # Get repositories
        $repos = Get-AdoRepositories -ProjectName $project.name

        foreach ($repo in $repos) {
            if ($repo.isDisabled) {
                Write-Log "Skipping disabled repository: $($repo.name)" "INFO"
                continue
            }

            $totalRepos++

            # Analyze commit activity
            $commitActivity = @{
                CommitCount = 0
                LastCommitDate = $null
                Authors = @()
                HasRecentActivity = $false
            }

            if ($IncludeCommits) {
                $commitActivity = Get-CommitActivity -ProjectName $project.name -RepoId $repo.id -RepoName $repo.name
            }

            # Analyze pipeline activity
            $pipelineActivity = @{
                PipelineCount = 0
                PipelineNames = @()
                TotalRuns = 0
                SuccessfulRuns = 0
                FailedRuns = 0
                LastRunDate = $null
                HasRecentActivity = $false
            }

            if ($IncludePipelines) {
                $pipelineActivity = Get-PipelineActivity -ProjectName $project.name -RepoId $repo.id -RepoName $repo.name
            }

            # Determine activity status
            $status = Get-ActivityStatus -CommitActivity $commitActivity -PipelineActivity $pipelineActivity

            if ($status -eq "Active") {
                $activeRepos++
            }
            else {
                $inactiveRepos++
            }

            # Determine last activity date
            $lastActivity = $null
            if ($null -ne $commitActivity.LastCommitDate) {
                $lastActivity = [datetime]$commitActivity.LastCommitDate
            }
            if ($null -ne $pipelineActivity.LastRunDate) {
                if ($null -eq $lastActivity -or $pipelineActivity.LastRunDate -gt $lastActivity) {
                    $lastActivity = $pipelineActivity.LastRunDate
                }
            }

            # Calculate days since last activity
            $daysSinceActivity = if ($null -ne $lastActivity) {
                [Math]::Round(((Get-Date) - $lastActivity).TotalDays, 0)
            }
            else {
                999999  # Very large number for repos with no activity
            }

            # Build result object
            $result = [PSCustomObject]@{
                ProjectName = $project.name
                RepoName = $repo.name
                RepoId = $repo.id
                Status = $status
                CommitCount = $commitActivity.CommitCount
                LastCommitDate = $commitActivity.LastCommitDate
                UniqueAuthors = $commitActivity.Authors.Count
                PipelineCount = $pipelineActivity.PipelineCount
                PipelineRuns = $pipelineActivity.TotalRuns
                SuccessfulRuns = $pipelineActivity.SuccessfulRuns
                FailedRuns = $pipelineActivity.FailedRuns
                LastPipelineRun = $pipelineActivity.LastRunDate
                LastActivityDate = $lastActivity
                DaysSinceActivity = $daysSinceActivity
                Size = $repo.size
                DefaultBranch = $repo.defaultBranch
                WebUrl = $repo.webUrl
                Recommendation = if ($status -eq "Inactive") { "Consider archiving or skipping migration" } else { "Migrate" }
            }

            $activityResults += $result

            # Add small delay to avoid rate limiting
            Start-Sleep -Milliseconds 100
        }
    }

    # Generate reports
    Write-Log "Generating activity analysis reports..."

    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"

    # Full activity report
    $fullReportPath = Join-Path $OutputDir "activity-analysis-full-$timestamp.csv"
    $activityResults | Export-Csv -Path $fullReportPath -NoTypeInformation
    Write-Log "Full activity report saved: $fullReportPath"

    # Active repos only (for migration)
    $activeReportPath = Join-Path $OutputDir "activity-analysis-active-$timestamp.csv"
    $activityResults | Where-Object { $_.Status -eq "Active" } | Export-Csv -Path $activeReportPath -NoTypeInformation
    Write-Log "Active repos report saved: $activeReportPath"

    # Inactive repos only (for archival consideration)
    $inactiveReportPath = Join-Path $OutputDir "activity-analysis-inactive-$timestamp.csv"
    $activityResults | Where-Object { $_.Status -eq "Inactive" } | Export-Csv -Path $inactiveReportPath -NoTypeInformation
    Write-Log "Inactive repos report saved: $inactiveReportPath"

    # Migration candidate list (if ExcludeInactive is set)
    if ($ExcludeInactive) {
        $migrationListPath = Join-Path $OutputDir "migration-candidates-$timestamp.csv"
        $activityResults | Where-Object { $_.Status -eq "Active" } |
            Select-Object ProjectName, RepoName, RepoId, CommitCount, PipelineRuns, LastActivityDate |
            Export-Csv -Path $migrationListPath -NoTypeInformation
        Write-Log "Migration candidates list saved: $migrationListPath"
    }

    # Generate summary report
    $summaryReport = [PSCustomObject]@{
        AnalysisDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Organization = $AdoOrg
        InactivityPeriodMonths = $InactivityMonths
        CutoffDate = $cutoffDate.ToString("yyyy-MM-dd")
        MinCommitsForActive = $MinCommits
        MinPipelineRunsForActive = $MinPipelineRuns
        TotalRepositories = $totalRepos
        ActiveRepositories = $activeRepos
        InactiveRepositories = $inactiveRepos
        ActivePercentage = [Math]::Round(($activeRepos / $totalRepos) * 100, 2)
        InactivePercentage = [Math]::Round(($inactiveRepos / $totalRepos) * 100, 2)
        TotalCommitsInPeriod = ($activityResults | Measure-Object -Property CommitCount -Sum).Sum
        TotalPipelineRunsInPeriod = ($activityResults | Measure-Object -Property PipelineRuns -Sum).Sum
        ReposWithNoCommits = ($activityResults | Where-Object { $_.CommitCount -eq 0 }).Count
        ReposWithNoPipelines = ($activityResults | Where-Object { $_.PipelineCount -eq 0 }).Count
        AverageDaysSinceActivity = [Math]::Round(($activityResults | Where-Object { $_.DaysSinceActivity -lt 999999 } | Measure-Object -Property DaysSinceActivity -Average).Average, 0)
        MigrationRecommendation = @{
            MigrateImmediately = $activeRepos
            ConsiderArchiving = $inactiveRepos
            EstimatedMigrationReduction = "$([Math]::Round(($inactiveRepos / $totalRepos) * 100, 1))% fewer repos if excluding inactive"
        }
    }

    $summaryPath = Join-Path $OutputDir "activity-analysis-summary-$timestamp.json"
    $summaryReport | ConvertTo-Json -Depth 10 | Out-File $summaryPath
    Write-Log "Summary report saved: $summaryPath"

    # Display summary
    Write-Log "=== Activity Analysis Summary ===" "INFO"
    Write-Log "Organization: $AdoOrg" "INFO"
    Write-Log "Analysis Period: Last $InactivityMonths months (since $($cutoffDate.ToString('yyyy-MM-dd')))" "INFO"
    Write-Log "Total Repositories: $totalRepos" "INFO"
    Write-Log "Active Repositories: $activeRepos ($([Math]::Round(($activeRepos / $totalRepos) * 100, 1))%)" "INFO"
    Write-Log "Inactive Repositories: $inactiveRepos ($([Math]::Round(($inactiveRepos / $totalRepos) * 100, 1))%)" "INFO"
    Write-Log "" "INFO"
    Write-Log "=== Recommendations ===" "INFO"
    Write-Log "Repositories recommended for migration: $activeRepos" "INFO"
    Write-Log "Repositories to consider archiving: $inactiveRepos" "INFO"

    if ($inactiveRepos -gt 0) {
        Write-Log "" "INFO"
        Write-Log "By excluding inactive repositories, you can reduce migration scope by $([Math]::Round(($inactiveRepos / $totalRepos) * 100, 1))%" "INFO"
        Write-Log "Review the inactive repos report to confirm archival candidates" "WARNING"
    }

    # List top inactive repos
    $topInactive = $activityResults | Where-Object { $_.Status -eq "Inactive" } |
                   Sort-Object DaysSinceActivity -Descending |
                   Select-Object -First 10

    if ($topInactive.Count -gt 0) {
        Write-Log "" "INFO"
        Write-Log "=== Top 10 Most Inactive Repositories ===" "INFO"
        foreach ($repo in $topInactive) {
            $daysSince = if ($repo.DaysSinceActivity -ge 999999) { "Never active" } else { "$($repo.DaysSinceActivity) days" }
            Write-Log "  $($repo.ProjectName)/$($repo.RepoName) - Last activity: $daysSince" "INFO"
        }
    }

    Write-Log "" "INFO"
    Write-Log "=== Activity Analysis Completed Successfully ===" "INFO"

}
catch {
    Write-Log "Activity analysis failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}
