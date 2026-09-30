#requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates (or, offline, only constructs) the Azure CLI commands used
    to deploy a Synapse workspace ARM/Bicep template, optionally followed by
    the workspace's own official post-deployment hook script.

.DESCRIPTION
    Wraps the standard Azure Synapse deployment pattern used by the
    "Synapse-Workspace-Deployment" tooling:
        az deployment group create --resource-group <rg> \
            --template-file <template> --parameters <parameters>

    Three execution modes, selected by parameters (never assumed):
      - Offline   : never calls az. Only builds and returns/prints the
                    command line that would run. Safe with no network, no
                    az CLI, and no Azure credentials.
      - DryRun    : requires az CLI (fails explicitly if missing) and runs
                    `az deployment group what-if`, a real Azure validation
                    call that reports the change set without applying it.
      - (neither) : requires az CLI + login, runs
                    `az deployment group create` for real, then invokes
                    -PostDeploymentScript if supplied and the deployment
                    succeeded.

    Secrets: the parameters file is never read or echoed by this script; it
    is passed to az by path only. Any parameter values appearing in az's
    own stdout/stderr are still redacted before logging.

.OUTPUTS
    PSCustomObject: Mode, Command, ExitCode, Succeeded, Simulated

.EXAMPLE
    ./Deploy-SynapseWorkspace.ps1 -ResourceGroupName rg-synapse-dev -WorkspaceName synws -TemplateFile .\infra\TemplateForWorkspace.json -TemplateParametersFile .\infra\TemplateParametersForWorkspace.json -Offline

.EXAMPLE
    ./Deploy-SynapseWorkspace.ps1 -ResourceGroupName rg-synapse-dev -WorkspaceName synws -TemplateFile .\infra\main.bicep -TemplateParametersFile .\infra\parameters\dev.bicepparam -AdditionalParameters 'environmentName=dev' -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$TemplateFile,

    [Parameter(Mandatory = $true)]
    [string]$TemplateParametersFile,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$DeploymentName,

    [Parameter()]
    [string]$PostDeploymentScript,

    # Accepts "key=value" tokens. Like the other array parameters in this
    # script family, a single comma-separated string (e.g.
    # "key1=value1,key2=value2") is also accepted, since PowerShell's -File
    # invocation - used by both GitHub Actions and Azure DevOps script
    # steps - does not bind space-separated tokens to an array parameter.
    [Parameter()]
    [string[]]$AdditionalParameters = @(),

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Offline,

    [Parameter()]
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force

