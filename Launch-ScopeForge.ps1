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
    [switch]$RerunPrevious,
    [string]$RerunManifestPath,
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
    $panelWidth = Get-LauncherPanelWidth
    $innerWidth = $panelWidth - 4
    $border = '+' + ''.PadRight($panelWidth - 2, '-') + '+'
    $logoLines = @(
        '   _____                      ______',
        '  / ___/________  ____  ___  / ____/___  _________ ____',
        '  \__ \/ ___/ __ \/ __ \/ _ \/ /   / __ \/ ___/ __ `/ _ \',
        ' ___/ / /__/ /_/ / /_/ /  __/ /___/ /_/ / /  / /_/ /  __/',
        '/____/\___/\____/ .___/\___/\____/\____/_/   \__, /\___/',
        '               /_/                         /____/'
    )

    Write-Host ''
    Write-Host $border -ForegroundColor DarkCyan
    foreach ($line in $logoLines) {
        Write-Host ("| {0} |" -f $line.PadRight($innerWidth)) -ForegroundColor Cyan
    }
    Write-Host ("| {0} |" -f ''.PadRight($innerWidth)) -ForegroundColor DarkCyan
    Write-Host ("| {0} |" -f 'ScopeForge Operator Console'.PadRight($innerWidth)) -ForegroundColor Gray
    Write-Host ("| {0} |" -f 'authorized programs only'.PadRight($innerWidth)) -ForegroundColor DarkGray
    Write-Host $border -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-LauncherSection {
    param([Parameter(Mandatory)][string]$Title)

    $panelWidth = Get-LauncherPanelWidth
    $titleText = (" {0} " -f $Title)
    if ($titleText.Length -gt ($panelWidth - 2)) {
        $titleText = $titleText.Substring(0, $panelWidth - 2)
    }
    $remaining = [Math]::Max($panelWidth - 2 - $titleText.Length, 0)
    Write-Host ''
    Write-Host ('+' + $titleText + ''.PadRight($remaining, '-')) -ForegroundColor DarkCyan
}

function Get-LauncherConsoleWidth {
    try {
        return [Math]::Max($Host.UI.RawUI.BufferSize.Width, 100)
    } catch {
        return 120
    }
}

function Get-LauncherPanelWidth {
    return [Math]::Max([Math]::Min((Get-LauncherConsoleWidth), 116), 72)
}

function Get-LauncherStatusColor {
    param([AllowNull()][string]$Status)

    switch (($Status ?? '').ToUpperInvariant()) {
        'OK' { return 'Green' }
        'ARCHIVE' { return 'DarkYellow' }
        'SUPPRIME' { return 'DarkRed' }
        'INTROUVABLE' { return 'Yellow' }
        default { return 'Gray' }
    }
}

function Write-LauncherStatusLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][string]$Status,
        [AllowNull()][string]$Details = ''
    )

    $statusText = if ([string]::IsNullOrWhiteSpace($Status)) { '-' } else { $Status }
    $suffix = if ([string]::IsNullOrWhiteSpace($Details)) { '' } else { " - $Details" }
    Write-Host ("  {0,-18}: {1}{2}" -f $Label, $statusText, $suffix) -ForegroundColor (Get-LauncherStatusColor -Status $statusText)
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

    Write-LauncherKeyValue -Key $Key -Value $Value -Color ([string]$Color)
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
    $prefix = ("  {0,-$Padding}: " -f $Key)
    $valueWidth = [Math]::Max((Get-LauncherConsoleWidth) - $prefix.Length - 2, 24)
    $wrappedLines = @(Split-LauncherWrappedText -Value $displayValue -Width $valueWidth)
    for ($lineIndex = 0; $lineIndex -lt $wrappedLines.Count; $lineIndex++) {
        $linePrefix = if ($lineIndex -eq 0) { $prefix } else { ''.PadRight($prefix.Length, ' ') }
        Write-Host ($linePrefix + $wrappedLines[$lineIndex]) -ForegroundColor $Color
    }
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

function Write-LauncherMenuOption {
    param(
        [Parameter(Mandatory)][string]$Number,
        [Parameter(Mandatory)][string]$Label,
        [bool]$IsDefault = $false,
        [AllowNull()][string]$Hint = ''
    )

    $marker = if ($IsDefault) { '>' } else { ' ' }
    $defaultTag = if ($IsDefault) { ' [defaut]' } else { '' }
    $hintSuffix = if ([string]::IsNullOrWhiteSpace($Hint)) { '' } else { " - $Hint" }
    $color = if ($IsDefault) { 'Green' } else { 'Gray' }
    Write-Host (" {0} {1,-4} {2}{3}{4}" -f $marker, ($Number + '.'), $Label, $defaultTag, $hintSuffix) -ForegroundColor $color
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

function Select-LauncherIndexedItem {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [hashtable]$Headers = @{},
        [hashtable]$Widths = @{},
        [string]$Prompt = 'Choix',
        [string]$DefaultChoice = '1'
    )

    if (-not $Rows -or $Rows.Count -eq 0) { return $null }

    if ((Get-LauncherInteractionMode) -eq 'visual' -and (Test-LauncherVisualModeSupport)) {
        try {
            $selected = @($Rows | Select-Object $Columns | Out-GridView -Title $Title -PassThru | Select-Object -First 1)
            if (-not $selected -or $selected.Count -eq 0) { return $null }
            $selectedIndex = [string]$selected[0].Index
            return ($Rows | Where-Object { [string]$_.Index -eq $selectedIndex } | Select-Object -First 1)
        } catch {
            Write-Host "Le mode visuel n'est pas disponible dans cet hote. Retour au mode console." -ForegroundColor Yellow
        }
    }

    Write-LauncherTable -Rows $Rows -Columns $Columns -Headers $Headers -Widths $Widths
    $allowedChoices = @('0') + @($Rows | ForEach-Object { [string]$_.Index })
    $defaultValue = if ($allowedChoices -contains $DefaultChoice) { $DefaultChoice } else { '0' }
    if ($defaultValue -ne '0') {
        Write-Host ("  > Valeur par defaut : {0}" -f $defaultValue) -ForegroundColor DarkGray
    }
    $choice = Read-LauncherChoice -Prompt $Prompt -Allowed $allowedChoices -Default $defaultValue
    if ($choice -eq '0') { return $null }
    return ($Rows | Where-Object { [string]$_.Index -eq $choice } | Select-Object -First 1)
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

function Get-LauncherDictionarySupportStatus {
    return [pscustomobject]@{
        Status         = 'not_proven'
        DisplayLabel   = 'Non pris en charge dans cette version'
        Detail         = "Aucun parametre ni workflow dictionnaire/wordlist n'a ete verifie dans le moteur actuel."
        Recommendation = "N'ajoute aucun champ custom lie a un dictionnaire dans 02-run-settings.json."
    }
}

function Get-LauncherScopeComposition {
    param([Parameter(Mandatory)][pscustomobject[]]$ScopeItems)

    $domainCount = @($ScopeItems | Where-Object { $_.Type -eq 'Domain' }).Count
    $wildcardCount = @($ScopeItems | Where-Object { $_.Type -eq 'Wildcard' }).Count
    $urlCount = @($ScopeItems | Where-Object { $_.Type -eq 'URL' }).Count
    $totalExclusions = 0
    foreach ($item in $ScopeItems) {
        $totalExclusions += @($item.Exclusions).Count
    }

    $typeLabels = [System.Collections.Generic.List[string]]::new()
    if ($domainCount -gt 0) { $typeLabels.Add('Domain') | Out-Null }
    if ($wildcardCount -gt 0) { $typeLabels.Add('Wildcard') | Out-Null }
    if ($urlCount -gt 0) { $typeLabels.Add('URL') | Out-Null }

    return [pscustomobject]@{
        DomainCount      = $domainCount
        WildcardCount    = $wildcardCount
        UrlCount         = $urlCount
        TotalEntries     = $ScopeItems.Count
        TotalExclusions  = $totalExclusions
        MixedTypes       = ($typeLabels.Count -gt 1)
        TypeSummary      = $(if ($typeLabels.Count -gt 0) { $typeLabels -join ', ' } else { '-' })
    }
}

function Get-LauncherApproximateTimeEstimate {
    param(
        [Parameter(Mandatory)][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][hashtable]$RunConfig
    )

    $scopeComposition = Get-LauncherScopeComposition -ScopeItems $ScopeItems
    $score = 0.0
    $reasons = [System.Collections.Generic.List[string]]::new()

    $score += $scopeComposition.DomainCount
    $score += ($scopeComposition.UrlCount * 1.5)
    $score += ($scopeComposition.WildcardCount * 3.0)
    $score += ([Math]::Min($scopeComposition.TotalExclusions, 8) * 0.2)

    if ($scopeComposition.WildcardCount -gt 0) {
        $reasons.Add("les wildcards elargissent la collecte") | Out-Null
    }
    if ($scopeComposition.TotalEntries -ge 4) {
        $reasons.Add("plusieurs cibles sont melangees dans le scope") | Out-Null
    }

    if ($RunConfig.Depth -ge 4) {
        $score += 3
        $reasons.Add("la profondeur de crawl est elevee") | Out-Null
    } elseif ($RunConfig.Depth -ge 3) {
        $score += 1.5
    }

    if ($RunConfig.EnableGau) { $score += 1; $reasons.Add("gau ajoute des URLs historiques") | Out-Null }
    if ($RunConfig.EnableWaybackUrls) { $score += 1; $reasons.Add("waybackurls ajoute des archives web") | Out-Null }
    if ($RunConfig.EnableHakrawler) { $score += 2; $reasons.Add("hakrawler ajoute un crawl complementaire") | Out-Null }
    if ($RunConfig.IncludeApex -and $scopeComposition.WildcardCount -gt 0) { $score += 0.5 }
    if ($RunConfig.Resume) {
        $score -= 2.5
        $reasons.Add("resume peut reduire la duree si des donnees existent deja") | Out-Null
    }
    if ($RunConfig.Threads -ge 20) {
        $score -= 0.5
    } elseif ($RunConfig.Threads -le 5) {
        $score += 0.5
    }

    $band = if ($score -le 3) {
        'Tres court'
    } elseif ($score -le 6) {
        'Court'
    } elseif ($score -le 10) {
        'Moyen'
    } elseif ($score -le 14) {
        'Long'
    } else {
        'Tres long'
    }

    if ($reasons.Count -eq 0) {
        $reasons.Add("scope simple et options limitees") | Out-Null
    }

    return [pscustomobject]@{
        Band       = $band
        Score      = [Math]::Round($score, 1)
        ReasonText = ($reasons | Select-Object -Unique | Select-Object -First 3) -join '; '
        ScopeStats = $scopeComposition
    }
}

function Show-LauncherPreRunSummary {
    param(
        [Parameter(Mandatory)][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][hashtable]$RunConfig
    )

    $scopeComposition = Get-LauncherScopeComposition -ScopeItems $ScopeItems
    $estimate = Get-LauncherApproximateTimeEstimate -ScopeItems $ScopeItems -RunConfig $RunConfig
    $dictionarySupport = Get-LauncherDictionarySupportStatus

    Write-LauncherSection -Title 'Resume avant lancement'

    Write-Host '  Composition du scope' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Types detectes' -Value $scopeComposition.TypeSummary
    Write-LauncherKeyValue -Key 'Entrees Domain' -Value $scopeComposition.DomainCount
    Write-LauncherKeyValue -Key 'Entrees Wildcard' -Value $scopeComposition.WildcardCount
    Write-LauncherKeyValue -Key 'Entrees URL' -Value $scopeComposition.UrlCount
    Write-LauncherKeyValue -Key 'Exclusions totales' -Value $scopeComposition.TotalExclusions

    Write-Host ''
    Write-Host '  Reglages du run' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Session active' -Value $(if ($RunConfig.ContainsKey('LauncherSessionId') -and $RunConfig.LauncherSessionId) { $RunConfig.LauncherSessionId } elseif ($RunConfig.ContainsKey('LauncherSessionRoot') -and $RunConfig.LauncherSessionRoot) { [System.IO.Path]::GetFileName([string]$RunConfig.LauncherSessionRoot) } else { 'Session provisoire' })
    Write-LauncherKeyValue -Key 'Fichier de scope' -Value $(if ($RunConfig.ContainsKey('ScopeFile')) { [string]$RunConfig.ScopeFile } else { '-' })
    Write-LauncherKeyValue -Key '02-run-settings.json' -Value $(if ($RunConfig.ContainsKey('LauncherSessionRoot') -and $RunConfig.LauncherSessionRoot) { Join-Path ([string]$RunConfig.LauncherSessionRoot) '02-run-settings.json' } else { '-' })
    Write-LauncherKeyValue -Key 'Dossier de sortie' -Value $RunConfig.OutputDir
    Write-LauncherKeyValue -Key 'Dossier logs' -Value (Get-LauncherPlannedLogRoot -RunConfig $RunConfig)
    Write-LauncherKeyValue -Key 'Mode de logs' -Value $(if ($RunConfig.ContainsKey('LauncherLogMode')) { $RunConfig.LauncherLogMode } else { Get-LauncherDefaultLoggingMode })
    Write-LauncherKeyValue -Key 'Resume' -Value $RunConfig.Resume
    Write-LauncherKeyValue -Key 'Sources actives' -Value (Get-LauncherSourceSummary -EnableGau $RunConfig.EnableGau -EnableWaybackUrls $RunConfig.EnableWaybackUrls -EnableHakrawler $RunConfig.EnableHakrawler)
    Write-LauncherKeyValue -Key 'Wordlist / dictionnaire' -Value $dictionarySupport.DisplayLabel -Color 'DarkGray'

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($RunConfig.ContainsKey('ScopeFile') -and [string]$RunConfig.ScopeFile -and -not (Test-Path -LiteralPath ([string]$RunConfig.ScopeFile))) {
        $warnings.Add("Le fichier de scope est introuvable: $([string]$RunConfig.ScopeFile)") | Out-Null
    }
    if ($RunConfig.ContainsKey('LauncherSessionRoot') -and [string]$RunConfig.LauncherSessionRoot -and -not (Test-Path -LiteralPath ([string]$RunConfig.LauncherSessionRoot))) {
        $warnings.Add("Le dossier de session n'existe pas encore et sera cree au lancement.") | Out-Null
    }
    if ($RunConfig.ContainsKey('Resume') -and [bool]$RunConfig.Resume) {
        $warnings.Add("Resume depend des donnees deja presentes dans le dossier de sortie.") | Out-Null
    }

    Write-Host ''
    Write-Host '  Duree approximative' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Estimation' -Value $estimate.Band
    Write-LauncherKeyValue -Key 'Pourquoi' -Value $estimate.ReasonText -Color 'DarkGray'
    if ($warnings.Count -gt 0) {
        Write-Host ''
        Write-Host '  Points a verifier' -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Host ("    - {0}" -f $warning) -ForegroundColor DarkYellow
        }
    }
    Write-Host '  Cette estimation est approximative. Elle sert seulement a se reperer avant le lancement.' -ForegroundColor DarkGray
    Write-Host '  Prochaine etape : confirme le lancement si tout correspond bien au scope, aux logs et au dossier de sortie.' -ForegroundColor DarkGray
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
    Write-Host ("  Entrees de scope valides : {0}" -f $ScopeItems.Count) -ForegroundColor Gray
    $rows = @($ScopeItems | ForEach-Object {
        [pscustomobject]@{
            Identifiant = $_.Id
            Type       = $_.Type
            Valeur     = $_.NormalizedValue
            Exclusions = if ($_.Exclusions -and $_.Exclusions.Count -gt 0) { ($_.Exclusions -join ', ') } else { '-' }
        }
    })
    Write-LauncherTable -Rows $rows -Columns @('Identifiant', 'Type', 'Valeur', 'Exclusions') -Widths @{ Identifiant = 12; Type = 10; Valeur = 56; Exclusions = 24 }
}

function Show-LauncherConfigPreview {
    param([Parameter(Mandatory)][hashtable]$RunConfig)
    Write-LauncherSection -Title 'Configuration'
    if ($RunConfig.ContainsKey('DocumentWorkspace')) {
        Write-LauncherKeyValue -Key 'Workspace documents' -Value $RunConfig.DocumentWorkspace
    }
    if ($RunConfig.ContainsKey('PresetName')) {
        Write-Host ''
        Write-Host '  Programme' -ForegroundColor Cyan
        Write-LauncherKeyValue -Key 'Preset' -Value $RunConfig.PresetName
        Write-LauncherKeyValue -Key 'Description preset' -Value $RunConfig.PresetDescription -Color 'DarkGray'
    }
    if ($RunConfig.ContainsKey('ProfileName')) {
        Write-LauncherKeyValue -Key 'Profil cible' -Value $RunConfig.ProfileName
        Write-LauncherKeyValue -Key 'Details profil' -Value $RunConfig.ProfileDescription -Color 'DarkGray'
        if ($RunConfig.ContainsKey('ProfileSourceExplanation')) {
            Write-LauncherKeyValue -Key 'Strategie sources' -Value $RunConfig.ProfileSourceExplanation -Color 'DarkGray'
        }
    }

    Write-LauncherKeyValue -Key 'Fichier de scope' -Value $RunConfig.ScopeFile
    if ($RunConfig.ContainsKey('LauncherSessionRoot')) {
        Write-LauncherKeyValue -Key 'Session active' -Value $RunConfig.LauncherSessionRoot
    }
    if ($RunConfig.ContainsKey('LauncherLogMode')) {
        Write-LauncherKeyValue -Key 'Mode de logs' -Value $RunConfig.LauncherLogMode
    }
    Write-LauncherKeyValue -Key 'Nom du programme' -Value $RunConfig.ProgramName
    Write-LauncherKeyValue -Key 'Dossier de sortie' -Value $RunConfig.OutputDir
    if ($RunConfig.ContainsKey('LauncherLogRoot')) {
        Write-LauncherKeyValue -Key 'Dossier logs' -Value $RunConfig.LauncherLogRoot
    }

    Write-Host ''
    Write-Host '  Vitesse et volume' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Profondeur' -Value $RunConfig.Depth
    Write-LauncherKeyValue -Key 'Concurrence' -Value $RunConfig.Threads
    Write-LauncherKeyValue -Key 'Timeout' -Value $RunConfig.TimeoutSeconds
    Write-LauncherKeyValue -Key 'User-Agent' -Value $RunConfig.UniqueUserAgent

    Write-Host ''
    Write-Host '  Couverture' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Sources actives' -Value (Get-LauncherSourceSummary -EnableGau $RunConfig.EnableGau -EnableWaybackUrls $RunConfig.EnableWaybackUrls -EnableHakrawler $RunConfig.EnableHakrawler)

    Write-Host ''
    Write-Host '  Options' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Inclure apex' -Value $RunConfig.IncludeApex
    Write-LauncherKeyValue -Key 'Respecter le scheme' -Value $RunConfig.RespectSchemeOnly
    Write-LauncherKeyValue -Key 'Sans installation' -Value $RunConfig.NoInstall
    Write-LauncherKeyValue -Key 'Sortie reduite' -Value $RunConfig.Quiet
    Write-LauncherKeyValue -Key 'Reprise' -Value $RunConfig.Resume
    if ($RunConfig.ContainsKey('OpenReportOnFinish')) {
        Write-LauncherKeyValue -Key 'Ouvrir le rapport' -Value $RunConfig.OpenReportOnFinish
    }
}

