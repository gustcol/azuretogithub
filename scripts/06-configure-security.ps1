<#
.SYNOPSIS
    GitHub Enterprise Cloud Security Hardening and Configuration Tool
.DESCRIPTION
    This script applies security best practices to migrated repositories including
    branch protection rules, secret scanning, Dependabot configuration, and
    GitHub Advanced Security features.
.PARAMETER GhOrg
    GitHub organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER RepoList
    List of repositories to configure (default: all repos in org)
.PARAMETER ConfigFile
    Path to security configuration file
.PARAMETER ApplyToAll
    Apply security settings to all repositories in the organization
.PARAMETER WhatIf
    Show what would be configured without actually applying
.EXAMPLE
    ./06-configure-security.ps1 -GhOrg "myorg" -GhToken "gh-pat" -ApplyToAll
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
    [string]$ConfigFile = "./templates/branch-protection.json",
    
    [Parameter(Mandatory=$false)]
    [switch]$ApplyToAll,
    
    [Parameter(Mandatory=$false)]
    [switch]$EnableAdvancedSecurity,
    
    [Parameter(Mandatory=$false)]
    [switch]$EnableSecretScanning,
    
    [Parameter(Mandatory=$false)]
    [switch]$EnableDependabot,
    
    [Parameter(Mandatory=$false)]
    [switch]$EnableCodeQL,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 10
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
$logFile = Join-Path $logsDir "security-config-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

# GitHub API base URL
$ghApiBase = "https://api.github.com"
$ghAuthHeader = @{
    "Authorization" = "token $GhToken"
    "Accept" = "application/vnd.github.v3+json"
    "Content-Type" = "application/json"
}

Write-Log "Starting security configuration for GitHub organization: $GhOrg"

