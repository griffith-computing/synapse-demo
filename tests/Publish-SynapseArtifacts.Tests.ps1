#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/Publish-SynapseArtifacts.ps1.
.NOTES
    Offline checks and a local az stub exercise publishing without Azure
    credentials/network.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'TestHelpers.psm1') -Force

Describe 'Publish-SynapseArtifacts.ps1' {
    $sandbox = New-TestSandbox
    $artifactsRoot = Join-Path $sandbox 'synapse'
    New-Item -ItemType Directory -Path (Join-Path $artifactsRoot 'linkedService') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $artifactsRoot 'pipeline') -Force | Out-Null

    $linkedServiceJson = @{
        name       = 'LS_Test'
        type       = 'Microsoft.Synapse/workspaces/linkedservices'
        properties = @{
            type          = 'AzureBlobFS'
            typeProperties = @{ url = 'https://REPLACE_ME.dfs.core.windows.net' }
        }
    } | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $artifactsRoot 'linkedService\LS_Test.json') -Value $linkedServiceJson -Encoding UTF8

    $pipelineJson = @{
        name       = 'PL_Test'
        type       = 'Microsoft.Synapse/workspaces/pipelines'
        properties = @{ activities = @() }
    } | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $artifactsRoot 'pipeline\PL_Test.json') -Value $pipelineJson -Encoding UTF8

    $configFile = Join-Path $sandbox 'dev.json'
    $configJson = @{
        environmentName  = 'dev'
        synapseArtifacts = @{
            parameters = @{
                'LS_Test_properties_typeProperties_url' = '{{STORAGE_ACCOUNT_DFS_ENDPOINT}}'
            }
        }
    } | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $configFile -Value $configJson -Encoding UTF8

    It 'offline mode resolves tokens and constructs commands for every artifact without calling az' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Publish-SynapseArtifacts.ps1' -Parameters @{
            ArtifactsRoot = $artifactsRoot
            ConfigFile    = $configFile
            WorkspaceName = 'synws'
            TokenValues   = @('STORAGE_ACCOUNT_DFS_ENDPOINT=https://abc123.dfs.core.windows.net')
            Offline       = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'TotalArtifacts\s*:\s*2'
        $result.StdOut | Should Match 'Skipped\s*:\s*2'
        $result.StdOut | Should Match ([regex]::Escape('linked-service create'))
        $result.StdOut | Should Match ([regex]::Escape('pipeline create'))
    }

    It 'constructs a SQL script REST request in offline mode' {
        $sqlScriptRoot = Join-Path $sandbox 'sqlscript-artifacts'
        $sqlScriptDir = Join-Path $sqlScriptRoot 'sqlscript'
        New-Item -ItemType Directory -Path $sqlScriptDir -Force | Out-Null
        @{
            name       = 'SQL_Test'
            type       = 'Microsoft.Synapse/workspaces/sqlscripts'
            properties = @{
                folder = @{ name = 'poc' }
                content = @{
                    query = "SELECT '{{STORAGE_ACCOUNT_DFS_ENDPOINT}}' AS endpoint;"
                    currentConnection = @{ databaseName = 'master'; poolName = 'Built-in' }
                    resultLimit = 5000
                }
                type = 'SqlQuery'
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $sqlScriptDir 'SQL_Test.json') -Encoding UTF8
        $sqlConfig = Join-Path $sandbox 'sql-config.json'
        '{"environmentName":"dev","synapseArtifacts":{"parameters":{}}}' |
            Set-Content -LiteralPath $sqlConfig -Encoding UTF8

        $result = Invoke-ScriptUnderTest -ScriptName 'Publish-SynapseArtifacts.ps1' -Parameters @{
            ArtifactsRoot = $sqlScriptRoot
            ConfigFile    = $sqlConfig
            WorkspaceName = 'synws'
            TokenValues   = @('STORAGE_ACCOUNT_DFS_ENDPOINT=https://abc123.dfs.core.windows.net')
            Offline       = $true
        }

        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'rest --method put'
        $result.StdOut | Should Match 'https://synws.dev.azuresynapse.net/sqlScripts/SQL_Test\?api-version=2020-12-01'
        $result.StdOut | Should Match '--resource https://dev.azuresynapse.net'
        $result.StdOut | Should Match '--body\s+"@[^"]+\.json"'
        $result.StdOut | Should Not Match '--result-limit'
    }

    It 'sends resolved SQL metadata as JSON and propagates REST failures without Azure access' {
        $restRoot = Join-Path $sandbox 'rest-artifacts'
        $sqlDir = Join-Path $restRoot 'sqlscript'
        $stubDir = Join-Path $sandbox 'stub cli'
        New-Item -ItemType Directory -Path $sqlDir, $stubDir -Force | Out-Null
        $capturePath = Join-Path $stubDir 'request.json'
        $restConfig = Join-Path $restRoot 'config.json'
        '{"environmentName":"dev","synapseArtifacts":{"parameters":{"SQL_Test Name_properties_folder_name":"overridden"}}}' |
            Set-Content -LiteralPath $restConfig -Encoding UTF8
        @'
@echo off
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0capture.ps1" %*
exit /b %errorlevel%
'@ | Set-Content -LiteralPath (Join-Path $stubDir 'az.cmd') -Encoding ASCII
        @'
$ErrorActionPreference = 'Stop'
$bodyIndex = [Array]::IndexOf($args, '--body')
if ($bodyIndex -lt 0) { throw 'Expected --body' }
$bodyPath = $args[$bodyIndex + 1].Substring(1)
@{
    Arguments = @($args)
    Payload = Get-Content -LiteralPath $bodyPath -Raw | ConvertFrom-Json
    BodyPath = $bodyPath
} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'request.json') -Encoding UTF8
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fail')) {
    [Console]::Error.WriteLine('SQL REST request rejected')
    exit 7
}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $stubDir 'capture.ps1') -Encoding UTF8

        $originalPath = $env:PATH
        try {
            $env:PATH = "$stubDir;$originalPath"
            foreach ($limit in @(5000, -1, $null)) {
                $content = @{
                    query = "SELECT '{{STORAGE_ACCOUNT_DFS_ENDPOINT}}' AS endpoint;"
                    metadata = @{ language = 'sql' }
                    currentConnection = @{ databaseName = 'master'; poolName = 'Built-in' }
                }
                if ($null -ne $limit) { $content.resultLimit = $limit }
                @{
                    name = 'SQL_Test Name'
                    type = 'Microsoft.Synapse/workspaces/sqlscripts'
                    properties = @{
                        folder = @{ name = 'poc' }
                        content = $content
                        type = 'SqlQuery'
                        description = 'Preserve metadata'
                    }
                } | ConvertTo-Json -Depth 10 |
                    Set-Content -LiteralPath (Join-Path $sqlDir 'SQL_Test.json') -Encoding UTF8
                $parameters = @{
                    ArtifactsRoot = $restRoot
                    ConfigFile = $restConfig
                    WorkspaceName = 'synws'
                    SubscriptionId = 'test-subscription'
                    TokenValues = @('STORAGE_ACCOUNT_DFS_ENDPOINT=https://abc123.dfs.core.windows.net')
                }
                $result = Invoke-ScriptUnderTest -ScriptName 'Publish-SynapseArtifacts.ps1' -Parameters $parameters
                $result.ExitCode | Should Be 0
                $result.StdOut | Should Match 'Succeeded\s*:\s*1'
                $request = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
                ($request.Arguments -join ' ') | Should Match 'rest --method put --url https://synws.dev.azuresynapse.net/sqlScripts/SQL_Test%20Name\?api-version=2020-12-01'
                ($request.Arguments -join ' ') | Should Match '--resource https://dev.azuresynapse.net --headers Content-Type=application/json'
                ($request.Arguments -join ' ') | Should Match '--subscription test-subscription'
                $request.Payload.name | Should Be 'SQL_Test Name'
                $request.Payload.properties.folder.name | Should Be 'overridden'
                $request.Payload.properties.content.query | Should Be "SELECT 'https://abc123.dfs.core.windows.net' AS endpoint;"
                $request.Payload.properties.content.currentConnection.databaseName | Should Be 'master'
                $request.Payload.properties.content.currentConnection.poolName | Should Be 'Built-in'
                $request.Payload.properties.content.metadata.language | Should Be 'sql'
                $request.Payload.properties.type | Should Be 'SqlQuery'
                $request.Payload.properties.description | Should Be 'Preserve metadata'
                if ($null -ne $limit) {
                    $request.Payload.properties.content.resultLimit | Should Be $limit
                    ($request.Payload.properties.content.resultLimit -is [int]) | Should Be $true
                } else {
                    $request.Payload.properties.content.PSObject.Properties.Match('resultLimit').Count | Should Be 0
                }
                Test-Path -LiteralPath $request.BodyPath | Should Be $false
            }

            New-Item -ItemType File -Path (Join-Path $stubDir 'fail') | Out-Null
            $result = Invoke-ScriptUnderTest -ScriptName 'Publish-SynapseArtifacts.ps1' -Parameters $parameters
            $result.ExitCode | Should Be 3
            $result.StdOut | Should Match 'SQL REST request rejected'
            $result.StdOut | Should Match 'Failed\s*:\s*1'
            $request = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
            Test-Path -LiteralPath $request.BodyPath | Should Be $false
        } finally {
            $env:PATH = $originalPath
        }
    }

    It 'fails explicitly when a placeholder token has no matching -TokenValues entry' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Publish-SynapseArtifacts.ps1' -Parameters @{
            ArtifactsRoot = $artifactsRoot
            ConfigFile    = $configFile
            WorkspaceName = 'synws'
            Offline       = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'Unresolved placeholder token'
    }

    It 'fails explicitly when an artifact JSON token has no matching runtime value' {
        $artifactTokenRoot = Join-Path $sandbox 'artifact-token-root'
        $sqlScriptDir = Join-Path $artifactTokenRoot 'sqlscript'
        New-Item -ItemType Directory -Path $sqlScriptDir -Force | Out-Null
        @{
            name       = 'SQL_Test'
            type       = 'Microsoft.Synapse/workspaces/sqlscripts'
            properties = @{ content = @{ query = "SELECT * FROM OPENROWSET(BULK '{{STORAGE_ACCOUNT_DFS_ENDPOINT}}/curated/test.csv')" } }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $sqlScriptDir 'SQL_Test.json') -Encoding UTF8
        $emptyConfig = Join-Path $sandbox 'empty-config.json'
        '{"environmentName":"dev","synapseArtifacts":{"parameters":{}}}' | Set-Content -LiteralPath $emptyConfig -Encoding UTF8

        $result = Invoke-ScriptUnderTest -ScriptName 'Publish-SynapseArtifacts.ps1' -Parameters @{
            ArtifactsRoot = $artifactTokenRoot
            ConfigFile    = $emptyConfig
            WorkspaceName = 'synws'
            Offline       = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'Unresolved placeholder token'
    }

    It 'fails explicitly when ArtifactsRoot is missing' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Publish-SynapseArtifacts.ps1' -Parameters @{
            ArtifactsRoot = (Join-Path $sandbox 'no-such-folder')
            ConfigFile    = $configFile
            WorkspaceName = 'synws'
            Offline       = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'ArtifactsRoot not found'
    }

    Remove-TestSandbox -Path $sandbox
}
