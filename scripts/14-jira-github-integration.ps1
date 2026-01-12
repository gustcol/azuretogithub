<#
.SYNOPSIS
    Configures Jira-GitHub integration for automated workflow synchronization.

.DESCRIPTION
    This script sets up integration between Jira Cloud/Data Center and GitHub Actions,
    enabling automated status transitions, issue linking, and bidirectional updates.
    It deploys workflow templates and configures repository secrets for Jira API access.

.PARAMETER GitHubOrg
    The GitHub organization name.

.PARAMETER GitHubPat
    GitHub Personal Access Token with repo and workflow permissions.

.PARAMETER JiraUrl
    The Jira instance URL (e.g., https://yourcompany.atlassian.net).

.PARAMETER JiraEmail
    Email address associated with the Jira API token.

.PARAMETER JiraApiToken
    Jira API token for authentication.

.PARAMETER JiraProject
    Default Jira project key for issue creation.

.PARAMETER Repositories
    Array of repository names to configure. If empty, configures all repositories.

.PARAMETER ConfigFile
    Path to Jira integration configuration file.

.PARAMETER DeployWorkflows
    Deploy GitHub Actions workflow templates for Jira integration.

.PARAMETER ConfigureSecrets
    Configure organization/repository secrets for Jira API access.

.PARAMETER EnableWebhooks
    Configure GitHub webhooks for Jira (requires GitHub App or webhook endpoint).

.PARAMETER TransitionMappings
    Hashtable mapping GitHub events to Jira transitions.

.PARAMETER WhatIf
    Show what would be done without making changes.

.EXAMPLE
    .\14-jira-github-integration.ps1 -GitHubOrg "myorg" -GitHubPat $env:GITHUB_TOKEN `
        -JiraUrl "https://mycompany.atlassian.net" -JiraEmail "user@company.com" `
        -JiraApiToken $env:JIRA_TOKEN -JiraProject "PROJ" -DeployWorkflows -ConfigureSecrets

.NOTES
    Version: 1.0.0
    Author: Migration Factory
    Requires: PowerShell 7+, GitHub CLI
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory=$true)]
    [string]$GitHubPat,

    [Parameter(Mandatory=$true)]
    [string]$JiraUrl,

    [Parameter(Mandatory=$true)]
    [string]$JiraEmail,

    [Parameter(Mandatory=$true)]
    [string]$JiraApiToken,

    [Parameter(Mandatory=$false)]
    [string]$JiraProject = "",

    [Parameter(Mandatory=$false)]
    [string[]]$Repositories = @(),

    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "",

    [Parameter(Mandatory=$false)]
    [switch]$DeployWorkflows,

    [Parameter(Mandatory=$false)]
    [switch]$ConfigureSecrets,

    [Parameter(Mandatory=$false)]
    [switch]$EnableWebhooks,

    [Parameter(Mandatory=$false)]
    [hashtable]$TransitionMappings = @{},

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "./reports"
)

# Script configuration
$ErrorActionPreference = "Stop"
$script:LogFile = Join-Path $OutputPath "jira-integration-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:ReportFile = Join-Path $OutputPath "jira-integration-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "INFO"    { Write-Host $logMessage -ForegroundColor Cyan }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
    }

    Add-Content -Path $script:LogFile -Value $logMessage
}

function Get-JiraAuthHeader {
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${JiraEmail}:${JiraApiToken}"))
    return @{
        "Authorization" = "Basic $base64Auth"
        "Content-Type" = "application/json"
        "Accept" = "application/json"
    }
}

