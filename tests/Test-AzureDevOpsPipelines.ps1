#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root 'scripts'
$count = 0
function Assert-Ado {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Assert-AdoFailure {
    param([scriptblock]$Action, [string]$Pattern)
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-Ado ($null -ne $failure -and $failure.ToString() -match $Pattern) "Expected '$Pattern'; received '$failure'."
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "ado-tests-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $sandbox | Out-Null
$savedProgramData = $env:ProgramData
$savedToken = $env:VSTS_AGENT_INPUT_TOKEN
$savedPath = $env:Path
$savedTfBuild = $env:TF_BUILD
$savedGitHub = $env:GITHUB_ACTIONS
$savedJobToken = $env:ADO_JOB_TOKEN
$savedPat = $env:ADO_AGENT_PAT
$savedPassword = $env:RUNNER_ADMIN_PASSWORD
try {
    foreach ($name in @('deploy-stage.yml', 'publish-artifacts-stage.yml')) {
        $text = Get-Content (Join-Path $root "azure-pipelines\templates\$name") -Raw
        foreach ($required in @(
            'name: ${{ parameters.agentPool }}', 'Agent.OS -equals Windows_NT', 'Agent.OSArchitecture -equals X64',
            'SYNAPSE_PRIVATE_AGENT -equals true', "eq(variables['Build.SourceBranch'], 'refs/heads/main')",
            'lockBehavior: sequential', '- download: none', 'source: current', 'source: specific',
            'runVersion: specific', 'runId: ${{ parameters.sourceBuildId }}', 'Expand-SynapsePipelinePackage.ps1',
            '-ExpectedVersion "$(expectedPackageVersion)"', '$(System.JobId)-$(System.JobAttempt)',
            'condition: always()', 'Get-SynapseDeploymentOutputs.ps1', 'Test-RunnerPrivateConnectivity.ps1'
        )) {
            Assert-Ado ($text.Contains($required)) "$name is missing '$required'."
        }
        Assert-Ado ($text -notmatch 'vmImage:') "$name still uses a hosted agent."
        Assert-Ado ($text.IndexOf('Get-SynapseDeploymentOutputs.ps1') -lt $text.IndexOf('Test-RunnerPrivateConnectivity.ps1')) "$name checks connectivity before resolving outputs."
        Assert-Ado ($text -notmatch 'Select-Object -First 1') "$name accepts ambiguous packages."
    }
    $deploy = Get-Content (Join-Path $root 'azure-pipelines\templates\deploy-stage.yml') -Raw
    Assert-Ado ($deploy.IndexOf('Get-SynapseDeploymentOutputs.ps1') -lt $deploy.IndexOf('Set-SynapsePrivateConnectivity.ps1')) 'Private endpoints precede output resolution.'
    Assert-Ado ($deploy.IndexOf('Set-SynapsePrivateConnectivity.ps1') -lt $deploy.IndexOf('Test-RunnerPrivateConnectivity.ps1')) 'Private preflight precedes endpoint deployment.'
    Assert-Ado ($deploy.Contains('timeoutInMinutes: 90')) 'Infrastructure timeout is missing.'
    $publish = Get-Content (Join-Path $root 'azure-pipelines\templates\publish-artifacts-stage.yml') -Raw
    Assert-Ado ($publish.IndexOf('Test-RunnerPrivateConnectivity.ps1') -lt $publish.IndexOf('Seed raw sample data')) 'Publication mutates storage before private preflight.'
    Assert-Ado ($publish -notmatch 'Set-SynapsePrivateConnectivity|Deploy-SynapseWorkspace') 'Artifact stream redeploys infrastructure.'
    Assert-Ado ($publish.Contains('timeoutInMinutes: 60')) 'Publication timeout is missing.'
    foreach ($name in @('deploy.yml', 'publish-artifacts.yml')) {
        $text = Get-Content (Join-Path $root "azure-pipelines\$name") -Raw
        Assert-Ado (($text | Select-String -Pattern "packageVersion:.*stageDependencies.Package.Package.outputs" -AllMatches).Matches.Count -eq 3) "$name does not wire the package version to all environments."
        Assert-Ado (($text | Select-String -Pattern '        - Package' -AllMatches).Matches.Count -eq 3) "$name does not expose Package outputs to all stages."
        Assert-Ado ($text.Contains('scripts/Expand-SynapsePipelinePackage.ps1')) "$name does not trigger on package helper changes."
        Assert-Ado ($text.Contains('scripts/Test-RunnerPrivateConnectivity.ps1')) "$name does not trigger on preflight changes."
        Assert-Ado ($text -notmatch 'serviceConnection: \$\(') "$name resolves service connections too late."
    }
    $promotion = Get-Content (Join-Path $root 'azure-pipelines\deploy.yml') -Raw
    Assert-Ado ($promotion.Contains('templates/deploy-runner-stage.yml') -and $promotion.Contains('        - Bootstrap')) 'Infrastructure deployment does not require bootstrap.'
    Assert-Ado ($promotion -match '(?s)stage: Package.*?dependsOn: \[\]') 'Packaging cannot run independently of bootstrap.'
    foreach ($name in @('rollback.yml', 'rollback-artifacts.yml')) {
        $text = Get-Content (Join-Path $root "azure-pipelines\$name") -Raw
        Assert-Ado (($text | Select-String -Pattern 'agentPool:' -AllMatches).Matches.Count -eq 3) "$name does not pass the private pool for every environment."
        Assert-Ado (($text | Select-String -Pattern 'downloadMode: specific' -AllMatches).Matches.Count -eq 3) "$name does not pin prior builds."
        Assert-Ado ($text.Contains('trigger: none') -and $text.Contains('pr: none')) "$name must be manual."
    }
    $bootstrap = Get-Content (Join-Path $root 'azure-pipelines\templates\deploy-runner-stage.yml') -Raw
    foreach ($required in @('vmImage: ubuntu-latest', 'dependsOn: []', 'environment: runner', 'lockBehavior: sequential', '$(System.AccessToken)', 'ADO_AGENT_PAT:', "eq(variables['Build.SourceBranch'], 'refs/heads/main')")) {
        Assert-Ado ($bootstrap.Contains($required)) "Bootstrap is missing '$required'."
    }
    $validation = Get-Content (Join-Path $root 'azure-pipelines\validate.yml') -Raw
    Assert-Ado ($validation.Contains('vmImage: ubuntu-latest') -and $validation -notmatch 'runnerPool|System.AccessToken') 'PR validation uses protected resources.'
    foreach ($required in @('autoCancel: true', 'infra/runner/main.bicep', 'infra/runner/connectivity.bicep', 'Test-RunnerInfrastructure.ps1', 'Test-AzureDevOpsPipelines.ps1')) {
        Assert-Ado ($validation.Contains($required)) "Hosted validation is missing '$required'."
    }
    $orchestrator = Get-Content (Join-Path $scripts 'Invoke-AzureDevOpsAgentBootstrap.ps1') -Raw
    Assert-Ado ($orchestrator.Contains('-ProtectedParameters @{ RegistrationToken = $token }')) 'Registration credential is not a protected parameter.'
    Assert-Ado ($orchestrator.Contains("RunnerInstall = 'None'")) 'ADO bootstrap installs a GitHub runner.'
    Assert-Ado ($orchestrator.Contains("'Agent.OS' = 'Windows_NT'")) 'Readiness does not inspect Windows capability.'

    $source = Join-Path $sandbox 'source'
    New-Item -ItemType Directory -Path $source | Out-Null
    'package-content' | Set-Content (Join-Path $source 'content.txt')
    $packageDirectory = Join-Path $sandbox 'package'
    New-Item -ItemType Directory -Path $packageDirectory | Out-Null
    & (Join-Path $scripts 'New-SynapseReleasePackage.ps1') -SourcePaths $source -OutputDirectory $packageDirectory `
        -Version '42-abc1234' -PackageName release -Offline | Out-Null
    Assert-Ado ($LASTEXITCODE -eq 0) 'Real release packaging failed.'
    $expand = Join-Path $scripts 'Expand-SynapsePipelinePackage.ps1'
    $expandParameters = @{ PackageDirectory = $packageDirectory; DestinationDirectory = (Join-Path $sandbox 'expanded'); ExpectedVersion = '42-abc1234' }
    $env:TF_BUILD = 'True'
    $env:GITHUB_ACTIONS = ''
    $output = (& $expand @expandParameters) 6>&1 | Out-String
    Assert-Ado ($output.Contains('##vso[task.setvariable variable=manifestPath]')) 'Manifest output was not exported to ADO.'
    Assert-Ado (Test-Path (Join-Path $expandParameters.DestinationDirectory 'source\content.txt')) 'Real package did not preserve the source root.'
    & (Join-Path $scripts 'Test-SynapseRepository.ps1') -RepositoryRoot $root `
        -ArtifactManifestPath (Join-Path $packageDirectory 'release-42-abc1234.manifest.json') `
        -ArtifactBasePath $expandParameters.DestinationDirectory -Offline | Out-Null
    Assert-Ado ($LASTEXITCODE -eq 0) 'Expanded release failed existing manifest integrity validation.'
    Assert-AdoFailure { & $expand @expandParameters } 'already exists'
    $expandParameters.ExpectedVersion = 'wrong-version'
    Assert-AdoFailure { & $expand @expandParameters } 'does not match'
    $expandParameters.ExpectedVersion = '$[ unresolved ]'
    Assert-AdoFailure { & $expand @expandParameters } 'resolved package version'
    $expandParameters.ExpectedVersion = '42-abc1234'
    Copy-Item (Join-Path $packageDirectory 'release-42-abc1234.zip') (Join-Path $packageDirectory 'extra.zip')
    Assert-AdoFailure { & $expand @expandParameters } 'exactly one'

    $agentArchiveRoot = Join-Path $sandbox 'archive-source'
    New-Item -ItemType Directory -Path (Join-Path $agentArchiveRoot 'bin') -Force | Out-Null
    'agent-binary' | Set-Content (Join-Path $agentArchiveRoot 'bin\Agent.Listener.exe')
    $global:AdoTestArchive = Join-Path $sandbox 'agent.zip'
    Compress-Archive -Path (Join-Path $agentArchiveRoot '*') -DestinationPath $global:AdoTestArchive
    $global:AdoTestDownloads = 0
    function global:Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing)
        $global:AdoTestDownloads++
        Copy-Item -LiteralPath $global:AdoTestArchive -Destination $OutFile
    }
    $env:ProgramData = $sandbox
    $initialize = Join-Path $scripts 'Initialize-AzureDevOpsAgent.ps1'
    $initializeParameters = @{
        DownloadUrl = 'https://download.agent.dev.azure.com/agent/test.zip'
        Sha256 = (Get-FileHash $global:AdoTestArchive -Algorithm SHA256).Hash
        AgentDirectory = (Join-Path $sandbox 'agent')
    }
    & $initialize @initializeParameters
    & $initialize @initializeParameters
    Assert-Ado ($global:AdoTestDownloads -eq 1) 'Existing agent installation was downloaded again.'
    $initializeParameters.AgentDirectory = Join-Path $sandbox 'bad-agent'
    $initializeParameters.Sha256 = '0' * 64
    Assert-AdoFailure { & $initialize @initializeParameters } 'checksum mismatch'
    Assert-Ado (-not (Test-Path (Join-Path $sandbox 'SynapseRunner\Downloads\azure-pipelines-agent.zip'))) 'Downloaded archive was not cleaned up.'
    $initializeParameters.DownloadUrl = 'https://untrusted.example/agent.zip'
    Assert-AdoFailure { & $initialize @initializeParameters } 'official HTTPS'

    $global:AdoTestStarts = 0
    $global:AdoTestRestarts = 0
    $global:AdoTestServiceStatus = 'Running'
    function global:Get-Service {
        $service = [pscustomobject]@{ Name = 'test-agent-service'; Status = $global:AdoTestServiceStatus }
        $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status, $Timeout) }
        return $service
    }
    function global:Start-Service { $global:AdoTestStarts++ }
    function global:Restart-Service { $global:AdoTestRestarts++ }
    function global:New-ItemProperty {}
    function global:icacls.exe { $global:LASTEXITCODE = 0 }
    $register = Join-Path $scripts 'Register-AzureDevOpsAgent.ps1'
    $agentDirectory = Join-Path $sandbox 'registration'
    New-Item -ItemType Directory -Path $agentDirectory | Out-Null
    $configuration = '{"agentName":"private-agent","poolId":7,"serverUrl":"https://dev.azure.com/example/"}'
    $configuration | Set-Content (Join-Path $agentDirectory '.agent')
    'test-agent-service' | Set-Content (Join-Path $agentDirectory '.service')
    $registerParameters = @{
        OrganizationUrl = 'https://dev.azure.com/example'
        PoolName = 'synapse-private'; PoolId = 7; AgentName = 'private-agent'
        RegistrationToken = 'test-secret-token'; AgentDirectory = $agentDirectory
    }
    & $register @registerParameters
    & $register @registerParameters
    Assert-Ado ($global:AdoTestStarts -eq 0 -and $global:AdoTestRestarts -eq 0) 'Matching running agent service was disturbed.'
    $global:AdoTestServiceStatus = 'Stopped'
    & $register @registerParameters
    Assert-Ado ($global:AdoTestStarts -eq 1) 'Stopped matching agent was not started.'
    $registerParameters.PoolId = 8
    Assert-AdoFailure { & $register @registerParameters } 'different organization, pool or name'
    $registerParameters.PoolId = 7
    Remove-Item -LiteralPath (Join-Path $agentDirectory '.service')
    Assert-AdoFailure { & $register @registerParameters } 'no Windows service'
    Remove-Item -LiteralPath (Join-Path $agentDirectory '.agent')
    Assert-AdoFailure { & $register @registerParameters } 'installation is missing'
    $registerParameters.RegistrationToken = ' '
    Assert-AdoFailure { & $register @registerParameters } 'credential is empty'
    $registerParameters.RegistrationToken = 'test-secret-token'
    $config = Join-Path $agentDirectory 'config.cmd'
    if ($IsWindows) {
        "@echo off`r`necho %VSTS_AGENT_INPUT_TOKEN%`r`necho test-agent-service>.service`r`nexit /b 0" | Set-Content $config
    } else {
        "#!/bin/sh`necho `"`$VSTS_AGENT_INPUT_TOKEN`"`necho test-agent-service > .service`nexit 0" | Set-Content $config
        & chmod +x $config
        if ($LASTEXITCODE -ne 0) { throw 'Could not make test agent configuration executable.' }
    }
    $output = (& $register @registerParameters) 6>&1 | Out-String
    Assert-Ado ($output -notmatch 'test-secret-token' -and $output.Contains('[REDACTED]')) 'Configuration output leaked the credential.'
    Assert-Ado ($env:VSTS_AGENT_INPUT_TOKEN -eq $savedToken) 'Registration left a token in the process environment.'
    Assert-Ado ($global:AdoTestRestarts -eq 1) 'New agent did not restart with private capability.'
    if ($IsWindows) {
        "@echo off`r`nexit /b 1" | Set-Content $config
    } else {
        "#!/bin/sh`nexit 1" | Set-Content $config
    }
    Assert-AdoFailure { & $register @registerParameters } 'registration failed'

    $bootstrapDirectory = Join-Path $sandbox 'bootstrap'
    New-Item -ItemType Directory -Path $bootstrapDirectory | Out-Null
    Copy-Item (Join-Path $scripts 'Invoke-AzureDevOpsAgentBootstrap.ps1') $bootstrapDirectory
    @'
param($ResourceGroupName, $Location, $VmSize, $AdminUsername, $VnetAddressPrefix, $BastionSubnetPrefix, $RunnerSubnetPrefix, $EndpointSubnetPrefix)
$global:AdoBootstrapDeploymentCount++
'@ | Set-Content (Join-Path $bootstrapDirectory 'Deploy-SharedRunner.ps1')
    @'
param($VmResourceId, $Location, $Name, $ScriptPath, $Parameters, $ProtectedParameters, $TimeoutSeconds)
$global:AdoBootstrapCommands.Add(@{ Name = $Name; ScriptPath = $ScriptPath; Parameters = $Parameters; ProtectedParameters = $ProtectedParameters })
'@ | Set-Content (Join-Path $bootstrapDirectory 'Invoke-RunnerManagedCommand.ps1')
    $global:AdoBootstrapCommands = [Collections.Generic.List[object]]::new()
    $global:AdoBootstrapDeploymentCount = 0
    $global:AdoBootstrapMode = 'online'
    $global:AdoBootstrapHeaders = [Collections.Generic.List[string]]::new()
    $standardPackageRow = "<tr>`n<td>Windows x64</td>`n<td><a href=`"https://download.agent.dev.azure.com/agent/5.0.0/vsts-agent-win-x64-5.0.0.zip`" rel=`"nofollow`">vsts-agent-win-x64-5.0.0.zip</a></td>`n<td>$('cd' * 32)</td>`n</tr>"
    $alternatePackageRow = "<tr>`n<td>Windows x64</td>`n<td><a href=`"https://download.agent.dev.azure.com/agent/5.0.0/pipelines-agent-win-x64-5.0.0.zip`" rel=`"nofollow`">pipelines-agent-win-x64-5.0.0.zip</a></td>`n<td>$('ef' * 32)</td>`n</tr>"
    $global:AdoBootstrapReleaseBody = $standardPackageRow
    function global:Invoke-WebRequest {
        param($Uri, $TimeoutSec, $Headers)
        if ($Uri -ne 'https://github.com/microsoft/azure-pipelines-agent/releases/latest' -or
            $TimeoutSec -ne 60 -or $Headers) {
            throw 'Release lookup must use the public latest-release page with a bounded timeout and no credentials.'
        }
        if ($global:AdoBootstrapMode -eq 'release-unavailable') { throw 'Release page unavailable.' }
        return @{ Content = $global:AdoBootstrapReleaseBody }
    }
    function global:az {
        $global:LASTEXITCODE = 0
        '{"vmName":{"value":"private-agent"},"vmResourceId":{"value":"/vm/test"},"location":{"value":"westus3"}}'
    }
    function global:Invoke-RestMethod {
        param($Uri, $Headers)
        if ($Uri -like 'https://api.github.com/*') { throw '403 (rate limit exceeded)' }
        $global:AdoBootstrapHeaders.Add($Headers.Authorization)
        if ($global:AdoBootstrapMode -eq 'unauthorized') { throw 'Registration identity is unauthorized.' }
        if ($Uri -match '/pools\?') {
            if ($global:AdoBootstrapMode -eq 'missing-pool') { return @{ value = @() } }
            return @{ value = @(@{ name = 'synapse-private'; id = 7 }) }
        }
        if ($Uri -match '/packages/') {
            if ($Uri -cne 'https://dev.azure.com/example/_apis/distributedtask/packages/agent?platform=win-x64&$top=1&api-version=7.1-preview.1') {
                throw 'Agent package lookup must pass the Windows x64 platform as a query parameter and request one package.'
            }
            if ($global:AdoBootstrapMode -in @('package-not-found', 'release-unavailable')) {
                throw 'A package with the type agent could not be found.'
            }
            $hash = ('ab-' * 31) + 'ab'
            if ($global:AdoBootstrapMode -eq 'bad-hash') { $hash = '' }
            return @{ value = @(@{ hashValue = $hash; downloadUrl = 'https://download.agent.dev.azure.com/agent/test.zip' }) }
        }
        $agent = [pscustomobject]@{
            name = 'private-agent'; enabled = $true; status = 'online'
            systemCapabilities = [pscustomobject]@{ 'Agent.OS' = 'Windows_NT'; 'Agent.OSArchitecture' = 'X64'; SYNAPSE_PRIVATE_AGENT = 'true' }
        }
        if ($global:AdoBootstrapMode -in @('busy', 'busy-once')) { $agent | Add-Member assignedRequest @{ requestId = 1 } }
        if ($global:AdoBootstrapMode -eq 'offline') { $agent.status = 'offline' }
        if ($global:AdoBootstrapMode -eq 'missing-capability') { $agent.systemCapabilities = [pscustomobject]@{} }
        return @{ value = @($agent) }
    }
    function global:Start-Sleep {
        if ($global:AdoBootstrapMode -eq 'busy-once') { $global:AdoBootstrapMode = 'online'; return }
        throw 'Readiness wait reached; test clock stopped.'
    }
    $env:ADO_JOB_TOKEN = 'test-job-token'
    $env:ADO_AGENT_PAT = 'test-pat-token'
    $env:RUNNER_ADMIN_PASSWORD = 'test-admin-password'
    $bootstrapScript = Join-Path $bootstrapDirectory 'Invoke-AzureDevOpsAgentBootstrap.ps1'
    $bootstrapParameters = @{ OrganizationUrl = 'https://dev.azure.com/example'; PoolName = 'synapse-private'; ResourceGroupName = 'shared' }
    & $bootstrapScript @bootstrapParameters
    Assert-Ado ($global:AdoBootstrapCommands.Count -eq 3) 'Bootstrap did not execute prerequisites, installation, and registration.'
    Assert-Ado ($global:AdoBootstrapCommands[0].Parameters.RunnerInstall -eq 'None') 'Bootstrap did not select prerequisites-only mode.'
    Assert-Ado ($global:AdoBootstrapCommands[1].Parameters.Sha256 -eq ('ab' * 32)) 'Official hyphenated SHA256 was not normalized.'
    $registration = $global:AdoBootstrapCommands[2]
    Assert-Ado ($registration.ProtectedParameters.RegistrationToken -eq 'test-job-token') 'Default bootstrap did not use the protected job credential.'
    Assert-Ado (-not $registration.Parameters.ContainsKey('RegistrationToken')) 'Registration credential leaked into normal parameters.'
    Assert-Ado (@($global:AdoBootstrapHeaders | Where-Object { $_ -ne 'Bearer test-job-token' }).Count -eq 0) 'Default bootstrap did not use Bearer REST authentication.'
    $global:AdoBootstrapMode = 'busy-once'
    & $bootstrapScript @bootstrapParameters
    Assert-Ado ($global:AdoBootstrapMode -eq 'online' -and $global:AdoBootstrapDeploymentCount -eq 2) 'Bootstrap did not resume after assigned work drained.'
    $global:AdoBootstrapCommands.Clear()
    $global:AdoBootstrapMode = 'package-not-found'
    & $bootstrapScript @bootstrapParameters
    Assert-Ado ($global:AdoBootstrapCommands[1].Parameters.Sha256 -eq ('cd' * 32)) 'Package-not-found response did not use the official release SHA256 fallback.'
    Assert-Ado ($global:AdoBootstrapCommands[1].Parameters.DownloadUrl -eq 'https://download.agent.dev.azure.com/agent/5.0.0/vsts-agent-win-x64-5.0.0.zip') 'Package-not-found response did not use the official Windows x64 release URL.'
    foreach ($newline in @("`n", "`r`n")) {
        $global:AdoBootstrapCommands.Clear()
        $global:AdoBootstrapReleaseBody = @(
            '<h2>Agent Downloads</h2><table><tbody>', $standardPackageRow, '</tbody></table>',
            '<h2>Alternate Agent Downloads</h2><table><tbody>', $alternatePackageRow, '</tbody></table>'
        ) -join "`n"
        $global:AdoBootstrapReleaseBody = $global:AdoBootstrapReleaseBody.Replace("`n", $newline)
        & $bootstrapScript @bootstrapParameters
        Assert-Ado ($global:AdoBootstrapCommands[1].Parameters.Sha256 -eq ('cd' * 32)) 'Alternate Windows x64 package interfered with standard package hash selection.'
        Assert-Ado ($global:AdoBootstrapCommands[1].Parameters.DownloadUrl -eq 'https://download.agent.dev.azure.com/agent/5.0.0/vsts-agent-win-x64-5.0.0.zip') 'Alternate Windows x64 package interfered with standard package URL selection.'
    }
    foreach ($case in @(
        @{ Body = $alternatePackageRow; Pattern = 'one standard Windows x64 package row' },
        @{ Body = "$standardPackageRow`n$standardPackageRow"; Pattern = 'one standard Windows x64 package row' },
        @{ Body = $standardPackageRow.Replace(('cd' * 32), 'invalid'); Pattern = 'valid Windows x64 download URL and SHA256' },
        @{ Body = $standardPackageRow.Replace('/agent/5.0.0/', '/agent/5.0.1/'); Pattern = 'valid Windows x64 download URL and SHA256' },
        @{ Body = $standardPackageRow.Replace('/vsts-agent-win-x64-5.0.0.zip"', '/vsts-agent-win-x64-5.0.1.zip"'); Pattern = 'valid Windows x64 download URL and SHA256' },
        @{ Body = $standardPackageRow.Replace('download.agent.dev.azure.com', 'example.com'); Pattern = 'valid Windows x64 download URL and SHA256' }
    )) {
        $global:AdoBootstrapReleaseBody = $case.Body
        $deploymentsBeforeFailure = $global:AdoBootstrapDeploymentCount
        $global:AdoBootstrapCommands.Clear()
        Assert-AdoFailure { & $bootstrapScript @bootstrapParameters } $case.Pattern
        Assert-Ado ($global:AdoBootstrapDeploymentCount -eq $deploymentsBeforeFailure -and $global:AdoBootstrapCommands.Count -eq 0) 'Invalid release metadata reached VM deployment or agent commands.'
    }
    $global:AdoBootstrapMode = 'online'
    $global:AdoBootstrapHeaders.Clear()
    & $bootstrapScript @bootstrapParameters -RegistrationAuth PAT
    Assert-Ado (@($global:AdoBootstrapHeaders | Where-Object { $_ -notlike 'Basic *' }).Count -eq 0) 'Explicit PAT mode did not use Basic REST authentication.'
    $env:ADO_JOB_TOKEN = ''
    Assert-AdoFailure { & $bootstrapScript @bootstrapParameters } 'RegistrationCredential'
    $env:ADO_JOB_TOKEN = 'test-job-token'
    foreach ($case in @(
        @{ Mode = 'unauthorized'; Pattern = 'unauthorized' },
        @{ Mode = 'missing-pool'; Pattern = 'must exist' },
        @{ Mode = 'bad-hash'; Pattern = 'SHA256 hash' },
        @{ Mode = 'release-unavailable'; Pattern = 'official Microsoft release fallback failed: Release page unavailable' },
        @{ Mode = 'busy'; Pattern = 'Readiness wait reached' },
        @{ Mode = 'offline'; Pattern = 'Readiness wait reached' },
        @{ Mode = 'missing-capability'; Pattern = 'Readiness wait reached' }
    )) {
        $global:AdoBootstrapMode = $case.Mode
        $deploymentsBeforeFailure = $global:AdoBootstrapDeploymentCount
        Assert-AdoFailure { & $bootstrapScript @bootstrapParameters } $case.Pattern
        if ($case.Mode -in @('busy', 'release-unavailable')) {
            Assert-Ado ($global:AdoBootstrapDeploymentCount -eq $deploymentsBeforeFailure) 'Failed bootstrap preflight reached VM deployment.'
        }
    }

    foreach ($path in @(
        'Initialize-AzureDevOpsAgent.ps1', 'Register-AzureDevOpsAgent.ps1',
        'Invoke-AzureDevOpsAgentBootstrap.ps1', 'Expand-SynapsePipelinePackage.ps1', 'Initialize-GitHubRunner.ps1'
    )) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts $path), [ref]$tokens, [ref]$errors) | Out-Null
        Assert-Ado ($errors.Count -eq 0) "PowerShell parsing failed for '$path'."
    }
    Write-Host "$count Azure DevOps pipeline and agent checks passed."
} finally {
    $env:ProgramData = $savedProgramData
    $env:VSTS_AGENT_INPUT_TOKEN = $savedToken
    $env:Path = $savedPath
    $env:TF_BUILD = $savedTfBuild
    $env:GITHUB_ACTIONS = $savedGitHub
    $env:ADO_JOB_TOKEN = $savedJobToken
    $env:ADO_AGENT_PAT = $savedPat
    $env:RUNNER_ADMIN_PASSWORD = $savedPassword
    Remove-Item -LiteralPath $sandbox -Recurse -Force
    foreach ($name in @('Invoke-WebRequest', 'Get-Service', 'Start-Service', 'Restart-Service', 'New-ItemProperty', 'icacls.exe', 'az', 'Invoke-RestMethod', 'Start-Sleep')) {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable AdoTestArchive, AdoTestDownloads, AdoTestStarts, AdoTestRestarts, AdoTestServiceStatus -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable AdoBootstrapCommands, AdoBootstrapDeploymentCount, AdoBootstrapMode, AdoBootstrapHeaders, AdoBootstrapReleaseBody -Scope Global -ErrorAction SilentlyContinue
}
