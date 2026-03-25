[CmdletBinding()]
param(
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

function Write-LauncherBanner {
    Write-Host ''
    Write-Host '=========================================' -ForegroundColor DarkCyan
    Write-Host ' ScopeForge Launcher' -ForegroundColor Cyan
    Write-Host ' Guided recon runner for authorized scope' -ForegroundColor Gray
    Write-Host '=========================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Read-LauncherValue {
    param([string]$Prompt, [string]$Default = '')
    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $value = Read-Host $label
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Read-LauncherChoice {
    param([string]$Prompt, [string[]]$Allowed, [string]$Default)
    while ($true) {
        $value = Read-LauncherValue -Prompt $Prompt -Default $Default
        if ($Allowed -contains $value) { return $value }
        Write-Host "Choix invalide. Valeurs autorisées: $($Allowed -join ', ')" -ForegroundColor Yellow
    }
}

function Read-LauncherYesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $defaultText = if ($Default) { 'Y' } else { 'N' }
    return (Read-LauncherChoice -Prompt "$Prompt (Y/N)" -Allowed @('Y', 'N', 'y', 'n') -Default $defaultText).ToUpperInvariant() -eq 'Y'
}

function Read-MultilineScopeJson {
    Write-Host ''
    Write-Host 'Colle ici le JSON complet du scope.' -ForegroundColor Cyan
    Write-Host 'Termine la saisie par une ligne contenant uniquement END_SCOPE' -ForegroundColor Gray
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Read-Host
        if ($line -eq 'END_SCOPE') { break }
        $lines.Add($line) | Out-Null
    }
    return ($lines -join [Environment]::NewLine)
}

