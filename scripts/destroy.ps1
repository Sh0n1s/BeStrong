<#
.SYNOPSIS
    Teardown entry point for the BeStrong sandbox stack.

.DESCRIPTION
    Tears down everything deploy.ps1 created, in dependency-safe order. Steps:

      1. Confirm      - interactive confirmation naming the target subscription and
                        playground resource group; -Force skips it for unattended runs.
      2. Destroy stack - terraform destroy of terraform/stack (same backend.hcl init
                        and -var-file as deploy). Runs while the backend still exists.
      3. Optional bootstrap teardown - only with -IncludeBootstrap: destroy the
                        state storage account via the bootstrap module's local state.
      4. Local cleanup - remove tfplan, .terraform/ caches, the .session/ directory,
                        and Env:ARM_ACCESS_KEY. Leaves the tree ready for the next
                        session's deploy.ps1 from zero.

    Never deletes the playground resource group itself - it is platform-owned.
    Windows PowerShell 5.1 compatible. Exit code 0 on success, 1 on any failure.

.PARAMETER Force
    Skip the interactive confirmation prompt (unattended runs).

.PARAMETER IncludeBootstrap
    Also destroy the state backend (sttfstate storage account) via the bootstrap
    module. Default keeps it so a follow-up deploy this session reuses it.

.EXAMPLE
    .\scripts\destroy.ps1

.EXAMPLE
    .\scripts\destroy.ps1 -Force -IncludeBootstrap
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$IncludeBootstrap
)

$ErrorActionPreference = 'Stop'

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

