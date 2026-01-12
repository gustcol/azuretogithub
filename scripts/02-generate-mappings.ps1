<#
.SYNOPSIS
    Identity Mapping Generator for Azure DevOps to GitHub Migration
.DESCRIPTION
    This script generates identity mappings between Azure DevOps users and GitHub accounts.
    It creates the necessary configuration for GitHub's mannequin system to properly
    attribute commits, PRs, and issues during migration.
.PARAMETER AdoOrg
    Azure DevOps organization name
.PARAMETER AdoPat
    Azure DevOps Personal Access Token
.PARAMETER GhOrg
    GitHub organization name
.PARAMETER GhToken
    GitHub Personal Access Token
.PARAMETER MappingFile
    Output file for identity mappings (default: ./reports/identity-mappings.csv)
.EXAMPLE
    ./02-generate-mappings.ps1 -AdoOrg "myorg" -AdoPat "ado-pat" -GhOrg "myghorg" -GhToken "gh-pat"
#>

[CmdletBinding()]
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
    [string]$MappingFile = "./reports/identity-mappings.csv"
)

# Set error handling
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Create reports directory if it doesn't exist
$reportsDir = Split-Path $MappingFile -Parent
if (!(Test-Path $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}

# Initialize logging
$logFile = Join-Path $reportsDir "identity-mapping-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

# API base URLs
$adoBaseUrl = "https://dev.azure.com/$AdoOrg"
$ghBaseUrl = "https://api.github.com"
$apiVersion = "7.1-preview.1"

# Authentication headers
$adoAuthHeader = @{
    "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")))"
    "Content-Type" = "application/json"
}

$ghAuthHeader = @{
    "Authorization" = "token $GhToken"
    "Accept" = "application/vnd.github.v3+json"
}

Write-Log "Starting identity mapping generation for ADO: $AdoOrg -> GitHub: $GhOrg"

