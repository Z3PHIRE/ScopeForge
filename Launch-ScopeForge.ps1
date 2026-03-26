[CmdletBinding()]
param(
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

function Write-LauncherBanner {
    try {
        Clear-Host
    } catch {
    }
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

function Get-LauncherConsoleWidth {
    try {
        return [Math]::Max($Host.UI.RawUI.BufferSize.Width, 100)
    } catch {
        return 120
    }
}

function ConvertTo-LauncherCellText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return (($Value | ForEach-Object { [string]$_ }) -join ', ')
    }
    return [string]$Value
}

function Split-LauncherWrappedText {
    param(
        [AllowNull()][object]$Value,
        [int]$Width = 32
    )

    $safeWidth = [Math]::Max($Width, 8)
    $text = ConvertTo-LauncherCellText -Value $Value
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in ($text -split "`r`n|`n|`r")) {
        $line = [string]$rawLine
        if ([string]::IsNullOrEmpty($line)) {
            $lines.Add('') | Out-Null
            continue
        }

        while ($line.Length -gt $safeWidth) {
            $sliceLength = [Math]::Min($safeWidth, $line.Length)
            $breakIndex = $line.LastIndexOf(' ', $sliceLength - 1, $sliceLength)
            if ($breakIndex -lt [Math]::Floor($safeWidth / 2)) {
                $breakIndex = $sliceLength
            }
            $chunk = $line.Substring(0, $breakIndex).TrimEnd()
            if ($chunk.Length -eq 0) {
                $chunk = $line.Substring(0, $sliceLength)
                $line = $line.Substring($sliceLength).TrimStart()
            } else {
                $line = $line.Substring($breakIndex).TrimStart()
            }
            $lines.Add($chunk) | Out-Null
        }
        $lines.Add($line) | Out-Null
    }

    if ($lines.Count -eq 0) { $lines.Add('') | Out-Null }
    return @($lines)
}

function Write-LauncherKV {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][object]$Value,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host ("  {0,-18} : {1}" -f $Key, (ConvertTo-LauncherCellText -Value $Value)) -ForegroundColor $Color
}

function Write-LauncherLink {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )

    Write-Host ("  {0,-18} : {1}" -f $Label, $Path) -ForegroundColor Green
}

function Write-LauncherBarList {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$LabelProperty,
        [Parameter(Mandatory)][string]$ValueProperty
    )

    if (-not $Items -or $Items.Count -eq 0) { return }
    Write-Host ''
    Write-Host ("  {0}" -f $Title) -ForegroundColor Cyan
    $maxValue = [int](($Items | Measure-Object -Property $ValueProperty -Maximum).Maximum)
    if ($maxValue -lt 1) { $maxValue = 1 }
    foreach ($item in ($Items | Select-Object -First 5)) {
        $label = ConvertTo-LauncherCellText -Value $item.$LabelProperty
        $count = [int]$item.$ValueProperty
        $barLength = [Math]::Max([Math]::Round(($count / $maxValue) * 14), 1)
        $bar = ('#' * $barLength).PadRight(14, '.')
        Write-Host ("    {0,-18} {1} {2,4}" -f $label, $bar, $count) -ForegroundColor Gray
    }
}

function Write-LauncherTable {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [hashtable]$Headers = @{},
        [hashtable]$Widths = @{}
    )

    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $columnWidths = @{}
    foreach ($column in $Columns) {
        $label = if ($Headers.ContainsKey($column)) { [string]$Headers[$column] } else { [string]$column }
        $columnWidths[$column] = [Math]::Max($label.Length, $(if ($Widths.ContainsKey($column)) { [int]$Widths[$column] } else { 18 }))
    }

    $header = ($Columns | ForEach-Object {
        $label = if ($Headers.ContainsKey($_)) { [string]$Headers[$_] } else { [string]$_ }
        $label.PadRight($columnWidths[$_])
    }) -join ' | '
    $separator = ($Columns | ForEach-Object { ''.PadRight($columnWidths[$_], '-') }) -join '-+-'

    Write-Host ("  {0}" -f $header) -ForegroundColor DarkCyan
    Write-Host ("  {0}" -f $separator) -ForegroundColor DarkGray

    foreach ($row in $Rows) {
        $wrappedByColumn = @{}
        $maxLines = 1
        foreach ($column in $Columns) {
            $wrappedByColumn[$column] = @(Split-LauncherWrappedText -Value $row.$column -Width $columnWidths[$column])
            if ($wrappedByColumn[$column].Count -gt $maxLines) { $maxLines = $wrappedByColumn[$column].Count }
        }

        for ($lineIndex = 0; $lineIndex -lt $maxLines; $lineIndex++) {
            $line = ($Columns | ForEach-Object {
                $cellLines = $wrappedByColumn[$_]
                $cellText = if ($lineIndex -lt $cellLines.Count) { $cellLines[$lineIndex] } else { '' }
                $cellText.PadRight($columnWidths[$_])
            }) -join ' | '
            Write-Host ("  {0}" -f $line) -ForegroundColor Gray
        }
    }
}

function Throw-LauncherConfigValidationError {
    param(
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Problem,
        [Parameter(Mandatory)][string]$Example
    )

    $payload = [ordered]@{
        Kind    = 'LauncherConfigValidation'
        Field   = $Field
        Value   = $(if ($null -eq $Value) { 'null' } else { ConvertTo-LauncherCellText -Value $Value })
        Problem = $Problem
        Example = $Example
    }
    throw ('SCOPEFORGE_CONFIG::{0}' -f ($payload | ConvertTo-Json -Compress))
}

function Get-LauncherConfigValidationIssue {
    param([Parameter(Mandatory)][System.Exception]$Exception)

    $prefix = 'SCOPEFORGE_CONFIG::'
    if (-not $Exception.Message.StartsWith($prefix)) { return $null }
    try {
        return ($Exception.Message.Substring($prefix.Length) | ConvertFrom-Json -Depth 10)
    } catch {
        return $null
    }
}

function Show-LauncherConfigValidationSummary {
    param([Parameter(Mandatory)][pscustomobject]$Issue)

    Write-LauncherSection -Title 'Erreur de configuration'
    Write-Host 'Le launcher a bloque le run avant execution. Corrige le champ ci-dessous dans 02-run-settings.json.' -ForegroundColor Yellow
    Write-LauncherTable -Rows @(
        [pscustomobject]@{
            Champ    = $Issue.Field
            Valeur   = $Issue.Value
            Probleme = $Issue.Problem
            Exemple  = $Issue.Example
        }
    ) -Columns @('Champ', 'Valeur', 'Probleme', 'Exemple') -Widths @{ Champ = 18; Valeur = 22; Probleme = 40; Exemple = 24 }
}

function Write-LauncherKeyValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][object]$Value,
        [string]$Color = 'Gray',
        [int]$Padding = 18
    )

    $displayValue = if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { '-' } else { [string]$Value }
    $format = "  {0,-$Padding}: {1}"
    Write-Host ($format -f $Key, $displayValue) -ForegroundColor $Color
}

function Write-LauncherLink {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )

    Write-LauncherKeyValue -Key $Label -Value $Path -Color 'Green'
}

function Write-LauncherBarRow {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$Count,
        [int]$MaxCount = 0,
        [string]$Color = 'Gray'
    )

    $barWidth = 0
    if ($MaxCount -gt 0) {
        $barWidth = [Math]::Max([int][Math]::Round(($Count / [double]$MaxCount) * 12), $(if ($Count -gt 0) { 1 } else { 0 }))
    }
    $bar = if ($barWidth -gt 0) { ''.PadLeft($barWidth, '#') } else { '-' }
    Write-Host ("  {0,-20} {1,5}  {2}" -f $Label, $Count, $bar) -ForegroundColor $Color
}

