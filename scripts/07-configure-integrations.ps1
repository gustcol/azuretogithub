<#
.SYNOPSIS
    Security Tool Integration Configuration for GitHub Enterprise Cloud
.DESCRIPTION
    This script configures external security tools (Checkov, SonarQube, Black Duck, AquaSec)
    and pre-commit hooks for migrated repositories. It creates workflow files and
    configuration files to enable comprehensive security scanning.
.PARAMETER GhOrg
    GitHub organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER RepoList
    List of repositories to configure (default: all repos in org)
.PARAMETER Tools
    Security tools to configure (Checkov, SonarQube, BlackDuck, AquaSec, PreCommit)
.PARAMETER WhatIf
    Show what would be configured without actually configuring
.EXAMPLE
    ./07-configure-integrations.ps1 -GhOrg "myorg" -GhToken "gh-pat" -Tools "Checkov,SonarQube,PreCommit"
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [string]$GhOrg,
    
    [Parameter(Mandatory=$true)]
    [string]$GhToken,
    
    [Parameter(Mandatory=$false)]
    [string]$RepoList = "",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("All", "Checkov", "SonarQube", "BlackDuck", "AquaSec", "PreCommit")]
    [string]$Tools = "All",
    
    [Parameter(Mandatory=$false)]
    [string]$SonarOrg = "",
    
    [Parameter(Mandatory=$false)]
    [string]$BlackDuckUrl = "",
    
    [Parameter(Mandatory=$false)]
    [string]$TrivyServerUrl = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$CreateSecrets,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipMissingSecrets,
    
    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 5
)

# Set error handling
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Initialize logging
$logFile = "./logs/integrations-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

# GitHub API headers
$ghHeaders = @{
    "Authorization" = "token $GhToken"
    "Accept" = "application/vnd.github.v3+json"
    "Content-Type" = "application/json"
}

Write-Log "Starting security tool integration configuration for organization: $GhOrg"

# Function to get organization repositories
function Get-OrganizationRepositories {
    Write-Log "Fetching organization repositories..."
    
    $repos = @()
    $page = 1
    
    do {
        try {
            $url = "https://api.github.com/orgs/$GhOrg/repos?per_page=100&page=$page"
            $response = Invoke-RestMethod -Uri $url -Method GET -Headers $ghHeaders
            
            $repos += $response
            $page++
            
            if ($response.Count -lt 100) { break }
        }
        catch {
            Write-Log "Error fetching repositories: $($_.Exception.Message)" "ERROR"
            throw
        }
    } while ($true)
    
    # Filter repositories if specific list provided
    if ($RepoList) {
        $repoNames = $RepoList -split "," | ForEach-Object { $_.Trim() }
        $repos = $repos | Where-Object { $repoNames -contains $_.name }
        Write-Log "Filtered to $($repos.Count) repositories from provided list"
    }
    
    Write-Log "Found $($repos.Count) repositories to configure"
    return $repos
}

# Function to check required secrets
function Test-RequiredSecrets {
    param([string]$ToolName)
    
    Write-Log "Checking required secrets for $ToolName"
    
    $requiredSecrets = switch ($ToolName) {
        "SonarQube" {
            @("SONAR_TOKEN", "SONAR_ORGANIZATION", "SONAR_PROJECT_KEY")
        }
        "BlackDuck" {
            @("BLACKDUCK_URL", "BLACKDUCK_API_TOKEN")
        }
        "AquaSec" {
            @("TRIVY_SERVER_URL", "TRIVY_TOKEN")
        }
        default {
            @()
        }
    }
    
    $missingSecrets = @()
    foreach ($secret in $requiredSecrets) {
        try {
            $url = "https://api.github.com/orgs/$GhOrg/actions/secrets/$secret"
            $response = Invoke-RestMethod -Uri $url -Method GET -Headers $ghHeaders
            Write-Log "Secret $secret exists" "INFO"
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                $missingSecrets += $secret
                Write-Log "Secret $secret not found" "WARNING"
            }
        }
    }
    
    if ($missingSecrets.Count -gt 0) {
        if ($SkipMissingSecrets) {
            Write-Log "Skipping $ToolName due to missing secrets: $($missingSecrets -join ', ')" "WARNING"
            return $false
        }
        else {
            Write-Log "Missing secrets for ${ToolName}: $($missingSecrets -join ', ')" "WARNING"
            Write-Log "Consider using -CreateSecrets to create these secrets" "INFO"
            return $false
        }
    }
    
    return $true
}

