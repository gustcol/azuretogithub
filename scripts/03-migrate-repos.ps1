<#
.SYNOPSIS
    Azure DevOps to GitHub Repository Migration Executor
.DESCRIPTION
    This script orchestrates the migration of repositories from Azure DevOps to GitHub Enterprise Cloud
    using the GitHub Enterprise Importer (GEI). It supports batch processing, retry logic, and
    comprehensive logging for enterprise-scale migrations.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER GhOrg
    GitHub target organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER MappingFile
    Path to identity mappings file (from 02-generate-mappings.ps1)
.PARAMETER BatchSize
    Number of repositories to migrate concurrently (default: 5)
.PARAMETER RetryCount
    Number of retry attempts for failed migrations (default: 3)
.PARAMETER WhatIf
    Show what would be migrated without actually migrating
.EXAMPLE
    ./03-migrate-repos.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -GhOrg "myghorg" -GhToken "gh-pat" -MappingFile "./reports/gei-mappings.csv"
#>

[CmdletBinding(SupportsShouldProcess=$true)]
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
    [string]$MappingFile = "./reports/gei-mappings.csv",
    
    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 5,
    
    [Parameter(Mandatory=$false)]
    [int]$RetryCount = 3,
    
    [Parameter(Mandatory=$false)]
    [string]$RepoList = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipExisting,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeWiki,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeAttachments
)

