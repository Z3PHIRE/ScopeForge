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

function Write-BootstrapVerbose {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Color = 'DarkGray'
    )

    if ($VerbosePreference -eq 'Continue') {
        Write-Host ("  > {0}" -f $Message) -ForegroundColor $Color
    }
}

function Get-BootstrapFilesToFetch {
    return @(
        'ScopeForge.ps1',
        'Launch-ScopeForge.ps1',
        'Launch-ScopeForge.cmd',
        'README.md',
        'examples/scope.json'
    )
}

function Get-LocalBootstrapSourceRoot {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string[]]$FilesToFetch
    )

    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $null }

    try {
        $resolvedSourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    } catch {
        return $null
    }

    $resolvedBootstrapRoot = $null
    try {
        if (Test-Path -LiteralPath $BootstrapRoot) {
            $resolvedBootstrapRoot = (Resolve-Path -LiteralPath $BootstrapRoot).Path
        }
    } catch {
        $resolvedBootstrapRoot = $null
    }

    if ($resolvedBootstrapRoot -and ($resolvedSourceRoot.TrimEnd('\','/') -eq $resolvedBootstrapRoot.TrimEnd('\','/'))) {
        return $null
    }

    foreach ($relativePath in $FilesToFetch) {
        $candidatePath = Join-Path $resolvedSourceRoot $relativePath
        if (-not (Test-Path -LiteralPath $candidatePath)) {
            return $null
        }
    }

    return $resolvedSourceRoot
}

function Get-LocalBootstrapRefreshPlan {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string[]]$FilesToFetch
    )

    $missingFiles = [System.Collections.Generic.List[string]]::new()
    $newerFiles = [System.Collections.Generic.List[string]]::new()
    $latestSourceWriteUtc = $null

    foreach ($relativePath in $FilesToFetch) {
        $sourcePath = Join-Path $SourceRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) { continue }

        $sourceWriteUtc = (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc
        if ($null -eq $latestSourceWriteUtc -or $sourceWriteUtc -gt $latestSourceWriteUtc) {
            $latestSourceWriteUtc = $sourceWriteUtc
        }

        $targetPath = Join-Path $BootstrapRoot $relativePath
        if (-not (Test-Path -LiteralPath $targetPath)) {
            $missingFiles.Add($relativePath) | Out-Null
            continue
        }

        $targetWriteUtc = (Get-Item -LiteralPath $targetPath).LastWriteTimeUtc
        if ($sourceWriteUtc -gt $targetWriteUtc) {
            $newerFiles.Add($relativePath) | Out-Null
        }
    }

    $willRefresh = ($missingFiles.Count -gt 0) -or ($newerFiles.Count -gt 0)
    $refreshReason = if ($missingFiles.Count -gt 0) {
        'Local workspace contains bootstrap file(s) missing from the cache: {0}' -f ($missingFiles -join ', ')
    } elseif ($newerFiles.Count -gt 0) {
        'Local workspace contains newer bootstrap file(s): {0}' -f ($newerFiles -join ', ')
    } else {
        'Bootstrap cache already matches the local workspace files.'
    }

    return [pscustomobject]@{
        WillRefresh        = $willRefresh
        RefreshReason      = $refreshReason
        RemoteVersionKey   = $null
        AppliedVersionKey  = $(if ($latestSourceWriteUtc) { $latestSourceWriteUtc.ToString('o') } else { $null })
        VersionCheckStatus = 'Local workspace source detected.'
        CheckedAtUtc       = [DateTime]::UtcNow
        MissingFiles       = @($missingFiles)
        NewerFiles         = @($newerFiles)
        SourceRoot         = $SourceRoot
    }
}

function Get-BootstrapManifestPath {
    param([Parameter(Mandatory)][string]$BootstrapRoot)

    return (Join-Path $BootstrapRoot 'bootstrap-manifest.json')
}