function New-LauncherConfigIssue {
    param(
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Problem,
        [Parameter(Mandatory)][string]$Example
    )

    $displayValue = switch ($Value) {
        $null { 'null' }
        { $_ -is [string] -and [string]::IsNullOrWhiteSpace($_) } { '<empty>' }
        default { [string]$Value }
    }

    [pscustomobject]@{
        Field   = $Field
        Value   = $displayValue
        Problem = $Problem
        Example = $Example
    }
}

function Throw-LauncherConfigIssue {
    param(
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Problem,
        [Parameter(Mandatory)][string]$Example
    )

    $exception = [System.InvalidOperationException]::new(("Champ '{0}' invalide: {1}" -f $Field, $Problem))
    $exception.Data['ScopeForgeConfigIssues'] = @(
        New-LauncherConfigIssue -Field $Field -Value $Value -Problem $Problem -Example $Example
    )
    throw $exception
}

function Get-LauncherConfigIssues {
    param([Parameter(Mandatory)][System.Exception]$Exception)

    if ($Exception.Data -and $Exception.Data.Contains('ScopeForgeConfigIssues')) {
        return @($Exception.Data['ScopeForgeConfigIssues'])
    }
    return @()
}

function Show-LauncherConfigIssues {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Issues)

    if (-not $Issues -or $Issues.Count -eq 0) { return }

    Write-LauncherSection -Title 'Erreur de configuration'
    Write-Host 'Le fichier 02-run-settings.json contient une valeur invalide. Corrige le champ ci-dessous puis sauvegarde a nouveau.' -ForegroundColor Red
    Write-LauncherTable -Rows @(
        $Issues | ForEach-Object {
            [pscustomobject]@{
                Champ    = $_.Field
                Valeur   = $_.Value
                Probleme = $_.Problem
                Exemple  = $_.Example
            }
        }
    ) -Columns @('Champ', 'Valeur', 'Probleme', 'Exemple') -Widths @{ Champ = 18; Valeur = 20; Probleme = 42; Exemple = 24 }
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
            return [pscustomobject]@{
                Name              = 'safe'
                Depth             = 2
                Threads           = 6
                TimeoutSeconds    = 20
                RespectSchemeOnly = $true
                Resume            = $false
                Label             = 'Minimal and cautious'
                Description       = 'Réduit le volume HTTP, conserve le schéma déclaré et limite la profondeur de crawl.'
            }
        }
        'balanced' {
            return [pscustomobject]@{
                Name              = 'balanced'
                Depth             = 3
                Threads           = 10
                TimeoutSeconds    = 30
                RespectSchemeOnly = $false
                Resume            = $false
                Label             = 'Default recon profile'
                Description       = "Bon compromis entre découverte d'assets, validation HTTP et crawl de chemins."
            }
        }
        'deep' {
            return [pscustomobject]@{
                Name              = 'deep'
                Depth             = 4
                Threads           = 20
                TimeoutSeconds    = 45
                RespectSchemeOnly = $false
                Resume            = $true
                Label             = 'Broader crawl for larger scopes'
                Description       = 'Approfondit davantage le crawl et active une logique adaptée aux scopes plus larges.'
            }
        }
        default {
            throw "Unknown preset: $Name"
        }
    }
}

function Select-LauncherPreset {
    Write-LauncherSection -Title 'Preset'
    Write-Host '1. safe      : minimal and cautious' -ForegroundColor Gray
    Write-Host '   Limite la profondeur, réduit les threads et garde un comportement conservateur.' -ForegroundColor DarkGray
    Write-Host '2. balanced  : default recon profile' -ForegroundColor Gray
    Write-Host '   Convient à la majorité des programmes web et API classiques.' -ForegroundColor DarkGray
    Write-Host '3. deep      : broader crawl for larger scopes' -ForegroundColor Gray
    Write-Host '   Augmente le volume de collecte pour les scopes plus vastes ou plus riches.' -ForegroundColor DarkGray
    $choice = Read-LauncherChoice -Prompt 'Choisis un preset' -Allowed @('1', '2', '3') -Default '2'
    switch ($choice) {
        '1' { $preset = Get-LauncherPreset -Name 'safe' }
        '2' { $preset = Get-LauncherPreset -Name 'balanced' }
        '3' { $preset = Get-LauncherPreset -Name 'deep' }
    }
    Write-Host ("Preset retenu : {0} - {1}" -f $preset.Name, $preset.Description) -ForegroundColor Cyan
    return $preset
}

function Get-LauncherSourceSummary {
    param(
        [bool]$EnableGau,
        [bool]$EnableWaybackUrls,
        [bool]$EnableHakrawler
    )

    $sources = [System.Collections.Generic.List[string]]::new()
    if ($EnableGau) { $sources.Add('gau') | Out-Null }
    if ($EnableWaybackUrls) { $sources.Add('waybackurls') | Out-Null }
    if ($EnableHakrawler) { $sources.Add('hakrawler') | Out-Null }
    if ($sources.Count -eq 0) { return 'subfinder/httpx/katana only' }
    return ('subfinder/httpx/katana + ' + ($sources -join ', '))
}

function Get-LauncherProgramProfile {
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name.ToLowerInvariant()) {
        'webapp' {
            return [pscustomobject]@{
                Name = 'webapp'
                Label = 'Traditional web application'
                Description = 'Favorise les zones login, admin, upload, dashboard et autres routes applicatives classiques.'
                SuggestedDepth = 3
                SuggestedThreads = 10
                ForceRespectSchemeOnly = $false
                ForceResume = $false
                UseGau = $true
                UseWaybackUrls = $true
                UseHakrawler = $true
                SourceExplanation = 'Ajoute des seeds historiques et un crawl complémentaire pour mieux remonter login, admin, upload et pages métiers.'
            }
        }
        'api' {
            return [pscustomobject]@{
                Name = 'api'
                Label = 'API-first target'
                Description = "Réduit le crawl profond et pousse davantage la validation d'URLs déjà connues, utile pour Swagger, GraphQL, REST et endpoints versionnés."
                SuggestedDepth = 2
                SuggestedThreads = 12
                ForceRespectSchemeOnly = $true
                ForceResume = $false
                UseGau = $true
                UseWaybackUrls = $true
                UseHakrawler = $false
                SourceExplanation = 'Favorise les URLs historiques et limite le crawl complémentaire pour réduire le bruit sur les APIs et docs techniques.'
            }
        }
        'wide-assets' {
            return [pscustomobject]@{
                Name = 'wide-assets'
                Label = 'Large wildcard-heavy scope'
                Description = "Met l'accent sur la couverture d'assets et la reprise, utile quand le scope contient beaucoup de hosts ou plusieurs wildcards."
                SuggestedDepth = 2
                SuggestedThreads = 16
                ForceRespectSchemeOnly = $false
                ForceResume = $true
                UseGau = $true
                UseWaybackUrls = $true
                UseHakrawler = $false
                SourceExplanation = 'Privilégie la couverture large des hosts et des URLs historiques, sans ajouter trop de coût par host.'
            }
        }
        default {
            throw "Unknown program profile: $Name"
        }
    }
}

function Select-LauncherProgramProfile {
    Write-LauncherSection -Title 'Profil cible'
    Write-Host '1. webapp      : application web classique' -ForegroundColor Gray
    Write-Host '   Plus pertinent si tu attends surtout des panels, auth, uploads, dashboards, pages métiers.' -ForegroundColor DarkGray
    Write-Host '2. api         : cible orientée API' -ForegroundColor Gray
    Write-Host '   Plus pertinent si le scope contient beaucoup de REST, GraphQL, docs Swagger, routes versionnées.' -ForegroundColor DarkGray
    Write-Host '3. wide-assets : scope large en wildcard' -ForegroundColor Gray
    Write-Host '   Plus pertinent si tu veux surtout cartographier rapidement de nombreux hosts et relancer souvent.' -ForegroundColor DarkGray
    $choice = Read-LauncherChoice -Prompt 'Choisis un profil' -Allowed @('1', '2', '3') -Default '1'
    switch ($choice) {
        '1' { $profile = Get-LauncherProgramProfile -Name 'webapp' }
        '2' { $profile = Get-LauncherProgramProfile -Name 'api' }
        '3' { $profile = Get-LauncherProgramProfile -Name 'wide-assets' }
    }
    Write-Host ("Profil retenu : {0} - {1}" -f $profile.Name, $profile.Description) -ForegroundColor Cyan
    return $profile
}

