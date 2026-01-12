<#
.SYNOPSIS
    Azure DevOps to GitHub Actions Pipeline Conversion Tool
.DESCRIPTION
    This script converts Azure DevOps pipelines to GitHub Actions workflows using
    the GitHub Actions Importer. It supports dry-run conversion, validation,
    and batch processing for enterprise-scale migrations.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER GhOrg
    GitHub target organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER PipelineFile
    Path to pipeline analysis file from 04-audit-pipelines.ps1
.PARAMETER OutputDir
    Directory for converted workflows (default: ./converted-workflows)
.PARAMETER WhatIf
    Show what would be converted without actually converting
.PARAMETER ValidateOnly
    Only validate conversion without creating files
.EXAMPLE
    ./05-convert-pipelines.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -GhOrg "myghorg" -GhToken "gh-pat" -PipelineFile "./reports/pipeline-analysis-*.csv"
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
    [string]$PipelineFile = "./reports/pipeline-analysis-*.csv",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "./converted-workflows",
    
    [Parameter(Mandatory=$false)]
    [string]$TargetDir = "workflows",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory=$false)]
    [switch]$ValidateOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$IncludeHighComplexity,
    
    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 5,
    
    [Parameter(Mandatory=$false)]
    [string]$PriorityFilter = "High"  # High, Medium, Low, All
)

# Set error handling
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Create output directory if it doesn't exist
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $OutputDir "conversion-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
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
        Write-Log "GitHub CLI not found. Please install GitHub CLI." "ERROR"
        throw "GitHub CLI not installed"
    }
    
    # Check if Actions Importer extension is installed
    try {
        $importerExtensions = gh extension list | Where-Object { $_ -match "gh-actions-importer" }
        if (!$importerExtensions) {
            Write-Log "GitHub Actions Importer extension not found. Installing..." "WARNING"
            gh extension install github/gh-actions-importer
        }
        Write-Log "GitHub Actions Importer extension is available"
    }
    catch {
        Write-Log "Error checking Actions Importer extension: $($_.Exception.Message)" "ERROR"
        throw
    }
    
    # Validate pipeline file
    $pipelineFiles = Get-ChildItem $PipelineFile -ErrorAction SilentlyContinue
    if (!$pipelineFiles) {
        Write-Log "Pipeline analysis file not found: $PipelineFile" "ERROR"
        Write-Log "Please run 04-audit-pipelines.ps1 first to create pipeline analysis" "ERROR"
        throw "Pipeline file not found"
    }
    
    Write-Log "Prerequisites validation completed"
}