function Test-JiraConnection {
    Write-Log "Testing Jira connection..."

    try {
        $headers = Get-JiraAuthHeader
        $response = Invoke-RestMethod -Uri "$JiraUrl/rest/api/3/myself" -Headers $headers -Method Get
        Write-Log "Connected to Jira as: $($response.displayName) ($($response.emailAddress))" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to connect to Jira: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Test-GitHubConnection {
    Write-Log "Testing GitHub connection..."

    try {
        $env:GH_TOKEN = $GitHubPat
        $result = gh api "/orgs/$GitHubOrg" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $org = $result | ConvertFrom-Json
            Write-Log "Connected to GitHub organization: $($org.login)" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Failed to connect to GitHub: $result" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Failed to connect to GitHub: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Get-JiraTransitions {
    param([string]$IssueKey)

    try {
        $headers = Get-JiraAuthHeader
        $response = Invoke-RestMethod -Uri "$JiraUrl/rest/api/3/issue/$IssueKey/transitions" -Headers $headers -Method Get
        return $response.transitions
    }
    catch {
        Write-Log "Failed to get transitions for $IssueKey : $($_.Exception.Message)" -Level WARNING
        return @()
    }
}

function Get-JiraProjectWorkflow {
    param([string]$ProjectKey)

    Write-Log "Fetching workflow information for project: $ProjectKey"

    try {
        $headers = Get-JiraAuthHeader

        # Get project details
        $project = Invoke-RestMethod -Uri "$JiraUrl/rest/api/3/project/$ProjectKey" -Headers $headers -Method Get

        # Get issue types for the project
        $issueTypes = $project.issueTypes | ForEach-Object { $_.name }

        Write-Log "Project '$ProjectKey' has issue types: $($issueTypes -join ', ')"

        return @{
            ProjectKey = $ProjectKey
            ProjectName = $project.name
            IssueTypes = $issueTypes
        }
    }
    catch {
        Write-Log "Failed to get workflow for project $ProjectKey : $($_.Exception.Message)" -Level WARNING
        return $null
    }
}

function Get-GitHubRepositories {
    Write-Log "Fetching GitHub repositories..."

    try {
        $env:GH_TOKEN = $GitHubPat
        $repos = @()
        $page = 1

        do {
            $result = gh api "/orgs/$GitHubOrg/repos?per_page=100&page=$page" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to fetch repositories: $result"
            }

            $pageRepos = $result | ConvertFrom-Json
            if ($pageRepos.Count -eq 0) { break }

            $repos += $pageRepos
            $page++
        } while ($pageRepos.Count -eq 100)

        if ($Repositories.Count -gt 0) {
            $repos = $repos | Where-Object { $Repositories -contains $_.name }
        }

        Write-Log "Found $($repos.Count) repositories to configure"
        return $repos
    }
    catch {
        Write-Log "Failed to fetch repositories: $($_.Exception.Message)" -Level ERROR
        return @()
    }
}

function Set-OrganizationSecret {
    param(
        [string]$SecretName,
        [string]$SecretValue,
        [string]$Visibility = "all"
    )

    Write-Log "Setting organization secret: $SecretName"

    if ($WhatIfPreference) {
        Write-Log "[WhatIf] Would set organization secret: $SecretName" -Level INFO
        return $true
    }

    try {
        $env:GH_TOKEN = $GitHubPat

        # Set the secret using gh CLI
        $result = $SecretValue | gh secret set $SecretName --org $GitHubOrg --visibility $Visibility 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully set organization secret: $SecretName" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Failed to set secret $SecretName : $result" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Failed to set organization secret: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Set-RepositorySecret {
    param(
        [string]$Repository,
        [string]$SecretName,
        [string]$SecretValue
    )

    Write-Log "Setting repository secret: $SecretName for $Repository"

    if ($WhatIfPreference) {
        Write-Log "[WhatIf] Would set repository secret: $SecretName for $Repository" -Level INFO
        return $true
    }

    try {
        $env:GH_TOKEN = $GitHubPat

        $result = $SecretValue | gh secret set $SecretName --repo "$GitHubOrg/$Repository" 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully set repository secret: $SecretName for $Repository" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Failed to set secret for $Repository : $result" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Failed to set repository secret: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function New-JiraIntegrationWorkflow {
    param(
        [string]$WorkflowType,
        [hashtable]$Config
    )

    $workflows = @{
        "jira-issue-transition" = @'
# Jira Issue Transition Workflow
# Automatically transitions Jira issues based on GitHub events

name: Jira Issue Transition

on:
  pull_request:
    types: [opened, closed, merged]
  push:
    branches:
      - main
      - master
  issues:
    types: [opened, closed]

env:
  JIRA_BASE_URL: ${{ secrets.JIRA_BASE_URL }}
  JIRA_USER_EMAIL: ${{ secrets.JIRA_USER_EMAIL }}
  JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}

jobs:
  extract-issue-key:
    runs-on: ubuntu-latest
    outputs:
      issue_key: ${{ steps.extract.outputs.issue_key }}
    steps:
      - name: Extract Jira Issue Key
        id: extract
        run: |
          # Extract Jira issue key from branch name, PR title, or commit message
          BRANCH_NAME="${{ github.head_ref || github.ref_name }}"
          PR_TITLE="${{ github.event.pull_request.title }}"
          COMMIT_MSG="${{ github.event.head_commit.message }}"

          # Pattern: PROJECT-123
          ISSUE_KEY=$(echo "$BRANCH_NAME $PR_TITLE $COMMIT_MSG" | grep -oE '[A-Z]+-[0-9]+' | head -1)

          if [ -n "$ISSUE_KEY" ]; then
            echo "Found Jira issue key: $ISSUE_KEY"
            echo "issue_key=$ISSUE_KEY" >> $GITHUB_OUTPUT
          else
            echo "No Jira issue key found"
            echo "issue_key=" >> $GITHUB_OUTPUT
          fi

  transition-on-pr-open:
    needs: extract-issue-key
    if: github.event_name == 'pull_request' && github.event.action == 'opened' && needs.extract-issue-key.outputs.issue_key != ''
    runs-on: ubuntu-latest
    steps:
      - name: Transition to In Review
        run: |
          ISSUE_KEY="${{ needs.extract-issue-key.outputs.issue_key }}"

          # Get available transitions
          TRANSITIONS=$(curl -s -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            "$JIRA_BASE_URL/rest/api/3/issue/$ISSUE_KEY/transitions")

          # Find "In Review" or similar transition
          TRANSITION_ID=$(echo $TRANSITIONS | jq -r '.transitions[] | select(.name | test("review|code review"; "i")) | .id' | head -1)

          if [ -n "$TRANSITION_ID" ]; then
            curl -s -X POST -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
              -H "Content-Type: application/json" \
              "$JIRA_BASE_URL/rest/api/3/issue/$ISSUE_KEY/transitions" \
              -d "{\"transition\": {\"id\": \"$TRANSITION_ID\"}}"
            echo "Transitioned $ISSUE_KEY to In Review"
          fi

          # Add comment with PR link
          curl -s -X POST -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$JIRA_BASE_URL/rest/api/3/issue/$ISSUE_KEY/comment" \
            -d "{\"body\": {\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \"text\": \"Pull Request opened: \"}, {\"type\": \"text\", \"text\": \"${{ github.event.pull_request.html_url }}\", \"marks\": [{\"type\": \"link\", \"attrs\": {\"href\": \"${{ github.event.pull_request.html_url }}\"}}]}]}]}}"

  transition-on-pr-merge:
    needs: extract-issue-key
    if: github.event_name == 'pull_request' && github.event.action == 'closed' && github.event.pull_request.merged == true && needs.extract-issue-key.outputs.issue_key != ''
    runs-on: ubuntu-latest
    steps:
      - name: Transition to Done
        run: |
          ISSUE_KEY="${{ needs.extract-issue-key.outputs.issue_key }}"

          # Get available transitions
          TRANSITIONS=$(curl -s -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            "$JIRA_BASE_URL/rest/api/3/issue/$ISSUE_KEY/transitions")

          # Find "Done" or similar transition
          TRANSITION_ID=$(echo $TRANSITIONS | jq -r '.transitions[] | select(.name | test("done|complete|resolved"; "i")) | .id' | head -1)

          if [ -n "$TRANSITION_ID" ]; then
            curl -s -X POST -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
              -H "Content-Type: application/json" \
              "$JIRA_BASE_URL/rest/api/3/issue/$ISSUE_KEY/transitions" \
              -d "{\"transition\": {\"id\": \"$TRANSITION_ID\"}}"
            echo "Transitioned $ISSUE_KEY to Done"
          fi

          # Add comment with merge info
          curl -s -X POST -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$JIRA_BASE_URL/rest/api/3/issue/$ISSUE_KEY/comment" \
            -d "{\"body\": {\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \"text\": \"Pull Request merged to ${{ github.base_ref }}: \"}, {\"type\": \"text\", \"text\": \"${{ github.event.pull_request.html_url }}\", \"marks\": [{\"type\": \"link\", \"attrs\": {\"href\": \"${{ github.event.pull_request.html_url }}\"}}]}]}]}}"

  add-commit-comment:
    needs: extract-issue-key
    if: github.event_name == 'push' && needs.extract-issue-key.outputs.issue_key != ''
    runs-on: ubuntu-latest
    steps:
      - name: Add Commit Comment to Jira
        run: |
          ISSUE_KEY="${{ needs.extract-issue-key.outputs.issue_key }}"
          COMMIT_SHA="${{ github.sha }}"
          COMMIT_MSG="${{ github.event.head_commit.message }}"
          COMMIT_URL="${{ github.event.head_commit.url }}"
          AUTHOR="${{ github.event.head_commit.author.name }}"

          # Add comment with commit info
          curl -s -X POST -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$JIRA_BASE_URL/rest/api/3/issue/$ISSUE_KEY/comment" \
            -d "{\"body\": {\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \"text\": \"Commit by $AUTHOR: \"}, {\"type\": \"text\", \"text\": \"${COMMIT_SHA:0:7}\", \"marks\": [{\"type\": \"link\", \"attrs\": {\"href\": \"$COMMIT_URL\"}}]}, {\"type\": \"text\", \"text\": \" - ${COMMIT_MSG%%$'\\n'*}\"}]}]}}"
'@

        "jira-create-issue" = @'
# Jira Create Issue Workflow
# Creates Jira issues from GitHub issues or manually triggered

name: Create Jira Issue

on:
  issues:
    types: [opened, labeled]
  workflow_dispatch:
    inputs:
      summary:
        description: 'Issue summary'
        required: true
      description:
        description: 'Issue description'
        required: false
      issue_type:
        description: 'Issue type'
        required: true
        default: 'Task'
        type: choice
        options:
          - Task
          - Bug
          - Story
          - Epic

env:
  JIRA_BASE_URL: ${{ secrets.JIRA_BASE_URL }}
  JIRA_USER_EMAIL: ${{ secrets.JIRA_USER_EMAIL }}
  JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
  JIRA_PROJECT_KEY: ${{ secrets.JIRA_PROJECT_KEY }}

jobs:
  create-from-github-issue:
    if: github.event_name == 'issues' && contains(github.event.issue.labels.*.name, 'sync-to-jira')
    runs-on: ubuntu-latest
    steps:
      - name: Create Jira Issue from GitHub Issue
        id: create
        run: |
          SUMMARY="${{ github.event.issue.title }}"
          DESCRIPTION="${{ github.event.issue.body }}"
          GITHUB_ISSUE_URL="${{ github.event.issue.html_url }}"

          # Determine issue type based on labels
          ISSUE_TYPE="Task"
          if echo "${{ toJson(github.event.issue.labels.*.name) }}" | grep -qi "bug"; then
            ISSUE_TYPE="Bug"
          elif echo "${{ toJson(github.event.issue.labels.*.name) }}" | grep -qi "feature"; then
            ISSUE_TYPE="Story"
          fi

          # Create Jira issue
          RESPONSE=$(curl -s -X POST -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$JIRA_BASE_URL/rest/api/3/issue" \
            -d "{
              \"fields\": {
                \"project\": {\"key\": \"$JIRA_PROJECT_KEY\"},
                \"summary\": \"$SUMMARY\",
                \"description\": {
                  \"type\": \"doc\",
                  \"version\": 1,
                  \"content\": [
                    {
                      \"type\": \"paragraph\",
                      \"content\": [{\"type\": \"text\", \"text\": \"GitHub Issue: $GITHUB_ISSUE_URL\"}]
                    },
                    {
                      \"type\": \"paragraph\",
                      \"content\": [{\"type\": \"text\", \"text\": \"$DESCRIPTION\"}]
                    }
                  ]
                },
                \"issuetype\": {\"name\": \"$ISSUE_TYPE\"}
              }
            }")

          ISSUE_KEY=$(echo $RESPONSE | jq -r '.key')
          echo "Created Jira issue: $ISSUE_KEY"
          echo "issue_key=$ISSUE_KEY" >> $GITHUB_OUTPUT

      - name: Add Comment to GitHub Issue
        if: steps.create.outputs.issue_key != ''
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `Jira issue created: [${{ steps.create.outputs.issue_key }}](${{ env.JIRA_BASE_URL }}/browse/${{ steps.create.outputs.issue_key }})`
            })

  create-manual:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps:
      - name: Create Jira Issue Manually
        run: |
          RESPONSE=$(curl -s -X POST -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$JIRA_BASE_URL/rest/api/3/issue" \
            -d "{
              \"fields\": {
                \"project\": {\"key\": \"$JIRA_PROJECT_KEY\"},
                \"summary\": \"${{ github.event.inputs.summary }}\",
                \"description\": {
                  \"type\": \"doc\",
                  \"version\": 1,
                  \"content\": [
                    {
                      \"type\": \"paragraph\",
                      \"content\": [{\"type\": \"text\", \"text\": \"${{ github.event.inputs.description }}\"}]
                    }
                  ]
                },
                \"issuetype\": {\"name\": \"${{ github.event.inputs.issue_type }}\"}
              }
            }")

          ISSUE_KEY=$(echo $RESPONSE | jq -r '.key')
          echo "Created Jira issue: $ISSUE_KEY"
          echo "View at: $JIRA_BASE_URL/browse/$ISSUE_KEY"
'@

        "jira-sync-status" = @'
# Jira Status Sync Workflow
# Syncs status between Jira and GitHub

name: Jira Status Sync

on:
  schedule:
    - cron: '*/15 * * * *'  # Every 15 minutes
  workflow_dispatch:

env:
  JIRA_BASE_URL: ${{ secrets.JIRA_BASE_URL }}
  JIRA_USER_EMAIL: ${{ secrets.JIRA_USER_EMAIL }}
  JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
  JIRA_PROJECT_KEY: ${{ secrets.JIRA_PROJECT_KEY }}

jobs:
  sync-status:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Sync Jira Issues to GitHub
        uses: actions/github-script@v7
        with:
          script: |
            const jiraBaseUrl = process.env.JIRA_BASE_URL;
            const jiraAuth = Buffer.from(`${process.env.JIRA_USER_EMAIL}:${process.env.JIRA_API_TOKEN}`).toString('base64');

            // Fetch recent Jira issues
            const jql = `project = ${process.env.JIRA_PROJECT_KEY} AND updated >= -1d ORDER BY updated DESC`;
            const response = await fetch(
              `${jiraBaseUrl}/rest/api/3/search?jql=${encodeURIComponent(jql)}&maxResults=50`,
              {
                headers: {
                  'Authorization': `Basic ${jiraAuth}`,
                  'Content-Type': 'application/json'
                }
              }
            );

            const data = await response.json();
            console.log(`Found ${data.issues?.length || 0} recently updated Jira issues`);

            // Process each issue
            for (const issue of (data.issues || [])) {
              const issueKey = issue.key;
              const status = issue.fields.status.name;

              // Find related GitHub issues/PRs by searching
              const { data: searchResults } = await github.rest.search.issuesAndPullRequests({
                q: `${issueKey} repo:${context.repo.owner}/${context.repo.repo}`,
                per_page: 10
              });

              for (const item of searchResults.items) {
                console.log(`Found GitHub item #${item.number} linked to ${issueKey} (Status: ${status})`);

                // Add/update label based on Jira status
                const statusLabel = `jira:${status.toLowerCase().replace(/\s+/g, '-')}`;

                // Remove old jira status labels
                const currentLabels = item.labels.map(l => l.name);
                const oldJiraLabels = currentLabels.filter(l => l.startsWith('jira:'));

                for (const oldLabel of oldJiraLabels) {
                  if (oldLabel !== statusLabel) {
                    try {
                      await github.rest.issues.removeLabel({
                        owner: context.repo.owner,
                        repo: context.repo.repo,
                        issue_number: item.number,
                        name: oldLabel
                      });
                    } catch (e) {
                      console.log(`Could not remove label ${oldLabel}: ${e.message}`);
                    }
                  }
                }

                // Add new status label
                if (!currentLabels.includes(statusLabel)) {
                  try {
                    await github.rest.issues.addLabels({
                      owner: context.repo.owner,
                      repo: context.repo.repo,
                      issue_number: item.number,
                      labels: [statusLabel]
                    });
                    console.log(`Added label ${statusLabel} to #${item.number}`);
                  } catch (e) {
                    console.log(`Could not add label: ${e.message}`);
                  }
                }
              }
            }
'@

        "jira-release-notes" = @'
# Jira Release Notes Generator
# Generates release notes from Jira issues

name: Generate Release Notes from Jira

on:
  release:
    types: [created, published]
  workflow_dispatch:
    inputs:
      version:
        description: 'Release version (e.g., 1.0.0)'
        required: true
      jql_filter:
        description: 'JQL filter for issues (optional)'
        required: false

env:
  JIRA_BASE_URL: ${{ secrets.JIRA_BASE_URL }}
  JIRA_USER_EMAIL: ${{ secrets.JIRA_USER_EMAIL }}
  JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
  JIRA_PROJECT_KEY: ${{ secrets.JIRA_PROJECT_KEY }}

jobs:
  generate-release-notes:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Generate Release Notes
        id: notes
        run: |
          VERSION="${{ github.event.release.tag_name || github.event.inputs.version }}"
          JQL_FILTER="${{ github.event.inputs.jql_filter }}"

          # Default JQL: issues fixed in this version
          if [ -z "$JQL_FILTER" ]; then
            JQL_FILTER="project = $JIRA_PROJECT_KEY AND fixVersion = \"$VERSION\" ORDER BY issuetype ASC, priority DESC"
          fi

          # Fetch issues
          RESPONSE=$(curl -s -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$JIRA_BASE_URL/rest/api/3/search?jql=$(echo $JQL_FILTER | jq -sRr @uri)&maxResults=100")

          # Generate markdown
          echo "# Release Notes - $VERSION" > release-notes.md
          echo "" >> release-notes.md
          echo "Generated on $(date -u +"%Y-%m-%d %H:%M UTC")" >> release-notes.md
          echo "" >> release-notes.md

          # Group by issue type
          for TYPE in "Bug" "Story" "Task" "Epic"; do
            ISSUES=$(echo $RESPONSE | jq -r ".issues[] | select(.fields.issuetype.name == \"$TYPE\") | \"- [\(.key)]($JIRA_BASE_URL/browse/\(.key)) - \(.fields.summary)\"")
            if [ -n "$ISSUES" ]; then
              case $TYPE in
                "Bug") echo "## Bug Fixes" >> release-notes.md ;;
                "Story") echo "## New Features" >> release-notes.md ;;
                "Task") echo "## Tasks" >> release-notes.md ;;
                "Epic") echo "## Epics" >> release-notes.md ;;
              esac
              echo "" >> release-notes.md
              echo "$ISSUES" >> release-notes.md
              echo "" >> release-notes.md
            fi
          done

          # Output for use in other steps
          NOTES=$(cat release-notes.md)
          echo "notes<<EOF" >> $GITHUB_OUTPUT
          echo "$NOTES" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT

      - name: Update Release Notes
        if: github.event_name == 'release'
        uses: actions/github-script@v7
        with:
          script: |
            const notes = `${{ steps.notes.outputs.notes }}`;

            await github.rest.repos.updateRelease({
              owner: context.repo.owner,
              repo: context.repo.repo,
              release_id: context.payload.release.id,
              body: notes
            });

            console.log('Release notes updated successfully');

      - name: Upload Release Notes Artifact
        uses: actions/upload-artifact@v4
        with:
          name: release-notes-${{ github.event.release.tag_name || github.event.inputs.version }}
          path: release-notes.md
'@
    }

    if ($workflows.ContainsKey($WorkflowType)) {
        return $workflows[$WorkflowType]
    }
    else {
        Write-Log "Unknown workflow type: $WorkflowType" -Level WARNING
        return $null
    }
}

