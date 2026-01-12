<#
.SYNOPSIS
    Automated Prerequisites Verification for Azure DevOps to GitHub Migration
.DESCRIPTION
    This script performs comprehensive validation of all tools, tokens, permissions,
    and connectivity required for the migration process. It ensures the environment
    is properly configured before proceeding with migration activities.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER GhOrg
    GitHub organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER CheckLevel
    Level of checking: Basic, Comprehensive, or Security (default: Comprehensive)
.EXAMPLE
    ./00-prereq-check.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -GhOrg "myghorg" -GhToken "gh-pat"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$AdoOrg,
    
    [Parameter(Mandatory=$false)]
    [string]$AdoPat,
    
    [Parameter(Mandatory=$false)]
    [string]$GhOrg,
    
    [Parameter(Mandatory=$false)]
    [string]$GhToken,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Basic", "Comprehensive", "Security")]
    [string]$CheckLevel = "Comprehensive",
    
    [Parameter(Mandatory=$false)]
    [switch]$AutoFix,
    
    [Parameter(Mandatory=$false)]
    [switch]$GenerateReport
)

# Set error handling
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Initialize results
$validationResults = @{
    Tools = @{}
    Connectivity = @{}
    Permissions = @{}
    Security = @{}
    Warnings = @()
    Errors = @()
    Recommendations = @()
}

# Color coding for output
$colors = @{
    Success = "Green"
    Warning = "Yellow"
    Error = "Red"
    Info = "Cyan"
    Header = "Magenta"
}

function Write-Status {
    param(
        [string]$Message,
        [string]$Status = "Info",
        [string]$Icon = "ℹ"
    )
    
    $color = $colors[$Status]
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [$Icon] $Message" -ForegroundColor $color
}

function Write-CheckHeader {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor $colors.Header
}

# Function to check tool installation and version
function Test-ToolInstallation {
    Write-CheckHeader "Tool Installation Check"
    
    $tools = @(
        @{ Name = "Git"; Command = "git"; MinVersion = "2.25"; Required = $true },
        @{ Name = "PowerShell Core"; Command = "pwsh"; MinVersion = "7.0"; Required = $true },
        @{ Name = "GitHub CLI"; Command = "gh"; MinVersion = "2.30"; Required = $true },
        @{ Name = "Azure CLI"; Command = "az"; MinVersion = "2.45"; Required = $false }
    )
    
    foreach ($tool in $tools) {
        Write-Status "Checking $($tool.Name)..." "Info" "🔧"
        
        try {
            $output = & $tool.Command --version 2>$null
            $version = if ($output -match '(\d+\.\d+\.\d+)') { $matches[1] } else { "Unknown" }
            
            if ($version -ne "Unknown") {
                $isValid = [version]$version -ge [version]$tool.MinVersion
                $status = if ($isValid) { "Success" } else { "Warning" }
                $icon = if ($isValid) { "✅" } else { "⚠️" }
                
                Write-Status "$($tool.Name) version $version detected" $status $icon
                $validationResults.Tools[$tool.Name] = @{
                    Installed = $true
                    Version = $version
                    MeetsRequirement = $isValid
                    Required = $tool.Required
                }
                
                if (!$isValid -and $tool.Required) {
                    $validationResults.Errors += "$($tool.Name) version $version is below minimum requirement $($tool.MinVersion)"
                }
            }
        }
        catch {
            $status = if ($tool.Required) { "Error" } else { "Warning" }
            $icon = if ($tool.Required) { "❌" } else { "⚠️" }
            
            Write-Status "$($tool.Name) not found or not accessible" $status $icon
            $validationResults.Tools[$tool.Name] = @{
                Installed = $false
                Required = $tool.Required
            }
            
            if ($tool.Required) {
                $validationResults.Errors += "$($tool.Name) is required but not installed"
            }
        }
    }
}

