# Permissions Matrix and Security Requirements

## Overview

This document provides a comprehensive breakdown of the permissions and security requirements for the Azure DevOps to GitHub Enterprise Cloud migration process. It covers both the survey/assessment phase and the actual migration execution.

## Permission Requirements by Phase

### Phase 0: Prerequisites Check
**Azure DevOps**: Read-only access
- **Purpose**: Validate connectivity and token functionality
- **Minimum Scopes**: Code (Read), Project and Team (Read)

**GitHub**: Read-only access  
- **Purpose**: Validate organization access and token functionality
- **Minimum Scopes**: repo (read), org:read

### Phase 1: Assessment & Inventory (Survey Phase)
**Azure DevOps**: Read-only access
- **Purpose**: Gather comprehensive organization data
- **Required Scopes**:
  - Code: Read (repository enumeration)
  - Build: Read (pipeline analysis)
  - Release: Read (release pipeline analysis)
  - Project and Team: Read (organization structure)
  - User Profile: Read (user information)

**GitHub**: No permissions required (survey phase)

### Phase 2: Identity Mapping
**Azure DevOps**: Read-only access
- **Purpose**: Extract user and group information
- **Required Scopes**: Same as Phase 1

**GitHub**: Read-only access
- **Purpose**: Enumerate organization members and teams
- **Required Scopes**: 
  - org:read (organization information)
  - repo:read (repository access for team validation)

### Phase 3: Repository Migration
**Azure DevOps**: Read-only access
- **Purpose**: Read repository data for migration
- **Required Scopes**: Same as Phase 1 (read-only sufficient)

**GitHub**: Full write access
- **Purpose**: Create repositories, push code, configure settings
- **Required Scopes**:
  - repo (full repository access)
  - admin:org (organization management)
  - admin:public_key (deploy keys)
  - admin:gpg_key (commit signing)

### Phase 4: Pipeline Analysis & Conversion
**Azure DevOps**: Read-only access
- **Purpose**: Analyze pipeline configurations
- **Required Scopes**: Same as Phase 1

**GitHub**: Write access for workflows
- **Purpose**: Create GitHub Actions workflows
- **Required Scopes**: 
  - repo (workflow creation)
  - workflow (Actions management)

### Phase 5: Security Configuration
**GitHub**: Administrative access
- **Purpose**: Configure branch protection, security features
- **Required Scopes**:
  - repo (branch protection)
  - admin:org (organization security settings)
  - security_events (security scanning)

### Phase 6: DevSecOps Integration
**GitHub**: Write access for workflows and secrets
- **Purpose**: Deploy security tool workflows
- **Required Scopes**:
  - repo (workflow deployment)
  - admin:org (organization secrets)
  - security_events (security tool integration)

## Security Token Configuration

### Azure DevOps Personal Access Token (PAT)

**Token Creation Steps**:
1. Navigate to Azure DevOps → User Settings → Personal Access Tokens
2. Click "New Token"
3. Configure with appropriate scopes (see phase requirements above)
4. Set expiration date (recommend 90-180 days)
5. Copy token immediately (cannot be retrieved later)

**Minimum Required Scopes**:
```
✓ Code: Read
✓ Build: Read  
✓ Release: Read
✓ Project and Team: Read
✓ User Profile: Read
```

**Recommended Additional Scopes** (for future flexibility):
```
✓ Code: Read & Write
✓ Build: Read & Execute
✓ Release: Read & Execute
```

### GitHub Personal Access Token

**Token Creation Steps**:
1. Navigate to GitHub Settings → Developer Settings → Personal Access Tokens
2. Click "Generate new token (classic)"
3. Select appropriate scopes (see phase requirements above)
4. Set expiration date
5. Copy token immediately

**Required Scopes for Full Migration**:
```
✓ repo (full control of private repositories)
✓ admin:org (full control of organizations)
✓ workflow (update GitHub Action workflows)
✓ write:packages (upload packages to GitHub Package Registry)
✓ delete:packages (delete packages from GitHub Package Registry)
✓ admin:public_key (manage public keys)
✓ admin:gpg_key (manage GPG keys)
```

## Identity Provider Configuration

### Entra ID (Azure AD) Requirements