function Show-ScopePreview {
    param([Parameter(Mandatory)][pscustomobject[]]$ScopeItems)
    Write-LauncherSection -Title 'Scope validé'
    Write-Host ("  Items in-scope: {0}" -f $ScopeItems.Count) -ForegroundColor Gray
    $rows = @($ScopeItems | ForEach-Object {
        [pscustomobject]@{
            Id         = $_.Id
            Type       = $_.Type
            Value      = $_.NormalizedValue
            Exclusions = if ($_.Exclusions -and $_.Exclusions.Count -gt 0) { ($_.Exclusions -join ', ') } else { '-' }
        }
    })
    Write-LauncherTable -Rows $rows -Columns @('Id', 'Type', 'Value', 'Exclusions') -Widths @{ Id = 10; Type = 10; Value = 58; Exclusions = 24 }
}

function Show-LauncherConfigPreview {
    param([Parameter(Mandatory)][hashtable]$RunConfig)
    Write-LauncherSection -Title 'Configuration'
    if ($RunConfig.ContainsKey('DocumentWorkspace')) {
        Write-LauncherKeyValue -Key 'DocumentWorkspace' -Value $RunConfig.DocumentWorkspace
    }
    if ($RunConfig.ContainsKey('PresetName')) {
        Write-Host ''
        Write-Host '  Program' -ForegroundColor Cyan
        Write-LauncherKeyValue -Key 'Preset' -Value $RunConfig.PresetName
        Write-LauncherKeyValue -Key 'Preset details' -Value $RunConfig.PresetDescription -Color 'DarkGray'
    }
    if ($RunConfig.ContainsKey('ProfileName')) {
        Write-LauncherKeyValue -Key 'Program profile' -Value $RunConfig.ProfileName
        Write-LauncherKeyValue -Key 'Profile details' -Value $RunConfig.ProfileDescription -Color 'DarkGray'
        if ($RunConfig.ContainsKey('ProfileSourceExplanation')) {
            Write-LauncherKeyValue -Key 'Source strategy' -Value $RunConfig.ProfileSourceExplanation -Color 'DarkGray'
        }
    }

    Write-LauncherKeyValue -Key 'ScopeFile' -Value $RunConfig.ScopeFile
    Write-LauncherKeyValue -Key 'ProgramName' -Value $RunConfig.ProgramName
    Write-LauncherKeyValue -Key 'OutputDir' -Value $RunConfig.OutputDir

    Write-Host ''
    Write-Host '  Performance' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Depth' -Value $RunConfig.Depth
    Write-LauncherKeyValue -Key 'Threads' -Value $RunConfig.Threads
    Write-LauncherKeyValue -Key 'TimeoutSeconds' -Value $RunConfig.TimeoutSeconds
    Write-LauncherKeyValue -Key 'UniqueUserAgent' -Value $RunConfig.UniqueUserAgent

    Write-Host ''
    Write-Host '  Sources' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Sources' -Value (Get-LauncherSourceSummary -EnableGau $RunConfig.EnableGau -EnableWaybackUrls $RunConfig.EnableWaybackUrls -EnableHakrawler $RunConfig.EnableHakrawler)

    Write-Host ''
    Write-Host '  Flags' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'IncludeApex' -Value $RunConfig.IncludeApex
    Write-LauncherKeyValue -Key 'RespectSchemeOnly' -Value $RunConfig.RespectSchemeOnly
    Write-LauncherKeyValue -Key 'NoInstall' -Value $RunConfig.NoInstall
    Write-LauncherKeyValue -Key 'Quiet' -Value $RunConfig.Quiet
    Write-LauncherKeyValue -Key 'Resume' -Value $RunConfig.Resume
    if ($RunConfig.ContainsKey('OpenReportOnFinish')) {
        Write-LauncherKeyValue -Key 'OpenReport' -Value $RunConfig.OpenReportOnFinish
    }
}

function Show-RunSummaryDashboard {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $summary = $Result.Summary
    $protectedCount = @($Result.LiveTargets | Where-Object { $_.StatusCode -in 401, 403 }).Count
    $metricRows = @(
        @{ Label = 'Scope items'; Count = [int]$summary.ScopeItemCount },
        @{ Label = 'Excluded'; Count = [int]$summary.ExcludedItemCount },
        @{ Label = 'Hosts discovered'; Count = [int]$summary.DiscoveredHostCount },
        @{ Label = 'Live hosts'; Count = [int]$summary.LiveHostCount },
        @{ Label = 'Live targets'; Count = [int]$summary.LiveTargetCount },
        @{ Label = 'URLs discovered'; Count = [int]$summary.DiscoveredUrlCount },
        @{ Label = 'Interesting URLs'; Count = [int]$summary.InterestingUrlCount },
        @{ Label = 'Protected 401/403'; Count = [int]$protectedCount },
        @{ Label = 'Errors'; Count = [int]$summary.ErrorCount }
    )
    $maxMetricCount = [int](($metricRows | Measure-Object -Property Count -Maximum).Maximum)
    if ($maxMetricCount -lt 1) { $maxMetricCount = 1 }
    Write-LauncherSection -Title 'Dashboard'
    Write-Host '  Counters' -ForegroundColor Cyan
    foreach ($metric in $metricRows) {
        Write-LauncherBarRow -Label $metric.Label -Count $metric.Count -MaxCount $maxMetricCount -Color 'Gray'
    }

    if ($summary.TopTechnologies -and $summary.TopTechnologies.Count -gt 0) {
        Write-Host ''
        Write-Host '  Top technologies' -ForegroundColor Cyan
        $maxTech = [int](($summary.TopTechnologies | Measure-Object -Property Count -Maximum).Maximum)
        foreach ($item in ($summary.TopTechnologies | Select-Object -First 5)) {
            Write-LauncherBarRow -Label $item.Technology -Count ([int]$item.Count) -MaxCount $maxTech
        }
    }

    if ($summary.TopInterestingFamilies -and $summary.TopInterestingFamilies.Count -gt 0) {
        Write-Host ''
        Write-Host '  Interesting families' -ForegroundColor Cyan
        $maxFamilies = [int](($summary.TopInterestingFamilies | Measure-Object -Property Count -Maximum).Maximum)
        foreach ($item in ($summary.TopInterestingFamilies | Select-Object -First 5)) {
            Write-LauncherBarRow -Label $item.Family -Count ([int]$item.Count) -MaxCount $maxFamilies
        }
    }

    if ($summary.InterestingPriorityDistribution -and $summary.InterestingPriorityDistribution.Count -gt 0) {
        Write-Host ''
        Write-Host '  Interesting priorities' -ForegroundColor Cyan
        $maxPriority = [int](($summary.InterestingPriorityDistribution | Measure-Object -Property Count -Maximum).Maximum)
        foreach ($item in $summary.InterestingPriorityDistribution) {
            Write-LauncherBarRow -Label $item.Priority -Count ([int]$item.Count) -MaxCount $maxPriority
        }
    }

    if ($summary.TopInterestingCategories -and $summary.TopInterestingCategories.Count -gt 0) {
        Write-Host ''
        Write-Host '  Interesting categories' -ForegroundColor Cyan
        $maxCategories = [int](($summary.TopInterestingCategories | Measure-Object -Property Count -Maximum).Maximum)
        foreach ($item in ($summary.TopInterestingCategories | Select-Object -First 5)) {
            Write-LauncherBarRow -Label $item.Category -Count ([int]$item.Count) -MaxCount $maxCategories
        }
    }
}

