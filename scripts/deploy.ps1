<#
.SYNOPSIS
    Single provisioning entry point for the BeStrong sandbox stack.

.DESCRIPTION
    Provisions the whole environment from a fresh Pluralsight Azure sandbox in a
    single run. Phases run strictly in order and stop at the first failure:

      1. preflight  - tools on PATH, az login, session discovery, stale .session/ cleanup
      2. bootstrap  - state backend (storage account + tfstate container) inside the
                      playground RG; derive ARM_ACCESS_KEY; write backend.hcl
      3. init       - terraform init of the stack against the session backend
      4. plan       - saved plan (tfplan); stop here with -PlanOnly
      5. apply      - apply the saved plan (~15-25 minutes)
      6. image      - local docker build, push via ACR admin creds, webapp restart
      7. post-apply - Key Vault demo secret; optional SQL schema step via sqlcmd
      8. smoke      - poll /health every 15 s for up to 15 min for HTTP 200 + "status":"ok"

    Windows PowerShell 5.1 compatible. Exit code 0 on full success, 1 on any failure.
    Secrets (ARM_ACCESS_KEY, ACR admin password, SQL password) live only in process
    memory / environment variables and are never written to files or logs.

.PARAMETER PlanOnly
    Stop after phase 4 (plan). Nothing is applied, no image is built.

.PARAMETER SkipImage
    Skip phase 6 (image build/push) when the image was already pushed this session.
    No switch bypasses preflight.

.EXAMPLE
    .\scripts\deploy.ps1

.EXAMPLE
    .\scripts\deploy.ps1 -PlanOnly
#>
[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$SkipImage
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may default to an older TLS for outbound web calls.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Shared helpers - duplicated at the top of each script by design (no module).
# ---------------------------------------------------------------------------

$RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SessionDir    = Join-Path $RepoRoot '.session'
$SessionVars   = Join-Path $SessionDir 'session.auto.tfvars'
$BackendConfig = Join-Path $SessionDir 'backend.hcl'
$BootstrapRoot = Join-Path $RepoRoot 'terraform\bootstrap'
$StackRoot     = Join-Path $RepoRoot 'terraform\stack'

function Write-Banner {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host ("== {0}" -f $Message)
    Write-Host ('=' * 78)
}

function Assert-LastExitCode {
    param([Parameter(Mandatory = $true)][string]$What)
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed (exit code {1})." -f $What, $LASTEXITCODE)
    }
}

function Invoke-Terraform {
    # Runs terraform against a root module directory and fails fast on a
    # non-zero exit code. Uses -chdir so the caller's cwd never matters.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    & terraform ("-chdir={0}" -f $Root) @Arguments
    Assert-LastExitCode ("terraform {0} (root: {1})" -f ($Arguments -join ' '), $Root)
}