**For SCIM Provisioning**:
- **Role**: Global Administrator or User Administrator
- **Purpose**: Configure automatic user provisioning to GitHub
- **Permissions**: User lifecycle management, group management

**For SSO Configuration**:
- **Role**: Application Administrator or Global Administrator
- **Purpose**: Configure SAML/SSO integration between Entra ID and GitHub
- **Permissions**: Enterprise application management, SAML configuration

## External Security Tool Requirements

### SonarQube Cloud
- **Token Type**: User Authentication Token
- **Generation**: https://sonarcloud.io/account/security/
- **Required Scopes**: Analysis permissions for the organization
- **Storage**: GitHub Secret named `SONAR_TOKEN`

### Black Duck (Synopsys)
- **Token Type**: API Token
- **Generation**: Black Duck instance admin interface
- **Required Permissions**: Project creation, scan upload
- **Storage**: GitHub Secrets named `BLACKDUCK_URL` and `BLACKDUCK_API_TOKEN`

### Trivy Server (Optional)
- **Token Type**: Bearer Token
- **Generation**: Trivy server configuration
- **Required Permissions**: Scan execution, result upload
- **Storage**: GitHub Secrets named `TRIVY_SERVER_URL` and `TRIVY_TOKEN`

## Security Best Practices

### Token Security
1. **Never commit tokens to code** - Use GitHub Secrets or environment variables
2. **Use least privilege principle** - Grant minimum required permissions
3. **Set expiration dates** - Rotate tokens regularly (90-180 days)
4. **Monitor token usage** - Review access logs for suspicious activity
5. **Use fine-grained tokens** where available instead of classic tokens

### Network Security
1. **Use HTTPS only** - All API calls use encrypted connections
2. **Implement IP allowlisting** - Restrict token usage to specific IP ranges
3. **Enable audit logging** - Track all API access and changes
4. **Use private networks** - Prefer private endpoints over public internet

### Access Control
1. **Separate survey and migration tokens** - Use different tokens for different phases
2. **Implement approval workflows** - Require approval for migration execution
3. **Use service accounts** - Prefer service accounts over personal accounts
4. **Enable MFA** - Multi-factor authentication for all admin accounts

## Compliance Considerations

### Data Residency
- **Azure DevOps**: Data remains in original region during survey
- **GitHub**: Configure data residency settings in GitHub Enterprise
- **External Tools**: Verify data residency for security scanning tools

### Audit Requirements
- **Token Usage**: Log all API calls and token usage
- **Permission Changes**: Track permission modifications
- **Access Reviews**: Regular review of granted permissions
- **Compliance Reporting**: Generate compliance reports for auditors

## Troubleshooting Permissions

### Common Issues
1. **"401 Unauthorized"**: Check token expiration and scopes
2. **"403 Forbidden"**: Verify organization membership and roles
3. **"404 Not Found"**: Confirm resource existence and access rights
4. **Rate Limiting**: Implement retry logic and rate limit handling

### Diagnostic Commands
```bash
# Test Azure DevOps PAT
curl -H "Authorization: Basic $(echo -n ":$ADO_PAT" | base64)" \
  "https://dev.azure.com/$ADO_ORG/_apis/projects"

# Test GitHub Token
curl -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/user"

# Test GitHub Organization Access
curl -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/orgs/$GH_ORG"
```

## Migration-Specific Security Considerations

### Pre-Migration
1. **Backup Verification**: Ensure ADO backups are current and tested
2. **Access Audit**: Review current permissions and access patterns
3. **Security Assessment**: Identify security configurations to migrate
4. **Compliance Review**: Ensure migration meets regulatory requirements

### During Migration
1. **Monitoring**: Real-time monitoring of migration progress
2. **Access Logging**: Comprehensive logging of all migration activities
3. **Error Handling**: Graceful handling of permission failures
4. **Rollback Planning**: Maintain ability to revert changes if needed

### Post-Migration
1. **Access Review**: Verify all permissions are correctly configured
2. **Security Validation**: Confirm security tools are properly integrated
3. **Audit Trail**: Maintain complete audit trail of migration activities
4. **Ongoing Monitoring**: Continuous monitoring of access and permissions

This comprehensive permissions matrix ensures that the migration factory operates with the minimum required permissions while maintaining security and compliance standards throughout the process.