# Set error handling
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Create logs directory if it doesn't exist
$logsDir = "./logs"
if (!(Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $logsDir "migration-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

# Validate prerequisites
function Test-Prerequisites {
    Write-Log "Validating prerequisites..."
    
    # Check if GitHub CLI is installed
    try {
        $ghVersion = gh --version
        Write-Log "GitHub CLI version: $($ghVersion[0])"
    }
    catch {
        Write-Log "GitHub CLI not found. Please install GitHub CLI and GEI extension." "ERROR"
        throw "GitHub CLI not installed"
    }
    
    # Check if GEI extension is installed
    try {
        $geiExtensions = gh extension list | Where-Object { $_ -match "gh-gei" }
        if (!$geiExtensions) {
            Write-Log "GitHub Enterprise Importer extension not found. Installing..." "WARNING"
            gh extension install github/gh-gei
        }
        Write-Log "GitHub Enterprise Importer extension is available"
    }
    catch {
        Write-Log "Error checking GEI extension: $($_.Exception.Message)" "ERROR"
        throw
    }
    
    # Check if Azure CLI is installed
    try {
        $azVersion = az --version
        Write-Log "Azure CLI is available"
    }
    catch {
        Write-Log "Azure CLI not found. Some features may not work." "WARNING"
    }
    
    # Validate mapping file
    if (!(Test-Path $MappingFile)) {
        Write-Log "Mapping file not found: $MappingFile" "ERROR"
        Write-Log "Please run 02-generate-mappings.ps1 first to create identity mappings" "ERROR"
        throw "Mapping file not found"
    }
    
    Write-Log "Prerequisites validation completed"
}

# Function to get repository list from ADO
function Get-AdoRepositories {
    Write-Log "Fetching repository list from Azure DevOps..."
    
    $adoBaseUrl = "https://dev.azure.com/$AdoOrg"
    $apiVersion = "7.1-preview.1"
    
    $authHeader = @{
        "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
        "Content-Type" = "application/json"
    }
    
    try {
        # Get all projects first
        $projectsUrl = "$adoBaseUrl/_apis/projects?api-version=$apiVersion"
        $projects = Invoke-RestMethod -Uri $projectsUrl -Method GET -Headers $authHeader
        
        $allRepos = @()
        
        foreach ($project in $projects.value) {
            Write-Log "Processing project: $($project.name)"
            
            # Get repositories for this project
            $reposUrl = "$adoBaseUrl/$($project.name)/_apis/git/repositories?api-version=$apiVersion"
            $repos = Invoke-RestMethod -Uri $reposUrl -Method GET -Headers $authHeader
            
            foreach ($repo in $repos.value) {
                if ($repo.isDisabled -ne $true) {
                    $allRepos += [PSCustomObject]@{
                        ProjectName = $project.name
                        RepoName = $repo.name
                        RepoId = $repo.id
                        DefaultBranch = $repo.defaultBranch
                        Size = $repo.size
                        RemoteUrl = $repo.remoteUrl
                        WebUrl = $repo.webUrl
                        LastUpdate = $repo.updatedDate
                        IsFork = $repo.isFork
                    }
                }
            }
        }
        
        Write-Log "Found $($allRepos.Count) repositories in Azure DevOps"
        return $allRepos
    }
    catch {
        Write-Log "Error fetching repositories from ADO: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Function to check if repository already exists in GitHub
function Test-GitHubRepoExists {
    param([string]$RepoName)
    
    try {
        $repoUrl = "https://api.github.com/repos/$GhOrg/$RepoName"
        $headers = @{
            "Authorization" = "token $GhToken"
            "Accept" = "application/vnd.github.v3+json"
        }
        
        $response = Invoke-RestMethod -Uri $repoUrl -Method GET -Headers $headers
        return $true
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            return $false
        }
        Write-Log "Error checking repository existence: $($_.Exception.Message)" "WARNING"
        return $false
    }
}

# Function to migrate a single repository
function Invoke-RepositoryMigration {
    param(
        [PSCustomObject]$Repo,
        [string]$MigrationId
    )
    
    $repoName = $Repo.RepoName
    $projectName = $Repo.ProjectName
    
    Write-Log "Starting migration for repository: $projectName/$repoName (ID: $MigrationId)"
    
    try {
        # Build migration command
        $migrationArgs = @(
            "gei", "migrate-repo",
            "--ado-org", $AdoOrg,
            "--ado-team-project", $projectName,
            "--ado-repo", $repoName,
            "--github-org", $GhOrg,
            "--github-repo", $repoName,
            "--wait"
        )
        
        # Add identity mapping if available
        if (Test-Path $MappingFile) {
            $migrationArgs += "--user-mapping-file"
            $migrationArgs += $MappingFile
        }
        
        # Add optional flags
        if ($IncludeWiki) {
            $migrationArgs += "--ado-pat"
            $migrationArgs += $AdoPat
        }
        
        if ($IncludeAttachments) {
            $migrationArgs += "--ado-pat"
            $migrationArgs += $AdoPat
        }
        
        # Set environment variables for authentication
        $env:GH_TOKEN = $GhToken
        $env:ADO_PAT = $AdoPat
        
        # Execute migration
        Write-Log "Executing: gh $($migrationArgs -join ' ')"
        
        $output = & gh $migrationArgs 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Log "Migration completed successfully for $repoName"
            
            # Parse migration ID from output
            $migrationUrl = $output | Where-Object { $_ -match "Migration completed successfully. Migration ID: (\d+)" }
            if ($migrationUrl) {
                $actualMigrationId = $matches[1]
                return @{
                    Status = "Success"
                    MigrationId = $actualMigrationId
                    Repository = $repoName
                    Message = "Migration completed successfully"
                }
            }
            
            return @{
                Status = "Success"
                MigrationId = $MigrationId
                Repository = $repoName
                Message = "Migration completed successfully"
            }
        }
        else {
            Write-Log "Migration failed for $repoName with exit code: $exitCode" "ERROR"
            Write-Log "Error output: $($output -join '`n')" "ERROR"
            
            return @{
                Status = "Failed"
                MigrationId = $MigrationId
                Repository = $repoName
                Message = "Migration failed with exit code: $exitCode"
                ErrorOutput = $output
            }
        }
    }
    catch {
        Write-Log "Exception during migration of $repoName: $($_.Exception.Message)" "ERROR"
        
        return @{
            Status = "Failed"
            MigrationId = $MigrationId
            Repository = $repoName
            Message = "Exception: $($_.Exception.Message)"
            ErrorOutput = $_.Exception.Message
        }
    }
}

# Function to process migration batch
function Process-MigrationBatch {
    param(
        [array]$Batch,
        [int]$BatchNumber
    )
    
    Write-Log "Processing batch $BatchNumber with $($Batch.Count) repositories"
    
    $results = @()
    $jobs = @()
    
    # Start migrations in parallel
    foreach ($repo in $Batch) {
        $migrationId = [Guid]::NewGuid().ToString()
        
        if ($PSCmdlet.ShouldProcess("$($repo.ProjectName)/$($repo.RepoName)", "Migrate repository")) {
            # Start job for parallel execution
            $job = Start-Job -ScriptBlock {
                param($Repo, $MigrationId, $AdoOrg, $GhOrg, $GhToken, $AdoPat, $MappingFile)
                
                $repoName = $Repo.RepoName
                $projectName = $Repo.ProjectName
                
                try {
                    # Build migration command
                    $migrationArgs = @(
                        "gei", "migrate-repo",
                        "--ado-org", $AdoOrg,
                        "--ado-team-project", $projectName,
                        "--ado-repo", $repoName,
                        "--github-org", $GhOrg,
                        "--github-repo", $repoName,
                        "--wait"
                    )
                    
                    # Add identity mapping if available
                    if ($MappingFile -and (Test-Path $MappingFile)) {
                        $migrationArgs += "--user-mapping-file"
                        $migrationArgs += $MappingFile
                    }
                    
                    # Set environment variables for authentication
                    $env:GH_TOKEN = $GhToken
                    $env:ADO_PAT = $AdoPat
                    
                    # Execute migration
                    $output = & gh $migrationArgs 2>&1
                    $exitCode = $LASTEXITCODE
                    
                    return @{
                        Status = if ($exitCode -eq 0) { "Success" } else { "Failed" }
                        MigrationId = $MigrationId
                        Repository = $repoName
                        ExitCode = $exitCode
                        Output = $output
                    }
                }
                catch {
                    return @{
                        Status = "Failed"
                        MigrationId = $MigrationId
                        Repository = $repoName
                        Message = "Exception: $($_.Exception.Message)"
                    }
                }
            } -ArgumentList $repo, $migrationId, $AdoOrg, $GhOrg, $GhToken, $AdoPat, $MappingFile
            
            $jobs += @{
                Job = $job
                Repo = $repo
                MigrationId = $migrationId
            }
        }
        else {
            # WhatIf mode
            $results += [PSCustomObject]@{
                Repository = "$($repo.ProjectName)/$($repo.RepoName)"
                Status = "WhatIf"
                MigrationId = $migrationId
                Message = "Would migrate repository"
            }
        }
    }
    
    # Wait for all jobs to complete
    if ($jobs.Count -gt 0) {
        Write-Log "Waiting for $($jobs.Count) migration jobs to complete..."
        
        $completedJobs = 0
        while ($completedJobs -lt $jobs.Count) {
            Start-Sleep -Seconds 30
            
            foreach ($jobInfo in $jobs) {
                if ($jobInfo.Job.State -eq "Completed") {
                    $result = Receive-Job -Job $jobInfo.Job
                    $result | Add-Member -NotePropertyName "Repository" -NotePropertyValue "$($jobInfo.Repo.ProjectName)/$($jobInfo.Repo.RepoName)"
                    $results += $result
                    
                    Remove-Job -Job $jobInfo.Job -Force
                    $completedJobs++
                    
                    Write-Log "Completed migration for $($jobInfo.Repo.RepoName): $($result.Status)"
                }
                elseif ($jobInfo.Job.State -eq "Failed") {
                    $result = [PSCustomObject]@{
                        Repository = "$($jobInfo.Repo.ProjectName)/$($jobInfo.Repo.RepoName)"
                        Status = "Failed"
                        MigrationId = $jobInfo.MigrationId
                        Message = "Job failed unexpectedly"
                    }
                    $results += $result
                    
                    Remove-Job -Job $jobInfo.Job -Force
                    $completedJobs++
                    
                    Write-Log "Job failed for $($jobInfo.Repo.RepoName)" "ERROR"
                }
            }
            
            Write-Log "Progress: $completedJobs/$($jobs.Count) migrations completed"
        }
    }
    
    return $results
}

# Function to generate migration report
function Generate-MigrationReport {
    param([array]$Results)
    
    Write-Log "Generating migration report..."
    
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
    $reportFile = Join-Path $logsDir "migration-report-$timestamp.json"
    
    $report = [PSCustomObject]@{
        MigrationDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AdoOrganization = $AdoOrg
        GitHubOrganization = $GhOrg
        TotalRepositories = $Results.Count
        SuccessfulMigrations = ($Results | Where-Object { $_.Status -eq "Success" }).Count
        FailedMigrations = ($Results | Where-Object { $_.Status -eq "Failed" }).Count
        WhatIfMigrations = ($Results | Where-Object { $_.Status -eq "WhatIf" }).Count
        SuccessRate = [Math]::Round((($Results | Where-Object { $_.Status -eq "Success" }).Count / $Results.Count) * 100, 2)
        Results = $Results
    }
    
    $report | ConvertTo-Json -Depth 10 | Out-File $reportFile
    Write-Log "Migration report saved: $reportFile"
    
    return $report
}

# Main execution
try {
    Write-Log "=== Repository Migration Started ==="
    Write-Log "Source: $AdoOrg -> Target: $GhOrg"
    Write-Log "Batch Size: $BatchSize, Retry Count: $RetryCount"
    
    # Validate prerequisites
    Test-Prerequisites
    
    # Get repository list
    $repositories = Get-AdoRepositories
    
    # Filter repositories if specific list provided
    if ($RepoList) {
        $repoNames = $RepoList -split "," | ForEach-Object { $_.Trim() }
        $repositories = $repositories | Where-Object { $repoNames -contains $_.RepoName }
        Write-Log "Filtered to $($repositories.Count) repositories from provided list"
    }
    
    # Skip existing repositories if requested
    if ($SkipExisting) {
        $existingRepos = @()
        foreach ($repo in $repositories) {
            if (Test-GitHubRepoExists -RepoName $repo.RepoName) {
                $existingRepos += $repo.RepoName
                Write-Log "Skipping existing repository: $($repo.RepoName)"
            }
        }
        $repositories = $repositories | Where-Object { $existingRepos -notcontains $_.RepoName }
        Write-Log "Skipping $($existingRepos.Count) existing repositories"
    }
    
    Write-Log "Preparing to migrate $($repositories.Count) repositories"
    
    # Process in batches
    $allResults = @()
    $batchNumber = 1
    
    for ($i = 0; $i -lt $repositories.Count; $i += $BatchSize) {
        $batch = $repositories[$i..[Math]::Min($i + $BatchSize - 1, $repositories.Count - 1)]
        
        Write-Log "Starting batch $batchNumber of $([Math]::Ceiling($repositories.Count / $BatchSize))"
        
        # Process batch
        $batchResults = Process-MigrationBatch -Batch $batch -BatchNumber $batchNumber
        $allResults += $batchResults
        
        # Add delay between batches to avoid rate limits
        if ($batchNumber -lt [Math]::Ceiling($repositories.Count / $BatchSize)) {
            Write-Log "Waiting 60 seconds before next batch..."
            Start-Sleep -Seconds 60
        }
        
        $batchNumber++
    }
    
    # Generate final report
    $migrationReport = Generate-MigrationReport -Results $allResults
    
    # Display summary
    Write-Log "=== Migration Summary ===" "INFO"
    Write-Log "Total Repositories: $($migrationReport.TotalRepositories)" "INFO"
    Write-Log "Successful Migrations: $($migrationReport.SuccessfulMigrations)" "INFO"
    Write-Log "Failed Migrations: $($migrationReport.FailedMigrations)" "INFO"
    Write-Log "Success Rate: $($migrationReport.SuccessRate)%" "INFO"
    
    if ($migrationReport.FailedMigrations -gt 0) {
        Write-Log "Failed migrations will be retried automatically" "WARNING"
        
        # Retry failed migrations
        $failedRepos = $allResults | Where-Object { $_.Status -eq "Failed" }
        Write-Log "Retrying $($failedRepos.Count) failed migrations..."
        
        for ($retry = 1; $retry -le $RetryCount; $retry++) {
            Write-Log "Retry attempt $retry of $RetryCount"
            
            $retryResults = Process-MigrationBatch -Batch $failedRepos -BatchNumber "Retry-$retry"
            
            # Update results
            foreach ($retryResult in $retryResults) {
                $originalResult = $allResults | Where-Object { $_.MigrationId -eq $retryResult.MigrationId }
                if ($originalResult) {
                    $originalResult.Status = $retryResult.Status
                    $originalResult.Message = $retryResult.Message
                }
            }
            
            # Check if all succeeded
            $remainingFailed = ($retryResults | Where-Object { $_.Status -eq "Failed" }).Count
            if ($remainingFailed -eq 0) {
                Write-Log "All retries completed successfully"
                break
            }
            
            Write-Log "$remainingFailed migrations still failed, waiting before next retry..."
            Start-Sleep -Seconds 300  # 5 minutes between retries
        }
    }
    
    Write-Log "=== Repository Migration Completed ==="
    
    # Return exit code based on success rate
    if ($migrationReport.SuccessRate -ge 95) {
        exit 0
    }
    elseif ($migrationReport.SuccessRate -ge 80) {
        Write-Log "Migration completed with warnings - some repositories failed" "WARNING"
        exit 1
    }
    else {
        Write-Log "Migration completed with significant failures" "ERROR"
        exit 2
    }
    
}
catch {
    Write-Log "Migration failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}