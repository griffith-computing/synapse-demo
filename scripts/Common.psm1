#requires -Version 5.1
<#
.SYNOPSIS
    Shared helper functions used by all scripts under scripts/.

.DESCRIPTION
    Provides consistent logging, secret redaction, dependency checks,
    dry-run/offline execution helpers, checksum/manifest utilities, and
    cross-platform CI output helpers so the same scripts work unmodified
    from GitHub Actions, Azure DevOps, or a developer's own console.

    This module intentionally has ZERO required external dependencies
    (no Az module, no Pester, no network). Anything that needs an
    external tool (az CLI, git, etc.) is guarded by Test-CommandAvailable
    / Assert-DependencyAvailable so callers can fail fast and explicitly
    instead of silently reporting success.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Exit code contract - shared across all scripts so CI can branch on them.
# ---------------------------------------------------------------------------
$Script:SynapseExitCodes = @{
    Success             = 0
    ValidationFailed    = 1
    MissingDependency   = 2
    ExecutionFailed     = 3
    RollbackFailed       = 4
    InvalidArguments    = 5
}

function Get-SynapseExitCode {
    <#
        .SYNOPSIS
            Returns the stable numeric exit code for a named result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'ValidationFailed', 'MissingDependency', 'ExecutionFailed', 'RollbackFailed', 'InvalidArguments')]
        [string]$Name
    )
    return $Script:SynapseExitCodes[$Name]
}

# ---------------------------------------------------------------------------
# Secret redaction
# ---------------------------------------------------------------------------
# Patterns are intentionally broad. False positives (over-redaction) are
# acceptable; leaking a secret into CI logs is not.
$Script:SecretPatterns = @(
    '(?i)(AccountKey\s*=\s*)([^;\s]+)'
    '(?i)(SharedAccessSignature\s*=\s*)([^;\s]+)'
    '(?i)(SharedAccessKey\s*=\s*)([^;\s]+)'
    '(?i)(client[_-]?secret["'':=\s]+)([^\s"'',;]+)'
    '(?i)(password["'':=\s]+)([^\s"'',;]+)'
    '(?i)(pwd["'':=\s]+)([^\s"'',;]+)'
    '(?i)(token["'':=\s]+)([^\s"'',;]+)'
    '(?i)(apikey["'':=\s]+)([^\s"'',;]+)'
    '(?i)(secret["'':=\s]+)([^\s"'',;]+)'
    '(?i)(Authorization:\s*Bearer\s+)([A-Za-z0-9\-_\.]+)'
    '(?i)(sig=)([^&\s]+)'
    '(?i)(connectionstring["'':=\s]+)([^\s"'',;]+)'
)

function Protect-SynapseSecretText {
    <#
        .SYNOPSIS
            Redacts common secret-shaped substrings from a string before it
            is written to a log, host output, or CI pipeline variable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Text
    )
    process {
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        $result = $Text
        foreach ($pattern in $Script:SecretPatterns) {
            $result = [regex]::Replace($result, $pattern, '${1}***REDACTED***')
        }
        return $result
    }
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-SynapseLog {
    <#
        .SYNOPSIS
            Writes a timestamped, secret-redacted log line.
        .PARAMETER Level
            Info, Warning, Error, or Success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info',

        [Parameter()]
        [string]$LogPath
    )

    $safeMessage = Protect-SynapseSecretText -Text $Message
    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $line = "[$timestamp] [$Level] $safeMessage"

    switch ($Level) {
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Warning' { Write-Host $line -ForegroundColor Yellow }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Debug'   { Write-Verbose $line }
        default   { Write-Host $line }
    }

    if ($LogPath) {
        try {
            Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Host "[$timestamp] [Warning] Failed to write to log file '$LogPath': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# Dependency / environment checks
# ---------------------------------------------------------------------------
function Test-SynapseCommandAvailable {
    <#
        .SYNOPSIS
            Returns $true/$false - never throws. Use Assert-SynapseDependency
            when the caller needs fail-fast behavior.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Assert-SynapseDependency {
    <#
        .SYNOPSIS
            Verifies an external command exists. Fails explicitly unless the
            caller explicitly allows it to be skipped in offline/dry-run mode.
        .PARAMETER AllowMissingWhenOffline
            When set, a missing dependency while -Offline is in effect
            produces a warning + returns $false instead of throwing. This
            must be requested explicitly by the calling script - it is never
            the default - so success can never be silently invented.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [switch]$Offline,

        [Parameter()]
        [switch]$AllowMissingWhenOffline
    )

    if (Test-SynapseCommandAvailable -Name $Name) {
        return $true
    }

    if ($Offline -and $AllowMissingWhenOffline) {
        Write-SynapseLog -Level Warning -Message "Dependency '$Name' not found. Continuing because -Offline was specified and this check is marked skippable offline. No network/dependency-backed step was executed or reported as passed."
        return $false
    }

    throw "Required dependency '$Name' was not found on PATH. Install it or re-run with -Offline if this step supports offline simulation."
}

function Get-SynapsePipelineProvider {
    <#
        .SYNOPSIS
            Detects the CI provider so output variables can be emitted using
            the correct mechanism for GitHub Actions vs Azure DevOps.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:GITHUB_ACTIONS -eq 'true') { return 'GitHubActions' }
    if ($env:TF_BUILD -eq 'True' -or $env:TF_BUILD -eq 'true') { return 'AzureDevOps' }
    return 'Local'
}

function Set-SynapsePipelineOutput {
    <#
        .SYNOPSIS
            Emits a named output variable using whichever CI mechanism is
            active (GitHub Actions $GITHUB_OUTPUT file, Azure DevOps
            ##vso[task.setvariable], or plain host output locally). Values
            marked -Secret are redacted before ever reaching Write-Host and
            are marked secret in Azure DevOps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter()]
        [switch]$Secret
    )

    $provider = Get-SynapsePipelineProvider
    $displayValue = if ($Secret) { '***REDACTED***' } else { Protect-SynapseSecretText -Text $Value }

    switch ($provider) {
        'GitHubActions' {
            if ($env:GITHUB_OUTPUT) {
                # GitHub Actions' modern file-based output protocol.
                Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value"
            }
            Write-SynapseLog -Level Info -Message "[GitHubActions output] $Name=$displayValue"
        }
        'AzureDevOps' {
            $secretFlag = if ($Secret) { ';issecret=true' } else { '' }
            Write-Host "##vso[task.setvariable variable=$Name$secretFlag]$Value"
            Write-SynapseLog -Level Info -Message "[AzureDevOps output] $Name=$displayValue"
        }
        default {
            Write-SynapseLog -Level Info -Message "[Output] $Name=$displayValue"
        }
    }
}