function Show-RunSummaryDashboard {
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $summary = $Result.Summary
    $protectedCount = @($Result.LiveTargets | Where-Object { $_.StatusCode -in 401, 403 }).Count
    $metricRows = @(
        @{ Label = 'Items scope'; Count = [int]$summary.ScopeItemCount },
        @{ Label = 'Exclus'; Count = [int]$summary.ExcludedItemCount },
        @{ Label = 'Hosts decouverts'; Count = [int]$summary.DiscoveredHostCount },
        @{ Label = 'Hosts live'; Count = [int]$summary.LiveHostCount },
        @{ Label = 'Cibles live'; Count = [int]$summary.LiveTargetCount },
        @{ Label = 'URLs decouvertes'; Count = [int]$summary.DiscoveredUrlCount },
        @{ Label = 'URLs interessantes'; Count = [int]$summary.InterestingUrlCount },
        @{ Label = 'Proteges 401/403'; Count = [int]$protectedCount },
        @{ Label = 'Erreurs'; Count = [int]$summary.ErrorCount }
    )
    $maxMetricCount = [int](($metricRows | Measure-Object -Property Count -Maximum).Maximum)
    if ($maxMetricCount -lt 1) { $maxMetricCount = 1 }
    Write-LauncherSection -Title 'Tableau de bord'
    Write-Host '  Compteurs' -ForegroundColor Cyan
    foreach ($metric in $metricRows) {
        Write-LauncherBarRow -Label $metric.Label -Count $metric.Count -MaxCount $maxMetricCount -Color 'Gray'
    }

    if ($summary.TopTechnologies -and $summary.TopTechnologies.Count -gt 0) {
        Write-Host ''
        Write-Host '  Technologies detectees' -ForegroundColor Cyan
        $maxTech = [int](($summary.TopTechnologies | Measure-Object -Property Count -Maximum).Maximum)
        foreach ($item in ($summary.TopTechnologies | Select-Object -First 5)) {
            Write-LauncherBarRow -Label $item.Technology -Count ([int]$item.Count) -MaxCount $maxTech
        }
    }

    if ($summary.TopInterestingFamilies -and $summary.TopInterestingFamilies.Count -gt 0) {
        Write-Host ''
        Write-Host '  Familles interessantes' -ForegroundColor Cyan
        $maxFamilies = [int](($summary.TopInterestingFamilies | Measure-Object -Property Count -Maximum).Maximum)
        foreach ($item in ($summary.TopInterestingFamilies | Select-Object -First 5)) {
            Write-LauncherBarRow -Label $item.Family -Count ([int]$item.Count) -MaxCount $maxFamilies
        }
    }

    if ($summary.InterestingPriorityDistribution -and $summary.InterestingPriorityDistribution.Count -gt 0) {
        Write-Host ''
        Write-Host '  Repartition des priorites' -ForegroundColor Cyan
        $maxPriority = [int](($summary.InterestingPriorityDistribution | Measure-Object -Property Count -Maximum).Maximum)
        foreach ($item in $summary.InterestingPriorityDistribution) {
            Write-LauncherBarRow -Label $item.Priority -Count ([int]$item.Count) -MaxCount $maxPriority
        }
    }

    if ($summary.TopInterestingCategories -and $summary.TopInterestingCategories.Count -gt 0) {
        Write-Host ''
        Write-Host '  Categories interessantes' -ForegroundColor Cyan
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
    Write-Host '  Session et logs' -ForegroundColor Cyan
    if ($Result.PSObject.Properties['LauncherSessionRoot']) {
        Write-LauncherLink -Label 'Ouvrir le dossier de session' -Path $Result.LauncherSessionRoot
    }
    if ($Result.PSObject.Properties['LauncherLogRoot']) {
        Write-LauncherLink -Label 'Ouvrir les logs du launcher' -Path $Result.LauncherLogRoot
    }
    Write-LauncherLink -Label 'Ouvrir errors.log' -Path (Join-Path $Result.OutputDir 'logs/errors.log')
    Write-LauncherLink -Label 'Ouvrir tools.log' -Path (Join-Path $Result.OutputDir 'logs/tools.log')

    Write-Host ''
    Write-Host '  Rapports' -ForegroundColor Cyan
    Write-LauncherLink -Label 'Ouvrir report.html' -Path (Join-Path $Result.OutputDir 'reports/report.html')
    Write-LauncherLink -Label 'Ouvrir triage.md' -Path (Join-Path $Result.OutputDir 'reports/triage.md')
    Write-LauncherLink -Label 'Ouvrir run-manifest.json' -Path (Join-Path $Result.OutputDir 'reports/run-manifest.json')
    Write-LauncherLink -Label 'Ouvrir scope-frozen.json' -Path (Join-Path $Result.OutputDir 'reports/scope-frozen.json')
    Write-LauncherLink -Label 'Ouvrir run-settings-frozen.json' -Path (Join-Path $Result.OutputDir 'reports/run-settings-frozen.json')

    Write-Host ''
    Write-Host '  Fichiers normalises' -ForegroundColor Cyan
    Write-LauncherLink -Label 'Ouvrir interesting_urls.json' -Path (Join-Path $Result.OutputDir 'normalized/interesting_urls.json')
    Write-LauncherLink -Label 'Ouvrir interesting_families.json' -Path (Join-Path $Result.OutputDir 'normalized/interesting_families.json')
    Write-LauncherLink -Label 'Ouvrir live_targets.json' -Path (Join-Path $Result.OutputDir 'normalized/live_targets.json')
}

function Show-LauncherInvokeDebugPanel {
    param(
        [Parameter(Mandatory)][hashtable]$RunConfig,
        [Parameter(Mandatory)][hashtable]$InvokeParams
    )

    if ($VerbosePreference -ne 'Continue') { return }

    $switchNames = @('NoInstall', 'Quiet', 'IncludeApex', 'RespectSchemeOnly', 'ExportHtml', 'ExportCsv', 'ExportJson', 'Resume')
    $rows = @(
        foreach ($name in @('EnableGau', 'EnableWaybackUrls', 'EnableHakrawler') + $switchNames) {
            $runValue = if ($RunConfig.ContainsKey($name)) { $RunConfig[$name] } else { $null }
            $runType = if ($null -eq $runValue) { '-' } else { $runValue.GetType().Name }
            $invokeValue = if ($InvokeParams.ContainsKey($name)) { $InvokeParams[$name] } elseif ($switchNames -contains $name) { '<omitted>' } else { '-' }
            $invokeType = if ($InvokeParams.ContainsKey($name)) { $InvokeParams[$name].GetType().Name } else { '-' }
            [pscustomobject]@{
                Field      = $name
                RunType    = $runType
                RunValue   = $(if ($null -eq $runValue) { '-' } else { (ConvertTo-LauncherCellText -Value $runValue) })
                InvokeType = $invokeType
                InvokeValue = $(if ($null -eq $invokeValue) { '-' } else { (ConvertTo-LauncherCellText -Value $invokeValue) })
            }
        }
    )

    Write-LauncherSection -Title 'Invoke debug'
    Write-LauncherTable -Rows $rows -Columns @('Field', 'RunType', 'RunValue', 'InvokeType', 'InvokeValue') -Widths @{ Field = 18; RunType = 12; RunValue = 14; InvokeType = 12; InvokeValue = 14 }
}

function Show-NextActionsPanel {
    param([Parameter(Mandatory)][pscustomobject]$Result)

    $protectedCount = @($Result.LiveTargets | Where-Object { $_.StatusCode -in 401, 403 }).Count
    $topCategory = $Result.Summary.TopInterestingCategories | Select-Object -First 1
    $topFamily = $Result.Summary.TopInterestingFamilies | Select-Object -First 1

    Write-LauncherSection -Title 'Prochaines actions'
    if ($protectedCount -gt 0) {
        Write-Host ("  Revoir les endpoints proteges: {0} cible(s) 401/403." -f $protectedCount) -ForegroundColor Yellow
    }
    if ($topCategory) {
        Write-Host ("  Priorite categorie: {0} ({1})" -f $topCategory.Category, $topCategory.Count) -ForegroundColor Gray
    }
    if ($topFamily) {
        Write-Host ("  Priorite famille  : {0} ({1})" -f $topFamily.Family, $topFamily.Count) -ForegroundColor Gray
    }
    if ($Result.Errors -and $Result.Errors.Count -gt 0) {
        Write-Host "  Verifie errors.log et tools.log avant d'elargir le run." -ForegroundColor Yellow
    }
    Write-Host ("  Rapport HTML      : {0}" -f (Join-Path $Result.OutputDir 'reports/report.html')) -ForegroundColor Green
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
        Group-Object -Property Phase, Tool |
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
        Group-Object -Property Phase, Tool |
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
    $runsRoot = Get-LauncherRunsRoot
    return (Get-LauncherUniqueRunDirectory)
}

function Get-LauncherRunsRoot {
    $runsRoot = Join-Path (Get-LauncherStorageRoot) 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) {
        $null = New-Item -ItemType Directory -Path $runsRoot -Force
    }
    return $runsRoot
}

function Get-LauncherDocumentsRoot {
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

    return $launcherRoot
}

function Get-LauncherUiStatePath {
    return (Join-Path (Get-LauncherDocumentsRoot) 'launcher-state.json')
}

function Read-LauncherUiState {
    $statePath = Get-LauncherUiStatePath
    if (-not (Test-Path -LiteralPath $statePath)) {
        return [pscustomobject]@{
            version                  = 1
            interaction_mode         = ''
            logging_mode             = 'normal'
            last_selected_session_id = ''
        }
    }

    try {
        $raw = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty' }
        $parsed = ConvertFrom-Json -InputObject $raw -Depth 20
    } catch {
        return [pscustomobject]@{
            version                  = 1
            interaction_mode         = ''
            logging_mode             = 'normal'
            last_selected_session_id = ''
        }
    }

    return [pscustomobject]@{
        version                  = 1
        interaction_mode         = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'interaction_mode' -Default '')
        logging_mode             = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'logging_mode' -Default 'normal')
        last_selected_session_id = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'last_selected_session_id' -Default '')
    }
}

function Write-LauncherUiState {
    param([Parameter(Mandatory)][pscustomobject]$State)

    $statePath = Get-LauncherUiStatePath
    Set-Content -LiteralPath $statePath -Value ($State | ConvertTo-Json -Depth 20) -Encoding utf8
    return $statePath
}

function Update-LauncherUiState {
    param([Parameter(Mandatory)][hashtable]$Values)

    $current = Read-LauncherUiState
    $updated = [ordered]@{
        version                  = 1
        interaction_mode         = $current.interaction_mode
        logging_mode             = $current.logging_mode
        last_selected_session_id = $current.last_selected_session_id
    }

    foreach ($key in $Values.Keys) {
        $updated[$key] = $Values[$key]
    }

    return (Write-LauncherUiState -State ([pscustomobject]$updated))
}

function Test-LauncherVisualModeSupport {
    if (-not $IsWindows) { return $false }
    return [bool](Get-Command -Name 'Out-GridView' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-LauncherInteractionMode {
    $state = Read-LauncherUiState
    $requestedMode = [string]$state.interaction_mode
    if ($requestedMode -eq 'visual' -and (Test-LauncherVisualModeSupport)) { return 'visual' }
    if ($requestedMode -eq 'console') { return 'console' }
    if (Test-LauncherVisualModeSupport) { return 'visual' }
    return 'console'
}

function Set-LauncherInteractionMode {
    param([Parameter(Mandatory)][ValidateSet('visual', 'console')][string]$Mode)

    $effectiveMode = if ($Mode -eq 'visual' -and -not (Test-LauncherVisualModeSupport)) { 'console' } else { $Mode }
    $null = Update-LauncherUiState -Values @{ interaction_mode = $effectiveMode }
    return $effectiveMode
}

function Get-LauncherFileWorkspace {
    $repoRoot = $PSScriptRoot
    $scopesRoot = Join-Path $repoRoot 'scopes'
    $stateRoot = Join-Path $repoRoot 'state'

    return [pscustomobject]@{
        RepoRoot         = $repoRoot
        ScopesRoot       = $scopesRoot
        Incoming         = Join-Path $scopesRoot 'incoming'
        Active           = Join-Path $scopesRoot 'active'
        Archived         = Join-Path $scopesRoot 'archived'
        Templates        = Join-Path $scopesRoot 'templates'
        TemplatesGuide   = Join-Path (Join-Path $scopesRoot 'templates') 'README.md'
        StateRoot        = $stateRoot
        RecentScopesPath = Join-Path $stateRoot 'recent-scopes.json'
    }
}

function Initialize-LauncherFileWorkspace {
    $workspace = Get-LauncherFileWorkspace
    # Ces dossiers restent stables pour que le launcher puisse retrouver
    # facilement les scopes, les modeles et l'historique recent.
    foreach ($path in @($workspace.ScopesRoot, $workspace.Incoming, $workspace.Active, $workspace.Archived, $workspace.Templates, $workspace.StateRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            $null = New-Item -ItemType Directory -Path $path -Force
        }
    }
    Ensure-LauncherDefaultTemplateFiles -Workspace $workspace
    return $workspace
}

function Resolve-LauncherScopePath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Path))
}

function Get-LauncherRepoRelativePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '-' }

    try {
        $workspace = Get-LauncherFileWorkspace
        $repoRoot = [System.IO.Path]::GetFullPath($workspace.RepoRoot)
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        if ($fullPath.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $fullPath.Substring($repoRoot.Length).TrimStart('\', '/')
            if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
                return ('.\' + $relativePath.Replace('/', '\'))
            }
        }
        return $fullPath
    } catch {
        return $Path
    }
}

function Get-LauncherRecentScopesLimit {
    return 12
}

function Get-LauncherScopeStatusLabel {
    param([bool]$Exists)

    if ($Exists) { return 'OK' }
    return 'INTROUVABLE'
}

function Test-LauncherEditableManagedScopePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $resolvedPath = Resolve-LauncherScopePath -Path $Path
    $workspace = Initialize-LauncherFileWorkspace
    foreach ($editableRoot in @($workspace.Incoming, $workspace.Active)) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($editableRoot).TrimEnd('\', '/')
        if ($resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
        if ($resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-LauncherRecentScopeUpdatePath {
    param([Parameter(Mandatory)][hashtable]$RunConfig)

    foreach ($key in @('LauncherSelectedScopePath', 'ManagedScopeFile', 'ScopeFile')) {
        if ($RunConfig.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$RunConfig[$key])) {
            return (Resolve-LauncherScopePath -Path ([string]$RunConfig[$key]))
        }
    }

    return $null
}

function Get-LauncherBuiltInScopeTemplateContent {
    param([Parameter(Mandatory)][string]$TemplateKey)

    switch ($TemplateKey.ToLowerInvariant()) {
        'minimal' {
            return @'
[
  {
    "type": "Domain",
    "value": "app.example.com",
    "exclusions": []
  }
]
'@
        }
        'standard' {
            return @'
[
  {
    "type": "Domain",
    "value": "app.example.com",
    "exclusions": []
  },
  {
    "type": "Wildcard",
    "value": "https://*.example.com",
    "exclusions": ["dev", "staging"]
  },
  {
    "type": "URL",
    "value": "https://app.example.com/api/v1",
    "exclusions": []
  }
]
'@
        }
        'advanced' {
            return @'
[
  {
    "type": "Domain",
    "value": "app.example.com",
    "exclusions": []
  },
  {
    "type": "Domain",
    "value": "api.example.com",
    "exclusions": []
  },
  {
    "type": "Wildcard",
    "value": "https://*.example.com",
    "exclusions": ["dev", "qa", "sandbox", "staging"]
  },
  {
    "type": "URL",
    "value": "https://app.example.com/login",
    "exclusions": []
  },
  {
    "type": "URL",
    "value": "https://app.example.com/api/v1",
    "exclusions": []
  }
]
'@
        }
        default {
            throw "Modele de scope inconnu: $TemplateKey"
        }
    }
}

function Get-LauncherBuiltInScopeTemplateHelpContent {
    param([Parameter(Mandatory)][string]$TemplateKey)

    switch ($TemplateKey.ToLowerInvariant()) {
        'minimal' {
            return @'
# Modele minimal

Ce modele sert a demarrer avec un seul item de scope simple et exact.

Quand l'utiliser :
- pour un premier test du launcher
- pour une cible avec un seul hostname exact
- pour verifier rapidement que le workflow fonctionne

Champs :
- `type` : obligatoire. Valeurs autorisees : `URL`, `Domain`, `Wildcard`.
- `value` : obligatoire. Ici, un hostname exact comme `app.example.com`.
- `exclusions` : optionnel. Tableau de tokens a exclure.

Workflow simple :
1. Remplace `app.example.com` par le vrai hostname autorise.
2. Laisse `exclusions` vide si tu n'as aucun sous-scope a retirer.
3. Sauvegarde le fichier dans `scopes/incoming` ou `scopes/active`.
4. Relance le launcher puis choisis `Lancer avec le scope ou la session active`.
5. Lis le resume avant lancement pour verifier le scope, les logs et le dossier de sortie.
6. Plus tard, retrouve-le depuis `Scopes recents` ou `Sessions enregistrees`.
'@
        }
        'standard' {
            return @'
# Modele standard

Ce modele combine les trois formes de scope les plus utiles : `Domain`, `Wildcard` et `URL`.

Quand l'utiliser :
- pour un programme web classique
- quand tu connais un ou deux hosts exacts
- quand tu veux aussi autoriser un wildcard et quelques URL de depart utiles

Champs :
- `type` : obligatoire. Utilise `Domain` pour un host exact, `Wildcard` pour des sous-domaines, `URL` pour une URL de depart precise.
- `value` : obligatoire. Respecte le format exact :
  - `Domain` : `app.example.com`
  - `Wildcard` : `https://*.example.com` ou `*.example.com`
  - `URL` : `https://app.example.com/api/v1`
- `exclusions` : optionnel. Tableau de chaines simples comme `["dev", "staging"]`.

Workflow simple :
1. Garde uniquement les items autorises par le programme.
2. Ajuste les exclusions avec des tokens specifiques.
3. Sauvegarde le fichier.
4. Reviens au launcher puis choisis `Lancer avec le scope ou la session active`.
5. Verifie le resume avant lancement : scope, logs, sortie et options actives.
6. Le resultat sera ecrit dans le dossier de sortie indique par le launcher.
'@
        }
        'advanced' {
            return @'
# Modele avance

Ce modele sert a preparer un scope plus riche avec plusieurs hosts exacts, plusieurs URL de depart et un wildcard complete par des exclusions.

Quand l'utiliser :
- pour un programme avec plusieurs applications
- pour separer clairement web, API et points d'entree utiles
- quand tu veux un fichier plus complet avant le premier run

Champs :
- `type` : obligatoire. Toujours `URL`, `Domain` ou `Wildcard`.
- `value` : obligatoire. Doit respecter le format attendu par le parseur.
- `exclusions` : optionnel. Tableau de chaines; evite les tokens trop larges qui excluent trop de choses.

Points d'attention :
- `*.example.com` n'inclut pas automatiquement `example.com`. Ajoute un item `Domain` si besoin.
- Les commentaires JSON ne sont pas supportes de maniere fiable. Garde un JSON strict.
- Les champs supplementaires dans le JSON n'ont pas d'effet. N'ajoute pas de metadonnees dans le scope.

Workflow simple :
1. Remplace tous les exemples par les vraies valeurs autorisees.
2. Supprime les lignes inutiles plutot que de les commenter.
3. Sauvegarde le fichier.
4. Reviens au launcher puis choisis `Lancer avec le scope ou la session active`.
5. Controle le resume avant lancement, surtout les exclusions, les logs et le dossier de sortie.
6. Apres un premier run reussi, tu pourras aussi le retrouver dans `Scopes recents` ou `Sessions enregistrees`.
'@
        }
        default {
            throw "Guide de modele de scope inconnu: $TemplateKey"
        }
    }
}

function Get-LauncherScopeTemplatesReadmeContent {
    return @'
# Modeles de fichiers de scope

Ces fichiers servent de base pour creer un scope editable a la main.

Regles importantes :
- Le moteur attend un tableau JSON strict.
- Chaque item doit contenir `type` et `value`.
- `exclusions` doit etre un tableau de chaines.
- Les commentaires JSON ne sont pas supportes de maniere fiable : utilise les fichiers `.md` pour l'aide.

Modeles disponibles :
- `01-minimal-scope.json` : un seul item simple pour demarrer vite.
- `02-standard-scope.json` : un exemple equilibre avec `Domain`, `Wildcard` et `URL`.
- `03-advanced-scope.json` : un squelette plus riche pour les programmes avec plusieurs surfaces.

Guides associes :
- `01-minimal-scope.help.md`
- `02-standard-scope.help.md`
- `03-advanced-scope.help.md`

Workflow conseille :
1. Lance `./Launch-ScopeForge.ps1`.
2. Choisis `Creer un nouveau fichier de scope a remplir`.
3. Selectionne le modele minimal, standard ou avance.
4. Ouvre le fichier cree dans ton editeur.
5. Remplis le fichier puis sauvegarde-le.
6. Reviens au launcher puis choisis `Lancer avec le scope ou la session active`.
7. Lis le resume avant lancement : scope, session, logs et sortie.
8. Apres un premier run reussi, tu pourras aussi le retrouver dans `Scopes recents` ou `Sessions enregistrees`.
'@
}

function Get-LauncherBuiltInScopeTemplates {
    return @(
        [pscustomobject]@{
            Key                 = 'minimal'
            SortOrder           = 1
            DisplayName         = 'Modele minimal'
            MenuLabel           = 'Creer un modele minimal'
            Description         = 'Un seul item exact pour demarrer tres vite.'
            FileName            = '01-minimal-scope.json'
            HelpFileName        = '01-minimal-scope.help.md'
            SuggestedFilePrefix = 'scope-minimal'
        },
        [pscustomobject]@{
            Key                 = 'standard'
            SortOrder           = 2
            DisplayName         = 'Modele standard'
            MenuLabel           = 'Creer un modele standard'
            Description         = 'Le bon choix pour la plupart des programmes web.'
            FileName            = '02-standard-scope.json'
            HelpFileName        = '02-standard-scope.help.md'
            SuggestedFilePrefix = 'scope-standard'
        },
        [pscustomobject]@{
            Key                 = 'advanced'
            SortOrder           = 3
            DisplayName         = 'Modele avance'
            MenuLabel           = 'Creer un modele avance'
            Description         = 'Plusieurs items pour preparer un scope plus complet.'
            FileName            = '03-advanced-scope.json'
            HelpFileName        = '03-advanced-scope.help.md'
            SuggestedFilePrefix = 'scope-advanced'
        }
    )
}

function Ensure-LauncherDefaultTemplateFiles {
    param([AllowNull()][object]$Workspace = $null)

    $targetWorkspace = if ($Workspace) { $Workspace } else { Get-LauncherFileWorkspace }

    # Les modeles integres sont ecrits localement si besoin pour que le workflow
    # reste autonome, y compris quand seuls les scripts principaux sont presents.
    foreach ($template in (Get-LauncherBuiltInScopeTemplates)) {
        $templatePath = Join-Path $targetWorkspace.Templates $template.FileName
        if (-not (Test-Path -LiteralPath $templatePath)) {
            Set-Content -LiteralPath $templatePath -Value (Get-LauncherBuiltInScopeTemplateContent -TemplateKey $template.Key) -Encoding utf8
        }

        $helpPath = Join-Path $targetWorkspace.Templates $template.HelpFileName
        if (-not (Test-Path -LiteralPath $helpPath)) {
            Set-Content -LiteralPath $helpPath -Value (Get-LauncherBuiltInScopeTemplateHelpContent -TemplateKey $template.Key) -Encoding utf8
        }
    }

    if (-not (Test-Path -LiteralPath $targetWorkspace.TemplatesGuide)) {
        Set-Content -LiteralPath $targetWorkspace.TemplatesGuide -Value (Get-LauncherScopeTemplatesReadmeContent) -Encoding utf8
    }
}

function Get-LauncherMinimalScopeStarterContent {
    return (Get-LauncherBuiltInScopeTemplateContent -TemplateKey 'minimal')
}

function Get-LauncherDefaultScopeTemplateContent {
    return (Get-LauncherBuiltInScopeTemplateContent -TemplateKey 'standard')
}

function Get-LauncherScopeTemplateFiles {
    $workspace = Initialize-LauncherFileWorkspace
    $templates = [System.Collections.Generic.List[object]]::new()
    $builtInByFileName = @{}
    foreach ($template in (Get-LauncherBuiltInScopeTemplates)) {
        $builtInByFileName[$template.FileName.ToLowerInvariant()] = $template
    }

    foreach ($file in (Get-ChildItem -LiteralPath $workspace.Templates -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $fileKey = $file.Name.ToLowerInvariant()
        $builtInTemplate = if ($builtInByFileName.ContainsKey($fileKey)) { $builtInByFileName[$fileKey] } else { $null }
        $templates.Add([pscustomobject]@{
                Key                 = $(if ($builtInTemplate) { $builtInTemplate.Key } else { $file.BaseName })
                DisplayName         = $(if ($builtInTemplate) { $builtInTemplate.DisplayName } else { $file.BaseName })
                MenuLabel           = $(if ($builtInTemplate) { $builtInTemplate.MenuLabel } else { "Utiliser le modele $($file.BaseName)" })
                Description         = $(if ($builtInTemplate) { $builtInTemplate.Description } else { 'Modele personnalise detecte dans scopes/templates.' })
                Source              = 'scopes/templates'
                Path                = $file.FullName
                HelpPath            = $(if ($builtInTemplate) { Join-Path $workspace.Templates $builtInTemplate.HelpFileName } else { $workspace.TemplatesGuide })
                SuggestedFilePrefix = $(if ($builtInTemplate) { $builtInTemplate.SuggestedFilePrefix } else { 'scope-personnalise' })
                SortOrder           = $(if ($builtInTemplate) { $builtInTemplate.SortOrder } else { 100 })
            }) | Out-Null
    }

    return @($templates | Sort-Object SortOrder, DisplayName)
}

function New-LauncherRecentScopeRecord {
    param(
        [AllowNull()][string]$DisplayName,
        [AllowNull()][string]$ScopePath,
        [AllowNull()][string]$LastOutputDir,
        [AllowNull()][string]$LastUsedUtc,
        [AllowNull()][string]$Note
    )

    if ([string]::IsNullOrWhiteSpace($ScopePath)) { return $null }

    $resolvedScopePath = Resolve-LauncherScopePath -Path $ScopePath
    $exists = Test-Path -LiteralPath $resolvedScopePath
    $displayNameValue = if ([string]::IsNullOrWhiteSpace($DisplayName)) { [System.IO.Path]::GetFileNameWithoutExtension($resolvedScopePath) } else { $DisplayName }
    $workspace = Initialize-LauncherFileWorkspace
    $archivedRoot = [System.IO.Path]::GetFullPath($workspace.Archived).TrimEnd('\', '/')
    $isArchived = $resolvedScopePath.StartsWith(($archivedRoot + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase) -or $resolvedScopePath.Equals($archivedRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $noteValue = if ([string]::IsNullOrWhiteSpace($Note)) {
        if ($isArchived) { 'ARCHIVE' } else { Get-LauncherScopeStatusLabel -Exists $exists }
    } else {
        $Note
    }

    return [pscustomobject]@{
        display_name    = $displayNameValue
        scope_path      = $resolvedScopePath
        last_output_dir = if ([string]::IsNullOrWhiteSpace($LastOutputDir)) { $null } else { $LastOutputDir }
        last_used_utc   = if ([string]::IsNullOrWhiteSpace($LastUsedUtc)) { [DateTimeOffset]::UtcNow.ToString('o') } else { $LastUsedUtc }
        exists          = [bool]$exists
        note            = $noteValue
    }
}

function Read-LauncherRecentScopes {
    $workspace = Initialize-LauncherFileWorkspace
    if (-not (Test-Path -LiteralPath $workspace.RecentScopesPath)) { return @() }

    try {
        $rawContent = Get-Content -LiteralPath $workspace.RecentScopesPath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($rawContent)) { return @() }
        $parsed = ConvertFrom-Json -InputObject $rawContent -Depth 50
    } catch {
        Write-Host ("Impossible de lire state/recent-scopes.json: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return @()
    }

    $items = if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string] -and -not $parsed.PSObject.Properties['items']) {
        @($parsed)
    } elseif ($parsed.PSObject.Properties['items']) {
        @($parsed.items)
    } else {
        @()
    }

    $records = [System.Collections.Generic.List[object]]::new()
    # Les scopes recents restent visibles meme s'ils ont ete deplaces, afin de
    # garder le dernier output connu et d'expliquer le statut INTROUVABLE.
    foreach ($item in $items) {
        $record = New-LauncherRecentScopeRecord `
            -DisplayName ([string](Get-LauncherDocumentProperty -InputObject $item -Name 'display_name' -Default '')) `
            -ScopePath ([string](Get-LauncherDocumentProperty -InputObject $item -Name 'scope_path' -Default '')) `
            -LastOutputDir ([string](Get-LauncherDocumentProperty -InputObject $item -Name 'last_output_dir' -Default '')) `
            -LastUsedUtc ([string](Get-LauncherDocumentProperty -InputObject $item -Name 'last_used_utc' -Default '')) `
            -Note ([string](Get-LauncherDocumentProperty -InputObject $item -Name 'note' -Default ''))
        if ($record) {
            $record.note = Get-LauncherScopeStatusLabel -Exists $record.exists
            $records.Add($record) | Out-Null
        }
    }

    return @(
        $records |
        Sort-Object -Property @{
            Expression = {
                try { [DateTimeOffset]$_.last_used_utc } catch { [DateTimeOffset]'1970-01-01T00:00:00Z' }
            }
            Descending = $true
        }
    )
}

function Write-LauncherRecentScopes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)

    $workspace = Initialize-LauncherFileWorkspace
    $payload = [ordered]@{
        version = 1
        items   = @(
            $Items |
            Select-Object -First (Get-LauncherRecentScopesLimit) |
            ForEach-Object {
                $record = New-LauncherRecentScopeRecord `
                    -DisplayName ([string](Get-LauncherDocumentProperty -InputObject $_ -Name 'display_name' -Default '')) `
                    -ScopePath ([string](Get-LauncherDocumentProperty -InputObject $_ -Name 'scope_path' -Default '')) `
                    -LastOutputDir ([string](Get-LauncherDocumentProperty -InputObject $_ -Name 'last_output_dir' -Default '')) `
                    -LastUsedUtc ([string](Get-LauncherDocumentProperty -InputObject $_ -Name 'last_used_utc' -Default '')) `
                    -Note ([string](Get-LauncherDocumentProperty -InputObject $_ -Name 'note' -Default ''))
                if ($record) {
                    [ordered]@{
                        display_name    = $record.display_name
                        scope_path      = $record.scope_path
                        last_output_dir = $record.last_output_dir
                        last_used_utc   = $record.last_used_utc
                        exists          = $record.exists
                        note            = $record.note
                    }
                }
            }
        )
    }

    Set-Content -LiteralPath $workspace.RecentScopesPath -Value ($payload | ConvertTo-Json -Depth 20) -Encoding utf8
    return $workspace.RecentScopesPath
}

function Update-LauncherRecentScopes {
    param(
        [Parameter(Mandatory)][string]$ScopePath,
        [AllowNull()][string]$LastOutputDir,
        [AllowNull()][string]$DisplayName,
        [AllowNull()][string]$Note
    )

    $currentItems = @(Read-LauncherRecentScopes)
    $newRecord = New-LauncherRecentScopeRecord -DisplayName $DisplayName -ScopePath $ScopePath -LastOutputDir $LastOutputDir -LastUsedUtc ([DateTimeOffset]::UtcNow.ToString('o')) -Note $Note
    if (-not $newRecord) { return $null }

    $normalizedScopePath = $newRecord.scope_path.ToLowerInvariant()
    $updatedItems = [System.Collections.Generic.List[object]]::new()
    $updatedItems.Add($newRecord) | Out-Null

    foreach ($item in $currentItems) {
        $itemPath = [string](Get-LauncherDocumentProperty -InputObject $item -Name 'scope_path' -Default '')
        if ([string]::IsNullOrWhiteSpace($itemPath)) { continue }
        if ($itemPath.ToLowerInvariant() -eq $normalizedScopePath) { continue }
        $updatedItems.Add($item) | Out-Null
    }

    $null = Write-LauncherRecentScopes -Items @($updatedItems)
    return $newRecord
}

function Get-LauncherSessionMetadataPath {
    param([Parameter(Mandatory)][string]$SessionRoot)

    return (Join-Path $SessionRoot 'session-metadata.json')
}

function New-LauncherSessionRecord {
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [AllowNull()][string]$DisplayName,
        [AllowNull()][string]$LoggingMode,
        [AllowNull()][string]$LastOutputDir,
        [AllowNull()][string]$LastLogDir,
        [AllowNull()][string]$LastUsedUtc,
        [AllowNull()][string]$Note,
        [AllowNull()][string]$ScopePath,
        [AllowNull()][string]$SettingsPath,
        [AllowNull()][string]$ReadmePath,
        [AllowNull()][string]$LogsRoot
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($SessionRoot)
    $sessionName = [System.IO.Path]::GetFileName($resolvedRoot.TrimEnd('\', '/'))
    $scopePath = if ([string]::IsNullOrWhiteSpace($ScopePath)) { Join-Path $resolvedRoot '01-scope.json' } else { [System.IO.Path]::GetFullPath($ScopePath) }
    $settingsPath = if ([string]::IsNullOrWhiteSpace($SettingsPath)) { Join-Path $resolvedRoot '02-run-settings.json' } else { [System.IO.Path]::GetFullPath($SettingsPath) }
    $readmePath = if ([string]::IsNullOrWhiteSpace($ReadmePath)) { Join-Path $resolvedRoot '00-START-HERE.txt' } else { [System.IO.Path]::GetFullPath($ReadmePath) }
    $logsRoot = if ([string]::IsNullOrWhiteSpace($LogsRoot)) { Join-Path $resolvedRoot 'logs' } else { [System.IO.Path]::GetFullPath($LogsRoot) }
    $exists = Test-Path -LiteralPath $resolvedRoot

    return [pscustomobject]@{
        session_id      = $sessionName
        display_name    = $(if ([string]::IsNullOrWhiteSpace($DisplayName)) { $sessionName } else { $DisplayName })
        session_root    = $resolvedRoot
        scope_path      = $scopePath
        settings_path   = $settingsPath
        readme_path     = $readmePath
        logs_root       = $logsRoot
        last_output_dir = $LastOutputDir
        last_log_dir    = $LastLogDir
        logging_mode    = $(if ([string]::IsNullOrWhiteSpace($LoggingMode)) { 'normal' } else { $LoggingMode })
        last_used_utc   = $(if ($LastUsedUtc) { $LastUsedUtc } else { [DateTimeOffset]::UtcNow.ToString('o') })
        exists          = [bool]$exists
        note            = $(if ([string]::IsNullOrWhiteSpace($Note)) { $(if ($exists) { 'SESSION' } else { 'INTROUVABLE' }) } else { $Note })
    }
}

function Write-LauncherSessionMetadata {
    param([Parameter(Mandatory)][pscustomobject]$SessionRecord)

    if (-not (Test-Path -LiteralPath $SessionRecord.session_root)) {
        $null = New-Item -ItemType Directory -Path $SessionRecord.session_root -Force
    }
    if (-not (Test-Path -LiteralPath $SessionRecord.logs_root)) {
        $null = New-Item -ItemType Directory -Path $SessionRecord.logs_root -Force
    }

    $payload = [ordered]@{
        version         = 1
        session_id      = $SessionRecord.session_id
        display_name    = $SessionRecord.display_name
        session_root    = $SessionRecord.session_root
        scope_path      = $SessionRecord.scope_path
        settings_path   = $SessionRecord.settings_path
        readme_path     = $SessionRecord.readme_path
        logs_root       = $SessionRecord.logs_root
        last_output_dir = $SessionRecord.last_output_dir
        last_log_dir    = $SessionRecord.last_log_dir
        logging_mode    = $SessionRecord.logging_mode
        last_used_utc   = $SessionRecord.last_used_utc
        note            = $SessionRecord.note
    }

    $metadataPath = Get-LauncherSessionMetadataPath -SessionRoot $SessionRecord.session_root
    Set-Content -LiteralPath $metadataPath -Value ($payload | ConvertTo-Json -Depth 20) -Encoding utf8
    return $metadataPath
}

function Read-LauncherSessionMetadata {
    param([Parameter(Mandatory)][string]$SessionRoot)

    $metadataPath = Get-LauncherSessionMetadataPath -SessionRoot $SessionRoot
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        return (New-LauncherSessionRecord -SessionRoot $SessionRoot)
    }

    try {
        $parsed = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    } catch {
        return (New-LauncherSessionRecord -SessionRoot $SessionRoot)
    }

    return (New-LauncherSessionRecord `
        -SessionRoot $SessionRoot `
        -DisplayName ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'display_name' -Default '')) `
        -LoggingMode ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'logging_mode' -Default 'normal')) `
        -LastOutputDir ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'last_output_dir' -Default '')) `
        -LastLogDir ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'last_log_dir' -Default '')) `
        -LastUsedUtc ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'last_used_utc' -Default '')) `
        -Note ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'note' -Default '')) `
        -ScopePath ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'scope_path' -Default '')) `
        -SettingsPath ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'settings_path' -Default '')) `
        -ReadmePath ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'readme_path' -Default '')) `
        -LogsRoot ([string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'logs_root' -Default '')))
}

function Update-LauncherSessionMetadata {
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [hashtable]$Values = @{}
    )

    $current = Read-LauncherSessionMetadata -SessionRoot $SessionRoot
    $record = New-LauncherSessionRecord `
        -SessionRoot $SessionRoot `
        -DisplayName $(if ($Values.ContainsKey('display_name')) { [string]$Values['display_name'] } else { $current.display_name }) `
        -LoggingMode $(if ($Values.ContainsKey('logging_mode')) { [string]$Values['logging_mode'] } else { $current.logging_mode }) `
        -LastOutputDir $(if ($Values.ContainsKey('last_output_dir')) { [string]$Values['last_output_dir'] } else { $current.last_output_dir }) `
        -LastLogDir $(if ($Values.ContainsKey('last_log_dir')) { [string]$Values['last_log_dir'] } else { $current.last_log_dir }) `
        -LastUsedUtc $(if ($Values.ContainsKey('last_used_utc')) { [string]$Values['last_used_utc'] } else { [DateTimeOffset]::UtcNow.ToString('o') }) `
        -Note $(if ($Values.ContainsKey('note')) { [string]$Values['note'] } else { $current.note }) `
        -ScopePath $(if ($Values.ContainsKey('scope_path')) { [string]$Values['scope_path'] } else { $current.scope_path }) `
        -SettingsPath $(if ($Values.ContainsKey('settings_path')) { [string]$Values['settings_path'] } else { $current.settings_path }) `
        -ReadmePath $(if ($Values.ContainsKey('readme_path')) { [string]$Values['readme_path'] } else { $current.readme_path }) `
        -LogsRoot $(if ($Values.ContainsKey('logs_root')) { [string]$Values['logs_root'] } else { $current.logs_root })

    $null = Write-LauncherSessionMetadata -SessionRecord $record
    return $record
}

function Get-LauncherSavedSessions {
    $launcherRoot = Get-LauncherDocumentsRoot
    $sessionRoots = @(Get-ChildItem -LiteralPath $launcherRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'session-*' })
    $sessions = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in $sessionRoots) {
        try {
            $sessions.Add((Read-LauncherSessionMetadata -SessionRoot $directory.FullName)) | Out-Null
        } catch {
        }
    }

    return @(
        $sessions |
        Sort-Object -Property @{
            Expression = {
                try { [DateTimeOffset]$_.last_used_utc } catch { [DateTimeOffset]'1970-01-01T00:00:00Z' }
            }
            Descending = $true
        }
    )
}

function Get-LauncherSavedSessionById {
    param([AllowNull()][string]$SessionId)

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }
    return (Get-LauncherSavedSessions | Where-Object { $_.session_id -eq $SessionId } | Select-Object -First 1)
}

function Get-LauncherSelectedSession {
    $state = Read-LauncherUiState
    $selected = Get-LauncherSavedSessionById -SessionId $state.last_selected_session_id
    if ($selected) { return $selected }
    return (Get-LauncherSavedSessions | Select-Object -First 1)
}

function Set-LauncherSelectedSession {
    param([AllowNull()][string]$SessionId)

    $null = Update-LauncherUiState -Values @{ last_selected_session_id = $(if ($SessionId) { $SessionId } else { '' }) }
}

function Get-LauncherSessionLogRunRoot {
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    $logsRoot = Join-Path $SessionRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsRoot)) {
        $null = New-Item -ItemType Directory -Path $logsRoot -Force
    }
    return (Join-Path $logsRoot $RunId)
}

function Copy-LauncherSavedSession {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$NewDisplayName
    )

    $newRoot = Get-LauncherUniqueSessionDirectory -Suffix '-copy'
    Copy-Item -LiteralPath $Session.session_root -Destination $newRoot -Recurse -Force
    $oldRoot = [System.IO.Path]::GetFullPath($Session.session_root)
    $resolvedNewRoot = [System.IO.Path]::GetFullPath($newRoot)
    $remapPath = {
        param([AllowNull()][string]$PathValue)

        if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
        $fullPath = [System.IO.Path]::GetFullPath($PathValue)
        if ($fullPath.StartsWith($oldRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $suffix = $fullPath.Substring($oldRoot.Length).TrimStart('\', '/')
            if ([string]::IsNullOrWhiteSpace($suffix)) { return $resolvedNewRoot }
            return (Join-Path $resolvedNewRoot $suffix)
        }
        return $fullPath
    }
    $record = Update-LauncherSessionMetadata -SessionRoot $newRoot -Values @{
        display_name  = $NewDisplayName
        last_used_utc = [DateTimeOffset]::UtcNow.ToString('o')
        note          = 'SESSION'
        scope_path    = (& $remapPath $Session.scope_path)
        settings_path = (& $remapPath $Session.settings_path)
        readme_path   = (& $remapPath $Session.readme_path)
        logs_root     = (& $remapPath $Session.logs_root)
        last_log_dir  = (& $remapPath $Session.last_log_dir)
    }
    Set-LauncherSelectedSession -SessionId $record.session_id
    return $record
}

function Remove-LauncherSavedSession {
    param([Parameter(Mandatory)][pscustomobject]$Session)

    if (-not (Test-Path -LiteralPath $Session.session_root)) { return $false }
    Remove-Item -LiteralPath $Session.session_root -Recurse -Force
    $state = Read-LauncherUiState
    if ($state.last_selected_session_id -eq $Session.session_id) {
        Set-LauncherSelectedSession -SessionId ''
    }
    return $true
}

function Get-LauncherLoggingModeDefinitions {
    return @(
        [pscustomobject]@{
            Key         = 'disabled'
            DisplayName = 'Logs desactives'
            Description = 'Ne garde que les metadonnees de session. Pas de journal detaille du launcher.'
        },
        [pscustomobject]@{
            Key         = 'normal'
            DisplayName = 'Logs normaux'
            Description = 'Journalise les etapes principales, les chemins utiles et les erreurs importantes.'
        },
        [pscustomobject]@{
            Key         = 'verbose'
            DisplayName = 'Logs verbeux'
            Description = 'Ajoute davantage de decisions du launcher et un transcript console si possible.'
        },
        [pscustomobject]@{
            Key         = 'debug'
            DisplayName = 'Logs debug'
            Description = 'Capture un maximum de details utiles pour depanner la validation et l invocation.'
        }
    )
}

function Get-LauncherLoggingModeDefinition {
    param([AllowNull()][string]$Key)

    $definitions = @(Get-LauncherLoggingModeDefinitions)
    $selected = $definitions | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if ($selected) { return $selected }
    return ($definitions | Where-Object { $_.Key -eq 'normal' } | Select-Object -First 1)
}

function Get-LauncherDefaultLoggingMode {
    $state = Read-LauncherUiState
    return (Get-LauncherLoggingModeDefinition -Key $state.logging_mode).Key
}

function Select-LauncherLoggingMode {
    param([AllowNull()][string]$DefaultMode = $null)

    $initialMode = if ($DefaultMode) { $DefaultMode } else { Get-LauncherDefaultLoggingMode }
    $definitions = @(Get-LauncherLoggingModeDefinitions)
    $rows = @()
    for ($index = 0; $index -lt $definitions.Count; $index++) {
        $definition = $definitions[$index]
        $rows += [pscustomobject]@{
            Index       = ($index + 1)
            Mode        = $definition.DisplayName
            Cle         = $definition.Key
            Description = $definition.Description
        }
    }

    Write-LauncherSection -Title 'Logs'
    Write-Host 'Choisis le niveau de journalisation avant le lancement.' -ForegroundColor Cyan
    $defaultRow = $rows | Where-Object { $_.Cle -eq $initialMode } | Select-Object -First 1
    $selected = Select-LauncherIndexedItem -Title 'Choisir un niveau de logs' -Rows $rows -Columns @('Index', 'Mode', 'Description') -Widths @{ Index = 6; Mode = 18; Description = 72 } -Prompt 'Mode de logs (0=annuler)' -DefaultChoice $(if ($defaultRow) { [string]$defaultRow.Index } else { '2' })
    if (-not $selected) { return (Get-LauncherLoggingModeDefinition -Key $initialMode) }
    return (Get-LauncherLoggingModeDefinition -Key $selected.Cle)
}

function Get-LauncherSessionRootForRunConfig {
    param([Parameter(Mandatory)][hashtable]$RunConfig)

    if ($RunConfig.ContainsKey('LauncherSessionRoot') -and -not [string]::IsNullOrWhiteSpace([string]$RunConfig.LauncherSessionRoot)) {
        return [System.IO.Path]::GetFullPath([string]$RunConfig.LauncherSessionRoot)
    }

    $sessionRoot = Get-LauncherUniqueSessionDirectory -Suffix '-adhoc'
    if (-not (Test-Path -LiteralPath $sessionRoot)) {
        $null = New-Item -ItemType Directory -Path $sessionRoot -Force
    }
    $RunConfig['LauncherSessionRoot'] = $sessionRoot
    return $sessionRoot
}

function Write-LauncherDiagnosticLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    if (-not (Get-Variable -Name LauncherLogContext -Scope Script -ErrorAction SilentlyContinue)) { return }
    $context = $script:LauncherLogContext
    if (-not $context -or [string]::IsNullOrWhiteSpace($context.LogPath)) { return }
    if ($context.Mode -eq 'disabled') { return }
    if ($Level -eq 'DEBUG' -and $context.Mode -notin @('verbose', 'debug')) { return }

    $line = '{0} [{1}] {2}' -f ([DateTimeOffset]::UtcNow.ToString('o')), $Level, $Message
    Add-Content -LiteralPath $context.LogPath -Value $line -Encoding utf8
}