function New-GuidedScopeJson {
    $items = [System.Collections.Generic.List[object]]::new()
    do {
        Write-Host ''
        $typeChoice = Read-LauncherChoice -Prompt 'Type d''item: 1=URL 2=Wildcard 3=Domain' -Allowed @('1', '2', '3') -Default '1'
        $type = switch ($typeChoice) { '1' { 'URL' } '2' { 'Wildcard' } '3' { 'Domain' } }
        $value = Read-LauncherValue -Prompt 'Valeur'
        $exclusionText = Read-LauncherValue -Prompt 'Exclusions séparées par des virgules' -Default ''
        $exclusions = if ($exclusionText) { @($exclusionText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
        $items.Add([pscustomobject]@{ type = $type; value = $value; exclusions = $exclusions }) | Out-Null
    } while (Read-LauncherYesNo -Prompt 'Ajouter un autre item ?' -Default $false)
    return ($items | ConvertTo-Json -Depth 10)
}

function Save-ScopeJsonToTempFile {
    param([Parameter(Mandatory)][string]$ScopeJson)
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-scope-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $tempPath -Value $ScopeJson -Encoding utf8
    return $tempPath
}

function Show-InterestingSummary {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Write-Host ''
    Write-Host 'Pages intéressantes' -ForegroundColor Yellow
    if (-not $Result.InterestingUrls -or $Result.InterestingUrls.Count -eq 0) {
        Write-Host '  Aucune URL prioritaire n''a été remontée par les heuristiques.' -ForegroundColor Gray
        return
    }
    foreach ($item in ($Result.InterestingUrls | Select-Object -First 15)) {
        Write-Host ("  [{0}] {1}" -f $item.Score, $item.Url) -ForegroundColor DarkYellow
        if ($item.Categories) { Write-Host ("      {0}" -f ($item.Categories -join ', ')) -ForegroundColor Gray }
    }
}

function Start-ScopeForgeLauncher {
    [CmdletBinding()]
    param(
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

    $scopeForgePath = Join-Path $PSScriptRoot 'ScopeForge.ps1'
    if (-not (Test-Path -LiteralPath $scopeForgePath)) { throw "ScopeForge.ps1 introuvable à côté du launcher: $scopeForgePath" }
    . $scopeForgePath

    $localScopeFile = $ScopeFile
    if (-not $NonInteractive) {
        Write-LauncherBanner
        if (-not $localScopeFile) {
            $mode = Read-LauncherChoice -Prompt 'Source du scope: 1=fichier 2=coller JSON 3=assistant guidé' -Allowed @('1', '2', '3') -Default '2'
            switch ($mode) {
                '1' { $localScopeFile = Read-LauncherValue -Prompt 'Chemin du scope.json' }
                '2' { $localScopeFile = Save-ScopeJsonToTempFile -ScopeJson (Read-MultilineScopeJson) }
                '3' { $localScopeFile = Save-ScopeJsonToTempFile -ScopeJson (New-GuidedScopeJson) }
            }
        }

        if (-not $ProgramName) { $ProgramName = Read-LauncherValue -Prompt 'Nom du programme' -Default 'authorized-bugbounty' }
        if (-not $OutputDir) { $OutputDir = Read-LauncherValue -Prompt 'Dossier de sortie' -Default (Join-Path (Get-Location).Path 'output') }
        $Depth = [int](Read-LauncherValue -Prompt 'Profondeur de crawl' -Default ([string]$Depth))
        if (-not $UniqueUserAgent) { $UniqueUserAgent = Read-LauncherValue -Prompt 'User-Agent unique' -Default ("researcher-" + ([Guid]::NewGuid().ToString('N').Substring(0, 8))) }
        $Threads = [int](Read-LauncherValue -Prompt 'Threads' -Default ([string]$Threads))
        $TimeoutSeconds = [int](Read-LauncherValue -Prompt 'Timeout secondes' -Default ([string]$TimeoutSeconds))
        $IncludeApex = [bool](Read-LauncherYesNo -Prompt 'Inclure l''apex des wildcards ?' -Default ([bool]$IncludeApex))
        $RespectSchemeOnly = [bool](Read-LauncherYesNo -Prompt 'Respecter strictement le schéma explicite ?' -Default ([bool]$RespectSchemeOnly))
        $NoInstall = [bool](Read-LauncherYesNo -Prompt 'Désactiver le bootstrap outils ?' -Default ([bool]$NoInstall))
        $Resume = [bool](Read-LauncherYesNo -Prompt 'Activer le mode reprise ?' -Default ([bool]$Resume))

        Write-Host ''
        Write-Host 'Lancement avec les paramètres suivants :' -ForegroundColor Cyan
        Write-Host ("  ScopeFile       : {0}" -f $localScopeFile) -ForegroundColor Gray
        Write-Host ("  ProgramName     : {0}" -f $ProgramName) -ForegroundColor Gray
        Write-Host ("  OutputDir       : {0}" -f $OutputDir) -ForegroundColor Gray
        Write-Host ("  Depth           : {0}" -f $Depth) -ForegroundColor Gray
        Write-Host ("  UniqueUserAgent : {0}" -f $UniqueUserAgent) -ForegroundColor Gray
        if (-not (Read-LauncherYesNo -Prompt 'Confirmer le lancement ?' -Default $true)) { return }
    }

    $invokeParams = @{
        ScopeFile         = $localScopeFile
        ProgramName       = $ProgramName
        OutputDir         = $OutputDir
        Depth             = $Depth
        UniqueUserAgent   = $UniqueUserAgent
        Threads           = $Threads
        TimeoutSeconds    = $TimeoutSeconds
        NoInstall         = [bool]$NoInstall
        Quiet             = [bool]$Quiet
        IncludeApex       = [bool]$IncludeApex
        RespectSchemeOnly = [bool]$RespectSchemeOnly
        Resume            = [bool]$Resume
    }

    $result = Invoke-BugBountyRecon @invokeParams
    Show-InterestingSummary -Result $result
    Write-Host ''
    Write-Host ("Rapport HTML : {0}" -f (Join-Path $result.OutputDir 'reports/report.html')) -ForegroundColor Green
    Write-Host ("Interesting  : {0}" -f (Join-Path $result.OutputDir 'normalized/interesting_urls.json')) -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-ScopeForgeLauncher @PSBoundParameters
}