# Function to get ADO users
function Get-AdoUsers {
    Write-Log "Fetching Azure DevOps users..."
    
    $url = "$adoBaseUrl/_apis/graph/users?api-version=$apiVersion"
    
    try {
        $response = Invoke-RestMethod -Uri $url -Method GET -Headers $adoAuthHeader
        
        $users = @()
        foreach ($user in $response.value) {
            if ($user.mailAddress -and $user.displayName) {
                $users += [PSCustomObject]@{
                    AdoUserId = $user.descriptor
                    DisplayName = $user.displayName
                    Email = $user.mailAddress.ToLower()
                    PrincipalName = $user.principalName
                    SubjectKind = $user.subjectKind
                    Origin = $user.origin
                    OriginId = $user.originId
                }
            }
        }
        
        Write-Log "Found $($users.Count) ADO users"
        return $users
    }
    catch {
        Write-Log "Error fetching ADO users: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# Function to get GitHub organization members
function Get-GitHubMembers {
    Write-Log "Fetching GitHub organization members..."
    
    $url = "$ghBaseUrl/orgs/$GhOrg/members?per_page=100"
    $members = @()
    
    do {
        try {
            $response = Invoke-RestMethod -Uri $url -Method GET -Headers $ghAuthHeader
            
            foreach ($member in $response) {
                # Get user details
                $userUrl = "$ghBaseUrl/users/$($member.login)"
                $userDetails = Invoke-RestMethod -Uri $userUrl -Method GET -Headers $ghAuthHeader
                
                $members += [PSCustomObject]@{
                    GitHubLogin = $member.login
                    GitHubId = $member.id
                    Email = $userDetails.email?.ToLower()
                    Name = $userDetails.name
                    Company = $userDetails.company
                    Location = $userDetails.location
                    AvatarUrl = $userDetails.avatar_url
                    HtmlUrl = $userDetails.html_url
                }
            }
            
            # Check for pagination
            $url = $null
            if ($response.Headers.Link) {
                $links = $response.Headers.Link -split ','
                foreach ($link in $links) {
                    if ($link -match '<([^>]+)>; rel="next"') {
                        $url = $matches[1]
                        break
                    }
                }
            }
        }
        catch {
            Write-Log "Error fetching GitHub members: $($_.Exception.Message)" "ERROR"
            break
        }
    } while ($url)
    
    Write-Log "Found $($members.Count) GitHub organization members"
    return $members
}

# Function to get GitHub organization teams
function Get-GitHubTeams {
    Write-Log "Fetching GitHub organization teams..."
    
    $url = "$ghBaseUrl/orgs/$GhOrg/teams?per_page=100"
    
    try {
        $teams = Invoke-RestMethod -Uri $url -Method GET -Headers $ghAuthHeader
        
        $teamList = @()
        foreach ($team in $teams) {
            $teamList += [PSCustomObject]@{
                TeamId = $team.id
                TeamName = $team.name
                Slug = $team.slug
                Description = $team.description
                Privacy = $team.privacy
                Permission = $team.permission
                MembersCount = $team.members_count
                ReposCount = $team.repos_count
                HtmlUrl = $team.html_url
            }
        }
        
        Write-Log "Found $($teamList.Count) GitHub teams"
        return $teamList
    }
    catch {
        Write-Log "Error fetching GitHub teams: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# Function to perform email-based matching
function Find-EmailMatches {
    param([array]$AdoUsers, [array]$GitHubMembers)
    
    Write-Log "Performing email-based user matching..."
    
    $matches = @()
    $unmatchedAdo = @()
    
    foreach ($adoUser in $AdoUsers) {
        $matched = $false
        
        # Try exact email match
        $ghMatch = $GitHubMembers | Where-Object { $_.Email -eq $adoUser.Email }
        
        if ($ghMatch) {
            $matches += [PSCustomObject]@{
                AdoUserId = $adoUser.AdoUserId
                AdoDisplayName = $adoUser.DisplayName
                AdoEmail = $adoUser.Email
                AdoPrincipalName = $adoUser.PrincipalName
                GitHubLogin = $ghMatch.GitHubLogin
                GitHubId = $ghMatch.GitHubId
                GitHubEmail = $ghMatch.Email
                GitHubName = $ghMatch.Name
                MatchType = "Email"
                Confidence = "High"
                Notes = "Exact email match"
            }
            $matched = $true
        }
        
        if (!$matched) {
            $unmatchedAdo += $adoUser
        }
    }
    
    Write-Log "Found $($matches.Count) exact email matches"
    return @{
        Matches = $matches
        UnmatchedAdo = $unmatchedAdo
    }
}

# Function to perform fuzzy name matching
function Find-NameMatches {
    param([array]$UnmatchedAdo, [array]$GitHubMembers)
    
    Write-Log "Performing fuzzy name-based matching..."
    
    $matches = @()
    $remainingUnmatched = @()
    
    foreach ($adoUser in $UnmatchedAdo) {
        $bestMatch = $null
        $bestScore = 0
        
        foreach ($ghMember in $GitHubMembers) {
            # Calculate similarity score
            $nameScore = Get-StringSimilarity -String1 $adoUser.DisplayName -String2 $ghMember.Name
            $emailScore = Get-StringSimilarity -String1 $adoUser.Email -String2 $ghMember.Email
            
            # Combined score with weights
            $combinedScore = ($nameScore * 0.7) + ($emailScore * 0.3)
            
            if ($combinedScore -gt $bestScore -and $combinedScore -gt 0.7) {
                $bestScore = $combinedScore
                $bestMatch = $ghMember
            }
        }
        
        if ($bestMatch) {
            $confidence = if ($bestScore -gt 0.9) { "High" } elseif ($bestScore -gt 0.8) { "Medium" } else { "Low" }
            
            $matches += [PSCustomObject]@{
                AdoUserId = $adoUser.AdoUserId
                AdoDisplayName = $adoUser.DisplayName
                AdoEmail = $adoUser.Email
                AdoPrincipalName = $adoUser.PrincipalName
                GitHubLogin = $bestMatch.GitHubLogin
                GitHubId = $bestMatch.GitHubId
                GitHubEmail = $bestMatch.Email
                GitHubName = $bestMatch.Name
                MatchType = "Fuzzy"
                Confidence = $confidence
                Notes = "Name similarity score: $($bestScore.ToString('0.00'))"
            }
        }
        else {
            $remainingUnmatched += $adoUser
        }
    }
    
    Write-Log "Found $($matches.Count) fuzzy name matches"
    return @{
        Matches = $matches
        RemainingUnmatched = $remainingUnmatched
    }
}

# Function to calculate string similarity
function Get-StringSimilarity {
    param([string]$String1, [string]$String2)
    
    if ([string]::IsNullOrEmpty($String1) -or [string]::IsNullOrEmpty($String2)) {
        return 0
    }
    
    # Simple Levenshtein distance implementation
    $len1 = $String1.Length
    $len2 = $String2.Length
    
    if ($len1 -eq 0) { return $len2 }
    if ($len2 -eq 0) { return $len1 }
    
    $matrix = New-Object 'int[,]' ($len1 + 1), ($len2 + 1)
    
    for ($i = 0; $i -le $len1; $i++) { $matrix[$i, 0] = $i }
    for ($j = 0; $j -le $len2; $j++) { $matrix[0, $j] = $j }
    
    for ($i = 1; $i -le $len1; $i++) {
        for ($j = 1; $j -le $len2; $j++) {
            $cost = if ($String1[$i - 1] -eq $String2[$j - 1]) { 0 } else { 1 }
            
            $matrix[$i, $j] = [Math]::Min(
                [Math]::Min(
                    $matrix[$i - 1, $j] + 1,      # deletion
                    $matrix[$i, $j - 1] + 1       # insertion
                ),
                $matrix[$i - 1, $j - 1] + $cost   # substitution
            )
        }
    }
    
    $distance = $matrix[$len1, $len2]
    $maxLen = [Math]::Max($len1, $len2)
    
    return 1 - ($distance / $maxLen)
}

# Function to generate mannequin mapping for unmatched users
function Generate-MannequinMapping {
    param([array]$UnmatchedUsers)
    
    Write-Log "Generating mannequin mappings for $($UnmatchedUsers.Count) unmatched users..."
    
    $mannequins = @()
    
    foreach ($user in $UnmatchedUsers) {
        $mannequinLogin = "mannequin-$($user.AdoUserId.Substring(0, 8))"
        
        $mannequins += [PSCustomObject]@{
            AdoUserId = $user.AdoUserId
            AdoDisplayName = $user.DisplayName
            AdoEmail = $user.Email
            MannequinLogin = $mannequinLogin
            MannequinEmail = "$mannequinLogin@mannequin.github.com"
            ClaimToken = [Guid]::NewGuid().ToString()
            Notes = "Unmatched user - requires manual claim"
        }
    }
    
    return $mannequins
}

# Function to generate team mapping recommendations
function Generate-TeamMappings {
    param([array]$AdoUsers, [array]$GitHubTeams)
    
    Write-Log "Generating team mapping recommendations..."
    
    $teamMappings = @()
    
    # Simple heuristic: look for common team name patterns
    foreach ($ghTeam in $GitHubTeams) {
        $teamMappings += [PSCustomObject]@{
            GitHubTeamName = $ghTeam.TeamName
            GitHubTeamSlug = $ghTeam.Slug
            RecommendedAdoGroups = @() # Would need ADO groups API to populate
            Notes = "Manual review required"
        }
    }
    
    return $teamMappings
}

# Main execution
try {
    Write-Log "=== Identity Mapping Generation Started ==="
    
    # Get users from both systems
    $adoUsers = Get-AdoUsers
    $gitHubMembers = Get-GitHubMembers
    $gitHubTeams = Get-GitHubTeams
    
    Write-Log "Starting user matching process..."
    
    # Phase 1: Email-based matching
    $emailResults = Find-EmailMatches -AdoUsers $adoUsers -GitHubMembers $gitHubMembers
    $emailMatches = $emailResults.Matches
    $unmatchedAfterEmail = $emailResults.UnmatchedAdo
    
    # Phase 2: Fuzzy name matching
    $nameResults = Find-NameMatches -UnmatchedAdo $unmatchedAfterEmail -GitHubMembers $gitHubMembers
    $nameMatches = $nameResults.Matches
    $remainingUnmatched = $nameResults.RemainingUnmatched
    
    # Combine all matches
    $allMatches = $emailMatches + $nameMatches
    
    # Generate mannequin mappings for remaining unmatched users
    $mannequins = Generate-MannequinMapping -UnmatchedUsers $remainingUnmatched
    
    # Generate team mapping recommendations
    $teamMappings = Generate-TeamMappings -AdoUsers $adoUsers -GitHubTeams $gitHubTeams
    
    # Create comprehensive mapping report
    $mappingReport = [PSCustomObject]@{
        GenerationDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AdoOrganization = $AdoOrg
        GitHubOrganization = $GhOrg
        TotalAdoUsers = $adoUsers.Count
        TotalGitHubMembers = $gitHubMembers.Count
        TotalGitHubTeams = $gitHubTeams.Count
        EmailMatches = $emailMatches.Count
        NameMatches = $nameMatches.Count
        TotalMatches = $allMatches.Count
        MannequinsRequired = $mannequins.Count
        MatchPercentage = [Math]::Round(($allMatches.Count / $adoUsers.Count) * 100, 2)
    }
    
    # Export results
    Write-Log "Exporting mapping results..."
    
    # User mappings
    $allMatches | Export-Csv -Path $MappingFile -NoTypeInformation
    Write-Log "User mappings saved: $MappingFile"
    
    # Mannequin mappings
    $mannequinFile = $MappingFile -replace "identity-mappings", "mannequin-mappings"
    $mannequins | Export-Csv -Path $mannequinFile -NoTypeInformation
    Write-Log "Mannequin mappings saved: $mannequinFile"
    
    # Team mappings
    $teamMappingFile = $MappingFile -replace "identity-mappings", "team-mappings"
    $teamMappings | Export-Csv -Path $teamMappingFile -NoTypeInformation
    Write-Log "Team mappings saved: $teamMappingFile"
    
    # Summary report
    $summaryFile = $MappingFile -replace "identity-mappings", "mapping-summary"
    $mappingReport | ConvertTo-Json -Depth 10 | Out-File "$summaryFile.json"
    Write-Log "Summary report saved: $summaryFile.json"
    
    # Generate GEI mapping file format
    $geiMappingFile = $MappingFile -replace "identity-mappings", "gei-mappings"
    $geiMappings = @()
    
    foreach ($match in $allMatches) {
        $geiMappings += [PSCustomObject]@{
            login = $match.GitHubLogin
            email = $match.GitHubEmail
            name = $match.GitHubName
            source_user_id = $match.AdoUserId
            source_username = $match.AdoDisplayName
        }
    }
    
    foreach ($mannequin in $mannequins) {
        $geiMappings += [PSCustomObject]@{
            login = $mannequin.MannequinLogin
            email = $mannequin.MannequinEmail
            name = $mannequin.AdoDisplayName
            source_user_id = $mannequin.AdoUserId
            source_username = $mannequin.AdoDisplayName
        }
    }
    
    $geiMappings | Export-Csv -Path $geiMappingFile -NoTypeInformation
    Write-Log "GEI-compatible mappings saved: $geiMappingFile"
    
    # Display summary
    Write-Log "=== Identity Mapping Summary ===" "INFO"
    Write-Log "ADO Users: $($mappingReport.TotalAdoUsers)" "INFO"
    Write-Log "GitHub Members: $($mappingReport.TotalGitHubMembers)" "INFO"
    Write-Log "Successful Matches: $($mappingReport.TotalMatches) ($($mappingReport.MatchPercentage)%)" "INFO"
    Write-Log "Email Matches: $($mappingReport.EmailMatches)" "INFO"
    Write-Log "Name Matches: $($mappingReport.NameMatches)" "INFO"
    Write-Log "Mannequins Required: $($mappingReport.MannequinsRequired)" "INFO"
    Write-Log "GitHub Teams: $($mappingReport.TotalGitHubTeams)" "INFO"
    
    # Provide recommendations
    Write-Log "=== Recommendations ===" "INFO"
    
    if ($remainingUnmatched.Count -gt 0) {
        Write-Log "Review unmatched users in mannequin-mappings.csv" "WARNING"
        Write-Log "Users need to claim their mannequin accounts after migration" "WARNING"
    }
    
    if ($nameMatches.Count -gt 0) {
        Write-Log "Review fuzzy name matches for accuracy" "WARNING"
    }
    
    Write-Log "=== Identity Mapping Completed Successfully ==="
    
}
catch {
    Write-Log "Identity mapping failed: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}