function Read-BootstrapManifest {
    param([Parameter(Mandatory)][string]$BootstrapRoot)

    $manifestPath = Get-BootstrapManifestPath -BootstrapRoot $BootstrapRoot
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $null }

    try {
        return (Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        Write-Warning ("Bootstrap manifest is unreadable at {0}: {1}" -f $manifestPath, $_.Exception.Message)
        return $null
    }
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

function Get-BootstrapRemoteVersionKey {
    param(
        [Parameter(Mandatory)][string]$RepositoryOwner,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$Branch
    )

    $checkedAtUtc = [DateTime]::UtcNow
    $uri = "https://api.github.com/repos/$RepositoryOwner/$RepositoryName/commits/$Branch"
    Write-BootstrapVerbose -Message ("Checking upstream version key via {0}" -f $uri)

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers @{
            'User-Agent' = 'ScopeForge-Bootstrap/1.0'
            'Accept'     = 'application/vnd.github+json'
        } -Method Get -TimeoutSec 20

        $key = [string]$response.sha
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw 'GitHub API returned no commit sha.'
        }

        Write-BootstrapVerbose -Message ("Upstream version key: {0}" -f $key.Substring(0, [Math]::Min($key.Length, 12))) -Color 'DarkCyan'
        return [pscustomobject]@{
            Success      = $true
            Key          = $key
            CheckedAtUtc = $checkedAtUtc
            Status       = 'Remote version key loaded from GitHub.'
            Source       = 'github-commit'
            ErrorMessage = $null
        }
    } catch {
        Write-BootstrapVerbose -Message ("Upstream version check failed: {0}" -f $_.Exception.Message) -Color 'DarkYellow'
        return [pscustomobject]@{
            Success      = $false
            Key          = $null
            CheckedAtUtc = $checkedAtUtc
            Status       = 'Remote version key unavailable.'
            Source       = 'github-commit'
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-BootstrapRefreshPlan {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string]$RepositoryOwner,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string[]]$FilesToFetch,
        [Parameter(Mandatory)][bool]$ForceRefresh,
        [ValidateRange(0, 168)][int]$AutoRefreshHours = 24
    )

    $manifest = Read-BootstrapManifest -BootstrapRoot $BootstrapRoot
    $appliedVersionKey = if ($manifest -and $manifest.AppliedVersionKey) { [string]$manifest.AppliedVersionKey } else { $null }
    $fileEntries = @(Get-BootstrapFileEntries -BootstrapRoot $BootstrapRoot -FilesToFetch $FilesToFetch)
    $missingFiles = @($fileEntries | Where-Object { -not $_.Exists } | Select-Object -ExpandProperty RelativePath)
    $fallbackRefreshNeeded = Test-BootstrapNeedsRefresh -BootstrapRoot $BootstrapRoot -FilesToFetch $FilesToFetch -AutoRefreshHours $AutoRefreshHours
    $remoteVersion = Get-BootstrapRemoteVersionKey -RepositoryOwner $RepositoryOwner -RepositoryName $RepositoryName -Branch $Branch

    if ($ForceRefresh) {
        return [pscustomobject]@{
            WillRefresh        = $true
            RefreshReason      = 'Forced refresh requested.'
            RemoteVersionKey   = $remoteVersion.Key
            AppliedVersionKey  = $appliedVersionKey
            VersionCheckStatus = $(if ($remoteVersion.Success) { 'Remote version key loaded from GitHub.' } else { "Remote version key unavailable: $($remoteVersion.ErrorMessage)" })
            CheckedAtUtc       = $remoteVersion.CheckedAtUtc
            MissingFiles       = @($missingFiles)
        }
    }

    if ($remoteVersion.Success) {
        if ($missingFiles.Count -gt 0) {
            return [pscustomobject]@{
                WillRefresh        = $true
                RefreshReason      = ('Bootstrap cache is incomplete; refreshing missing file(s): {0}' -f ($missingFiles -join ', '))
                RemoteVersionKey   = $remoteVersion.Key
                AppliedVersionKey  = $appliedVersionKey
                VersionCheckStatus = 'Remote version key loaded from GitHub.'
                CheckedAtUtc       = $remoteVersion.CheckedAtUtc
                MissingFiles       = @($missingFiles)
            }
        }

        if ([string]::IsNullOrWhiteSpace($appliedVersionKey)) {
            return [pscustomobject]@{
                WillRefresh        = $true
                RefreshReason      = 'Bootstrap cache has no applied version key yet; refreshing once to stamp the local cache.'
                RemoteVersionKey   = $remoteVersion.Key
                AppliedVersionKey  = $null
                VersionCheckStatus = 'Remote version key loaded from GitHub.'
                CheckedAtUtc       = $remoteVersion.CheckedAtUtc
                MissingFiles       = @()
            }
        }

        if ($appliedVersionKey -ne $remoteVersion.Key) {
            return [pscustomobject]@{
                WillRefresh        = $true
                RefreshReason      = 'A newer upstream version key was detected; refreshing the bootstrap cache.'
                RemoteVersionKey   = $remoteVersion.Key
                AppliedVersionKey  = $appliedVersionKey
                VersionCheckStatus = 'Remote version key differs from the local cache.'
                CheckedAtUtc       = $remoteVersion.CheckedAtUtc
                MissingFiles       = @()
            }
        }

        return [pscustomobject]@{
            WillRefresh        = $false
            RefreshReason      = 'Bootstrap cache already matches the upstream version key.'
            RemoteVersionKey   = $remoteVersion.Key
            AppliedVersionKey  = $appliedVersionKey
            VersionCheckStatus = 'Remote version key matches the local cache.'
            CheckedAtUtc       = $remoteVersion.CheckedAtUtc
            MissingFiles       = @()
        }
    }

    return [pscustomobject]@{
        WillRefresh        = [bool]$fallbackRefreshNeeded
        RefreshReason      = $(if ($fallbackRefreshNeeded) { "Remote version check failed; fallback refresh enabled because the cache is missing or older than $AutoRefreshHours hour(s)." } else { 'Remote version check failed; reusing the cached bootstrap files.' })
        RemoteVersionKey   = $null
        AppliedVersionKey  = $appliedVersionKey
        VersionCheckStatus = ("Remote version key unavailable: {0}" -f $remoteVersion.ErrorMessage)
        CheckedAtUtc       = $remoteVersion.CheckedAtUtc
        MissingFiles       = @($missingFiles)
    }
}

