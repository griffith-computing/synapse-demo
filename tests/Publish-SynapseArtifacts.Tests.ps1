#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/Publish-SynapseArtifacts.ps1.
.NOTES
    Only the -Offline path is exercised without requiring real Azure
    credentials/network. It never calls az.
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

    It 'publishes SQL scripts from a query file and maps supported artifact metadata' {
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
        $result.StdOut | Should Match 'sql-script create'
        $result.StdOut | Should Match '--file\s+"?[^"\s]+\.sql"?'
        $result.StdOut | Should Match '--folder-name poc'
        $result.StdOut | Should Match '--result-limit 5000'
        $result.StdOut | Should Match '--sql-database-name master'
        $result.StdOut | Should Match '--sql-pool-name Built-in'
        $result.StdOut | Should Not Match '--file @'
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
