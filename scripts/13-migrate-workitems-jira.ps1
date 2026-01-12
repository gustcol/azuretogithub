<#
.SYNOPSIS
    Azure DevOps Work Items to Jira Migration Tool
.DESCRIPTION
    This script migrates work items (tasks, bugs, user stories, epics) from Azure DevOps
    to Jira Cloud or Jira Data Center. It preserves relationships, attachments, comments,
    and custom fields while following migration best practices.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER AdoProject
    Azure DevOps project name (or comma-separated list)
.PARAMETER JiraUrl
    Jira instance URL (e.g., https://yourcompany.atlassian.net)
.PARAMETER JiraEmail
    Jira user email for authentication
.PARAMETER JiraApiToken
    Jira API token
.PARAMETER JiraProject
    Target Jira project key
.PARAMETER MappingFile
    Path to field mapping configuration file
.PARAMETER BatchSize
    Number of work items to process per batch (default: 50)
.PARAMETER IncludeAttachments
    Include work item attachments (default: $true)
.PARAMETER IncludeComments
    Include work item comments (default: $true)
.PARAMETER IncludeLinks
    Include work item links/relationships (default: $true)
.PARAMETER DryRun
    Preview migration without creating items in Jira
.EXAMPLE
    ./13-migrate-workitems-jira.ps1 -AdoOrg "myorg" -AdoPat "pat" -AdoProject "MyProject" -JiraUrl "https://company.atlassian.net" -JiraEmail "user@company.com" -JiraApiToken "token" -JiraProject "PROJ"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdoOrg,

    [Parameter(Mandatory=$true)]
    [string]$AdoPat,

    [Parameter(Mandatory=$true)]
    [string]$AdoProject,

    [Parameter(Mandatory=$true)]
    [string]$JiraUrl,

    [Parameter(Mandatory=$true)]
    [string]$JiraEmail,

    [Parameter(Mandatory=$true)]
    [string]$JiraApiToken,

    [Parameter(Mandatory=$true)]
    [string]$JiraProject,

    [Parameter(Mandatory=$false)]
    [string]$MappingFile = "./templates/jira-field-mapping.json",

    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 50,

    [Parameter(Mandatory=$false)]
    [bool]$IncludeAttachments = $true,

    [Parameter(Mandatory=$false)]
    [bool]$IncludeComments = $true,

    [Parameter(Mandatory=$false)]
    [bool]$IncludeLinks = $true,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = "./reports",

    [Parameter(Mandatory=$false)]
    [string]$WorkItemTypes = "Epic,Feature,User Story,Task,Bug",

    [Parameter(Mandatory=$false)]
    [string]$AreaPath = "",

    [Parameter(Mandatory=$false)]
    [string]$IterationPath = "",

    [Parameter(Mandatory=$false)]
    [datetime]$ModifiedSince,

    [Parameter(Mandatory=$false)]
    [switch]$ResumeFromLast
)

# Set error handling
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Create output directory
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $OutputDir "jira-migration-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
$migrationStateFile = Join-Path $OutputDir "jira-migration-state.json"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry -ForegroundColor $(switch ($Level) { "ERROR" { "Red" } "WARNING" { "Yellow" } "SUCCESS" { "Green" } default { "White" } })
    Add-Content -Path $logFile -Value $logEntry
}

# API Headers
$adoAuthHeader = @{
    "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
    "Content-Type" = "application/json"
}

$jiraAuthString = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${JiraEmail}:${JiraApiToken}"))
$jiraAuthHeader = @{
    "Authorization" = "Basic $jiraAuthString"
    "Content-Type" = "application/json"
    "Accept" = "application/json"
}

# Default field mapping
$script:FieldMapping = @{
    workItemTypes = @{
        "Epic" = "Epic"
        "Feature" = "Story"
        "User Story" = "Story"
        "Task" = "Task"
        "Bug" = "Bug"
        "Issue" = "Task"
        "Product Backlog Item" = "Story"
    }
    fields = @{
        "System.Title" = "summary"
        "System.Description" = "description"
        "System.State" = "status"
        "System.AssignedTo" = "assignee"
        "Microsoft.VSTS.Common.Priority" = "priority"
        "Microsoft.VSTS.Scheduling.StoryPoints" = "customfield_10016"
        "System.Tags" = "labels"
    }
    states = @{
        "New" = "To Do"
        "Active" = "In Progress"
        "Resolved" = "Done"
        "Closed" = "Done"
        "Removed" = "Done"
    }
    priorities = @{
        "1" = "Highest"
        "2" = "High"
        "3" = "Medium"
        "4" = "Low"
    }
}