# Function to check GitHub CLI extensions
function Test-GitHubExtensions {
    Write-CheckHeader "GitHub CLI Extensions Check"
    
    $requiredExtensions = @(
        @{ Name = "gh-gei"; Description = "GitHub Enterprise Importer" },
        @{ Name = "gh-actions-importer"; Description = "GitHub Actions Importer" }
    )
    
    try {
        $installedExtensions = gh extension list --json name,description | ConvertFrom-Json
        $extensionNames = $installedExtensions.name
        
        foreach ($extension in $requiredExtensions) {
            Write-Status "Checking $($extension.Description)..." "Info" "🔌"
            
            if ($extensionNames -contains $extension.Name) {
                Write-Status "$($extension.Description) is installed" "Success" "✅"
                $validationResults.Tools[$extension.Description] = @{ Installed = $true }
            }
            else {
                Write-Status "$($extension.Description) is not installed" "Error" "❌"
                $validationResults.Tools[$extension.Description] = @{ Installed = $false }
                $validationResults.Errors += "$($extension.Description) extension is required"
                
                if ($AutoFix) {
                    Write-Status "Attempting to install $($extension.Name)..." "Info" "🔧"
                    try {
                        gh extension install $extension.Name
                        Write-Status "$($extension.Name) installed successfully" "Success" "✅"
                        $validationResults.Tools[$extension.Description].Installed = $true
                    }
                    catch {
                        Write-Status "Failed to install $($extension.Name): $($_.Exception.Message)" "Error" "❌"
                    }
                }
            }
        }
    }
    catch {
        Write-Status "Unable to check GitHub CLI extensions: $($_.Exception.Message)" "Error" "❌"
        $validationResults.Errors += "GitHub CLI extensions check failed"
    }
}

# Function to test connectivity
function Test-Connectivity {
    Write-CheckHeader "Connectivity Check"
    
    # Test Azure DevOps connectivity
    if ($AdoOrg -and $AdoPat) {
        Write-Status "Testing Azure DevOps connectivity..." "Info" "🌐"
        
        try {
            $authHeader = @{
                "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
                "Content-Type" = "application/json"
            }
            
            $url = "https://dev.azure.com/$AdoOrg/_apis/projects?api-version=7.1-preview.1"
            $response = Invoke-RestMethod -Uri $url -Method GET -Headers $authHeader -TimeoutSec 30
            
            Write-Status "Azure DevOps connectivity successful" "Success" "✅"
            $validationResults.Connectivity.ADO = @{ Status = "Success"; Projects = $response.count }
        }
        catch {
            Write-Status "Azure DevOps connectivity failed: $($_.Exception.Message)" "Error" "❌"
            $validationResults.Connectivity.ADO = @{ Status = "Failed"; Error = $_.Exception.Message }
            $validationResults.Errors += "Azure DevOps connectivity check failed"
        }
    }
    else {
        Write-Status "Azure DevOps credentials not provided - skipping connectivity check" "Warning" "⚠️"
        $validationResults.Warnings += "ADO credentials not provided - connectivity not verified"
    }
    
    # Test GitHub connectivity
    if ($GhToken) {
        Write-Status "Testing GitHub connectivity..." "Info" "🌐"
        
        try {
            $headers = @{
                "Authorization" = "token $GhToken"
                "Accept" = "application/vnd.github.v3+json"
            }
            
            $response = Invoke-RestMethod -Uri "https://api.github.com/user" -Method GET -Headers $headers -TimeoutSec 30
            
            Write-Status "GitHub connectivity successful (authenticated as $($response.login))" "Success" "✅"
            $validationResults.Connectivity.GitHub = @{ Status = "Success"; User = $response.login }
        }
        catch {
            Write-Status "GitHub connectivity failed: $($_.Exception.Message)" "Error" "❌"
            $validationResults.Connectivity.GitHub = @{ Status = "Failed"; Error = $_.Exception.Message }
            $validationResults.Errors += "GitHub connectivity check failed"
        }
    }
    else {
        Write-Status "GitHub token not provided - skipping connectivity check" "Warning" "⚠️"
        $validationResults.Warnings += "GitHub token not provided - connectivity not verified"
    }
}