function Deploy-WorkflowToRepository {
    param(
        [string]$Repository,
        [string]$WorkflowName,
        [string]$WorkflowContent
    )

    Write-Log "Deploying workflow '$WorkflowName' to $Repository"

    if ($WhatIfPreference) {
        Write-Log "[WhatIf] Would deploy workflow '$WorkflowName' to $Repository" -Level INFO
        return $true
    }

    try {
        $env:GH_TOKEN = $GitHubPat

        # Check if .github/workflows directory exists
        $workflowPath = ".github/workflows/$WorkflowName.yml"

        # Encode content to base64
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($WorkflowContent)
        $contentBase64 = [Convert]::ToBase64String($contentBytes)

        # Check if file exists
        $existingFile = gh api "/repos/$GitHubOrg/$Repository/contents/$workflowPath" 2>&1
        $sha = $null

        if ($LASTEXITCODE -eq 0) {
            $existing = $existingFile | ConvertFrom-Json
            $sha = $existing.sha
            Write-Log "Workflow file exists, will update (SHA: $sha)"
        }

        # Create or update the file
        $body = @{
            message = "Add/Update Jira integration workflow: $WorkflowName"
            content = $contentBase64
            branch = "main"
        }

        if ($sha) {
            $body.sha = $sha
        }

        $bodyJson = $body | ConvertTo-Json -Compress
        $result = echo $bodyJson | gh api "/repos/$GitHubOrg/$Repository/contents/$workflowPath" --method PUT --input - 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully deployed workflow '$WorkflowName' to $Repository" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Failed to deploy workflow: $result" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Failed to deploy workflow: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Get-IntegrationConfig {
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        Write-Log "Loading configuration from: $ConfigFile"
        return Get-Content $ConfigFile -Raw | ConvertFrom-Json
    }

    # Return default configuration
    return @{
        workflows = @(
            "jira-issue-transition"
            "jira-create-issue"
            "jira-sync-status"
            "jira-release-notes"
        )
        transitionMappings = @{
            "pr_opened" = "In Review"
            "pr_merged" = "Done"
            "pr_closed" = "To Do"
            "issue_opened" = "To Do"
            "issue_closed" = "Done"
        }
    }
}

# Main execution
function Main {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Jira-GitHub Integration Setup" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $report = @{
        StartTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        GitHubOrg = $GitHubOrg
        JiraUrl = $JiraUrl
        JiraProject = $JiraProject
        Actions = @{
            SecretsConfigured = @()
            WorkflowsDeployed = @()
            Errors = @()
        }
        Summary = @{
            RepositoriesProcessed = 0
            SecretsConfigured = 0
            WorkflowsDeployed = 0
            Errors = 0
        }
    }

    # Test connections
    if (-not (Test-JiraConnection)) {
        Write-Log "Jira connection failed. Please check your credentials." -Level ERROR
        return
    }

    if (-not (Test-GitHubConnection)) {
        Write-Log "GitHub connection failed. Please check your credentials." -Level ERROR
        return
    }

    # Get configuration
    $config = Get-IntegrationConfig

    # Get Jira project info if specified
    if ($JiraProject) {
        $projectInfo = Get-JiraProjectWorkflow -ProjectKey $JiraProject
        if ($projectInfo) {
            $report.JiraProjectInfo = $projectInfo
        }
    }

    # Configure organization secrets
    if ($ConfigureSecrets) {
        Write-Log "Configuring organization secrets..."

        $secrets = @{
            "JIRA_BASE_URL" = $JiraUrl
            "JIRA_USER_EMAIL" = $JiraEmail
            "JIRA_API_TOKEN" = $JiraApiToken
        }

        if ($JiraProject) {
            $secrets["JIRA_PROJECT_KEY"] = $JiraProject
        }

        foreach ($secret in $secrets.GetEnumerator()) {
            if (Set-OrganizationSecret -SecretName $secret.Key -SecretValue $secret.Value) {
                $report.Actions.SecretsConfigured += @{
                    Name = $secret.Key
                    Level = "Organization"
                    Status = "Success"
                }
                $report.Summary.SecretsConfigured++
            }
            else {
                $report.Actions.Errors += "Failed to set organization secret: $($secret.Key)"
                $report.Summary.Errors++
            }
        }
    }

    # Get repositories to configure
    $repositories = Get-GitHubRepositories

    if ($repositories.Count -eq 0) {
        Write-Log "No repositories found to configure" -Level WARNING
        return
    }

    # Deploy workflows
    if ($DeployWorkflows) {
        Write-Log "Deploying Jira integration workflows..."

        $workflowTypes = $config.workflows
        if (-not $workflowTypes) {
            $workflowTypes = @("jira-issue-transition", "jira-create-issue", "jira-sync-status", "jira-release-notes")
        }

        foreach ($repo in $repositories) {
            Write-Log "Processing repository: $($repo.name)"
            $report.Summary.RepositoriesProcessed++

            foreach ($workflowType in $workflowTypes) {
                $workflowContent = New-JiraIntegrationWorkflow -WorkflowType $workflowType -Config $config

                if ($workflowContent) {
                    if (Deploy-WorkflowToRepository -Repository $repo.name -WorkflowName $workflowType -WorkflowContent $workflowContent) {
                        $report.Actions.WorkflowsDeployed += @{
                            Repository = $repo.name
                            Workflow = $workflowType
                            Status = "Success"
                        }
                        $report.Summary.WorkflowsDeployed++
                    }
                    else {
                        $report.Actions.Errors += "Failed to deploy $workflowType to $($repo.name)"
                        $report.Summary.Errors++
                    }
                }
            }
        }
    }

    # Generate report
    $report.EndTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $report | ConvertTo-Json -Depth 10 | Out-File $script:ReportFile -Encoding UTF8

    # Display summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Integration Setup Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Repositories Processed: $($report.Summary.RepositoriesProcessed)" -ForegroundColor White
    Write-Host "Secrets Configured:     $($report.Summary.SecretsConfigured)" -ForegroundColor Green
    Write-Host "Workflows Deployed:     $($report.Summary.WorkflowsDeployed)" -ForegroundColor Green
    Write-Host "Errors:                 $($report.Summary.Errors)" -ForegroundColor $(if ($report.Summary.Errors -gt 0) { "Red" } else { "Green" })
    Write-Host ""
    Write-Host "Log file:    $script:LogFile" -ForegroundColor Gray
    Write-Host "Report file: $script:ReportFile" -ForegroundColor Gray
    Write-Host ""

    if ($report.Summary.WorkflowsDeployed -gt 0) {
        Write-Host "Next Steps:" -ForegroundColor Yellow
        Write-Host "1. Verify workflows are enabled in each repository's Actions settings" -ForegroundColor White
        Write-Host "2. Ensure branch protection rules allow GitHub Actions" -ForegroundColor White
        Write-Host "3. Test the integration by creating a PR with a Jira issue key" -ForegroundColor White
        Write-Host "4. Use branch naming convention: feature/PROJ-123-description" -ForegroundColor White
        Write-Host ""
    }
}

# Run main function
Main