# Migration state tracking
$script:MigrationState = @{
    StartTime = Get-Date
    ProcessedItems = 0
    SuccessfulItems = 0
    FailedItems = 0
    SkippedItems = 0
    ItemMapping = @{}
    Errors = @()
}

#region Helper Functions

function Initialize-FieldMapping {
    if (Test-Path $MappingFile) {
        try {
            $customMapping = Get-Content $MappingFile -Raw | ConvertFrom-Json -AsHashtable
            $script:FieldMapping = $customMapping
            Write-Log "Custom field mapping loaded from $MappingFile"
        }
        catch {
            Write-Log "Failed to load custom mapping, using defaults: $($_.Exception.Message)" "WARNING"
        }
    }
    else {
        Write-Log "Using default field mapping"
    }
}

function Invoke-AdoApi {
    param(
        [string]$Url,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$RetryCount = 3
    )

    $attempt = 0
    while ($attempt -lt $RetryCount) {
        try {
            $params = @{
                Uri = $Url
                Method = $Method
                Headers = $adoAuthHeader
                TimeoutSec = 60
            }
            if ($Body) {
                $params.Body = $Body | ConvertTo-Json -Depth 20
            }
            return Invoke-RestMethod @params
        }
        catch {
            $attempt++
            if ($attempt -lt $RetryCount) {
                Write-Log "ADO API call failed (attempt $attempt): $($_.Exception.Message)" "WARNING"
                Start-Sleep -Seconds (2 * $attempt)
            }
            else {
                Write-Log "ADO API call failed after $RetryCount attempts: $Url" "ERROR"
                return $null
            }
        }
    }
}

function Invoke-JiraApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$RetryCount = 3
    )

    $url = "$JiraUrl/rest/api/3/$Endpoint"
    $attempt = 0

    while ($attempt -lt $RetryCount) {
        try {
            $params = @{
                Uri = $url
                Method = $Method
                Headers = $jiraAuthHeader
                TimeoutSec = 60
            }
            if ($Body) {
                $params.Body = $Body | ConvertTo-Json -Depth 20
            }
            return Invoke-RestMethod @params
        }
        catch {
            $attempt++
            if ($attempt -lt $RetryCount) {
                Write-Log "Jira API call failed (attempt $attempt): $($_.Exception.Message)" "WARNING"
                Start-Sleep -Seconds (2 * $attempt)
            }
            else {
                Write-Log "Jira API call failed after $RetryCount attempts: $Endpoint" "ERROR"
                throw $_
            }
        }
    }
}

