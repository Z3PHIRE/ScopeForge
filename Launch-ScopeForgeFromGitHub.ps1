[CmdletBinding()]
param(
    [string]$RepositoryOwner = 'Z3PHIRE',
    [string]$RepositoryName = 'ScopeForge',
    [string]$Branch = 'main',
    [string]$BootstrapRoot,
    [Alias('Update')][switch]$ForceRefresh,
    [ValidateRange(0, 168)][int]$AutoRefreshHours = 24,
    [string]$ScopeFile,
    [string]$ProgramName,
    [string]$OutputDir,
    [int]$Depth = 3,
    [string]$UniqueUserAgent,
    [int]$Threads = 10,
    [int]$TimeoutSeconds = 30,
    [bool]$EnableGau = $true,
    [bool]$EnableWaybackUrls = $true,
    [bool]$EnableHakrawler = $true,
    [switch]$NoInstall,
    [switch]$Quiet,
    [switch]$IncludeApex,
    [switch]$RespectSchemeOnly,
    [switch]$Resume,
    [switch]$ConsoleMode,
    [switch]$RerunPrevious,
    [bool]$OpenReportOnFinish = $true,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BootstrapFilesToFetch {
    return @(
        'ScopeForge.ps1',
        'Launch-ScopeForge.ps1',
        'Launch-ScopeForge.cmd',
        'README.md',
        'examples/scope.json'
    )
}

function Get-BootstrapManifestPath {
    param([Parameter(Mandatory)][string]$BootstrapRoot)

    return (Join-Path $BootstrapRoot 'bootstrap-manifest.json')
}

function Get-BootstrapFileEntries {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string[]]$FilesToFetch
    )

    return @(
        foreach ($relativePath in $FilesToFetch) {
            $fullPath = Join-Path $BootstrapRoot $relativePath
            [pscustomobject]@{
                RelativePath = $relativePath
                FullPath     = $fullPath
                Exists       = (Test-Path -LiteralPath $fullPath)
            }
        }
    )
}

function Get-BootstrapCacheLastWriteTimeUtc {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string[]]$FilesToFetch
    )

    $latest = $null
    foreach ($entry in (Get-BootstrapFileEntries -BootstrapRoot $BootstrapRoot -FilesToFetch $FilesToFetch)) {
        if (-not $entry.Exists) { continue }
        $lastWriteUtc = (Get-Item -LiteralPath $entry.FullPath).LastWriteTimeUtc
        if ($null -eq $latest -or $lastWriteUtc -gt $latest) {
            $latest = $lastWriteUtc
        }
    }
    return $latest
}

function Test-BootstrapNeedsRefresh {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string[]]$FilesToFetch,
        [ValidateRange(0, 168)][int]$AutoRefreshHours = 24
    )

    foreach ($entry in (Get-BootstrapFileEntries -BootstrapRoot $BootstrapRoot -FilesToFetch $FilesToFetch)) {
        if (-not $entry.Exists) { return $true }
    }

    if ($AutoRefreshHours -le 0) { return $false }

    $lastWriteUtc = Get-BootstrapCacheLastWriteTimeUtc -BootstrapRoot $BootstrapRoot -FilesToFetch $FilesToFetch
    if ($null -eq $lastWriteUtc) { return $true }
    return ($lastWriteUtc -lt [DateTime]::UtcNow.AddHours(-1 * $AutoRefreshHours))
}

function Show-BootstrapStatusPanel {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string]$RepositoryOwner,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$LauncherPath,
        [AllowNull()][datetime]$UpdatedUtc,
        [Parameter(Mandatory)][bool]$WillRefresh,
        [Parameter(Mandatory)][bool]$ForcedRefresh,
        [ValidateRange(0, 168)][int]$AutoRefreshHours = 24
    )

    $statusText = if ($ForcedRefresh) {
        'Forced refresh requested'
    } elseif ($WillRefresh) {
        "Auto-refreshing cache older than $AutoRefreshHours hour(s)"
    } else {
        'Using cached bootstrap files'
    }

    Write-Host ''
    Write-Host '[Bootstrap]' -ForegroundColor Cyan
    Write-Host ("  Source            : https://github.com/{0}/{1} ({2})" -f $RepositoryOwner, $RepositoryName, $Branch) -ForegroundColor Gray
    Write-Host ("  CacheRoot         : {0}" -f $BootstrapRoot) -ForegroundColor Gray
    Write-Host ("  Launcher          : {0}" -f $LauncherPath) -ForegroundColor Gray
    Write-Host ("  Updated           : {0}" -f $(if ($UpdatedUtc) { $UpdatedUtc.ToString('u') } else { 'not downloaded yet' })) -ForegroundColor Gray
    Write-Host ("  Status            : {0}" -f $statusText) -ForegroundColor $(if ($WillRefresh) { 'Yellow' } else { 'Green' })
    Write-Host "  Refresh hint      : relance avec -Update ou -ForceRefresh pour retélécharger immédiatement le launcher et le runtime." -ForegroundColor DarkGray
}

