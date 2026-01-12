# Troubleshooting Guide

## Common Issues and Solutions

### 1. Authentication Issues

#### Problem: "Authentication failed" or "401 Unauthorized"
**Symptoms**: Scripts fail with authentication errors when connecting to Azure DevOps or GitHub.

**Solutions**:
1. **Verify PAT tokens**:
   ```powershell
   # Test Azure DevOps PAT
   $response = Invoke-RestMethod -Uri "https://dev.azure.com/YOUR_ORG/_apis/projects" -Headers @{Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":YOUR_PAT")))"}
   
   # Test GitHub token
   gh auth status
   ```

2. **Check token permissions**:
   - **Azure DevOps PAT**: Full access or at minimum: Code (read), Build (read), Release (read), Project and Team (read)
   - **GitHub token**: `repo`, `admin:org`, `workflow`, `write:packages`, `delete:packages`, `admin:public_key`, `admin:gpg_key`

3. **Verify token expiration**: Check if tokens have expired and regenerate if necessary.

#### Problem: "Organization not found" or "403 Forbidden"
**Symptoms**: Scripts can't find or access the specified organization.

**Solutions**:
1. Verify organization name spelling and case sensitivity
2. Ensure your account has appropriate permissions in both organizations
3. Check if organization requires SSO authentication

### 2. Repository Migration Issues

#### Problem: "Repository already exists" during migration
**Symptoms**: Migration fails because target repository already exists.

**Solutions**:
1. Use the `-SkipExisting` parameter in `03-migrate-repos.ps1`
2. Manually delete the existing repository if appropriate
3. Use a different target repository name

#### Problem: "Migration failed with exit code: 1"
**Symptoms**: GEI migration fails with generic error.

**Solutions**:
1. **Check identity mappings**: Ensure `gei-mappings.csv` is properly formatted
2. **Verify repository size**: Large repositories may need special handling
3. **Check rate limits**: Reduce batch size with `-BatchSize 1` parameter
4. **Review detailed logs**: Check the migration log file for specific error details

#### Problem: "User mapping failed" or attribution issues
**Symptoms**: Commits and PRs don't have proper user attribution after migration.

**Solutions**:
1. Run `02-generate-mappings.ps1` to create fresh identity mappings
2. Verify email addresses match between ADO and GitHub
3. Check for users who need to claim their mannequin accounts
4. Manually review and update mappings in `identity-mappings.csv`

### 3. Pipeline Conversion Issues

#### Problem: "Pipeline conversion failed" or incomplete conversion
**Symptoms**: ADO pipelines don't convert properly to GitHub Actions.

**Solutions**:
1. **Check pipeline complexity**: Very complex pipelines may need manual conversion
2. **Review unsupported tasks**: Some ADO tasks don't have GitHub Actions equivalents
3. **Verify YAML syntax**: Ensure original ADO YAML is valid
4. **Use validate-only mode**: Run with `-ValidateOnly` first to identify issues

#### Problem: "Classic pipeline detected" warning
**Symptoms**: Classic release pipelines can't be automatically converted.

**Solutions**:
1. Plan for manual redesign of classic pipelines
2. Use the pipeline analysis report to understand complexity
3. Consider using GitHub environments for deployment stages
4. Review migration guide for conversion patterns

#### Problem: "Workflow validation failed"
**Symptoms**: Converted workflows have syntax errors or missing elements.

**Solutions**:
1. **Check YAML syntax**: Use a YAML validator on converted files
2. **Verify action availability**: Ensure all referenced actions exist in GitHub Marketplace
3. **Review variable usage**: Convert ADO variables to GitHub secrets/context
4. **Update triggers**: Ensure workflow triggers are properly configured

### 4. Security Configuration Issues

#### Problem: "Branch protection configuration failed"
**Symptoms**: Security script fails to apply branch protection rules.

**Solutions**:
1. **Check default branch**: Ensure repository has a default branch (main/master)
2. **Verify permissions**: Ensure token has admin permissions on repositories
3. **Review branch protection template**: Validate JSON syntax in template file
4. **Check for existing protection**: Branch protection may already be configured

#### Problem: "Advanced security features not available"
**Symptoms**: Can't enable GitHub Advanced Security features.

**Solutions**:
1. **Verify GitHub Enterprise licensing**: Advanced Security requires appropriate licensing
2. **Check organization settings**: Ensure features are enabled at organization level
3. **Review repository visibility**: Some features require public repositories or specific licensing
4. **Contact GitHub support**: For licensing or feature availability issues