try {
    $AdditionalParameters = ConvertTo-SynapseStringArray -Value $AdditionalParameters

    foreach ($fileParam in @(
        @{ Name = 'TemplateFile'; Path = $TemplateFile }
        @{ Name = 'TemplateParametersFile'; Path = $TemplateParametersFile }
    )) {
        if (-not (Test-Path -LiteralPath $fileParam.Path)) {
            throw "$($fileParam.Name) not found: $($fileParam.Path)"
        }
    }
    if ($PostDeploymentScript -and -not (Test-Path -LiteralPath $PostDeploymentScript)) {
        throw "PostDeploymentScript not found: $PostDeploymentScript"
    }

    if (-not $DeploymentName) {
        $DeploymentName = "synapse-$WorkspaceName-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    }

    # -WorkspaceName is used for deployment naming, logging and the
    # post-deployment hook's arguments only. It is NOT auto-injected as a
    # template parameter: neither ARM JSON exports nor this PoC's Bicep
    # template (infra/main.bicep, which computes workspaceName internally)
    # can be assumed to declare a parameter with that exact name, and
    # passing an undeclared parameter fails az deployment with
    # DeploymentParameterNotDefined. Callers that DO need to override a
    # template parameter (workspace name or otherwise) supply it via
    # -AdditionalParameters.
    #
    # az requires parameter-file + inline overrides to be passed via a
    # SINGLE --parameters argument (repeating --parameters is only valid
    # for stacking multiple ARM JSON parameter files, and is rejected when
    # a .bicepparam file is involved) - so everything is combined below
    # into one --parameters invocation: "@file" followed by any
    # "key=value" overrides.
    $paramOverrides = @("@$TemplateParametersFile")
    foreach ($override in $AdditionalParameters) {
        if ($override -notmatch '^[^=\s]+=.+$') {
            throw "AdditionalParameters entries must be in 'key=value' form, got: '$override'"
        }
        $paramOverrides += $override
    }

    $baseArgs = @(
        'deployment', 'group'
    )
    $commonDeployArgs = @(
        '--resource-group', $ResourceGroupName
        '--name', $DeploymentName
        '--template-file', $TemplateFile
        '--parameters'
    ) + $paramOverrides

    if ($SubscriptionId) {
        $commonDeployArgs += @('--subscription', $SubscriptionId)
    }

    $mode = if ($Offline) { 'Offline' } elseif ($DryRun) { 'WhatIf' } else { 'Deploy' }
    Write-SynapseLog -LogPath $LogPath -Message "Deploy-SynapseWorkspace mode=$mode resourceGroup=$ResourceGroupName workspace=$WorkspaceName deployment=$DeploymentName"

    if ($Offline) {
        $action = 'create'
        $argList = $baseArgs + @($action) + $commonDeployArgs
        $displayCommand = "az $($argList -join ' ')"
        Write-SynapseLog -LogPath $LogPath -Level Info -Message "[Offline] Would execute: $(Protect-SynapseSecretText -Text $displayCommand)"
        $result = [PSCustomObject]@{
            Mode       = $mode
            Command    = $displayCommand
            ExitCode   = 0
            Succeeded  = $true
            Simulated  = $true
        }
        Set-SynapsePipelineOutput -Name 'deploymentMode' -Value $mode
        Set-SynapsePipelineOutput -Name 'deploymentSimulated' -Value 'true'
        $result
        exit (Get-SynapseExitCode -Name Success)
    }

    # Both WhatIf and real Deploy modes need a working az CLI - fail
    # explicitly rather than pretending offline behavior if it's missing.
    Assert-SynapseDependency -Name 'az' | Out-Null

    if ($DryRun) {
        $argList = $baseArgs + @('what-if') + $commonDeployArgs
        $cmdResult = Invoke-SynapseManagedCommand -FilePath 'az' -ArgumentList $argList -DryRun:$false -Description "Running az deployment what-if against Azure (validates without applying changes)"
        $succeeded = ($cmdResult.ExitCode -eq 0)
        $result = [PSCustomObject]@{
            Mode       = $mode
            Command    = $cmdResult.Command
            ExitCode   = $cmdResult.ExitCode
            Succeeded  = $succeeded
            Simulated  = $false
        }
        Set-SynapsePipelineOutput -Name 'deploymentMode' -Value $mode
        Set-SynapsePipelineOutput -Name 'deploymentWhatIfSucceeded' -Value ([string]$succeeded)
        $result
        if ($succeeded) {
            Write-SynapseLog -LogPath $LogPath -Level Success -Message "what-if validation succeeded."
            exit (Get-SynapseExitCode -Name Success)
        } else {
            Write-SynapseLog -LogPath $LogPath -Level Error -Message "what-if validation failed (exit code $($cmdResult.ExitCode))."
            exit (Get-SynapseExitCode -Name ExecutionFailed)
        }
    }

    # Real deployment.
    $argList = $baseArgs + @('create') + $commonDeployArgs
    $cmdResult = Invoke-SynapseManagedCommand -FilePath 'az' -ArgumentList $argList -DryRun:$false -Description "Deploying Synapse workspace template to resource group '$ResourceGroupName'"
    $succeeded = ($cmdResult.ExitCode -eq 0)

    if (-not $succeeded) {
        Write-SynapseLog -LogPath $LogPath -Level Error -Message "Deployment failed (az exit code $($cmdResult.ExitCode)). Post-deployment script will NOT be run."
        [PSCustomObject]@{
            Mode      = $mode
            Command   = $cmdResult.Command
            ExitCode  = $cmdResult.ExitCode
            Succeeded = $false
            Simulated = $false
        }
        exit (Get-SynapseExitCode -Name ExecutionFailed)
    }

    Write-SynapseLog -LogPath $LogPath -Level Success -Message "Deployment succeeded."

    $postResult = $null
    if ($PostDeploymentScript) {
        Write-SynapseLog -LogPath $LogPath -Message "Invoking post-deployment hook: $PostDeploymentScript"
        $postResult = Invoke-SynapseManagedCommand -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PostDeploymentScript, '-ResourceGroupName', $ResourceGroupName, '-WorkspaceName', $WorkspaceName) -DryRun:$false
        if ($postResult.ExitCode -ne 0) {
            Write-SynapseLog -LogPath $LogPath -Level Error -Message "Post-deployment script failed (exit code $($postResult.ExitCode))."
            exit (Get-SynapseExitCode -Name ExecutionFailed)
        }
    }

    Set-SynapsePipelineOutput -Name 'deploymentMode' -Value $mode
    Set-SynapsePipelineOutput -Name 'deploymentSucceeded' -Value 'true'
    Set-SynapsePipelineOutput -Name 'deploymentName' -Value $DeploymentName

    [PSCustomObject]@{
        Mode       = $mode
        Command    = $cmdResult.Command
        ExitCode   = $cmdResult.ExitCode
        Succeeded  = $true
        Simulated  = $false
        PostDeploymentExitCode = if ($postResult) { $postResult.ExitCode } else { $null }
    }
    exit (Get-SynapseExitCode -Name Success)
} catch {
    Write-SynapseLog -LogPath $LogPath -Level Error -Message "Deployment orchestration failed: $($_.Exception.Message)"
    exit (Get-SynapseExitCode -Name ExecutionFailed)
}