function Get-LauncherInvokeParams {
    param([Parameter(Mandatory)][hashtable]$RunConfig)
    $invokeParams = @{}
    foreach ($name in @('ScopeFile', 'ProgramName', 'OutputDir', 'Depth', 'UniqueUserAgent', 'Threads', 'TimeoutSeconds')) {
        if ($RunConfig.ContainsKey($name)) {
            $invokeParams[$name] = $RunConfig[$name]
        }
    }
    foreach ($name in @('EnableGau', 'EnableWaybackUrls', 'EnableHakrawler')) {
        if (-not $RunConfig.ContainsKey($name)) { continue }
        $invokeParams[$name] = ConvertTo-LauncherBoolean -Value $RunConfig[$name] -Name $name -Default $false
    }
    foreach ($name in @('NoInstall', 'Quiet', 'IncludeApex', 'RespectSchemeOnly', 'ExportHtml', 'ExportCsv', 'ExportJson', 'Resume')) {
        if (-not $RunConfig.ContainsKey($name)) { continue }
        $value = ConvertTo-LauncherBoolean -Value $RunConfig[$name] -Name $name -Default $false
        if ([bool]$value) {
            $invokeParams[$name] = $true
        }
    }
    return $invokeParams
}

function Show-InterestingSummary {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Write-LauncherSection -Title 'Pages intéressantes'
    if (-not $Result.InterestingUrls -or $Result.InterestingUrls.Count -eq 0) {
        Write-Host '  Aucune URL prioritaire n''a été remontée par les heuristiques.' -ForegroundColor Gray
        return
    }
    foreach ($item in ($Result.InterestingUrls | Select-Object -First 15)) {
        Write-Host ("  [{0}/{1}/{2}] {3}" -f $item.Priority, $item.PrimaryFamily, $item.Score, $item.Url) -ForegroundColor DarkYellow
        if ($item.Categories) { Write-Host ("      {0}" -f ($item.Categories -join ', ')) -ForegroundColor Gray }
        if ($item.Reasons) { Write-Host ("      {0}" -f ($item.Reasons -join '; ')) -ForegroundColor DarkGray }
    }
}

function Show-InterestingFamilyBreakdown {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    Write-LauncherSection -Title 'Familles intéressantes'
    $groups = $Result.InterestingUrls | Group-Object -Property PrimaryFamily | Where-Object { $_.Name } | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name
    if ($groups.Count -eq 0) {
        Write-Host '  Aucune famille à afficher.' -ForegroundColor Gray
        return
    }
    foreach ($group in $groups) {
        $best = $group.Group | Sort-Object -Property PriorityRank, @{ Expression = 'Score'; Descending = $true }, Url | Select-Object -First 1
        Write-Host ("  {0,-18} {1,5}  best={2}/{3}" -f $group.Name, $group.Count, $best.Priority, $best.Score) -ForegroundColor Gray
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
    Write-Host '  Quick actions' -ForegroundColor Cyan
    Write-LauncherLink -Label 'Open report.html' -Path (Join-Path $Result.OutputDir 'reports/report.html')
    Write-LauncherLink -Label 'Open triage.md' -Path (Join-Path $Result.OutputDir 'reports/triage.md')
    Write-LauncherLink -Label 'Open interesting_urls.json' -Path (Join-Path $Result.OutputDir 'normalized/interesting_urls.json')
    Write-LauncherLink -Label 'Open interesting_families.json' -Path (Join-Path $Result.OutputDir 'normalized/interesting_families.json')
    Write-LauncherLink -Label 'Open errors.log' -Path (Join-Path $Result.OutputDir 'logs/errors.log')
    Write-LauncherLink -Label 'Open tools.log' -Path (Join-Path $Result.OutputDir 'logs/tools.log')
}

function Get-LauncherErrorRecommendation {
    param([Parameter(Mandatory)][pscustomobject]$ErrorRecord)

    switch ($ErrorRecord.ErrorCode) {
        'ToolMissing' { return 'Installe l''outil manquant ou ajuste le preset/profile pour ne pas l''utiliser.' }
        'ToolExitCode' { return 'Consulte tools.log puis relance avec moins de threads, un timeout plus large, ou une source moins bruyante.' }
        'ToolTimeout' { return 'Augmente timeoutSeconds ou relance le run avec moins de concurrence.' }
        'InvalidBooleanInConfig' { return 'Corrige la valeur en true/false sans guillemets dans 02-run-settings.json.' }
        default { return 'Consulte errors.log et tools.log pour le détail complet.' }
    }
}

function Show-ErrorSummaryPanel {
    param([Parameter(Mandatory)][pscustomobject]$Result)

    if (-not $Result.Errors -or $Result.Errors.Count -eq 0) { return }

    Write-LauncherSection -Title 'Résumé des erreurs'
    Write-Host ("  Total erreurs non fatales: {0}" -f $Result.Errors.Count) -ForegroundColor Yellow
    $groupRows = @(
        $Result.Errors |
        Group-Object -Property @{ Expression = { $_.Phase } }, @{ Expression = { if ($_.Tool) { $_.Tool } else { '-' } } } |
        Sort-Object -Property Count -Descending |
        Select-Object -First 8 |
        ForEach-Object {
            [pscustomobject]@{
                Phase = $_.Group[0].Phase
                Tool  = if ($_.Group[0].Tool) { $_.Group[0].Tool } else { '-' }
                Count = $_.Count
            }
        }
    )
    if ($groupRows.Count -gt 0) {
        Write-Host '  Groupes' -ForegroundColor Cyan
        Write-LauncherTable -Rows $groupRows -Columns @('Phase', 'Tool', 'Count') -Widths @{ Phase = 18; Tool = 12; Count = 6 }
    }
    $groupedRows = @(
        $Result.Errors |
        Group-Object -Property { '{0}|{1}' -f $_.Phase, $(if ($_.Tool) { $_.Tool } else { '-' }) } |
        Sort-Object Count -Descending |
        ForEach-Object {
            $sample = $_.Group | Select-Object -First 1
            [pscustomobject]@{
                Phase      = $sample.Phase
                Tool       = if ($sample.Tool) { $sample.Tool } else { '-' }
                Count      = $_.Count
                Code       = if ($sample.ErrorCode) { $sample.ErrorCode } else { '-' }
                Suggestion = Get-LauncherErrorRecommendation -ErrorRecord $sample
            }
        }
    )
    Write-LauncherTable -Rows $groupedRows -Columns @('Phase', 'Tool', 'Count', 'Code', 'Suggestion') -Widths @{ Phase = 18; Tool = 12; Count = 6; Code = 18; Suggestion = 48 }

    Write-Host ''
    Write-Host '  Dernieres erreurs utiles' -ForegroundColor Cyan
    $rows = @(
        $Result.Errors |
        Select-Object -Last 12 |
        ForEach-Object {
            [pscustomobject]@{
                Phase   = $_.Phase
                Tool    = if ($_.Tool) { $_.Tool } else { '-' }
                Code    = if ($_.ErrorCode) { $_.ErrorCode } else { '-' }
                Target  = if ($_.Target) { $_.Target } else { '-' }
                Message = $_.Message
            }
        }
    )
    Write-LauncherTable -Rows $rows -Columns @('Phase', 'Tool', 'Code', 'Target', 'Message') -Widths @{ Phase = 16; Tool = 12; Code = 18; Target = 28; Message = 46 }
    Write-LauncherLink -Label 'errors.log' -Path (Join-Path $Result.OutputDir 'logs/errors.log')
    Write-LauncherLink -Label 'tools.log' -Path (Join-Path $Result.OutputDir 'logs/tools.log')
}

function Get-LauncherStorageRoot {
    if ($IsWindows) {
        $basePath = [Environment]::GetFolderPath('LocalApplicationData')
    } elseif ($HOME) {
        $basePath = $HOME
    } else {
        $basePath = [System.IO.Path]::GetTempPath()
    }

    $primaryPath = Join-Path $basePath 'ScopeForge'
    try {
        if (-not (Test-Path -LiteralPath $primaryPath)) {
            $null = New-Item -ItemType Directory -Path $primaryPath -Force
        }
        return $primaryPath
    } catch {
        $fallbackPath = Join-Path $PSScriptRoot '.scopeforge'
        if (-not (Test-Path -LiteralPath $fallbackPath)) {
            $null = New-Item -ItemType Directory -Path $fallbackPath -Force
        }
        return $fallbackPath
    }
}

function Get-LauncherDefaultOutputDir {
    $runsRoot = Join-Path (Get-LauncherStorageRoot) 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) {
        $null = New-Item -ItemType Directory -Path $runsRoot -Force
    }
    return (Join-Path $runsRoot ([DateTime]::Now.ToString('yyyyMMdd-HHmmss')))
}

