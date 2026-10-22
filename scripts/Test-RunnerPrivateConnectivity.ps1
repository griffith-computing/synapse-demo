#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$StorageAccountName,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$WorkspaceName,
    [switch]$IncludeSql
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$targets = @(
    @{ HostName = "$StorageAccountName.blob.core.windows.net"; Port = 443 }
    @{ HostName = "$StorageAccountName.dfs.core.windows.net"; Port = 443 }
    @{ HostName = "$WorkspaceName.dev.azuresynapse.net"; Port = 443 }
)
if ($IncludeSql) {
    $targets += @{ HostName = "$WorkspaceName.sql.azuresynapse.net"; Port = 1433 }
    $targets += @{ HostName = "$WorkspaceName-ondemand.sql.azuresynapse.net"; Port = 1433 }
}
foreach ($target in $targets) {
    $addresses = @(Resolve-DnsName -Name $target.HostName -Type A -DnsOnly -ErrorAction Stop |
        Where-Object Type -EQ A | ForEach-Object { [Net.IPAddress]::Parse($_.IPAddress) })
    if ($addresses.Count -eq 0) { throw "No DNS addresses returned for '$($target.HostName)'." }
    foreach ($address in $addresses) {
        $bytes = $address.GetAddressBytes()
        $private = $bytes.Length -eq 4 -and (
            $bytes[0] -eq 10 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
        )
        if (-not $private) { throw "'$($target.HostName)' resolves to non-private address '$address'. Check private endpoint approval, DNS zone groups and VNet links." }
    }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($target.HostName, $target.Port)
        if (-not $task.Wait(10000)) { throw "Connection to '$($target.HostName):$($target.Port)' timed out." }
        $task.GetAwaiter().GetResult()
        Write-Host "Private DNS and TCP access verified: $($target.HostName):$($target.Port)"
    } finally {
        $client.Dispose()
    }
}