# ---------------------------------------------------------------------------
# Command execution wrapper (dry-run aware)
# ---------------------------------------------------------------------------
function Invoke-SynapseManagedCommand {
    <#
        .SYNOPSIS
            Runs an external executable, honoring dry-run. Never invents a
            successful result: in dry-run it clearly marks the result as
            simulated and does not execute anything.
        .OUTPUTS
            PSCustomObject with: Simulated, ExitCode, StdOut, StdErr, Command
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$ArgumentList = @(),

        [Parameter()]
        [switch]$DryRun,

        [Parameter()]
        [string]$Description
    )

    $displayCommand = "$FilePath $($ArgumentList -join ' ')"
    $safeCommand = Protect-SynapseSecretText -Text $displayCommand

    if ($Description) {
        Write-SynapseLog -Level Info -Message $Description
    }

    if ($DryRun) {
        Write-SynapseLog -Level Info -Message "[DryRun] Would execute: $safeCommand"
        return [PSCustomObject]@{
            Simulated = $true
            ExitCode  = 0
            StdOut    = $null
            StdErr    = $null
            Command   = $safeCommand
        }
    }

    Write-SynapseLog -Level Info -Message "Executing: $safeCommand"

    $stdOutFile = [System.IO.Path]::GetTempFileName()
    $stdErrFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile
        $stdOut = Get-Content -LiteralPath $stdOutFile -Raw -ErrorAction SilentlyContinue
        $stdErr = Get-Content -LiteralPath $stdErrFile -Raw -ErrorAction SilentlyContinue

        if ($stdOut) { Write-SynapseLog -Level Info -Message ($stdOut.Trim()) }
        if ($stdErr) { Write-SynapseLog -Level Warning -Message ($stdErr.Trim()) }

        return [PSCustomObject]@{
            Simulated = $false
            ExitCode  = $process.ExitCode
            StdOut    = $stdOut
            StdErr    = $stdErr
            Command   = $safeCommand
        }
    } finally {
        Remove-Item -LiteralPath $stdOutFile, $stdErrFile -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Repository helpers
# ---------------------------------------------------------------------------
function Get-SynapseRepositoryRoot {
    <#
        .SYNOPSIS
            Resolves the git repository root. Falls back to the parent of
            the scripts/ folder when git metadata is unavailable (e.g. an
            extracted release package rather than a clone).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$StartPath = $PSScriptRoot
    )

    if (Test-SynapseCommandAvailable -Name 'git') {
        Push-Location -LiteralPath $StartPath
        try {
            $top = git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $top) {
                return ($top -replace '/', '\')
            }
        } finally {
            Pop-Location
        }
    }

    return (Resolve-Path (Join-Path $StartPath '..')).Path
}