function Get-LauncherEditorDefinition {
    if ($IsWindows) {
        return [pscustomobject]@{
            FilePath  = 'notepad.exe'
            Arguments = @()
            Label     = 'Notepad'
        }
    }

    if ($env:VISUAL) {
        $visual = Get-Command -Name $env:VISUAL -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($visual) {
            return [pscustomobject]@{
                FilePath  = $visual.Source
                Arguments = @()
                Label     = $visual.Name
            }
        }
    }

    if ($env:EDITOR) {
        $editor = Get-Command -Name $env:EDITOR -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($editor) {
            return [pscustomobject]@{
                FilePath  = $editor.Source
                Arguments = @()
                Label     = $editor.Name
            }
        }
    }

    $candidates = @(
        [pscustomobject]@{ Name = 'code'; Arguments = @('--wait'); Label = 'VS Code' },
        [pscustomobject]@{ Name = 'gedit'; Arguments = @('--wait'); Label = 'gedit' },
        [pscustomobject]@{ Name = 'kate'; Arguments = @('--block'); Label = 'kate' },
        [pscustomobject]@{ Name = 'xed'; Arguments = @('--wait'); Label = 'xed' },
        [pscustomobject]@{ Name = 'nano'; Arguments = @(); Label = 'nano' }
    )

    foreach ($candidate in $candidates) {
        $command = Get-Command -Name $candidate.Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return [pscustomobject]@{
                FilePath  = $command.Source
                Arguments = $candidate.Arguments
                Label     = $candidate.Label
            }
        }
    }

    throw "Aucun editeur compatible n'a ete detecte. Definis VISUAL/EDITOR ou installe VS Code, gedit, kate ou nano."
}

function Open-LauncherDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Title
    )

    $editor = Get-LauncherEditorDefinition
    Write-Host ("Ouverture de {0} dans {1}" -f $Title, $editor.Label) -ForegroundColor Cyan
    Start-Process -FilePath $editor.FilePath -ArgumentList @($editor.Arguments + @($Path)) -Wait
}

function Open-LauncherPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        if ($IsWindows) {
            Start-Process -FilePath $Path | Out-Null
            return
        }

        if ($IsLinux) {
            $xdgOpen = Get-Command -Name 'xdg-open' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($xdgOpen) {
                Start-Process -FilePath $xdgOpen.Source -ArgumentList @($Path) | Out-Null
            }
            return
        }

        if ($IsMacOS) {
            $openCommand = Get-Command -Name 'open' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($openCommand) {
                Start-Process -FilePath $openCommand.Source -ArgumentList @($Path) | Out-Null
            }
        }
    } catch {
        Write-Host ("Impossible d'ouvrir automatiquement: {0}" -f $Path) -ForegroundColor Yellow
    }
}

function Get-LauncherDocumentProperty {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-LauncherBoolean {
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [string]$Name = 'value',
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [System.Management.Automation.SwitchParameter]) { return [bool]$Value }
    if ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {
        switch ([int64]$Value) {
            0 { return $false }
            1 { return $true }
            default {
                Throw-LauncherConfigIssue -Field $Name -Value $Value -Problem 'Doit etre un booléen JSON true/false.' -Example ('"{0}": false' -f $Name)
            }
        }
    }

    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            Throw-LauncherConfigIssue -Field $Name -Value $Value -Problem 'Doit etre un booléen JSON true/false, pas une chaine vide.' -Example ('"{0}": false' -f $Name)
        }

        switch ($text.ToLowerInvariant()) {
            'true' {
                Write-Warning ("Format legacy pour '{0}' dans 02-run-settings.json: utilise true/false sans guillemets." -f $Name)
                return $true
            }
            'false' {
                Write-Warning ("Format legacy pour '{0}' dans 02-run-settings.json: utilise true/false sans guillemets." -f $Name)
                return $false
            }
            '1' {
                Write-Warning ("Format legacy pour '{0}' dans 02-run-settings.json: utilise true/false sans guillemets." -f $Name)
                return $true
            }
            '0' {
                Write-Warning ("Format legacy pour '{0}' dans 02-run-settings.json: utilise true/false sans guillemets." -f $Name)
                return $false
            }
            default {
                Throw-LauncherConfigIssue -Field $Name -Value $Value -Problem 'Doit etre un booléen JSON true/false.' -Example ('"{0}": false' -f $Name)
            }
        }
    }

    Throw-LauncherConfigIssue -Field $Name -Value $Value.GetType().FullName -Problem 'Type non supporté pour un booléen de configuration.' -Example ('"{0}": false' -f $Name)
}

function ConvertTo-LauncherInteger {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ($null -eq $Value) { return $Default }

    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            Throw-LauncherConfigIssue -Field $Name -Value $Value -Problem ("Doit etre un entier compris entre {0} et {1}." -f $Minimum, $Maximum) -Example ('"{0}": {1}' -f $Name, $Default)
        }
    }

    try {
        $intValue = [int]$Value
    } catch {
        Throw-LauncherConfigIssue -Field $Name -Value $Value -Problem ("Doit etre un entier compris entre {0} et {1}." -f $Minimum, $Maximum) -Example ('"{0}": {1}' -f $Name, $Default)
    }

    if ($intValue -lt $Minimum -or $intValue -gt $Maximum) {
        Throw-LauncherConfigIssue -Field $Name -Value $Value -Problem ("Doit etre compris entre {0} et {1}." -f $Minimum, $Maximum) -Example ('"{0}": {1}' -f $Name, $Default)
    }

    return $intValue
}

function Read-LauncherIntegerValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )

    while ($true) {
        $rawValue = Read-LauncherValue -Prompt $Prompt -Default ([string]$Default)
        try {
            return (ConvertTo-LauncherInteger -Value $rawValue -Name $Name -Default $Default -Minimum $Minimum -Maximum $Maximum)
        } catch {
            $configIssues = @(Get-LauncherConfigIssues -Exception $_.Exception)
            if ($configIssues.Count -gt 0) {
                Show-LauncherConfigIssues -Issues $configIssues
                continue
            }
            throw
        }
    }
}

