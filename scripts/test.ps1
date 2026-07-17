<#
.SYNOPSIS
    Acceptance suite for a deployed BeStrong sandbox environment.

.DESCRIPTION
    Verifies a deployed environment end to end. Three stages:

      1. Positive checks  - /health over HTTPS plus az control-plane assertions
                            on the deployed security configuration.
      2. Negative probes  - bounded rule-flips for SQL / Key Vault / Storage:
                            temporarily remove the deployer-IP allow rule, expect
                            the data-plane call to FAIL, restore the exact rule in
                            a finally block. ACR: anonymous GET /v2/ expects 401.
                            A successful connection during a probe window is a
                            SECURITY FAILURE of the suite.
      3. Final checks     - remote state blob exists; terraform plan
                            -detailed-exitcode returns 0 ("No changes"), which
                            also proves the probes restored every rule exactly.

    The rule-flips are the only cloud mutations this script performs; the snet-app
    VNet rules are never touched, so the app stays healthy throughout.

    Windows PowerShell 5.1 compatible. Prints a summary table; exit code 0 only
    when every check passes, 1 otherwise.

.EXAMPLE
    .\scripts\test.ps1
#>
[CmdletBinding()]
param()

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

function Get-ConfigValue {
    # Reads a `name = "value"` assignment from session.auto.tfvars / backend.hcl.
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $match = @(Select-String -Path $File -Pattern ('^\s*' + [regex]::Escape($Name) + '\s*=\s*"([^"]*)"'))
    if ($match.Count -eq 0) {
        throw ("Value '{0}' not found in {1}." -f $Name, $File)
    }
    return $match[0].Matches[0].Groups[1].Value
}

function Get-AzJson {
    # az call returning parsed JSON; throws on a non-zero exit code.
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$What
    )
    $raw = (& az @Arguments --output json) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed (exit code {1})." -f $What, $LASTEXITCODE)
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

function Get-AzTsv {
    # az call returning a single trimmed TSV value; throws on a non-zero exit code.
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$What
    )
    $raw = (& az @Arguments --output tsv) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed (exit code {1})." -f $What, $LASTEXITCODE)
    }
    return ([string]$raw).Trim()
}

function Invoke-ExpectedFailure {
    # Runs a command line via cmd.exe with all output suppressed (the failure is
    # the expected outcome - its error text is noise). Returns $true when the
    # command FAILED (non-zero exit code).
    param([Parameter(Mandatory = $true)][string]$CommandLine)
    cmd /c "$CommandLine >nul 2>nul"
    return ($LASTEXITCODE -ne 0)
}

# ---------------------------------------------------------------------------
# Test-specific helpers
# ---------------------------------------------------------------------------

$script:Results          = New-Object System.Collections.ArrayList
$script:HealthJson       = $null
$script:WebApp           = $null
$script:WebConfig        = $null
$script:DeployedImageTag = ''
$ProbeWaitSeconds        = 30   # firewall-change propagation before each probe

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Req,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string]$Detail = ''
    )
    $result = $(if ($Passed) { 'PASS' } else { 'FAIL' })
    [void]$script:Results.Add([pscustomobject]@{
        Id     = $Id
        Req    = $Req
        Type   = $Type
        Result = $result
        Check  = $Name
        Detail = $Detail
    })
    if ($Passed) {
        Write-Host ("  [PASS] {0} {1}" -f $Id, $Name) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] {0} {1} - {2}" -f $Id, $Name, $Detail) -ForegroundColor Red
    }
}

function Invoke-Check {
    # Runs a check body that returns @($passed, $detail); an exception inside the
    # body records a FAIL and the suite continues (the summary decides the exit code).
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Req,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $passed = $false
    $detail = ''
    try {
        $r = & $Body
        $passed = [bool]$r[0]
        if (@($r).Count -gt 1) {
            $detail = [string]$r[1]
        }
    }
    catch {
        $passed = $false
        $detail = $_.Exception.Message
    }
    Add-Result -Id $Id -Req $Req -Type $Type -Name $Name -Passed $passed -Detail $detail
}

function Test-SqlLogin {
    # Attempts a real SQL login + SELECT 1. Returns $true when the login SUCCEEDS.
    # Prefers sqlcmd; falls back to System.Data.SqlClient (a TCP connect + TDS
    # login) when sqlcmd is absent.
    param(
        [Parameter(Mandatory = $true)][string]$ServerFqdn,
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutSec = 15
    )
    if ($null -ne (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        # random_password uses special = false, so the value is cmd-safe.
        cmd /c "sqlcmd -S $ServerFqdn -d $Database -U $User -P $Password -Q ""SELECT 1"" -l $TimeoutSec -b >nul 2>nul"
        return ($LASTEXITCODE -eq 0)
    }
    # Pooling=False is load-bearing for the negative probe: with the default
    # pool, a connection authenticated BEFORE the firewall rule was removed is
    # silently reused by later attempts (no new TDS login, no firewall
    # re-evaluation), making the probe report success forever. Azure SQL
    # firewall rules only affect NEW logins. ClearAllPools additionally drops
    # anything pooled by earlier checks in this same process.
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    $connectionString = "Server=tcp:$ServerFqdn,1433;Initial Catalog=$Database;User ID=$User;Password=$Password;Encrypt=True;TrustServerCertificate=False;Connection Timeout=$TimeoutSec;Pooling=False"
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT 1'
        [void]$command.ExecuteScalar()
        return $true
    }
    catch {
        return $false
    }
    finally {
        $connection.Dispose()
    }
}

