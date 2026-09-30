#requires -Version 5.1
<#
.SYNOPSIS
    Publishes the version-controlled synapse/ workspace artifacts (linked
    services, datasets, pipelines, SQL scripts, triggers) to a target Synapse
    workspace using the `az synapse` CLI, after resolving environment-specific
    placeholder tokens from a config/<env>.json file.

.DESCRIPTION
    This PoC deploys workspace artifacts directly with `az synapse <kind>
    create --file`, rather than generating an ARM template via the Synapse
    "publish" / npm export toolchain. That keeps deployment fully scriptable
    from a clean checkout (no npm/network dependency to *build* the
    deployable unit) while still using an officially supported Azure CLI
    surface for every artifact kind involved in this PoC.

    Artifacts are deployed in dependency order so references resolve:
    linkedService -> dataset -> pipeline -> sqlscript -> trigger.

    Token resolution: config/<env>.json declares
    `synapseArtifacts.parameters`, a map of
    "<ArtifactName>_<propertyPath_with_underscores>" to a value that may
    itself be a "{{TOKEN}}" placeholder (e.g. "{{STORAGE_ACCOUNT_DFS_ENDPOINT}}"),
    because some values (like the storage account's dfs endpoint) are only
    known after infra/ has been deployed. -TokenValues supplies the runtime
    resolution for those tokens (e.g. from the infra deployment's outputs).
    The artifact's JSON property at that path is overwritten with the
    resolved value before the artifact is deployed. Unresolved "{{TOKEN}}"
    placeholders left in the config after substitution cause a hard failure
    rather than being deployed as literal text.

.PARAMETER Offline
    Never calls az. Only resolves tokens, patches artifact JSON in a temp
    location, and reports the command that would run for each artifact.

.PARAMETER DryRun
    Requires az CLI. Currently behaves like -Offline for command
    construction purposes (there is no `--what-if` equivalent for `az
    synapse <kind> create`), but is kept as a distinct switch for interface
    symmetry with the other scripts and so future validation (e.g. `az
    synapse <kind> show` pre-checks) can be added without a breaking change.

.OUTPUTS
    PSCustomObject: TotalArtifacts, Succeeded, Failed, Skipped, Results,
    IsSuccess

.EXAMPLE
    ./Publish-SynapseArtifacts.ps1 -ArtifactsRoot .\synapse -ConfigFile .\config\dev.json -WorkspaceName synws -TokenValues 'STORAGE_ACCOUNT_DFS_ENDPOINT=https://abc123.dfs.core.windows.net' -Offline

.EXAMPLE
    ./Publish-SynapseArtifacts.ps1 -ArtifactsRoot .\synapse -ConfigFile .\config\dev.json -WorkspaceName synws -TokenValues 'STORAGE_ACCOUNT_DFS_ENDPOINT=https://abc123.dfs.core.windows.net' -SubscriptionId $subId
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsRoot,

    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter()]
    [string]$SubscriptionId,

    # Accepts "TOKEN=value" tokens, same comma-separated-string convention as
    # -AdditionalParameters in Deploy-SynapseWorkspace.ps1 (required because
    # -File invocation from GitHub Actions/Azure DevOps script steps cannot
    # bind space-separated tokens to an array parameter).
    [Parameter()]
    [string[]]$TokenValues = @(),

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

# Folder name -> `az synapse <kind>` subcommand, in required deployment order.
$Script:ArtifactKindOrder = [ordered]@{
    'linkedService' = 'linked-service'
    'dataset'       = 'dataset'
    'dataflow'      = 'data-flow'
    'pipeline'      = 'pipeline'
    'sqlscript'     = 'sql-script'
    'trigger'       = 'trigger'
}

function ConvertTo-SynapseTokenMap {
    param([Parameter()][string[]]$Value)

    $normalized = ConvertTo-SynapseStringArray -Value $Value
    $map = @{}
    foreach ($entry in $normalized) {
        if ($entry -notmatch '^[^=\s]+=.*$') {
            throw "TokenValues entries must be in 'TOKEN=value' form, got: '$entry'"
        }
        $idx = $entry.IndexOf('=')
        $key = $entry.Substring(0, $idx)
        $val = $entry.Substring($idx + 1)
        $map[$key] = $val
    }
    return $map
}

function Resolve-SynapseTokenString {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][hashtable]$TokenMap
    )

    $unresolvedMatches = [regex]::Matches($Text, '\{\{([A-Za-z0-9_]+)\}\}')
    $result = $Text
    foreach ($m in $unresolvedMatches) {
        $tokenName = $m.Groups[1].Value
        if (-not $TokenMap.ContainsKey($tokenName)) {
            throw "Unresolved placeholder token '{{$tokenName}}' found in config parameter value; supply it via -TokenValues '$tokenName=<value>'."
        }
        # Literal (non-regex) replace so token values containing regex
        # metacharacters (e.g. URLs with dots) are substituted verbatim.
        $result = $result.Replace($m.Value, $TokenMap[$tokenName])
    }
    return $result
}