function Show-BootstrapStatusPanel {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string]$SourceLabel,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Nullable[datetime]]$UpdatedUtc = $null,
        [Parameter(Mandatory)][bool]$WillRefresh,
        [Parameter(Mandatory)][bool]$ForcedRefresh,
        [Parameter(Mandatory)][string]$RefreshReason,
        [AllowNull()][string]$RemoteVersionKey,
        [AllowNull()][string]$AppliedVersionKey,
        [Parameter(Mandatory)][string]$VersionCheckStatus,
        [Nullable[datetime]]$CheckedAtUtc = $null,
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
    Write-Host ("  Source            : {0}" -f $SourceLabel) -ForegroundColor Gray
    Write-Host ("  CacheRoot         : {0}" -f $BootstrapRoot) -ForegroundColor Gray
    Write-Host ("  Launcher          : {0}" -f $LauncherPath) -ForegroundColor Gray
    Write-Host ("  Updated           : {0}" -f $(if ($UpdatedUtc) { $UpdatedUtc.ToString('u') } else { 'not downloaded yet' })) -ForegroundColor Gray
    Write-Host ("  VersionCheck      : {0}" -f $VersionCheckStatus) -ForegroundColor Gray
    Write-Host ("  RemoteKey         : {0}" -f $(if ($RemoteVersionKey) { $RemoteVersionKey.Substring(0, [Math]::Min($RemoteVersionKey.Length, 12)) } else { 'unavailable' })) -ForegroundColor Gray
    Write-Host ("  AppliedKey        : {0}" -f $(if ($AppliedVersionKey) { $AppliedVersionKey.Substring(0, [Math]::Min($AppliedVersionKey.Length, 12)) } else { 'not stamped yet' })) -ForegroundColor Gray
    Write-Host ("  Checked           : {0}" -f $(if ($CheckedAtUtc) { $CheckedAtUtc.ToString('u') } else { 'not checked' })) -ForegroundColor Gray
    Write-Host ("  Status            : {0}" -f $statusText) -ForegroundColor $(if ($WillRefresh) { 'Yellow' } else { 'Green' })
    Write-Host ("  Reason            : {0}" -f $RefreshReason) -ForegroundColor Gray
    Write-Host "  Refresh hint      : relance avec -Update ou -ForceRefresh pour retélécharger immédiatement le launcher et le runtime." -ForegroundColor DarkGray
    if ($VerbosePreference -eq 'Continue') {
        Write-Host ("  FallbackHours     : {0}" -f $AutoRefreshHours) -ForegroundColor DarkGray
    }
}