function Test-DiagnosticSetting {
    # $true when at least one diagnostic setting on the resource targets the
    # given Log Analytics workspace.
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$WorkspaceName
    )
    $settings = Get-AzJson -Arguments @('monitor', 'diagnostic-settings', 'list', '--resource', $ResourceId) -What "'az monitor diagnostic-settings list'"
    if ($null -ne $settings -and $null -ne $settings.PSObject.Properties['value']) {
        $settings = $settings.value   # older az returns { value: [...] }
    }
    foreach ($setting in @($settings)) {
        if ($null -eq $setting) { continue }
        if ($null -ne $setting.workspaceId -and [string]$setting.workspaceId -match [regex]::Escape($WorkspaceName)) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Setup: session context and coordinates from terraform outputs
# ---------------------------------------------------------------------------

try {
    Write-Banner 'test.ps1: setup and coordinates'

    foreach ($tool in @('az', 'terraform')) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw ("Required tool '{0}' is not on PATH." -f $tool)
        }
    }

    $liveSubscription = Get-AzTsv -Arguments @('account', 'show', '--query', 'id') -What "'az account show' - run 'az login' as the sandbox cloud_user"

    if (-not (Test-Path $SessionVars)) {
        throw '.session\session.auto.tfvars not found - run scripts\deploy.ps1 first.'
    }
    if (-not (Test-Path $BackendConfig)) {
        throw '.session\backend.hcl not found - run scripts\deploy.ps1 first.'
    }

    $recordedSubscription = Get-ConfigValue -File $SessionVars -Name 'subscription_id'
    $ResourceGroupName    = Get-ConfigValue -File $SessionVars -Name 'resource_group_name'
    $DeployerIp           = Get-ConfigValue -File $SessionVars -Name 'deployer_ip'
    if ($recordedSubscription -ne $liveSubscription) {
        throw ("Stale .session/: recorded subscription '{0}' does not match live '{1}'. Re-run scripts\deploy.ps1." -f $recordedSubscription, $liveSubscription)
    }

    $StateResourceGroup  = Get-ConfigValue -File $BackendConfig -Name 'resource_group_name'
    $StateStorageAccount = Get-ConfigValue -File $BackendConfig -Name 'storage_account_name'
    $StateContainer      = Get-ConfigValue -File $BackendConfig -Name 'container_name'
    $StateBlobKey        = Get-ConfigValue -File $BackendConfig -Name 'key'

    if ([string]::IsNullOrEmpty($env:ARM_ACCESS_KEY)) {
        Write-Host 'ARM_ACCESS_KEY not set in this shell - deriving it from the state storage account.'
        $env:ARM_ACCESS_KEY = Get-AzTsv -Arguments @('storage', 'account', 'keys', 'list', '--resource-group', $StateResourceGroup, '--account-name', $StateStorageAccount, '--query', '[0].value') -What "'az storage account keys list' (state storage account)"
    }

    $outputsRaw = (& terraform ("-chdir={0}" -f $StackRoot) output -json) -join [Environment]::NewLine
    Assert-LastExitCode "terraform output -json - has the stack been deployed via scripts\deploy.ps1?"
    $tfOutputs = $outputsRaw | ConvertFrom-Json

    $AppName        = [string]$tfOutputs.app_name.value
    $AppHostname    = [string]$tfOutputs.app_default_hostname.value
    $AcrName        = [string]$tfOutputs.acr_name.value
    $AcrLoginServer = [string]$tfOutputs.acr_login_server.value
    $KeyVaultName   = [string]$tfOutputs.key_vault_name.value
    $SqlServerName  = [string]$tfOutputs.sql_server_name.value
    $SqlServerFqdn  = [string]$tfOutputs.sql_server_fqdn.value
    $SqlAdminLogin  = [string]$tfOutputs.sql_admin_login.value
    $SqlDatabase    = [string]$tfOutputs.sql_database_name.value
    $StorageAccount = [string]$tfOutputs.storage_account_name.value
    $FileShareName  = [string]$tfOutputs.file_share_name.value
    $LogWorkspace   = [string]$tfOutputs.log_analytics_workspace_name.value
    $AppInsights    = [string]$tfOutputs.application_insights_name.value   # "" when the flag is off
    if ([string]::IsNullOrWhiteSpace($AppName)) {
        throw 'terraform outputs are empty - deploy the stack first (scripts\deploy.ps1).'
    }
    $HealthUrl = "https://{0}/health" -f $AppHostname

    Write-Host ("Target: RG={0}, app={1}, deployer IP={2}" -f $ResourceGroupName, $AppName, $DeployerIp)

    # -----------------------------------------------------------------------
    Write-Banner 'Stage 1: positive checks (L2)'
    # -----------------------------------------------------------------------

    Invoke-Check -Id 'P01' -Req 'R1' -Type 'Positive' -Name 'GET /health returns HTTP 200 with status "ok"' -Body {
        $response = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 60
        $script:HealthJson = $response.Content | ConvertFrom-Json
        $ok = ([int]$response.StatusCode -eq 200 -and [string]$script:HealthJson.status -eq 'ok')
        @($ok, ("HTTP {0}, body: {1}" -f [int]$response.StatusCode, $response.Content))
    }

    Invoke-Check -Id 'P02' -Req 'R1' -Type 'Positive' -Name 'Web app: HTTPS-only, no managed identity' -Body {
        $script:WebApp = Get-AzJson -Arguments @('webapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroupName) -What "'az webapp show'"
        $problems = @()
        if (-not $script:WebApp.httpsOnly) {
            $problems += ("httpsOnly={0}" -f $script:WebApp.httpsOnly)
        }
        $identityType = ''
        if ($null -ne $script:WebApp.identity) {
            $identityType = [string]$script:WebApp.identity.type
        }
        if ($identityType -ne '' -and $identityType -ne 'None') {
            $problems += ("unexpected managed identity '{0}' (enable_app_identity is flag-gated off in the sandbox)" -f $identityType)
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    Invoke-Check -Id 'P03' -Req 'R1' -Type 'Positive' -Name 'Web app config: TLS 1.2, FTPS disabled, VNet route-all' -Body {
        $script:WebConfig = Get-AzJson -Arguments @('webapp', 'config', 'show', '--name', $AppName, '--resource-group', $ResourceGroupName) -What "'az webapp config show'"
        $problems = @()
        if ([string]$script:WebConfig.minTlsVersion -ne '1.2') {
            $problems += ("minTlsVersion={0}" -f $script:WebConfig.minTlsVersion)
        }
        if ([string]$script:WebConfig.ftpsState -ne 'Disabled') {
            $problems += ("ftpsState={0}" -f $script:WebConfig.ftpsState)
        }
        if (-not $script:WebConfig.vnetRouteAllEnabled) {
            $problems += ("vnetRouteAllEnabled={0}" -f $script:WebConfig.vnetRouteAllEnabled)
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    Invoke-Check -Id 'P04' -Req 'R1/R5' -Type 'Positive' -Name 'Web app VNet integration bound to snet-app' -Body {
        $integrations = @((Get-AzJson -Arguments @('webapp', 'vnet-integration', 'list', '--name', $AppName, '--resource-group', $ResourceGroupName) -What "'az webapp vnet-integration list'") | Where-Object { $null -ne $_ })
        $ok = ($integrations.Count -eq 1 -and [string]$integrations[0].vnetResourceId -match '/subnets/snet-app$')
        $ids = @($integrations | ForEach-Object { [string]$_.vnetResourceId })
        @($ok, ("integrations: {0}" -f ($ids -join ', ')))
    }

    Invoke-Check -Id 'P05' -Req 'R2' -Type 'Positive' -Name '/health "insights" consistent with the App Insights flag' -Body {
        if ($null -eq $script:HealthJson) {
            throw 'no /health JSON captured (P01 failed)'
        }
        $insights = [string]$script:HealthJson.insights
        $expected = $(if ($AppInsights -ne '') { 'ok' } else { 'disabled' })
        @(($insights -eq $expected), ("insights='{0}', expected '{1}' (application_insights_name='{2}')" -f $insights, $expected, $AppInsights))
    }

    Invoke-Check -Id 'P06' -Req 'R2' -Type 'Positive' -Name 'Diagnostic settings target the LAW (app, SQL DB, KV, ACR, storage files)' -Body {
        $resourceIds = @{}
        $resourceIds['app-service']  = [string]$script:WebApp.id
        if ([string]::IsNullOrEmpty($resourceIds['app-service'])) {
            $resourceIds['app-service'] = Get-AzTsv -Arguments @('webapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroupName, '--query', 'id') -What "'az webapp show' (id)"
        }
        $resourceIds['sql-database'] = Get-AzTsv -Arguments @('sql', 'db', 'show', '--resource-group', $ResourceGroupName, '--server', $SqlServerName, '--name', $SqlDatabase, '--query', 'id') -What "'az sql db show' (id)"
        $resourceIds['key-vault']    = Get-AzTsv -Arguments @('keyvault', 'show', '--name', $KeyVaultName, '--query', 'id') -What "'az keyvault show' (id)"
        $resourceIds['acr']          = Get-AzTsv -Arguments @('acr', 'show', '--name', $AcrName, '--query', 'id') -What "'az acr show' (id)"
        $storageId = Get-AzTsv -Arguments @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroupName, '--query', 'id') -What "'az storage account show' (id)"
        $resourceIds['storage-files'] = "{0}/fileServices/default" -f $storageId
        $problems = @()
        foreach ($key in $resourceIds.Keys) {
            if (-not (Test-DiagnosticSetting -ResourceId $resourceIds[$key] -WorkspaceName $LogWorkspace)) {
                $problems += $key
            }
        }
        $detail = $(if ($problems.Count -gt 0) { 'missing/mistargeted diagnostics: ' + ($problems -join ', ') } else { 'all five wired to ' + $LogWorkspace })
        @(($problems.Count -eq 0), $detail)
    }

    Invoke-Check -Id 'P07' -Req 'R3' -Type 'Positive' -Name 'ACR: Basic SKU, admin user enabled (documented deviation)' -Body {
        $acr = Get-AzJson -Arguments @('acr', 'show', '--name', $AcrName) -What "'az acr show'"
        $problems = @()
        if ([string]$acr.sku.name -ne 'Basic') {
            $problems += ("sku={0}" -f $acr.sku.name)
        }
        if (-not $acr.adminUserEnabled) {
            $problems += ("adminUserEnabled={0}" -f $acr.adminUserEnabled)
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    Invoke-Check -Id 'P08' -Req 'R3' -Type 'Positive' -Name 'Web app runs the bestrong-sample image from our ACR' -Body {
        $linuxFx = ''
        if ($null -ne $script:WebConfig) {
            $linuxFx = [string]$script:WebConfig.linuxFxVersion
        }
        if ($linuxFx -eq '') {
            $linuxFx = Get-AzTsv -Arguments @('webapp', 'config', 'show', '--name', $AppName, '--resource-group', $ResourceGroupName, '--query', 'linuxFxVersion') -What "'az webapp config show' (linuxFxVersion)"
        }
        $expectedPrefix = "DOCKER|{0}/bestrong-sample:" -f $AcrLoginServer
        $ok = $linuxFx.StartsWith($expectedPrefix)
        if ($ok) {
            $script:DeployedImageTag = $linuxFx.Substring($expectedPrefix.Length)
        }
        @($ok, ("linuxFxVersion={0}" -f $linuxFx))
    }

    Invoke-Check -Id 'P09' -Req 'R3' -Type 'Positive' -Name 'ACR repository bestrong-sample holds the deployed tag' -Body {
        if ([string]::IsNullOrEmpty($script:DeployedImageTag)) {
            throw 'deployed tag unknown (P08 failed)'
        }
        $tags = @((Get-AzJson -Arguments @('acr', 'repository', 'show-tags', '--name', $AcrName, '--repository', 'bestrong-sample') -What "'az acr repository show-tags'") | Where-Object { $null -ne $_ })
        $ok = ($tags -contains $script:DeployedImageTag)
        @($ok, ("deployed tag '{0}'; registry tags: {1}" -f $script:DeployedImageTag, ($tags -join ', ')))
    }

    Invoke-Check -Id 'P10' -Req 'R4' -Type 'Positive' -Name 'Key Vault: default Deny firewall, access-policy model' -Body {
        $kv = Get-AzJson -Arguments @('keyvault', 'show', '--name', $KeyVaultName) -What "'az keyvault show'"
        $problems = @()
        if ([string]$kv.properties.networkAcls.defaultAction -ne 'Deny') {
            $problems += ("networkAcls.defaultAction={0}" -f $kv.properties.networkAcls.defaultAction)
        }
        if ($kv.properties.enableRbacAuthorization) {
            $problems += 'enableRbacAuthorization=true (expected the access-policy model - the sandbox cannot grant data-plane roles)'
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    Invoke-Check -Id 'P11' -Req 'R4' -Type 'Positive' -Name 'Key Vault secrets present (sql-admin-password, demo-operator-secret)' -Body {
        $secrets = @((Get-AzJson -Arguments @('keyvault', 'secret', 'list', '--vault-name', $KeyVaultName) -What "'az keyvault secret list'") | Where-Object { $null -ne $_ })
        $names = @($secrets | ForEach-Object { [string]$_.name })
        $ok = (($names -contains 'sql-admin-password') -and ($names -contains 'demo-operator-secret'))
        @($ok, ("secrets: {0}" -f ($names -join ', ')))
    }

    Invoke-Check -Id 'P12' -Req 'R5' -Type 'Positive' -Name 'VNet topology: expected address space, subnets, delegation, endpoints' -Body {
        $vnet = Get-AzJson -Arguments @('network', 'vnet', 'show', '--resource-group', $ResourceGroupName, '--name', 'vnet-bestrong-dev') -What "'az network vnet show'"
        $problems = @()
        if (@($vnet.addressSpace.addressPrefixes) -notcontains '10.20.0.0/16') {
            $problems += ("address space: {0}" -f (@($vnet.addressSpace.addressPrefixes) -join ', '))
        }
        $snetApp = @($vnet.subnets | Where-Object { $_.name -eq 'snet-app' })
        if ($snetApp.Count -ne 1) {
            $problems += 'snet-app missing'
        }
        else {
            $subnet = $snetApp[0]
            if ([string]$subnet.addressPrefix -ne '10.20.1.0/24') {
                $problems += ("snet-app prefix={0}" -f $subnet.addressPrefix)
            }
            if (@($subnet.delegations | ForEach-Object { [string]$_.serviceName }) -notcontains 'Microsoft.Web/serverFarms') {
                $problems += 'snet-app missing Microsoft.Web/serverFarms delegation'
            }
            $endpoints = @($subnet.serviceEndpoints | ForEach-Object { [string]$_.service })
            foreach ($required in @('Microsoft.Sql', 'Microsoft.KeyVault', 'Microsoft.Storage')) {
                if ($endpoints -notcontains $required) {
                    $problems += ("snet-app missing service endpoint {0}" -f $required)
                }
            }
        }
        $snetPe = @($vnet.subnets | Where-Object { $_.name -eq 'snet-private-endpoints' })
        if ($snetPe.Count -ne 1) {
            $problems += 'snet-private-endpoints missing'
        }
        elseif ([string]$snetPe[0].addressPrefix -ne '10.20.2.0/24') {
            $problems += ("snet-private-endpoints prefix={0}" -f $snetPe[0].addressPrefix)
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    Invoke-Check -Id 'P13' -Req 'R5' -Type 'Positive' -Name 'Zero private endpoints in the baseline (one SQL PE only when flagged)' -Body {
        $endpoints = @((Get-AzJson -Arguments @('network', 'private-endpoint', 'list', '--resource-group', $ResourceGroupName) -What "'az network private-endpoint list'") | Where-Object { $null -ne $_ })
        if ($endpoints.Count -eq 0) {
            @($true, 'no private endpoints (baseline)')
        }
        elseif ($endpoints.Count -eq 1 -and [string]$endpoints[0].name -match 'sql') {
            @($true, ("one SQL private endpoint '{0}' (enable_sql_private_endpoint experiment)" -f $endpoints[0].name))
        }
        else {
            $names = @($endpoints | ForEach-Object { [string]$_.name })
            @($false, ("unexpected private endpoints: {0}" -f ($names -join ', ')))
        }
    }

    Invoke-Check -Id 'P14' -Req 'R6' -Type 'Positive' -Name '/health "sql" is "ok" (SELECT 1 over the VNet path)' -Body {
        if ($null -eq $script:HealthJson) {
            throw 'no /health JSON captured (P01 failed)'
        }
        @(([string]$script:HealthJson.sql -eq 'ok'), ("sql='{0}'" -f $script:HealthJson.sql))
    }

    Invoke-Check -Id 'P15' -Req 'R6' -Type 'Positive' -Name 'SQL server: TLS 1.2, public access enabled (documented deviation)' -Body {
        $sqlServer = Get-AzJson -Arguments @('sql', 'server', 'show', '--resource-group', $ResourceGroupName, '--name', $SqlServerName) -What "'az sql server show'"
        $problems = @()
        if ([string]$sqlServer.minimalTlsVersion -ne '1.2') {
            $problems += ("minimalTlsVersion={0}" -f $sqlServer.minimalTlsVersion)
        }
        if ([string]$sqlServer.publicNetworkAccess -ne 'Enabled') {
            $problems += ("publicNetworkAccess={0} (expected 'Enabled' - the sandbox blocks private endpoints, so firewall/VNet rules restrict access instead)" -f $sqlServer.publicNetworkAccess)
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    Invoke-Check -Id 'P16' -Req 'R6' -Type 'Positive' -Name 'SQL firewall: exactly one VNet rule + one deployer-ip rule, no 0.0.0.0' -Body {
        $vnetRules = @((Get-AzJson -Arguments @('sql', 'server', 'vnet-rule', 'list', '--resource-group', $ResourceGroupName, '--server', $SqlServerName) -What "'az sql server vnet-rule list'") | Where-Object { $null -ne $_ })
        $fwRules   = @((Get-AzJson -Arguments @('sql', 'server', 'firewall-rule', 'list', '--resource-group', $ResourceGroupName, '--server', $SqlServerName) -What "'az sql server firewall-rule list'") | Where-Object { $null -ne $_ })
        $problems = @()
        if ($vnetRules.Count -ne 1) {
            $problems += ("{0} VNet rules (expected 1)" -f $vnetRules.Count)
        }
        elseif ([string]$vnetRules[0].virtualNetworkSubnetId -notmatch '/subnets/snet-app$') {
            $problems += ("VNet rule bound to {0} (expected snet-app)" -f $vnetRules[0].virtualNetworkSubnetId)
        }
        if ($fwRules.Count -ne 1) {
            $names = @($fwRules | ForEach-Object { [string]$_.name })
            $problems += ("{0} IP rules (expected exactly 1: deployer-ip): {1}" -f $fwRules.Count, ($names -join ', '))
        }
        else {
            $rule = $fwRules[0]
            if ([string]$rule.name -ne 'deployer-ip' -or [string]$rule.startIpAddress -ne $DeployerIp -or [string]$rule.endIpAddress -ne $DeployerIp) {
                $problems += ("rule {0} {1}-{2} (expected deployer-ip {3}-{3})" -f $rule.name, $rule.startIpAddress, $rule.endIpAddress, $DeployerIp)
            }
        }
        foreach ($rule in $fwRules) {
            if ([string]$rule.startIpAddress -eq '0.0.0.0') {
                $problems += ("0.0.0.0 'Allow Azure services' rule present: {0}" -f $rule.name)
            }
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    Invoke-Check -Id 'P17' -Req 'R7' -Type 'Positive' -Name '/health "fileshare" is "ok" (write/read/delete under the mount)' -Body {
        if ($null -eq $script:HealthJson) {
            throw 'no /health JSON captured (P01 failed)'
        }
        @(([string]$script:HealthJson.fileshare -eq 'ok'), ("fileshare='{0}'" -f $script:HealthJson.fileshare))
    }

    Invoke-Check -Id 'P18' -Req 'R7' -Type 'Positive' -Name 'Storage: default Deny, snet-app + deployer IP only, HTTPS, TLS1_2' -Body {
        $storage = Get-AzJson -Arguments @('storage', 'account', 'show', '--name', $StorageAccount, '--resource-group', $ResourceGroupName) -What "'az storage account show'"
        $problems = @()
        if ([string]$storage.networkRuleSet.defaultAction -ne 'Deny') {
            $problems += ("defaultAction={0}" -f $storage.networkRuleSet.defaultAction)
        }
        $ipRules = @($storage.networkRuleSet.ipRules | ForEach-Object { [string]$_.ipAddressOrRange })
        if ($ipRules -notcontains $DeployerIp) {
            $problems += ("deployer IP {0} not in ipRules ({1})" -f $DeployerIp, ($ipRules -join ', '))
        }
        $subnetRules = @($storage.networkRuleSet.virtualNetworkRules | ForEach-Object { [string]$_.virtualNetworkResourceId })
        $snetAppRule = @($subnetRules | Where-Object { $_ -match '/subnets/snet-app$' })
        if ($snetAppRule.Count -ne 1) {
            $problems += ("snet-app VNet rule not found ({0})" -f ($subnetRules -join ', '))
        }
        if (-not $storage.enableHttpsTrafficOnly) {
            $problems += ("enableHttpsTrafficOnly={0}" -f $storage.enableHttpsTrafficOnly)
        }
        if ([string]$storage.minimumTlsVersion -ne 'TLS1_2') {
            $problems += ("minimumTlsVersion={0}" -f $storage.minimumTlsVersion)
        }
        @(($problems.Count -eq 0), ($problems -join '; '))
    }

    # -----------------------------------------------------------------------
    Write-Banner 'Stage 2: negative probes (L3) - bounded rule-flips, auto-restored'
    # -----------------------------------------------------------------------
    Write-Host 'Expected outcome: every data-plane attempt below FAILS while the deployer'
    Write-Host 'rule is removed. The snet-app rules are never touched - the app stays healthy.'

    # Fetch data-plane credentials while the deployer IP is still allowlisted.
    $SqlPassword = $null
    $StorageKey  = $null
    try {
        $SqlPassword = Get-AzTsv -Arguments @('keyvault', 'secret', 'show', '--vault-name', $KeyVaultName, '--name', 'sql-admin-password', '--query', 'value') -What "'az keyvault secret show' (sql-admin-password)"
        $StorageKey  = Get-AzTsv -Arguments @('storage', 'account', 'keys', 'list', '--resource-group', $ResourceGroupName, '--account-name', $StorageAccount, '--query', '[0].value') -What "'az storage account keys list' (app storage)"
    }
    catch {
        Write-Host ("WARNING: could not pre-fetch data-plane credentials for the probes: {0}" -f $_.Exception.Message)
    }

    # --- N1: SQL - remove deployer-ip rule, login must fail, recreate rule ---
    $n1Passed = $false
    $n1Detail = ''
    if ([string]::IsNullOrEmpty($SqlPassword)) {
        $n1Detail = 'skipped: SQL admin password could not be read from Key Vault'
    }
    else {
        $sqlRuleRemoved = $false
        try {
            az sql server firewall-rule delete --resource-group $ResourceGroupName --server $SqlServerName --name deployer-ip --output none
            Assert-LastExitCode "'az sql server firewall-rule delete' (deployer-ip)"
            $sqlRuleRemoved = $true
            # SQL firewall rule changes can take up to ~5 minutes to reach the
            # gateway (observed live: a probe fired 30 s after the delete still
            # rode the cached ALLOW). Poll until the login is refused; only a
            # login still accepted after the full window is a real finding.
            Write-Host '  N1: deployer-ip SQL rule removed; polling until the gateway refuses the login (up to 4 min)...'
            $n1Deadline = (Get-Date).AddSeconds(240)
            $n1Denied = $false
            while (-not $n1Denied) {
                if (Test-SqlLogin -ServerFqdn $SqlServerFqdn -Database $SqlDatabase -User $SqlAdminLogin -Password $SqlPassword -TimeoutSec 15) {
                    if ((Get-Date) -ge $n1Deadline) { break }
                    Write-Host '  N1: login still accepted - firewall change not propagated yet; retrying in 20 s...'
                    Start-Sleep -Seconds 20
                }
                else {
                    $n1Denied = $true
                }
            }
            if ($n1Denied) {
                $n1Passed = $true
                $n1Detail = 'SQL connection refused without the deployer-ip rule, as expected (after gateway propagation)'
            }
            else {
                $n1Detail = 'SECURITY FAILURE: SQL login still succeeded 4 minutes after the deployer-ip rule was removed'
            }
        }
        catch {
            $n1Detail = $_.Exception.Message
        }
        finally {
            if ($sqlRuleRemoved) {
                # Restore the exact Terraform-managed name and value.
                az sql server firewall-rule create --resource-group $ResourceGroupName --server $SqlServerName --name deployer-ip --start-ip-address $DeployerIp --end-ip-address $DeployerIp --output none
                if ($LASTEXITCODE -ne 0) {
                    $n1Passed = $false
                    $n1Detail = $n1Detail + ' | RESTORE FAILED: recreate the deployer-ip rule or re-run terraform apply'
                }
                else {
                    Write-Host '  N1: deployer-ip SQL rule restored.'
                }
            }
        }
    }
    Add-Result -Id 'N1' -Req 'R6' -Type 'Negative' -Name 'SQL data plane denied from a non-allowlisted IP' -Passed $n1Passed -Detail $n1Detail

    # --- N2: Key Vault - remove IP rule, secret list must fail, add it back ---
    $n2Passed = $false
    $n2Detail = ''
    $kvRuleRemoved = $false
    try {
        az keyvault network-rule remove --resource-group $ResourceGroupName --name $KeyVaultName --ip-address $DeployerIp --output none
        Assert-LastExitCode "'az keyvault network-rule remove'"
        $kvRuleRemoved = $true
        Write-Host ("  N2: deployer IP removed from the Key Vault firewall; waiting {0} s..." -f $ProbeWaitSeconds)
        Start-Sleep -Seconds $ProbeWaitSeconds
        $denied = Invoke-ExpectedFailure -CommandLine ("az keyvault secret list --vault-name {0}" -f $KeyVaultName)
        if ($denied) {
            $n2Passed = $true
            $n2Detail = 'Key Vault data plane denied without the deployer IP rule, as expected'
        }
        else {
            $n2Detail = 'SECURITY FAILURE: Key Vault secret list succeeded from a non-allowlisted IP'
        }
    }
    catch {
        $n2Detail = $_.Exception.Message
    }
    finally {
        if ($kvRuleRemoved) {
            az keyvault network-rule add --resource-group $ResourceGroupName --name $KeyVaultName --ip-address $DeployerIp --output none
            if ($LASTEXITCODE -ne 0) {
                $n2Passed = $false
                $n2Detail = $n2Detail + ' | RESTORE FAILED: re-add the Key Vault IP rule or re-run terraform apply'
            }
            else {
                Write-Host '  N2: Key Vault IP rule restored.'
            }
        }
    }
    Add-Result -Id 'N2' -Req 'R4' -Type 'Negative' -Name 'Key Vault data plane denied from a non-allowlisted IP' -Passed $n2Passed -Detail $n2Detail

    # --- N3: Storage - remove IP rule, file list must fail, add it back ---
    $n3Passed = $false
    $n3Detail = ''
    if ([string]::IsNullOrEmpty($StorageKey)) {
        $n3Detail = 'skipped: storage account key could not be fetched'
    }
    else {
        $stRuleRemoved = $false
        try {
            az storage account network-rule remove --resource-group $ResourceGroupName --account-name $StorageAccount --ip-address $DeployerIp --output none
            Assert-LastExitCode "'az storage account network-rule remove'"
            $stRuleRemoved = $true
            Write-Host ("  N3: deployer IP removed from the storage firewall; waiting {0} s..." -f $ProbeWaitSeconds)
            Start-Sleep -Seconds $ProbeWaitSeconds
            # Key via environment variables so it never appears on a command line.
            $env:AZURE_STORAGE_ACCOUNT = $StorageAccount
            $env:AZURE_STORAGE_KEY     = $StorageKey
            $denied = Invoke-ExpectedFailure -CommandLine ("az storage file list --share-name {0} --num-results 1" -f $FileShareName)
            if ($denied) {
                $n3Passed = $true
                $n3Detail = 'storage data plane denied without the deployer IP rule, as expected'
            }
            else {
                $n3Detail = 'SECURITY FAILURE: storage file list succeeded from a non-allowlisted IP'
            }
        }
        catch {
            $n3Detail = $_.Exception.Message
        }
        finally {
            Remove-Item Env:\AZURE_STORAGE_ACCOUNT -ErrorAction SilentlyContinue
            Remove-Item Env:\AZURE_STORAGE_KEY -ErrorAction SilentlyContinue
            if ($stRuleRemoved) {
                az storage account network-rule add --resource-group $ResourceGroupName --account-name $StorageAccount --ip-address $DeployerIp --output none
                if ($LASTEXITCODE -ne 0) {
                    $n3Passed = $false
                    $n3Detail = $n3Detail + ' | RESTORE FAILED: re-add the storage IP rule or re-run terraform apply'
                }
                else {
                    Write-Host '  N3: storage IP rule restored.'
                }
            }
        }
    }
    Add-Result -Id 'N3' -Req 'R7' -Type 'Negative' -Name 'Storage data plane denied from a non-allowlisted IP' -Passed $n3Passed -Detail $n3Detail

    # --- N4: ACR - anonymous GET /v2/ must return 401. ACR Basic has no network
    # firewall, so authentication is the registry's only boundary. ---
    $n4Passed = $false
    $n4Detail = ''
    try {
        $response = Invoke-WebRequest -Uri ("https://{0}/v2/" -f $AcrLoginServer) -UseBasicParsing -TimeoutSec 30
        $n4Detail = ("SECURITY FAILURE: anonymous /v2/ returned HTTP {0}" -f [int]$response.StatusCode)
    }
    catch {
        $statusCode = 0
        if ($null -ne $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 401) {
            $n4Passed = $true
            $n4Detail = 'anonymous pull refused with HTTP 401, as expected'
        }
        else {
            $n4Detail = ("expected HTTP 401, got: {0}" -f $(if ($statusCode -ne 0) { "HTTP $statusCode" } else { $_.Exception.Message }))
        }
    }
    Add-Result -Id 'N4' -Req 'R3' -Type 'Negative' -Name 'Unauthenticated ACR pull fails (401 on /v2/)' -Passed $n4Passed -Detail $n4Detail

    # -----------------------------------------------------------------------
    Write-Banner 'Stage 3: final checks (R8) - remote state and idempotency'
    # -----------------------------------------------------------------------

    # F1: the state blob exists, read with ARM_ACCESS_KEY.
    $f1Passed = $false
    $f1Detail = ''
    try {
        $env:AZURE_STORAGE_ACCOUNT = $StateStorageAccount
        $env:AZURE_STORAGE_KEY     = $env:ARM_ACCESS_KEY
        $blobMissing = Invoke-ExpectedFailure -CommandLine ("az storage blob show --container-name {0} --name {1}" -f $StateContainer, $StateBlobKey)
        $f1Passed = (-not $blobMissing)
        if ($f1Passed) {
            $f1Detail = ("blob '{0}' present in container '{1}' of {2}" -f $StateBlobKey, $StateContainer, $StateStorageAccount)
        }
        else {
            $f1Detail = 'state blob not found or not readable with ARM_ACCESS_KEY'
        }
    }
    catch {
        $f1Detail = $_.Exception.Message
    }
    finally {
        Remove-Item Env:\AZURE_STORAGE_ACCOUNT -ErrorAction SilentlyContinue
        Remove-Item Env:\AZURE_STORAGE_KEY -ErrorAction SilentlyContinue
    }
    Add-Result -Id 'F1' -Req 'R8' -Type 'Positive' -Name 'Remote state blob exists (bestrong/dev/terraform.tfstate)' -Passed $f1Passed -Detail $f1Detail

    # F2: terraform plan -detailed-exitcode == 0. Runs LAST: "No changes" also
    # proves the negative probes restored every firewall rule exactly. The plan
    # must use the deployed image tag or the tag itself would show as a change.
    $planImageTag = $script:DeployedImageTag
    if ([string]::IsNullOrEmpty($planImageTag)) {
        $planImageTag = 'v1'
        $gitSha = cmd /c "git -C ""$RepoRoot"" rev-parse --short HEAD 2>nul"
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($gitSha -join ''))) {
            $planImageTag = ([string]($gitSha -join '')).Trim()
        }
    }
    $f2Passed = $false
    $f2Detail = ''
    try {
        if (-not (Test-Path (Join-Path $StackRoot '.terraform'))) {
            & terraform ("-chdir={0}" -f $StackRoot) init ("-backend-config={0}" -f $BackendConfig) -reconfigure -input=false
            Assert-LastExitCode 'terraform init (stack)'
        }
        & terraform ("-chdir={0}" -f $StackRoot) plan -detailed-exitcode -input=false ("-var-file={0}" -f $SessionVars) ("-var=image_tag={0}" -f $planImageTag)
        $planExit = $LASTEXITCODE
        if ($planExit -eq 0) {
            $f2Passed = $true
            $f2Detail = 'No changes - environment matches code; probes restored every rule exactly'
        }
        elseif ($planExit -eq 2) {
            $f2Detail = 'plan reports pending changes - drift (an unrestored probe rule, a changed deployer IP, or an image_tag mismatch)'
        }
        else {
            $f2Detail = ("terraform plan errored (exit code {0})" -f $planExit)
        }
    }
    catch {
        $f2Detail = $_.Exception.Message
    }
    Add-Result -Id 'F2' -Req 'R8' -Type 'Positive' -Name 'terraform plan reports "No changes" (idempotency + exact probe restore)' -Passed $f2Passed -Detail $f2Detail

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------

    $failedChecks = @($script:Results | Where-Object { $_.Result -eq 'FAIL' })
    $passedCount  = $script:Results.Count - $failedChecks.Count

    Write-Banner ("Summary: {0}/{1} checks passed" -f $passedCount, $script:Results.Count)
    $script:Results | Format-Table -Property Id, Req, Type, Result, Check, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host

    if ($failedChecks.Count -gt 0) {
        Write-Host ("test.ps1 FAILED: {0} check(s) did not pass." -f $failedChecks.Count) -ForegroundColor Red
        exit 1
    }
    Write-Host 'test.ps1 PASSED: all checks green.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ''
    Write-Host ("test.ps1 FAILED during setup: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($script:Results.Count -gt 0) {
        $script:Results | Format-Table -Property Id, Req, Type, Result, Check, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    }
    exit 1
}