function New-LauncherDocumentSet {
    param(
        [string]$InitialScopeFile,
        [string]$ProgramName,
        [string]$OutputDir,
        [int]$Depth,
        [string]$UniqueUserAgent,
        [int]$Threads,
        [int]$TimeoutSeconds,
        [bool]$EnableGau,
        [bool]$EnableWaybackUrls,
        [bool]$EnableHakrawler,
        [bool]$NoInstall,
        [bool]$Quiet,
        [bool]$IncludeApex,
        [bool]$RespectSchemeOnly,
        [bool]$Resume,
        [bool]$OpenReportOnFinish
    )

    $launcherRoot = Join-Path (Get-LauncherStorageRoot) 'launcher'
    try {
        if (-not (Test-Path -LiteralPath $launcherRoot)) {
            $null = New-Item -ItemType Directory -Path $launcherRoot -Force
        }
    } catch {
        $launcherRoot = Join-Path (Join-Path $PSScriptRoot '.scopeforge') 'launcher'
        if (-not (Test-Path -LiteralPath $launcherRoot)) {
            $null = New-Item -ItemType Directory -Path $launcherRoot -Force
        }
    }

    $sessionRoot = Join-Path $launcherRoot ('session-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
    $null = New-Item -ItemType Directory -Path $sessionRoot -Force

    $readmePath = Join-Path $sessionRoot '00-START-HERE.txt'
    $scopePath = Join-Path $sessionRoot '01-scope.json'
    $settingsPath = Join-Path $sessionRoot '02-run-settings.json'

    $scopeTemplate = $null
    if ($InitialScopeFile -and (Test-Path -LiteralPath $InitialScopeFile)) {
        $scopeTemplate = Get-Content -LiteralPath $InitialScopeFile -Raw -Encoding utf8
    } else {
        $exampleScopePath = Join-Path $PSScriptRoot 'examples/scope.json'
        if (Test-Path -LiteralPath $exampleScopePath) {
            $scopeTemplate = Get-Content -LiteralPath $exampleScopePath -Raw -Encoding utf8
        } else {
            $scopeTemplate = @'
[
  {
    "type": "URL",
    "value": "https://target.example/api/v1",
    "exclusions": []
  },
  {
    "type": "Wildcard",
    "value": "https://*.example.com",
    "exclusions": ["dev", "stg", "staging"]
  }
]
'@
        }
    }

    $defaultProgramName = if ($ProgramName) { $ProgramName } else { 'authorized-bugbounty' }
    $defaultOutputDir = if ($OutputDir) { $OutputDir } else { Get-LauncherDefaultOutputDir }
    $defaultUserAgent = if ($UniqueUserAgent) { $UniqueUserAgent } else { "researcher-" + ([Guid]::NewGuid().ToString('N').Substring(0, 8)) }

    $settingsObject = [ordered]@{
        programName       = $defaultProgramName
        outputDir         = $defaultOutputDir
        preset            = 'balanced'
        profile           = 'webapp'
        depth             = if ($Depth -gt 0) { $Depth } else { 3 }
        threads           = if ($Threads -gt 0) { $Threads } else { 10 }
        timeoutSeconds    = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { 30 }
        uniqueUserAgent   = $defaultUserAgent
        includeApex       = $IncludeApex
        respectSchemeOnly = $RespectSchemeOnly
        enableGau         = $EnableGau
        enableWaybackUrls = $EnableWaybackUrls
        enableHakrawler   = $EnableHakrawler
        noInstall         = $NoInstall
        quiet             = $Quiet
        resume            = $Resume
        openReportOnFinish = $OpenReportOnFinish
    }

    $instructions = @"
ScopeForge - mode documents

Ordre recommande:
1. Lis rapidement ce fichier.
2. Remplis puis sauvegarde 01-scope.json avec UNIQUEMENT le scope autorise.
3. Remplis puis sauvegarde 02-run-settings.json.
4. Ferme les fenetres d'edition. Le launcher validera les fichiers et demarrera automatiquement.

Fichiers:
- 01-scope.json
  Mets ici la liste du scope autorise. Format attendu: tableau JSON d'items URL / Wildcard / Domain.
- 02-run-settings.json
  Mets ici les reglages du run.

Valeurs utiles dans 02-run-settings.json:
- preset: safe | balanced | deep
- profile: webapp | api | wide-assets
- enableGau / enableWaybackUrls / enableHakrawler: true ou false
- Les champs booléens (quiet, noInstall, resume, includeApex, respectSchemeOnly, openReportOnFinish) doivent rester en JSON natif true / false, sans guillemets.
- openReportOnFinish: true pour ouvrir automatiquement le rapport HTML a la fin

Conseils:
- Conserve un User-Agent unique si le programme le demande.
- Ne mets jamais de cible hors scope.
- Si une validation echoue, le launcher rouvrira les fichiers pour correction.

Le rapport final ouvrira le HTML principal avec les pages interessantes, familles, priorites et endpoints proteges.
"@

    Set-Content -LiteralPath $readmePath -Value $instructions -Encoding utf8
    Set-Content -LiteralPath $scopePath -Value $scopeTemplate -Encoding utf8
    Set-Content -LiteralPath $settingsPath -Value ($settingsObject | ConvertTo-Json -Depth 20) -Encoding utf8

    return [pscustomobject]@{
        RootPath     = $sessionRoot
        ReadmePath   = $readmePath
        ScopePath    = $scopePath
        SettingsPath = $settingsPath
    }
}

function Build-DocumentRunConfig {
    param(
        [string]$InitialScopeFile,
        [string]$ProgramName,
        [string]$OutputDir,
        [int]$Depth,
        [string]$UniqueUserAgent,
        [int]$Threads,
        [int]$TimeoutSeconds,
        [bool]$EnableGau,
        [bool]$EnableWaybackUrls,
        [bool]$EnableHakrawler,
        [bool]$NoInstall,
        [bool]$Quiet,
        [bool]$IncludeApex,
        [bool]$RespectSchemeOnly,
        [bool]$Resume,
        [bool]$OpenReportOnFinish
    )

    $documentSet = New-LauncherDocumentSet -InitialScopeFile $InitialScopeFile -ProgramName $ProgramName -OutputDir $OutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -EnableGau $EnableGau -EnableWaybackUrls $EnableWaybackUrls -EnableHakrawler $EnableHakrawler -NoInstall $NoInstall -Quiet $Quiet -IncludeApex $IncludeApex -RespectSchemeOnly $RespectSchemeOnly -Resume $Resume -OpenReportOnFinish $OpenReportOnFinish

    Write-LauncherSection -Title 'Mode documents'
    Write-Host ("Les documents de configuration ont ete crees ici : {0}" -f $documentSet.RootPath) -ForegroundColor Cyan
    Write-Host 'Remplis, sauvegarde et ferme chaque document. Le launcher reprendra automatiquement.' -ForegroundColor Gray

    Open-LauncherDocument -Path $documentSet.ReadmePath -Title 'Instructions'

    while ($true) {
        Open-LauncherDocument -Path $documentSet.ScopePath -Title 'Scope autorise'
        Open-LauncherDocument -Path $documentSet.SettingsPath -Title 'Parametres du run'

        try {
            $settingsRaw = Get-Content -LiteralPath $documentSet.SettingsPath -Raw -Encoding utf8
            if ([string]::IsNullOrWhiteSpace($settingsRaw)) { throw 'Le fichier 02-run-settings.json est vide.' }
            $settings = ConvertFrom-Json -InputObject $settingsRaw -Depth 50

            $presetName = [string](Get-LauncherDocumentProperty -InputObject $settings -Name 'preset' -Default 'balanced')
            if ([string]::IsNullOrWhiteSpace($presetName)) { $presetName = 'balanced' }
            try {
                $preset = Get-LauncherPreset -Name $presetName
            } catch {
                Throw-LauncherConfigIssue -Field 'preset' -Value $presetName -Problem 'Preset inconnu. Valeurs attendues: safe, balanced, deep.' -Example '"preset": "balanced"'
            }

            $profileName = [string](Get-LauncherDocumentProperty -InputObject $settings -Name 'profile' -Default 'webapp')
            if ([string]::IsNullOrWhiteSpace($profileName)) { $profileName = 'webapp' }
            try {
                $profile = Get-LauncherProgramProfile -Name $profileName
            } catch {
                Throw-LauncherConfigIssue -Field 'profile' -Value $profileName -Problem 'Profil inconnu. Valeurs attendues: webapp, api, wide-assets.' -Example '"profile": "webapp"'
            }

            $localDepth = $preset.Depth
            $localThreads = $preset.Threads
            $localTimeout = $preset.TimeoutSeconds
            $localRespectSchemeOnly = $preset.RespectSchemeOnly
            $localResume = $preset.Resume
            $localEnableGau = $profile.UseGau
            $localEnableWaybackUrls = $profile.UseWaybackUrls
            $localEnableHakrawler = $profile.UseHakrawler

            if ($profile.SuggestedDepth -gt 0) {
                if ($preset.Name -eq 'safe') {
                    $localDepth = [Math]::Min($localDepth, $profile.SuggestedDepth)
                } else {
                    $localDepth = [Math]::Max($localDepth, $profile.SuggestedDepth)
                }
            }
            if ($profile.SuggestedThreads -gt 0) {
                $localThreads = [Math]::Max($localThreads, $profile.SuggestedThreads)
            }
            if ($profile.ForceRespectSchemeOnly) { $localRespectSchemeOnly = $true }
            if ($profile.ForceResume) { $localResume = $true }

            $programNameValue = [string](Get-LauncherDocumentProperty -InputObject $settings -Name 'programName' -Default 'authorized-bugbounty')
            if ([string]::IsNullOrWhiteSpace($programNameValue)) {
                Throw-LauncherConfigIssue -Field 'programName' -Value $programNameValue -Problem 'Doit etre renseigné.' -Example '"programName": "authorized-bugbounty"'
            }

            $outputDirValue = [string](Get-LauncherDocumentProperty -InputObject $settings -Name 'outputDir' -Default (Get-LauncherDefaultOutputDir))
            if ([string]::IsNullOrWhiteSpace($outputDirValue)) {
                Throw-LauncherConfigIssue -Field 'outputDir' -Value $outputDirValue -Problem 'Doit etre renseigné.' -Example '"outputDir": "./output"'
            }

            $depthValue = Get-LauncherDocumentProperty -InputObject $settings -Name 'depth' -Default $null
            if ($null -ne $depthValue) {
                $localDepth = ConvertTo-LauncherInteger -Value $depthValue -Name 'depth' -Default $localDepth -Minimum 1 -Maximum 20
            }

            $threadsValue = Get-LauncherDocumentProperty -InputObject $settings -Name 'threads' -Default $null
            if ($null -ne $threadsValue) {
                $localThreads = ConvertTo-LauncherInteger -Value $threadsValue -Name 'threads' -Default $localThreads -Minimum 1 -Maximum 200
            }

            $timeoutValue = Get-LauncherDocumentProperty -InputObject $settings -Name 'timeoutSeconds' -Default $null
            if ($null -ne $timeoutValue) {
                $localTimeout = ConvertTo-LauncherInteger -Value $timeoutValue -Name 'timeoutSeconds' -Default $localTimeout -Minimum 5 -Maximum 600
            }

            $uniqueUserAgentValue = [string](Get-LauncherDocumentProperty -InputObject $settings -Name 'uniqueUserAgent' -Default '')
            if ([string]::IsNullOrWhiteSpace($uniqueUserAgentValue)) {
                $uniqueUserAgentValue = "researcher-" + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
            }

            $localQuiet = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'quiet' -Default $Quiet) -Default $Quiet -Name 'quiet'
            $includeApexValue = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'includeApex' -Default $IncludeApex) -Default $IncludeApex -Name 'includeApex'
            $localRespectSchemeOnly = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'respectSchemeOnly' -Default $localRespectSchemeOnly) -Default $localRespectSchemeOnly -Name 'respectSchemeOnly'
            $localEnableGau = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'enableGau' -Default $localEnableGau) -Default $localEnableGau -Name 'enableGau'
            $localEnableWaybackUrls = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'enableWaybackUrls' -Default $localEnableWaybackUrls) -Default $localEnableWaybackUrls -Name 'enableWaybackUrls'
            $localEnableHakrawler = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'enableHakrawler' -Default $localEnableHakrawler) -Default $localEnableHakrawler -Name 'enableHakrawler'
            $localNoInstall = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'noInstall' -Default $NoInstall) -Default $NoInstall -Name 'noInstall'
            $localResume = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'resume' -Default $localResume) -Default $localResume -Name 'resume'
            $localOpenReportOnFinish = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'openReportOnFinish' -Default $OpenReportOnFinish) -Default $OpenReportOnFinish -Name 'openReportOnFinish'

            $scopePreview = Read-ScopeFile -Path $documentSet.ScopePath -IncludeApex:$includeApexValue

            return @{
                PresetName             = $preset.Name
                PresetDescription      = $preset.Description
                ProfileName            = $profile.Name
                ProfileDescription     = $profile.Description
                ProfileSourceExplanation = $profile.SourceExplanation
                ScopeFile              = $documentSet.ScopePath
                ProgramName            = $programNameValue
                OutputDir              = $outputDirValue
                Depth                  = $localDepth
                UniqueUserAgent        = $uniqueUserAgentValue
                Threads                = $localThreads
                TimeoutSeconds         = $localTimeout
                EnableGau              = $localEnableGau
                EnableWaybackUrls      = $localEnableWaybackUrls
                EnableHakrawler        = $localEnableHakrawler
                NoInstall              = $localNoInstall
                Quiet                  = $localQuiet
                IncludeApex            = $includeApexValue
                RespectSchemeOnly      = $localRespectSchemeOnly
                Resume                 = $localResume
                OpenReportOnFinish     = $localOpenReportOnFinish
                DocumentWorkspace      = $documentSet.RootPath
                ScopePreview           = $scopePreview
            }
        } catch {
            Write-Host ''
            $configIssues = @(Get-LauncherConfigIssues -Exception $_.Exception)
            if ($configIssues.Count -gt 0) {
                Show-LauncherConfigIssues -Issues $configIssues
                Write-Host 'Les documents vont etre rouverts pour correction.' -ForegroundColor Yellow
            } else {
                Write-LauncherSection -Title 'Erreur interne du launcher'
                Write-Host ("Une erreur inattendue a interrompu la validation: {0}" -f $_.Exception.Message) -ForegroundColor Red
                throw
            }
        }
    }
}