function Set-SynapseJsonPropertyPath {
    <#
        .SYNOPSIS
            Sets a nested property on a PSCustomObject (parsed JSON) given a
            path of underscore-joined segment names, matching Synapse's own
            ARM parameterization naming convention (e.g.
            properties_typeProperties_url).
    #>
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$PathSegments,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $current = $InputObject
    for ($i = 0; $i -lt $PathSegments.Count - 1; $i++) {
        $segment = $PathSegments[$i]
        if (-not ($current.PSObject.Properties.Match($segment).Count)) {
            throw "Artifact JSON has no property '$segment' while resolving path '$($PathSegments -join '_')'."
        }
        $current = $current.$segment
    }
    $lastSegment = $PathSegments[$PathSegments.Count - 1]
    if (-not ($current.PSObject.Properties.Match($lastSegment).Count)) {
        throw "Artifact JSON has no property '$lastSegment' while resolving path '$($PathSegments -join '_')'."
    }
    $current.$lastSegment = $Value
}

try {
    if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
        throw "ArtifactsRoot not found: $ArtifactsRoot"
    }
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "ConfigFile not found: $ConfigFile"
    }

    $tokenMap = ConvertTo-SynapseTokenMap -Value $TokenValues
    $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json

    $overrideParams = @{}
    if ($config.PSObject.Properties.Match('synapseArtifacts').Count -and
        $config.synapseArtifacts.PSObject.Properties.Match('parameters').Count) {
        $config.synapseArtifacts.parameters.PSObject.Properties | ForEach-Object {
            $overrideParams[$_.Name] = Resolve-SynapseTokenString -Text ([string]$_.Value) -TokenMap $tokenMap
        }
    }

    $isSimulated = [bool]($Offline -or $DryRun)
    if (-not $isSimulated) {
        Assert-SynapseDependency -Name 'az' | Out-Null
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "synapse-artifacts-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $results = @()
    try {
        foreach ($folder in $Script:ArtifactKindOrder.Keys) {
            $kind = $Script:ArtifactKindOrder[$folder]
            $folderPath = Join-Path $ArtifactsRoot $folder
            if (-not (Test-Path -LiteralPath $folderPath)) {
                continue
            }

            $artifactFiles = Get-ChildItem -LiteralPath $folderPath -Filter '*.json' -File | Sort-Object Name
            foreach ($file in $artifactFiles) {
                $artifact = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                $artifactName = $artifact.name
                if (-not $artifactName) {
                    throw "Artifact file '$($file.FullName)' has no top-level 'name' property."
                }

                # Apply any override whose key starts with "<artifactName>_".
                $prefix = "$artifactName`_"
                $appliedOverrides = @()
                foreach ($paramName in $overrideParams.Keys) {
                    if ($paramName.StartsWith($prefix)) {
                        $pathSegments = $paramName.Substring($prefix.Length) -split '_'
                        Set-SynapseJsonPropertyPath -InputObject $artifact -PathSegments $pathSegments -Value $overrideParams[$paramName]
                        $appliedOverrides += $paramName
                    }
                }

                $patchedPath = Join-Path $tempRoot "$artifactName.json"
                $artifact | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $patchedPath -Encoding UTF8

                $argList = @(
                    'synapse', $kind, 'create'
                    '--workspace-name', $WorkspaceName
                    '--name', $artifactName
                    '--file', "@$patchedPath"
                )
                if ($SubscriptionId) {
                    $argList += @('--subscription', $SubscriptionId)
                }

                $displayCommand = "az $($argList -join ' ')"
                $overrideNote = if ($appliedOverrides.Count -gt 0) { " (overrides applied: $($appliedOverrides -join ', '))" } else { '' }

                if ($isSimulated) {
                    Write-SynapseLog -LogPath $LogPath -Level Info -Message "[Simulated] Would publish $folder/$($file.Name) as '$artifactName'$overrideNote -> $(Protect-SynapseSecretText -Text $displayCommand)"
                    $results += [PSCustomObject]@{
                        Kind      = $folder
                        Name      = $artifactName
                        Status    = 'Skipped'
                        Command   = $displayCommand
                        Reason    = 'Offline/DryRun - not executed'
                    }
                    continue
                }

                $cmdResult = Invoke-SynapseManagedCommand -FilePath 'az' -ArgumentList $argList -DryRun:$false -Description "Publishing $folder/$($file.Name) as '$artifactName'$overrideNote"
                if ($cmdResult.ExitCode -eq 0) {
                    $results += [PSCustomObject]@{
                        Kind    = $folder
                        Name    = $artifactName
                        Status  = 'Succeeded'
                        Command = $cmdResult.Command
                        Reason  = $null
                    }
                } else {
                    $results += [PSCustomObject]@{
                        Kind    = $folder
                        Name    = $artifactName
                        Status  = 'Failed'
                        Command = $cmdResult.Command
                        Reason  = "az exited with code $($cmdResult.ExitCode)"
                    }
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $succeeded = @($results | Where-Object { $_.Status -eq 'Succeeded' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

    $summary = [PSCustomObject]@{
        TotalArtifacts = $results.Count
        Succeeded      = $succeeded
        Failed         = $failed
        Skipped        = $skipped
        Results        = $results
        Simulated      = $isSimulated
        IsSuccess      = ($failed -eq 0)
    }

    Set-SynapsePipelineOutput -Name 'artifactsPublished' -Value ([string]$succeeded)
    Set-SynapsePipelineOutput -Name 'artifactsFailed' -Value ([string]$failed)

    $summary
    if ($summary.IsSuccess) {
        exit (Get-SynapseExitCode -Name Success)
    } else {
        exit (Get-SynapseExitCode -Name ExecutionFailed)
    }
} catch {
    Write-SynapseLog -LogPath $LogPath -Level Error -Message "Synapse artifact publishing failed: $($_.Exception.Message)"
    exit (Get-SynapseExitCode -Name ExecutionFailed)
}
