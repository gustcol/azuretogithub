<#
.SYNOPSIS
    Azure DevOps Organization Inventory and Assessment Tool
.DESCRIPTION
    This script performs a comprehensive audit of your Azure DevOps organization,
    generating CSV reports of repositories, pipelines, users, and permissions.
    It serves as the foundation for planning your migration to GitHub Enterprise Cloud.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER OutputDir
    Directory for generated reports (default: ./reports)
.EXAMPLE
    ./01-inventory.ps1 -AdoOrg "myorg" -AdoPat "my-pat-token"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdoOrg,
    
    [Parameter(Mandatory=$true)]
    [string]$AdoPat,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "./reports"
)

# Import required modules
#Requires -Version 7.0
#Requires -Module Az.Accounts, Az.DevOps

# Set error handling
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Create output directory if it doesn't exist
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $OutputDir "inventory-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

# Azure DevOps API base URL
$adoBaseUrl = "https://dev.azure.com/$AdoOrg"
$apiVersion = "7.1-preview.1"

# Authentication header
$authHeader = @{
    "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
    "Content-Type" = "application/json"
}

Write-Log "Starting Azure DevOps inventory for organization: $AdoOrg"

# Function to make ADO API calls
function Invoke-AdoApi {
    param([string]$Url, [string]$Method = "GET")
    
    try {
        $response = Invoke-RestMethod -Uri $Url -Method $Method -Headers $authHeader
        return $response
    }
    catch {
        Write-Log "API call failed: $Url - $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Function to get all projects
function Get-AdoProjects {
    Write-Log "Fetching Azure DevOps projects..."
    $url = "$adoBaseUrl/_apis/projects?api-version=$apiVersion"
    $projects = Invoke-AdoApi -Url $url
    
    $projectList = @()
    foreach ($project in $projects.value) {
        $projectList += [PSCustomObject]@{
            ProjectId = $project.id
            ProjectName = $project.name
            Description = $project.description
            State = $project.state
            LastUpdateTime = $project.lastUpdateTime
            Url = $project.url
        }
    }
    
    Write-Log "Found $($projectList.Count) projects"
    return $projectList
}

# Function to get repositories for a project
function Get-AdoRepositories {
    param([string]$ProjectName)
    
    Write-Log "Fetching repositories for project: $ProjectName"
    $url = "$adoBaseUrl/$ProjectName/_apis/git/repositories?api-version=$apiVersion"
    $repos = Invoke-AdoApi -Url $url
    
    $repoList = @()
    foreach ($repo in $repos.value) {
        $repoList += [PSCustomObject]@{
            ProjectName = $ProjectName
            RepoId = $repo.id
            RepoName = $repo.name
            DefaultBranch = $repo.defaultBranch
            Size = $repo.size
            RemoteUrl = $repo.remoteUrl
            SshUrl = $repo.sshUrl
            WebUrl = $repo.webUrl
            IsDisabled = $repo.isDisabled
            IsFork = $repo.isFork
            CreatedDate = $repo.createdDate
            LastUpdate = $repo.updatedDate
        }
    }
    
    return $repoList
}

# Function to get build pipelines
function Get-AdoBuildPipelines {
    param([string]$ProjectName)
    
    Write-Log "Fetching build pipelines for project: $ProjectName"
    $url = "$adoBaseUrl/$ProjectName/_apis/build/definitions?api-version=$apiVersion"
    $pipelines = Invoke-AdoApi -Url $url
    
    $pipelineList = @()
    foreach ($pipeline in $pipelines.value) {
        $pipelineList += [PSCustomObject]@{
            ProjectName = $ProjectName
            PipelineId = $pipeline.id
            PipelineName = $pipeline.name
            PipelineType = "Build"
            Path = $pipeline.path
            CreatedDate = $pipeline.createdDate
            ModifiedDate = $pipeline.modifiedDate
            Repository = $pipeline.repository.name
            RepositoryType = $pipeline.repository.type
            IsDisabled = $pipeline.queueStatus -eq "disabled"
            Url = $pipeline.url
        }
    }
    
    return $pipelineList
}

# Function to get release pipelines
function Get-AdoReleasePipelines {
    param([string]$ProjectName)
    
    Write-Log "Fetching release pipelines for project: $ProjectName"
    $url = "$adoBaseUrl/$ProjectName/_apis/release/definitions?api-version=$apiVersion"
    
    try {
        $pipelines = Invoke-AdoApi -Url $url
        
        $pipelineList = @()
        foreach ($pipeline in $pipelines.value) {
            $pipelineList += [PSCustomObject]@{
                ProjectName = $ProjectName
                PipelineId = $pipeline.id
                PipelineName = $pipeline.name
                PipelineType = "Release"
                Path = $pipeline.path
                CreatedDate = $pipeline.createdDate
                ModifiedDate = $pipeline.modifiedOn
                Url = $pipeline.url
            }
        }
        
        return $pipelineList
    }
    catch {
        Write-Log "No release pipelines found or error accessing release API for project $ProjectName" "WARNING"
        return @()
    }
}

# Function to get project users and permissions
function Get-AdoProjectUsers {
    param([string]$ProjectName)
    
    Write-Log "Fetching users and permissions for project: $ProjectName"
    $url = "$adoBaseUrl/_apis/graph/users?api-version=$apiVersion"
    
    try {
        $users = Invoke-AdoApi -Url $url
        
        $userList = @()
        foreach ($user in $users.value) {
            $userList += [PSCustomObject]@{
                ProjectName = $ProjectName
                UserId = $user.descriptor
                DisplayName = $user.displayName
                MailAddress = $user.mailAddress
                PrincipalName = $user.principalName
                SubjectKind = $user.subjectKind
                Url = $user.url
            }
        }
        
        return $userList
    }
    catch {
        Write-Log "Error fetching users for project $ProjectName - $($_.Exception.Message)" "WARNING"
        return @()
    }
}

# Function to calculate repository statistics
function Get-RepoStats {
    param([string]$ProjectName, [string]$RepoName)
    
    Write-Log "Calculating statistics for repository: $RepoName"
    
    # Get commit count (approximate)
    $url = "$adoBaseUrl/$ProjectName/_apis/git/repositories/$RepoName/stats/branches?api-version=$apiVersion"
    
    try {
        $stats = Invoke-AdoApi -Url $url
        
        $totalCommits = 0
        foreach ($branch in $stats.value) {
            if ($branch.aheadCount) {
                $totalCommits += $branch.aheadCount
            }
        }
        
        return @{
            TotalCommits = $totalCommits
            BranchCount = $stats.value.Count
        }
    }
    catch {
        Write-Log "Error getting stats for repository $RepoName - $($_.Exception.Message)" "WARNING"
        return @{
            TotalCommits = 0
            BranchCount = 0
        }
    }
}

# Main execution
try {
    Write-Log "=== Azure DevOps Inventory Started ==="
    
    # Get all projects
    $projects = Get-AdoProjects
    
    # Initialize collections
    $allRepos = @()
    $allBuildPipelines = @()
    $allReleasePipelines = @()
    $allUsers = @()
    
    # Process each project
    foreach ($project in $projects) {
        Write-Log "Processing project: $($project.ProjectName)"
        
        # Get repositories
        $repos = Get-AdoRepositories -ProjectName $project.ProjectName
        $allRepos += $repos
        
        # Get build pipelines
        $buildPipelines = Get-AdoBuildPipelines -ProjectName $project.ProjectName
        $allBuildPipelines += $buildPipelines
        
        # Get release pipelines
        $releasePipelines = Get-AdoReleasePipelines -ProjectName $project.ProjectName
        $allReleasePipelines += $releasePipelines
        
        # Get users
        $users = Get-AdoProjectUsers -ProjectName $project.ProjectName
        $allUsers += $users
        
        Write-Log "Project $($project.ProjectName) processed: $($repos.Count) repos, $($buildPipelines.Count) build pipelines, $($releasePipelines.Count) release pipelines, $($users.Count) users"
    }
    
    # Generate reports
    Write-Log "Generating inventory reports..."
    
    # Projects report
    $projects | Export-Csv -Path (Join-Path $OutputDir "inventory-projects.csv") -NoTypeInformation
    Write-Log "Projects report saved: inventory-projects.csv"
    
    # Repositories report
    $allRepos | Export-Csv -Path (Join-Path $OutputDir "inventory-repos.csv") -NoTypeInformation
    Write-Log "Repositories report saved: inventory-repos.csv"
    
    # Pipelines report (combined)
    $allPipelines = $allBuildPipelines + $allReleasePipelines
    $allPipelines | Export-Csv -Path (Join-Path $OutputDir "inventory-pipelines.csv") -NoTypeInformation
    Write-Log "Pipelines report saved: inventory-pipelines.csv"
    
    # Users report
    $allUsers | Select-Object -Unique | Export-Csv -Path (Join-Path $OutputDir "inventory-users.csv") -NoTypeInformation
    Write-Log "Users report saved: inventory-users.csv"
    
    # Generate summary report
    $summary = [PSCustomObject]@{
        InventoryDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Organization = $AdoOrg
        TotalProjects = $projects.Count
        TotalRepositories = $allRepos.Count
        TotalBuildPipelines = $allBuildPipelines.Count
        TotalReleasePipelines = $allReleasePipelines.Count
        TotalPipelines = $allPipelines.Count
        TotalUsers = ($allUsers | Select-Object -Unique MailAddress).Count
        DisabledRepositories = ($allRepos | Where-Object { $_.IsDisabled -eq $true }).Count
        ForkRepositories = ($allRepos | Where-Object { $_.IsFork -eq $true }).Count
        DisabledPipelines = ($allPipelines | Where-Object { $_.IsDisabled -eq $true }).Count
    }
    
    $summary | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutputDir "inventory-summary.json")
    Write-Log "Summary report saved: inventory-summary.json"
    
    # Display summary
    Write-Log "=== Inventory Summary ===" "INFO"
    Write-Log "Organization: $($summary.Organization)" "INFO"
    Write-Log "Projects: $($summary.TotalProjects)" "INFO"
    Write-Log "Repositories: $($summary.TotalRepositories)" "INFO"
    Write-Log "Build Pipelines: $($summary.TotalBuildPipelines)" "INFO"
    Write-Log "Release Pipelines: $($summary.TotalReleasePipelines)" "INFO"
    Write-Log "Total Users: $($summary.TotalUsers)" "INFO"
    Write-Log "Disabled Repos: $($summary.DisabledRepositories)" "INFO"
    Write-Log "Fork Repos: $($summary.ForkRepositories)" "INFO"
    
    Write-Log "=== Inventory Completed Successfully ==="
    
}
catch {
    Write-Log "Inventory failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}