function Show-PostRunMenu {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    while ($true) {
        Write-LauncherSection -Title 'Actions'
        Write-Host '1. Revoir les pages intéressantes' -ForegroundColor Gray
        Write-Host '2. Voir les familles intéressantes' -ForegroundColor Gray
        Write-Host '3. Voir les catégories intéressantes' -ForegroundColor Gray
        Write-Host '4. Voir les endpoints protégés' -ForegroundColor Gray
        Write-Host '5. Voir le résumé des erreurs' -ForegroundColor Gray
        Write-Host '6. Voir les chemins d''export' -ForegroundColor Gray
        Write-Host '7. Terminer' -ForegroundColor Gray
        $choice = Read-LauncherChoice -Prompt 'Action' -Allowed @('1', '2', '3', '4', '5', '6', '7') -Default '7'
        switch ($choice) {
            '1' { Show-InterestingSummary -Result $Result }
            '2' { Show-InterestingFamilyBreakdown -Result $Result }
            '3' { Show-InterestingCategoryBreakdown -Result $Result }
            '4' { Show-ProtectedEndpoints -Result $Result }
            '5' { Show-ErrorSummaryPanel -Result $Result }
            '6' { Show-OutputPaths -Result $Result }
            '7' { break }
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
        [string]$InitialScopeFile,
        [string]$ProgramName,
        [string]$OutputDir,
        [int]$Depth,
        [string]$UniqueUserAgent,
        [int]$Threads,
        [int]$TimeoutSeconds,
        [bool]$EnableGau,
        [bool]$EnableWaybackUrls,
        [bool]$EnableHakrawler,
        [bool]$NoInstall,
        [bool]$Quiet,
        [bool]$IncludeApex,
        [bool]$RespectSchemeOnly,
        [bool]$Resume,
        [bool]$OpenReportOnFinish
    )

    $preset = Select-LauncherPreset
    $profile = Select-LauncherProgramProfile
    $localDepth = $preset.Depth
    $localThreads = $preset.Threads
    $localTimeout = $preset.TimeoutSeconds
    $localRespectSchemeOnly = $preset.RespectSchemeOnly
    $localResume = $preset.Resume
    $localEnableGau = $profile.UseGau
    $localEnableWaybackUrls = $profile.UseWaybackUrls
    $localEnableHakrawler = $profile.UseHakrawler

    if (-not $EnableGau) { $localEnableGau = $false }
    if (-not $EnableWaybackUrls) { $localEnableWaybackUrls = $false }
    if (-not $EnableHakrawler) { $localEnableHakrawler = $false }

    if ($profile.SuggestedDepth -gt 0) {
        if ($preset.Name -eq 'safe') {
            $localDepth = [Math]::Min($localDepth, $profile.SuggestedDepth)
        } else {
            $localDepth = [Math]::Max($localDepth, $profile.SuggestedDepth)
        }
    }
    if ($profile.SuggestedThreads -gt 0) {
        $localThreads = [Math]::Max($localThreads, $profile.SuggestedThreads)
    }
    if ($profile.ForceRespectSchemeOnly) { $localRespectSchemeOnly = $true }
    if ($profile.ForceResume) { $localResume = $true }

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
    $localDepth = Read-LauncherIntegerValue -Prompt 'Profondeur de crawl' -Name 'depth' -Default $localDepth -Minimum 1 -Maximum 20
    $localUserAgent = Read-LauncherValue -Prompt 'User-Agent unique' -Default $localUserAgent
    $localThreads = Read-LauncherIntegerValue -Prompt 'Threads' -Name 'threads' -Default $localThreads -Minimum 1 -Maximum 200
    $localTimeout = Read-LauncherIntegerValue -Prompt 'Timeout secondes' -Name 'timeoutSeconds' -Default $localTimeout -Minimum 5 -Maximum 600
    $localIncludeApex = [bool](Read-LauncherYesNo -Prompt 'Inclure l''apex des wildcards ?' -Default $IncludeApex)
    $localRespectSchemeOnly = [bool](Read-LauncherYesNo -Prompt 'Respecter strictement le schéma explicite ?' -Default $localRespectSchemeOnly)
    Write-Host ''
    Write-Host 'Sources complémentaires' -ForegroundColor Cyan
    Write-Host ("  Profil {0} : {1}" -f $profile.Name, $profile.SourceExplanation) -ForegroundColor DarkGray
    $localEnableGau = [bool](Read-LauncherYesNo -Prompt 'Activer gau pour les URLs historiques ?' -Default $localEnableGau)
    $localEnableWaybackUrls = [bool](Read-LauncherYesNo -Prompt 'Activer waybackurls pour les archives web ?' -Default $localEnableWaybackUrls)
    $localEnableHakrawler = [bool](Read-LauncherYesNo -Prompt 'Activer hakrawler en crawl complémentaire ?' -Default $localEnableHakrawler)
    $localNoInstall = [bool](Read-LauncherYesNo -Prompt 'Désactiver le bootstrap outils ?' -Default $NoInstall)
    $localResume = [bool](Read-LauncherYesNo -Prompt 'Activer le mode reprise ?' -Default $localResume)
    $localOpenReportOnFinish = [bool](Read-LauncherYesNo -Prompt 'Ouvrir le rapport HTML a la fin ?' -Default $OpenReportOnFinish)

    return @{
        PresetName        = $preset.Name
        PresetDescription = $preset.Description
        ProfileName       = $profile.Name
        ProfileDescription = $profile.Description
        ProfileSourceExplanation = $profile.SourceExplanation
        ScopeFile         = $localScopeFile
        ProgramName       = $localProgramName
        OutputDir         = $localOutputDir
        Depth             = $localDepth
        UniqueUserAgent   = $localUserAgent
        Threads           = $localThreads
        TimeoutSeconds    = $localTimeout
        EnableGau         = $localEnableGau
        EnableWaybackUrls = $localEnableWaybackUrls
        EnableHakrawler   = $localEnableHakrawler
        NoInstall         = $localNoInstall
        Quiet             = $Quiet
        IncludeApex       = $localIncludeApex
        RespectSchemeOnly = $localRespectSchemeOnly
        Resume            = $localResume
        OpenReportOnFinish = $localOpenReportOnFinish
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
        EnableGau         = $EnableGau
        EnableWaybackUrls = $EnableWaybackUrls
        EnableHakrawler   = $EnableHakrawler
        NoInstall         = [bool]$NoInstall
        Quiet             = [bool]$Quiet
        IncludeApex       = [bool]$IncludeApex
        RespectSchemeOnly = [bool]$RespectSchemeOnly
        Resume            = [bool]$Resume
        OpenReportOnFinish = $OpenReportOnFinish
    }

    if (-not $NonInteractive) {
        Write-LauncherBanner
        if ($ConsoleMode) {
            $runConfig = Build-InteractiveRunConfig -InitialScopeFile $ScopeFile -ProgramName $ProgramName -OutputDir $OutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -EnableGau $EnableGau -EnableWaybackUrls $EnableWaybackUrls -EnableHakrawler $EnableHakrawler -NoInstall ([bool]$NoInstall) -Quiet ([bool]$Quiet) -IncludeApex ([bool]$IncludeApex) -RespectSchemeOnly ([bool]$RespectSchemeOnly) -Resume ([bool]$Resume) -OpenReportOnFinish $OpenReportOnFinish
        } else {
            $runConfig = Build-DocumentRunConfig -InitialScopeFile $ScopeFile -ProgramName $ProgramName -OutputDir $OutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -EnableGau $EnableGau -EnableWaybackUrls $EnableWaybackUrls -EnableHakrawler $EnableHakrawler -NoInstall ([bool]$NoInstall) -Quiet ([bool]$Quiet) -IncludeApex ([bool]$IncludeApex) -RespectSchemeOnly ([bool]$RespectSchemeOnly) -Resume ([bool]$Resume) -OpenReportOnFinish $OpenReportOnFinish
        }
        $scopePreview = if ($runConfig.ContainsKey('ScopePreview')) { $runConfig.ScopePreview } else { Read-ScopeFile -Path $runConfig.ScopeFile -IncludeApex:([bool]$runConfig.IncludeApex) }
        Show-ScopePreview -ScopeItems $scopePreview
        Show-LauncherConfigPreview -RunConfig $runConfig
        if ($ConsoleMode) {
            if (-not (Read-LauncherYesNo -Prompt 'Confirmer le lancement ?' -Default $true)) { return }
        } else {
            Write-Host ''
            Write-Host 'Configuration validee. Demarrage automatique de la collecte.' -ForegroundColor Green
        }
    }

    $invokeParams = Get-LauncherInvokeParams -RunConfig $runConfig
    $result = Invoke-BugBountyRecon @invokeParams
    Show-RunSummaryDashboard -Result $result
    Show-InterestingSummary -Result $result
    Show-ErrorSummaryPanel -Result $result
    Show-OutputPaths -Result $result

    if ($runConfig.OpenReportOnFinish) {
        Open-LauncherPath -Path (Join-Path $result.OutputDir 'reports/report.html')
    }

    if ((-not $NonInteractive) -and $ConsoleMode) {
        Show-PostRunMenu -Result $result
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-ScopeForgeLauncher @PSBoundParameters
}