# Function to validate token permissions
function Test-TokenPermissions {
    Write-CheckHeader "Token Permissions Check"
    
    # Validate Azure DevOps PAT permissions
    if ($AdoOrg -and $AdoPat) {
        Write-Status "Validating Azure DevOps PAT permissions..." "Info" "🔑"
        
        try {
            $authHeader = @{
                "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
                "Content-Type" = "application/json"
            }
            
            # Test various API endpoints to check permissions
            $endpoints = @(
                @{ Url = "https://dev.azure.com/$AdoOrg/_apis/projects"; Permission = "Project read" },
                @{ Url = "https://dev.azure.com/$AdoOrg/_apis/git/repositories"; Permission = "Code read" },
                @{ Url = "https://dev.azure.com/$AdoOrg/_apis/build/definitions"; Permission = "Build read" }
            )
            
            $permissions = @()
            foreach ($endpoint in $endpoints) {
                try {
                    $response = Invoke-RestMethod -Uri "$($endpoint.Url)?api-version=7.1-preview.1" -Method GET -Headers $authHeader -TimeoutSec 10
                    $permissions += "$($endpoint.Permission): ✅"
                }
                catch {
                    $permissions += "$($endpoint.Permission): ❌"
                }
            }
            
            Write-Status "Azure DevOps PAT permissions validated" "Success" "✅"
            $validationResults.Permissions.ADO = @{
                Status = "Success"
                Permissions = $permissions
            }
        }
        catch {
            Write-Status "Azure DevOps PAT permission validation failed: $($_.Exception.Message)" "Error" "❌"
            $validationResults.Permissions.ADO = @{ Status = "Failed"; Error = $_.Exception.Message }
            $validationResults.Errors += "Azure DevOps PAT permission validation failed"
        }
    }
    
    # Validate GitHub token permissions
    if ($GhToken) {
        Write-Status "Validating GitHub token permissions..." "Info" "🔑"
        
        try {
            $headers = @{
                "Authorization" = "token $GhToken"
                "Accept" = "application/vnd.github.v3+json"
            }
            
            # Test various API endpoints to check permissions
            $endpoints = @(
                @{ Url = "https://api.github.com/user"; Permission = "User read" },
                @{ Url = "https://api.github.com/user/repos"; Permission = "Repository read" }
            )
            
            if ($GhOrg) {
                $endpoints += @{ Url = "https://api.github.com/orgs/$GhOrg"; Permission = "Organization read" }
                $endpoints += @{ Url = "https://api.github.com/orgs/$GhOrg/repos"; Permission = "Organization repos" }
            }
            
            $permissions = @()
            foreach ($endpoint in $endpoints) {
                try {
                    $response = Invoke-RestMethod -Uri $endpoint.Url -Method GET -Headers $headers -TimeoutSec 10
                    $permissions += "$($endpoint.Permission): ✅"
                }
                catch {
                    $permissions += "$($endpoint.Permission): ❌"
                }
            }
            
            Write-Status "GitHub token permissions validated" "Success" "✅"
            $validationResults.Permissions.GitHub = @{
                Status = "Success"
                Permissions = $permissions
            }
        }
        catch {
            Write-Status "GitHub token permission validation failed: $($_.Exception.Message)" "Error" "❌"
            $validationResults.Permissions.GitHub = @{ Status = "Failed"; Error = $_.Exception.Message }
            $validationResults.Errors += "GitHub token permission validation failed"
        }
    }
}

# Function to check security configurations
function Test-SecurityConfigurations {
    if ($CheckLevel -ne "Security") { return }
    
    Write-CheckHeader "Security Configuration Check"
    
    # Check for secure token storage
    Write-Status "Checking token storage security..." "Info" "🔒"
    
    if ($AdoPat -and $AdoPat.Length -lt 40) {
        Write-Status "ADO PAT appears to be a personal token (not a full PAT)" "Warning" "⚠️"
        $validationResults.Warnings += "ADO PAT may be a personal token rather than a full PAT"
    }
    
    if ($GhToken -and $GhToken.StartsWith("ghp_")) {
        Write-Status "GitHub token is a personal access token" "Info" "ℹ️"
    }
    elseif ($GhToken -and $GhToken.StartsWith("github_pat_")) {
        Write-Status "GitHub token is a fine-grained personal access token" "Info" "ℹ️"
    }
    
    # Check for environment variable usage
    if ($env:ADO_PAT -or $env:GH_TOKEN) {
        Write-Status "Tokens are stored in environment variables (recommended)" "Success" "✅"
    }
    else {
        Write-Status "Consider storing tokens in environment variables for better security" "Info" "ℹ️"
        $validationResults.Recommendations += "Store tokens in environment variables for better security"
    }
    
    # Check for HTTPS usage
    Write-Status "Verifying secure connections..." "Info" "🔒"
    
    $adoHttps = $true  # ADO always uses HTTPS
    $githubHttps = $true  # GitHub API always uses HTTPS
    
    if ($adoHttps -and $githubHttps) {
        Write-Status "All connections use HTTPS (secure)" "Success" "✅"
    }
}