function Write-BootstrapManifest {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string]$RepositoryOwner,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string[]]$FilesToFetch,
        [Parameter(Mandatory)][datetime]$LastRefreshUtc
    )

    $manifestPath = Get-BootstrapManifestPath -BootstrapRoot $BootstrapRoot
    $manifest = [ordered]@{
        ManifestVersion = 1
        RepositoryOwner = $RepositoryOwner
        RepositoryName  = $RepositoryName
        Branch          = $Branch
        BootstrapRoot   = $BootstrapRoot
        LastRefreshUtc  = $LastRefreshUtc.ToString('o')
        LauncherPath    = (Join-Path $BootstrapRoot 'Launch-ScopeForge.ps1')
        Files           = @(
            foreach ($entry in (Get-BootstrapFileEntries -BootstrapRoot $BootstrapRoot -FilesToFetch $FilesToFetch)) {
                [ordered]@{
                    RelativePath      = $entry.RelativePath
                    FullPath          = $entry.FullPath
                    Exists            = $entry.Exists
                    LastWriteTimeUtc  = $(if ($entry.Exists) { (Get-Item -LiteralPath $entry.FullPath).LastWriteTimeUtc.ToString('o') } else { $null })
                }
            }
        )
    }

    Set-Content -LiteralPath $manifestPath -Value ($manifest | ConvertTo-Json -Depth 10) -Encoding utf8
    return $manifestPath
}

