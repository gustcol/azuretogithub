<#
.SYNOPSIS
    Azure DevOps Pipeline Analysis and Assessment Tool
.DESCRIPTION
    This script analyzes Azure DevOps pipelines and assesses their complexity for migration
    to GitHub Actions. It uses the GitHub Actions Importer to provide detailed reports
    on pipeline structure, tasks, and conversion feasibility.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER GhOrg
    GitHub organization name (for target assessment)
.PARAMETER OutputDir
    Directory for analysis reports (default: ./reports)
.PARAMETER IncludeClassic
    Include classic release pipelines in analysis (default: $true)
.PARAMETER IncludeYaml
    Include YAML pipelines in analysis (default: $true)
.EXAMPLE
    ./04-audit-pipelines.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -GhOrg "myghorg"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdoOrg,
    
    [Parameter(Mandatory=$true)]
    [string]$AdoPat,
    
    [Parameter(Mandatory=$true)]
    [string]$GhOrg,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "./reports",
    
    [Parameter(Mandatory=$false)]
    [bool]$IncludeClassic = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$IncludeYaml = $true,
    
    [Parameter(Mandatory=$false)]
    [string]$PipelineFilter = ""
)

# Set error handling
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Create output directory if it doesn't exist
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $OutputDir "pipeline-audit-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
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
    
    Write-Log "Prerequisites validation completed"
}

