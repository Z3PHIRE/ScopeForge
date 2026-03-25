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
    Clear-Host
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor DarkCyan
    Write-Host ' ScopeForge Assistant' -ForegroundColor Cyan
    Write-Host ' Guided recon runner for authorized programs' -ForegroundColor Gray
    Write-Host '=============================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-LauncherSection {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ("[{0}]" -f $Title) -ForegroundColor Cyan
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
    Write-LauncherSection -Title 'Collage du scope'
    Write-Host 'Colle ici le JSON complet du scope.' -ForegroundColor Cyan
    Write-Host 'Termine par une ligne contenant uniquement END_SCOPE' -ForegroundColor Gray
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Read-Host
        if ($line -eq 'END_SCOPE') { break }
        $lines.Add($line) | Out-Null
    }
    return ($lines -join [Environment]::NewLine)
}

function New-GuidedScopeJson {
    Write-LauncherSection -Title 'Assistant scope'
    $items = [System.Collections.Generic.List[object]]::new()
    do {
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

function Get-LauncherPreset {
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name.ToLowerInvariant()) {
        'safe' {
            return [pscustomobject]@{ Name = 'safe'; Depth = 2; Threads = 6; TimeoutSeconds = 20; RespectSchemeOnly = $true; Resume = $false; Label = 'Minimal and cautious' }
        }
        'balanced' {
            return [pscustomobject]@{ Name = 'balanced'; Depth = 3; Threads = 10; TimeoutSeconds = 30; RespectSchemeOnly = $false; Resume = $false; Label = 'Default recon profile' }
        }
        'deep' {
            return [pscustomobject]@{ Name = 'deep'; Depth = 4; Threads = 20; TimeoutSeconds = 45; RespectSchemeOnly = $false; Resume = $true; Label = 'Broader crawl for larger scopes' }
        }
        default {
            throw "Unknown preset: $Name"
        }
    }
}

function Select-LauncherPreset {
    Write-LauncherSection -Title 'Preset'
    Write-Host '1. safe      : minimal and cautious' -ForegroundColor Gray
    Write-Host '2. balanced  : default recon profile' -ForegroundColor Gray
    Write-Host '3. deep      : broader crawl for larger scopes' -ForegroundColor Gray
    $choice = Read-LauncherChoice -Prompt 'Choisis un preset' -Allowed @('1', '2', '3') -Default '2'
    switch ($choice) {
        '1' { return Get-LauncherPreset -Name 'safe' }
        '2' { return Get-LauncherPreset -Name 'balanced' }
        '3' { return Get-LauncherPreset -Name 'deep' }
    }
}

function Show-ScopePreview {
    param([Parameter(Mandatory)][pscustomobject[]]$ScopeItems)
    Write-LauncherSection -Title 'Scope validé'
    $rows = $ScopeItems | ForEach-Object {
        [pscustomobject]@{
            Id         = $_.Id
            Type       = $_.Type
            Value      = $_.NormalizedValue
            Exclusions = ($_.Exclusions -join ', ')
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function Show-LauncherConfigPreview {
    param([Parameter(Mandatory)][hashtable]$RunConfig)
    Write-LauncherSection -Title 'Configuration'
    Write-Host ("  ScopeFile         : {0}" -f $RunConfig.ScopeFile) -ForegroundColor Gray
    Write-Host ("  ProgramName       : {0}" -f $RunConfig.ProgramName) -ForegroundColor Gray
    Write-Host ("  OutputDir         : {0}" -f $RunConfig.OutputDir) -ForegroundColor Gray
    Write-Host ("  Depth             : {0}" -f $RunConfig.Depth) -ForegroundColor Gray
    Write-Host ("  Threads           : {0}" -f $RunConfig.Threads) -ForegroundColor Gray
    Write-Host ("  TimeoutSeconds    : {0}" -f $RunConfig.TimeoutSeconds) -ForegroundColor Gray
    Write-Host ("  UniqueUserAgent   : {0}" -f $RunConfig.UniqueUserAgent) -ForegroundColor Gray
    Write-Host ("  IncludeApex       : {0}" -f $RunConfig.IncludeApex) -ForegroundColor Gray
    Write-Host ("  RespectSchemeOnly : {0}" -f $RunConfig.RespectSchemeOnly) -ForegroundColor Gray
    Write-Host ("  NoInstall         : {0}" -f $RunConfig.NoInstall) -ForegroundColor Gray
    Write-Host ("  Resume            : {0}" -f $RunConfig.Resume) -ForegroundColor Gray
}

function Show-RunSummaryDashboard {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $summary = $Result.Summary
    Write-LauncherSection -Title 'Dashboard'
    Write-Host ("  Scope items      : {0}" -f $summary.ScopeItemCount) -ForegroundColor Gray
    Write-Host ("  Excluded         : {0}" -f $summary.ExcludedItemCount) -ForegroundColor Gray
    Write-Host ("  Hosts discovered : {0}" -f $summary.DiscoveredHostCount) -ForegroundColor Gray
    Write-Host ("  Live hosts       : {0}" -f $summary.LiveHostCount) -ForegroundColor Gray
    Write-Host ("  Live targets     : {0}" -f $summary.LiveTargetCount) -ForegroundColor Gray
    Write-Host ("  URLs discovered  : {0}" -f $summary.DiscoveredUrlCount) -ForegroundColor Gray
    Write-Host ("  Interesting URLs : {0}" -f $summary.InterestingUrlCount) -ForegroundColor Gray
    Write-Host ("  Errors           : {0}" -f $summary.ErrorCount) -ForegroundColor Gray

    if ($summary.TopTechnologies -and $summary.TopTechnologies.Count -gt 0) {
        Write-Host ''
        Write-Host '  Top technologies' -ForegroundColor Cyan
        foreach ($item in ($summary.TopTechnologies | Select-Object -First 5)) {
            Write-Host ("    {0} ({1})" -f $item.Technology, $item.Count) -ForegroundColor Gray
        }
    }

    if ($summary.TopInterestingCategories -and $summary.TopInterestingCategories.Count -gt 0) {
        Write-Host ''
        Write-Host '  Interesting categories' -ForegroundColor Cyan
        foreach ($item in ($summary.TopInterestingCategories | Select-Object -First 5)) {
            Write-Host ("    {0} ({1})" -f $item.Category, $item.Count) -ForegroundColor Gray
        }
    }
}

function Show-InterestingSummary {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Write-LauncherSection -Title 'Pages intéressantes'
    if (-not $Result.InterestingUrls -or $Result.InterestingUrls.Count -eq 0) {
        Write-Host '  Aucune URL prioritaire n''a été remontée par les heuristiques.' -ForegroundColor Gray
        return
    }
    foreach ($item in ($Result.InterestingUrls | Select-Object -First 15)) {
        Write-Host ("  [{0}] {1}" -f $item.Score, $item.Url) -ForegroundColor DarkYellow
        if ($item.Categories) { Write-Host ("      {0}" -f ($item.Categories -join ', ')) -ForegroundColor Gray }
        if ($item.Reasons) { Write-Host ("      {0}" -f ($item.Reasons -join '; ')) -ForegroundColor DarkGray }
    }
}

function Show-InterestingCategoryBreakdown {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Write-LauncherSection -Title 'Répartition intéressante'
    $groups = $Result.InterestingUrls | ForEach-Object { $_.Categories } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending
    if ($groups.Count -eq 0) {
        Write-Host '  Aucune catégorie à afficher.' -ForegroundColor Gray
        return
    }
    foreach ($group in $groups) {
        Write-Host ("  {0,-18} {1,5}" -f $group.Name, $group.Count) -ForegroundColor Gray
    }
}

function Show-ProtectedEndpoints {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Write-LauncherSection -Title 'Endpoints protégés'
    $protected = $Result.LiveTargets | Where-Object { $_.StatusCode -in 401, 403 } | Sort-Object -Property StatusCode, Url | Select-Object -First 20
    if ($protected.Count -eq 0) {
        Write-Host '  Aucun endpoint 401/403 dans les résultats live.' -ForegroundColor Gray
        return
    }
    foreach ($item in $protected) {
        Write-Host ("  [{0}] {1}" -f $item.StatusCode, $item.Url) -ForegroundColor Gray
    }
}

function Show-OutputPaths {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Write-LauncherSection -Title 'Exports'
    Write-Host ("  HTML report : {0}" -f (Join-Path $Result.OutputDir 'reports/report.html')) -ForegroundColor Green
    Write-Host ("  Markdown    : {0}" -f (Join-Path $Result.OutputDir 'reports/triage.md')) -ForegroundColor Green
    Write-Host ("  Interesting : {0}" -f (Join-Path $Result.OutputDir 'normalized/interesting_urls.json')) -ForegroundColor Green
}

function Show-PostRunMenu {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    while ($true) {
        Write-LauncherSection -Title 'Actions'
        Write-Host '1. Revoir les pages intéressantes' -ForegroundColor Gray
        Write-Host '2. Voir les catégories intéressantes' -ForegroundColor Gray
        Write-Host '3. Voir les endpoints protégés' -ForegroundColor Gray
        Write-Host '4. Voir les chemins d''export' -ForegroundColor Gray
        Write-Host '5. Terminer' -ForegroundColor Gray
        $choice = Read-LauncherChoice -Prompt 'Action' -Allowed @('1', '2', '3', '4', '5') -Default '5'
        switch ($choice) {
            '1' { Show-InterestingSummary -Result $Result }
            '2' { Show-InterestingCategoryBreakdown -Result $Result }
            '3' { Show-ProtectedEndpoints -Result $Result }
            '4' { Show-OutputPaths -Result $Result }
            '5' { break }
        }
    }
}

function Get-InteractiveScopeFile {
    $mode = Read-LauncherChoice -Prompt 'Source du scope: 1=fichier 2=coller JSON 3=assistant guidé 4=exemple local' -Allowed @('1', '2', '3', '4') -Default '2'
    switch ($mode) {
        '1' { return (Read-LauncherValue -Prompt 'Chemin du scope.json') }
        '2' { return (Save-ScopeJsonToTempFile -ScopeJson (Read-MultilineScopeJson)) }
        '3' { return (Save-ScopeJsonToTempFile -ScopeJson (New-GuidedScopeJson)) }
        '4' { return (Join-Path $PSScriptRoot 'examples/scope.json') }
    }
}

function Build-InteractiveRunConfig {
    param(
        [Parameter(Mandatory)][string]$InitialScopeFile,
        [string]$ProgramName,
        [string]$OutputDir,
        [int]$Depth,
        [string]$UniqueUserAgent,
        [int]$Threads,
        [int]$TimeoutSeconds,
        [bool]$NoInstall,
        [bool]$Quiet,
        [bool]$IncludeApex,
        [bool]$RespectSchemeOnly,
        [bool]$Resume
    )

    $preset = Select-LauncherPreset
    $localDepth = $preset.Depth
    $localThreads = $preset.Threads
    $localTimeout = $preset.TimeoutSeconds
    $localRespectSchemeOnly = $preset.RespectSchemeOnly
    $localResume = $preset.Resume

    if ($Depth -gt 0) { $localDepth = $Depth }
    if ($Threads -gt 0) { $localThreads = $Threads }
    if ($TimeoutSeconds -gt 0) { $localTimeout = $TimeoutSeconds }
    if ($PSBoundParameters.ContainsKey('RespectSchemeOnly')) { $localRespectSchemeOnly = $RespectSchemeOnly }
    if ($PSBoundParameters.ContainsKey('Resume')) { $localResume = $Resume }

    $localScopeFile = if ($InitialScopeFile) { $InitialScopeFile } else { Get-InteractiveScopeFile }
    $localProgramName = if ($ProgramName) { $ProgramName } else { 'authorized-bugbounty' }
    $localOutputDir = if ($OutputDir) { $OutputDir } else { Join-Path (Get-Location).Path 'output' }
    $localUserAgent = if ($UniqueUserAgent) { $UniqueUserAgent } else { "researcher-" + ([Guid]::NewGuid().ToString('N').Substring(0, 8)) }

    Write-LauncherSection -Title 'Ajustements'
    $localProgramName = Read-LauncherValue -Prompt 'Nom du programme' -Default $localProgramName
    $localOutputDir = Read-LauncherValue -Prompt 'Dossier de sortie' -Default $localOutputDir
    $localDepth = [int](Read-LauncherValue -Prompt 'Profondeur de crawl' -Default ([string]$localDepth))
    $localUserAgent = Read-LauncherValue -Prompt 'User-Agent unique' -Default $localUserAgent
    $localThreads = [int](Read-LauncherValue -Prompt 'Threads' -Default ([string]$localThreads))
    $localTimeout = [int](Read-LauncherValue -Prompt 'Timeout secondes' -Default ([string]$localTimeout))
    $localIncludeApex = [bool](Read-LauncherYesNo -Prompt 'Inclure l''apex des wildcards ?' -Default $IncludeApex)
    $localRespectSchemeOnly = [bool](Read-LauncherYesNo -Prompt 'Respecter strictement le schéma explicite ?' -Default $localRespectSchemeOnly)
    $localNoInstall = [bool](Read-LauncherYesNo -Prompt 'Désactiver le bootstrap outils ?' -Default $NoInstall)
    $localResume = [bool](Read-LauncherYesNo -Prompt 'Activer le mode reprise ?' -Default $localResume)

    return @{
        ScopeFile         = $localScopeFile
        ProgramName       = $localProgramName
        OutputDir         = $localOutputDir
        Depth             = $localDepth
        UniqueUserAgent   = $localUserAgent
        Threads           = $localThreads
        TimeoutSeconds    = $localTimeout
        NoInstall         = $localNoInstall
        Quiet             = $Quiet
        IncludeApex       = $localIncludeApex
        RespectSchemeOnly = $localRespectSchemeOnly
        Resume            = $localResume
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

    $runConfig = @{
        ScopeFile         = $ScopeFile
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

    if (-not $NonInteractive) {
        Write-LauncherBanner
        $runConfig = Build-InteractiveRunConfig -InitialScopeFile $ScopeFile -ProgramName $ProgramName -OutputDir $OutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -NoInstall ([bool]$NoInstall) -Quiet ([bool]$Quiet) -IncludeApex ([bool]$IncludeApex) -RespectSchemeOnly ([bool]$RespectSchemeOnly) -Resume ([bool]$Resume)
        $scopePreview = Read-ScopeFile -Path $runConfig.ScopeFile -IncludeApex:([bool]$runConfig.IncludeApex)
        Show-ScopePreview -ScopeItems $scopePreview
        Show-LauncherConfigPreview -RunConfig $runConfig
        if (-not (Read-LauncherYesNo -Prompt 'Confirmer le lancement ?' -Default $true)) { return }
    }

    $result = Invoke-BugBountyRecon @runConfig
    Show-RunSummaryDashboard -Result $result
    Show-InterestingSummary -Result $result
    Show-OutputPaths -Result $result

    if (-not $NonInteractive) {
        Show-PostRunMenu -Result $result
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-ScopeForgeLauncher @PSBoundParameters
}