# Function to load pipeline analysis data
function Get-PipelineData {
    Write-Log "Loading pipeline analysis data..."
    
    try {
        $pipelineFiles = Get-ChildItem $PipelineFile
        $allPipelines = @()
        
        foreach ($file in $pipelineFiles) {
            $pipelines = Import-Csv $file.FullName
            $allPipelines += $pipelines
        }
        
        Write-Log "Loaded $($allPipelines.Count) pipelines from analysis"
        
        # Filter by priority if specified
        if ($PriorityFilter -ne "All") {
            $allPipelines = $allPipelines | Where-Object { $_.Priority -eq $PriorityFilter }
            Write-Log "Filtered to $($allPipelines.Count) pipelines with priority: $PriorityFilter"
        }
        
        # Filter by complexity if not including high complexity
        if (!$IncludeHighComplexity) {
            $allPipelines = $allPipelines | Where-Object { $_.ComplexityLevel -ne "Very High" }
            Write-Log "Filtered to $($allPipelines.Count) pipelines (excluding Very High complexity)"
        }
        
        # Filter out classic pipelines (they need manual redesign)
        $yamlPipelines = $allPipelines | Where-Object { $_.PipelineType -eq "YAML" }
        $classicPipelines = $allPipelines | Where-Object { $_.PipelineType -eq "Classic" }
        
        if ($classicPipelines.Count -gt 0) {
            Write-Log "Warning: $($classicPipelines.Count) classic pipelines will be skipped (require manual conversion)" "WARNING"
        }
        
        return $yamlPipelines
    }
    catch {
        Write-Log "Error loading pipeline data: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Function to convert a single pipeline
function Convert-Pipeline {
    param(
        [PSCustomObject]$Pipeline,
        [string]$ConversionId
    )
    
    $pipelineName = $Pipeline.PipelineName
    $projectName = $Pipeline.ProjectName
    
    Write-Log "Starting conversion for pipeline: $projectName/$pipelineName (ID: $ConversionId)"
    
    try {
        # Set up environment variables
        $env:GITHUB_TOKEN = $GhToken
        $env:AZURE_DEVOPS_ORG = $AdoOrg
        $env:AZURE_DEVOPS_PAT = $AdoPat
        
        # Build conversion command
        $convertArgs = @(
            "actions-importer", "dry-run",
            "azure-devops",
            "--output-dir", $OutputDir,
            "--organization", $AdoOrg,
            "--project", $projectName,
            "--pipeline-id", $Pipeline.PipelineId
        )
        
        if ($ValidateOnly) {
            $convertArgs += "--validate-only"
        }
        
        # Execute conversion
        Write-Log "Executing: gh $($convertArgs -join ' ')"
        
        $output = & gh $convertArgs 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Log "Conversion completed successfully for $pipelineName"
            
            # Find generated workflow file
            $workflowFile = Get-ChildItem -Path $OutputDir -Filter "*.yml" -Recurse | 
                           Where-Object { $_.Name -like "*$pipelineName*" -or $_.Name -like "*$($Pipeline.PipelineId)*" } |
                           Select-Object -First 1
            
            if ($workflowFile) {
                Write-Log "Generated workflow file: $($workflowFile.FullName)"
                
                # Validate the generated workflow
                $validation = Validate-Workflow -WorkflowPath $workflowFile.FullName
                
                return @{
                    Status = "Success"
                    ConversionId = $ConversionId
                    PipelineName = $pipelineName
                    ProjectName = $projectName
                    WorkflowFile = $workflowFile.FullName
                    WorkflowContent = Get-Content $workflowFile.FullName -Raw
                    Validation = $validation
                    ExitCode = $exitCode
                }
            }
            else {
                Write-Log "No workflow file generated for $pipelineName" "WARNING"
                
                return @{
                    Status = "Warning"
                    ConversionId = $ConversionId
                    PipelineName = $pipelineName
                    ProjectName = $projectName
                    Message = "Conversion completed but no workflow file found"
                    ExitCode = $exitCode
                }
            }
        }
        else {
            Write-Log "Conversion failed for $pipelineName with exit code: $exitCode" "ERROR"
            Write-Log "Error output: $($output -join '`n')" "ERROR"
            
            return @{
                Status = "Failed"
                ConversionId = $ConversionId
                PipelineName = $pipelineName
                ProjectName = $projectName
                Message = "Conversion failed with exit code: $exitCode"
                ErrorOutput = $output
                ExitCode = $exitCode
            }
        }
    }
    catch {
        Write-Log "Exception during conversion of ${pipelineName}: $($_.Exception.Message)" "ERROR"
        
        return @{
            Status = "Failed"
            ConversionId = $ConversionId
            PipelineName = $pipelineName
            ProjectName = $projectName
            Message = "Exception: $($_.Exception.Message)"
            ErrorOutput = $_.Exception.Message
        }
    }
}

# Function to validate generated workflow
function Validate-Workflow {
    param([string]$WorkflowPath)
    
    Write-Log "Validating generated workflow: $WorkflowPath"
    
    try {
        $content = Get-Content $WorkflowPath -Raw
        
        $validationResults = @{
            SyntaxValid = $false
            HasTriggers = $false
            HasJobs = $false
            HasSteps = $false
            UsesActions = @()
            Issues = @()
            Warnings = @()
        }
        
        # Basic YAML syntax check
        try {
            $yaml = ConvertFrom-Yaml $content
            $validationResults.SyntaxValid = $true
        }
        catch {
            $validationResults.Issues += "Invalid YAML syntax: $($_.Exception.Message)"
            return $validationResults
        }
        
        # Check for required elements
        if ($content -match "on:") { $validationResults.HasTriggers = $true }
        if ($content -match "jobs:") { $validationResults.HasJobs = $true }
        if ($content -match "steps:") { $validationResults.HasSteps = $true }
        
        # Extract used actions
        $actionMatches = [regex]::Matches($content, "uses:\s*([^\s]+)")
        foreach ($match in $actionMatches) {
            $action = $match.Groups[1].Value
            if ($action -notin $validationResults.UsesActions) {
                $validationResults.UsesActions += $action
            }
        }
        
        # Check for common issues
        if (!$validationResults.HasTriggers) {
            $validationResults.Issues += "No workflow triggers found"
        }
        
        if (!$validationResults.HasJobs) {
            $validationResults.Issues += "No jobs defined"
        }
        
        if (!$validationResults.HasSteps) {
            $validationResults.Warnings += "No steps found in jobs"
        }
        
        # Check for ADO-specific elements that may need attention
        if ($content -match "azure.*devops|ado|dev.azure.com") {
            $validationResults.Warnings += "Contains Azure DevOps references that may need updating"
        }
        
        if ($content -match "task:|script:|powershell:|bash:") {
            $validationResults.Warnings += "Contains ADO task syntax that may need conversion"
        }
        
        # Check for variables that might need secrets
        if ($content -match "\$\(.*\)|\{\{.*\}\}") {
            $validationResults.Warnings += "Contains variables that may need to be converted to secrets"
        }
        
        return $validationResults
    }
    catch {
        Write-Log "Error validating workflow: $($_.Exception.Message)" "WARNING"
        
        return @{
            SyntaxValid = $false
            Issues = @("Validation failed: $($_.Exception.Message)")
        }
    }
}

# Function to process conversion batch
function Process-ConversionBatch {
    param(
        [array]$Batch,
        [int]$BatchNumber
    )
    
    Write-Log "Processing batch $BatchNumber with $($Batch.Count) pipelines"
    
    $results = @()
    
    foreach ($pipeline in $Batch) {
        $conversionId = [Guid]::NewGuid().ToString()
        
        if ($PSCmdlet.ShouldProcess("$($pipeline.ProjectName)/$($pipeline.PipelineName)", "Convert pipeline")) {
            $result = Convert-Pipeline -Pipeline $pipeline -ConversionId $conversionId
            $results += $result
            
            # Add delay between conversions to avoid rate limits
            Start-Sleep -Seconds 5
        }
        else {
            # WhatIf mode
            $results += [PSCustomObject]@{
                PipelineName = $pipeline.PipelineName
                ProjectName = $pipeline.ProjectName
                Status = "WhatIf"
                ConversionId = $conversionId
                Message = "Would convert pipeline"
            }
        }
    }
    
    return $results
}

# Function to generate conversion report
function Generate-ConversionReport {
    param([array]$Results)
    
    Write-Log "Generating conversion report..."
    
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
    $reportFile = Join-Path $OutputDir "conversion-report-$timestamp.json"
    $csvFile = Join-Path $OutputDir "conversion-report-$timestamp.csv"
    
    # Export to CSV
    $Results | Select-Object PipelineName, ProjectName, Status, @{Name="HasValidationIssues";Expression={$_.Validation.Issues.Count -gt 0}}, @{Name="HasWarnings";Expression={$_.Validation.Warnings.Count -gt 0}} | 
               Export-Csv -Path $csvFile -NoTypeInformation
    Write-Log "Conversion report CSV saved: $csvFile"
    
    # Generate summary statistics
    $summary = [PSCustomObject]@{
        ConversionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AdoOrganization = $AdoOrg
        GitHubOrganization = $GhOrg
        TotalPipelines = $Results.Count
        SuccessfulConversions = ($Results | Where-Object { $_.Status -eq "Success" }).Count
        FailedConversions = ($Results | Where-Object { $_.Status -eq "Failed" }).Count
        WarningConversions = ($Results | Where-Object { $_.Status -eq "Warning" }).Count
        WhatIfConversions = ($Results | Where-Object { $_.Status -eq "WhatIf" }).Count
        SuccessRate = [Math]::Round((($Results | Where-Object { $_.Status -eq "Success" }).Count / $Results.Count) * 100, 2)
        ConversionsWithIssues = ($Results | Where-Object { $_.Validation -and $_.Validation.Issues.Count -gt 0 }).Count
        ConversionsWithWarnings = ($Results | Where-Object { $_.Validation -and $_.Validation.Warnings.Count -gt 0 }).Count
        Results = $Results
    }
    
    # Export JSON report
    $summary | ConvertTo-Json -Depth 10 | Out-File $reportFile
    Write-Log "Conversion report saved: $reportFile"
    
    return $summary
}

# Function to create workflow organization structure
function Organize-Workflows {
    Write-Log "Organizing converted workflows..."
    
    try {
        # Create target directory structure
        $targetPath = Join-Path $OutputDir $TargetDir
        if (!(Test-Path $targetPath)) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        }
        
        # Find all generated workflow files
        $workflowFiles = Get-ChildItem -Path $OutputDir -Filter "*.yml" -Recurse
        
        foreach ($file in $workflowFiles) {
            # Create project-specific subdirectory
            $projectDir = Join-Path $targetPath $file.Directory.Name
            if (!(Test-Path $projectDir)) {
                New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
            }
            
            # Move and rename file to standard naming convention
            $newName = $file.Name -replace '[^a-zA-Z0-9-_]', '-'  # Sanitize filename
            $newPath = Join-Path $projectDir $newName
            
            Move-Item -Path $file.FullName -Destination $newPath -Force
            Write-Log "Organized workflow: $newPath"
        }
        
        Write-Log "Workflow organization completed"
    }
    catch {
        Write-Log "Error organizing workflows: $($_.Exception.Message)" "WARNING"
    }
}