function Test-JiraConnection {
    Write-Log "Testing Jira connection..."
    try {
        $myself = Invoke-JiraApi -Endpoint "myself"
        Write-Log "Connected to Jira as: $($myself.displayName) ($($myself.emailAddress))" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to connect to Jira: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Get-JiraProjectMetadata {
    Write-Log "Fetching Jira project metadata..."
    try {
        $project = Invoke-JiraApi -Endpoint "project/$JiraProject"
        Write-Log "Target Jira project: $($project.name) ($($project.key))"

        # Get issue types
        $issueTypes = Invoke-JiraApi -Endpoint "issuetype"
        Write-Log "Available issue types: $($issueTypes.name -join ', ')"

        # Get project statuses
        $statuses = Invoke-JiraApi -Endpoint "project/$JiraProject/statuses"

        return @{
            Project = $project
            IssueTypes = $issueTypes
            Statuses = $statuses
        }
    }
    catch {
        Write-Log "Failed to get Jira project metadata: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

#endregion

#region Work Item Functions

function Get-AdoWorkItems {
    param([string]$Project)

    Write-Log "Fetching work items from Azure DevOps project: $Project"

    # Build WIQL query
    $types = ($WorkItemTypes -split ",") | ForEach-Object { "'$($_.Trim())'" }
    $typeFilter = $types -join ","

    $wiql = "SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State] FROM WorkItems WHERE [System.TeamProject] = '$Project' AND [System.WorkItemType] IN ($typeFilter)"

    if ($AreaPath) {
        $wiql += " AND [System.AreaPath] UNDER '$AreaPath'"
    }

    if ($IterationPath) {
        $wiql += " AND [System.IterationPath] UNDER '$IterationPath'"
    }

    if ($ModifiedSince) {
        $dateStr = $ModifiedSince.ToString("yyyy-MM-dd")
        $wiql += " AND [System.ChangedDate] >= '$dateStr'"
    }

    $wiql += " ORDER BY [System.Id]"

    $body = @{ query = $wiql }
    $url = "https://dev.azure.com/$AdoOrg/$Project/_apis/wit/wiql?api-version=7.1-preview.2"

    $result = Invoke-RestMethod -Uri $url -Method POST -Headers $adoAuthHeader -Body ($body | ConvertTo-Json) -ContentType "application/json"

    if ($null -eq $result -or $null -eq $result.workItems) {
        Write-Log "No work items found matching criteria" "WARNING"
        return @()
    }

    Write-Log "Found $($result.workItems.Count) work items"
    return $result.workItems
}

function Get-AdoWorkItemDetails {
    param([int]$WorkItemId, [string]$Project)

    $url = "https://dev.azure.com/$AdoOrg/$Project/_apis/wit/workitems/${WorkItemId}?`$expand=all&api-version=7.1-preview.3"
    return Invoke-AdoApi -Url $url
}

function Get-AdoWorkItemComments {
    param([int]$WorkItemId, [string]$Project)

    $url = "https://dev.azure.com/$AdoOrg/$Project/_apis/wit/workitems/${WorkItemId}/comments?api-version=7.1-preview.3"
    return Invoke-AdoApi -Url $url
}

function Get-AdoWorkItemAttachments {
    param([int]$WorkItemId, [string]$Project)

    $url = "https://dev.azure.com/$AdoOrg/$Project/_apis/wit/workitems/${WorkItemId}?`$expand=relations&api-version=7.1-preview.3"
    $workItem = Invoke-AdoApi -Url $url

    if ($null -eq $workItem -or $null -eq $workItem.relations) {
        return @()
    }

    return $workItem.relations | Where-Object { $_.rel -eq "AttachedFile" }
}

function Convert-AdoToJiraDescription {
    param([string]$HtmlContent)

    if ([string]::IsNullOrEmpty($HtmlContent)) {
        return $null
    }

    # Convert HTML to Atlassian Document Format (ADF)
    # Basic conversion - strip HTML tags for simple text
    $text = $HtmlContent -replace '<br\s*/?>', "`n"
    $text = $text -replace '<p>', ""
    $text = $text -replace '</p>', "`n"
    $text = $text -replace '<[^>]+>', ''
    $text = [System.Web.HttpUtility]::HtmlDecode($text)

    # Return as ADF format
    return @{
        type = "doc"
        version = 1
        content = @(
            @{
                type = "paragraph"
                content = @(
                    @{
                        type = "text"
                        text = $text.Trim()
                    }
                )
            }
        )
    }
}

function Convert-AdoWorkItemToJira {
    param([object]$WorkItem)

    $fields = $WorkItem.fields

    # Map work item type
    $adoType = $fields.'System.WorkItemType'
    $jiraType = $script:FieldMapping.workItemTypes[$adoType]
    if (-not $jiraType) {
        $jiraType = "Task"
        Write-Log "No mapping for type '$adoType', defaulting to 'Task'" "WARNING"
    }

    # Map priority
    $adoPriority = $fields.'Microsoft.VSTS.Common.Priority'
    $jiraPriority = $script:FieldMapping.priorities["$adoPriority"]
    if (-not $jiraPriority) {
        $jiraPriority = "Medium"
    }

    # Build Jira issue
    $jiraIssue = @{
        fields = @{
            project = @{ key = $JiraProject }
            summary = $fields.'System.Title'
            issuetype = @{ name = $jiraType }
        }
    }

    # Add description
    $description = $fields.'System.Description'
    if ($description) {
        $jiraIssue.fields.description = Convert-AdoToJiraDescription -HtmlContent $description
    }

    # Add priority
    $jiraIssue.fields.priority = @{ name = $jiraPriority }

    # Add labels from tags
    $tags = $fields.'System.Tags'
    if ($tags) {
        $labels = ($tags -split ";") | ForEach-Object { $_.Trim() -replace '\s+', '-' }
        $jiraIssue.fields.labels = $labels
    }

    # Add custom fields based on mapping
    foreach ($mapping in $script:FieldMapping.fields.GetEnumerator()) {
        $adoField = $mapping.Key
        $jiraField = $mapping.Value

        if ($jiraField -like "customfield_*" -and $fields.$adoField) {
            $jiraIssue.fields[$jiraField] = $fields.$adoField
        }
    }

    # Add ADO reference in description
    $adoUrl = $WorkItem._links.html.href
    if ($jiraIssue.fields.description) {
        $jiraIssue.fields.description.content += @{
            type = "paragraph"
            content = @(
                @{
                    type = "text"
                    text = "`n`nMigrated from Azure DevOps: "
                },
                @{
                    type = "text"
                    text = "Work Item #$($WorkItem.id)"
                    marks = @(@{ type = "link"; attrs = @{ href = $adoUrl } })
                }
            )
        }
    }

    return $jiraIssue
}

function New-JiraIssue {
    param([hashtable]$Issue)

    if ($DryRun) {
        Write-Log "[DRY RUN] Would create Jira issue: $($Issue.fields.summary)"
        return @{ key = "DRY-RUN-$([guid]::NewGuid().ToString().Substring(0,8))" }
    }

    try {
        $result = Invoke-JiraApi -Endpoint "issue" -Method POST -Body $Issue
        Write-Log "Created Jira issue: $($result.key) - $($Issue.fields.summary)" "SUCCESS"
        return $result
    }
    catch {
        Write-Log "Failed to create Jira issue: $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Add-JiraComment {
    param([string]$IssueKey, [string]$CommentBody, [string]$Author, [datetime]$Created)

    if ($DryRun) {
        Write-Log "[DRY RUN] Would add comment to $IssueKey"
        return
    }

    $body = @{
        body = @{
            type = "doc"
            version = 1
            content = @(
                @{
                    type = "paragraph"
                    content = @(
                        @{
                            type = "text"
                            text = "Comment by $Author on $($Created.ToString('yyyy-MM-dd HH:mm')):`n$CommentBody"
                        }
                    )
                }
            )
        }
    }

    try {
        Invoke-JiraApi -Endpoint "issue/$IssueKey/comment" -Method POST -Body $body
        Write-Log "Added comment to $IssueKey"
    }
    catch {
        Write-Log "Failed to add comment to $IssueKey : $($_.Exception.Message)" "WARNING"
    }
}

function Add-JiraAttachment {
    param([string]$IssueKey, [string]$AttachmentUrl, [string]$FileName)

    if ($DryRun) {
        Write-Log "[DRY RUN] Would add attachment to $IssueKey : $FileName"
        return
    }

    try {
        # Download from ADO
        $tempFile = Join-Path $env:TEMP $FileName
        Invoke-WebRequest -Uri $AttachmentUrl -Headers $adoAuthHeader -OutFile $tempFile

        # Upload to Jira
        $boundary = [guid]::NewGuid().ToString()
        $fileBytes = [System.IO.File]::ReadAllBytes($tempFile)
        $fileEnc = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($fileBytes)

        $bodyLines = @(
            "--$boundary",
            "Content-Disposition: form-data; name=`"file`"; filename=`"$FileName`"",
            "Content-Type: application/octet-stream",
            "",
            $fileEnc,
            "--$boundary--"
        ) -join "`r`n"

        $headers = @{
            "Authorization" = "Basic $jiraAuthString"
            "X-Atlassian-Token" = "no-check"
            "Content-Type" = "multipart/form-data; boundary=$boundary"
        }

        Invoke-RestMethod -Uri "$JiraUrl/rest/api/3/issue/$IssueKey/attachments" -Method POST -Headers $headers -Body $bodyLines

        Remove-Item $tempFile -Force
        Write-Log "Added attachment to $IssueKey : $FileName"
    }
    catch {
        Write-Log "Failed to add attachment to $IssueKey : $($_.Exception.Message)" "WARNING"
    }
}

function Add-JiraLink {
    param([string]$IssueKey, [string]$LinkedIssueKey, [string]$LinkType)

    if ($DryRun) {
        Write-Log "[DRY RUN] Would link $IssueKey to $LinkedIssueKey"
        return
    }

    $body = @{
        type = @{ name = $LinkType }
        inwardIssue = @{ key = $IssueKey }
        outwardIssue = @{ key = $LinkedIssueKey }
    }

    try {
        Invoke-JiraApi -Endpoint "issueLink" -Method POST -Body $body
        Write-Log "Linked $IssueKey to $LinkedIssueKey ($LinkType)"
    }
    catch {
        Write-Log "Failed to link issues: $($_.Exception.Message)" "WARNING"
    }
}

#endregion

#region Migration Functions

function Start-WorkItemMigration {
    param([string]$Project)

    Write-Log "Starting work item migration for project: $Project"

    # Get work items
    $workItems = Get-AdoWorkItems -Project $Project

    if ($workItems.Count -eq 0) {
        Write-Log "No work items to migrate"
        return
    }

    # Process in batches
    $totalBatches = [Math]::Ceiling($workItems.Count / $BatchSize)
    $currentBatch = 0

    for ($i = 0; $i -lt $workItems.Count; $i += $BatchSize) {
        $currentBatch++
        $batch = $workItems[$i..[Math]::Min($i + $BatchSize - 1, $workItems.Count - 1)]

        Write-Log "Processing batch $currentBatch of $totalBatches ($($batch.Count) items)"

        foreach ($item in $batch) {
            $script:MigrationState.ProcessedItems++

            try {
                # Check if already migrated (resume support)
                if ($script:MigrationState.ItemMapping.ContainsKey($item.id.ToString())) {
                    Write-Log "Skipping already migrated item: $($item.id)"
                    $script:MigrationState.SkippedItems++
                    continue
                }

                # Get full work item details
                $workItemDetails = Get-AdoWorkItemDetails -WorkItemId $item.id -Project $Project

                if ($null -eq $workItemDetails) {
                    Write-Log "Failed to get details for work item $($item.id)" "ERROR"
                    $script:MigrationState.FailedItems++
                    continue
                }

                # Convert to Jira format
                $jiraIssue = Convert-AdoWorkItemToJira -WorkItem $workItemDetails

                # Create Jira issue
                $createdIssue = New-JiraIssue -Issue $jiraIssue

                # Store mapping
                $script:MigrationState.ItemMapping[$item.id.ToString()] = $createdIssue.key

                # Add comments
                if ($IncludeComments) {
                    $comments = Get-AdoWorkItemComments -WorkItemId $item.id -Project $Project
                    if ($comments -and $comments.comments) {
                        foreach ($comment in $comments.comments) {
                            Add-JiraComment -IssueKey $createdIssue.key -CommentBody $comment.text -Author $comment.createdBy.displayName -Created ([datetime]$comment.createdDate)
                        }
                    }
                }

                # Add attachments
                if ($IncludeAttachments) {
                    $attachments = Get-AdoWorkItemAttachments -WorkItemId $item.id -Project $Project
                    foreach ($attachment in $attachments) {
                        $fileName = $attachment.attributes.name
                        Add-JiraAttachment -IssueKey $createdIssue.key -AttachmentUrl $attachment.url -FileName $fileName
                    }
                }

                $script:MigrationState.SuccessfulItems++

                # Save state periodically
                if ($script:MigrationState.ProcessedItems % 10 -eq 0) {
                    Save-MigrationState
                }
            }
            catch {
                Write-Log "Failed to migrate work item $($item.id): $($_.Exception.Message)" "ERROR"
                $script:MigrationState.FailedItems++
                $script:MigrationState.Errors += @{
                    WorkItemId = $item.id
                    Error = $_.Exception.Message
                    Timestamp = Get-Date
                }
            }

            # Rate limiting
            Start-Sleep -Milliseconds 200
        }

        # Delay between batches
        if ($currentBatch -lt $totalBatches) {
            Write-Log "Waiting before next batch..."
            Start-Sleep -Seconds 5
        }
    }

    # Process links after all items are created
    if ($IncludeLinks) {
        Write-Log "Processing work item links..."
        Process-WorkItemLinks -Project $Project
    }
}

function Process-WorkItemLinks {
    param([string]$Project)

    foreach ($mapping in $script:MigrationState.ItemMapping.GetEnumerator()) {
        $adoId = $mapping.Key
        $jiraKey = $mapping.Value

        try {
            $workItem = Get-AdoWorkItemDetails -WorkItemId $adoId -Project $Project

            if ($workItem.relations) {
                foreach ($relation in $workItem.relations) {
                    if ($relation.rel -in @("System.LinkTypes.Hierarchy-Forward", "System.LinkTypes.Hierarchy-Reverse", "System.LinkTypes.Related")) {
                        # Extract linked work item ID
                        if ($relation.url -match '/workItems/(\d+)$') {
                            $linkedAdoId = $matches[1]

                            if ($script:MigrationState.ItemMapping.ContainsKey($linkedAdoId)) {
                                $linkedJiraKey = $script:MigrationState.ItemMapping[$linkedAdoId]

                                $linkType = switch ($relation.rel) {
                                    "System.LinkTypes.Hierarchy-Forward" { "is parent of" }
                                    "System.LinkTypes.Hierarchy-Reverse" { "is child of" }
                                    default { "relates to" }
                                }

                                Add-JiraLink -IssueKey $jiraKey -LinkedIssueKey $linkedJiraKey -LinkType $linkType
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "Failed to process links for $jiraKey : $($_.Exception.Message)" "WARNING"
        }
    }
}

function Save-MigrationState {
    $script:MigrationState | ConvertTo-Json -Depth 10 | Out-File $migrationStateFile -Force
}

function Load-MigrationState {
    if ($ResumeFromLast -and (Test-Path $migrationStateFile)) {
        try {
            $script:MigrationState = Get-Content $migrationStateFile -Raw | ConvertFrom-Json -AsHashtable
            Write-Log "Resumed from previous migration state. Already processed: $($script:MigrationState.ProcessedItems) items"
            return $true
        }
        catch {
            Write-Log "Failed to load migration state, starting fresh" "WARNING"
        }
    }
    return $false
}

function Generate-MigrationReport {
    $report = @{
        MigrationDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        SourceOrganization = $AdoOrg
        SourceProject = $AdoProject
        TargetJiraUrl = $JiraUrl
        TargetProject = $JiraProject
        DryRun = $DryRun.IsPresent
        Statistics = @{
            TotalProcessed = $script:MigrationState.ProcessedItems
            Successful = $script:MigrationState.SuccessfulItems
            Failed = $script:MigrationState.FailedItems
            Skipped = $script:MigrationState.SkippedItems
            Duration = ((Get-Date) - $script:MigrationState.StartTime).TotalMinutes
        }
        ItemMapping = $script:MigrationState.ItemMapping
        Errors = $script:MigrationState.Errors
    }

    # Save JSON report
    $reportPath = Join-Path $OutputDir "jira-migration-report-$(Get-Date -Format 'yyyy-MM-dd-HHmm').json"
    $report | ConvertTo-Json -Depth 10 | Out-File $reportPath
    Write-Log "Migration report saved: $reportPath"

    # Save CSV mapping
    $csvPath = Join-Path $OutputDir "jira-migration-mapping-$(Get-Date -Format 'yyyy-MM-dd-HHmm').csv"
    $script:MigrationState.ItemMapping.GetEnumerator() |
        Select-Object @{N='AdoWorkItemId';E={$_.Key}}, @{N='JiraIssueKey';E={$_.Value}} |
        Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "ID mapping saved: $csvPath"

    return $report
}

#endregion

#region Main Execution

try {
    Write-Log "=== Azure DevOps to Jira Work Item Migration Started ==="
    Write-Log "Source: $AdoOrg/$AdoProject"
    Write-Log "Target: $JiraUrl (Project: $JiraProject)"
    Write-Log "Work Item Types: $WorkItemTypes"
    Write-Log "Dry Run: $($DryRun.IsPresent)"

    # Initialize
    Initialize-FieldMapping

    # Test Jira connection
    if (-not (Test-JiraConnection)) {
        throw "Failed to connect to Jira"
    }

    # Get Jira project metadata
    $jiraMetadata = Get-JiraProjectMetadata
    if (-not $jiraMetadata) {
        throw "Failed to get Jira project metadata"
    }

    # Load previous state if resuming
    Load-MigrationState

    # Process each project
    $projects = $AdoProject -split "," | ForEach-Object { $_.Trim() }

    foreach ($project in $projects) {
        Start-WorkItemMigration -Project $project
    }

    # Save final state
    Save-MigrationState

    # Generate report
    $report = Generate-MigrationReport

    # Display summary
    Write-Log "=== Migration Summary ===" "INFO"
    Write-Log "Total Processed: $($report.Statistics.TotalProcessed)" "INFO"
    Write-Log "Successful: $($report.Statistics.Successful)" "SUCCESS"
    Write-Log "Failed: $($report.Statistics.Failed)" $(if ($report.Statistics.Failed -gt 0) { "ERROR" } else { "INFO" })
    Write-Log "Skipped: $($report.Statistics.Skipped)" "INFO"
    Write-Log "Duration: $([Math]::Round($report.Statistics.Duration, 2)) minutes" "INFO"
    Write-Log "=== Migration Completed ==="

}
catch {
    Write-Log "Migration failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}

#endregion
