#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RunnerDirectory = 'C:\actions-runner',
    [ValidateSet('GitHub', 'None')][string]$RunnerInstall = 'GitHub'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'synapse-runner-bootstrap' }
$downloadDirectory = Join-Path $env:ProgramData 'SynapseRunner\Downloads'
New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null

function Get-VerifiedReleaseAsset {
    param([string]$Repository, [string]$AssetPattern)
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    $assets = @($release.assets | Where-Object { $_.name -match $AssetPattern })
    if ($assets.Count -ne 1) { throw "Expected one release asset matching '$AssetPattern' in '$Repository'." }
    $asset = $assets[0]
    if (-not $asset.digest -or $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw "Release asset '$($asset.name)' has no SHA256 digest. Refusing an unverified download."
    }
    $expected = $Matches[1]
    $path = Join-Path $downloadDirectory $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $path -UseBasicParsing
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) {
        throw "Checksum mismatch for '$($asset.name)'."
    }
    return $path
}

function Invoke-Installer {
    param([string]$Path, [string]$Arguments)
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Installer '$Path' failed with exit code $($process.ExitCode)." }
    if ($process.ExitCode -eq 3010) { Write-Host 'Installer requested a reboot; verify readiness before registration.' }
}

if (-not (Test-Path -LiteralPath 'C:\Program Files\PowerShell\7\pwsh.exe')) {
    $msi = Get-VerifiedReleaseAsset -Repository 'PowerShell/PowerShell' -AssetPattern '^PowerShell-[\d.]+-win-x64\.msi$'
    Invoke-Installer -Path 'msiexec.exe' -Arguments "/i `"$msi`" /qn /norestart ADD_PATH=1 ENABLE_MU=1 USE_MU=1"
}
if (-not (Test-Path -LiteralPath 'C:\Program Files\Git\cmd\git.exe')) {
    $installer = Get-VerifiedReleaseAsset -Repository 'git-for-windows/git' -AssetPattern '^Git-[\d.]+-64-bit\.exe$'
    Invoke-Installer -Path $installer -Arguments '/VERYSILENT /NORESTART /NOCANCEL /SP-'
}
$azPath = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path -LiteralPath $azPath)) {
    $msi = Join-Path $downloadDirectory 'AzureCLI-x64.msi'
    Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $msi -UseBasicParsing
    $signature = Get-AuthenticodeSignature -FilePath $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw 'Azure CLI MSI does not have a valid Microsoft signature.'
    }
    Invoke-Installer -Path 'msiexec.exe' -Arguments "/i `"$msi`" /qn /norestart"
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
& $azPath version --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI installation verification failed.' }
$bicepDirectory = 'C:\Program Files\AzureBicep'
if (-not (Test-Path -LiteralPath (Join-Path $bicepDirectory 'bicep.exe'))) {
    & $azPath bicep install
    if ($LASTEXITCODE -ne 0) { throw 'Bicep installation failed.' }
    New-Item -ItemType Directory -Path $bicepDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:USERPROFILE '.azure\bin\bicep.exe') -Destination (Join-Path $bicepDirectory 'bicep.exe')
}
& (Join-Path $bicepDirectory 'bicep.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'Bicep installation verification failed.' }
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($bicepDirectory -notin $machinePath.Split(';')) {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$bicepDirectory", 'Machine')
}
[Environment]::SetEnvironmentVariable('AZURE_BICEP_USE_BINARY_FROM_PATH', 'true', 'Machine')
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0) { throw 'PowerShell 7 installation verification failed.' }
& 'C:\Program Files\Git\cmd\git.exe' --version
if ($LASTEXITCODE -ne 0) { throw 'Git installation verification failed.' }

if ($RunnerInstall -eq 'None') {
    Write-Host 'Windows agent prerequisites are installed.'
    return
}
if (-not (Test-Path -LiteralPath (Join-Path $RunnerDirectory 'bin\Runner.Listener.exe'))) {
    $zip = Get-VerifiedReleaseAsset -Repository 'actions/runner' -AssetPattern '^actions-runner-win-x64-[\d.]+\.zip$'
    New-Item -ItemType Directory -Path $RunnerDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $RunnerDirectory -Force
}
Write-Host "Windows runner prerequisites are installed at '$RunnerDirectory'."