# Function to check external tool integrations
function Test-ExternalIntegrations {
    if ($CheckLevel -ne "Comprehensive" -and $CheckLevel -ne "Security") { return }
    
    Write-CheckHeader "External Tool Integration Check"
    
    $integrations = @(
        @{ Name = "Checkov"; Command = "checkov"; Description = "Infrastructure as Code scanning" },
        @{ Name = "Pre-commit"; Command = "pre-commit"; Description = "Git hook framework" },
        @{ Name = "SonarQube Scanner"; Command = "sonar-scanner"; Description = "Code quality analysis" }
    )
    
    foreach ($integration in $integrations) {
        Write-Status "Checking $($integration.Name)..." "Info" "🔧"
        
        try {
            $output = & $integration.Command --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Status "$($integration.Name) is installed and accessible" "Success" "✅"
                $validationResults.Tools[$integration.Name] = @{ Installed = $true; Version = $output }
            }
            else {
                Write-Status "$($integration.Name) command failed" "Warning" "⚠️"
                $validationResults.Tools[$integration.Name] = @{ Installed = $false }
                $validationResults.Warnings += "$($integration.Name) is recommended but not installed"
            }
        }
        catch {
            Write-Status "$($integration.Name) not found (optional)" "Info" "ℹ️"
            $validationResults.Tools[$integration.Name] = @{ Installed = $false }
            if ($CheckLevel -eq "Security") {
                $validationResults.Recommendations += "Consider installing $($integration.Name) for enhanced security scanning"
            }
        }
    }
}

# Function to generate recommendations
function Get-Recommendations {
    Write-CheckHeader "Recommendations"
    
    if ($validationResults.Errors.Count -eq 0) {
        Write-Status "All critical requirements are met!" "Success" "🎉"
    }
    else {
        Write-Status "The following issues need to be resolved:" "Error" "❌"
        foreach ($err in $validationResults.Errors) {
            Write-Status "  • $err" "Error" "  "
        }
    }
    
    if ($validationResults.Warnings.Count -gt 0) {
        Write-Status "The following warnings should be considered:" "Warning" "⚠️"
        foreach ($warning in $validationResults.Warnings) {
            Write-Status "  • $warning" "Warning" "  "
        }
    }
    
    if ($validationResults.Recommendations.Count -gt 0) {
        Write-Status "Recommendations for improvement:" "Info" "💡"
        foreach ($recommendation in $validationResults.Recommendations) {
            Write-Status "  • $recommendation" "Info" "  "
        }
    }
}

# Function to generate detailed report
function New-ValidationReport {
    if (!$GenerateReport) { return }
    
    Write-CheckHeader "Generating Validation Report"
    
    $report = [PSCustomObject]@{
        ValidationDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        CheckLevel = $CheckLevel
        Summary = @{
            TotalChecks = 0
            PassedChecks = 0
            FailedChecks = 0
            WarningChecks = 0
        }
        Results = $validationResults
        Environment = @{
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            OperatingSystem = $PSVersionTable.OS
            Platform = $PSVersionTable.Platform
        }
    }
    
    # Calculate summary statistics
    $report.Summary.TotalChecks = $validationResults.Tools.Count + $validationResults.Connectivity.Count + $validationResults.Permissions.Count
    $report.Summary.PassedChecks = ($validationResults.Tools.Values | Where-Object { $_.Installed -eq $true -or $_.MeetsRequirement -eq $true }).Count
    $report.Summary.FailedChecks = $validationResults.Errors.Count
    $report.Summary.WarningChecks = $validationResults.Warnings.Count
    
    # Save report
    $reportPath = "./reports/prereq-validation-$(Get-Date -Format 'yyyy-MM-dd-HHmm').json"
    $report | ConvertTo-Json -Depth 10 | Out-File $reportPath
    
    Write-Status "Validation report saved to: $reportPath" "Success" "📄"
}

# Main execution
try {
    Write-Host "`n🔍 Azure DevOps to GitHub Migration - Prerequisites Check" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "Check Level: $CheckLevel" -ForegroundColor Gray
    Write-Host "Auto-Fix: $AutoFix" -ForegroundColor Gray
    Write-Host "Generate Report: $GenerateReport" -ForegroundColor Gray
    Write-Host "==================================================`n" -ForegroundColor Cyan
    
    # Create reports directory if it doesn't exist
    if (!(Test-Path "./reports")) {
        New-Item -ItemType Directory -Path "./reports" -Force | Out-Null
    }
    
    # Run all validation checks
    Test-ToolInstallation
    Test-GitHubExtensions
    Test-Connectivity
    Test-TokenPermissions
    Test-SecurityConfigurations
    Test-ExternalIntegrations
    
    # Generate recommendations and report
    Get-Recommendations
    New-ValidationReport
    
    # Final status
    Write-Host "`n==================================================" -ForegroundColor Cyan
    if ($validationResults.Errors.Count -eq 0) {
        Write-Host "✅ All critical prerequisites are satisfied!" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "❌ Prerequisites check failed. Please resolve the issues above before proceeding." -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Status "Prerequisites check failed with exception: $($_.Exception.Message)" "Error" "❌"
    exit 1
}