# Function to create GitHub workflow file
function New-GitHubWorkflow {
    param(
        [string]$RepoName,
        [string]$WorkflowName,
        [string]$WorkflowContent
    )
    
    Write-Log "Creating workflow $WorkflowName for repository $RepoName"
    
    try {
        # Create .github/workflows directory structure
        $workflowPath = ".github/workflows/$WorkflowName"
        
        # Create or update file via GitHub API
        $url = "https://api.github.com/repos/$GhOrg/$RepoName/contents/$workflowPath"
        
        # Check if file already exists
        try {
            $existingFile = Invoke-RestMethod -Uri $url -Method GET -Headers $ghHeaders
            $sha = $existingFile.sha
            Write-Log "Updating existing workflow $WorkflowName" "INFO"
        }
        catch {
            $sha = $null
            Write-Log "Creating new workflow $WorkflowName" "INFO"
        }
        
        # Encode content
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($WorkflowContent)
        $encodedContent = [Convert]::ToBase64String($bytes)
        
        $body = @{
            message = "Add $WorkflowName security workflow"
            content = $encodedContent
            branch = "main"
        }
        
        if ($sha) {
            $body.sha = $sha
        }
        
        if ($PSCmdlet.ShouldProcess("$RepoName/$workflowPath", "Create workflow file")) {
            $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghHeaders -Body ($body | ConvertTo-Json)
            Write-Log "Workflow $WorkflowName created/updated successfully" "SUCCESS"
            return $true
        }
        else {
            Write-Log "Would create workflow $WorkflowName (WhatIf mode)" "INFO"
            return $true
        }
    }
    catch {
        Write-Log "Failed to create workflow ${WorkflowName} for ${RepoName}: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function to create pre-commit configuration
function New-PreCommitConfig {
    param([string]$RepoName)
    
    Write-Log "Creating pre-commit configuration for repository $RepoName"
    
    try {
        # Read template
        $templatePath = "./templates/pre-commit-config.yaml"
        if (!(Test-Path $templatePath)) {
            Write-Log "Pre-commit template not found at $templatePath" "ERROR"
            return $false
        }
        
        $configContent = Get-Content $templatePath -Raw
        
        # Create .pre-commit-config.yaml
        $configPath = ".pre-commit-config.yaml"
        $url = "https://api.github.com/repos/$GhOrg/$RepoName/contents/$configPath"
        
        # Check if file already exists
        try {
            $existingFile = Invoke-RestMethod -Uri $url -Method GET -Headers $ghHeaders
            $sha = $existingFile.sha
            Write-Log "Updating existing pre-commit configuration" "INFO"
        }
        catch {
            $sha = $null
            Write-Log "Creating new pre-commit configuration" "INFO"
        }
        
        # Encode content
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($configContent)
        $encodedContent = [Convert]::ToBase64String($bytes)
        
        $body = @{
            message = "Add pre-commit configuration for code quality"
            content = $encodedContent
            branch = "main"
        }
        
        if ($sha) {
            $body.sha = $sha
        }
        
        if ($PSCmdlet.ShouldProcess("$RepoName/$configPath", "Create pre-commit config")) {
            $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghHeaders -Body ($body | ConvertTo-Json)
            Write-Log "Pre-commit configuration created successfully" "SUCCESS"
            return $true
        }
        else {
            Write-Log "Would create pre-commit configuration (WhatIf mode)" "INFO"
            return $true
        }
    }
    catch {
        Write-Log "Failed to create pre-commit configuration for ${RepoName}: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function to create organization secrets
function New-OrganizationSecrets {
    param([hashtable]$Secrets)
    
    Write-Log "Creating organization secrets"
    
    foreach ($secret in $Secrets.GetEnumerator()) {
        try {
            $url = "https://api.github.com/orgs/$GhOrg/actions/secrets/$($secret.Key)"
            $body = @{
                encrypted_value = $secret.Value
                visibility = "all"
            }
            
            if ($PSCmdlet.ShouldProcess("Organization secret $($secret.Key)", "Create secret")) {
                $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghHeaders -Body ($body | ConvertTo-Json)
                Write-Log "Created organization secret $($secret.Key)" "SUCCESS"
            }
            else {
                Write-Log "Would create organization secret $($secret.Key) (WhatIf mode)" "INFO"
            }
        }
        catch {
            Write-Log "Failed to create secret $($secret.Key): $($_.Exception.Message)" "ERROR"
        }
    }
}

# Function to get workflow template content
function Get-WorkflowTemplate {
    param([string]$ToolName)
    
    $templatePath = "./templates/workflows/$($ToolName.ToLower()).yml"
    if (Test-Path $templatePath) {
        return Get-Content $templatePath -Raw
    }
    else {
        Write-Log "Template not found for $ToolName at $templatePath" "ERROR"
        return $null
    }
}

# Function to configure repository integrations
function Configure-RepositoryIntegrations {
    param(
        [PSCustomObject]$Repo,
        [array]$ToolsToConfigure
    )
    
    $repoName = $Repo.name
    Write-Log "Configuring integrations for repository: $repoName"
    
    $results = @{
        Repository = $repoName
        ConfiguredTools = @()
        FailedTools = @()
        Errors = @()
    }
    
    foreach ($tool in $ToolsToConfigure) {
        Write-Log "Configuring $tool for $repoName"
        
        # Check required secrets
        if (!(Test-RequiredSecrets -ToolName $tool)) {
            $results.FailedTools += $tool
            continue
        }
        
        switch ($tool) {
            "Checkov" {
                $workflowContent = Get-WorkflowTemplate -ToolName "checkov"
                if ($workflowContent) {
                    $workflowContent = $workflowContent -replace 'main, master, develop', 'main, master'
                    $success = New-GitHubWorkflow -RepoName $repoName -WorkflowName "checkov.yml" -WorkflowContent $workflowContent
                    if ($success) {
                        $results.ConfiguredTools += "Checkov"
                    } else {
                        $results.FailedTools += "Checkov"
                    }
                }
            }
            "SonarQube" {
                $workflowContent = Get-WorkflowTemplate -ToolName "sonarqube-cloud"
                if ($workflowContent) {
                    $workflowContent = $workflowContent -replace 'SONAR_ORGANIZATION: \$\{\{ secrets.SONAR_ORGANIZATION \}\}', "SONAR_ORGANIZATION: $SonarOrg"
                    $workflowContent = $workflowContent -replace 'SONAR_PROJECT_KEY: \$\{\{ secrets.SONAR_PROJECT_KEY \}\}', "SONAR_PROJECT_KEY: $repoName"
                    $success = New-GitHubWorkflow -RepoName $repoName -WorkflowName "sonarqube-cloud.yml" -WorkflowContent $workflowContent
                    if ($success) {
                        $results.ConfiguredTools += "SonarQube"
                    } else {
                        $results.FailedTools += "SonarQube"
                    }
                }
            }
            "BlackDuck" {
                if ($BlackDuckUrl) {
                    $workflowContent = Get-WorkflowTemplate -ToolName "blackduck"
                    if ($workflowContent) {
                        $workflowContent = $workflowContent -replace 'BLACKDUCK_URL: \$\{\{ secrets.BLACKDUCK_URL \}\}', "BLACKDUCK_URL: $BlackDuckUrl"
                        $success = New-GitHubWorkflow -RepoName $repoName -WorkflowName "blackduck.yml" -WorkflowContent $workflowContent
                        if ($success) {
                            $results.ConfiguredTools += "BlackDuck"
                        } else {
                            $results.FailedTools += "BlackDuck"
                        }
                    }
                } else {
                    Write-Log "BlackDuck URL not provided, skipping BlackDuck configuration" "WARNING"
                }
            }
            "AquaSec" {
                if ($TrivyServerUrl) {
                    $workflowContent = Get-WorkflowTemplate -ToolName "aquasec"
                    if ($workflowContent) {
                        $workflowContent = $workflowContent -replace 'TRIVY_SERVER_URL: \$\{\{ secrets.TRIVY_SERVER_URL \}\}', "TRIVY_SERVER_URL: $TrivyServerUrl"
                        $success = New-GitHubWorkflow -RepoName $repoName -WorkflowName "aquasec.yml" -WorkflowContent $workflowContent
                        if ($success) {
                            $results.ConfiguredTools += "AquaSec"
                        } else {
                            $results.FailedTools += "AquaSec"
                        }
                    }
                } else {
                    Write-Log "Trivy Server URL not provided, local Trivy scanning will still work" "INFO"
                    # Still configure the workflow for local scanning
                    $workflowContent = Get-WorkflowTemplate -ToolName "aquasec"
                    if ($workflowContent) {
                        $success = New-GitHubWorkflow -RepoName $repoName -WorkflowName "aquasec.yml" -WorkflowContent $workflowContent
                        if ($success) {
                            $results.ConfiguredTools += "AquaSec"
                        } else {
                            $results.FailedTools += "AquaSec"
                        }
                    }
                }
            }
            "PreCommit" {
                $success = New-PreCommitConfig -RepoName $repoName
                if ($success) {
                    $results.ConfiguredTools += "PreCommit"
                } else {
                    $results.FailedTools += "PreCommit"
                }
            }
        }
    }
    
    return $results
}

# Function to process integration batch
function Process-IntegrationBatch {
    param(
        [array]$Batch,
        [int]$BatchNumber,
        [array]$ToolsToConfigure
    )
    
    Write-Log "Processing integration batch $BatchNumber with $($Batch.Count) repositories"
    
    $results = @()
    
    foreach ($repo in $Batch) {
        $result = Configure-RepositoryIntegrations -Repo $repo -ToolsToConfigure $ToolsToConfigure
        $results += $result
        
        # Add delay between repositories
        Start-Sleep -Seconds 2
    }
    
    return $results
}

# Function to generate integration report
function Generate-IntegrationReport {
    param([array]$Results)
    
    Write-Log "Generating integration configuration report"
    
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
    $reportFile = "./logs/integrations-report-$timestamp.json"
    $csvFile = "./logs/integrations-report-$timestamp.csv"
    
    # Export to CSV
    $Results | Select-Object Repository, @{Name="ConfiguredTools";Expression={$_.ConfiguredTools -join "; "}}, @{Name="FailedTools";Expression={$_.FailedTools -join "; "}}, @{Name="Errors";Expression={$_.Errors -join "; "}} | 
               Export-Csv -Path $csvFile -NoTypeInformation
    Write-Log "Integration report CSV saved: $csvFile"
    
    # Generate summary statistics
    $summary = [PSCustomObject]@{
        ConfigurationDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        GitHubOrganization = $GhOrg
        TotalRepositories = $Results.Count
        SuccessfullyConfigured = ($Results | Where-Object { $_.ConfiguredTools.Count -gt 0 }).Count
        FailedConfigurations = ($Results | Where-Object { $_.FailedTools.Count -gt 0 }).Count
        TotalToolsConfigured = ($Results | ForEach-Object { $_.ConfiguredTools.Count } | Measure-Object -Sum).Sum
        ToolsConfigured = ($Results.ConfiguredTools | Select-Object -Unique).Count
        Results = $Results
    }
    
    # Export JSON report
    $summary | ConvertTo-Json -Depth 10 | Out-File $reportFile
    Write-Log "Integration report saved: $reportFile"
    
    return $summary
}

# Main execution
try {
    Write-Log "=== Security Tool Integration Configuration Started ==="
    Write-Log "Organization: $GhOrg"
    Write-Log "Tools to configure: $Tools"
    
    # Determine which tools to configure
    $toolsToConfigure = if ($Tools -eq "All") {
        @("Checkov", "SonarQube", "PreCommit")
    } else {
        $Tools -split "," | ForEach-Object { $_.Trim() }
    }
    
    Write-Log "Will configure the following tools: $($toolsToConfigure -join ', ')"
    
    # Validate required parameters
    if ($toolsToConfigure -contains "SonarQube" -and !$SonarOrg) {
        Write-Log "SonarQube organization not provided, SonarQube configuration may fail" "WARNING"
    }
    
    if ($toolsToConfigure -contains "BlackDuck" -and !$BlackDuckUrl) {
        Write-Log "BlackDuck URL not provided, BlackDuck configuration will be skipped" "WARNING"
        $toolsToConfigure = $toolsToConfigure | Where-Object { $_ -ne "BlackDuck" }
    }
    
    if ($toolsToConfigure -contains "AquaSec" -and !$TrivyServerUrl) {
        Write-Log "Trivy Server URL not provided, Trivy server mode will be skipped (local scanning will still work)" "INFO"
        $toolsToConfigure = $toolsToConfigure | Where-Object { $_ -ne "AquaSec" }
    }
    
    # Get repositories to configure
    $repositories = Get-OrganizationRepositories
    
    Write-Log "Configuring integrations for $($repositories.Count) repositories"
    
    # Process in batches
    $allResults = @()
    $batchNumber = 1
    
    for ($i = 0; $i -lt $repositories.Count; $i += $BatchSize) {
        $batch = $repositories[$i..[Math]::Min($i + $BatchSize - 1, $repositories.Count - 1)]
        
        Write-Log "Starting batch $batchNumber of $([Math]::Ceiling($repositories.Count / $BatchSize))"
        
        # Process batch
        $batchResults = Process-IntegrationBatch -Batch $batch -BatchNumber $batchNumber -ToolsToConfigure $toolsToConfigure
        $allResults += $batchResults
        
        # Add delay between batches
        if ($batchNumber -lt [Math]::Ceiling($repositories.Count / $BatchSize)) {
            Write-Log "Waiting 30 seconds before next batch..."
            Start-Sleep -Seconds 30
        }
        
        $batchNumber++
    }
    
    # Generate final report
    $integrationReport = Generate-IntegrationReport -Results $allResults
    
    # Display summary
    Write-Log "=== Integration Configuration Summary ===" "INFO"
    Write-Log "Total Repositories: $($integrationReport.TotalRepositories)" "INFO"
    Write-Log "Successfully Configured: $($integrationReport.SuccessfullyConfigured)" "INFO"
    Write-Log "Failed Configurations: $($integrationReport.FailedConfigurations)" "INFO"
    Write-Log "Total Tools Configured: $($integrationReport.TotalToolsConfigured)" "INFO"
    Write-Log "Unique Tools: $($integrationReport.ToolsConfigured)" "INFO"
    
    if ($integrationReport.FailedConfigurations -gt 0) {
        Write-Log "Some configurations failed - review logs for details" "WARNING"
    }
    
    Write-Log "=== Security Tool Integration Configuration Completed ==="
    
    # Return appropriate exit code
    if ($integrationReport.FailedConfigurations -eq 0) {
        exit 0
    }
    elseif ($integrationReport.FailedConfigurations -lt $integrationReport.TotalRepositories * 0.2) {
        Write-Log "Integration completed with minor failures" "WARNING"
        exit 1
    }
    else {
        Write-Log "Integration completed with significant failures" "ERROR"
        exit 2
    }
    
}
catch {
    Write-Log "Integration configuration failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}