function Invoke-ScopeForgeBootstrap {
    [CmdletBinding()]
    param(
        [string]$RepositoryOwner = 'Z3PHIRE',
        [string]$RepositoryName = 'ScopeForge',
        [string]$Branch = 'main',
        [string]$BootstrapRoot,
        [Alias('Update')][switch]$ForceRefresh,
        [ValidateRange(0, 168)][int]$AutoRefreshHours = 24,
        [string]$ScopeFile,
        [string]$ProgramName,
        [string]$OutputDir,
        [int]$Depth = 3,
        [string]$UniqueUserAgent,
        [int]$Threads = 10,
        [int]$TimeoutSeconds = 30,
        [bool]$EnableGau = $true,
        [bool]$EnableWaybackUrls = $true,
        [bool]$EnableHakrawler = $true,
        [switch]$NoInstall,
        [switch]$Quiet,
        [switch]$IncludeApex,
        [switch]$RespectSchemeOnly,
        [switch]$Resume,
        [switch]$ConsoleMode,
        [switch]$RerunPrevious,
        [bool]$OpenReportOnFinish = $true,
        [switch]$NonInteractive
    )

    if (-not $BootstrapRoot) {
        $BootstrapRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-Bootstrap" -f $RepositoryName)
    }

    $filesToFetch = Get-BootstrapFilesToFetch
    $baseRaw = "https://raw.githubusercontent.com/$RepositoryOwner/$RepositoryName/$Branch"
    $launcherPath = Join-Path $BootstrapRoot 'Launch-ScopeForge.ps1'
    $cacheUpdatedUtc = Get-BootstrapCacheLastWriteTimeUtc -BootstrapRoot $BootstrapRoot -FilesToFetch $filesToFetch
    $autoRefreshNeeded = Test-BootstrapNeedsRefresh -BootstrapRoot $BootstrapRoot -FilesToFetch $filesToFetch -AutoRefreshHours $AutoRefreshHours
    $refreshNow = ([bool]$ForceRefresh) -or $autoRefreshNeeded

    Show-BootstrapStatusPanel -BootstrapRoot $BootstrapRoot -RepositoryOwner $RepositoryOwner -RepositoryName $RepositoryName -Branch $Branch -LauncherPath $launcherPath -UpdatedUtc $cacheUpdatedUtc -WillRefresh:$refreshNow -ForcedRefresh:([bool]$ForceRefresh) -AutoRefreshHours $AutoRefreshHours

    foreach ($relativePath in $filesToFetch) {
        $targetPath = Join-Path $BootstrapRoot $relativePath
        $targetDirectory = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDirectory)) {
            $null = New-Item -ItemType Directory -Path $targetDirectory -Force
        }

        if ((-not $refreshNow) -and (Test-Path -LiteralPath $targetPath)) {
            continue
        }

        $uri = [Uri]("$baseRaw/$relativePath")
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'raw.githubusercontent.com') {
            throw "Refusing unexpected bootstrap source: $uri"
        }

        Write-Host ("Downloading {0}" -f $relativePath) -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $uri.AbsoluteUri -Headers @{ 'User-Agent' = 'ScopeForge-Bootstrap/1.0' } -OutFile $targetPath -TimeoutSec 60
        } catch {
            if ($ForceRefresh) {
                throw
            }
            if (Test-Path -LiteralPath $targetPath) {
                Write-Warning ("Refresh failed for {0}; using cached copy at {1}" -f $relativePath, $targetPath)
                continue
            }
            throw
        }
    }

    $refreshTimestampUtc = if ($refreshNow) { [DateTime]::UtcNow } elseif ($cacheUpdatedUtc) { $cacheUpdatedUtc } else { [DateTime]::UtcNow }
    $bootstrapManifestPath = Write-BootstrapManifest -BootstrapRoot $BootstrapRoot -RepositoryOwner $RepositoryOwner -RepositoryName $RepositoryName -Branch $Branch -FilesToFetch $filesToFetch -LastRefreshUtc $refreshTimestampUtc

    $env:SCOPEFORGE_BOOTSTRAP_ROOT = $BootstrapRoot
    $env:SCOPEFORGE_BOOTSTRAP_SOURCE = $baseRaw
    $env:SCOPEFORGE_BOOTSTRAP_UPDATED_AT = $refreshTimestampUtc.ToString('o')
    $env:SCOPEFORGE_BOOTSTRAP_REFRESH_REASON = $(if ($ForceRefresh) { 'forced by -Update/-ForceRefresh' } elseif ($refreshNow) { "auto-refresh after $AutoRefreshHours hour(s)" } else { 'cached bootstrap reused' })
    $env:SCOPEFORGE_BOOTSTRAP_MANIFEST = $bootstrapManifestPath
    $env:SCOPEFORGE_BOOTSTRAP_LAUNCHER = $launcherPath

    if ($env:OS -eq 'Windows_NT') {
        foreach ($scriptPath in @(
                (Join-Path $BootstrapRoot 'ScopeForge.ps1'),
                (Join-Path $BootstrapRoot 'Launch-ScopeForge.ps1'),
                (Join-Path $BootstrapRoot 'Launch-ScopeForge.cmd')
            )) {
            if (Test-Path -LiteralPath $scriptPath) {
                Unblock-File -LiteralPath $scriptPath -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not (Test-Path -LiteralPath $launcherPath)) {
        throw "Launcher file not found after bootstrap: $launcherPath"
    }

    $pwshCommand = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pwshCommand) {
        throw "PowerShell 7 (pwsh) est requis pour lancer ScopeForge. Installe pwsh puis relance la commande de bootstrap."
    }

    $launcherArgs = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $launcherPath
    )

    foreach ($name in @('ScopeFile', 'ProgramName', 'OutputDir', 'Depth', 'UniqueUserAgent', 'Threads', 'TimeoutSeconds')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $launcherArgs += @("-$name", [string]$PSBoundParameters[$name])
        }
    }

    foreach ($name in @('EnableGau', 'EnableWaybackUrls', 'EnableHakrawler', 'OpenReportOnFinish')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $launcherArgs += ("-{0}:{1}" -f $name, ([string]([bool]$PSBoundParameters[$name])).ToLowerInvariant())
        }
    }

    foreach ($name in @('NoInstall', 'Quiet', 'IncludeApex', 'RespectSchemeOnly', 'Resume', 'ConsoleMode', 'RerunPrevious', 'NonInteractive')) {
        if ($PSBoundParameters.ContainsKey($name) -and $PSBoundParameters[$name]) {
            $launcherArgs += "-$name"
        }
    }

    if ($VerbosePreference -eq 'Continue') {
        $launcherArgs += '-Verbose'
    }

    & $pwshCommand.Source @launcherArgs
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ScopeForgeBootstrap @PSBoundParameters
}
