#requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for scripts/Deploy-SynapseWorkspace.ps1.
.NOTES
    Only the -Offline path is exercised without requiring real Azure
    credentials/network. It never calls az.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'TestHelpers.psm1') -Force

Describe 'Deploy-SynapseWorkspace.ps1' {
    $sandbox = New-TestSandbox
    $templateFile = Join-Path $sandbox 'TemplateForWorkspace.json'
    $paramsFile = Join-Path $sandbox 'TemplateParametersForWorkspace.json'
    '{"resources":[]}' | Set-Content -LiteralPath $templateFile
    '{"parameters":{}}' | Set-Content -LiteralPath $paramsFile

    It 'offline mode constructs the az command without invoking az' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{
            ResourceGroupName       = 'rg-synapse-dev'
            WorkspaceName           = 'synws'
            TemplateFile            = $templateFile
            TemplateParametersFile  = $paramsFile
            Offline                 = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'Simulated\s*:\s*True'
        $result.StdOut | Should Match 'deployment group create'
        $result.StdOut | Should Match '--resource-group rg-synapse-dev'
        # WorkspaceName must NOT be auto-injected as a template parameter -
        # not every template (e.g. this PoC's Bicep template) declares a
        # parameter with that name, and an undeclared --parameters entry
        # fails az deployment outright. WorkspaceName is only used for
        # deployment naming/logging/post-deployment hook arguments.
        $result.StdOut | Should Not Match 'workspaceName=synws'
        $result.StdOut | Should Match ([regex]::Escape("--parameters @$paramsFile"))
    }

    It 'applies -AdditionalParameters as inline overrides alongside the parameters file' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{
            ResourceGroupName       = 'rg-synapse-dev'
            WorkspaceName           = 'synws'
            TemplateFile            = $templateFile
            TemplateParametersFile  = $paramsFile
            AdditionalParameters    = @('environmentName=dev')
            Offline                 = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match ([regex]::Escape("--parameters @$paramsFile environmentName=dev"))
    }

    It 'fails explicitly when TemplateFile is missing' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{
            ResourceGroupName      = 'rg-synapse-dev'
            WorkspaceName          = 'synws'
            TemplateFile           = (Join-Path $sandbox 'missing.json')
            TemplateParametersFile = $paramsFile
            Offline                = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'TemplateFile not found'
    }

    It 'fails explicitly when TemplateParametersFile is missing' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{
            ResourceGroupName      = 'rg-synapse-dev'
            WorkspaceName          = 'synws'
            TemplateFile           = $templateFile
            TemplateParametersFile = (Join-Path $sandbox 'missing-params.json')
            Offline                = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'TemplateParametersFile not found'
    }

    It 'fails explicitly when PostDeploymentScript is specified but missing' {
        $result = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{
            ResourceGroupName      = 'rg-synapse-dev'
            WorkspaceName          = 'synws'
            TemplateFile           = $templateFile
            TemplateParametersFile = $paramsFile
            PostDeploymentScript   = (Join-Path $sandbox 'no-such-script.ps1')
            Offline                = $true
        }
        $result.ExitCode | Should Be 3
        $result.StdOut | Should Match 'PostDeploymentScript not found'
    }

    It 'never leaks parameters file contents to output (secrets stay off the log)' {
        $secretParamsFile = Join-Path $sandbox 'secret-params.json'
        '{"dbPassword":"SuperSecretValue123"}' | Set-Content -LiteralPath $secretParamsFile
        $result = Invoke-ScriptUnderTest -ScriptName 'Deploy-SynapseWorkspace.ps1' -Parameters @{
            ResourceGroupName      = 'rg-synapse-dev'
            WorkspaceName          = 'synws'
            TemplateFile           = $templateFile
            TemplateParametersFile = $secretParamsFile
            Offline                = $true
        }
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Not Match 'SuperSecretValue123'
    }

    Remove-TestSandbox -Path $sandbox
}