#### Problem: "Team permissions configuration failed"
**Symptoms**: Can't configure team access to repositories.

**Solutions**:
1. **Verify team existence**: Ensure teams exist in the GitHub organization
2. **Check team permissions**: Ensure you have admin access to manage teams
3. **Review team names**: Verify team names are spelled correctly
4. **Check organization membership**: Ensure users are members of the organization

### 5. Performance and Rate Limiting Issues

#### Problem: "Rate limit exceeded" or "API throttling"
**Symptoms**: Scripts fail due to API rate limits.

**Solutions**:
1. **Reduce batch size**: Use smaller `-BatchSize` values
2. **Add delays**: Increase delay between operations
3. **Use different tokens**: Rotate between multiple PATs if available
4. **Schedule during off-peak hours**: Run migrations during low-usage periods

#### Problem: "Operation timed out" or slow performance
**Symptoms**: Scripts run very slowly or timeout.

**Solutions**:
1. **Check network connectivity**: Ensure stable internet connection
2. **Optimize batch processing**: Adjust batch sizes for your environment
3. **Monitor resource usage**: Ensure adequate CPU/memory on execution machine
4. **Use parallel processing**: Enable parallel execution where appropriate

### 6. Environment and Configuration Issues

#### Problem: "Module not found" or "Command not recognized"
**Symptoms**: PowerShell scripts fail with module/command errors.

**Solutions**:
1. **Install required modules**:
   ```powershell
   Install-Module -Name Az -AllowClobber -Force
   Install-Module -Name PowerShellGet -Force
   ```

2. **Update PowerShell**: Ensure PowerShell Core 7.x is installed
3. **Install GitHub CLI and extensions**:
   ```bash
   gh extension install github/gh-gei
   gh extension install github/gh-actions-importer
   ```

4. **Check execution policy**: Set appropriate execution policy
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

#### Problem: "Environment variable not found"
**Symptoms**: Scripts can't find required environment variables.

**Solutions**:
1. **Verify .env file**: Ensure `.env` file exists and is properly formatted
2. **Check variable names**: Ensure no typos in variable names
3. **Load environment variables**: Scripts should load .env file automatically
4. **Use absolute paths**: Try using absolute paths for file references

## Diagnostic Commands

### Check Azure DevOps Connectivity
```powershell
$adoPat = $env:ADO_PAT
$adoOrg = $env:ADO_ORG
$authHeader = @{Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat")))"}
Invoke-RestMethod -Uri "https://dev.azure.com/$adoOrg/_apis/projects" -Headers $authHeader
```

### Check GitHub Authentication
```bash
gh auth status
gh api user --jq '.login'
```

### Verify GEI Extension
```bash
gh extension list | grep gei
gh gei --help
```

### Test Actions Importer
```bash
gh extension list | grep actions-importer
gh actions-importer --help
```

### Check PowerShell Version
```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable Az.*
```

## Getting Help

### Log Files
- Check `logs/` directory for detailed execution logs
- Look for files with timestamps matching your execution
- Review both success and failure logs for context

### Error Reporting
When reporting issues, include:
1. **Script name and version**
2. **Full error message and stack trace**
3. **Environment details** (PowerShell version, OS, etc.)
4. **Relevant log file excerpts**
5. **Steps to reproduce the issue**

### Support Resources
- **GitHub Enterprise Support**: For GitHub-related issues
- **Azure DevOps Support**: For ADO-specific problems
- **GitHub Community**: For general GitHub Actions questions
- **Microsoft Documentation**: For Azure DevOps API issues

## Prevention Best Practices

### Before Migration
1. **Test in non-production**: Always test scripts in a dev/test environment first
2. **Validate prerequisites**: Ensure all tools and permissions are in place
3. **Backup data**: Maintain backups of critical repositories and configurations
4. **Plan rollback**: Have rollback procedures ready

### During Migration
1. **Monitor progress**: Watch logs and reports for early issue detection
2. **Validate results**: Check each phase before proceeding to the next
3. **Document issues**: Keep records of any problems and solutions
4. **Communicate**: Keep stakeholders informed of progress and issues

### After Migration
1. **Verify functionality**: Test all migrated repositories and workflows
2. **Update documentation**: Reflect new GitHub-based processes
3. **Train users**: Ensure teams understand new workflows
4. **Monitor performance**: Watch for issues in the new environment