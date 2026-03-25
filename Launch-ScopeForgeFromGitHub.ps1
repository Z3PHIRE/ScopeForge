[CmdletBinding()]
param(
    [string]$RepositoryOwner = 'Z3PHIRE',
    [string]$RepositoryName = 'ScopeForge',
    [string]$Branch = 'main',
    [string]$BootstrapRoot,
    [switch]$ForceRefresh,
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
    [bool]$OpenReportOnFinish = $true,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $BootstrapRoot) {
    $BootstrapRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'ScopeForge-Bootstrap'
}

$baseRaw = "https://raw.githubusercontent.com/$RepositoryOwner/$RepositoryName/$Branch"
$filesToFetch = @(
    'ScopeForge.ps1',
    'Launch-ScopeForge.ps1',
    'Launch-ScopeForge.cmd',
    'README.md',
    'examples/scope.json'
)

foreach ($relativePath in $filesToFetch) {
    $targetPath = Join-Path $BootstrapRoot $relativePath
    $targetDirectory = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $targetDirectory)) {
        $null = New-Item -ItemType Directory -Path $targetDirectory -Force
    }

    if ((-not $ForceRefresh) -and (Test-Path -LiteralPath $targetPath)) {
        continue
    }

    $uri = [Uri]("$baseRaw/$relativePath")
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'raw.githubusercontent.com') {
        throw "Refusing unexpected bootstrap source: $uri"
    }

    Write-Host ("Downloading {0}" -f $relativePath) -ForegroundColor Cyan
    Invoke-WebRequest -Uri $uri.AbsoluteUri -Headers @{ 'User-Agent' = 'ScopeForge-Bootstrap/1.0' } -OutFile $targetPath -TimeoutSec 60
}

if ($IsWindows) {
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

$launcherPath = Join-Path $BootstrapRoot 'Launch-ScopeForge.ps1'
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

foreach ($name in @('ScopeFile', 'ProgramName', 'OutputDir', 'Depth', 'UniqueUserAgent', 'Threads', 'TimeoutSeconds', 'EnableGau', 'EnableWaybackUrls', 'EnableHakrawler', 'OpenReportOnFinish')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $launcherArgs += @("-$name", [string]$PSBoundParameters[$name])
    }
}

foreach ($name in @('NoInstall', 'Quiet', 'IncludeApex', 'RespectSchemeOnly', 'Resume', 'ConsoleMode', 'NonInteractive')) {
    if ($PSBoundParameters.ContainsKey($name) -and $PSBoundParameters[$name]) {
        $launcherArgs += "-$name"
    }
}

& $pwshCommand.Source @launcherArgs