function Get-TerraformOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $value = (& terraform ("-chdir={0}" -f $Root) output -raw $Name) -join ''
    Assert-LastExitCode ("terraform output -raw {0} (root: {1})" -f $Name, $Root)
    return ([string]$value).Trim()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    # -----------------------------------------------------------------------
    Write-Banner 'Phase 1/8: preflight'
    # -----------------------------------------------------------------------

    foreach ($tool in @('az', 'terraform', 'docker')) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw ("Required tool '{0}' is not on PATH. Install az CLI, Terraform, and Docker Desktop before deploying." -f $tool)
        }
    }
    Write-Host 'Tools present: az, terraform, docker.'

    $accountJson = (az account show --output json) -join [Environment]::NewLine
    Assert-LastExitCode "'az account show' - are you logged in as the sandbox cloud_user? Run 'az login'"
    $account        = $accountJson | ConvertFrom-Json
    $SubscriptionId = [string]$account.id
    Write-Host ("Subscription: {0} ({1}), user: {2}" -f $account.name, $SubscriptionId, $account.user.name)

    $ResourceGroupName = ((az group list --query "[?contains(name, 'playground-sandbox')].name | [0]" --output tsv) -join '').Trim()
    Assert-LastExitCode "'az group list'"
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw "No resource group matching '*playground-sandbox*' found. Is this really a Pluralsight sandbox subscription?"
    }
    Write-Host ("Playground resource group: {0}" -f $ResourceGroupName)

    $DeployerIp = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org')).Trim()
    if ($DeployerIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw ("Could not discover the deployer public IPv4 address (got '{0}')." -f $DeployerIp)
    }
    Write-Host ("Deployer public IP: {0}" -f $DeployerIp)

    # Leftover .session/ files from an expired sandbox point at a dead
    # subscription; detect and clean before anything else.
    if (Test-Path $SessionVars) {
        $recordedSubscription = ''
        $match = @(Select-String -Path $SessionVars -Pattern 'subscription_id\s*=\s*"([^"]*)"')
        if ($match.Count -gt 0) {
            $recordedSubscription = $match[0].Matches[0].Groups[1].Value
        }
        if ($recordedSubscription -ne $SubscriptionId) {
            Write-Host ("Stale .session/ detected (recorded subscription '{0}' does not match live '{1}') - cleaning." -f $recordedSubscription, $SubscriptionId)
            Remove-Item (Join-Path $SessionDir '*') -Recurse -Force
            if (Test-Path Env:\ARM_ACCESS_KEY) {
                Remove-Item Env:\ARM_ACCESS_KEY
            }
        }
        else {
            Write-Host '.session/ matches the live subscription - keeping it.'
        }
    }

    # Image tag = git short SHA, falling back to "v1" outside a git checkout.
    # cmd /c keeps the expected-failure stderr out of the PowerShell error stream.
    $ImageTag = 'v1'
    $gitSha = cmd /c "git -C ""$RepoRoot"" rev-parse --short HEAD 2>nul"
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($gitSha -join ''))) {
        $ImageTag = ([string]($gitSha -join '')).Trim()
    }
    else {
        Write-Host "Not a git checkout (or git unavailable) - falling back to image tag 'v1'."
    }
    Write-Host ("Image tag: {0}" -f $ImageTag)

    # -----------------------------------------------------------------------
    Write-Banner 'Phase 2/8: bootstrap state backend'
    # -----------------------------------------------------------------------

    if (-not (Test-Path $SessionDir)) {
        New-Item -ItemType Directory -Path $SessionDir | Out-Null
    }

    # session.auto.tfvars is written FIRST, from live discovery - both terraform
    # roots consume it. Coordinates only, never credentials.
    @"
subscription_id     = "$SubscriptionId"
resource_group_name = "$ResourceGroupName"
deployer_ip         = "$DeployerIp"
"@ | Out-File -FilePath $SessionVars -Encoding ascii
    Write-Host ("Wrote {0}" -f $SessionVars)

    $bootstrapState = Join-Path $SessionDir 'bootstrap.tfstate'
    $bootstrapPlan  = Join-Path $SessionDir 'bootstrap.tfplan'
    Invoke-Terraform -Root $BootstrapRoot -Arguments @('init', "-backend-config=path=$bootstrapState", '-reconfigure', '-input=false')
    Invoke-Terraform -Root $BootstrapRoot -Arguments @('plan', "-var-file=$SessionVars", '-input=false', "-out=$bootstrapPlan")
    Invoke-Terraform -Root $BootstrapRoot -Arguments @('apply', '-input=false', $bootstrapPlan)

    $stateResourceGroup  = Get-TerraformOutput -Root $BootstrapRoot -Name 'state_resource_group_name'
    $stateStorageAccount = Get-TerraformOutput -Root $BootstrapRoot -Name 'state_storage_account_name'
    $stateContainer      = Get-TerraformOutput -Root $BootstrapRoot -Name 'state_container_name'

    # Key auth is the working alternative in the sandbox: role assignments are
    # denied, so Entra ID data-plane auth to state blobs is impossible.
    $stateKey = ((az storage account keys list --resource-group $stateResourceGroup --account-name $stateStorageAccount --query '[0].value' --output tsv) -join '').Trim()
    Assert-LastExitCode "'az storage account keys list' (state storage account)"
    if ([string]::IsNullOrWhiteSpace($stateKey)) {
        throw 'Derived state storage account key is empty.'
    }
    $env:ARM_ACCESS_KEY = $stateKey  # process environment only - never written to disk
    $stateKey = $null
    Write-Host 'ARM_ACCESS_KEY derived and exported for this process.'

    # backend.hcl holds names only - the access key travels exclusively via env.
    @"