# Function to get organization repositories
function Get-OrganizationRepositories {
    Write-Log "Fetching organization repositories..."
    
    $repos = @()
    $page = 1
    
    do {
        try {
            $url = "$ghApiBase/orgs/$GhOrg/repos?per_page=100&page=$page"
            $response = Invoke-RestMethod -Uri $url -Method GET -Headers $ghAuthHeader
            
            $repos += $response
            
            # Check if there are more pages
            if ($response.Count -lt 100) {
                break
            }
            
            $page++
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

# Function to load security configuration
function Get-SecurityConfig {
    Write-Log "Loading security configuration..."
    
    try {
        if (Test-Path $ConfigFile) {
            $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            Write-Log "Loaded security configuration from: $ConfigFile"
        }
        else {
            # Default configuration
            $config = [PSCustomObject]@{
                branchProtection = [PSCustomObject]@{
                    required_status_checks = [PSCustomObject]@{
                        strict = $true
                        contexts = @("continuous-integration")
                    }
                    enforce_admins = $false
                    required_pull_request_reviews = [PSCustomObject]@{
                        required_approving_review_count = 2
                        dismiss_stale_reviews = $true
                        require_code_owner_reviews = $true
                        dismissal_restrictions = @{}
                    }
                    restrictions = $null
                    allow_force_pushes = $false
                    allow_deletions = $false
                    required_conversation_resolution = $true
                }
                securityFeatures = [PSCustomObject]@{
                    advanced_security = $EnableAdvancedSecurity
                    secret_scanning = $EnableSecretScanning
                    secret_scanning_push_protection = $true
                    dependabot_alerts = $EnableDependabot
                    dependabot_security_updates = $true
                    code_scanning_default_setup = [PSCustomObject]@{
                        state = if ($EnableCodeQL) { "configured" } else { "not-configured" }
                        languages = @("javascript", "python", "csharp", "java", "go", "ruby", "swift")
                    }
                }
                teamPermissions = [PSCustomObject]@{
                    default_permission = "push"
                    admin_teams = @("admin-team")
                    maintain_teams = @("maintain-team")
                    push_teams = @("developers")
                    pull_teams = @("readers")
                }
            }
            
            Write-Log "Using default security configuration"
        }
        
        return $config
    }
    catch {
        Write-Log "Error loading security configuration: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Function to configure branch protection
function Set-BranchProtection {
    param(
        [string]$RepoName,
        [string]$Branch = "main",
        [PSCustomObject]$Config
    )
    
    Write-Log "Configuring branch protection for $RepoName/$Branch"
    
    try {
        $url = "$ghApiBase/repos/$GhOrg/$RepoName/branches/$Branch/protection"
        
        $body = $Config.branchProtection | ConvertTo-Json -Depth 10 -Compress
        
        Write-Log "Applying branch protection rules to $RepoName/$Branch"
        
        $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghAuthHeader -Body $body
        
        Write-Log "Branch protection configured successfully for $RepoName/$Branch"
        return $true
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Log "Branch $Branch not found in $RepoName - trying 'master'" "WARNING"
            
            # Try master branch
            try {
                $url = "$ghApiBase/repos/$GhOrg/$RepoName/branches/master/protection"
                $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghAuthHeader -Body $body
                Write-Log "Branch protection configured successfully for $RepoName/master"
                return $true
            }
            catch {
                Write-Log "Failed to configure branch protection for $RepoName: $($_.Exception.Message)" "ERROR"
                return $false
            }
        }
        elseif ($_.Exception.Response.StatusCode -eq 422) {
            Write-Log "Branch protection may already be configured for $RepoName" "WARNING"
            return $true
        }
        else {
            Write-Log "Error configuring branch protection for $RepoName: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }
}

# Function to enable GitHub Advanced Security features
function Enable-AdvancedSecurity {
    param(
        [string]$RepoName,
        [PSCustomObject]$Config
    )
    
    Write-Log "Enabling advanced security features for $RepoName"
    
    try {
        $features = $Config.securityFeatures
        $results = @{}
        
        # Enable advanced security
        if ($features.advanced_security) {
            $url = "$ghApiBase/repos/$GhOrg/$RepoName/advanced-security"
            $body = @{ "enabled" = $true } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri $url -Method PATCH -Headers $ghAuthHeader -Body $body
                $results.AdvancedSecurity = "Enabled"
                Write-Log "Advanced security enabled for $RepoName"
            }
            catch {
                Write-Log "Failed to enable advanced security for $RepoName: $($_.Exception.Message)" "WARNING"
                $results['AdvancedSecurity'] = "Failed"
            }
        }
        
        # Enable secret scanning
        if ($features.secret_scanning) {
            $url = "$ghApiBase/repos/$GhOrg/$RepoName/secret-scanning"
            $body = @{ "enabled" = $true } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri $url -Method PATCH -Headers $ghAuthHeader -Body $body
                $results.SecretScanning = "Enabled"
                Write-Log "Secret scanning enabled for $RepoName"
            }
            catch {
                Write-Log "Failed to enable secret scanning for $RepoName: $($_.Exception.Message)" "WARNING"
                $results['SecretScanning'] = "Failed"
            }
        }
        
        # Enable secret scanning push protection
        if ($features.secret_scanning_push_protection) {
            $url = "$ghApiBase/repos/$GhOrg/$RepoName/secret-scanning/push-protection"
            $body = @{ "enabled" = $true } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri $url -Method PATCH -Headers $ghAuthHeader -Body $body
                $results.PushProtection = "Enabled"
                Write-Log "Secret scanning push protection enabled for $RepoName"
            }
            catch {
                Write-Log "Failed to enable push protection for $RepoName: $($_.Exception.Message)" "WARNING"
                $results['PushProtection'] = "Failed"
            }
        }
        
        # Enable Dependabot alerts
        if ($features.dependabot_alerts) {
            $url = "$ghApiBase/repos/$GhOrg/$RepoName/vulnerability-alerts"
            
            try {
                $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghAuthHeader
                $results.DependabotAlerts = "Enabled"
                Write-Log "Dependabot alerts enabled for $RepoName"
            }
            catch {
                Write-Log "Failed to enable Dependabot alerts for $RepoName: $($_.Exception.Message)" "WARNING"
                $results['DependabotAlerts'] = "Failed"
            }
        }
        
        # Enable Dependabot security updates
        if ($features.dependabot_security_updates) {
            $url = "$ghApiBase/repos/$GhOrg/$RepoName/automated-security-fixes"
            
            try {
                $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghAuthHeader
                $results.DependabotSecurityUpdates = "Enabled"
                Write-Log "Dependabot security updates enabled for $RepoName"
            }
            catch {
                Write-Log "Failed to enable Dependabot security updates for $RepoName: $($_.Exception.Message)" "WARNING"
                $results['DependabotSecurityUpdates'] = "Failed"
            }
        }
        
        # Configure CodeQL
        if ($features.code_scanning_default_setup.state -eq "configured") {
            $url = "$ghApiBase/repos/$GhOrg/$RepoName/code-scanning/default-setup"
            $body = @{
                "state" = "configured"
                "languages" = $features.code_scanning_default_setup.languages
                "query_suite" = "default"
            } | ConvertTo-Json
            
            try {
                $response = Invoke-RestMethod -Uri $url -Method PATCH -Headers $ghAuthHeader -Body $body
                $results.CodeQL = "Configured"
                Write-Log "CodeQL default setup configured for $RepoName"
            }
            catch {
                Write-Log "Failed to configure CodeQL for $RepoName: $($_.Exception.Message)" "WARNING"
                $results['CodeQL'] = "Failed"
            }
        }
        
        return $results
    }
    catch {
        Write-Log "Error enabling advanced security features for $RepoName: $($_.Exception.Message)" "ERROR"
        return @{ 'Error' = $_.Exception.Message }
    }
}

# Function to create Dependabot configuration
function New-DependabotConfig {
    param([string]$RepoName)
    
    Write-Log "Creating Dependabot configuration for $RepoName"
    
    try {
        $dependabotConfig = @"
version: 2
updates:
  # Enable version updates for npm
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
    
  # Enable version updates for Docker
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
      
  # Enable version updates for GitHub Actions
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
      
  # Enable version updates for pip
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
      
  # Enable version updates for Maven
  - package-ecosystem: "maven"
    directory: "/"
    schedule:
      interval: "weekly"
      
  # Enable version updates for NuGet
  - package-ecosystem: "nuget"
    directory: "/"
    schedule:
      interval: "weekly"
"@

        # Create .github directory if it doesn't exist
        $githubDir = ".github"
        if (!(Test-Path $githubDir)) {
            New-Item -ItemType Directory -Path $githubDir -Force | Out-Null
        }
        
        # Write dependabot.yml
        $configPath = Join-Path $githubDir "dependabot.yml"
        $dependabotConfig | Out-File $configPath -Encoding UTF8
        
        Write-Log "Dependabot configuration created: $configPath"
        
        # Commit and push the configuration (this would need to be done via API or CLI)
        return $true
    }
    catch {
        Write-Log "Error creating Dependabot configuration: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function to configure team permissions
function Set-TeamPermissions {
    param(
        [string]$RepoName,
        [PSCustomObject]$Config
    )
    
    Write-Log "Configuring team permissions for $RepoName"
    
    try {
        $teams = $Config.teamPermissions
        $results = @{}
        
        # Get current teams
        $url = "$ghApiBase/repos/$GhOrg/$RepoName/teams"
        $currentTeams = Invoke-RestMethod -Uri $url -Method GET -Headers $ghAuthHeader
        
        # Configure admin teams
        foreach ($team in $teams.admin_teams) {
            try {
                $url = "$ghApiBase/teams/$team/repos/$GhOrg/$RepoName"
                $body = @{ "permission" = "admin" } | ConvertTo-Json
                
                $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghAuthHeader -Body $body
                $results["Admin-$team"] = "Configured"
                Write-Log "Admin permission granted to team: $team"
            }
            catch {
                Write-Log "Failed to configure admin permission for team $team: $($_.Exception.Message)" "WARNING"
                $results["Admin-$team"] = "Failed"
            }
        }
        
        # Configure maintain teams
        foreach ($team in $teams.maintain_teams) {
            try {
                $url = "$ghApiBase/teams/$team/repos/$GhOrg/$RepoName"
                $body = @{ "permission" = "maintain" } | ConvertTo-Json
                
                $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghAuthHeader -Body $body
                $results["Maintain-$team"] = "Configured"
                Write-Log "Maintain permission granted to team: $team"
            }
            catch {
                Write-Log "Failed to configure maintain permission for team $team: $($_.Exception.Message)" "WARNING"
                $results["Maintain-$team"] = "Failed"
            }
        }
        
        # Configure push teams
        foreach ($team in $teams.push_teams) {
            try {
                $url = "$ghApiBase/teams/$team/repos/$GhOrg/$RepoName"
                $body = @{ "permission" = "push" } | ConvertTo-Json
                
                $response = Invoke-RestMethod -Uri $url -Method PUT -Headers $ghAuthHeader -Body $body
                $results["Push-$team"] = "Configured"
                Write-Log "Push permission granted to team: $team"
            }
            catch {
                Write-Log "Failed to configure push permission for team $team: $($_.Exception.Message)" "WARNING"
                $results["Push-$team"] = "Failed"
            }
        }
        
        return $results
    }
    catch {
        Write-Log "Error configuring team permissions for $RepoName: $($_.Exception.Message)" "ERROR"
        return @{ 'Error' = $_.Exception.Message }
    }
}

# Function to configure repository security settings
function Configure-RepositorySecurity {
    param(
        [PSCustomObject]$Repo,
        [PSCustomObject]$Config
    )
    
    $repoName = $Repo.name
    Write-Log "Configuring security for repository: $repoName"
    
    $results = [PSCustomObject]@{
        Repository = $repoName
        BranchProtection = $false
        AdvancedSecurity = @{}
        TeamPermissions = @{}
        DependabotConfig = $false
        Errors = @()
    }
    
    try {
        # 1. Configure branch protection
        Write-Log "Configuring branch protection for $repoName..."
        $branchResult = Set-BranchProtection -RepoName $repoName -Config $Config
        $results.BranchProtection = $branchResult
        
        # 2. Enable advanced security features
        Write-Log "Enabling advanced security features for $repoName..."
        $securityResults = Enable-AdvancedSecurity -RepoName $repoName -Config $Config
        $results.AdvancedSecurity = $securityResults
        
        # 3. Configure team permissions
        Write-Log "Configuring team permissions for $repoName..."
        $teamResults = Set-TeamPermissions -RepoName $repoName -Config $Config
        $results.TeamPermissions = $teamResults
        
        # 4. Create Dependabot configuration
        if ($Config.securityFeatures.dependabot_alerts) {
            Write-Log "Creating Dependabot configuration for $repoName..."
            $dependabotResult = New-DependabotConfig -RepoName $repoName
            $results.DependabotConfig = $dependabotResult
        }
        
        Write-Log "Security configuration completed for $repoName"
        return $results
        
    }
    catch {
        $errorMsg = "Error configuring security for $repoName: $($_.Exception.Message)"
        Write-Log $errorMsg "ERROR"
        $results.Errors += $errorMsg
        return $results
    }
}

# Function to process repository batch
function Process-SecurityBatch {
    param(
        [array]$Batch,
        [int]$BatchNumber,
        [PSCustomObject]$Config
    )
    
    Write-Log "Processing security batch $BatchNumber with $($Batch.Count) repositories"
    
    $results = @()
    
    foreach ($repo in $Batch) {
        if ($PSCmdlet.ShouldProcess($repo.name, "Configure security settings")) {
            $result = Configure-RepositorySecurity -Repo $repo -Config $Config
            $results += $result
            
            # Add delay between repositories to avoid rate limits
            Start-Sleep -Seconds 2
        }
        else {
            # WhatIf mode
            $results += [PSCustomObject]@{
                Repository = $repo.name
                Status = "WhatIf"
                Message = "Would configure security settings"
            }
        }
    }
    
    return $results
}

# Function to generate security configuration report
function Generate-SecurityReport {
    param([array]$Results)
    
    Write-Log "Generating security configuration report..."
    
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
    $reportFile = Join-Path $logsDir "security-config-report-$timestamp.json"
    $csvFile = Join-Path $logsDir "security-config-report-$timestamp.csv"
    
    # Export to CSV
    $Results | Select-Object Repository, BranchProtection, @{Name="AdvancedSecurity";Expression={$_.AdvancedSecurity.Keys -join "; "}}, @{Name="TeamPermissions";Expression={$_.TeamPermissions.Keys -join "; "}}, @{Name="Errors";Expression={$_.Errors -join "; "}} | 
               Export-Csv -Path $csvFile -NoTypeInformation
    Write-Log "Security report CSV saved: $csvFile"
    
    # Generate summary statistics
    $summary = [PSCustomObject]@{
        ConfigurationDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        GitHubOrganization = $GhOrg
        TotalRepositories = $Results.Count
        BranchProtectionConfigured = ($Results | Where-Object { $_.BranchProtection -eq $true }).Count
        AdvancedSecurityEnabled = ($Results | Where-Object { $_.AdvancedSecurity.Count -gt 0 }).Count
        SecretScanningEnabled = ($Results | Where-Object { $_.AdvancedSecurity.SecretScanning -eq "Enabled" }).Count
        DependabotAlertsEnabled = ($Results | Where-Object { $_.AdvancedSecurity.DependabotAlerts -eq "Enabled" }).Count
        CodeQLConfigured = ($Results | Where-Object { $_.AdvancedSecurity.CodeQL -eq "Configured" }).Count
        TeamPermissionsConfigured = ($Results | Where-Object { $_.TeamPermissions.Count -gt 0 }).Count
        ErrorsEncountered = ($Results | Where-Object { $_.Errors.Count -gt 0 }).Count
        SuccessRate = [Math]::Round((($Results | Where-Object { $_.Errors.Count -eq 0 }).Count / $Results.Count) * 100, 2)
        Results = $Results
    }
    
    # Export JSON report
    $summary | ConvertTo-Json -Depth 10 | Out-File $reportFile
    Write-Log "Security configuration report saved: $reportFile"
    
    return $summary
}

# Function to create security policy file
function New-SecurityPolicy {
    param([string]$OutputPath)
    
    Write-Log "Creating security policy file..."
    
    $securityPolicy = @"
# Security Policy

## Supported Versions

We release patches for security vulnerabilities. Which versions are eligible receiving such patches depend on the CVSS v3.0 Rating:

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

Please report vulnerabilities to our security team at: security@$GhOrg.com

**Please do not report security vulnerabilities through public GitHub issues.**

Please include the following information:
- Type of vulnerability
- Full paths of source file(s) related to the vulnerability
- Location of the affected source code (tag/branch/commit or direct URL)
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the vulnerability

We will acknowledge receipt of your vulnerability report within 48 hours and provide regular updates on our progress.

## Security Features

This repository has the following security features enabled:
- Branch protection rules
- Required pull request reviews
- Secret scanning
- Dependabot alerts
- CodeQL analysis
- Security advisories

## Best Practices

### For Contributors
- Never commit secrets or sensitive data
- Use environment variables for configuration
- Follow the principle of least privilege
- Keep dependencies updated
- Review code for security vulnerabilities

### For Maintainers
- Regularly review and update security settings
- Monitor security alerts and advisories
- Keep GitHub Actions and dependencies updated
- Follow secure coding practices
"@

    $policyPath = Join-Path $OutputPath "SECURITY.md"
    $securityPolicy | Out-File $policyPath -Encoding UTF8
    
    Write-Log "Security policy created: $policyPath"
}

# Main execution
try {
    Write-Log "=== Security Configuration Started ==="
    Write-Log "Organization: $GhOrg"
    Write-Log "Apply to All: $ApplyToAll"
    Write-Log "Advanced Security: $EnableAdvancedSecurity"
    Write-Log "Secret Scanning: $EnableSecretScanning"
    Write-Log "Dependabot: $EnableDependabot"
    Write-Log "CodeQL: $EnableCodeQL"
    
    # Validate prerequisites
    Write-Log "Validating GitHub CLI and permissions..."
    
    try {
        $ghVersion = gh --version
        Write-Log "GitHub CLI version: $($ghVersion[0])"
        
        # Test authentication
        $authTest = gh api user --jq '.login'
        Write-Log "Authenticated as: $authTest"
    }
    catch {
        Write-Log "GitHub CLI authentication failed: $($_.Exception.Message)" "ERROR"
        throw "GitHub CLI not properly authenticated"
    }
    
    # Load security configuration
    $securityConfig = Get-SecurityConfig
    
    # Get repositories to configure
    if ($ApplyToAll) {
        $repositories = Get-OrganizationRepositories
    }
    elseif ($RepoList) {
        $repositories = Get-OrganizationRepositories | Where-Object { $RepoList -split "," -contains $_.name }
    }
    else {
        Write-Log "No repositories specified. Use -ApplyToAll or provide -RepoList" "ERROR"
        throw "No repositories to configure"
    }
    
    Write-Log "Configuring security for $($repositories.Count) repositories"
    
    # Process in batches
    $allResults = @()
    $batchNumber = 1
    
    for ($i = 0; $i -lt $repositories.Count; $i += $BatchSize) {
        $batch = $repositories[$i..[Math]::Min($i + $BatchSize - 1, $repositories.Count - 1)]
        
        Write-Log "Starting security batch $batchNumber of $([Math]::Ceiling($repositories.Count / $BatchSize))"
        
        # Process batch
        $batchResults = Process-SecurityBatch -Batch $batch -BatchNumber $batchNumber -Config $securityConfig
        $allResults += $batchResults
        
        # Add delay between batches
        if ($batchNumber -lt [Math]::Ceiling($repositories.Count / $BatchSize)) {
            Write-Log "Waiting 30 seconds before next batch..."
            Start-Sleep -Seconds 30
        }
        
        $batchNumber++
    }
    
    # Generate security policy file
    New-SecurityPolicy -OutputPath $logsDir
    
    # Generate final report
    $securityReport = Generate-SecurityReport -Results $allResults
    
    # Display summary
    Write-Log "=== Security Configuration Summary ===" "INFO"
    Write-Log "Total Repositories: $($securityReport.TotalRepositories)" "INFO"
    Write-Log "Branch Protection Configured: $($securityReport.BranchProtectionConfigured)" "INFO"
    Write-Log "Advanced Security Enabled: $($securityReport.AdvancedSecurityEnabled)" "INFO"
    Write-Log "Secret Scanning Enabled: $($securityReport.SecretScanningEnabled)" "INFO"
    Write-Log "Dependabot Alerts Enabled: $($securityReport.DependabotAlertsEnabled)" "INFO"
    Write-Log "CodeQL Configured: $($securityReport.CodeQLConfigured)" "INFO"
    Write-Log "Team Permissions Configured: $($securityReport.TeamPermissionsConfigured)" "INFO"
    Write-Log "Success Rate: $($securityReport.SuccessRate)%" "INFO"
    
    if ($securityReport.ErrorsEncountered -gt 0) {
        Write-Log "Errors encountered in $($securityReport.ErrorsEncountered) repositories - review logs for details" "WARNING"
    }
    
    Write-Log "=== Security Configuration Completed ==="
    
    # Return appropriate exit code
    if ($securityReport.SuccessRate -ge 95) {
        exit 0
    }
    elseif ($securityReport.SuccessRate -ge 80) {
        Write-Log "Security configuration completed with warnings" "WARNING"
        exit 1
    }
    else {
        Write-Log "Security configuration completed with significant failures" "ERROR"
        exit 2
    }
    
}
catch {
    Write-Log "Security configuration failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}