function Write-BootstrapManifest {
    param(
        [Parameter(Mandatory)][string]$BootstrapRoot,
        [Parameter(Mandatory)][string]$RepositoryOwner,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string[]]$FilesToFetch,
        [Parameter(Mandatory)][datetime]$LastRefreshUtc,
        [Nullable[datetime]]$LastCheckedUtc = $null,
        [AllowNull()][string]$AppliedVersionKey,
        [AllowNull()][string]$RemoteVersionKey,
        [AllowNull()][string]$VersionCheckStatus,
        [AllowNull()][string]$RefreshReason
    )

    $manifestPath = Get-BootstrapManifestPath -BootstrapRoot $BootstrapRoot
    $manifest = [ordered]@{
        ManifestVersion = 2
        RepositoryOwner = $RepositoryOwner
        RepositoryName  = $RepositoryName
        Branch          = $Branch
        BootstrapRoot   = $BootstrapRoot
        LastRefreshUtc  = $LastRefreshUtc.ToString('o')
        LastCheckedUtc  = $(if ($LastCheckedUtc) { $LastCheckedUtc.ToString('o') } else { $null })
        LauncherPath    = (Join-Path $BootstrapRoot 'Launch-ScopeForge.ps1')
        AppliedVersionKey = $AppliedVersionKey
        RemoteVersionKey  = $RemoteVersionKey
        VersionCheckStatus = $VersionCheckStatus
        RefreshReason      = $RefreshReason
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
    $localSourceRoot = Get-LocalBootstrapSourceRoot -BootstrapRoot $BootstrapRoot -FilesToFetch $filesToFetch
    $usingLocalWorkspace = -not [string]::IsNullOrWhiteSpace($localSourceRoot)
    $refreshPlan = if ($usingLocalWorkspace) {
        Get-LocalBootstrapRefreshPlan -BootstrapRoot $BootstrapRoot -SourceRoot $localSourceRoot -FilesToFetch $filesToFetch
    } else {
        Get-BootstrapRefreshPlan -BootstrapRoot $BootstrapRoot -RepositoryOwner $RepositoryOwner -RepositoryName $RepositoryName -Branch $Branch -FilesToFetch $filesToFetch -ForceRefresh:([bool]$ForceRefresh) -AutoRefreshHours $AutoRefreshHours
    }
    $refreshNow = [bool]$refreshPlan.WillRefresh

    $sourceLabel = if ($usingLocalWorkspace) { $localSourceRoot } else { "https://github.com/$RepositoryOwner/$RepositoryName ($Branch)" }
    Show-BootstrapStatusPanel -BootstrapRoot $BootstrapRoot -SourceLabel $sourceLabel -LauncherPath $launcherPath -UpdatedUtc $cacheUpdatedUtc -WillRefresh:$refreshNow -ForcedRefresh:([bool]$ForceRefresh) -RefreshReason $refreshPlan.RefreshReason -RemoteVersionKey $refreshPlan.RemoteVersionKey -AppliedVersionKey $refreshPlan.AppliedVersionKey -VersionCheckStatus $refreshPlan.VersionCheckStatus -CheckedAtUtc $refreshPlan.CheckedAtUtc -AutoRefreshHours $AutoRefreshHours

    foreach ($relativePath in $filesToFetch) {
        $targetPath = Join-Path $BootstrapRoot $relativePath
        $targetDirectory = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDirectory)) {
            $null = New-Item -ItemType Directory -Path $targetDirectory -Force
        }

        if ((-not $refreshNow) -and (Test-Path -LiteralPath $targetPath)) {
            Write-BootstrapVerbose -Message ("Using cached file: {0}" -f $relativePath)
            continue
        }

        if ($usingLocalWorkspace) {
            $sourcePath = Join-Path $localSourceRoot $relativePath
            $actionLabel = if (Test-Path -LiteralPath $targetPath) { 'Updating' } else { 'Copying' }
            Write-Host ("{0} {1}" -f $actionLabel, $relativePath) -ForegroundColor Cyan
            Write-BootstrapVerbose -Message ("Source: {0}" -f $sourcePath)
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            Write-BootstrapVerbose -Message ("Saved to: {0}" -f $targetPath) -Color 'DarkCyan'
            continue
        }

        $uri = [Uri]("$baseRaw/$relativePath")
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'raw.githubusercontent.com') {
            throw "Refusing unexpected bootstrap source: $uri"
        }

        $actionLabel = if (Test-Path -LiteralPath $targetPath) { 'Updating' } else { 'Downloading' }
        Write-Host ("{0} {1}" -f $actionLabel, $relativePath) -ForegroundColor Cyan
        Write-BootstrapVerbose -Message ("Source: {0}" -f $uri.AbsoluteUri)
        try {
            Invoke-WebRequest -Uri $uri.AbsoluteUri -Headers @{ 'User-Agent' = 'ScopeForge-Bootstrap/1.0' } -OutFile $targetPath -TimeoutSec 60
            Write-BootstrapVerbose -Message ("Saved to: {0}" -f $targetPath) -Color 'DarkCyan'
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
    $appliedVersionKey = if ($usingLocalWorkspace) {
        $refreshPlan.AppliedVersionKey
    } elseif ($refreshPlan.RemoteVersionKey) {
        $refreshPlan.RemoteVersionKey
    } elseif ($refreshNow) {
        $null
    } else {
        $refreshPlan.AppliedVersionKey
    }
    $bootstrapManifestPath = Write-BootstrapManifest -BootstrapRoot $BootstrapRoot -RepositoryOwner $RepositoryOwner -RepositoryName $RepositoryName -Branch $Branch -FilesToFetch $filesToFetch -LastRefreshUtc $refreshTimestampUtc -LastCheckedUtc $refreshPlan.CheckedAtUtc -AppliedVersionKey $appliedVersionKey -RemoteVersionKey $refreshPlan.RemoteVersionKey -VersionCheckStatus $refreshPlan.VersionCheckStatus -RefreshReason $refreshPlan.RefreshReason

    $env:SCOPEFORGE_BOOTSTRAP_ROOT = $BootstrapRoot
    $env:SCOPEFORGE_BOOTSTRAP_SOURCE = $(if ($usingLocalWorkspace) { $localSourceRoot } else { $baseRaw })
    $env:SCOPEFORGE_BOOTSTRAP_UPDATED_AT = $refreshTimestampUtc.ToString('o')
    $env:SCOPEFORGE_BOOTSTRAP_REFRESH_REASON = $refreshPlan.RefreshReason
    $env:SCOPEFORGE_BOOTSTRAP_MANIFEST = $bootstrapManifestPath
    $env:SCOPEFORGE_BOOTSTRAP_LAUNCHER = $launcherPath
    $env:SCOPEFORGE_BOOTSTRAP_REMOTE_VERSION_KEY = $(if ($refreshPlan.RemoteVersionKey) { $refreshPlan.RemoteVersionKey } else { '' })
    $env:SCOPEFORGE_BOOTSTRAP_APPLIED_VERSION_KEY = $(if ($appliedVersionKey) { $appliedVersionKey } else { '' })
    $env:SCOPEFORGE_BOOTSTRAP_VERSION_CHECK_STATUS = $refreshPlan.VersionCheckStatus

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