resource_group_name  = "$stateResourceGroup"
storage_account_name = "$stateStorageAccount"
container_name       = "$stateContainer"
key                  = "bestrong/dev/terraform.tfstate"
"@ | Out-File -FilePath $BackendConfig -Encoding ascii
    Write-Host ("Wrote {0}" -f $BackendConfig)

    # -----------------------------------------------------------------------
    Write-Banner 'Phase 3/8: stack init'
    # -----------------------------------------------------------------------

    # -reconfigure so a new session's backend replaces the previous one without
    # a migration prompt.
    Invoke-Terraform -Root $StackRoot -Arguments @('init', "-backend-config=$BackendConfig", '-reconfigure', '-input=false')

    # -----------------------------------------------------------------------
    Write-Banner 'Phase 4/8: stack plan'
    # -----------------------------------------------------------------------

    Invoke-Terraform -Root $StackRoot -Arguments @('plan', "-var-file=$SessionVars", "-var=image_tag=$ImageTag", '-input=false', '-out=tfplan')

    if ($PlanOnly) {
        Write-Banner 'PlanOnly requested - stopping after plan. Saved plan: terraform\stack\tfplan'
        exit 0
    }

    # -----------------------------------------------------------------------
    Write-Banner 'Phase 5/8: stack apply (expect roughly 15-25 minutes)'
    # -----------------------------------------------------------------------

    Invoke-Terraform -Root $StackRoot -Arguments @('apply', '-input=false', 'tfplan')

    # -----------------------------------------------------------------------
    if ($SkipImage) {
        Write-Banner 'Phase 6/8: image build/push - skipped (-SkipImage)'
    }
    else {
        Write-Banner 'Phase 6/8: build and push sample image'

        $acrName        = Get-TerraformOutput -Root $StackRoot -Name 'acr_name'
        $acrLoginServer = Get-TerraformOutput -Root $StackRoot -Name 'acr_login_server'
        $appName        = Get-TerraformOutput -Root $StackRoot -Name 'app_name'
        $imageRef       = "{0}/bestrong-sample:{1}" -f $acrLoginServer, $ImageTag
        $appDir         = Join-Path $RepoRoot 'app'

        # ACR Tasks are blocked in the sandbox - the build happens locally.
        docker build -t $imageRef $appDir
        Assert-LastExitCode 'docker build'

        # The sandbox denies managed identities and role assignments, so ACR
        # admin login is the only working pull/push path. Credentials stay in
        # process memory only.
        $acrUser = ((az acr credential show --name $acrName --query 'username' --output tsv) -join '').Trim()
        Assert-LastExitCode "'az acr credential show' (username)"
        $acrPassword = ((az acr credential show --name $acrName --query 'passwords[0].value' --output tsv) -join '').Trim()
        Assert-LastExitCode "'az acr credential show' (password)"

        # NOTE: --password-stdin is the textbook form, but the Windows
        # PowerShell 5.1 native-command pipe corrupts the value on its way to
        # docker's stdin (verified live: stdin form gets 401, direct form
        # succeeds with the same credentials). The direct argument is accepted
        # here: the value is a throwaway sandbox admin credential that dies
        # with the 4-hour session, and it is never written to files or logs.
        docker login $acrLoginServer --username $acrUser --password $acrPassword
        Assert-LastExitCode 'docker login'
        $acrPassword = $null

        docker push $imageRef
        Assert-LastExitCode 'docker push'

        az webapp restart --name $appName --resource-group $ResourceGroupName --output none
        Assert-LastExitCode "'az webapp restart'"
        Write-Host ("Pushed {0} and restarted {1}." -f $imageRef, $appName)
    }

    # -----------------------------------------------------------------------
    Write-Banner 'Phase 7/8: post-apply (Key Vault demo secret, optional SQL schema)'
    # -----------------------------------------------------------------------

    $keyVaultName = Get-TerraformOutput -Root $StackRoot -Name 'key_vault_name'

    # Demonstrates operator write access through the KV firewall from the
    # allowlisted deployer IP. --output none: never echo secrets.
    $timestamp = Get-Date -Format s
    az keyvault secret set --vault-name $keyVaultName --name demo-operator-secret --value ("deploy-ps1-{0}" -f $timestamp) --output none
    Assert-LastExitCode "'az keyvault secret set' (demo-operator-secret)"
    Write-Host 'Demo secret demo-operator-secret set in Key Vault.'

    if ($null -ne (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        $sqlFqdn       = Get-TerraformOutput -Root $StackRoot -Name 'sql_server_fqdn'
        $sqlAdminLogin = Get-TerraformOutput -Root $StackRoot -Name 'sql_admin_login'
        $sqlDatabase   = Get-TerraformOutput -Root $StackRoot -Name 'sql_database_name'

        $sqlPassword = ((az keyvault secret show --vault-name $keyVaultName --name sql-admin-password --query 'value' --output tsv) -join '').Trim()
        Assert-LastExitCode "'az keyvault secret show' (sql-admin-password)"

        # Idempotent schema step: create-or-skip guard.
        $schemaQuery = "IF OBJECT_ID('dbo.HealthProbe') IS NULL CREATE TABLE dbo.HealthProbe (Id INT IDENTITY PRIMARY KEY, ProbedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());"
        sqlcmd -S $sqlFqdn -d $sqlDatabase -U $sqlAdminLogin -P $sqlPassword -Q $schemaQuery -l 30 -b
        Assert-LastExitCode 'sqlcmd (minimal schema step)'
        $sqlPassword = $null
        Write-Host 'Minimal SQL schema applied (dbo.HealthProbe present).'
    }
    else {
        Write-Host 'sqlcmd not found on PATH - skipping the optional SQL schema step (install sqlcmd and re-run to include it).'
    }

    # -----------------------------------------------------------------------
    Write-Banner 'Phase 8/8: smoke - poll /health'
    # -----------------------------------------------------------------------

    $appHostname = Get-TerraformOutput -Root $StackRoot -Name 'app_default_hostname'
    $healthUrl   = "https://{0}/health" -f $appHostname
    $pollSeconds    = 15
    $timeoutMinutes = 15
    $deadline   = (Get-Date).AddMinutes($timeoutMinutes)
    $healthy    = $false
    $lastStatus = '(no response received)'

    Write-Host ("Polling {0} every {1} s for up to {2} minutes (first container pull can take a few minutes)..." -f $healthUrl, $pollSeconds, $timeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 30
            $lastStatus = "HTTP {0}: {1}" -f [int]$response.StatusCode, $response.Content
            if ([int]$response.StatusCode -eq 200 -and $response.Content -match '"status"\s*:\s*"ok"') {
                $healthy = $true
                break
            }
        }
        catch {
            # Non-2xx responses throw in PowerShell 5.1; read the body if present.
            $lastStatus = $_.Exception.Message
            if ($null -ne $_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                    if (-not [string]::IsNullOrWhiteSpace($body)) {
                        $lastStatus = $body
                    }
                }
                catch { }
            }
        }
        Write-Host ("  not healthy yet at {0:HH:mm:ss} - retrying in {1} s" -f (Get-Date), $pollSeconds)
        Start-Sleep -Seconds $pollSeconds
    }

    if (-not $healthy) {
        throw ("Smoke check failed: /health did not return HTTP 200 with status 'ok' within {0} minutes. Last status: {1}" -f $timeoutMinutes, $lastStatus)
    }
    Write-Host ("Smoke check passed: {0}" -f $lastStatus)

    Write-Banner 'deploy.ps1 SUCCEEDED'
    Write-Host ("App URL: https://{0}" -f $appHostname)
    Write-Host 'Next: scripts\test.ps1 (acceptance suite), scripts\destroy.ps1 (teardown).'
    exit 0
}
catch {
    Write-Host ''
    Write-Host ("deploy.ps1 FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Re-running deploy.ps1 after fixing the cause is safe (P2 - re-runnable from zero).'
    exit 1
}