function Invoke-LocalCleanup {
    # Removes tfplan, .terraform caches, the .session/ directory, ARM_ACCESS_KEY.
    Write-Banner 'Local cleanup'
    $targets = @(
        (Join-Path $StackRoot 'tfplan'),
        (Join-Path $StackRoot '.terraform'),
        (Join-Path $BootstrapRoot '.terraform'),
        $SessionDir
    )
    foreach ($target in $targets) {
        if (Test-Path $target) {
            Remove-Item $target -Recurse -Force -Confirm:$false
            Write-Host ("Removed {0}" -f $target)
        }
    }
    if (Test-Path Env:\ARM_ACCESS_KEY) {
        Remove-Item Env:\ARM_ACCESS_KEY
        Write-Host 'Cleared ARM_ACCESS_KEY from the process environment.'
    }
    Write-Host "Working tree is ready for the next session's deploy.ps1 from zero."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Banner 'destroy.ps1: BeStrong sandbox teardown'

    foreach ($tool in @('az', 'terraform')) {
        if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw ("Required tool '{0}' is not on PATH." -f $tool)
        }
    }

    if (-not (Test-Path $SessionVars)) {
        Write-Host 'No .session\session.auto.tfvars found - nothing to destroy from this machine.'
        Invoke-LocalCleanup
        Write-Banner 'destroy.ps1 finished (local cleanup only)'
        exit 0
    }

    $recordedSubscription = Get-ConfigValue -File $SessionVars -Name 'subscription_id'
    $ResourceGroupName    = Get-ConfigValue -File $SessionVars -Name 'resource_group_name'

    # Step 1: confirmation naming the target subscription and playground RG.
    if (-not $Force) {
        Write-Host 'This will DESTROY the BeStrong sandbox stack:'
        Write-Host ("  Subscription:   {0}" -f $recordedSubscription)
        Write-Host ("  Resource group: {0} (the RG itself is platform-owned and stays)" -f $ResourceGroupName)
        if ($IncludeBootstrap) {
            Write-Host '  Including the bootstrap state backend (-IncludeBootstrap).'
        }
        $answer = Read-Host "Type 'destroy' to continue"
        if ($answer -ne 'destroy') {
            Write-Host 'Aborted - nothing was destroyed.'
            exit 1
        }
    }

    # Guard against a stale session: destroying against a dead sandbox only
    # produces misleading errors - the platform already wiped everything.
    $liveSubscription = ((az account show --query 'id' --output tsv) -join '').Trim()
    Assert-LastExitCode "'az account show' - run 'az login' as the sandbox cloud_user"
    if ($liveSubscription -ne $recordedSubscription) {
        Write-Host ("Recorded subscription '{0}' does not match live '{1}' - the recorded sandbox has expired and was wiped by the platform." -f $recordedSubscription, $liveSubscription)
        Invoke-LocalCleanup
        Write-Banner 'destroy.ps1 finished (stale session - local cleanup only)'
        exit 0
    }

    # The stack backend authenticates via ARM_ACCESS_KEY; re-derive it when the
    # shell is fresh (e.g. destroy runs in a different console than deploy).
    if ([string]::IsNullOrEmpty($env:ARM_ACCESS_KEY) -and (Test-Path $BackendConfig)) {
        Write-Host 'ARM_ACCESS_KEY not set in this shell - deriving it from the state storage account.'
        $stateResourceGroup  = Get-ConfigValue -File $BackendConfig -Name 'resource_group_name'
        $stateStorageAccount = Get-ConfigValue -File $BackendConfig -Name 'storage_account_name'
        $stateKey = ((az storage account keys list --resource-group $stateResourceGroup --account-name $stateStorageAccount --query '[0].value' --output tsv) -join '').Trim()
        Assert-LastExitCode "'az storage account keys list' (state storage account)"
        if ([string]::IsNullOrWhiteSpace($stateKey)) {
            throw 'Derived state storage account key is empty.'
        }
        $env:ARM_ACCESS_KEY = $stateKey  # process environment only - never written to disk
        $stateKey = $null
    }

    # Step 2: destroy the main stack while its backend still exists.
    Write-Banner 'Step 2: terraform destroy (stack)'
    if (Test-Path $BackendConfig) {
        Invoke-Terraform -Root $StackRoot -Arguments @('init', "-backend-config=$BackendConfig", '-reconfigure', '-input=false')
        Invoke-Terraform -Root $StackRoot -Arguments @('destroy', '-auto-approve', "-var-file=$SessionVars", '-input=false')
        Write-Host 'Stack destroyed.'
    }
    else {
        Write-Host 'No .session\backend.hcl - the stack backend was never bootstrapped; skipping stack destroy.'
    }

    # Step 3: optional bootstrap teardown (state storage account). Default keeps
    # the backend; the sandbox wipe removes it within 4 hours regardless - this
    # step shows the state backend itself is also fully code-managed.
    if ($IncludeBootstrap) {
        Write-Banner 'Step 3: terraform destroy (bootstrap state backend)'
        $bootstrapState = Join-Path $SessionDir 'bootstrap.tfstate'
        if (Test-Path $bootstrapState) {
            Invoke-Terraform -Root $BootstrapRoot -Arguments @('init', "-backend-config=path=$bootstrapState", '-reconfigure', '-input=false')
            Invoke-Terraform -Root $BootstrapRoot -Arguments @('destroy', '-auto-approve', "-var-file=$SessionVars", '-input=false')
            Write-Host 'Bootstrap state backend destroyed.'
        }
        else {
            Write-Host 'No bootstrap local state found in .session/ - skipping bootstrap destroy.'
        }
    }
    else {
        Write-Banner 'Step 3: bootstrap teardown skipped (run with -IncludeBootstrap to remove the state backend)'
    }

    # Step 4: local cleanup.
    Invoke-LocalCleanup

    Write-Banner 'destroy.ps1 SUCCEEDED'
    Write-Host ("Verify the playground RG is empty: az resource list -g {0} -o table" -f $ResourceGroupName)
    exit 0
}
catch {
    Write-Host ''
    Write-Host ("destroy.ps1 FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Fix the cause and re-run destroy.ps1; a half-completed destroy is recoverable (P2/P3).'
    exit 1
}