# Function to get Azure DevOps pipelines
function Get-AdoPipelines {
    Write-Log "Fetching Azure DevOps pipelines..."
    
    $adoBaseUrl = "https://dev.azure.com/$AdoOrg"
    $apiVersion = "7.1-preview.1"
    
    $authHeader = @{
        "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
        "Content-Type" = "application/json"
    }
    
    try {
        # Get all projects
        $projectsUrl = "$adoBaseUrl/_apis/projects?api-version=$apiVersion"
        $projects = Invoke-RestMethod -Uri $projectsUrl -Method GET -Headers $authHeader
        
        $allPipelines = @()
        
        foreach ($project in $projects.value) {
            Write-Log "Processing project: $($project.name)"
            
            # Get build definitions (YAML pipelines)
            if ($IncludeYaml) {
                try {
                    $buildUrl = "$adoBaseUrl/$($project.name)/_apis/build/definitions?api-version=$apiVersion"
                    $buildPipelines = Invoke-RestMethod -Uri $buildUrl -Method GET -Headers $authHeader
                    
                    foreach ($pipeline in $buildPipelines.value) {
                        $allPipelines += [PSCustomObject]@{
                            ProjectName = $project.name
                            PipelineId = $pipeline.id
                            PipelineName = $pipeline.name
                            PipelineType = "YAML"
                            Path = $pipeline.path
                            CreatedDate = $pipeline.createdDate
                            ModifiedDate = $pipeline.modifiedDate
                            Repository = $pipeline.repository.name
                            RepositoryType = $pipeline.repository.type
                            QueueStatus = $pipeline.queueStatus
                            Url = $pipeline.url
                            Definition = $pipeline
                        }
                    }
                }
                catch {
                    Write-Log "Error fetching build pipelines for project $($project.name): $($_.Exception.Message)" "WARNING"
                }
            }
            
            # Get release definitions (classic release pipelines)
            if ($IncludeClassic) {
                try {
                    $releaseUrl = "$adoBaseUrl/$($project.name)/_apis/release/definitions?api-version=$apiVersion"
                    $releasePipelines = Invoke-RestMethod -Uri $releaseUrl -Method GET -Headers $authHeader
                    
                    foreach ($pipeline in $releasePipelines.value) {
                        $allPipelines += [PSCustomObject]@{
                            ProjectName = $project.name
                            PipelineId = $pipeline.id
                            PipelineName = $pipeline.name
                            PipelineType = "Classic"
                            Path = $pipeline.path
                            CreatedDate = $pipeline.createdDate
                            ModifiedDate = $pipeline.modifiedOn
                            Repository = $null
                            RepositoryType = $null
                            QueueStatus = $null
                            Url = $pipeline.url
                            Definition = $pipeline
                        }
                    }
                }
                catch {
                    Write-Log "Error fetching release pipelines for project $($project.name): $($_.Exception.Message)" "WARNING"
                }
            }
        }
        
        Write-Log "Found $($allPipelines.Count) total pipelines"
        
        # Apply filter if specified
        if ($PipelineFilter) {
            $allPipelines = $allPipelines | Where-Object { 
                $_.PipelineName -like "*$PipelineFilter*" -or 
                $_.ProjectName -like "*$PipelineFilter*" 
            }
            Write-Log "Filtered to $($allPipelines.Count) pipelines matching filter: $PipelineFilter"
        }
        
        return $allPipelines
    }
    catch {
        Write-Log "Error fetching pipelines from ADO: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Function to analyze pipeline complexity
function Analyze-PipelineComplexity {
    param([PSCustomObject]$Pipeline)
    
    Write-Log "Analyzing pipeline: $($Pipeline.PipelineName) (Type: $($Pipeline.PipelineType))"
    
    $complexityScore = 0
    $issues = @()
    $recommendations = @()
    
    try {
        if ($Pipeline.PipelineType -eq "YAML") {
            # Get detailed YAML definition
            $adoBaseUrl = "https://dev.azure.com/$AdoOrg"
            $apiVersion = "7.1-preview.1"
            
            $authHeader = @{
                "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
                "Content-Type" = "application/json"
            }
            
            $definitionUrl = "$adoBaseUrl/$($Pipeline.ProjectName)/_apis/build/definitions/$($Pipeline.PipelineId)?api-version=$apiVersion"
            $definition = Invoke-RestMethod -Uri $definitionUrl -Method GET -Headers $authHeader
            
            # Analyze YAML content
            if ($definition.process.yamlFilename) {
                $yamlContent = $definition.process.yamlFilename
                
                # Complexity factors
                $stepCount = 0
                $taskCount = 0
                $variableCount = 0
                $conditionCount = 0
                $templateCount = 0
                
                # Count various elements (simplified analysis)
                if ($definition.process) {
                    $stepCount = $definition.process.phases.Count
                    foreach ($phase in $definition.process.phases) {
                        $taskCount += $phase.steps.Count
                        foreach ($step in $phase.steps) {
                            if ($step.condition) { $conditionCount++ }
                        }
                    }
                }
                
                # Calculate complexity score
                $complexityScore = ($stepCount * 2) + ($taskCount * 1) + ($variableCount * 0.5) + ($conditionCount * 3) + ($templateCount * 4)
                
                # Identify potential issues
                if ($taskCount -gt 20) {
                    $issues += "High task count ($taskCount) - consider breaking into smaller workflows"
                }
                
                if ($conditionCount -gt 5) {
                    $issues += "Complex conditional logic - review GitHub Actions equivalents"
                }
                
                if ($definition.process.phases.Count -gt 3) {
                    $issues += "Multiple phases detected - may need matrix strategy in GitHub Actions"
                }
                
                # Recommendations
                $recommendations += "Convert to GitHub Actions workflow"
                if ($stepCount -gt 1) {
                    $recommendations += "Consider using matrix strategy for parallel jobs"
                }
            }
        }
        else {
            # Classic pipeline analysis
            $complexityScore = 15  # Base score for classic pipelines
            
            # Get release definition details
            $adoBaseUrl = "https://dev.azure.com/$AdoOrg"
            $apiVersion = "7.1-preview.1"
            
            $authHeader = @{
                "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
                "Content-Type" = "application/json"
            }
            
            $definitionUrl = "$adoBaseUrl/$($Pipeline.ProjectName)/_apis/release/definitions/$($Pipeline.PipelineId)?api-version=$apiVersion"
            $definition = Invoke-RestMethod -Uri $definitionUrl -Method GET -Headers $authHeader
            
            if ($definition.environments) {
                $environmentCount = $definition.environments.Count
                $complexityScore += $environmentCount * 5
                
                foreach ($environment in $definition.environments) {
                    if ($environment.deployPhases) {
                        $complexityScore += $environment.deployPhases.Count * 3
                    }
                }
            }
            
            $issues += "Classic release pipeline - requires complete redesign for GitHub Actions"
            $recommendations += "Design new deployment workflow using GitHub Actions"
            $recommendations += "Consider using environments and deployment protection rules"
        }
        
        return [PSCustomObject]@{
            PipelineName = $Pipeline.PipelineName
            ProjectName = $Pipeline.ProjectName
            PipelineType = $Pipeline.PipelineType
            ComplexityScore = [Math]::Round($complexityScore, 1)
            ComplexityLevel = Get-ComplexityLevel -Score $complexityScore
            Issues = $issues
            Recommendations = $recommendations
            LastModified = $Pipeline.ModifiedDate
            CreatedDate = $Pipeline.CreatedDate
        }
    }
    catch {
        Write-Log "Error analyzing pipeline $($Pipeline.PipelineName): $($_.Exception.Message)" "WARNING"
        
        return [PSCustomObject]@{
            PipelineName = $Pipeline.PipelineName
            ProjectName = $Pipeline.ProjectName
            PipelineType = $Pipeline.PipelineType
            ComplexityScore = 0
            ComplexityLevel = "Unknown"
            Issues = @("Analysis failed: $($_.Exception.Message)")
            Recommendations = @("Manual review required")
            LastModified = $Pipeline.ModifiedDate
            CreatedDate = $Pipeline.CreatedDate
        }
    }
}

# Function to determine complexity level
function Get-ComplexityLevel {
    param([double]$Score)
    
    if ($Score -le 10) { return "Low" }
    elseif ($Score -le 25) { return "Medium" }
    elseif ($Score -le 50) { return "High" }
    else { return "Very High" }
}

# Function to run GitHub Actions Importer audit
function Invoke-ActionsImporterAudit {
    param([PSCustomObject]$Pipeline)
    
    Write-Log "Running Actions Importer audit for: $($Pipeline.PipelineName)"
    
    try {
        # Set up environment variables
        $env:GITHUB_TOKEN = $GhToken
        $env:AZURE_DEVOPS_ORG = $AdoOrg
        $env:AZURE_DEVOPS_PAT = $AdoPat
        
        # Build audit command
        $auditArgs = @(
            "actions-importer", "audit",
            "azure-devops",
            "--output-dir", $OutputDir,
            "--organization", $AdoOrg,
            "--project", $Pipeline.ProjectName
        )
        
        if ($Pipeline.PipelineType -eq "YAML") {
            $auditArgs += "--pipeline-id"
            $auditArgs += $Pipeline.PipelineId
        }
        
        # Execute audit
        Write-Log "Executing: gh $($auditArgs -join ' ')"
        $output = & gh $auditArgs 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Log "Actions Importer audit completed successfully for $($Pipeline.PipelineName)"
            
            # Parse audit results
            $auditFile = Join-Path $OutputDir "audit-summary.md"
            if (Test-Path $auditFile) {
                $auditContent = Get-Content $auditFile -Raw
                return @{
                    Status = "Success"
                    AuditFile = $auditFile
                    AuditContent = $auditContent
                    ExitCode = $exitCode
                }
            }
        }
        else {
            Write-Log "Actions Importer audit failed for $($Pipeline.PipelineName) with exit code: $exitCode" "WARNING"
            Write-Log "Error output: $($output -join '`n')" "WARNING"
        }
        
        return @{
            Status = "Failed"
            ExitCode = $exitCode
            ErrorOutput = $output
        }
    }
    catch {
        Write-Log "Exception during Actions Importer audit: $($_.Exception.Message)" "WARNING"
        
        return @{
            Status = "Failed"
            Message = "Exception: $($_.Exception.Message)"
        }
    }
}

# Function to generate comprehensive pipeline report
function Generate-PipelineReport {
    param(
        [array]$Pipelines,
        [array]$AnalysisResults,
        [array]$AuditResults
    )
    
    Write-Log "Generating comprehensive pipeline report..."
    
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmm"
    $reportFile = Join-Path $OutputDir "pipeline-analysis-$timestamp.json"
    $csvFile = Join-Path $OutputDir "pipeline-analysis-$timestamp.csv"
    
    # Combine all analysis results
    $comprehensiveResults = @()
    
    for ($i = 0; $i -lt $Pipelines.Count; $i++) {
        $pipeline = $Pipelines[$i]
        $analysis = $AnalysisResults[$i]
        $audit = $AuditResults[$i]
        
        $result = [PSCustomObject]@{
            ProjectName = $pipeline.ProjectName
            PipelineName = $pipeline.PipelineName
            PipelineType = $pipeline.PipelineType
            PipelineId = $pipeline.PipelineId
            ComplexityScore = $analysis.ComplexityScore
            ComplexityLevel = $analysis.ComplexityLevel
            Issues = ($analysis.Issues -join "; ")
            Recommendations = ($analysis.Recommendations -join "; ")
            AuditStatus = $audit.Status
            LastModified = $pipeline.ModifiedDate
            CreatedDate = $pipeline.CreatedDate
            MigrationEffort = Get-MigrationEffortEstimate -ComplexityScore $analysis.ComplexityScore -PipelineType $pipeline.PipelineType
            Priority = Get-MigrationPriority -ComplexityScore $analysis.ComplexityScore -LastModified $pipeline.ModifiedDate
        }
        
        $comprehensiveResults += $result
    }
    
    # Export to CSV
    $comprehensiveResults | Export-Csv -Path $csvFile -NoTypeInformation
    Write-Log "Pipeline analysis CSV saved: $csvFile"
    
    # Generate summary statistics
    $summary = [PSCustomObject]@{
        AnalysisDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AdoOrganization = $AdoOrg
        GitHubOrganization = $GhOrg
        TotalPipelines = $Pipelines.Count
        YamlPipelines = ($Pipelines | Where-Object { $_.PipelineType -eq "YAML" }).Count
        ClassicPipelines = ($Pipelines | Where-Object { $_.PipelineType -eq "Classic" }).Count
        LowComplexity = ($AnalysisResults | Where-Object { $_.ComplexityLevel -eq "Low" }).Count
        MediumComplexity = ($AnalysisResults | Where-Object { $_.ComplexityLevel -eq "Medium" }).Count
        HighComplexity = ($AnalysisResults | Where-Object { $_.ComplexityLevel -eq "High" }).Count
        VeryHighComplexity = ($AnalysisResults | Where-Object { $_.ComplexityLevel -eq "Very High" }).Count
        SuccessfulAudits = ($AuditResults | Where-Object { $_.Status -eq "Success" }).Count
        FailedAudits = ($AuditResults | Where-Object { $_.Status -eq "Failed" }).Count
        Pipelines = $comprehensiveResults
    }
    
    # Export JSON report
    $summary | ConvertTo-Json -Depth 10 | Out-File $reportFile
    Write-Log "Pipeline analysis report saved: $reportFile"
    
    return $summary
}

# Function to estimate migration effort
function Get-MigrationEffortEstimate {
    param(
        [double]$ComplexityScore,
        [string]$PipelineType
    )
    
    $baseEffort = if ($PipelineType -eq "Classic") { 16 } else { 8 }  # hours
    
    if ($ComplexityScore -le 10) { return $baseEffort }
    elseif ($ComplexityScore -le 25) { return $baseEffort + 8 }
    elseif ($ComplexityScore -le 50) { return $baseEffort + 16 }
    else { return $baseEffort + 24 }
}

# Function to determine migration priority
function Get-MigrationPriority {
    param(
        [double]$ComplexityScore,
        [datetime]$LastModified
    )
    
    $daysSinceModified = (Get-Date) - $LastModified
    
    if ($daysSinceModified.Days -gt 365) { return "Low" }
    elseif ($ComplexityScore -gt 50) { return "Low" }
    elseif ($ComplexityScore -le 25) { return "High" }
    else { return "Medium" }
}

# Main execution
try {
    Write-Log "=== Pipeline Analysis and Audit Started ==="
    Write-Log "Organization: $AdoOrg"
    
    # Validate prerequisites
    Test-Prerequisites
    
    # Get all pipelines
    $pipelines = Get-AdoPipelines
    
    Write-Log "Analyzing $($pipelines.Count) pipelines..."
    
    # Analyze each pipeline
    $analysisResults = @()
    $auditResults = @()
    
    foreach ($pipeline in $pipelines) {
        Write-Log "Processing pipeline: $($pipeline.PipelineName)"
        
        # Perform complexity analysis
        $analysis = Analyze-PipelineComplexity -Pipeline $pipeline
        $analysisResults += $analysis
        
        # Run Actions Importer audit
        $audit = Invoke-ActionsImporterAudit -Pipeline $pipeline
        $auditResults += $audit
        
        # Add delay to avoid rate limits
        Start-Sleep -Seconds 2
    }
    
    # Generate comprehensive report
    $report = Generate-PipelineReport -Pipelines $pipelines -AnalysisResults $analysisResults -AuditResults $auditResults
    
    # Display summary
    Write-Log "=== Pipeline Analysis Summary ===" "INFO"
    Write-Log "Total Pipelines: $($report.TotalPipelines)" "INFO"
    Write-Log "YAML Pipelines: $($report.YamlPipelines)" "INFO"
    Write-Log "Classic Pipelines: $($report.ClassicPipelines)" "INFO"
    Write-Log "Low Complexity: $($report.LowComplexity)" "INFO"
    Write-Log "Medium Complexity: $($report.MediumComplexity)" "INFO"
    Write-Log "High Complexity: $($report.HighComplexity)" "INFO"
    Write-Log "Very High Complexity: $($report.VeryHighComplexity)" "INFO"
    Write-Log "Successful Audits: $($report.SuccessfulAudits)" "INFO"
    Write-Log "Failed Audits: $($report.FailedAudits)" "INFO"
    
    # Provide recommendations
    Write-Log "=== Migration Recommendations ===" "INFO"
    
    $highPriorityPipelines = $report.Pipelines | Where-Object { $_.Priority -eq "High" }
    if ($highPriorityPipelines) {
        Write-Log "High Priority Pipelines (start with these):" "INFO"
        foreach ($pipeline in $highPriorityPipelines | Select-Object -First 5) {
            Write-Log "  - $($pipeline.ProjectName)/$($pipeline.PipelineName) (Complexity: $($pipeline.ComplexityLevel))" "INFO"
        }
    }
    
    $classicPipelines = $report.Pipelines | Where-Object { $_.PipelineType -eq "Classic" }
    if ($classicPipelines) {
        Write-Log "Classic Pipelines (require complete redesign):" "WARNING"
        Write-Log "  Count: $($classicPipelines.Count) pipelines need complete workflow redesign" "WARNING"
    }
    
    Write-Log "=== Pipeline Analysis Completed Successfully ==="
    
}
catch {
    Write-Log "Pipeline analysis failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}