# ---------------------------------------------------------------------------
# Checksum / manifest helpers
# ---------------------------------------------------------------------------
function Get-SynapseCommonAncestorPath {
    <#
        .SYNOPSIS
            Returns the deepest directory common to all supplied resolved
            paths (files or directories). Used so a multi-root package
            (e.g. infra/, synapse/, config/ packaged together) produces
            manifest/zip relative paths rooted at their shared ancestor
            (typically the repository root) rather than silently using the
            first path as an incorrect base for its siblings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ResolvedPath
    )

    $dirPaths = @($ResolvedPath | ForEach-Object {
        if ((Get-Item -LiteralPath $_).PSIsContainer) { $_ } else { Split-Path -Parent $_ }
    })

    if ($dirPaths.Count -eq 1) {
        return $dirPaths[0]
    }

    # Build segment arrays with an explicit loop (not a ForEach-Object
    # pipeline): PowerShell flattens nested arrays emitted from a pipeline,
    # so `@($dirPaths | ForEach-Object { $_ -split '...' })` would collapse
    # into one flat array of all segments across all paths instead of an
    # array-of-arrays, silently breaking the comparison below.
    $segmentSets = New-Object System.Collections.Generic.List[object]
    foreach ($dirPath in $dirPaths) {
        $segmentSets.Add(@($dirPath -split '[\\/]'))
    }
    $minLength = ($segmentSets | ForEach-Object { $_.Count } | Measure-Object -Minimum).Minimum

    $commonSegments = @()
    for ($i = 0; $i -lt $minLength; $i++) {
        $candidate = $segmentSets[0][$i]
        $matchesAll = $true
        foreach ($segments in $segmentSets) {
            if ($segments[$i] -ne $candidate) { $matchesAll = $false; break }
        }
        if (-not $matchesAll) { break }
        $commonSegments += $candidate
    }

    if ($commonSegments.Count -eq 0) {
        throw "Supplied paths have no common ancestor directory: $($ResolvedPath -join ', ')"
    }

    return ($commonSegments -join [System.IO.Path]::DirectorySeparatorChar)
}

function Get-SynapseFileManifestEntries {
    <#
        .SYNOPSIS
            Computes SHA256 + size for every file under one or more paths.
        .OUTPUTS
            Array of PSCustomObject: RelativePath, Sha256, SizeBytes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $entries = @()
    $resolvedBase = (Resolve-Path -LiteralPath $BasePath).Path

    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Source path not found: $p"
        }
        $resolved = Resolve-Path -LiteralPath $p
        $item = Get-Item -LiteralPath $resolved
        if ($item.PSIsContainer) {
            $files = Get-ChildItem -LiteralPath $resolved -Recurse -File
        } else {
            $files = @($item)
        }

        foreach ($file in $files) {
            $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            $relative = $file.FullName.Substring($resolvedBase.Length).TrimStart('\', '/')
            $entries += [PSCustomObject]@{
                RelativePath = $relative -replace '\\', '/'
                Sha256       = $hash.Hash
                SizeBytes    = $file.Length
            }
        }
    }

    # Callers should wrap this call in @(...) when they need guaranteed
    # array semantics (e.g. .Count) for a possible single-file result,
    # since PowerShell unwraps single-item pipeline output to a scalar on
    # simple assignment. Returning normally (rather than -NoEnumerate) is
    # required so pipe-chaining (e.g. `| Where-Object { ... }`) still
    # evaluates each entry individually instead of once against the whole
    # array.
    return $entries | Sort-Object RelativePath
}

function Test-SynapseFileManifest {
    <#
        .SYNOPSIS
            Verifies files on disk match the checksums recorded in a
            manifest.json produced by New-SynapseReleasePackage.ps1.
        .OUTPUTS
            PSCustomObject: IsValid, Mismatches (array), Missing (array)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $mismatches = @()
    $missing = @()

    foreach ($entry in $manifest.Files) {
        $directorySeparator = [string][System.IO.Path]::DirectorySeparatorChar
        $relativePath = ([string]$entry.RelativePath).Replace('/', $directorySeparator).Replace('\', $directorySeparator)
        $fullPath = Join-Path $BasePath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $missing += $entry.RelativePath
            continue
        }
        $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        if ($actualHash -ne $entry.Sha256) {
            $mismatches += [PSCustomObject]@{
                RelativePath = $entry.RelativePath
                Expected     = $entry.Sha256
                Actual       = $actualHash
            }
        }
    }

    return [PSCustomObject]@{
        IsValid    = ($mismatches.Count -eq 0 -and $missing.Count -eq 0)
        Mismatches = $mismatches
        Missing    = $missing
    }
}

function ConvertTo-SynapseStringArray {
    <#
        .SYNOPSIS
            Normalizes a [string[]] parameter value so both native
            PowerShell array literals AND a single comma-separated string
            work identically. This matters because PowerShell's `-File`
            invocation (the form GitHub Actions / Azure DevOps YAML steps
            use) does not parse array literals from the command line the
            way an in-session function call does - callers instead pass one
            comma-separated token, e.g. -RequiredPaths "a,b,c".
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]]$Value
    )

    if (-not $Value -or $Value.Count -eq 0) {
        return @()
    }
    if ($Value.Count -eq 1 -and $Value[0] -match ',') {
        return @($Value[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }
    return @($Value | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

Export-ModuleMember -Function @(
    'Get-SynapseExitCode'
    'Protect-SynapseSecretText'
    'Write-SynapseLog'
    'Test-SynapseCommandAvailable'
    'Assert-SynapseDependency'
    'Get-SynapsePipelineProvider'
    'Set-SynapsePipelineOutput'
    'Invoke-SynapseManagedCommand'
    'Get-SynapseRepositoryRoot'
    'Get-SynapseCommonAncestorPath'
    'Get-SynapseFileManifestEntries'
    'Test-SynapseFileManifest'
    'ConvertTo-SynapseStringArray'
)