function Start-LauncherLoggingContext {
    param([Parameter(Mandatory)][hashtable]$RunConfig)

    $sessionRoot = Get-LauncherSessionRootForRunConfig -RunConfig $RunConfig
    $runId = if ($RunConfig.ContainsKey('RunId') -and $RunConfig.RunId) { [string]$RunConfig.RunId } else { [Guid]::NewGuid().ToString('N') }
    $logMode = if ($RunConfig.ContainsKey('LauncherLogMode')) { [string]$RunConfig.LauncherLogMode } else { Get-LauncherDefaultLoggingMode }
    $logRoot = Get-LauncherSessionLogRunRoot -SessionRoot $sessionRoot -RunId $runId
    if (-not (Test-Path -LiteralPath $logRoot)) {
        $null = New-Item -ItemType Directory -Path $logRoot -Force
    }

    $context = [pscustomobject]@{
        Mode            = $logMode
        SessionRoot     = $sessionRoot
        LogRoot         = $logRoot
        LogPath         = (Join-Path $logRoot 'launcher.log')
        TranscriptPath  = (Join-Path $logRoot 'launcher-transcript.log')
        MetadataPath    = (Join-Path $logRoot 'run-session.json')
        TranscriptOpen  = $false
    }

    $script:LauncherLogContext = $context
    $RunConfig['LauncherSessionRoot'] = $sessionRoot
    $RunConfig['LauncherLogRoot'] = $logRoot
    $RunConfig['LauncherLogMode'] = $logMode

    $null = Update-LauncherSessionMetadata -SessionRoot $sessionRoot -Values @{
        logging_mode  = $logMode
        scope_path    = $(if ($RunConfig.ContainsKey('ScopeFile')) { [string]$RunConfig.ScopeFile } else { $null })
        logs_root     = (Join-Path $sessionRoot 'logs')
        last_log_dir  = $logRoot
        last_used_utc = [DateTimeOffset]::UtcNow.ToString('o')
        note          = 'SESSION'
    }
    $null = Update-LauncherUiState -Values @{ logging_mode = $logMode }

    if ($logMode -in @('verbose', 'debug')) {
        try {
            Start-Transcript -Path $context.TranscriptPath -Force | Out-Null
            $context.TranscriptOpen = $true
        } catch {
        }
    }

    $metadata = [ordered]@{
        run_id        = $runId
        session_root  = $sessionRoot
        log_root      = $logRoot
        logging_mode  = $logMode
        scope_file    = $(if ($RunConfig.ContainsKey('ScopeFile')) { $RunConfig.ScopeFile } else { $null })
        output_dir    = $(if ($RunConfig.ContainsKey('OutputDir')) { $RunConfig.OutputDir } else { $null })
        started_utc   = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Set-Content -LiteralPath $context.MetadataPath -Value ($metadata | ConvertTo-Json -Depth 20) -Encoding utf8
    Write-LauncherDiagnosticLog -Message ("Initialisation des logs launcher dans {0}" -f $logRoot)
    return $context
}

function Stop-LauncherLoggingContext {
    if (-not (Get-Variable -Name LauncherLogContext -Scope Script -ErrorAction SilentlyContinue)) { return }
    $context = $script:LauncherLogContext
    if ($context -and $context.TranscriptOpen) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    $script:LauncherLogContext = $null
}

function Get-LauncherRecentScopeByPath {
    param(
        [Parameter(Mandatory)][string]$ScopePath,
        [AllowEmptyCollection()][object[]]$RecentScopes = @()
    )

    if (-not $RecentScopes -or $RecentScopes.Count -eq 0) {
        $RecentScopes = @(Read-LauncherRecentScopes)
    }

    $normalizedPath = (Resolve-LauncherScopePath -Path $ScopePath).ToLowerInvariant()
    return ($RecentScopes | Where-Object {
            $candidatePath = [string](Get-LauncherDocumentProperty -InputObject $_ -Name 'scope_path' -Default '')
            -not [string]::IsNullOrWhiteSpace($candidatePath) -and $candidatePath.ToLowerInvariant() -eq $normalizedPath
        } | Select-Object -First 1)
}

function Get-LauncherScopeEntryFromPath {
    param(
        [Parameter(Mandatory)][string]$ScopePath,
        [AllowEmptyCollection()][object[]]$RecentScopes = @()
    )

    $resolvedScopePath = Resolve-LauncherScopePath -Path $ScopePath
    $recentItem = Get-LauncherRecentScopeByPath -ScopePath $resolvedScopePath -RecentScopes $RecentScopes
    $exists = Test-Path -LiteralPath $resolvedScopePath

    return [pscustomobject]@{
        display_name       = $(if ($recentItem) { $recentItem.display_name } else { [System.IO.Path]::GetFileNameWithoutExtension($resolvedScopePath) })
        scope_path         = $resolvedScopePath
        scope_display_path = Get-LauncherRepoRelativePath -Path $resolvedScopePath
        last_output_dir    = $(if ($recentItem) { $recentItem.last_output_dir } else { $null })
        last_used_utc      = $(if ($recentItem) { $recentItem.last_used_utc } else { $null })
        exists             = [bool]$exists
        note               = $(if ($recentItem -and $recentItem.note) { $recentItem.note } else { Get-LauncherScopeStatusLabel -Exists $exists })
    }
}

function Get-LauncherManagedScopeFiles {
    $workspace = Initialize-LauncherFileWorkspace
    $recentScopes = @(Read-LauncherRecentScopes)
    $rows = [System.Collections.Generic.List[object]]::new()
    $folders = @(
        [pscustomobject]@{ Label = 'actif'; Path = $workspace.Active },
        [pscustomobject]@{ Label = 'nouveau'; Path = $workspace.Incoming }
    )

    foreach ($folder in $folders) {
        foreach ($file in (Get-ChildItem -LiteralPath $folder.Path -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $recentItem = Get-LauncherRecentScopeByPath -ScopePath $file.FullName -RecentScopes $recentScopes
            $rows.Add([pscustomobject]@{
                    display_name       = $file.BaseName
                    scope_path         = $file.FullName
                    scope_display_path = Get-LauncherRepoRelativePath -Path $file.FullName
                    folder_label       = $folder.Label
                    last_output_dir    = $(if ($recentItem) { $recentItem.last_output_dir } else { $null })
                    last_used_utc      = $(if ($recentItem) { $recentItem.last_used_utc } else { $null })
                    exists             = $true
                    note               = 'OK'
                }) | Out-Null
        }
    }

    return @($rows)
}

function Show-LauncherScopeFolders {
    $workspace = Initialize-LauncherFileWorkspace

    Write-LauncherSection -Title 'Emplacements des scopes'
    Write-LauncherKeyValue -Key 'Racine du repo' -Value $workspace.RepoRoot
    Write-LauncherKeyValue -Key 'Nouveaux scopes' -Value $workspace.Incoming
    Write-LauncherKeyValue -Key 'Scopes actifs' -Value $workspace.Active
    Write-LauncherKeyValue -Key 'Scopes archives' -Value $workspace.Archived
    Write-LauncherKeyValue -Key 'Dossier modeles' -Value $workspace.Templates
    Write-LauncherKeyValue -Key 'Guide des modeles' -Value $workspace.TemplatesGuide
    Write-LauncherKeyValue -Key 'Etat launcher' -Value $workspace.StateRoot
    Write-LauncherKeyValue -Key 'Index recent' -Value $workspace.RecentScopesPath
    Write-LauncherKeyValue -Key 'Exemple local' -Value (Join-Path $workspace.RepoRoot 'examples\scope.json')
    Write-LauncherKeyValue -Key 'Output par defaut' -Value (Get-LauncherDefaultOutputDir)
    Write-Host '  Prochaine etape : ouvre un modele dans scopes/templates, ou choisis un fichier deja pret dans scopes/active ou scopes/incoming.' -ForegroundColor DarkGray
}

function Show-LauncherRecentScopes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RecentScopes)

    Write-LauncherSection -Title 'Scopes recents'
    if (-not $RecentScopes -or $RecentScopes.Count -eq 0) {
        Write-Host 'Aucun scope recent enregistre pour le moment.' -ForegroundColor Yellow
        return
    }

    $rows = @()
    for ($index = 0; $index -lt $RecentScopes.Count; $index++) {
        $item = $RecentScopes[$index]
        $rows += [pscustomobject]@{
            Index          = ($index + 1)
            Statut         = $item.note
            Fichier        = $item.display_name
            Scope          = (Get-LauncherRepoRelativePath -Path $item.scope_path)
            DerniereUtilisation = $(if ($item.last_used_utc) { ([DateTimeOffset]$item.last_used_utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })
            DossierSortie  = $(if ($item.last_output_dir) { $item.last_output_dir } else { '-' })
        }
    }

    Write-LauncherTable -Rows $rows -Columns @('Index', 'Statut', 'Fichier', 'Scope', 'DerniereUtilisation', 'DossierSortie') -Widths @{ Index = 6; Statut = 12; Fichier = 18; Scope = 34; DerniereUtilisation = 20; DossierSortie = 34 }
}

function Show-LauncherSavedSessions {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions)

    Write-LauncherSection -Title 'Sessions enregistrees'
    if (-not $Sessions -or $Sessions.Count -eq 0) {
        Write-Host 'Aucune session enregistree pour le moment.' -ForegroundColor Yellow
        return
    }

    $rows = @()
    for ($index = 0; $index -lt $Sessions.Count; $index++) {
        $session = $Sessions[$index]
        $rows += [pscustomobject]@{
            Index         = ($index + 1)
            Statut        = $(if ($session.exists) { $(if ($session.note) { $session.note } else { 'OK' }) } else { 'INTROUVABLE' })
            Session       = $session.display_name
            Utilisation   = $(if ($session.last_used_utc) { ([DateTimeOffset]$session.last_used_utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })
            LogMode       = $session.logging_mode
            DossierSortie = $(if ($session.last_output_dir) { $session.last_output_dir } else { '-' })
            DossierLogs   = $(if ($session.last_log_dir) { $session.last_log_dir } else { $session.logs_root })
            SessionRoot   = (Get-LauncherRepoRelativePath -Path $session.session_root)
        }
    }

    Write-LauncherTable -Rows $rows -Columns @('Index', 'Statut', 'Session', 'Utilisation', 'LogMode', 'DossierSortie', 'DossierLogs', 'SessionRoot') -Widths @{ Index = 6; Statut = 12; Session = 18; Utilisation = 20; LogMode = 12; DossierSortie = 24; DossierLogs = 24; SessionRoot = 28 }
}

function Select-LauncherSavedSession {
    $sessions = @(Get-LauncherSavedSessions)
    if ($sessions.Count -eq 0) {
        Show-LauncherSavedSessions -Sessions $sessions
        return $null
    }

    $rows = @()
    for ($index = 0; $index -lt $sessions.Count; $index++) {
        $session = $sessions[$index]
        $rows += [pscustomobject]@{
            Index         = ($index + 1)
            Statut        = $(if ($session.exists) { $(if ($session.note) { $session.note } else { 'OK' }) } else { 'INTROUVABLE' })
            Session       = $session.display_name
            Utilisation   = $(if ($session.last_used_utc) { ([DateTimeOffset]$session.last_used_utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })
            LogMode       = $session.logging_mode
            DossierSortie = $(if ($session.last_output_dir) { $session.last_output_dir } else { '-' })
            DossierLogs   = $(if ($session.last_log_dir) { $session.last_log_dir } else { $session.logs_root })
            SessionRoot   = (Get-LauncherRepoRelativePath -Path $session.session_root)
        }
    }

    $defaultChoice = '1'
    $currentSelection = Get-LauncherSelectedSession
    if ($currentSelection) {
        $defaultIndex = 0
        for ($index = 0; $index -lt $sessions.Count; $index++) {
            if ($sessions[$index].session_id -eq $currentSelection.session_id) {
                $defaultIndex = $index
                break
            }
        }
        $defaultChoice = [string]($defaultIndex + 1)
    }

    $selected = Select-LauncherIndexedItem -Title 'Choisir une session enregistree' -Rows $rows -Columns @('Index', 'Statut', 'Session', 'Utilisation', 'LogMode', 'DossierSortie', 'DossierLogs', 'SessionRoot') -Widths @{ Index = 6; Statut = 12; Session = 18; Utilisation = 20; LogMode = 12; DossierSortie = 24; DossierLogs = 24; SessionRoot = 28 } -Prompt 'Choisis une session (0=annuler)' -DefaultChoice $defaultChoice
    if (-not $selected) { return $null }
    return $sessions[[int]$selected.Index - 1]
}

function Get-LauncherPlannedLogRoot {
    param([Parameter(Mandatory)][hashtable]$RunConfig)

    if ($RunConfig.ContainsKey('LauncherLogRoot') -and -not [string]::IsNullOrWhiteSpace([string]$RunConfig.LauncherLogRoot)) {
        return [System.IO.Path]::GetFullPath([string]$RunConfig.LauncherLogRoot)
    }

    if (-not $RunConfig.ContainsKey('LauncherSessionRoot') -or [string]::IsNullOrWhiteSpace([string]$RunConfig.LauncherSessionRoot)) {
        return 'Sera cree au lancement'
    }

    $runId = if ($RunConfig.ContainsKey('RunId') -and -not [string]::IsNullOrWhiteSpace([string]$RunConfig.RunId)) { [string]$RunConfig.RunId } else { '<prochain-run>' }
    return (Join-Path (Join-Path ([System.IO.Path]::GetFullPath([string]$RunConfig.LauncherSessionRoot)) 'logs') $runId)
}

function Get-LauncherSettingsPreview {
    param(
        [AllowNull()][string]$SettingsPath,
        [AllowNull()][string]$FallbackOutputDir = '',
        [AllowNull()][string]$FallbackLoggingMode = ''
    )

    $defaults = [ordered]@{
        ProgramName       = '-'
        Preset            = 'balanced'
        Profile           = 'webapp'
        OutputDir         = $(if ([string]::IsNullOrWhiteSpace($FallbackOutputDir)) { '-' } else { $FallbackOutputDir })
        Depth             = '-'
        Threads           = '-'
        TimeoutSeconds    = '-'
        Resume            = '-'
        Sources           = '-'
        LoggingMode       = $(if ([string]::IsNullOrWhiteSpace($FallbackLoggingMode)) { Get-LauncherDefaultLoggingMode } else { $FallbackLoggingMode })
    }

    if ([string]::IsNullOrWhiteSpace($SettingsPath) -or -not (Test-Path -LiteralPath $SettingsPath)) {
        return [pscustomobject]$defaults
    }

    try {
        $parsed = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        $sources = Get-LauncherSourceSummary `
            -EnableGau (ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $parsed -Name 'enableGau' -Default $true) -Default $true -Name 'enableGau') `
            -EnableWaybackUrls (ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $parsed -Name 'enableWaybackUrls' -Default $true) -Default $true -Name 'enableWaybackUrls') `
            -EnableHakrawler (ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $parsed -Name 'enableHakrawler' -Default $true) -Default $true -Name 'enableHakrawler')

        return [pscustomobject]@{
            ProgramName    = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'programName' -Default $defaults.ProgramName)
            Preset         = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'preset' -Default $defaults.Preset)
            Profile        = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'profile' -Default $defaults.Profile)
            OutputDir      = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'outputDir' -Default $defaults.OutputDir)
            Depth          = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'depth' -Default $defaults.Depth)
            Threads        = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'threads' -Default $defaults.Threads)
            TimeoutSeconds = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'timeoutSeconds' -Default $defaults.TimeoutSeconds)
            Resume         = [string](Get-LauncherDocumentProperty -InputObject $parsed -Name 'resume' -Default $defaults.Resume)
            Sources        = $sources
            LoggingMode    = $(if ([string]::IsNullOrWhiteSpace($FallbackLoggingMode)) { $defaults.LoggingMode } else { $FallbackLoggingMode })
        }
    } catch {
        return [pscustomobject]$defaults
    }
}

function Manage-LauncherSavedSessions {
    while ($true) {
        $selectedSession = Select-LauncherSavedSession
        if (-not $selectedSession) { return $null }

        Write-LauncherSection -Title 'Session actuelle'
        Write-LauncherKeyValue -Key 'Session' -Value $selectedSession.display_name
        Write-LauncherKeyValue -Key 'Chemin session' -Value $selectedSession.session_root
        Write-LauncherKeyValue -Key 'Scope' -Value $selectedSession.scope_path
        Write-LauncherKeyValue -Key 'Reglages' -Value $selectedSession.settings_path
        Write-LauncherKeyValue -Key 'Dossier logs' -Value $selectedSession.logs_root
        Write-LauncherKeyValue -Key 'Mode de logs' -Value $selectedSession.logging_mode
        Write-LauncherKeyValue -Key 'Dernier dossier de sortie' -Value $(if ($selectedSession.last_output_dir) { $selectedSession.last_output_dir } else { '-' })

        $actions = @(
            [pscustomobject]@{ Index = 1; Action = 'Ouvrir'; Cle = 'open'; Description = 'Ouvre 00-START-HERE.txt, 01-scope.json et 02-run-settings.json.' },
            [pscustomobject]@{ Index = 2; Action = 'Relancer'; Cle = 'launch'; Description = 'Recharge la session et relance le flux documents.' },
            [pscustomobject]@{ Index = 3; Action = 'Dupliquer'; Cle = 'duplicate'; Description = 'Cree une copie complete de la session dans un nouveau dossier.' },
            [pscustomobject]@{ Index = 4; Action = 'Voir logs'; Cle = 'logs'; Description = 'Ouvre le dernier dossier de logs connu ou le dossier logs de la session.' },
            [pscustomobject]@{ Index = 5; Action = 'Ouvrir dossier'; Cle = 'folder'; Description = 'Ouvre le dossier de la session dans le shell.' },
            [pscustomobject]@{ Index = 6; Action = 'Supprimer'; Cle = 'delete'; Description = 'Supprime la session apres confirmation explicite.' }
        )

        $selectedAction = Select-LauncherIndexedItem -Title 'Actions sur la session' -Rows $actions -Columns @('Index', 'Action', 'Description') -Widths @{ Index = 6; Action = 16; Description = 72 } -Prompt 'Action (0=retour)' -DefaultChoice '1'
        if (-not $selectedAction) { return $null }

        switch ($selectedAction.Cle) {
            'open' {
                $null = Update-LauncherSessionMetadata -SessionRoot $selectedSession.session_root -Values @{ last_used_utc = [DateTimeOffset]::UtcNow.ToString('o') }
                Set-LauncherSelectedSession -SessionId $selectedSession.session_id
                Open-LauncherDocument -Path $selectedSession.readme_path -Title 'Instructions session'
                Open-LauncherDocument -Path $selectedSession.scope_path -Title 'Scope session'
                Open-LauncherDocument -Path $selectedSession.settings_path -Title 'Reglages session'
                return [pscustomobject]@{ Action = 'selected'; Session = $selectedSession }
            }
            'launch' {
                $null = Update-LauncherSessionMetadata -SessionRoot $selectedSession.session_root -Values @{ last_used_utc = [DateTimeOffset]::UtcNow.ToString('o') }
                Set-LauncherSelectedSession -SessionId $selectedSession.session_id
                return [pscustomobject]@{ Action = 'launch'; Session = $selectedSession }
            }
            'duplicate' {
                $newName = Read-LauncherValue -Prompt 'Nom de la copie' -Default ($selectedSession.display_name + '-copie')
                if ([string]::IsNullOrWhiteSpace($newName)) { continue }
                $selectedSession = Copy-LauncherSavedSession -Session $selectedSession -NewDisplayName $newName
                Write-Host ("Session dupliquee : {0}" -f $selectedSession.session_root) -ForegroundColor Green
            }
            'logs' {
                $logPath = if ($selectedSession.last_log_dir -and (Test-Path -LiteralPath $selectedSession.last_log_dir)) { $selectedSession.last_log_dir } else { $selectedSession.logs_root }
                Open-LauncherPath -Path $logPath
            }
            'folder' {
                Open-LauncherPath -Path $selectedSession.session_root
            }
            'delete' {
                if (-not (Read-LauncherYesNo -Prompt ("Supprimer la session '{0}' ?" -f $selectedSession.display_name) -Default $false)) { continue }
                $null = Remove-LauncherSavedSession -Session $selectedSession
                Write-Host 'Session supprimee.' -ForegroundColor Yellow
            }
        }
    }
}

function Show-LauncherSelectedScopeGuidance {
    param([Parameter(Mandatory)][pscustomobject]$SelectedScope)

    $willEditInPlace = Test-LauncherEditableManagedScopePath -Path $SelectedScope.scope_path
    Write-Host ''
    Write-Host '  Fichier de scope selectionne' -ForegroundColor Cyan
    Write-LauncherKeyValue -Key 'Fichier' -Value $SelectedScope.scope_display_path
    Write-LauncherKeyValue -Key 'Chemin complet' -Value $SelectedScope.scope_path
    Write-LauncherKeyValue -Key 'Statut' -Value (Get-LauncherScopeStatusLabel -Exists ([bool]$SelectedScope.exists))
    Write-LauncherKeyValue -Key 'Mode d edition' -Value $(if ($willEditInPlace) { 'Edition directe sur ce fichier' } else { 'Copie dans une session documents avant edition' })
    Write-LauncherKeyValue -Key 'Dernier dossier de sortie' -Value $(if ($SelectedScope.last_output_dir) { $SelectedScope.last_output_dir } else { 'Aucun dossier enregistre' })
    Write-Host '  Prochaine etape : choisis "Lancer avec ce fichier de scope" ou affiche son dernier dossier de sortie.' -ForegroundColor DarkGray
}

function Select-LauncherRecentScope {
    $recentScopes = @(Read-LauncherRecentScopes)
    if ($recentScopes.Count -eq 0) { return $null }
    $rows = @()
    for ($index = 0; $index -lt $recentScopes.Count; $index++) {
        $item = $recentScopes[$index]
        $rows += [pscustomobject]@{
            Index               = ($index + 1)
            Statut              = (Get-LauncherScopeStatusLabel -Exists ([bool]$item.exists))
            Fichier             = $item.display_name
            Scope               = (Get-LauncherRepoRelativePath -Path $item.scope_path)
            DerniereUtilisation = $(if ($item.last_used_utc) { ([DateTimeOffset]$item.last_used_utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })
            DossierSortie       = $(if ($item.last_output_dir) { $item.last_output_dir } else { '-' })
        }
    }

    $selected = Select-LauncherIndexedItem -Title 'Choisir un scope recent' -Rows $rows -Columns @('Index', 'Statut', 'Fichier', 'Scope', 'DerniereUtilisation', 'DossierSortie') -Widths @{ Index = 6; Statut = 12; Fichier = 18; Scope = 34; DerniereUtilisation = 20; DossierSortie = 34 } -Prompt 'Choisis un scope recent (0=annuler)' -DefaultChoice '1'
    if (-not $selected) { return $null }
    return $recentScopes[[int]$selected.Index - 1]
}

function Show-LauncherScopeHelp {
    $workspace = Initialize-LauncherFileWorkspace
    $templates = @(Get-LauncherScopeTemplateFiles)

    Write-LauncherSection -Title 'Aide sur les champs du scope'
    Write-Host 'Les fichiers de scope doivent rester en JSON strict sans commentaires.' -ForegroundColor Gray
    Write-LauncherKeyValue -Key 'Guide general' -Value $workspace.TemplatesGuide

    if ($templates.Count -gt 0) {
        $rows = @()
        for ($index = 0; $index -lt $templates.Count; $index++) {
            $template = $templates[$index]
            $rows += [pscustomobject]@{
                Index   = ($index + 1)
                Modele  = $template.DisplayName
                Usage   = $template.Description
                JSON    = (Get-LauncherRepoRelativePath -Path $template.Path)
                Guide   = (Get-LauncherRepoRelativePath -Path $template.HelpPath)
            }
        }

        Write-LauncherTable -Rows $rows -Columns @('Index', 'Modele', 'Usage', 'JSON', 'Guide') -Widths @{ Index = 6; Modele = 20; Usage = 34; JSON = 28; Guide = 30 }
        Write-Host 'G. Ouvrir le guide general' -ForegroundColor Gray
        Write-Host '0. Retour' -ForegroundColor Gray

        $allowedChoices = @('0', 'G', 'g') + @(1..$templates.Count | ForEach-Object { [string]$_ })
        $choice = Read-LauncherChoice -Prompt 'Choix' -Allowed $allowedChoices -Default '0'
        switch ($choice.ToUpperInvariant()) {
            '0' { return }
            'G' { Open-LauncherDocument -Path $workspace.TemplatesGuide -Title 'Guide des modeles de scope' }
            default {
                $selectedTemplate = $templates[[int]$choice - 1]
                Open-LauncherDocument -Path $selectedTemplate.HelpPath -Title ("Guide {0}" -f $selectedTemplate.DisplayName)
            }
        }
    }
}

function Read-LauncherManualScopePath {
    while ($true) {
        $rawPath = Read-LauncherValue -Prompt 'Chemin du fichier de scope JSON (vide pour annuler)' -Default ''
        if ([string]::IsNullOrWhiteSpace($rawPath)) { return $null }

        $resolvedPath = Resolve-LauncherScopePath -Path $rawPath
        # La saisie manuelle reste volontairement stricte pour eviter d'ouvrir
        # un dossier, un mauvais format ou un fichier absent.
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            Write-Host ("Scope introuvable: {0}" -f $resolvedPath) -ForegroundColor Yellow
            continue
        }

        $item = Get-Item -LiteralPath $resolvedPath
        if ($item.PSIsContainer) {
            Write-Host 'Le chemin pointe vers un dossier, pas un fichier JSON.' -ForegroundColor Yellow
            continue
        }

        if ($item.Extension -ne '.json') {
            Write-Host 'Le scope doit etre un fichier .json.' -ForegroundColor Yellow
            continue
        }

        try {
            $null = @(Read-ScopeFile -Path $resolvedPath)
        } catch {
            Write-Host ("Ce fichier JSON ne ressemble pas a un fichier de scope valide: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            continue
        }

        return $item.FullName
    }
}

function Show-LauncherManagedScopeFiles {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ScopeFiles)

    Write-LauncherSection -Title 'Choisir un fichier de scope existant'
    if (-not $ScopeFiles -or $ScopeFiles.Count -eq 0) {
        Write-Host 'Aucun fichier de scope JSON detecte dans scopes/active ou scopes/incoming.' -ForegroundColor Yellow
        return
    }

    $rows = @()
    for ($index = 0; $index -lt $ScopeFiles.Count; $index++) {
        $item = $ScopeFiles[$index]
        $rows += [pscustomobject]@{
            Index         = ($index + 1)
            Dossier       = $item.folder_label
            Nom           = $item.display_name
            Scope         = $item.scope_display_path
            DossierSortie = $(if ($item.last_output_dir) { $item.last_output_dir } else { '-' })
        }
    }

    Write-LauncherTable -Rows $rows -Columns @('Index', 'Dossier', 'Nom', 'Scope', 'DossierSortie') -Widths @{ Index = 6; Dossier = 12; Nom = 18; Scope = 38; DossierSortie = 32 }
}

function Select-LauncherManagedScopeFile {
    $scopeFiles = @(Get-LauncherManagedScopeFiles)
    if ($scopeFiles.Count -gt 0) {
        $rows = @()
        for ($index = 0; $index -lt $scopeFiles.Count; $index++) {
            $item = $scopeFiles[$index]
            $rows += [pscustomobject]@{
                Index         = ($index + 1)
                Dossier       = $item.folder_label
                Nom           = $item.display_name
                Scope         = $item.scope_display_path
                DossierSortie = $(if ($item.last_output_dir) { $item.last_output_dir } else { '-' })
            }
        }

        $selected = Select-LauncherIndexedItem -Title 'Choisir un fichier de scope existant' -Rows $rows -Columns @('Index', 'Dossier', 'Nom', 'Scope', 'DossierSortie') -Widths @{ Index = 6; Dossier = 12; Nom = 18; Scope = 38; DossierSortie = 32 } -Prompt 'Choisis un scope (0=autre)' -DefaultChoice '1'
        if ($selected) {
            return $scopeFiles[[int]$selected.Index - 1].scope_path
        }
    }

    if (Read-LauncherYesNo -Prompt 'Saisir un chemin manuel ?' -Default $true) {
        return (Read-LauncherManualScopePath)
    }
    return $null
}

function Show-LauncherCreatedScopeGuidance {
    param(
        [Parameter(Mandatory)][pscustomobject]$CreatedScope,
        [Parameter(Mandatory)][string]$PlannedOutputDir
    )

    Write-LauncherSection -Title 'Fichier de scope cree'
    Write-LauncherKeyValue -Key 'Nom du fichier' -Value ([System.IO.Path]::GetFileName($CreatedScope.Path))
    Write-LauncherKeyValue -Key 'Chemin complet' -Value $CreatedScope.Path
    Write-LauncherKeyValue -Key 'Chemin repo' -Value (Get-LauncherRepoRelativePath -Path $CreatedScope.Path)
    Write-LauncherKeyValue -Key 'Modele' -Value $CreatedScope.TemplateDisplayName
    Write-LauncherKeyValue -Key 'Guide du modele' -Value $CreatedScope.HelpPath
    Write-LauncherKeyValue -Key 'Fichier ouvert' -Value $(if ($CreatedScope.OpenedScope) { 'Oui' } else { 'Non' })
    Write-LauncherKeyValue -Key 'Guide ouvert' -Value $(if ($CreatedScope.OpenedGuide) { 'Oui' } else { 'Non' })
    Write-LauncherKeyValue -Key 'Dossier de sortie du prochain run' -Value $PlannedOutputDir

    Write-Host ''
    Write-Host 'Etapes suivantes' -ForegroundColor Cyan
    Write-Host '1. Remplis le fichier de scope puis sauvegarde-le.' -ForegroundColor Gray
    Write-Host '2. Reviens au menu et choisis "Lancer avec ce fichier de scope".' -ForegroundColor Gray
    Write-Host '3. Apres un premier run reussi, tu pourras aussi le retrouver dans "Afficher les fichiers de scope deja utilises".' -ForegroundColor Gray
}

function New-LauncherScopeFromTemplate {
    param([string]$PlannedOutputDir = '')

    $workspace = Initialize-LauncherFileWorkspace
    $templates = @(Get-LauncherScopeTemplateFiles)
    $minimalTemplate = $templates | Where-Object { $_.Key -eq 'minimal' } | Select-Object -First 1
    $standardTemplate = $templates | Where-Object { $_.Key -eq 'standard' } | Select-Object -First 1
    $advancedTemplate = $templates | Where-Object { $_.Key -eq 'advanced' } | Select-Object -First 1
    $otherTemplates = @($templates | Where-Object { $_.Key -notin @('minimal', 'standard', 'advanced') })

    Write-LauncherSection -Title 'Creer un nouveau fichier de scope a remplir'
    Write-Host 'Choisis le type de fichier de scope que tu veux creer.' -ForegroundColor Cyan
    Write-Host '1. Creer un modele minimal' -ForegroundColor Gray
    Write-Host '2. Creer un modele standard' -ForegroundColor Gray
    Write-Host '3. Creer un modele avance' -ForegroundColor Gray
    if ($otherTemplates.Count -gt 0) {
        Write-Host '4. Utiliser un autre modele de scopes/templates' -ForegroundColor Gray
    }
    Write-Host '0. Annuler' -ForegroundColor Gray

    $allowedTemplateChoices = @('0', '1', '2', '3')
    if ($otherTemplates.Count -gt 0) { $allowedTemplateChoices += '4' }
    $templateChoice = Read-LauncherChoice -Prompt 'Type de modele' -Allowed $allowedTemplateChoices -Default '2'

    if ($templateChoice -eq '0') { return $null }

    $selectedTemplate = switch ($templateChoice) {
        '1' { $minimalTemplate }
        '2' { $standardTemplate }
        '3' { $advancedTemplate }
        '4' {
            $rows = @()
            for ($index = 0; $index -lt $otherTemplates.Count; $index++) {
                $template = $otherTemplates[$index]
                $rows += [pscustomobject]@{
                    Index   = ($index + 1)
                    Nom     = $template.DisplayName
                    Usage   = $template.Description
                    JSON    = (Get-LauncherRepoRelativePath -Path $template.Path)
                    Guide   = (Get-LauncherRepoRelativePath -Path $template.HelpPath)
                }
            }

            Write-LauncherTable -Rows $rows -Columns @('Index', 'Nom', 'Usage', 'JSON', 'Guide') -Widths @{ Index = 6; Nom = 20; Usage = 30; JSON = 28; Guide = 28 }
            Write-Host '0. Annuler' -ForegroundColor Gray
            $customChoice = Read-LauncherChoice -Prompt 'Modele avance' -Allowed @('0') + @(1..$otherTemplates.Count | ForEach-Object { [string]$_ }) -Default '1'
            if ($customChoice -eq '0') { return $null }
            $otherTemplates[[int]$customChoice - 1]
        }
    }
    if (-not $selectedTemplate) { return $null }

    $templateContent = Get-Content -LiteralPath $selectedTemplate.Path -Raw -Encoding utf8

    Write-Host ("Modele choisi : {0}" -f $selectedTemplate.DisplayName) -ForegroundColor Green
    Write-Host ("Guide associe  : {0}" -f (Get-LauncherRepoRelativePath -Path $selectedTemplate.HelpPath)) -ForegroundColor Gray
    Write-Host '1. Enregistrer dans scopes/incoming' -ForegroundColor Gray
    Write-Host '2. Enregistrer dans scopes/active' -ForegroundColor Gray
    $destinationChoice = Read-LauncherChoice -Prompt 'Destination' -Allowed @('1', '2') -Default '1'
    $destinationRoot = if ($destinationChoice -eq '2') { $workspace.Active } else { $workspace.Incoming }

    while ($true) {
        # Le nom par defaut rappelle le type de modele pour retrouver vite le bon
        # fichier dans scopes/incoming ou dans les recents.
        $defaultName = ('{0}-{1}' -f $selectedTemplate.SuggestedFilePrefix, [DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
        $fileName = Read-LauncherValue -Prompt 'Nom du fichier scope' -Default $defaultName
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            Write-Host 'Le nom du fichier ne peut pas etre vide.' -ForegroundColor Yellow
            continue
        }
        if (-not $fileName.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
            $fileName += '.json'
        }

        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        if ($fileName.IndexOfAny($invalidChars) -ge 0) {
            Write-Host 'Le nom du fichier contient des caracteres invalides.' -ForegroundColor Yellow
            continue
        }

        $targetPath = Join-Path $destinationRoot $fileName
        if (Test-Path -LiteralPath $targetPath) {
            Write-Host ("Le fichier existe deja: {0}" -f $targetPath) -ForegroundColor Yellow
            continue
        }

        Set-Content -LiteralPath $targetPath -Value $templateContent -Encoding utf8
        $openedScope = $false
        $openedGuide = $false

        # Ouvrir immediatement les fichiers retire l'ambiguite sur la prochaine
        # action attendue: l'utilisateur modifie, sauvegarde, puis relance.
        if (Read-LauncherYesNo -Prompt 'Ouvrir le fichier cree dans l''editeur' -Default $true) {
            Open-LauncherDocument -Path $targetPath -Title 'Fichier de scope'
            $openedScope = $true
        }

        if (Read-LauncherYesNo -Prompt 'Ouvrir aussi le guide du modele' -Default $false) {
            Open-LauncherDocument -Path $selectedTemplate.HelpPath -Title ("Guide {0}" -f $selectedTemplate.DisplayName)
            $openedGuide = $true
        }

        $createdScope = [pscustomobject]@{
            Path                = $targetPath
            HelpPath            = $selectedTemplate.HelpPath
            TemplateDisplayName = $selectedTemplate.DisplayName
            OpenedScope         = $openedScope
            OpenedGuide         = $openedGuide
        }
        Show-LauncherCreatedScopeGuidance -CreatedScope $createdScope -PlannedOutputDir $(if ($PlannedOutputDir) { $PlannedOutputDir } else { Get-LauncherDefaultOutputDir })
        return $createdScope
    }
}

function Show-LauncherScopeSelection {
    param(
        [AllowNull()][pscustomobject]$SelectedScope,
        [AllowNull()][pscustomobject]$SelectedSession,
        [Parameter(Mandatory)][string]$PlannedOutputDir,
        [string]$LoggingMode = 'normal',
        [string]$PlannedLogDir = '',
        [string]$InteractionMode = '',
        [AllowEmptyCollection()][object[]]$RecentScopes = @(),
        [AllowEmptyCollection()][object[]]$SavedSessions = @()
    )

    $workspace = Initialize-LauncherFileWorkspace
    $modeLabel = switch ($(if ($InteractionMode) { $InteractionMode } else { Get-LauncherInteractionMode })) {
        'visual' { 'Visuel assiste (selection Windows si disponible)' }
        'console' { 'Console classique (clavier / numeros)' }
        default { $_ }
    }
    $settingsPreview = Get-LauncherSettingsPreview -SettingsPath $(if ($SelectedSession) { $SelectedSession.settings_path } else { $null }) -FallbackOutputDir $PlannedOutputDir -FallbackLoggingMode $LoggingMode

    Write-LauncherSection -Title 'Session actuelle'
    Write-LauncherKeyValue -Key 'Mode interaction' -Value $modeLabel
    Write-LauncherKeyValue -Key 'Session active' -Value $(if ($SelectedSession) { $SelectedSession.display_name } else { 'Aucune session enregistree selectionnee' })
    Write-LauncherKeyValue -Key 'Chemin session' -Value $(if ($SelectedSession) { $SelectedSession.session_root } else { 'Une session sera creee si necessaire' })
    Write-LauncherKeyValue -Key '02-run-settings.json' -Value $(if ($SelectedSession) { $SelectedSession.settings_path } else { '-' })
    Write-LauncherStatusLine -Label 'Statut session' -Status $(if ($SelectedSession) { $(if ($SelectedSession.exists) { 'OK' } else { 'INTROUVABLE' }) } else { 'OK' }) -Details $(if ($SelectedSession) { 'session memorisee' } else { 'session creee a la demande' })

    Write-LauncherSection -Title 'Scope actuel'
    Write-LauncherKeyValue -Key 'Fichier actuellement utilise' -Value $(if ($SelectedScope) { $SelectedScope.scope_display_path } else { 'Aucun fichier de scope selectionne' })
    Write-LauncherStatusLine -Label 'Statut scope' -Status $(if ($SelectedScope) { $SelectedScope.note } else { '-' }) -Details $(if ($SelectedScope -and $SelectedScope.last_output_dir) { "dernier output: $($SelectedScope.last_output_dir)" } else { '' })
    Write-LauncherKeyValue -Key 'Chemin complet' -Value $(if ($SelectedScope) { $SelectedScope.scope_path } else { '-' })
    Write-LauncherKeyValue -Key 'Aide pour remplir' -Value $workspace.TemplatesGuide
    Write-LauncherKeyValue -Key 'Mode d edition' -Value $(if ($SelectedScope) { $(if (Test-LauncherEditableManagedScopePath -Path $SelectedScope.scope_path) { 'Edition directe' } else { 'Copie dans une session documents' }) } else { '-' })

    Write-LauncherSection -Title 'Parametres du run'
    Write-LauncherKeyValue -Key 'Programme' -Value $settingsPreview.ProgramName
    Write-LauncherKeyValue -Key 'Preset / profil' -Value ("{0} / {1}" -f $settingsPreview.Preset, $settingsPreview.Profile)
    Write-LauncherKeyValue -Key 'Profondeur / threads' -Value ("{0} / {1}" -f $settingsPreview.Depth, $settingsPreview.Threads)
    Write-LauncherKeyValue -Key 'Timeout' -Value $settingsPreview.TimeoutSeconds
    Write-LauncherKeyValue -Key 'Sources actives' -Value $settingsPreview.Sources
    Write-LauncherKeyValue -Key 'Resume' -Value $settingsPreview.Resume

    Write-LauncherSection -Title 'Logs'
    Write-LauncherKeyValue -Key 'Mode de logs' -Value $LoggingMode
    Write-LauncherKeyValue -Key 'Dossier des logs' -Value $(if ($PlannedLogDir) { $PlannedLogDir } else { 'Sera cree au lancement' })
    Write-Host '  Le mode debug ajoute plus de decisions internes pour le depannage.' -ForegroundColor DarkGray

    Write-LauncherSection -Title 'Dossier de sortie'
    Write-LauncherKeyValue -Key 'Sortie active' -Value $(if ($settingsPreview.OutputDir -and $settingsPreview.OutputDir -ne '-') { $settingsPreview.OutputDir } else { $PlannedOutputDir })
    Write-LauncherKeyValue -Key 'Dernier output scope' -Value $(if ($SelectedScope -and $SelectedScope.last_output_dir) { $SelectedScope.last_output_dir } else { '-' })

    if ($RecentScopes -and $RecentScopes.Count -gt 0) {
        Write-LauncherSection -Title 'Scopes recents'
        $recentRows = @(
            $RecentScopes |
            Select-Object -First 3 |
            ForEach-Object {
                [pscustomobject]@{
                    Statut      = $_.note
                    Scope       = $_.display_name
                    Utilisation = $(if ($_.last_used_utc) { ([DateTimeOffset]$_.last_used_utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '-' })
                    Sortie      = $(if ($_.last_output_dir) { $_.last_output_dir } else { '-' })
                }
            }
        )
        Write-LauncherTable -Rows $recentRows -Columns @('Statut', 'Scope', 'Utilisation', 'Sortie') -Widths @{ Statut = 12; Scope = 22; Utilisation = 18; Sortie = 44 }
    }

    if ($SavedSessions -and $SavedSessions.Count -gt 0) {
        Write-LauncherSection -Title 'Sessions enregistrees'
        $sessionRows = @(
            $SavedSessions |
            Select-Object -First 3 |
            ForEach-Object {
                [pscustomobject]@{
                    Session     = $_.display_name
                    Statut      = $(if ($_.exists) { 'OK' } else { 'INTROUVABLE' })
                    Logs        = $(if ($_.logging_mode) { $_.logging_mode } else { '-' })
                    Utilisation = $(if ($_.last_used_utc) { ([DateTimeOffset]$_.last_used_utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '-' })
                }
            }
        )
        Write-LauncherTable -Rows $sessionRows -Columns @('Session', 'Statut', 'Logs', 'Utilisation') -Widths @{ Session = 24; Statut = 12; Logs = 12; Utilisation = 18 }
    }

    Write-LauncherSection -Title 'Actions disponibles'
    Write-Host '  Cree ou choisis un scope, gere les sessions, regle les logs, puis lance.' -ForegroundColor Gray
    Write-Host '  Le menu ci-dessous garde toujours un raccourci clavier numerique.' -ForegroundColor DarkGray

    Write-LauncherSection -Title 'Prochaine etape'
    if ($SelectedSession) {
        Write-Host '  Reprends la session active si ses fichiers te conviennent, sinon choisis un autre scope.' -ForegroundColor Yellow
    } elseif ($SelectedScope) {
        Write-Host '  Verifie le scope selectionne, le dossier des logs et le dossier de sortie, puis lance.' -ForegroundColor Yellow
    } else {
        Write-Host '  Commence par creer un fichier de scope ou en choisir un existant.' -ForegroundColor Yellow
    }
}

function Show-LauncherScopeLastOutput {
    param([AllowNull()][pscustomobject]$SelectedScope)

    Write-LauncherSection -Title 'Dernier dossier de sortie connu'
    if (-not $SelectedScope) {
        Write-Host 'Aucun fichier de scope courant selectionne.' -ForegroundColor Yellow
        return
    }

    Write-LauncherKeyValue -Key 'Fichier de scope' -Value $SelectedScope.scope_display_path
    Write-LauncherKeyValue -Key 'Statut' -Value (Get-LauncherScopeStatusLabel -Exists ([bool]$SelectedScope.exists))
    Write-LauncherKeyValue -Key 'Dossier de sortie' -Value $(if ($SelectedScope.last_output_dir) { $SelectedScope.last_output_dir } else { 'Aucun dossier enregistre' })
    Write-Host '  Prochaine etape : ouvre ce dossier si tu veux relire les anciens rapports avant de relancer.' -ForegroundColor DarkGray
}

function Select-LauncherGuidedStartupPlan {
    param(
        [string]$InitialScopeFile,
        [string]$OutputDir,
        [bool]$AllowRerun = $false
    )

    $plannedOutputDir = if ($OutputDir) { $OutputDir } else { Get-LauncherDefaultOutputDir }
    $selectedSession = Get-LauncherSelectedSession
    $selectedScope = $null
    if ($InitialScopeFile) {
        $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $InitialScopeFile -RecentScopes (Read-LauncherRecentScopes)
    } elseif ($selectedSession -and $selectedSession.scope_path) {
        $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $selectedSession.scope_path -RecentScopes (Read-LauncherRecentScopes)
    }
    $loggingMode = if ($selectedSession -and $selectedSession.logging_mode) { [string]$selectedSession.logging_mode } else { Get-LauncherDefaultLoggingMode }
    $interactionMode = Get-LauncherInteractionMode

    while ($true) {
        $recentScopes = @(Read-LauncherRecentScopes)
        $savedSessions = @(Get-LauncherSavedSessions)
        if ($selectedSession) {
            $selectedSession = $savedSessions | Where-Object { $_.session_id -eq $selectedSession.session_id } | Select-Object -First 1
        }
        if ($selectedScope) {
            $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $selectedScope.scope_path -RecentScopes $recentScopes
        }
        if (-not $selectedScope -and $selectedSession -and $selectedSession.scope_path) {
            $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $selectedSession.scope_path -RecentScopes $recentScopes
        }
        $plannedLogDir = if ($selectedSession) {
            if ($selectedSession.last_log_dir) { $selectedSession.last_log_dir } else { $selectedSession.logs_root }
        } else {
            'Sera cree dans la session au lancement'
        }

        Show-LauncherScopeSelection -SelectedScope $selectedScope -SelectedSession $selectedSession -PlannedOutputDir $plannedOutputDir -LoggingMode $loggingMode -PlannedLogDir $plannedLogDir -InteractionMode $interactionMode -RecentScopes $recentScopes -SavedSessions $savedSessions

        $defaultChoice = if ($selectedScope -or $selectedSession) { '11' } else { '2' }

        Write-LauncherSection -Title 'Zone de selection'
        Write-LauncherMenuOption -Number '1' -Label 'Creer un nouveau fichier de scope a remplir' -IsDefault:($defaultChoice -eq '1') -Hint 'modele minimal, standard ou avance'
        Write-LauncherMenuOption -Number '2' -Label 'Choisir un fichier de scope existant' -IsDefault:($defaultChoice -eq '2') -Hint 'scopes actifs ou incoming'
        Write-LauncherMenuOption -Number '3' -Label 'Ouvrir un fichier de scope recent' -IsDefault:($defaultChoice -eq '3') -Hint 'scope deja utilise'
        Write-LauncherMenuOption -Number '4' -Label 'Gerer les sessions enregistrees' -IsDefault:($defaultChoice -eq '4') -Hint 'ouvrir, relancer, dupliquer, supprimer'
        Write-LauncherMenuOption -Number '5' -Label 'Choisir le niveau de logs' -IsDefault:($defaultChoice -eq '5') -Hint 'standard, verbeux ou debug'
        Write-LauncherMenuOption -Number '6' -Label ("Basculer le mode d'interaction ({0})" -f $interactionMode) -IsDefault:($defaultChoice -eq '6')
        Write-LauncherMenuOption -Number '7' -Label 'Afficher les emplacements des scopes et modeles' -IsDefault:($defaultChoice -eq '7')
        Write-LauncherMenuOption -Number '8' -Label 'Afficher l''aide sur les champs du scope' -IsDefault:($defaultChoice -eq '8')
        Write-LauncherMenuOption -Number '9' -Label 'Afficher le dernier dossier de sortie du scope courant' -IsDefault:($defaultChoice -eq '9')
        Write-LauncherMenuOption -Number '10' -Label 'Relancer le dernier fichier de scope utilise' -IsDefault:($defaultChoice -eq '10')
        Write-LauncherMenuOption -Number '11' -Label 'Lancer avec le scope ou la session active' -IsDefault:($defaultChoice -eq '11') -Hint 'action recommandee si tout est pret'
        Write-LauncherMenuOption -Number '12' -Label 'Assistant console sans documents' -IsDefault:($defaultChoice -eq '12')
        Write-LauncherMenuOption -Number '13' -Label 'Relancer un ancien run' -IsDefault:($defaultChoice -eq '13')
        Write-LauncherMenuOption -Number '0' -Label 'Quitter' -IsDefault:($defaultChoice -eq '0')

        $allowedChoices = @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12', '13')
        $choice = Read-LauncherChoice -Prompt 'Choix' -Allowed $allowedChoices -Default $defaultChoice

        switch ($choice) {
            '1' {
                $createdScope = New-LauncherScopeFromTemplate -PlannedOutputDir $plannedOutputDir
                if ($createdScope) {
                    $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $createdScope.Path -RecentScopes $recentScopes
                    $selectedSession = $null
                }
            }
            '2' {
                $scopePath = Select-LauncherManagedScopeFile
                if ($scopePath) {
                    $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $scopePath -RecentScopes $recentScopes
                    $selectedSession = $null
                    Show-LauncherSelectedScopeGuidance -SelectedScope $selectedScope
                }
            }
            '3' {
                $recentItem = Select-LauncherRecentScope
                if ($recentItem) {
                    $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $recentItem.scope_path -RecentScopes $recentScopes
                    $selectedSession = $null
                    Show-LauncherSelectedScopeGuidance -SelectedScope $selectedScope
                }
            }
            '4' {
                $sessionAction = Manage-LauncherSavedSessions
                if (-not $sessionAction) { continue }
                $selectedSession = $sessionAction.Session
                if ($selectedSession) {
                    $loggingMode = if ($selectedSession.logging_mode) { [string]$selectedSession.logging_mode } else { $loggingMode }
                    if ($selectedSession.scope_path) {
                        $selectedScope = Get-LauncherScopeEntryFromPath -ScopePath $selectedSession.scope_path -RecentScopes $recentScopes
                    }
                }
                if ($sessionAction.Action -eq 'launch') {
                    return [pscustomobject]@{
                        Action           = 'saved-session-documents'
                        SessionRoot      = $selectedSession.session_root
                        SessionId        = $selectedSession.session_id
                        InitialScopeFile = $selectedSession.scope_path
                        ManagedScopeFile = $(if (Test-LauncherEditableManagedScopePath -Path $selectedSession.scope_path) { $selectedSession.scope_path } else { $null })
                        OutputDir        = $plannedOutputDir
                        LoggingMode      = $loggingMode
                    }
                }
            }
            '5' {
                $selectedMode = Select-LauncherLoggingMode -DefaultMode $loggingMode
                $loggingMode = $selectedMode.Key
                $null = Update-LauncherUiState -Values @{ logging_mode = $loggingMode }
                if ($selectedSession) {
                    $selectedSession = Update-LauncherSessionMetadata -SessionRoot $selectedSession.session_root -Values @{ logging_mode = $loggingMode }
                }
            }
            '6' {
                $interactionMode = Set-LauncherInteractionMode -Mode $(if ($interactionMode -eq 'visual') { 'console' } else { 'visual' })
                Write-Host ("Mode d'interaction actif : {0}" -f $interactionMode) -ForegroundColor Green
            }
            '7' {
                Show-LauncherScopeFolders
            }
            '8' {
                Show-LauncherScopeHelp
            }
            '9' {
                Show-LauncherScopeLastOutput -SelectedScope $selectedScope
            }
            '10' {
                $lastRecent = $recentScopes | Select-Object -First 1
                if (-not $lastRecent) {
                    Write-Host 'Aucun fichier de scope recent a relancer.' -ForegroundColor Yellow
                    continue
                }
                $lastScope = Get-LauncherScopeEntryFromPath -ScopePath $lastRecent.scope_path -RecentScopes $recentScopes
                if (-not $lastScope.exists) {
                    Write-Host ("Le dernier fichier de scope utilise est INTROUVABLE: {0}" -f $lastScope.scope_display_path) -ForegroundColor Yellow
                    continue
                }
                return [pscustomobject]@{
                    Action           = 'documents'
                    InitialScopeFile = $lastScope.scope_path
                    ManagedScopeFile = $(if (Test-LauncherEditableManagedScopePath -Path $lastScope.scope_path) { $lastScope.scope_path } else { $null })
                    OutputDir        = $plannedOutputDir
                    LoggingMode      = $loggingMode
                }
            }
            '11' {
                if ($selectedSession) {
                    return [pscustomobject]@{
                        Action           = 'saved-session-documents'
                        SessionRoot      = $selectedSession.session_root
                        SessionId        = $selectedSession.session_id
                        InitialScopeFile = $selectedSession.scope_path
                        ManagedScopeFile = $(if (Test-LauncherEditableManagedScopePath -Path $selectedSession.scope_path) { $selectedSession.scope_path } else { $null })
                        OutputDir        = $plannedOutputDir
                        LoggingMode      = $loggingMode
                    }
                }
                if (-not $selectedScope) {
                    Write-Host 'Selectionne d''abord un fichier de scope.' -ForegroundColor Yellow
                    continue
                }
                if (-not $selectedScope.exists) {
                    Write-Host ("Le fichier de scope courant est INTROUVABLE: {0}" -f $selectedScope.scope_display_path) -ForegroundColor Yellow
                    continue
                }
                return [pscustomobject]@{
                    Action           = 'documents'
                    InitialScopeFile = $selectedScope.scope_path
                    ManagedScopeFile = $(if (Test-LauncherEditableManagedScopePath -Path $selectedScope.scope_path) { $selectedScope.scope_path } else { $null })
                    OutputDir        = $plannedOutputDir
                    LoggingMode      = $loggingMode
                }
            }
            '12' {
                return [pscustomobject]@{
                    Action           = 'console'
                    InitialScopeFile = $(if ($selectedScope) { $selectedScope.scope_path } else { $null })
                    OutputDir        = $plannedOutputDir
                    LoggingMode      = $loggingMode
                    SessionRoot      = $(if ($selectedSession) { $selectedSession.session_root } else { $null })
                    SessionId        = $(if ($selectedSession) { $selectedSession.session_id } else { $null })
                }
            }
            '13' {
                if (-not $AllowRerun) {
                    Write-Host 'Aucun ancien run enregistre pour le moment.' -ForegroundColor Yellow
                    continue
                }
                return [pscustomobject]@{
                    Action      = 'rerun'
                    LoggingMode = $loggingMode
                }
            }
            '0' {
                return [pscustomobject]@{ Action = 'quit' }
            }
        }
    }
}

function Get-LauncherRunCatalogRoot {
    $catalogRoot = Join-Path (Get-LauncherRunsRoot) '_catalog'
    if (-not (Test-Path -LiteralPath $catalogRoot)) {
        $null = New-Item -ItemType Directory -Path $catalogRoot -Force
    }
    return $catalogRoot
}

function Get-LauncherUniqueRunDirectory {
    param([string]$Suffix = '')

    $runsRoot = Get-LauncherRunsRoot
    $baseName = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $candidatePath = Join-Path $runsRoot ($baseName + $Suffix)
    $counter = 1
    while (Test-Path -LiteralPath $candidatePath) {
        $candidatePath = Join-Path $runsRoot ("{0}{1}-{2}" -f $baseName, $Suffix, $counter)
        $counter++
    }
    return $candidatePath
}

function Get-LauncherUniqueSessionDirectory {
    param([string]$Suffix = '')

    $launcherRoot = Get-LauncherDocumentsRoot
    $baseName = 'session-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $candidatePath = Join-Path $launcherRoot ($baseName + $Suffix)
    $counter = 1
    while (Test-Path -LiteralPath $candidatePath) {
        $candidatePath = Join-Path $launcherRoot ("{0}{1}-{2}" -f $baseName, $Suffix, $counter)
        $counter++
    }
    return $candidatePath
}

function Get-LauncherRunManifestPath {
    param([Parameter(Mandatory)][string]$OutputDir)
    return (Join-Path $OutputDir 'reports/run-manifest.json')
}

function Get-LauncherFrozenScopePath {
    param([Parameter(Mandatory)][string]$OutputDir)
    return (Join-Path $OutputDir 'reports/scope-frozen.json')
}

function Get-LauncherFrozenSettingsPath {
    param([Parameter(Mandatory)][string]$OutputDir)
    return (Join-Path $OutputDir 'reports/run-settings-frozen.json')
}

function Get-LauncherVersionInfo {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Path             = $item.FullName
        LastWriteTime    = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    }
}

function Test-LauncherBootstrapContext {
    if ($env:SCOPEFORGE_BOOTSTRAP_ROOT) { return $true }
    $tempRoot = [System.IO.Path]::GetTempPath()
    return $PSScriptRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and $PSScriptRoot.Contains('-Bootstrap')
}

function Show-LauncherVersionPanel {
    $launcherInfo = Get-LauncherVersionInfo -Path $PSCommandPath
    $engineInfo = Get-LauncherVersionInfo -Path (Join-Path $PSScriptRoot 'ScopeForge.ps1')
    $showFullPaths = [bool](Test-LauncherBootstrapContext) -or ($VerbosePreference -eq 'Continue')

    Write-LauncherSection -Title 'Version'
    if ($launcherInfo) {
        Write-LauncherKeyValue -Key 'Launcher' -Value $(if ($showFullPaths) { $launcherInfo.Path } else { [System.IO.Path]::GetFileName($launcherInfo.Path) })
        Write-LauncherKeyValue -Key 'LauncherUpdated' -Value $launcherInfo.LastWriteTime
    }
    if ($engineInfo) {
        Write-LauncherKeyValue -Key 'Moteur' -Value $(if ($showFullPaths) { $engineInfo.Path } else { [System.IO.Path]::GetFileName($engineInfo.Path) })
        Write-LauncherKeyValue -Key 'EngineUpdated' -Value $engineInfo.LastWriteTime
    }
    if (Test-LauncherBootstrapContext) {
        Write-Host ''
        Write-Host '  Bootstrap' -ForegroundColor Cyan
        Write-LauncherKeyValue -Key 'BootstrapRoot' -Value $(if ($env:SCOPEFORGE_BOOTSTRAP_ROOT) { $env:SCOPEFORGE_BOOTSTRAP_ROOT } else { $PSScriptRoot })
        Write-LauncherKeyValue -Key 'BootstrapSource' -Value $(if ($env:SCOPEFORGE_BOOTSTRAP_SOURCE) { $env:SCOPEFORGE_BOOTSTRAP_SOURCE } else { 'cached temp bootstrap detected' })
        Write-LauncherKeyValue -Key 'BootstrapUpdated' -Value $(if ($env:SCOPEFORGE_BOOTSTRAP_UPDATED_AT) { $env:SCOPEFORGE_BOOTSTRAP_UPDATED_AT } else { $(if ($launcherInfo) { $launcherInfo.LastWriteTimeUtc } else { '-' }) })
        Write-LauncherKeyValue -Key 'BootstrapStatus' -Value $(if ($env:SCOPEFORGE_BOOTSTRAP_REFRESH_REASON) { $env:SCOPEFORGE_BOOTSTRAP_REFRESH_REASON } else { 'cached bootstrap reused' })
        Write-Host '  Refresh hint     : relance le bootstrap avec -Update pour forcer le refresh.' -ForegroundColor Yellow
    }
}

function Get-LauncherRunSettingsSnapshot {
    param([Parameter(Mandatory)][hashtable]$RunConfig)

    $snapshot = [ordered]@{}
    foreach ($name in @('PresetName', 'PresetDescription', 'ProfileName', 'ProfileDescription', 'ProfileSourceExplanation', 'ProgramName', 'OutputDir', 'Depth', 'UniqueUserAgent', 'Threads', 'TimeoutSeconds', 'EnableGau', 'EnableWaybackUrls', 'EnableHakrawler', 'NoInstall', 'Quiet', 'IncludeApex', 'RespectSchemeOnly', 'Resume', 'OpenReportOnFinish')) {
        if ($RunConfig.ContainsKey($name)) {
            $snapshot[$name] = $RunConfig[$name]
        }
    }
    return [pscustomobject]$snapshot
}

function Get-LauncherToolSnapshot {
    param([Parameter(Mandatory)][string]$OutputDir)

    $binRoot = Join-Path $OutputDir 'tools/bin'
    if (-not (Test-Path -LiteralPath $binRoot)) { return @() }

    function Get-LauncherToolVersionText {
        param([Parameter(Mandatory)][string]$BinaryPath)

        foreach ($arguments in @(@('--version'), @('-version'), @('version'))) {
            try {
                $output = & $BinaryPath @arguments 2>&1
                $firstLine = @($output | Where-Object { $_ } | Select-Object -First 1)
                if ($firstLine.Count -gt 0) {
                    return ([string]$firstLine[0]).Trim()
                }
            } catch {
            }
        }
        return $null
    }

    return @(
        foreach ($toolName in @('subfinder', 'httpx', 'katana', 'gau', 'waybackurls', 'hakrawler')) {
            $candidate = Get-ChildItem -LiteralPath $binRoot -File | Where-Object { $_.BaseName -eq $toolName -or $_.BaseName -like "$toolName.*" } | Sort-Object Name | Select-Object -First 1
            if ($candidate) {
                $versionInfo = $candidate.VersionInfo
                [pscustomobject]@{
                    Name             = $toolName
                    Binary           = $candidate.Name
                    BinaryPath       = $candidate.FullName
                    ProductVersion   = $(if ($versionInfo -and $versionInfo.ProductVersion) { $versionInfo.ProductVersion } else { $null })
                    FileVersion      = $(if ($versionInfo -and $versionInfo.FileVersion) { $versionInfo.FileVersion } else { $null })
                    Version          = Get-LauncherToolVersionText -BinaryPath $candidate.FullName
                    LastWriteTimeUtc = $candidate.LastWriteTimeUtc.ToString('o')
                }
            }
        }
    )
}

function Get-LauncherRepoVersionDescriptor {
    $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gitCommand) {
        try {
            $commit = (& $gitCommand.Source -C $PSScriptRoot rev-parse --short HEAD 2>$null | Select-Object -First 1)
            if ($commit) {
                return [pscustomobject]@{
                    Source    = 'git'
                    GitCommit = ([string]$commit).Trim()
                }
            }
        } catch {
        }
    }

    return [pscustomobject]@{
        Source    = 'file-timestamp'
        GitCommit = $null
    }
}

function Save-LauncherRunManifest {
    param(
        [Parameter(Mandatory)][hashtable]$RunConfig,
        [Parameter(Mandatory)][pscustomobject]$Result,
        [Parameter(Mandatory)][string]$RunStartedAtUtc,
        [Parameter(Mandatory)][string]$RunEndedAtUtc
    )

    $manifestPath = Get-LauncherRunManifestPath -OutputDir $Result.OutputDir
    $frozenScopePath = Get-LauncherFrozenScopePath -OutputDir $Result.OutputDir
    $frozenSettingsPath = Get-LauncherFrozenSettingsPath -OutputDir $Result.OutputDir
    $reportsDirectory = Split-Path -Parent $manifestPath
    if (-not (Test-Path -LiteralPath $reportsDirectory)) {
        $null = New-Item -ItemType Directory -Path $reportsDirectory -Force
    }

    if ($RunConfig.ContainsKey('ScopeFile') -and $RunConfig.ScopeFile -and (Test-Path -LiteralPath $RunConfig.ScopeFile)) {
        Set-Content -LiteralPath $frozenScopePath -Value (Get-Content -LiteralPath $RunConfig.ScopeFile -Raw -Encoding utf8) -Encoding utf8
    } elseif ($RunConfig.ContainsKey('ScopePreview')) {
        Set-Content -LiteralPath $frozenScopePath -Value ($RunConfig.ScopePreview | ConvertTo-Json -Depth 50) -Encoding utf8
    }

    $settingsSnapshot = Get-LauncherRunSettingsSnapshot -RunConfig $RunConfig
    Set-Content -LiteralPath $frozenSettingsPath -Value ($settingsSnapshot | ConvertTo-Json -Depth 20) -Encoding utf8

    $launcherInfo = Get-LauncherVersionInfo -Path $PSCommandPath
    $engineInfo = Get-LauncherVersionInfo -Path (Join-Path $PSScriptRoot 'ScopeForge.ps1')
    $repoVersion = Get-LauncherRepoVersionDescriptor
    $runId = if ($RunConfig.ContainsKey('RunId') -and $RunConfig.RunId) { [string]$RunConfig.RunId } else { [Guid]::NewGuid().ToString('N') }
    $summary = $Result.Summary

    $manifest = [ordered]@{
        ManifestVersion    = 1
        RunId             = $runId
        ParentRunId       = $(if ($RunConfig.ContainsKey('ParentRunId')) { $RunConfig.ParentRunId } else { $null })
        ProgramName       = $Result.ProgramName
        StartTimeUtc      = $RunStartedAtUtc
        EndTimeUtc        = $RunEndedAtUtc
        OutputDir         = $Result.OutputDir
        OriginalScopeFile = $(if ($RunConfig.ContainsKey('ScopeFile')) { $RunConfig.ScopeFile } else { $null })
        FrozenScopeFile   = $frozenScopePath
        FrozenSettingsFile = $frozenSettingsPath
        RunSettings       = $settingsSnapshot
        Session           = [ordered]@{
            SessionRoot   = $(if ($RunConfig.ContainsKey('LauncherSessionRoot')) { $RunConfig.LauncherSessionRoot } else { $null })
            SessionId     = $(if ($RunConfig.ContainsKey('LauncherSessionId')) { $RunConfig.LauncherSessionId } else { $null })
            LoggingMode   = $(if ($RunConfig.ContainsKey('LauncherLogMode')) { $RunConfig.LauncherLogMode } else { $null })
            LauncherLogRoot = $(if ($RunConfig.ContainsKey('LauncherLogRoot')) { $RunConfig.LauncherLogRoot } else { $null })
        }
        Summary           = [ordered]@{
            ScopeItemCount        = $summary.ScopeItemCount
            ExcludedItemCount     = $summary.ExcludedItemCount
            DiscoveredHostCount   = $summary.DiscoveredHostCount
            LiveHostCount         = $summary.LiveHostCount
            LiveTargetCount       = $summary.LiveTargetCount
            DiscoveredUrlCount    = $summary.DiscoveredUrlCount
            InterestingUrlCount   = $summary.InterestingUrlCount
            ProtectedInterestingCount = $summary.ProtectedInterestingCount
            ErrorCount            = $summary.ErrorCount
        }
        RepoVersion       = [ordered]@{
            Source              = $repoVersion.Source
            GitCommit           = $repoVersion.GitCommit
            LauncherPath        = $(if ($launcherInfo) { $launcherInfo.Path } else { $null })
            LauncherUpdatedUtc  = $(if ($launcherInfo) { $launcherInfo.LastWriteTimeUtc } else { $null })
            EnginePath          = $(if ($engineInfo) { $engineInfo.Path } else { $null })
            EngineUpdatedUtc    = $(if ($engineInfo) { $engineInfo.LastWriteTimeUtc } else { $null })
        }
        ToolSnapshot      = @(Get-LauncherToolSnapshot -OutputDir $Result.OutputDir)
        Reports           = [ordered]@{
            ManifestPath = $manifestPath
            ReportHtml   = Join-Path $Result.OutputDir 'reports/report.html'
            TriageMarkdown = Join-Path $Result.OutputDir 'reports/triage.md'
            SummaryJson  = Join-Path $Result.OutputDir 'reports/summary.json'
        }
    }

    Set-Content -LiteralPath $manifestPath -Value ($manifest | ConvertTo-Json -Depth 50) -Encoding utf8
    $catalogPath = Join-Path (Get-LauncherRunCatalogRoot) ("{0}.json" -f $runId)
    Set-Content -LiteralPath $catalogPath -Value ($manifest | ConvertTo-Json -Depth 50) -Encoding utf8
    $manifest['CatalogPath'] = $catalogPath
    return [pscustomobject]$manifest
}

function Read-LauncherStoredRunManifest {
    param([Parameter(Mandatory)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest introuvable: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $ManifestPath -Force
    return $manifest
}

function Get-LauncherStoredRuns {
    $catalogRoot = Get-LauncherRunCatalogRoot
    $catalogFiles = @(Get-ChildItem -LiteralPath $catalogRoot -Filter *.json -File -ErrorAction SilentlyContinue)
    $manifests = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $catalogFiles) {
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
            $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $file.FullName -Force
            $manifests.Add($manifest) | Out-Null
        } catch {
        }
    }

    if ($manifests.Count -eq 0) {
        foreach ($runDirectory in (Get-ChildItem -LiteralPath (Get-LauncherRunsRoot) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_catalog' })) {
            $manifestPath = Join-Path $runDirectory.FullName 'reports/run-manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
                $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $manifestPath -Force
                $manifests.Add($manifest) | Out-Null
            } catch {
            }
        }
    }

    return @(
        $manifests |
        Sort-Object -Property @{ Expression = { [DateTimeOffset](if ($_.EndTimeUtc) { $_.EndTimeUtc } else { '1970-01-01T00:00:00Z' }) }; Descending = $true }
    )
}

function Show-LauncherStoredRuns {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs)

    if (-not $Runs -or $Runs.Count -eq 0) {
        Write-LauncherSection -Title 'Relancer un run'
        Write-Host 'Aucun run précédent détecté dans le stockage ScopeForge.' -ForegroundColor Yellow
        return
    }

    $rows = @()
    for ($index = 0; $index -lt $Runs.Count; $index++) {
        $run = $Runs[$index]
        $rows += [pscustomobject]@{
            Index      = ($index + 1)
            Date       = $(if ($run.EndTimeUtc) { ([DateTimeOffset]$run.EndTimeUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })
            Program    = $(if ($run.ProgramName) { $run.ProgramName } else { '-' })
            OutputDir  = $(if ($run.OutputDir) { $run.OutputDir } else { '-' })
            Interesting = $(if ($run.Summary -and $run.Summary.InterestingUrlCount -ne $null) { $run.Summary.InterestingUrlCount } else { 0 })
            Errors     = $(if ($run.Summary -and $run.Summary.ErrorCount -ne $null) { $run.Summary.ErrorCount } else { 0 })
            Report     = $(if ($run.Reports -and $run.Reports.ReportHtml) { $run.Reports.ReportHtml } else { '-' })
        }
    }

    Write-LauncherSection -Title 'Relancer un run'
    Write-LauncherTable -Rows $rows -Columns @('Index', 'Date', 'Program', 'OutputDir', 'Interesting', 'Errors', 'Report') -Widths @{ Index = 6; Date = 19; Program = 18; OutputDir = 32; Interesting = 11; Errors = 8; Report = 32 }
}

function Select-LauncherStoredRun {
    $runs = @(Get-LauncherStoredRuns)
    if ($runs.Count -eq 0) { return $null }
    $rows = @()
    for ($index = 0; $index -lt $runs.Count; $index++) {
        $run = $runs[$index]
        $rows += [pscustomobject]@{
            Index       = ($index + 1)
            Date        = $(if ($run.EndTimeUtc) { ([DateTimeOffset]$run.EndTimeUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })
            Program     = $(if ($run.ProgramName) { $run.ProgramName } else { '-' })
            OutputDir   = $(if ($run.OutputDir) { $run.OutputDir } else { '-' })
            Interesting = $(if ($run.Summary -and $run.Summary.InterestingUrlCount -ne $null) { $run.Summary.InterestingUrlCount } else { 0 })
            Errors      = $(if ($run.Summary -and $run.Summary.ErrorCount -ne $null) { $run.Summary.ErrorCount } else { 0 })
            Report      = $(if ($run.Reports -and $run.Reports.ReportHtml) { $run.Reports.ReportHtml } else { '-' })
        }
    }

    $selected = Select-LauncherIndexedItem -Title 'Choisir un run a relancer' -Rows $rows -Columns @('Index', 'Date', 'Program', 'OutputDir', 'Interesting', 'Errors', 'Report') -Widths @{ Index = 6; Date = 19; Program = 18; OutputDir = 32; Interesting = 11; Errors = 8; Report = 32 } -Prompt 'Choisis un run a relancer (0=annuler)' -DefaultChoice '1'
    if (-not $selected) { return $null }
    return $runs[[int]$selected.Index - 1]
}

function New-LauncherRerunConfigFromManifest {
    param(
        [Parameter(Mandatory)][pscustomobject]$Manifest,
        [switch]$ReviewInDocuments
    )

    $settings = if ($Manifest.RunSettings) { $Manifest.RunSettings } else { [pscustomobject]@{} }
    $newOutputDir = Get-LauncherUniqueRunDirectory -Suffix '-rerun'
    $scopeFile = if ($Manifest.FrozenScopeFile -and (Test-Path -LiteralPath $Manifest.FrozenScopeFile)) { $Manifest.FrozenScopeFile } elseif ($Manifest.OriginalScopeFile -and (Test-Path -LiteralPath $Manifest.OriginalScopeFile)) { $Manifest.OriginalScopeFile } else { $null }
    if (-not $scopeFile) {
        throw "Impossible de relancer ce run: scope figé introuvable pour $($Manifest.ProgramName)."
    }

    $programName = [string](Get-LauncherDocumentProperty -InputObject $settings -Name 'ProgramName' -Default $Manifest.ProgramName)
    $depth = ConvertTo-LauncherInteger -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'Depth' -Default 3) -Name 'depth' -Default 3 -Minimum 1 -Maximum 20
    $threads = ConvertTo-LauncherInteger -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'Threads' -Default 10) -Name 'threads' -Default 10 -Minimum 1 -Maximum 200
    $timeoutSeconds = ConvertTo-LauncherInteger -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'TimeoutSeconds' -Default 30) -Name 'timeoutSeconds' -Default 30 -Minimum 5 -Maximum 600
    $enableGau = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'EnableGau' -Default $true) -Name 'enableGau' -Default $true
    $enableWaybackUrls = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'EnableWaybackUrls' -Default $true) -Name 'enableWaybackUrls' -Default $true
    $enableHakrawler = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'EnableHakrawler' -Default $true) -Name 'enableHakrawler' -Default $true
    $noInstall = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'NoInstall' -Default $false) -Name 'noInstall' -Default $false
    $quiet = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'Quiet' -Default $false) -Name 'quiet' -Default $false
    $includeApex = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'IncludeApex' -Default $false) -Name 'includeApex' -Default $false
    $respectSchemeOnly = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'RespectSchemeOnly' -Default $false) -Name 'respectSchemeOnly' -Default $false
    $resume = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'Resume' -Default $false) -Name 'resume' -Default $false
    $openReportOnFinish = ConvertTo-LauncherBoolean -Value (Get-LauncherDocumentProperty -InputObject $settings -Name 'OpenReportOnFinish' -Default $true) -Name 'openReportOnFinish' -Default $true
    $uniqueUserAgent = [string](Get-LauncherDocumentProperty -InputObject $settings -Name 'UniqueUserAgent' -Default '')

    if ($ReviewInDocuments) {
        $reviewedConfig = Build-DocumentRunConfig -InitialScopeFile $scopeFile -ProgramName $programName -OutputDir $newOutputDir -Depth $depth -UniqueUserAgent $uniqueUserAgent -Threads $threads -TimeoutSeconds $timeoutSeconds -EnableGau $enableGau -EnableWaybackUrls $enableWaybackUrls -EnableHakrawler $enableHakrawler -NoInstall $noInstall -Quiet $quiet -IncludeApex $includeApex -RespectSchemeOnly $respectSchemeOnly -Resume $resume -OpenReportOnFinish $openReportOnFinish
        $reviewedConfig['ParentRunId'] = $Manifest.RunId
        $reviewedConfig['RerunSourceManifest'] = $Manifest.ManifestPath
        return $reviewedConfig
    }

    $scopePreview = Read-ScopeFile -Path $scopeFile -IncludeApex:$includeApex
    return @{
        PresetName             = Get-LauncherDocumentProperty -InputObject $settings -Name 'PresetName' -Default ''
        PresetDescription      = Get-LauncherDocumentProperty -InputObject $settings -Name 'PresetDescription' -Default ''
        ProfileName            = Get-LauncherDocumentProperty -InputObject $settings -Name 'ProfileName' -Default ''
        ProfileDescription     = Get-LauncherDocumentProperty -InputObject $settings -Name 'ProfileDescription' -Default ''
        ProfileSourceExplanation = Get-LauncherDocumentProperty -InputObject $settings -Name 'ProfileSourceExplanation' -Default ''
        ScopeFile              = $scopeFile
        ProgramName            = $programName
        OutputDir              = $newOutputDir
        Depth                  = $depth
        UniqueUserAgent        = $uniqueUserAgent
        Threads                = $threads
        TimeoutSeconds         = $timeoutSeconds
        EnableGau              = $enableGau
        EnableWaybackUrls      = $enableWaybackUrls
        EnableHakrawler        = $enableHakrawler
        NoInstall              = $noInstall
        Quiet                  = $quiet
        IncludeApex            = $includeApex
        RespectSchemeOnly      = $respectSchemeOnly
        Resume                 = $resume
        OpenReportOnFinish     = $openReportOnFinish
        ParentRunId            = $Manifest.RunId
        RerunSourceManifest    = $Manifest.ManifestPath
        ScopePreview           = $scopePreview
    }
}

function Select-LauncherStartupAction {
    param(
        [bool]$ConsoleModeDefault = $false,
        [bool]$AllowRerun = $false
    )

    if ($ConsoleModeDefault) { return 'console' }

    Write-LauncherSection -Title 'Mode'
    Write-Host '1. Nouveau run (documents)' -ForegroundColor Gray
    if ($AllowRerun) {
        Write-Host '2. Relancer un ancien run' -ForegroundColor Gray
    }
    Write-Host '3. Assistant console' -ForegroundColor Gray

    $allowedChoices = @('1', '3')
    if ($AllowRerun) { $allowedChoices += '2' }
    $choice = Read-LauncherChoice -Prompt 'Choix' -Allowed $allowedChoices -Default '1'
    switch ($choice) {
        '2' { return 'rerun' }
        '3' { return 'console' }
        default { return 'documents' }
    }
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

function Get-LauncherStartHereContent {
    param(
        [Parameter(Mandatory)][string]$ScopePath,
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][string]$DefaultOutputDir,
        [AllowNull()][string]$SessionRoot = '',
        [AllowNull()][string]$LogsRoot = '',
        [bool]$ManagedScopeFile = $false
    )

    $dictionarySupport = Get-LauncherDictionarySupportStatus
    $scopeFileLabel = if ($ManagedScopeFile) { [System.IO.Path]::GetFileName($ScopePath) } else { '01-scope.json' }

    return @"
ScopeForge - guide operateur pas a pas

Repere rapide
- Session actuelle       : $(if ([string]::IsNullOrWhiteSpace($SessionRoot)) { 'session creee a la demande' } else { $SessionRoot })
- Fichier de scope       : $ScopePath
- Fichier des reglages   : $SettingsPath
- Dossier des logs       : $(if ([string]::IsNullOrWhiteSpace($LogsRoot)) { 'sera cree pendant le run' } else { $LogsRoot })
- Dossier de sortie prevu: $DefaultOutputDir
- Guide des modeles      : scopes/templates/README.md

Tu vas remplir 2 fichiers :
- $scopeFileLabel : decrit UNIQUEMENT ce qui est autorise
- 02-run-settings.json : regle la vitesse, la couverture, les logs et le volume du run

Etape 1 - Comprendre les types de scope

1. Domain
- Signifie : un hostname exact comme app.example.com
- Utilise-le quand le programme autorise un site ou sous-domaine precis
- Exemple :
  { "type": "Domain", "value": "app.example.com", "exclusions": [] }

2. Wildcard
- Signifie : plusieurs sous-domaines d'une meme racine comme https://*.example.com
- Utilise-le quand le programme autorise une famille complete de sous-domaines
- Exemple :
  { "type": "Wildcard", "value": "https://*.example.com", "exclusions": ["dev", "staging"] }

3. URL
- Signifie : une URL de depart precise comme https://api.example.com/v1
- Utilise-la quand le programme mentionne une URL de depart ou une zone applicative precise
- Exemple :
  { "type": "URL", "value": "https://api.example.com/v1", "exclusions": [] }

Etape 2 - Construire un scope avec plusieurs cibles

- 01-scope.json doit rester un tableau JSON
- Tu peux melanger plusieurs Domain, Wildcard et URL dans le meme fichier
- Garde seulement les cibles explicitement autorisees

Exemple mixte :
[
  { "type": "Domain", "value": "app.example.com", "exclusions": [] },
  { "type": "Wildcard", "value": "https://*.example.com", "exclusions": ["dev", "staging"] },
  { "type": "URL", "value": "https://api.example.com/v1", "exclusions": [] }
]

Etape 3 - Comprendre les exclusions

- exclusions est toujours un tableau, meme s'il est vide
- Chaque token exclut tout host, URL ou chemin qui contient cette chaine
- Reste specifique : un token trop large peut exclure plus que prevu

Exemple :
- ["dev", "staging"] exclut par exemple dev.example.com ou /staging/api

Etape 4 - Ce qu'il ne faut PAS mettre dans le scope

- pas de commentaires JSON
- pas de type inconnu comme "CIDR" ou "Subdomain"
- pas de Domain avec scheme comme https://app.example.com
- pas de Wildcard avec chemin comme https://*.example.com/admin
- pas de cible hors scope

Etape 5 - Remplir le fichier de scope

- Chemin du fichier scope : $ScopePath
- Relis le fichier avant de continuer :
  1. chaque item a bien type, value, exclusions
  2. les Domain n'ont ni scheme ni chemin
  3. les Wildcard sont du type *.example.com ou https://*.example.com
  4. les URL sont absolues en http:// ou https://
- Quand tu as termine : sauvegarde le scope puis passe a 02-run-settings.json

Etape 6 - Remplir 02-run-settings.json

- Chemin des reglages : $SettingsPath
- Reglages qui affectent surtout la vitesse :
  - depth
  - threads
  - timeoutSeconds
  - resume
- Reglages qui affectent surtout la couverture :
  - enableGau
  - enableWaybackUrls
  - enableHakrawler
  - includeApex
  - respectSchemeOnly
- Reglages qui augmentent surtout le volume de sortie :
  - depth
  - enableGau
  - enableWaybackUrls
  - enableHakrawler
- Reglages prudents par defaut :
  - preset = balanced
  - profile = webapp
  - includeApex = false
  - respectSchemeOnly = false
  - resume = false
- Tous les booleens doivent rester en JSON natif true / false sans guillemets
- Le mode de logs sera memorise avec la session

Etape 7 - Dictionnaires / wordlists
- Statut : $($dictionarySupport.DisplayLabel)
- Detail : $($dictionarySupport.Detail)
- Consigne : $($dictionarySupport.Recommendation)

Etape 8 - Ce que fait le launcher ensuite

1. Sauvegarde 02-run-settings.json
2. Ferme les fenetres d'edition
3. Le launcher valide les fichiers
4. Il affiche un resume du scope, des reglages, des logs et une duree approximative
5. Il lance la collecte
6. Les resultats seront ecrits dans le dossier indique par outputDir
7. Valeur actuelle de outputDir : $DefaultOutputDir
8. Les logs du launcher et du run seront ranges dans le dossier des logs

Etape 9 - Prochaine action attendue

- Sauvegarde les deux fichiers
- Ferme l'editeur
- Lis le resume avant lancement
- Verifie le dossier de sortie et le niveau de logs
- Lance le run

Relancer plus tard

- Utilise le menu des fichiers de scope deja utilises
- Utilise aussi les sessions enregistrees pour rouvrir, dupliquer ou relancer une session complete
- Si un fichier a ete deplace ou supprime, il restera visible comme INTROUVABLE avec son dernier output connu
$(if ($ManagedScopeFile) { "- Le scope sera edite directement dans son emplacement gere : $ScopePath" } else { "- Le scope est copie dans le workspace de session pour edition." })
"@
}

function New-LauncherDocumentSet {
    param(
        [string]$InitialScopeFile,
        [string]$ManagedScopeFilePath,
        [string]$SessionRootOverride,
        [bool]$PreserveExistingFiles = $false,
        [string]$LoggingMode,
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

    $sessionRoot = if ($SessionRootOverride) { [System.IO.Path]::GetFullPath($SessionRootOverride) } else { Get-LauncherUniqueSessionDirectory }
    if (-not (Test-Path -LiteralPath $sessionRoot)) {
        $null = New-Item -ItemType Directory -Path $sessionRoot -Force
    }

    $readmePath = Join-Path $sessionRoot '00-START-HERE.txt'
    $scopePath = if ($ManagedScopeFilePath) { Resolve-LauncherScopePath -Path $ManagedScopeFilePath } else { Join-Path $sessionRoot '01-scope.json' }
    $settingsPath = Join-Path $sessionRoot '02-run-settings.json'
    $logsRoot = Join-Path $sessionRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsRoot)) {
        $null = New-Item -ItemType Directory -Path $logsRoot -Force
    }

    $scopeTemplate = $null
    if ($ManagedScopeFilePath) {
        $scopeTemplate = $null
    } elseif ($InitialScopeFile -and (Test-Path -LiteralPath $InitialScopeFile)) {
        $scopeTemplate = Get-Content -LiteralPath $InitialScopeFile -Raw -Encoding utf8
    } else {
        $scopeTemplate = Get-LauncherDefaultScopeTemplateContent
    }

    $defaultProgramName = if ($ProgramName) { $ProgramName } else { 'authorized-bugbounty' }
    $defaultOutputDir = if ($OutputDir) { $OutputDir } else { Get-LauncherDefaultOutputDir }
    $defaultUserAgent = if ($UniqueUserAgent) { $UniqueUserAgent } else { "researcher-" + ([Guid]::NewGuid().ToString('N').Substring(0, 8)) }

    $settingsObject = [ordered]@{
        preset             = 'balanced'
        profile            = 'webapp'
        programName        = $defaultProgramName
        outputDir          = $defaultOutputDir
        uniqueUserAgent    = $defaultUserAgent
        depth              = if ($Depth -gt 0) { $Depth } else { 3 }
        threads            = if ($Threads -gt 0) { $Threads } else { 10 }
        timeoutSeconds     = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { 30 }
        enableGau          = $EnableGau
        enableWaybackUrls  = $EnableWaybackUrls
        enableHakrawler    = $EnableHakrawler
        includeApex        = $IncludeApex
        respectSchemeOnly  = $RespectSchemeOnly
        resume             = $Resume
        noInstall          = $NoInstall
        quiet              = $Quiet
        openReportOnFinish = $OpenReportOnFinish
    }

    $instructions = Get-LauncherStartHereContent -ScopePath $scopePath -SettingsPath $settingsPath -DefaultOutputDir $defaultOutputDir -SessionRoot $sessionRoot -LogsRoot $logsRoot -ManagedScopeFile ([bool](-not [string]::IsNullOrWhiteSpace($ManagedScopeFilePath)))

    Set-Content -LiteralPath $readmePath -Value $instructions -Encoding utf8
    if (-not $ManagedScopeFilePath -and (-not $PreserveExistingFiles -or -not (Test-Path -LiteralPath $scopePath))) {
        Set-Content -LiteralPath $scopePath -Value $scopeTemplate -Encoding utf8
    }
    if (-not $PreserveExistingFiles -or -not (Test-Path -LiteralPath $settingsPath)) {
        Set-Content -LiteralPath $settingsPath -Value ($settingsObject | ConvertTo-Json -Depth 20) -Encoding utf8
    }

    $sessionRecord = Update-LauncherSessionMetadata -SessionRoot $sessionRoot -Values @{
        display_name  = $(if ($ProgramName) { $ProgramName } else { [System.IO.Path]::GetFileName($sessionRoot) })
        scope_path    = $scopePath
        settings_path = $settingsPath
        readme_path   = $readmePath
        logs_root     = $logsRoot
        logging_mode  = $(if ($LoggingMode) { $LoggingMode } else { Get-LauncherDefaultLoggingMode })
        last_log_dir  = $logsRoot
        last_used_utc = [DateTimeOffset]::UtcNow.ToString('o')
        note          = 'SESSION'
    }
    Set-LauncherSelectedSession -SessionId $sessionRecord.session_id

    return [pscustomobject]@{
        RootPath      = $sessionRoot
        ReadmePath    = $readmePath
        ScopePath     = $scopePath
        SettingsPath  = $settingsPath
        LogsRoot      = $logsRoot
        SessionRecord = $sessionRecord
    }
}

function Build-DocumentRunConfig {
    param(
        [string]$InitialScopeFile,
        [string]$ManagedScopeFilePath,
        [string]$ExistingSessionRoot,
        [string]$LoggingMode,
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

    $existingSession = if ($ExistingSessionRoot) { Read-LauncherSessionMetadata -SessionRoot $ExistingSessionRoot } else { $null }
    $effectiveManagedScopeFilePath = $ManagedScopeFilePath
    if (-not $effectiveManagedScopeFilePath -and $existingSession -and $existingSession.scope_path) {
        $defaultSessionScopePath = Join-Path ([System.IO.Path]::GetFullPath($ExistingSessionRoot)) '01-scope.json'
        $recordedScopePath = Resolve-LauncherScopePath -Path $existingSession.scope_path
        if ($recordedScopePath -ne [System.IO.Path]::GetFullPath($defaultSessionScopePath) -and (Test-Path -LiteralPath $recordedScopePath)) {
            $effectiveManagedScopeFilePath = $recordedScopePath
        }
    }
    $effectiveLoggingMode = if ($LoggingMode) { $LoggingMode } elseif ($existingSession -and $existingSession.logging_mode) { [string]$existingSession.logging_mode } else { $null }

    $documentSet = New-LauncherDocumentSet -InitialScopeFile $InitialScopeFile -ManagedScopeFilePath $effectiveManagedScopeFilePath -SessionRootOverride $ExistingSessionRoot -PreserveExistingFiles:([bool](-not [string]::IsNullOrWhiteSpace($ExistingSessionRoot))) -LoggingMode $effectiveLoggingMode -ProgramName $ProgramName -OutputDir $OutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -EnableGau $EnableGau -EnableWaybackUrls $EnableWaybackUrls -EnableHakrawler $EnableHakrawler -NoInstall $NoInstall -Quiet $Quiet -IncludeApex $IncludeApex -RespectSchemeOnly $RespectSchemeOnly -Resume $Resume -OpenReportOnFinish $OpenReportOnFinish

    $documentSessionRecord = if ($documentSet.PSObject.Properties['SessionRecord']) { $documentSet.SessionRecord } else { $null }

    Write-LauncherSection -Title 'Mode documents'
    Write-Host ("Les documents de configuration ont ete crees ici : {0}" -f $documentSet.RootPath) -ForegroundColor Cyan
    if ($effectiveManagedScopeFilePath) {
        Write-Host ("Le scope actif sera edite directement ici : {0}" -f (Get-LauncherRepoRelativePath -Path $documentSet.ScopePath)) -ForegroundColor Cyan
    }
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
                ManagedScopeFile       = $(if ($effectiveManagedScopeFilePath) { $documentSet.ScopePath } else { $null })
                LauncherSelectedScopePath = $(if ($InitialScopeFile) { Resolve-LauncherScopePath -Path $InitialScopeFile } else { $documentSet.ScopePath })
                LauncherSessionRoot    = $documentSet.RootPath
                LauncherSessionId      = $(if ($documentSessionRecord) { $documentSessionRecord.session_id } else { $null })
                LauncherLogMode        = $(if ($effectiveLoggingMode) { $effectiveLoggingMode } else { $(if ($documentSessionRecord) { $documentSessionRecord.logging_mode } else { Get-LauncherDefaultLoggingMode }) })
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
        LauncherSelectedScopePath = $(if ($localScopeFile) { Resolve-LauncherScopePath -Path $localScopeFile } else { $null })
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
        Quiet             = [bool]$Quiet
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
        [switch]$RerunPrevious,
        [string]$RerunManifestPath,
        [bool]$OpenReportOnFinish = $true,
        [switch]$NonInteractive
    )

    $scopeForgePath = Join-Path $PSScriptRoot 'ScopeForge.ps1'
    if (-not (Test-Path -LiteralPath $scopeForgePath)) { throw "ScopeForge.ps1 introuvable à côté du launcher: $scopeForgePath" }
    . $scopeForgePath

    if ($NonInteractive -and $RerunPrevious -and -not $RerunManifestPath) {
        throw 'Le mode -RerunPrevious nécessite une sélection interactive ou un -RerunManifestPath explicite.'
    }

    $runConfig = @{
        ScopeFile         = $ScopeFile
        LauncherSelectedScopePath = $(if ($ScopeFile) { Resolve-LauncherScopePath -Path $ScopeFile } else { $null })
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
        RunId             = [Guid]::NewGuid().ToString('N')
    }

    if ($NonInteractive -and $RerunManifestPath) {
        $runConfig = New-LauncherRerunConfigFromManifest -Manifest (Read-LauncherStoredRunManifest -ManifestPath $RerunManifestPath) -ReviewInDocuments:$false
        if (-not $runConfig.ContainsKey('RunId')) {
            $runConfig['RunId'] = [Guid]::NewGuid().ToString('N')
        }
    }

    $showPostRunMenu = $false

    if (-not $NonInteractive) {
        Write-LauncherBanner
        Show-LauncherVersionPanel

        $startupPlan = if ($RerunManifestPath -or $RerunPrevious) {
            [pscustomobject]@{ Action = 'rerun' }
        } elseif ($ConsoleMode) {
            [pscustomobject]@{ Action = 'console' }
        } else {
            Select-LauncherGuidedStartupPlan -InitialScopeFile $ScopeFile -OutputDir $OutputDir -AllowRerun:([bool](@(Get-LauncherStoredRuns).Count -gt 0))
        }

        if (-not $startupPlan -or $startupPlan.Action -eq 'quit') { return }
        $selectedLoggingMode = if ($startupPlan.PSObject.Properties['LoggingMode'] -and $startupPlan.LoggingMode) { [string]$startupPlan.LoggingMode } else { Get-LauncherDefaultLoggingMode }
        $selectedSessionRoot = if ($startupPlan.PSObject.Properties['SessionRoot'] -and $startupPlan.SessionRoot) { [string]$startupPlan.SessionRoot } else { $null }
        $selectedSessionId = if ($startupPlan.PSObject.Properties['SessionId'] -and $startupPlan.SessionId) { [string]$startupPlan.SessionId } else { $null }

        switch ($startupPlan.Action) {
            'console' {
                $showPostRunMenu = $true
                $selectedScopeFile = if ($startupPlan.PSObject.Properties['InitialScopeFile']) { $startupPlan.InitialScopeFile } else { $ScopeFile }
                $selectedOutputDir = if ($startupPlan.PSObject.Properties['OutputDir'] -and $startupPlan.OutputDir) { $startupPlan.OutputDir } else { $OutputDir }
                $runConfig = Build-InteractiveRunConfig -InitialScopeFile $selectedScopeFile -ProgramName $ProgramName -OutputDir $selectedOutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -EnableGau $EnableGau -EnableWaybackUrls $EnableWaybackUrls -EnableHakrawler $EnableHakrawler -NoInstall ([bool]$NoInstall) -Quiet ([bool]$Quiet) -IncludeApex ([bool]$IncludeApex) -RespectSchemeOnly ([bool]$RespectSchemeOnly) -Resume ([bool]$Resume) -OpenReportOnFinish $OpenReportOnFinish
            }
            'rerun' {
                $selectedRun = if ($RerunManifestPath) { Read-LauncherStoredRunManifest -ManifestPath $RerunManifestPath } else { Select-LauncherStoredRun }
                if (-not $selectedRun) { return }
                $reviewInDocuments = if ($RerunManifestPath -and $NonInteractive) { $false } else { Read-LauncherYesNo -Prompt 'Rouvrir les documents avant la relance ?' -Default $false }
                $runConfig = New-LauncherRerunConfigFromManifest -Manifest $selectedRun -ReviewInDocuments:$reviewInDocuments
                if (-not $runConfig.ContainsKey('RunId')) {
                    $runConfig['RunId'] = [Guid]::NewGuid().ToString('N')
                }
            }
            'saved-session-documents' {
                $selectedScopeFile = if ($startupPlan.PSObject.Properties['InitialScopeFile']) { $startupPlan.InitialScopeFile } else { $ScopeFile }
                $managedScopeFile = if ($startupPlan.PSObject.Properties['ManagedScopeFile']) { $startupPlan.ManagedScopeFile } else { $null }
                $selectedOutputDir = if ($startupPlan.PSObject.Properties['OutputDir'] -and $startupPlan.OutputDir) { $startupPlan.OutputDir } else { $OutputDir }
                $runConfig = Build-DocumentRunConfig -InitialScopeFile $selectedScopeFile -ManagedScopeFilePath $managedScopeFile -ExistingSessionRoot $selectedSessionRoot -LoggingMode $selectedLoggingMode -ProgramName $ProgramName -OutputDir $selectedOutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -EnableGau $EnableGau -EnableWaybackUrls $EnableWaybackUrls -EnableHakrawler $EnableHakrawler -NoInstall ([bool]$NoInstall) -Quiet ([bool]$Quiet) -IncludeApex ([bool]$IncludeApex) -RespectSchemeOnly ([bool]$RespectSchemeOnly) -Resume ([bool]$Resume) -OpenReportOnFinish $OpenReportOnFinish
            }
            default {
                $selectedScopeFile = if ($startupPlan.PSObject.Properties['InitialScopeFile']) { $startupPlan.InitialScopeFile } else { $ScopeFile }
                $managedScopeFile = if ($startupPlan.PSObject.Properties['ManagedScopeFile']) { $startupPlan.ManagedScopeFile } else { $null }
                $selectedOutputDir = if ($startupPlan.PSObject.Properties['OutputDir'] -and $startupPlan.OutputDir) { $startupPlan.OutputDir } else { $OutputDir }
                $runConfig = Build-DocumentRunConfig -InitialScopeFile $selectedScopeFile -ManagedScopeFilePath $managedScopeFile -ExistingSessionRoot $selectedSessionRoot -LoggingMode $selectedLoggingMode -ProgramName $ProgramName -OutputDir $selectedOutputDir -Depth $Depth -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -EnableGau $EnableGau -EnableWaybackUrls $EnableWaybackUrls -EnableHakrawler $EnableHakrawler -NoInstall ([bool]$NoInstall) -Quiet ([bool]$Quiet) -IncludeApex ([bool]$IncludeApex) -RespectSchemeOnly ([bool]$RespectSchemeOnly) -Resume ([bool]$Resume) -OpenReportOnFinish $OpenReportOnFinish
            }
        }

        if (-not $runConfig.ContainsKey('RunId')) {
            $runConfig['RunId'] = [Guid]::NewGuid().ToString('N')
        }
        if (-not $runConfig.ContainsKey('LauncherLogMode') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherLogMode)) {
            $runConfig['LauncherLogMode'] = $selectedLoggingMode
        }
        if ($selectedSessionRoot -and (-not $runConfig.ContainsKey('LauncherSessionRoot') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherSessionRoot))) {
            $runConfig['LauncherSessionRoot'] = $selectedSessionRoot
        }
        if ($selectedSessionId -and (-not $runConfig.ContainsKey('LauncherSessionId') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherSessionId))) {
            $runConfig['LauncherSessionId'] = $selectedSessionId
        }
        if (-not $runConfig.ContainsKey('LauncherSessionRoot') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherSessionRoot)) {
            $runConfig['LauncherSessionRoot'] = Get-LauncherUniqueSessionDirectory -Suffix '-adhoc'
        }
        if (-not $runConfig.ContainsKey('LauncherLogRoot') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherLogRoot)) {
            $runConfig['LauncherLogRoot'] = Get-LauncherPlannedLogRoot -RunConfig $runConfig
        }

        $scopePreview = if ($runConfig.ContainsKey('ScopePreview')) { $runConfig.ScopePreview } else { Read-ScopeFile -Path $runConfig.ScopeFile -IncludeApex:([bool]$runConfig.IncludeApex) }
        Show-ScopePreview -ScopeItems $scopePreview
        Show-LauncherConfigPreview -RunConfig $runConfig
        Show-LauncherPreRunSummary -ScopeItems $scopePreview -RunConfig $runConfig
        if ($startupPlan.Action -in @('console', 'rerun') -and -not ($RerunManifestPath -and $NonInteractive)) {
            if (-not (Read-LauncherYesNo -Prompt 'Confirmer le lancement ?' -Default $true)) { return }
        } else {
            Write-Host ''
            Write-Host 'Configuration validee. Demarrage automatique de la collecte.' -ForegroundColor Green
        }
    }

    if (-not $runConfig.ContainsKey('RunId')) {
        $runConfig['RunId'] = [Guid]::NewGuid().ToString('N')
    }
    if (-not $runConfig.ContainsKey('LauncherLogMode') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherLogMode)) {
        $runConfig['LauncherLogMode'] = Get-LauncherDefaultLoggingMode
    }
    if (-not $runConfig.ContainsKey('LauncherSessionRoot') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherSessionRoot)) {
        $runConfig['LauncherSessionRoot'] = Get-LauncherUniqueSessionDirectory -Suffix '-adhoc'
    }
    if (-not $runConfig.ContainsKey('LauncherLogRoot') -or [string]::IsNullOrWhiteSpace([string]$runConfig.LauncherLogRoot)) {
        $runConfig['LauncherLogRoot'] = Get-LauncherPlannedLogRoot -RunConfig $runConfig
    }

    $runStartedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    try {
        $null = Start-LauncherLoggingContext -RunConfig $runConfig
        Write-LauncherDiagnosticLog -Message ("Session active: {0}" -f [string]$runConfig.LauncherSessionRoot)
        Write-LauncherDiagnosticLog -Message ("Scope selectionne: {0}" -f [string]$runConfig.ScopeFile)
        Write-LauncherDiagnosticLog -Message ("Dossier de sortie: {0}" -f [string]$runConfig.OutputDir)
        Write-LauncherDiagnosticLog -Message ("Mode de logs: {0}" -f [string]$runConfig.LauncherLogMode)
        Write-LauncherDiagnosticLog -Message ("Resume={0} Gau={1} Wayback={2} Hakrawler={3}" -f [bool]$runConfig.Resume, [bool]$runConfig.EnableGau, [bool]$runConfig.EnableWaybackUrls, [bool]$runConfig.EnableHakrawler) -Level DEBUG

        $invokeParams = Get-LauncherInvokeParams -RunConfig $runConfig
        Write-LauncherDiagnosticLog -Message ("Invocation ScopeForge avec {0} parametres." -f $invokeParams.Count)
        Show-LauncherInvokeDebugPanel -RunConfig $runConfig -InvokeParams $invokeParams
        $result = Invoke-BugBountyRecon @invokeParams
        Write-LauncherDiagnosticLog -Message ("Execution terminee. OutputDir={0}" -f [string]$result.OutputDir)
    } catch {
        Write-LauncherDiagnosticLog -Message ("Echec launcher/run: {0}" -f $_.Exception.Message) -Level ERROR
        $configIssues = @(Get-LauncherConfigIssues -Exception $_.Exception)
        if ($configIssues.Count -gt 0) {
            Show-LauncherConfigIssues -Issues $configIssues
            if (Test-LauncherBootstrapContext) {
                Write-Host 'Relance le bootstrap avec -Update si tu veux écraser une copie locale potentiellement obsolète.' -ForegroundColor Yellow
            }
            return
        }

        if ($_.Exception.Message -like "*parameter 'Quiet'*" -and $_.Exception.Message -like "*System.String*") {
            Show-LauncherConfigIssues -Issues @(
                New-LauncherConfigIssue -Field 'quiet' -Value 'System.String' -Problem 'Un launcher obsolète ou un appel interne invalide a tenté d''envoyer une chaîne vers un bool/switch.' -Example '"quiet": false'
            )
            if (Test-LauncherBootstrapContext) {
                Write-Host 'Relance le bootstrap avec -Update pour retélécharger Launch-ScopeForge.ps1 et ScopeForge.ps1.' -ForegroundColor Yellow
            }
            return
        }

        throw
    } finally {
        Stop-LauncherLoggingContext
    }

    if ($runConfig.ContainsKey('LauncherSessionRoot') -and $runConfig.LauncherSessionRoot) {
        $sessionUpdate = @{
            display_name  = $(if ($runConfig.ContainsKey('ProgramName') -and $runConfig.ProgramName) { [string]$runConfig.ProgramName } else { [System.IO.Path]::GetFileName([string]$runConfig.LauncherSessionRoot) })
            scope_path    = $(if ($runConfig.ContainsKey('ScopeFile')) { [string]$runConfig.ScopeFile } else { $null })
            settings_path = $(if ($runConfig.ContainsKey('LauncherSessionRoot')) { Join-Path ([string]$runConfig.LauncherSessionRoot) '02-run-settings.json' } else { $null })
            readme_path   = $(if ($runConfig.ContainsKey('LauncherSessionRoot')) { Join-Path ([string]$runConfig.LauncherSessionRoot) '00-START-HERE.txt' } else { $null })
            logs_root     = $(if ($runConfig.ContainsKey('LauncherSessionRoot')) { Join-Path ([string]$runConfig.LauncherSessionRoot) 'logs' } else { $null })
            logging_mode  = $(if ($runConfig.ContainsKey('LauncherLogMode')) { [string]$runConfig.LauncherLogMode } else { Get-LauncherDefaultLoggingMode })
            last_output_dir = $result.OutputDir
            last_log_dir  = $(if ($runConfig.ContainsKey('LauncherLogRoot')) { [string]$runConfig.LauncherLogRoot } else { $null })
            last_used_utc = [DateTimeOffset]::UtcNow.ToString('o')
            note          = 'SESSION'
        }
        $sessionRecord = Update-LauncherSessionMetadata -SessionRoot ([string]$runConfig.LauncherSessionRoot) -Values $sessionUpdate
        Set-LauncherSelectedSession -SessionId $sessionRecord.session_id
        $runConfig['LauncherSessionId'] = $sessionRecord.session_id
    }

    $runManifest = Save-LauncherRunManifest -RunConfig $runConfig -Result $result -RunStartedAtUtc $runStartedAtUtc -RunEndedAtUtc ([DateTimeOffset]::UtcNow.ToString('o'))
    $recentScopePath = Get-LauncherRecentScopeUpdatePath -RunConfig $runConfig
    if (-not [string]::IsNullOrWhiteSpace([string]$recentScopePath)) {
        $null = Update-LauncherRecentScopes -ScopePath $recentScopePath -LastOutputDir $result.OutputDir -DisplayName ([System.IO.Path]::GetFileNameWithoutExtension([string]$recentScopePath))
    }
    $result | Add-Member -NotePropertyName LauncherSessionRoot -NotePropertyValue $runConfig.LauncherSessionRoot -Force
    $result | Add-Member -NotePropertyName LauncherLogRoot -NotePropertyValue $runConfig.LauncherLogRoot -Force
    $result | Add-Member -NotePropertyName LauncherLogMode -NotePropertyValue $runConfig.LauncherLogMode -Force
    $result | Add-Member -NotePropertyName RunManifest -NotePropertyValue $runManifest -Force
    Show-RunSummaryDashboard -Result $result
    Show-NextActionsPanel -Result $result
    Show-InterestingSummary -Result $result
    Show-ErrorSummaryPanel -Result $result
    Show-OutputPaths -Result $result

    if ($runConfig.OpenReportOnFinish) {
        Open-LauncherPath -Path (Join-Path $result.OutputDir 'reports/report.html')
    }

    if ((-not $NonInteractive) -and $showPostRunMenu) {
        Show-PostRunMenu -Result $result
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Start-ScopeForgeLauncher @PSBoundParameters
}
