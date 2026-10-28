#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$DownloadUrl,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
    [string]$AgentDirectory = 'C:\azagent'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($DownloadUrl.Scheme -ne 'https' -or
    $DownloadUrl.Host -notin @('download.agent.dev.azure.com', 'vstsagentpackage.azureedge.net')) {
    throw 'Agent download must use an official HTTPS Azure Pipelines distribution endpoint.'
}
if (Test-Path -LiteralPath (Join-Path $AgentDirectory 'bin\Agent.Listener.exe')) {
    Write-Host 'Azure Pipelines agent is already installed; automatic agent updates remain enabled.'
    return
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$downloadDirectory = Join-Path $env:ProgramData 'SynapseRunner\Downloads'
New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
$archive = Join-Path $downloadDirectory 'azure-pipelines-agent.zip'
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $archive -UseBasicParsing
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Sha256) {
        throw 'Azure Pipelines agent checksum mismatch.'
    }
    New-Item -ItemType Directory -Path $AgentDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $AgentDirectory -Force
    if (-not (Test-Path -LiteralPath (Join-Path $AgentDirectory 'bin\Agent.Listener.exe'))) {
        throw 'Agent archive did not contain Agent.Listener.exe.'
    }
} finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
}
