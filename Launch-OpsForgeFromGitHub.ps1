[CmdletBinding()]
param(
    [string]$RepositoryOwner = 'Z3PHIRE',
    [string]$RepositoryName = 'OpsForge',
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
    [switch]$NoInstall,
    [switch]$Quiet,
    [switch]$IncludeApex,
    [switch]$RespectSchemeOnly,
    [switch]$Resume,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $BootstrapRoot) {
    $BootstrapRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'OpsForge-Bootstrap'
}

$baseRaw = "https://raw.githubusercontent.com/$RepositoryOwner/$RepositoryName/$Branch"
$filesToFetch = @(
    'ScopeForge.ps1',
    'Launch-ScopeForge.ps1',
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
    Invoke-WebRequest -Uri $uri.AbsoluteUri -Headers @{ 'User-Agent' = 'OpsForge-Bootstrap/1.0' } -OutFile $targetPath -TimeoutSec 60
}

$launcherPath = Join-Path $BootstrapRoot 'Launch-ScopeForge.ps1'
if (-not (Test-Path -LiteralPath $launcherPath)) {
    throw "Launcher file not found after bootstrap: $launcherPath"
}

$launcherParams = @{}
foreach ($name in @('ScopeFile', 'ProgramName', 'OutputDir', 'Depth', 'UniqueUserAgent', 'Threads', 'TimeoutSeconds', 'NoInstall', 'Quiet', 'IncludeApex', 'RespectSchemeOnly', 'Resume', 'NonInteractive')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $launcherParams[$name] = $PSBoundParameters[$name]
    }
}

& $launcherPath @launcherParams