# Function to generate migration guide
function Generate-MigrationGuide {
    param([array]$Results)
    
    Write-Log "Generating migration guide..."
    
    $guideFile = Join-Path $OutputDir "MIGRATION-GUIDE.md"
    
    $guideContent = @"
# GitHub Actions Migration Guide

Generated on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

## Conversion Summary

- **Total Pipelines Processed**: $($Results.Count)
- **Successful Conversions**: $(($Results | Where-Object { $_.Status -eq "Success" }).Count)
- **Conversions with Issues**: $(($Results | Where-Object { $_.Validation -and $_.Validation.Issues.Count -gt 0 }).Count)
- **Conversions with Warnings**: $(($Results | Where-Object { $_.Validation -and $_.Validation.Warnings.Count -gt 0 }).Count)

## Next Steps

### 1. Review Converted Workflows
Check the converted workflows in the `$TargetDir` directory for:
- Correct triggers and events
- Proper job and step definitions
- Appropriate action usage

### 2. Handle Common Issues

#### Variables and Secrets
- Review variables that may need to be converted to GitHub secrets
- Update environment-specific values
- Ensure sensitive data is properly secured

#### Action Dependencies
- Verify all used actions are available in GitHub Marketplace
- Update action versions to latest stable releases
- Replace any Azure DevOps-specific tasks with GitHub Actions equivalents

#### Environment Configuration
- Set up required GitHub environments for deployment workflows
- Configure environment protection rules
- Add required secrets to environments

### 3. Testing Strategy

1. **Dry Run Testing**: Test workflows in a non-production repository
2. **Parallel Testing**: Run both ADO and GitHub Actions pipelines in parallel
3. **Gradual Migration**: Start with less critical pipelines
4. **Rollback Plan**: Maintain ability to revert to ADO if needed

### 4. Manual Review Required

The following pipelines require special attention:

"@

    # Add specific recommendations for pipelines with issues
    $problematicPipelines = $Results | Where-Object { $_.Validation -and ($_.Validation.Issues.Count -gt 0 -or $_.Validation.Warnings.Count -gt 0) }
    
    if ($problematicPipelines) {
        foreach ($pipeline in $problematicPipelines | Select-Object -First 10) {
            $guideContent += @"

#### $($pipeline.PipelineName) (Project: $($pipeline.ProjectName))
- **Status**: $($pipeline.Status)
- **Issues**: $(if ($pipeline.Validation.Issues) { $pipeline.Validation.Issues -join ", " } else { "None" })
- **Warnings**: $(if ($pipeline.Validation.Warnings) { $pipeline.Validation.Warnings -join ", " } else { "None" })

"@
        }
    }
    
    $guideContent += @"

## Common Conversion Patterns

### Azure DevOps Tasks → GitHub Actions
- `VSBuild@1` → `microsoft/setup-msbuild` + build commands
- `VSTest@2` → `actions/setup-dotnet` + `dotnet test`
- `AzureWebApp@1` → `azure/webapps-deploy`
- `CmdLine@2` → `run:` steps
- `PowerShell@2` → `run: pwsh:` steps

### Variables and Secrets
- ADO variables → GitHub secrets or environment variables
- ADO variable groups → GitHub environments with secrets
- Build variables → GitHub context variables

### Triggers and Conditions
- CI triggers → `on: push:` and `on: pull_request:`
- Scheduled triggers → `on: schedule:`
- Branch conditions → `if:` conditions with `github.ref`

## Support and Resources

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [GitHub Actions Importer Documentation](https://docs.github.com/en/actions/migrating-to-github-actions/automated-migrations/migrating-to-github-actions-with-github-actions-importer)
- [Azure DevOps to GitHub Actions Migration Guide](https://docs.microsoft.com/en-us/azure/devops/pipelines/migrate)

"@

    $guideContent | Out-File $guideFile -Encoding UTF8
    Write-Log "Migration guide saved: $guideFile"
}

# Main execution
try {
    Write-Log "=== Pipeline Conversion Started ==="
    Write-Log "Source: $AdoOrg -> Target: $GhOrg"
    Write-Log "Validate Only: $ValidateOnly, WhatIf: $WhatIf"
    
    # Validate prerequisites
    Test-Prerequisites
    
    # Load pipeline data
    $pipelines = Get-PipelineData
    
    Write-Log "Converting $($pipelines.Count) pipelines..."
    
    # Process in batches
    $allResults = @()
    $batchNumber = 1
    
    for ($i = 0; $i -lt $pipelines.Count; $i += $BatchSize) {
        $batch = $pipelines[$i..[Math]::Min($i + $BatchSize - 1, $pipelines.Count - 1)]
        
        Write-Log "Starting batch $batchNumber of $([Math]::Ceiling($pipelines.Count / $BatchSize))"
        
        # Process batch
        $batchResults = Process-ConversionBatch -Batch $batch -BatchNumber $batchNumber
        $allResults += $batchResults
        
        # Add delay between batches
        if ($batchNumber -lt [Math]::Ceiling($pipelines.Count / $BatchSize)) {
            Write-Log "Waiting 30 seconds before next batch..."
            Start-Sleep -Seconds 30
        }
        
        $batchNumber++
    }
    
    # Organize converted workflows
    if (!$ValidateOnly -and !$WhatIf) {
        Organize-Workflows
    }
    
    # Generate reports
    $conversionReport = Generate-ConversionReport -Results $allResults
    Generate-MigrationGuide -Results $allResults
    
    # Display summary
    Write-Log "=== Conversion Summary ===" "INFO"
    Write-Log "Total Pipelines: $($conversionReport.TotalPipelines)" "INFO"
    Write-Log "Successful Conversions: $($conversionReport.SuccessfulConversions)" "INFO"
    Write-Log "Failed Conversions: $($conversionReport.FailedConversions)" "INFO"
    Write-Log "Success Rate: $($conversionReport.SuccessRate)%" "INFO"
    Write-Log "Conversions with Issues: $($conversionReport.ConversionsWithIssues)" "INFO"
    Write-Log "Conversions with Warnings: $($conversionReport.ConversionsWithWarnings)" "INFO"
    
    if ($conversionReport.FailedConversions -gt 0) {
        Write-Log "Some conversions failed - review logs for details" "WARNING"
    }
    
    Write-Log "=== Pipeline Conversion Completed ==="
    
    # Return appropriate exit code
    if ($conversionReport.SuccessRate -ge 90) {
        exit 0
    }
    elseif ($conversionReport.SuccessRate -ge 70) {
        Write-Log "Conversion completed with warnings" "WARNING"
        exit 1
    }
    else {
        Write-Log "Conversion completed with significant failures" "ERROR"
        exit 2
    }
    
}
catch {
    Write-Log "Conversion failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}