[CmdletBinding()]
param(
    [string]$ScopeFile,
    [int]$Depth = 3,
    [string]$OutputDir = './output',
    [string]$ProgramName = 'default-program',
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
    [switch]$ExportHtml,
    [switch]$ExportCsv,
    [switch]$ExportJson,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ScopeForgeScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$script:ScopeForgeContext = $null
$script:ScopeForgeToolHelpCache = @{}
$script:ScopeForgeProgressState = $null
$script:ScopeForgeConsoleState = [ordered]@{
    LogWriteFailureShown = $false
}
$script:ScopeForgeStageWeights = [ordered]@{
    '1' = 10
    '2' = 10
    '3' = 25
    '4' = 25
    '5' = 20
    '6' = 10
}

function Format-ScopeForgeDuration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][TimeSpan]$Duration)

    $safeDuration = if ($Duration.TotalSeconds -lt 0) { [TimeSpan]::Zero } else { $Duration }
    if ($safeDuration.TotalHours -ge 1) {
        return ('{0}h {1}m {2}s' -f [int]$safeDuration.TotalHours, $safeDuration.Minutes, $safeDuration.Seconds)
    }
    if ($safeDuration.TotalMinutes -ge 1) {
        return ('{0}m {1}s' -f [int]$safeDuration.TotalMinutes, $safeDuration.Seconds)
    }
    return ('{0}s' -f [Math]::Max([int][Math]::Round($safeDuration.TotalSeconds), 0))
}

function Initialize-ScopeForgeProgressState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Layout)

    $startedAt = [DateTimeOffset]::UtcNow
    $samples = [System.Collections.Generic.List[object]]::new()
    $samples.Add([pscustomobject]@{
        At      = $startedAt
        Percent = 0
    }) | Out-Null

    $script:ScopeForgeProgressState = [ordered]@{
        StartedAtUtc    = $startedAt
        Layout          = $Layout
        StageStep       = 0
        StageTitle      = ''
        StagePercent    = 0
        StatusText      = ''
        OverallPercent  = 0
        LastMessage     = ''
        LastEtaSeconds  = $null
        LastProgressAtUtc = $startedAt
        ProgressSamples = $samples
    }
}

function Get-ScopeForgeCompactProgressMessage {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Message,
        [int]$MaxLength = 220
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return '' }
    $singleLine = (($Message -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim()
    if ($singleLine.Length -le $MaxLength) { return $singleLine }
    return ($singleLine.Substring(0, $MaxLength - 3) + '...')
}

function Register-ScopeForgeProgressSample {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$OverallPercent)

    if (-not $script:ScopeForgeProgressState) { return }

    $safePercent = [Math]::Max([Math]::Min($OverallPercent, 100), 0)
    $now = [DateTimeOffset]::UtcNow
    $samples = $script:ScopeForgeProgressState.ProgressSamples
    $lastSample = if ($samples.Count -gt 0) { $samples[$samples.Count - 1] } else { $null }

    $shouldAdd = $false
    if (-not $lastSample) {
        $shouldAdd = $true
    } elseif ($safePercent -gt [int]$lastSample.Percent) {
        $shouldAdd = $true
    } else {
        $ageSeconds = ($now - [DateTimeOffset]$lastSample.At).TotalSeconds
        if ($ageSeconds -ge 15) {
            $shouldAdd = $true
        }
    }

    if ($shouldAdd) {
        $samples.Add([pscustomobject]@{
            At      = $now
            Percent = $safePercent
        }) | Out-Null
    }

    while ($samples.Count -gt 30) {
        $samples.RemoveAt(0)
    }
}

function Get-ScopeForgeOverallProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][int]$StagePercent
    )

    $safeStep = [Math]::Max([Math]::Min($Step, 6), 0)
    $safeStagePercent = [Math]::Max([Math]::Min($StagePercent, 100), 0)

    if (-not $script:ScopeForgeStageWeights) {
        return $safeStagePercent
    }

    $completedWeight = 0
    $currentWeight = 0

    foreach ($entry in ($script:ScopeForgeStageWeights.GetEnumerator() | Sort-Object { [int]$_.Key })) {
        $entryStep = [int]$entry.Key
        $entryWeight = [int]$entry.Value

        if ($entryStep -lt $safeStep) {
            $completedWeight += $entryWeight
            continue
        }

        if ($entryStep -eq $safeStep) {
            $currentWeight = $entryWeight
        }
    }

    $overall = $completedWeight + (($currentWeight * $safeStagePercent) / 100.0)
    return [int][Math]::Round([Math]::Min([Math]::Max($overall, 0), 100))
}

function Get-ScopeForgeEtaText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$OverallPercent)

    if (-not $script:ScopeForgeProgressState) { return 'ETA calcul en cours' }

    $safePercent = [Math]::Max([Math]::Min($OverallPercent, 100), 0)
    if ($safePercent -ge 100) { return 'ETA < 1s' }

    $now = [DateTimeOffset]::UtcNow
    $elapsedSeconds = ($now - $script:ScopeForgeProgressState.StartedAtUtc).TotalSeconds

    if ($safePercent -lt 2 -or $elapsedSeconds -lt 10) {
        return 'ETA calcul en cours'
    }

    $overallRate = if ($elapsedSeconds -gt 0) {
        $safePercent / $elapsedSeconds
    } else {
        0
    }

    $recentRate = 0
    $samples = @($script:ScopeForgeProgressState.ProgressSamples)

    if ($samples.Count -ge 2) {
        $anchor = $null

        for ($i = $samples.Count - 1; $i -ge 0; $i--) {
            $candidate = $samples[$i]
            $candidateAge = ($now - [DateTimeOffset]$candidate.At).TotalSeconds
            if ($candidateAge -ge 120) {
                $anchor = $candidate
                break
            }
        }

        if (-not $anchor) {
            $anchor = $samples[0]
        }

        $percentDelta = $safePercent - [double]$anchor.Percent
        $secondsDelta = ($now - [DateTimeOffset]$anchor.At).TotalSeconds

        if ($percentDelta -gt 0.2 -and $secondsDelta -gt 0) {
            $recentRate = $percentDelta / $secondsDelta
        }
    }

    $blendedRate = 0
    if ($recentRate -gt 0 -and $overallRate -gt 0) {
        $blendedRate = ($recentRate * 0.70) + ($overallRate * 0.30)
    } elseif ($recentRate -gt 0) {
        $blendedRate = $recentRate
    } else {
        $blendedRate = $overallRate
    }

    if ($blendedRate -le 0) {
        return 'ETA calcul en cours'
    }

    $remainingSeconds = (100 - $safePercent) / $blendedRate

    if ($null -ne $script:ScopeForgeProgressState.LastEtaSeconds) {
        $previousEta = [double]$script:ScopeForgeProgressState.LastEtaSeconds
        $delta = [Math]::Abs($remainingSeconds - $previousEta)

        if ($previousEta -gt 0 -and $delta -ge ($previousEta * 0.50)) {
            $remainingSeconds = ($previousEta * 0.45) + ($remainingSeconds * 0.55)
        } else {
            $remainingSeconds = ($previousEta * 0.65) + ($remainingSeconds * 0.35)
        }
    }

    $stallSeconds = ($now - $script:ScopeForgeProgressState.LastProgressAtUtc).TotalSeconds
    if ($stallSeconds -gt 20) {
        $stallPenalty = [Math]::Min((($stallSeconds - 20) * 0.60), 300)
        $remainingSeconds += $stallPenalty
    }

    $remainingSeconds = [Math]::Max([double]$remainingSeconds, 0)
    $script:ScopeForgeProgressState.LastEtaSeconds = $remainingSeconds

    return ('ETA ~ {0}' -f (Format-ScopeForgeDuration -Duration ([TimeSpan]::FromSeconds($remainingSeconds))))
}

function Get-ScopeForgeProgressLocationHint {
    [CmdletBinding()]
    param()

    if (-not $script:ScopeForgeProgressState) { return '' }
    $layout = $script:ScopeForgeProgressState.Layout
    if (-not $layout) { return '' }

    return ('Logs: {0} | Data: {1} | Report: {2}' -f $layout.MainLog, $layout.Normalized, $layout.ReportHtml)
}

function Update-ScopeForgeProgressDisplay {
    [CmdletBinding()]
    param(
        [int]$Step = 0,
        [string]$Title = '',
        [int]$StagePercent = 0,
        [string]$Status = '',
        [string]$CurrentMessage = ''
    )

    if (-not $script:ScopeForgeProgressState) { return }
    if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Quiet) { return }

    $safeStep = [Math]::Max([Math]::Min($Step, 6), 0)
    $safeStagePercent = [Math]::Max([Math]::Min($StagePercent, 100), 0)

    if (Get-Command -Name 'Get-ScopeForgeOverallProgress' -CommandType Function -ErrorAction SilentlyContinue) {
        $overallPercent = Get-ScopeForgeOverallProgress -Step $safeStep -StagePercent $safeStagePercent
    } else {
        $overallPercent = $safeStagePercent
    }

    $previousOverallPercent = [int]$script:ScopeForgeProgressState.OverallPercent
    if ($overallPercent -gt $previousOverallPercent) {
        $script:ScopeForgeProgressState.LastProgressAtUtc = [DateTimeOffset]::UtcNow
    }

    $script:ScopeForgeProgressState.StageStep = $safeStep
    $script:ScopeForgeProgressState.StageTitle = $Title
    $script:ScopeForgeProgressState.StagePercent = $safeStagePercent
    $script:ScopeForgeProgressState.OverallPercent = $overallPercent
    $script:ScopeForgeProgressState.StatusText = $Status

    if (-not [string]::IsNullOrWhiteSpace($CurrentMessage)) {
        $script:ScopeForgeProgressState.LastMessage = Get-ScopeForgeCompactProgressMessage -Message $CurrentMessage
    }

    if (Get-Command -Name 'Register-ScopeForgeProgressSample' -CommandType Function -ErrorAction SilentlyContinue) {
        Register-ScopeForgeProgressSample -OverallPercent $overallPercent
    }

    $etaText = if (Get-Command -Name 'Get-ScopeForgeEtaText' -CommandType Function -ErrorAction SilentlyContinue) {
        Get-ScopeForgeEtaText -OverallPercent $overallPercent
    } else {
        'ETA calcul en cours'
    }

    $activity = if ($safeStep -gt 0 -and -not [string]::IsNullOrWhiteSpace($Title)) {
        ('[{0}/6] {1}' -f $safeStep, $Title)
    } else {
        'ScopeForge'
    }

    $statusText = if ([string]::IsNullOrWhiteSpace($Status)) {
        ('Global {0}% | {1} | Phase {2}/6' -f $overallPercent, $etaText, $(if ($safeStep -gt 0) { $safeStep } else { 0 }))
    } else {
        ('Global {0}% | {1} | Phase {2}/6 | {3}' -f $overallPercent, $etaText, $(if ($safeStep -gt 0) { $safeStep } else { 0 }), $Status)
    }

    $currentOperation = $script:ScopeForgeProgressState.LastMessage
    $locationHint = Get-ScopeForgeProgressLocationHint

    if (-not [string]::IsNullOrWhiteSpace($locationHint)) {
        $progressMessage = if ([string]::IsNullOrWhiteSpace($currentOperation)) {
            $locationHint
        } else {
            "$currentOperation | $locationHint"
        }

        $currentOperation = Get-ScopeForgeCompactProgressMessage -Message $progressMessage
    }

    try {
        Write-Progress -Id 1 -Activity $activity -PercentComplete $overallPercent -Status $statusText -CurrentOperation $currentOperation
    } catch {
    }
}

function Set-ScopeForgeProgressMessage {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    if (-not $script:ScopeForgeProgressState) { return }

    $script:ScopeForgeProgressState.LastMessage = Get-ScopeForgeCompactProgressMessage -Message $Message
    Update-ScopeForgeProgressDisplay `
        -Step $script:ScopeForgeProgressState.StageStep `
        -Title $script:ScopeForgeProgressState.StageTitle `
        -StagePercent $script:ScopeForgeProgressState.StagePercent `
        -CurrentMessage $script:ScopeForgeProgressState.LastMessage
}

function Complete-ScopeForgeProgress {
    [CmdletBinding()]
    param()

    if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Quiet) { return }

    try {
        Write-Progress -Id 1 -Activity 'ScopeForge' -PercentComplete 100 -Status 'Global 100% | Analyse terminee' -Completed
    } catch {
    }
}

function Write-ScopeForgeConsolePathsHint {
    [CmdletBinding()]
    param()

    if (-not $script:ScopeForgeContext) { return }

    if (-not $script:ScopeForgeContext.PSObject.Properties['ConsolePathsHintShown']) {
        Add-Member -InputObject $script:ScopeForgeContext -MemberType NoteProperty -Name ConsolePathsHintShown -Value $false -Force
    }

    if ($script:ScopeForgeContext.ConsolePathsHintShown) { return }

    $layout = $script:ScopeForgeContext.Layout
    Write-Host ("Analyse en cours. Logs : {0}" -f $layout.MainLog) -ForegroundColor DarkGray
    Write-Host ("Erreurs : {0}" -f $layout.ErrorsLog) -ForegroundColor DarkGray
    Write-Host ("Exclusions : {0}" -f $layout.ExclusionsLog) -ForegroundColor DarkGray
    Write-Host ("Donnees brutes : {0}" -f $layout.Raw) -ForegroundColor DarkGray
    Write-Host ("Donnees normalisees : {0}" -f $layout.Normalized) -ForegroundColor DarkGray
    Write-Host ("Rapports : {0}" -f $layout.Reports) -ForegroundColor DarkGray

    $script:ScopeForgeContext.ConsolePathsHintShown = $true
}

function Test-ExclusionTokenInText {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Token)) { return $false }

    $safeText = $Text.ToLowerInvariant()
    $safeToken = $Token.Trim().ToLowerInvariant()
    $pattern = '(?<![a-z0-9])' + [regex]::Escape($safeToken) + '(?![a-z0-9])'

    return [regex]::IsMatch($safeText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Write-CompactedExclusionConsoleMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Record)

    if (-not $script:ScopeForgeContext) { return }

    if (-not $script:ScopeForgeContext.PSObject.Properties['ExclusionConsoleTracker']) {
        Add-Member -InputObject $script:ScopeForgeContext -MemberType NoteProperty -Name ExclusionConsoleTracker -Value @{} -Force
    }

    if (-not $script:ScopeForgeContext.PSObject.Properties['ExclusionConsoleSampleLimit']) {
        Add-Member -InputObject $script:ScopeForgeContext -MemberType NoteProperty -Name ExclusionConsoleSampleLimit -Value 3 -Force
    }

    $token = if ($Record.Token) { [string]$Record.Token } else { '<empty>' }
    $trackerKey = '{0}|{1}|{2}' -f $Record.Phase, $Record.ScopeId, $token

    if (-not $script:ScopeForgeContext.ExclusionConsoleTracker.ContainsKey($trackerKey)) {
        $script:ScopeForgeContext.ExclusionConsoleTracker[$trackerKey] = @{
            Shown      = 0
            Suppressed = 0
        }
    }

    $tracker = $script:ScopeForgeContext.ExclusionConsoleTracker[$trackerKey]
    $sampleMessage = ('[{0}] Excluded by token ''{1}'' on {2}: {3}' -f $Record.Phase, $token, $Record.MatchedOn, $Record.Target)

    if ([int]$tracker['Shown'] -lt [int]$script:ScopeForgeContext.ExclusionConsoleSampleLimit) {
        $tracker['Shown'] = [int]$tracker['Shown'] + 1
        Write-Host $sampleMessage -ForegroundColor DarkYellow
        Set-ScopeForgeProgressMessage -Message $sampleMessage
        return
    }

    $tracker['Suppressed'] = [int]$tracker['Suppressed'] + 1
    if (($tracker['Suppressed'] -eq 1) -or (($tracker['Suppressed'] % 25) -eq 0)) {
        $summary = ('[{0}] Beaucoup d exclusions pour le token ''{1}'' sur {2}. Console compactee; voir {3} (supprimees console={4})' -f $Record.Phase, $token, $Record.ScopeId, $script:ScopeForgeContext.Layout.ExclusionsLog, $tracker['Suppressed'])
        Write-Host $summary -ForegroundColor DarkYellow
        Set-ScopeForgeProgressMessage -Message $summary
    }
}

function Resolve-AbsolutePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-PlatformInfo {
    [CmdletBinding()]
    param()

    $os = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'darwin' } else { throw 'Unsupported OS.' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        'X86' { '386' }
        default { throw "Unsupported architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
    }

    [pscustomobject]@{
        Os           = $os
        Architecture = $arch
        Description  = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
}

function Get-CompressedArchiveKind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath)

    if ($ArchivePath -match '(?i)\.zip$') { return 'zip' }
    if ($ArchivePath -match '(?i)(?:\.tar\.gz|\.tgz)$') { return 'tar-gzip' }
    return 'unsupported'
}

function Test-ReleaseAssetNameTokenMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)][string[]]$Aliases
    )

    $tokens = @(
        $AssetName.ToLowerInvariant() -split '[^a-z0-9]+' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    foreach ($alias in $Aliases) {
        if ($tokens -contains $alias.ToLowerInvariant()) { return $true }
    }
    return $false
}

function Select-ToolReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ReleaseAssets,
        [Parameter(Mandatory)][pscustomobject]$PlatformInfo
    )

    $platformAliases = switch ($PlatformInfo.Os) {
        'windows' { @('windows', 'win') }
        'linux' { @('linux') }
        'darwin' { @('darwin', 'macos', 'mac') }
        default { throw "Unsupported bootstrap platform: $($PlatformInfo.Os)" }
    }
    $archAliases = switch ($PlatformInfo.Architecture) {
        'amd64' { @('amd64', 'x86_64', 'x64') }
        'arm64' { @('arm64', 'aarch64') }
        '386' { @('386', 'x86', 'i386') }
        default { @($PlatformInfo.Architecture) }
    }

    return @(
        $ReleaseAssets |
        Where-Object {
            $assetName = [string]$_.name
            (Test-ReleaseAssetNameTokenMatch -AssetName $assetName -Aliases @($ToolName)) -and
            (Test-ReleaseAssetNameTokenMatch -AssetName $assetName -Aliases $platformAliases) -and
            (Test-ReleaseAssetNameTokenMatch -AssetName $assetName -Aliases $archAliases)
        } |
        Select-Object -First 1
    )[0]
}

function Get-ToolBootstrapFailureSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    if ($ToolName -eq 'hakrawler' -and $FailureMessage -match '(?i)release assets') {
        return "Optional tool 'hakrawler' is unavailable: automatic bootstrap did not find a compatible release asset. Supplemental crawl is disabled, but the main analysis continues with subfinder/httpx/katana. To silence this message, set enableHakrawler=false."
    }

    if ($FailureMessage -match '(?i)(api\.github\.com|githubusercontent\.com|github\.com:443|proxy|offline|firewall|timed out|timeout|No such host|Name or service not known|Unable to connect|connection.*failed)') {
        return ("Optional tool '{0}' is unavailable: GitHub download failed or is blocked (offline mode, firewall, or proxy issue). Related enrichment will be skipped. Details: {1}" -f $ToolName, $FailureMessage)
    }
    if ($FailureMessage -match '(?i)Unsupported archive format') {
        return ("Optional tool '{0}' is unavailable: downloaded archive format is unsupported in the current runtime. Related enrichment will be skipped. Details: {1}" -f $ToolName, $FailureMessage)
    }
    if ($FailureMessage -match '(?i)Unable to select a release asset') {
        return ("Optional tool '{0}' is unavailable: no release asset matched the detected platform. Related enrichment will be skipped. Details: {1}" -f $ToolName, $FailureMessage)
    }

    return ("Optional tool '{0}' is unavailable: {1}. Related enrichment will be skipped." -f $ToolName, $FailureMessage)
}

function Get-OutputLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputDir)

    $root = Resolve-AbsolutePath -Path $OutputDir
    [pscustomobject]@{
        Root                 = $root
        Logs                 = Join-Path $root 'logs'
        Raw                  = Join-Path $root 'raw'
        Normalized           = Join-Path $root 'normalized'
        Reports              = Join-Path $root 'reports'
        Temp                 = Join-Path $root 'temp'
        ToolsRoot            = Join-Path $root 'tools'
        ToolsBin             = Join-Path (Join-Path $root 'tools') 'bin'
        ToolsDownloads       = Join-Path (Join-Path $root 'tools') 'downloads'
        ToolsExtracted       = Join-Path (Join-Path $root 'tools') 'extracted'
        MainLog              = Join-Path (Join-Path $root 'logs') 'main.log'
        ErrorsLog            = Join-Path (Join-Path $root 'logs') 'errors.log'
        ExclusionsLog        = Join-Path (Join-Path $root 'logs') 'exclusions.log'
        ToolsLog             = Join-Path (Join-Path $root 'logs') 'tools.log'
        HttpxBatchLog        = Join-Path (Join-Path $root 'logs') 'httpx-batches.log'
        KatanaSeedStatsLog   = Join-Path (Join-Path $root 'logs') 'katana-seeds.log'
        SubfinderRaw         = Join-Path (Join-Path $root 'raw') 'subfinder_raw.txt'
        GauRaw               = Join-Path (Join-Path $root 'raw') 'gau_raw.txt'
        WaybackRaw           = Join-Path (Join-Path $root 'raw') 'waybackurls_raw.txt'
        HttpxRaw             = Join-Path (Join-Path $root 'raw') 'httpx_raw.jsonl'
        HttpxEmptyBatchInput = Join-Path (Join-Path $root 'raw') 'httpx_empty_batch_input.txt'
        HttpxEmptyBatchStdOut = Join-Path (Join-Path $root 'raw') 'httpx_empty_batch_stdout.jsonl'
        HttpxEmptyBatchStdErr = Join-Path (Join-Path $root 'raw') 'httpx_empty_batch_stderr.log'
        HttpxEmptyBatchMeta  = Join-Path (Join-Path $root 'raw') 'httpx_empty_batch_context.json'
        KatanaRaw            = Join-Path (Join-Path $root 'raw') 'katana_raw.jsonl'
        HakrawlerRaw         = Join-Path (Join-Path $root 'raw') 'hakrawler_raw.txt'
        ScopeNormalized      = Join-Path (Join-Path $root 'normalized') 'scope_normalized.json'
        HostsAllJson         = Join-Path (Join-Path $root 'normalized') 'hosts_all.json'
        HostsAllCsv          = Join-Path (Join-Path $root 'normalized') 'hosts_all.csv'
        HostsLiveJson        = Join-Path (Join-Path $root 'normalized') 'hosts_live.json'
        LiveTargetsJson      = Join-Path (Join-Path $root 'normalized') 'live_targets.json'
        LiveTargetsCsv       = Join-Path (Join-Path $root 'normalized') 'live_targets.csv'
        UrlsDiscoveredJson   = Join-Path (Join-Path $root 'normalized') 'urls_discovered.json'
        UrlsDiscoveredCsv    = Join-Path (Join-Path $root 'normalized') 'urls_discovered.csv'
        FilteredUrlsJson     = Join-Path (Join-Path $root 'normalized') 'urls_filtered.json'
        FilteredUrlsCsv      = Join-Path (Join-Path $root 'normalized') 'urls_filtered.csv'
        NoiseUrlsJson        = Join-Path (Join-Path $root 'normalized') 'urls_noise_removed.json'
        NoiseUrlsCsv         = Join-Path (Join-Path $root 'normalized') 'urls_noise_removed.csv'
        InterestingUrlsJson  = Join-Path (Join-Path $root 'normalized') 'interesting_urls.json'
        InterestingUrlsCsv   = Join-Path (Join-Path $root 'normalized') 'interesting_urls.csv'
        ReviewableUrlsJson   = Join-Path (Join-Path $root 'normalized') 'reviewable_urls.json'
        ReviewableUrlsCsv    = Join-Path (Join-Path $root 'normalized') 'reviewable_urls.csv'
        ShortlistJson        = Join-Path (Join-Path $root 'normalized') 'shortlist.json'
        InterestingFamiliesJson = Join-Path (Join-Path $root 'normalized') 'interesting_families.json'
        EndpointsUniqueTxt   = Join-Path (Join-Path $root 'normalized') 'endpoints_unique.txt'
        SummaryJson          = Join-Path (Join-Path $root 'reports') 'summary.json'
        SummaryCsv           = Join-Path (Join-Path $root 'reports') 'summary.csv'
        ReportHtml           = Join-Path (Join-Path $root 'reports') 'report.html'
        RunManifestJson      = Join-Path (Join-Path $root 'reports') 'run-manifest.json'
        FrozenScopeJson      = Join-Path (Join-Path $root 'reports') 'scope-frozen.json'
        FrozenSettingsJson   = Join-Path (Join-Path $root 'reports') 'run-settings-frozen.json'
        TriageMarkdown       = Join-Path (Join-Path $root 'reports') 'triage.md'
        ShortlistMarkdown    = Join-Path (Join-Path $root 'reports') 'shortlist.md'
    }
}

function Initialize-OutputDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Layout)

    foreach ($directory in @($Layout.Root, $Layout.Logs, $Layout.Raw, $Layout.Normalized, $Layout.Reports, $Layout.Temp, $Layout.ToolsRoot, $Layout.ToolsBin, $Layout.ToolsDownloads, $Layout.ToolsExtracted)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
    }

    foreach ($file in @($Layout.MainLog, $Layout.ErrorsLog, $Layout.ExclusionsLog, $Layout.ToolsLog, $Layout.HttpxBatchLog, $Layout.KatanaSeedStatsLog)) {
        if (-not (Test-Path -LiteralPath $file)) {
            $null = New-Item -ItemType File -Path $file -Force
        }
    }
}

function New-ScopeForgeContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Layout,
        [Parameter(Mandatory)][string]$ProgramName,
        [Parameter(Mandatory)][bool]$Quiet,
        [Parameter(Mandatory)][bool]$ExportJsonEnabled,
        [Parameter(Mandatory)][bool]$ExportCsvEnabled,
        [Parameter(Mandatory)][bool]$ExportHtmlEnabled
    )

    [pscustomobject]@{
        Layout                      = $Layout
        ProgramName                 = $ProgramName
        Quiet                       = $Quiet
        ExportJsonEnabled           = $ExportJsonEnabled
        ExportCsvEnabled            = $ExportCsvEnabled
        ExportHtmlEnabled           = $ExportHtmlEnabled
        Exclusions                  = [System.Collections.Generic.List[object]]::new()
        Errors                      = [System.Collections.Generic.List[object]]::new()
        Warnings                    = [System.Collections.Generic.List[string]]::new()
        Triage                      = $null
        TriageState                 = $null
        ExclusionConsoleTracker     = @{}
        ExclusionConsoleSampleLimit = 3
        ConsolePathsHintShown       = $false
    }
}

function Write-ReconLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'TOOL', 'EXCLUDED', 'VERBOSE')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Path,
        [switch]$NoConsole
    )

    $timestamp = [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
    $entry = '{0} [{1}] {2}' -f $timestamp, $Level, $Message
    $targetPath = if ($Path) {
        $Path
    } elseif ($script:ScopeForgeContext) {
        switch ($Level) {
            'ERROR' { $script:ScopeForgeContext.Layout.ErrorsLog }
            'TOOL' { $script:ScopeForgeContext.Layout.ToolsLog }
            'EXCLUDED' { $script:ScopeForgeContext.Layout.ExclusionsLog }
            default { $script:ScopeForgeContext.Layout.MainLog }
        }
    }

    if ($targetPath) {
        try {
            Add-Content -LiteralPath $targetPath -Value $entry -Encoding utf8
        } catch {
            if (-not $script:ScopeForgeConsoleState.LogWriteFailureShown) {
                $script:ScopeForgeConsoleState.LogWriteFailureShown = $true
                Write-Host ("[LogGuard] Impossible d'ecrire dans '{0}'. Le run continue en console. Detail: {1}" -f $targetPath, $_.Exception.Message) -ForegroundColor Yellow
            }
        }

        if (($Level -eq 'ERROR') -and $script:ScopeForgeContext -and ($targetPath -ne $script:ScopeForgeContext.Layout.MainLog)) {
            try {
                Add-Content -LiteralPath $script:ScopeForgeContext.Layout.MainLog -Value $entry -Encoding utf8
            } catch {
            }
        }
    }

    if ($NoConsole) { return }
    if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Quiet -and ($Level -notin @('WARN', 'ERROR'))) { return }

    switch ($Level) {
        'INFO' { Write-Host $Message -ForegroundColor Cyan }
        'WARN' { Write-Host $Message -ForegroundColor Yellow }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'TOOL' { Write-Host $Message -ForegroundColor DarkGray }
        'EXCLUDED' { Write-Host $Message -ForegroundColor DarkYellow }
        'VERBOSE' { Write-Host $Message -ForegroundColor DarkGray }
    }

    if ($Level -in @('INFO', 'WARN', 'ERROR', 'TOOL')) {
        Set-ScopeForgeProgressMessage -Message $Message
    }
}

function Write-StageBanner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Step, [Parameter(Mandatory)][string]$Title)

    Update-ScopeForgeProgressDisplay -Step $Step -Title $Title -StagePercent 0 -Status 'Initialisation de l etape' -CurrentMessage $Title
    Write-ReconLog -Level INFO -Message ('[{0}/6] {1}' -f $Step, $Title)
}

function Write-StageProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][int]$Percent,
        [string]$Status = ''
    )

    Update-ScopeForgeProgressDisplay -Step $Step -Title $Title -StagePercent $Percent -Status $Status -CurrentMessage $Status
}

function Resolve-ToolPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ToolsBin)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($IsWindows) { $candidates.Add((Join-Path $ToolsBin "$Name.exe")) }
    $candidates.Add((Join-Path $ToolsBin $Name))

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    return $(if ($command) { $command.Source } else { $null })
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [string]$StdOutPath,
        [string]$StdErrPath,
        [switch]$IgnoreExitCode
    )

    $resolvedFilePath = if (Test-Path -LiteralPath $FilePath) {
        (Resolve-Path -LiteralPath $FilePath).Path
    } else {
        $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { throw "Executable not found: $FilePath" }
        $command.Source
    }

    $filteredArguments = @($Arguments | Where-Object { $null -ne $_ -and $_ -ne '' })
    $createdStdOut = $false
    $createdStdErr = $false
    if (-not $StdOutPath) { $StdOutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-{0}.stdout" -f ([Guid]::NewGuid().ToString('N'))); $createdStdOut = $true }
    if (-not $StdErrPath) { $StdErrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-{0}.stderr" -f ([Guid]::NewGuid().ToString('N'))); $createdStdErr = $true }

    $displayArguments = ($filteredArguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
    Write-ReconLog -Level TOOL -Message ("EXEC {0} {1}" -f $resolvedFilePath, $displayArguments)

    $process = Start-Process -FilePath $resolvedFilePath -ArgumentList $filteredArguments -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath -PassThru -NoNewWindow

    $commandStartedAt = [DateTimeOffset]::UtcNow
    $nextHeartbeatAt = $commandStartedAt

    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 500

        $now = [DateTimeOffset]::UtcNow
        $elapsedSeconds = ($now - $commandStartedAt).TotalSeconds

        if ($elapsedSeconds -ge $TimeoutSeconds) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
            throw "Command timed out after $TimeoutSeconds seconds: $resolvedFilePath"
        }

        if ($script:ScopeForgeProgressState -and $now -ge $nextHeartbeatAt) {
            $commandName = [System.IO.Path]::GetFileName($resolvedFilePath)
            $heartbeatMessage = ("{0} en cours depuis {1} | garde-fou timeout {2}s" -f $commandName, (Format-ScopeForgeDuration -Duration ([TimeSpan]::FromSeconds($elapsedSeconds))), $TimeoutSeconds)

            Update-ScopeForgeProgressDisplay `
                -Step $script:ScopeForgeProgressState.StageStep `
                -Title $script:ScopeForgeProgressState.StageTitle `
                -StagePercent $script:ScopeForgeProgressState.StagePercent `
                -Status $script:ScopeForgeProgressState.StatusText `
                -CurrentMessage $heartbeatMessage

            $nextHeartbeatAt = $now.AddSeconds(1)
        }
    }

    $process.WaitForExit()

    $stdout = if (Test-Path -LiteralPath $StdOutPath) { Get-Content -LiteralPath $StdOutPath -Raw -Encoding utf8 } else { '' }
    $stderr = if (Test-Path -LiteralPath $StdErrPath) { Get-Content -LiteralPath $StdErrPath -Raw -Encoding utf8 } else { '' }
    if ($stderr) { Write-ReconLog -Level TOOL -Message ($stderr.Trim()) }
    if (($process.ExitCode -ne 0) -and -not $IgnoreExitCode) { throw "Command failed with exit code $($process.ExitCode): $resolvedFilePath" }

    $result = [pscustomobject]@{
        ExitCode   = $process.ExitCode
        StdOut     = $stdout
        StdErr     = $stderr
        StdOutPath = $StdOutPath
        StdErrPath = $StdErrPath
        FilePath   = $resolvedFilePath
        Arguments  = $filteredArguments
    }

    if ($createdStdOut -and (Test-Path -LiteralPath $StdOutPath)) { Remove-Item -LiteralPath $StdOutPath -Force -ErrorAction SilentlyContinue }
    if ($createdStdErr -and (Test-Path -LiteralPath $StdErrPath)) { Remove-Item -LiteralPath $StdErrPath -Force -ErrorAction SilentlyContinue }

    return $result
}

function Invoke-ExternalCommandArgumentSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [switch]$IgnoreExitCode
    )

    $resolvedFilePath = if (Test-Path -LiteralPath $FilePath) {
        (Resolve-Path -LiteralPath $FilePath).Path
    } else {
        $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { throw "Executable not found: $FilePath" }
        $command.Source
    }

    $filteredArguments = @($Arguments | Where-Object { $null -ne $_ -and $_ -ne '' })
    $displayArguments = ($filteredArguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
    Write-ReconLog -Level TOOL -Message ("EXEC {0} {1}" -f $resolvedFilePath, $displayArguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedFilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $filteredArguments) {
        $null = $startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
        throw "Command timed out after $TimeoutSeconds seconds: $resolvedFilePath"
    }

    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($stderr) { Write-ReconLog -Level TOOL -Message ($stderr.Trim()) }
    if (($process.ExitCode -ne 0) -and -not $IgnoreExitCode) { throw "Command failed with exit code $($process.ExitCode): $resolvedFilePath" }

    return [pscustomobject]@{
        ExitCode  = $process.ExitCode
        StdOut    = $stdout
        StdErr    = $stderr
        FilePath  = $resolvedFilePath
        Arguments = $filteredArguments
    }
}

function Get-ToolHelpText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolPath, [int]$TimeoutSeconds = 15)

    $cacheKey = try { [System.IO.Path]::GetFullPath($ToolPath) } catch { $ToolPath }
    if ($script:ScopeForgeToolHelpCache.ContainsKey($cacheKey)) {
        return $script:ScopeForgeToolHelpCache[$cacheKey]
    }

    $helpText = ''
    try {
        $result = Invoke-ExternalCommand -FilePath $ToolPath -Arguments @('-h') -TimeoutSeconds $TimeoutSeconds -IgnoreExitCode
        $helpText = ('{0}`n{1}' -f $result.StdOut, $result.StdErr)
    } catch {
        try {
            $result = Invoke-ExternalCommand -FilePath $ToolPath -Arguments @('--help') -TimeoutSeconds $TimeoutSeconds -IgnoreExitCode
            $helpText = ('{0}`n{1}' -f $result.StdOut, $result.StdErr)
        } catch {
            $helpText = ''
        }
    }

    $script:ScopeForgeToolHelpCache[$cacheKey] = $helpText
    return $helpText
}

function Test-ToolFlagSupport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HelpText, [Parameter(Mandatory)][string]$Flag)

    return $HelpText -and [regex]::IsMatch($HelpText, "(?m)(^|\s){0}(\s|,|$)" -f [regex]::Escape($Flag))
}

function Expand-CompressedArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$DestinationPath)

    if (-not (Test-Path -LiteralPath $DestinationPath)) { $null = New-Item -ItemType Directory -Path $DestinationPath -Force }
    $archiveKind = Get-CompressedArchiveKind -ArchivePath $ArchivePath
    if ($archiveKind -eq 'zip') {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath, $true)
        return [pscustomobject]@{
            ArchiveKind = 'zip'
            Extractor   = 'System.IO.Compression.ZipFile'
        }
    }
    if ($archiveKind -eq 'tar-gzip') {
        $tarCommand = Get-Command -Name 'tar' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $tarCommand) { throw 'Unable to extract tar.gz archive because tar is not available.' }
        $null = Invoke-ExternalCommandArgumentSafe -FilePath $tarCommand.Source -Arguments @('-xzf', $ArchivePath, '-C', $DestinationPath) -TimeoutSeconds 120
        return [pscustomobject]@{
            ArchiveKind = 'tar-gzip'
            Extractor   = $tarCommand.Source
        }
    }
    throw "Unsupported archive format: $ArchivePath"
}

function Install-ExternalTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$BinaryName,
        [Parameter(Mandatory)][pscustomobject]$PlatformInfo,
        [Parameter(Mandatory)][pscustomobject]$Layout,
        [int]$TimeoutSeconds = 60
    )

    $headers = @{ 'User-Agent' = 'ScopeForge/1.0'; 'Accept' = 'application/vnd.github+json' }
    Write-ReconLog -Level TOOL -Message ("BOOTSTRAP {0}: detected os={1} arch={2}" -f $ToolName, $PlatformInfo.Os, $PlatformInfo.Architecture)
    $release = Invoke-RestMethod -Uri ("https://api.github.com/repos/$Repository/releases/latest") -Headers $headers -Method Get -TimeoutSec $TimeoutSeconds
    if (-not $release.assets) { throw "Unable to find release assets for $ToolName." }

    $asset = Select-ToolReleaseAsset -ToolName $ToolName -ReleaseAssets @($release.assets) -PlatformInfo $PlatformInfo
    if (-not $asset) { throw "Unable to select a release asset for $ToolName." }
    Write-ReconLog -Level TOOL -Message ("BOOTSTRAP {0}: selected asset={1}" -f $ToolName, [string]$asset.name)

    $downloadUri = [Uri]([string]$asset.browser_download_url)
    if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -notmatch '(^|\.)(github\.com|githubusercontent\.com)$') { throw "Refusing unexpected download host for ${ToolName}: $downloadUri" }

    $archivePath = Join-Path $Layout.ToolsDownloads $asset.name
    $extractPath = Join-Path $Layout.ToolsExtracted ("{0}-{1}" -f $ToolName, [Guid]::NewGuid().ToString('N'))
    Write-ReconLog -Level TOOL -Message ("BOOTSTRAP {0}: download path={1}" -f $ToolName, $archivePath)
    Invoke-WebRequest -Uri $downloadUri.AbsoluteUri -Headers @{ 'User-Agent' = 'ScopeForge/1.0' } -OutFile $archivePath -TimeoutSec $TimeoutSeconds

    $downloadedInfo = Get-Item -LiteralPath $archivePath
    if ($downloadedInfo.Length -le 0) { throw "Downloaded archive for $ToolName is empty." }
    if ($asset.size -and ([int64]$asset.size -ne [int64]$downloadedInfo.Length)) { throw "Downloaded archive size mismatch for $ToolName." }
    Write-ReconLog -Level TOOL -Message ("BOOTSTRAP {0}: downloaded bytes={1}" -f $ToolName, $downloadedInfo.Length)

    $extractionInfo = Expand-CompressedArchive -ArchivePath $archivePath -DestinationPath $extractPath
    Write-ReconLog -Level TOOL -Message ("BOOTSTRAP {0}: archive={1} extractor={2} destination={3}" -f $ToolName, $extractionInfo.ArchiveKind, $extractionInfo.Extractor, $extractPath)
    $binaryName = if ($IsWindows) { "$BinaryName.exe" } else { $BinaryName }
    $binary = Get-ChildItem -Path $extractPath -Recurse -File | Where-Object { $_.Name -ieq $binaryName } | Select-Object -First 1
    if (-not $binary) { throw "Unable to locate extracted binary for $ToolName." }

    $destination = Join-Path $Layout.ToolsBin $binary.Name
    Copy-Item -LiteralPath $binary.FullName -Destination $destination -Force
    if (-not $IsWindows) {
        $chmod = Get-Command -Name 'chmod' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($chmod) { $null = Invoke-ExternalCommand -FilePath $chmod.Source -Arguments @('755', $destination) -TimeoutSeconds 15 }
    }

    $resolvedDestination = (Resolve-Path -LiteralPath $destination).Path
    $validationHelp = Get-ToolHelpText -ToolPath $resolvedDestination
    $validationStatus = if ([string]::IsNullOrWhiteSpace($validationHelp)) { 'no-help-output' } else { 'ok' }
    Write-ReconLog -Level TOOL -Message ("BOOTSTRAP {0}: validation={1} binary={2}" -f $ToolName, $validationStatus, $resolvedDestination)
    return $resolvedDestination
}

function Initialize-ReconTools {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Layout,
        [switch]$NoInstall,
        [int]$TimeoutSeconds = 60,
        [bool]$EnableGau = $true,
        [bool]$EnableWaybackUrls = $true,
        [bool]$EnableHakrawler = $true
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or later is required.' }
    $platformInfo = Get-PlatformInfo
    Write-ReconLog -Level INFO -Message ("PowerShell {0} on {1} ({2}/{3})" -f $PSVersionTable.PSVersion, $platformInfo.Description, $platformInfo.Os, $platformInfo.Architecture)

    $manifest = @(
        [pscustomobject]@{ Name = 'subfinder'; Repository = 'projectdiscovery/subfinder'; BinaryName = 'subfinder'; Required = $true },
        [pscustomobject]@{ Name = 'httpx'; Repository = 'projectdiscovery/httpx'; BinaryName = 'httpx'; Required = $true },
        [pscustomobject]@{ Name = 'katana'; Repository = 'projectdiscovery/katana'; BinaryName = 'katana'; Required = $true },
        [pscustomobject]@{ Name = 'gau'; Repository = 'lc/gau'; BinaryName = 'gau'; Required = $false; Enabled = $EnableGau },
        [pscustomobject]@{ Name = 'waybackurls'; Repository = 'tomnomnom/waybackurls'; BinaryName = 'waybackurls'; Required = $false; Enabled = $EnableWaybackUrls },
        [pscustomobject]@{ Name = 'hakrawler'; Repository = 'hakluke/hakrawler'; BinaryName = 'hakrawler'; Required = $false; Enabled = $EnableHakrawler }
    )

    $resolvedTools = [ordered]@{}
    foreach ($tool in $manifest) {
        if ($tool.PSObject.Properties['Enabled'] -and -not $tool.Enabled) {
            $resolvedTools[$tool.Name] = $null
            continue
        }
        $toolPath = Resolve-ToolPath -Name $tool.Name -ToolsBin $Layout.ToolsBin
        $toolSource = if ($toolPath) { 'cached' } else { $null }
        if (-not $toolPath) {
            if ($tool.Required) {
                if ($NoInstall) { throw "Required tool '$($tool.Name)' not found and -NoInstall was specified." }
                $toolPath = Install-ExternalTool -ToolName $tool.Name -Repository $tool.Repository -BinaryName $tool.BinaryName -PlatformInfo $platformInfo -Layout $Layout -TimeoutSeconds $TimeoutSeconds
                $toolSource = 'downloaded'
            } elseif (-not $NoInstall) {
                try {
                    $toolPath = Install-ExternalTool -ToolName $tool.Name -Repository $tool.Repository -BinaryName $tool.BinaryName -PlatformInfo $platformInfo -Layout $Layout -TimeoutSeconds $TimeoutSeconds
                    $toolSource = 'downloaded'
                } catch {
                    Write-ReconLog -Level WARN -Message (Get-ToolBootstrapFailureSummary -ToolName $tool.Name -FailureMessage $_.Exception.Message)
                    $toolPath = $null
                }
            } else {
                Write-ReconLog -Level WARN -Message "Optional tool '$($tool.Name)' not found. Related enrichment will be skipped."
            }
        }
        $resolvedTools[$tool.Name] = if ($toolPath) {
            $helpText = Get-ToolHelpText -ToolPath $toolPath
            $validationStatus = if ([string]::IsNullOrWhiteSpace($helpText)) { 'no-help-output' } else { 'ok' }
            Write-ReconLog -Level TOOL -Message ("BOOTSTRAP {0}: source={1} path={2} validation={3}" -f $tool.Name, $(if ($toolSource) { $toolSource } else { 'resolved' }), $toolPath, $validationStatus)
            [pscustomobject]@{ Path = $toolPath; HelpText = $helpText }
        } else {
            $null
        }
    }

    [pscustomobject]@{
        Platform    = $platformInfo
        Subfinder   = $resolvedTools['subfinder']
        Httpx       = $resolvedTools['httpx']
        Katana      = $resolvedTools['katana']
        Gau         = $resolvedTools['gau']
        WaybackUrls = $resolvedTools['waybackurls']
        Hakrawler   = $resolvedTools['hakrawler']
    }
}

Set-Alias -Name Ensure-ReconTools -Value Initialize-ReconTools -Scope Script

function Test-ValidDnsName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $value = $Name.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('*') -or $value.Contains('/') -or $value.Contains('\') -or $value.Contains(':')) { return $false }
    $labels = $value -split '\.'
    if ($labels.Count -lt 2) { return $false }
    foreach ($label in $labels) {
        if ($label.Length -lt 1 -or $label.Length -gt 63 -or $label.StartsWith('-') -or $label.EndsWith('-') -or $label -notmatch '^[a-z0-9-]+$') { return $false }
    }
    return $true
}

function ConvertTo-NormalizedExclusions {
    [CmdletBinding()]
    param([object]$InputObject)

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -isnot [System.Collections.IEnumerable] -or $InputObject -is [string]) { throw 'The exclusions property must be an array of strings.' }

    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $InputObject) {
        if ($item -isnot [string]) { throw 'Each exclusion must be a string.' }
        $token = $item.Trim().ToLowerInvariant()
        if ($token -and -not $tokens.Contains($token)) { $tokens.Add($token) }
    }
    return @($tokens)
}

function ConvertTo-NormalizedPathPrefix {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq '/') { return '/' }
    $normalized = if ($Path.StartsWith('/')) { $Path } else { '/' + $Path }
    if ($normalized.Length -gt 1) { $normalized = $normalized.TrimEnd('/') }
    return $(if ($normalized) { $normalized } else { '/' })
}

function ConvertTo-NormalizedScopeItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$InputObject, [Parameter(Mandatory)][int]$Index, [switch]$IncludeApex)

    $typeProperty = $InputObject.PSObject.Properties['type']
    $valueProperty = $InputObject.PSObject.Properties['value']
    $exclusionsProperty = $InputObject.PSObject.Properties['exclusions']
    if (-not $typeProperty -or -not $valueProperty) { throw "Scope item #$Index is missing required properties 'type' and/or 'value'." }

    $type = [string]$typeProperty.Value
    $value = [string]$valueProperty.Value
    if ([string]::IsNullOrWhiteSpace($type) -or [string]::IsNullOrWhiteSpace($value)) { throw "Scope item #$Index contains an empty type or value." }

    $normalizedType = $type.Trim().ToUpperInvariant()
    $normalizedValue = $value.Trim()
    $exclusions = ConvertTo-NormalizedExclusions -InputObject $(if ($exclusionsProperty) { $exclusionsProperty.Value } else { @() })

    switch ($normalizedType) {
        'URL' {
            $uri = $null
            if (-not [Uri]::TryCreate($normalizedValue, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) { throw "Scope item #$Index contains an invalid absolute HTTP(S) URL: $normalizedValue" }
            $targetHost = $uri.DnsSafeHost.ToLowerInvariant()
            if (-not (Test-ValidDnsName -Name $targetHost)) { throw "Scope item #$Index contains an invalid hostname in URL: $targetHost" }
            $pathPrefix = ConvertTo-NormalizedPathPrefix -Path $uri.AbsolutePath
            $port = if ($uri.IsDefaultPort) { $null } else { $uri.Port }
            return [pscustomobject]@{ Id = 'scope-{0:d3}' -f $Index; Index = $Index; Type = 'URL'; OriginalValue = $normalizedValue; NormalizedValue = $uri.AbsoluteUri; Scheme = $uri.Scheme.ToLowerInvariant(); Host = $targetHost; Port = $port; RootDomain = $targetHost; PathPrefix = $pathPrefix; StartUrl = $uri.AbsoluteUri; IncludeApex = $false; Exclusions = $exclusions; HostRegexString = '^' + [regex]::Escape($targetHost) + '$'; ScopeRegexString = ''; Description = "URL seed $($uri.AbsoluteUri)" }
        }
        'DOMAIN' {
            $targetHost = $normalizedValue.Trim().TrimEnd('.').ToLowerInvariant()
            if (-not (Test-ValidDnsName -Name $targetHost)) { throw "Scope item #$Index contains an invalid exact domain: $normalizedValue" }
            return [pscustomobject]@{ Id = 'scope-{0:d3}' -f $Index; Index = $Index; Type = 'Domain'; OriginalValue = $normalizedValue; NormalizedValue = $targetHost; Scheme = $null; Host = $targetHost; Port = $null; RootDomain = $targetHost; PathPrefix = '/'; StartUrl = $null; IncludeApex = $false; Exclusions = $exclusions; HostRegexString = '^' + [regex]::Escape($targetHost) + '$'; ScopeRegexString = '^https?://' + [regex]::Escape($targetHost) + '(?::\d+)?(?:/.*)?$'; Description = "Exact domain $targetHost" }
        }
        'WILDCARD' {
            $wildcardMatch = [regex]::Match($normalizedValue, '^(?:(?<scheme>https?)://)?\*\.(?<root>[a-z0-9.-]+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $wildcardMatch.Success) { throw "Scope item #$Index contains an invalid wildcard. Expected https://*.example.com or *.example.com" }
            $scheme = $wildcardMatch.Groups['scheme'].Value.ToLowerInvariant(); if (-not $scheme) { $scheme = $null }
            $rootDomain = $wildcardMatch.Groups['root'].Value.ToLowerInvariant().TrimEnd('.')
            if (-not (Test-ValidDnsName -Name $rootDomain)) { throw "Scope item #$Index contains an invalid wildcard root domain: $rootDomain" }
            $hostRegex = if ($IncludeApex) { '^(?:[a-z0-9-]+\.)*' + [regex]::Escape($rootDomain) + '$' } else { '^(?:[a-z0-9-]+\.)+' + [regex]::Escape($rootDomain) + '$' }
            return [pscustomobject]@{ Id = 'scope-{0:d3}' -f $Index; Index = $Index; Type = 'Wildcard'; OriginalValue = $normalizedValue; NormalizedValue = $(if ($scheme) { "${scheme}://*.$rootDomain" } else { "*.$rootDomain" }); Scheme = $scheme; Host = $null; Port = $null; RootDomain = $rootDomain; PathPrefix = '/'; StartUrl = $null; IncludeApex = [bool]$IncludeApex; Exclusions = $exclusions; HostRegexString = $hostRegex; ScopeRegexString = ''; Description = "Wildcard *.$rootDomain" }
        }
        default { throw "Scope item #$Index contains an unsupported type '$type'. Allowed values: URL, Domain, Wildcard." }
    }
}

function Read-ScopeFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$IncludeApex)

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $resolvedPath)) { throw "Scope file not found: $resolvedPath" }
    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Scope file is empty.' }
    try { $parsed = ConvertFrom-Json -InputObject $raw -Depth 100 -NoEnumerate } catch { throw "Scope file is not valid JSON: $($_.Exception.Message)" }
    if ($parsed -isnot [System.Collections.IEnumerable] -or $parsed -is [string]) { throw 'Scope file must contain a JSON array.' }
    $items = [System.Collections.Generic.List[object]]::new(); $index = 0
    foreach ($item in $parsed) { $index++; $items.Add((ConvertTo-NormalizedScopeItem -InputObject $item -Index $index -IncludeApex:$IncludeApex)) }
    if ($items.Count -eq 0) { throw 'Scope file does not contain any scope items.' }
    return @($items)
}

function Test-PathPrefixMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CandidatePath, [Parameter(Mandatory)][string]$Prefix)

    $normalizedCandidate = if ([string]::IsNullOrWhiteSpace($CandidatePath)) { '/' } else { $CandidatePath }
    $normalizedPrefix = ConvertTo-NormalizedPathPrefix -Path $Prefix
    if ($normalizedPrefix -eq '/') { return $true }
    if ($normalizedCandidate -ceq $normalizedPrefix) { return $true }
    return $normalizedCandidate.StartsWith($normalizedPrefix + '/', [System.StringComparison]::Ordinal)
}

function Test-ExclusionMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$ScopeItem, [string]$TargetHost, [string]$Url, [string]$Path)

    $result = [pscustomobject]@{
        IsExcluded = $false
        Token      = $null
        MatchedOn  = $null
        MatchedText = $null
    }

    foreach ($token in $ScopeItem.Exclusions) {
        foreach ($entry in @(
                @{ Name = 'host'; Value = $TargetHost },
                @{ Name = 'url'; Value = $Url },
                @{ Name = 'path'; Value = $Path }
            )) {

            if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) { continue }

            if (Test-ExclusionTokenInText -Text ([string]$entry.Value) -Token $token) {
                $result.IsExcluded = $true
                $result.Token = $token
                $result.MatchedOn = $entry.Name
                $result.MatchedText = [string]$entry.Value
                return $result
            }
        }
    }

    return $result
}

function Test-ScopeMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$ScopeItem, [string]$CandidateHostInput, [string]$Url, [switch]$RespectSchemeOnly)

    $candidateUri = $null; $candidateHost = $null; $candidateScheme = $null; $candidatePort = $null; $candidatePath = '/'
    if ($Url) {
        if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$candidateUri) -or $candidateUri.Scheme -notin @('http', 'https')) { return $false }
        $candidateHost = $candidateUri.DnsSafeHost.ToLowerInvariant()
        $candidateScheme = $candidateUri.Scheme.ToLowerInvariant()
        $candidatePort = if ($candidateUri.IsDefaultPort) { $null } else { $candidateUri.Port }
        $candidatePath = if ($candidateUri.AbsolutePath) { $candidateUri.AbsolutePath } else { '/' }
    } elseif ($CandidateHostInput) {
        $candidateHost = $CandidateHostInput.Trim().TrimEnd('.').ToLowerInvariant()
    } else {
        return $false
    }

    switch ($ScopeItem.Type) {
        'URL' {
            if ($candidateHost -ne $ScopeItem.Host) { return $false }
            if ($RespectSchemeOnly -and $candidateScheme -and $candidateScheme -ne $ScopeItem.Scheme) { return $false }
            if ($null -ne $ScopeItem.Port -and $candidatePort -and $candidatePort -ne $ScopeItem.Port) { return $false }
            return $(if ($Url) { Test-PathPrefixMatch -CandidatePath $candidatePath -Prefix $ScopeItem.PathPrefix } else { $true })
        }
        'Domain' { return ($candidateHost -eq $ScopeItem.Host) }
        'Wildcard' {
            if (-not [regex]::IsMatch($candidateHost, $ScopeItem.HostRegexString, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $false }
            if ($RespectSchemeOnly -and $candidateScheme -and $ScopeItem.Scheme -and $candidateScheme -ne $ScopeItem.Scheme) { return $false }
            return $true
        }
        default { return $false }
    }
}

function Get-ProbeCandidateUrls {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$ScopeItem, [string]$TargetHost, [switch]$RespectSchemeOnly)

    $urls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    switch ($ScopeItem.Type) {
        'URL' { $null = $urls.Add($ScopeItem.StartUrl) }
        'Domain' { foreach ($scheme in @('https', 'http')) { $null = $urls.Add(("{0}://{1}" -f $scheme, $ScopeItem.Host)) } }
        'Wildcard' {
            if (-not $TargetHost) { return @() }
            if ($ScopeItem.Scheme) {
                $null = $urls.Add(("{0}://{1}" -f $ScopeItem.Scheme, $TargetHost))
                if (-not $RespectSchemeOnly) {
                    $alternate = if ($ScopeItem.Scheme -eq 'https') { 'http' } else { 'https' }
                    $null = $urls.Add(("{0}://{1}" -f $alternate, $TargetHost))
                }
            } else {
                foreach ($scheme in @('https', 'http')) { $null = $urls.Add(("{0}://{1}" -f $scheme, $TargetHost)) }
            }
        }
    }
    return @($urls)
}

function Get-CanonicalUrlKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $Url.Trim() }
    $builder = [UriBuilder]::new($uri)
    $builder.Scheme = $builder.Scheme.ToLowerInvariant()
    $builder.Host = $builder.Host.ToLowerInvariant()
    if (($builder.Scheme -eq 'http' -and $builder.Port -eq 80) -or ($builder.Scheme -eq 'https' -and $builder.Port -eq 443)) { $builder.Port = -1 }
    return $builder.Uri.AbsoluteUri.TrimEnd('/')
}


function ConvertTo-ScopeForgeSafeSegment {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    $safe = if ([string]::IsNullOrWhiteSpace($Value)) { 'default-program' } else { $Value }
    $safe = ($safe -replace '[^a-zA-Z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'default-program' }
    return $safe
}

function New-ScopeForgeStringSet {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Values = @())

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $null = $set.Add([string]$value)
        }
    }
    return $set
}

function ConvertTo-ScopeForgeTriageState {
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$State,
        [string]$ProgramName = '',
        [string]$Path = ''
    )

    $effectiveProgramName = if (-not [string]::IsNullOrWhiteSpace($ProgramName)) {
        $ProgramName
    } elseif ($State -and $State.PSObject.Properties['ProgramName'] -and -not [string]::IsNullOrWhiteSpace([string]$State.ProgramName)) {
        [string]$State.ProgramName
    } else {
        'default-program'
    }

    $effectivePath = if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $Path
    } elseif ($State -and $State.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$State.Path)) {
        [string]$State.Path
    } else {
        Join-Path (Get-ScopeForgeStateRoot -ProgramName $effectiveProgramName) 'triage-state.json'
    }

    $rawIgnoreKeys = if ($State -and $State.PSObject.Properties['IgnoreKeys']) { $State.IgnoreKeys } else { @() }
    $rawFalsePositiveKeys = if ($State -and $State.PSObject.Properties['FalsePositiveKeys']) { $State.FalsePositiveKeys } else { @() }
    $rawValidatedKeys = if ($State -and $State.PSObject.Properties['ValidatedKeys']) { $State.ValidatedKeys } else { @() }
    $rawSeenKeys = if ($State -and $State.PSObject.Properties['SeenKeys']) { $State.SeenKeys } else { @() }
    $reviewNotes = if ($State -and $State.PSObject.Properties['ReviewNotes'] -and $null -ne $State.ReviewNotes) { $State.ReviewNotes } else { @{} }

    return [pscustomobject]@{
        Path              = $effectivePath
        ProgramName       = $effectiveProgramName
        IgnoreKeys        = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $rawIgnoreKeys) | ForEach-Object { [string]$_ })
        FalsePositiveKeys = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $rawFalsePositiveKeys) | ForEach-Object { [string]$_ })
        ValidatedKeys     = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $rawValidatedKeys) | ForEach-Object { [string]$_ })
        SeenKeys          = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $rawSeenKeys) | ForEach-Object { [string]$_ })
        ReviewNotes       = $reviewNotes
    }
}


function Get-ScopeForgeStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramName)

    $programSegment = ConvertTo-ScopeForgeSafeSegment -Value $ProgramName
    $baseRoot = if ($IsWindows -and $env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'ScopeForge'
    } elseif ($HOME) {
        Join-Path $HOME '.scopeforge'
    } else {
        Join-Path $script:ScopeForgeScriptRoot '.scopeforge'
    }

    $stateRoot = Join-Path (Join-Path $baseRoot 'state') $programSegment
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        $null = New-Item -ItemType Directory -Path $stateRoot -Force
    }
    return $stateRoot
}

function Get-DefaultTriageStateDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramName)

    [ordered]@{
        version            = 1
        programName        = $ProgramName
        updatedUtc         = [DateTime]::UtcNow.ToString('o')
        ignoreKeys         = @()
        falsePositiveKeys  = @()
        validatedKeys      = @()
        seenKeys           = @()
        reviewNotes        = @{}
    }
}

function Get-ScopeForgeTriageState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramName)

    $root = Get-ScopeForgeStateRoot -ProgramName $ProgramName
    $path = Join-Path $root 'triage-state.json'
    if (-not (Test-Path -LiteralPath $path)) {
        $defaultDoc = Get-DefaultTriageStateDocument -ProgramName $ProgramName
        $defaultDoc | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
    }

    $parsed = $null
    try {
        $parsed = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    } catch {
        $parsed = [pscustomobject](Get-DefaultTriageStateDocument -ProgramName $ProgramName)
    }

    $ignoreKeys = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $parsed.ignoreKeys) | ForEach-Object { [string]$_ })
    $falsePositiveKeys = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $parsed.falsePositiveKeys) | ForEach-Object { [string]$_ })
    $validatedKeys = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $parsed.validatedKeys) | ForEach-Object { [string]$_ })
    $seenKeys = New-ScopeForgeStringSet -Values @((ConvertTo-ArrayOrEmpty -Data $parsed.seenKeys) | ForEach-Object { [string]$_ })

    return ConvertTo-ScopeForgeTriageState -State ([pscustomobject]@{
        Path              = $path
        ProgramName       = $ProgramName
        IgnoreKeys        = $ignoreKeys
        FalsePositiveKeys = $falsePositiveKeys
        ValidatedKeys     = $validatedKeys
        SeenKeys          = $seenKeys
        ReviewNotes       = $(if ($parsed.reviewNotes) { $parsed.reviewNotes } else { @{} })
    }) -ProgramName $ProgramName -Path $path
}

function Save-ScopeForgeTriageState {
    [CmdletBinding()]
    param(
        [AllowNull()][pscustomobject]$State,
        [AllowEmptyCollection()][string[]]$SeenReviewKeys = @()
    )

    function Get-ScopeForgeStatePropertyValue {
        param(
            [AllowNull()][object]$InputObject,
            [Parameter(Mandatory)][string]$PropertyName,
            $DefaultValue = $null
        )

        if ($null -eq $InputObject) { return $DefaultValue }

        $property = $InputObject.PSObject.Properties[$PropertyName]
        if ($null -eq $property) { return $DefaultValue }
        if ($null -eq $property.Value) { return $DefaultValue }

        return $property.Value
    }

    $normalizedState = $null
    try {
        if ($null -ne $State) {
            $normalizedState = ConvertTo-ScopeForgeTriageState -State $State
        }
    } catch {
        $normalizedState = $null
    }

    $programName = 'default-program'
    $normalizedProgramName = [string](Get-ScopeForgeStatePropertyValue -InputObject $normalizedState -PropertyName 'ProgramName' -DefaultValue '')
    $rawProgramName = [string](Get-ScopeForgeStatePropertyValue -InputObject $State -PropertyName 'ProgramName' -DefaultValue '')

    if (-not [string]::IsNullOrWhiteSpace($normalizedProgramName)) {
        $programName = $normalizedProgramName
    } elseif (-not [string]::IsNullOrWhiteSpace($rawProgramName)) {
        $programName = $rawProgramName
    }

    $path = [string](Get-ScopeForgeStatePropertyValue -InputObject $normalizedState -PropertyName 'Path' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = [string](Get-ScopeForgeStatePropertyValue -InputObject $State -PropertyName 'Path' -DefaultValue '')
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path (Get-ScopeForgeStateRoot -ProgramName $programName) 'triage-state.json'
    }

    $ignoreValues = @(
        ConvertTo-ArrayOrEmpty -Data (Get-ScopeForgeStatePropertyValue -InputObject $normalizedState -PropertyName 'IgnoreKeys' -DefaultValue @()) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $falsePositiveValues = @(
        ConvertTo-ArrayOrEmpty -Data (Get-ScopeForgeStatePropertyValue -InputObject $normalizedState -PropertyName 'FalsePositiveKeys' -DefaultValue @()) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $validatedValues = @(
        ConvertTo-ArrayOrEmpty -Data (Get-ScopeForgeStatePropertyValue -InputObject $normalizedState -PropertyName 'ValidatedKeys' -DefaultValue @()) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $seenValues = @(
        ConvertTo-ArrayOrEmpty -Data (Get-ScopeForgeStatePropertyValue -InputObject $normalizedState -PropertyName 'SeenKeys' -DefaultValue @()) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $seenReviewValues = @(
        ConvertTo-ArrayOrEmpty -Data $SeenReviewKeys |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $ignoreKeys = New-ScopeForgeStringSet -Values $ignoreValues
    $falsePositiveKeys = New-ScopeForgeStringSet -Values $falsePositiveValues
    $validatedKeys = New-ScopeForgeStringSet -Values $validatedValues
    $seenKeys = New-ScopeForgeStringSet -Values @($seenValues + $seenReviewValues)

    $reviewNotes = Get-ScopeForgeStatePropertyValue -InputObject $normalizedState -PropertyName 'ReviewNotes' -DefaultValue @{}

    $parentDir = Split-Path -Parent $path
    if (
        -not [string]::IsNullOrWhiteSpace($parentDir) -and
        -not (Test-Path -LiteralPath $parentDir)
    ) {
        $null = New-Item -ItemType Directory -Path $parentDir -Force
    }

    $document = [ordered]@{
        version           = 1
        programName       = $programName
        updatedUtc        = [DateTime]::UtcNow.ToString('o')
        ignoreKeys        = @($ignoreKeys | Sort-Object)
        falsePositiveKeys = @($falsePositiveKeys | Sort-Object)
        validatedKeys     = @($validatedKeys | Sort-Object)
        seenKeys          = @($seenKeys | Sort-Object)
        reviewNotes       = $reviewNotes
    }

    $document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8

    if ($script:ScopeForgeContext) {
        $script:ScopeForgeContext.TriageState = [pscustomobject]@{
            Path              = $path
            ProgramName       = $programName
            IgnoreKeys        = $ignoreKeys
            FalsePositiveKeys = $falsePositiveKeys
            ValidatedKeys     = $validatedKeys
            SeenKeys          = $seenKeys
            ReviewNotes       = $reviewNotes
        }
    }
}

function Write-ScopeForgeDiagnosticLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Line
    )

    try {
        Add-Content -LiteralPath $Path -Value $Line -Encoding utf8
    } catch {
    }
}

function Invoke-HttpxEmptyBatchDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HttpxPath,
        [Parameter(Mandatory)][string]$HelpText,
        [Parameter(Mandatory)][string[]]$InputUrls,
        [string]$UniqueUserAgent,
        [int]$TimeoutSeconds = 30,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$BatchLabel
    )

    $sampleUrls = @(
        $InputUrls |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -First 5
    )
    if ($sampleUrls.Count -eq 0) { return }

    $inputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-diag-input-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-diag-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-diag-{0}.err" -f ([Guid]::NewGuid().ToString('N')))

    try {
        Set-Content -LiteralPath $inputFile -Value $sampleUrls -Encoding utf8

        $arguments = @(
            '-silent',
            '-json',
            '-probe',
            '-status-code',
            '-threads', '2',
            '-timeout', ([string]([Math]::Min([Math]::Max($TimeoutSeconds, 5), 15)))
        )
        if (Test-ToolFlagSupport -HelpText $HelpText -Flag '-duc') { $arguments += '-duc' }

        if ($UniqueUserAgent) {
            if (Test-ToolFlagSupport -HelpText $HelpText -Flag '-H') {
                $arguments += @('-H', "User-Agent: $UniqueUserAgent")
            } elseif (Test-ToolFlagSupport -HelpText $HelpText -Flag '-header') {
                $arguments += @('-header', "User-Agent: $UniqueUserAgent")
            }
        }

        $arguments += @('-l', $inputFile)

        $result = Invoke-ExternalCommand -FilePath $HttpxPath -Arguments $arguments -TimeoutSeconds ([Math]::Min([Math]::Max($TimeoutSeconds, 10), 30)) -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
        $diagLines = @(
            if (Test-Path -LiteralPath $stdoutFile) {
                Get-Content -LiteralPath $stdoutFile -Encoding utf8
            }
        )

        $diagParseErrors = 0
        $reasonCounts = [ordered]@{}

        foreach ($line in $diagLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $raw = $line | ConvertFrom-Json -Depth 100
            } catch {
                $diagParseErrors++
                continue
            }

            $reason = [string](Get-ObjectValue -InputObject $raw -Names @('error') -Default '')
            if ($reason -match 'cause="([^"]+)"') {
                $reason = $Matches[1]
            }

            if ([string]::IsNullOrWhiteSpace($reason)) {
                $statusCode = [int](Get-ObjectValue -InputObject $raw -Names @('status-code', 'status_code') -Default 0)
                $failed = [bool](Get-ObjectValue -InputObject $raw -Names @('failed') -Default $false)
                if ($failed) {
                    $reason = 'failed-no-error'
                } elseif ($statusCode -gt 0) {
                    $reason = ('status-{0}' -f $statusCode)
                } else {
                    $reason = 'unknown'
                }
            }

            $reason = (($reason -replace '\r?\n', ' ') -replace '\|', '/').Trim()
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'unknown' }
            if (-not $reasonCounts.Contains($reason)) { $reasonCounts[$reason] = 0 }
            $reasonCounts[$reason]++
        }

        $reasonSummary = (
            $reasonCounts.GetEnumerator() |
            Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } |
            ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
        ) -join ','

        if ([string]::IsNullOrWhiteSpace($reasonSummary)) {
            $stderrSummary = ''
            if ($result.StdErr) {
                $stderrSummary = (($result.StdErr -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -join '')
                $stderrSummary = (($stderrSummary -replace '\|', '/') -replace '\r?\n', ' ').Trim()
            }
            $reasonSummary = if ($stderrSummary) { 'stderr:' + $stderrSummary } else { 'no-json-output' }
        }

        Write-ScopeForgeDiagnosticLine -Path $LogPath -Line ("BATCH_EMPTY_DIAG|{0}|sample={1}|diag_lines={2}|diag_exit={3}|parse_errors={4}|reasons={5}" -f $BatchLabel, $sampleUrls.Count, $diagLines.Count, $result.ExitCode, $diagParseErrors, $reasonSummary)

        if ($reasonSummary -eq 'no-json-output' -and $sampleUrls.Count -gt 0) {
            $singleUrl = [string]$sampleUrls[0]
            $safeSingleUrl = (($singleUrl -replace '\|', '%7C') -replace '\r?\n', '').Trim()
            $singleStdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-diag-single-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))
            $singleStderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-diag-single-{0}.err" -f ([Guid]::NewGuid().ToString('N')))

            try {
                $singleArguments = @(
                    '-json',
                    '-probe',
                    '-status-code',
                    '-timeout', ([string]([Math]::Min([Math]::Max($TimeoutSeconds, 5), 15)))
                )
                if (Test-ToolFlagSupport -HelpText $HelpText -Flag '-duc') { $singleArguments += '-duc' }

                if ($UniqueUserAgent) {
                    if (Test-ToolFlagSupport -HelpText $HelpText -Flag '-H') {
                        $singleArguments += @('-H', "User-Agent: $UniqueUserAgent")
                    } elseif (Test-ToolFlagSupport -HelpText $HelpText -Flag '-header') {
                        $singleArguments += @('-header', "User-Agent: $UniqueUserAgent")
                    }
                }

                $singleArguments += @('-u', $singleUrl)

                $singleResult = Invoke-ExternalCommand -FilePath $HttpxPath -Arguments $singleArguments -TimeoutSeconds ([Math]::Min([Math]::Max($TimeoutSeconds, 10), 30)) -StdOutPath $singleStdoutFile -StdErrPath $singleStderrFile -IgnoreExitCode
                $singleLines = @(
                    if (Test-Path -LiteralPath $singleStdoutFile) {
                        Get-Content -LiteralPath $singleStdoutFile -Encoding utf8
                    }
                )

                $singleParseErrors = 0
                $singleReasonCounts = [ordered]@{}

                foreach ($line in $singleLines) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }

                    try {
                        $raw = $line | ConvertFrom-Json -Depth 100
                    } catch {
                        $singleParseErrors++
                        continue
                    }

                    $singleReason = [string](Get-ObjectValue -InputObject $raw -Names @('error') -Default '')
                    if ($singleReason -match 'cause="([^"]+)"') {
                        $singleReason = $Matches[1]
                    }

                    if ([string]::IsNullOrWhiteSpace($singleReason)) {
                        $statusCode = [int](Get-ObjectValue -InputObject $raw -Names @('status-code', 'status_code') -Default 0)
                        $failed = [bool](Get-ObjectValue -InputObject $raw -Names @('failed') -Default $false)
                        if ($failed) {
                            $singleReason = 'failed-no-error'
                        } elseif ($statusCode -gt 0) {
                            $singleReason = ('status-{0}' -f $statusCode)
                        } else {
                            $singleReason = 'unknown'
                        }
                    }

                    $singleReason = (($singleReason -replace '\r?\n', ' ') -replace '\|', '/').Trim()
                    if ([string]::IsNullOrWhiteSpace($singleReason)) { $singleReason = 'unknown' }
                    if (-not $singleReasonCounts.Contains($singleReason)) { $singleReasonCounts[$singleReason] = 0 }
                    $singleReasonCounts[$singleReason]++
                }

                $singleReasonSummary = (
                    $singleReasonCounts.GetEnumerator() |
                    Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } |
                    ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
                ) -join ','

                if ([string]::IsNullOrWhiteSpace($singleReasonSummary)) {
                    $singleStderrSummary = ''
                    if ($singleResult.StdErr) {
                        $singleStderrSummary = (($singleResult.StdErr -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -join '')
                        $singleStderrSummary = (($singleStderrSummary -replace '\|', '/') -replace '\r?\n', ' ').Trim()
                    }
                    $singleReasonSummary = if ($singleStderrSummary) { 'stderr:' + $singleStderrSummary } else { 'no-json-output' }
                }

                Write-ScopeForgeDiagnosticLine -Path $LogPath -Line ("BATCH_EMPTY_DIAG_SINGLE|{0}|url={1}|diag_lines={2}|diag_exit={3}|parse_errors={4}|reasons={5}" -f $BatchLabel, $safeSingleUrl, $singleLines.Count, $singleResult.ExitCode, $singleParseErrors, $singleReasonSummary)
            } catch {
                $message = (($_.Exception.Message -replace '\|', '/') -replace '\r?\n', ' ').Trim()
                Write-ScopeForgeDiagnosticLine -Path $LogPath -Line ("BATCH_EMPTY_DIAG_SINGLE|{0}|url={1}|error={2}" -f $BatchLabel, $safeSingleUrl, $message)
            } finally {
                Remove-Item -LiteralPath $singleStdoutFile, $singleStderrFile -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        $message = (($_.Exception.Message -replace '\|', '/') -replace '\r?\n', ' ').Trim()
        Write-ScopeForgeDiagnosticLine -Path $LogPath -Line ("BATCH_EMPTY_DIAG|{0}|sample={1}|error={2}" -f $BatchLabel, $sampleUrls.Count, $message)
    } finally {
        Remove-Item -LiteralPath $inputFile, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ReviewUrlAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$ContentType = '',
        [int]$StatusCode = 0
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        return [pscustomobject]@{
            Url                = $Url
            ReviewKey          = $Url.Trim()
            ReviewUrl          = $Url.Trim()
            Host               = ''
            Path               = '/'
            Query              = ''
            PathAndQuery       = '/'
            Extension          = ''
            IsNoise            = $false
            NoiseTags          = @()
            HasVolatileParams  = $false
        }
    }

    $builder = [UriBuilder]::new($uri)
    $builder.Scheme = $builder.Scheme.ToLowerInvariant()
    $builder.Host = $builder.Host.ToLowerInvariant()
    if (($builder.Scheme -eq 'http' -and $builder.Port -eq 80) -or ($builder.Scheme -eq 'https' -and $builder.Port -eq 443)) {
        $builder.Port = -1
    }

    $path = if ($uri.AbsolutePath) { $uri.AbsolutePath } else { '/' }
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    $pathLower = $path.ToLowerInvariant()
    $volatileNames = New-ScopeForgeStringSet -Values @('__cf_chl_f_tk','__cf_chl_rt_tk','__cf_chl_tk','__cf_chl_captcha_tk__','cf_chl_2','cf_chl_prog','cf_clearance','fbclid','gclid','mc_cid','mc_eid','token','access_token','id_token','session_state','nonce','timestamp','ts','sig','signature','expires','exp')
    $keptPairs = [System.Collections.Generic.List[object]]::new()
    $hasVolatileParams = $false
    if ($uri.Query) {
        foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
            if ([string]::IsNullOrWhiteSpace($pair)) { continue }
            $split = $pair -split '=', 2
            $name = [Uri]::UnescapeDataString($split[0])
            $value = if ($split.Count -gt 1) { [Uri]::UnescapeDataString($split[1]) } else { '' }
            if ($name -match '^(?i)(__cf_|cf_|utm_|x-amz-)') {
                $hasVolatileParams = $true
                continue
            }
            if ($volatileNames.Contains($name)) {
                $hasVolatileParams = $true
                continue
            }
            $keptPairs.Add([pscustomobject]@{ Name = $name; Value = $value }) | Out-Null
        }
    }

    $normalizedQuery = ''
    if ($keptPairs.Count -gt 0) {
        $normalizedQuery = '?' + (($keptPairs | Sort-Object Name, Value | ForEach-Object { '{0}={1}' -f [Uri]::EscapeDataString($_.Name), [Uri]::EscapeDataString($_.Value) }) -join '&')
    }

    $builder.Query = $normalizedQuery.TrimStart('?')
    $reviewUrl = $builder.Uri.AbsoluteUri
    if ($reviewUrl.EndsWith('/') -and $path -ne '/') {
        $reviewUrl = $reviewUrl.TrimEnd('/')
    }

    $noiseTags = [System.Collections.Generic.List[string]]::new()
    $staticExtensions = @('.js','.css','.map','.woff','.woff2','.ttf','.eot','.ico','.png','.jpg','.jpeg','.gif','.svg','.webp','.bmp','.mp3','.wav','.mp4','.avi','.mov')
    $documentExtensions = @('.pdf','.doc','.docx','.ppt','.pptx','.xls','.xlsx')
    if ($pathLower -like '*/cdn-cgi/*') { $noiseTags.Add('cloudflare') | Out-Null }
    if ($pathLower -like '*/_next/static/*' -or $pathLower -like '*/static/*' -or $pathLower -like '*/assets/*' -or $pathLower -like '*/fonts/*') { $noiseTags.Add('static-path') | Out-Null }
    if ($staticExtensions -contains $extension) { $noiseTags.Add('static-extension') | Out-Null }
    if ($documentExtensions -contains $extension) { $noiseTags.Add('document-extension') | Out-Null }
    if ($ContentType -match '(?i)(font/|image/|audio/|video/)') { $noiseTags.Add('content-type-asset') | Out-Null }
    if ($StatusCode -in 404, 410 -and $noiseTags.Count -eq 0 -and $pathLower -match '^/(?:_next|cdn-cgi|favicon\.ico|manifest\.json)') { $noiseTags.Add('404-static') | Out-Null }

    $pathAndQuery = $path
    if ($normalizedQuery) { $pathAndQuery += $normalizedQuery }

    return [pscustomobject]@{
        Url               = $Url
        ReviewKey         = $reviewUrl
        ReviewUrl         = $reviewUrl
        Host              = $builder.Host
        Path              = $path
        Query             = $normalizedQuery
        PathAndQuery      = $pathAndQuery
        Extension         = $extension
        IsNoise           = ($noiseTags.Count -gt 0)
        NoiseTags         = @($noiseTags | Select-Object -Unique)
        HasVolatileParams = $hasVolatileParams
    }
}

function Test-KatanaSeedEligibility {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$LiveTarget)

    $analysis = Get-ReviewUrlAnalysis -Url $LiveTarget.Url -StatusCode ([int]$LiveTarget.StatusCode)
    $allowedStatuses = @(200,201,202,204,301,302,303,307,308,401,403,405)
    if ($analysis.IsNoise) {
        return [pscustomobject]@{ Eligible = $false; Reason = ($analysis.NoiseTags -join ', ') }
    }
    if ($LiveTarget.StatusCode -notin $allowedStatuses) {
        return [pscustomobject]@{ Eligible = $false; Reason = ('status-{0}' -f $LiveTarget.StatusCode) }
    }
    return [pscustomobject]@{ Eligible = $true; Reason = 'ok' }
}

function Select-NativeProbeFallbackInputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$InputUrls,
        [int]$MaxPerHost = 1,
        [int]$MaxTotal = 250
    )

    if (-not $InputUrls -or $InputUrls.Count -eq 0) { return @() }

    $ranked = [System.Collections.Generic.List[object]]::new()
    foreach ($inputUrl in @($InputUrls)) {
        if ([string]::IsNullOrWhiteSpace($inputUrl)) { continue }

        $uri = $null
        if (-not [Uri]::TryCreate([string]$inputUrl, [UriKind]::Absolute, [ref]$uri)) { continue }

        $normalizedUrl = $uri.AbsoluteUri
        $analysis = Get-ReviewUrlAnalysis -Url $normalizedUrl
        $ranked.Add([pscustomobject]@{
                Url        = $normalizedUrl
                Host       = $uri.DnsSafeHost.ToLowerInvariant()
                NoiseRank  = $(if ($analysis.IsNoise) { 1 } else { 0 })
                RootRank   = $(if ($analysis.Path -eq '/') { 0 } else { 1 })
                QueryRank  = $(if ([string]::IsNullOrWhiteSpace([string]$analysis.Query)) { 0 } else { 1 })
                SchemeRank = $(if ($uri.Scheme -eq 'https') { 0 } elseif ($uri.Scheme -eq 'http') { 1 } else { 2 })
                PathLength = [int]([string]$analysis.PathAndQuery).Length
            }) | Out-Null
    }

    if ($ranked.Count -eq 0) { return @() }

    $selected = foreach ($group in ($ranked | Group-Object -Property Host | Sort-Object Name)) {
        $group.Group |
            Sort-Object NoiseRank, RootRank, QueryRank, PathLength, SchemeRank, Url |
            Select-Object -First ([Math]::Max($MaxPerHost, 1))
    }

    return @($selected | Select-Object -ExpandProperty Url -First ([Math]::Max($MaxTotal, 1)))
}

function Invoke-NativeHttpProbeFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$InputUrls,
        [Parameter(Mandatory)][pscustomobject[]]$ScopeItems,
        [int]$Threads = 10,
        [int]$TimeoutSeconds = 30,
        [string]$UniqueUserAgent,
        [switch]$RespectSchemeOnly
    )

    if (-not $InputUrls -or $InputUrls.Count -eq 0) { return @() }

    $selectedInputs = @(Select-NativeProbeFallbackInputs -InputUrls $InputUrls -MaxPerHost 1 -MaxTotal ([Math]::Min([Math]::Max(($Threads * 20), 50), 250)))
    if ($selectedInputs.Count -eq 0) { return @() }

    $probeTimeoutSeconds = [Math]::Min([Math]::Max([int]([Math]::Floor($TimeoutSeconds / 2)), 5), 15)
    $throttleLimit = [Math]::Min([Math]::Max($Threads, 1), 20)
    $headers = @{}
    if ($UniqueUserAgent) {
        $headers['User-Agent'] = $UniqueUserAgent
    }

    Write-ReconLog -Level WARN -Message ("httpx returned no retained live targets. Native HTTP rescue will probe {0} reduced candidate(s)." -f $selectedInputs.Count)

    $rawResults = @(
        $selectedInputs |
        ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
            $inputUrl = [string]$_
            $headerCopy = @{}
            $sharedHeaders = $using:headers
            foreach ($entry in $sharedHeaders.GetEnumerator()) {
                $headerCopy[[string]$entry.Key] = [string]$entry.Value
            }

            $response = $null
            $methodUsed = 'HEAD'
            $lastError = ''

            try {
                $response = Invoke-WebRequest -Uri $inputUrl -Method Head -Headers $headerCopy -TimeoutSec $using:probeTimeoutSeconds -MaximumRedirection 5 -SkipHttpErrorCheck
            } catch {
                $lastError = $_.Exception.Message
            }

            $statusCode = 0
            try {
                if ($response -and $response.PSObject.Properties['StatusCode']) {
                    $statusCode = [int]$response.StatusCode
                }
            } catch {}

            if ($null -eq $response -or $statusCode -in 405, 501) {
                try {
                    $response = Invoke-WebRequest -Uri $inputUrl -Method Get -Headers $headerCopy -TimeoutSec $using:probeTimeoutSeconds -MaximumRedirection 5 -SkipHttpErrorCheck
                    $methodUsed = 'GET'
                    $lastError = ''
                    $statusCode = 0
                    try {
                        if ($response -and $response.PSObject.Properties['StatusCode']) {
                            $statusCode = [int]$response.StatusCode
                        }
                    } catch {}
                } catch {
                    if ([string]::IsNullOrWhiteSpace($lastError)) {
                        $lastError = $_.Exception.Message
                    }
                }
            }

            if ($null -eq $response) {
                return [pscustomobject]@{
                    Input  = $inputUrl
                    Url    = $inputUrl
                    Method = $methodUsed
                    Error  = $lastError
                }
            }

            $finalUrl = $inputUrl
            try {
                if ($response.BaseResponse -and $response.BaseResponse.RequestMessage -and $response.BaseResponse.RequestMessage.RequestUri) {
                    $finalUrl = [string]$response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
                } elseif ($response.BaseResponse -and $response.BaseResponse.ResponseUri) {
                    $finalUrl = [string]$response.BaseResponse.ResponseUri.AbsoluteUri
                }
            } catch {}

            $contentLength = 0L
            $contentType = ''
            $redirectLocation = ''
            $webServer = ''
            try {
                $responseHeaders = $response.Headers
                if ($responseHeaders) {
                    if ($responseHeaders['Content-Length']) {
                        $null = [int64]::TryParse([string]$responseHeaders['Content-Length'], [ref]$contentLength)
                    }
                    if ($responseHeaders['Location']) {
                        $redirectLocation = [string]$responseHeaders['Location']
                    }
                    if ($responseHeaders['Content-Type']) {
                        $contentType = [string]$responseHeaders['Content-Type']
                    }
                    if ($responseHeaders['Server']) {
                        $webServer = [string]$responseHeaders['Server']
                    }
                }
            } catch {}

            [pscustomobject]@{
                Input            = $inputUrl
                Url              = $finalUrl
                Method           = $methodUsed
                StatusCode       = $statusCode
                ContentType      = $contentType
                ContentLength    = $contentLength
                RedirectLocation = $redirectLocation
                WebServer        = $webServer
                Error            = ''
            }
        }
    )

    $allowedStatuses = @(200, 201, 202, 204, 301, 302, 303, 307, 308, 401, 403, 405)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $liveTargets = [System.Collections.Generic.List[object]]::new()

    $errorCount = 0
    $statusFilteredCount = 0
    $noiseCount = 0
    $duplicateCount = 0
    $excludedCount = 0
    $outOfScopeCount = 0
    $invalidUriCount = 0

    foreach ($result in $rawResults) {
        if (-not $result) { continue }
        if ($result.PSObject.Properties['Error'] -and -not [string]::IsNullOrWhiteSpace([string]$result.Error)) {
            $errorCount++
            continue
        }

        $finalUrl = [string]$result.Url
        $uri = $null
        if (-not [Uri]::TryCreate($finalUrl, [UriKind]::Absolute, [ref]$uri)) {
            $invalidUriCount++
            continue
        }

        $statusCode = [int](Get-ObjectValue -InputObject $result -Names @('StatusCode', 'status-code', 'status_code') -Default 0)
        if ($statusCode -notin $allowedStatuses) {
            $statusFilteredCount++
            continue
        }

        $resolvedHost = $uri.DnsSafeHost.ToLowerInvariant()
        $path = if ($uri.AbsolutePath) { $uri.AbsolutePath } else { '/' }
        $matchedScopeIds = [System.Collections.Generic.List[string]]::new()
        $matchedScopeTypes = [System.Collections.Generic.List[string]]::new()
        $matchedAnyScope = $false
        $excludedByScope = $false

        foreach ($scopeItem in $ScopeItems) {
            if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $finalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
            $matchedAnyScope = $true

            $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $resolvedHost -Url $finalUrl -Path $path
            if ($exclusion.IsExcluded) {
                $excludedByScope = $true
                Add-ExclusionRecord -Phase 'NativeHttpProbe' -ScopeItem $scopeItem -Target $finalUrl -ExclusionResult $exclusion
                continue
            }

            $matchedScopeIds.Add($scopeItem.Id)
            $matchedScopeTypes.Add($scopeItem.Type)
        }

        if ($matchedScopeIds.Count -eq 0) {
            if ($matchedAnyScope -and $excludedByScope) {
                $excludedCount++
            } else {
                $outOfScopeCount++
            }
            continue
        }

        $analysis = Get-ReviewUrlAnalysis -Url $finalUrl -StatusCode $statusCode
        if ($analysis.IsNoise) {
            $noiseCount++
            continue
        }

        if ($seen.Contains([string]$analysis.ReviewKey)) {
            $duplicateCount++
            continue
        }

        $null = $seen.Add([string]$analysis.ReviewKey)
        $liveTargets.Add([pscustomobject]@{
                Input            = [string](Get-ObjectValue -InputObject $result -Names @('Input', 'input') -Default $finalUrl)
                Url              = $analysis.ReviewUrl
                Host             = $resolvedHost
                Scheme           = $uri.Scheme.ToLowerInvariant()
                Port             = if ($uri.IsDefaultPort) { $null } else { $uri.Port }
                Path             = $path
                StatusCode       = $statusCode
                Title            = ''
                ContentType      = [string](Get-ObjectValue -InputObject $result -Names @('ContentType', 'content-type', 'content_type') -Default '')
                ContentLength    = [int64](Get-ObjectValue -InputObject $result -Names @('ContentLength', 'content-length', 'content_length') -Default 0)
                Technologies     = @()
                RedirectLocation = [string](Get-ObjectValue -InputObject $result -Names @('RedirectLocation', 'location') -Default '')
                WebServer        = [string](Get-ObjectValue -InputObject $result -Names @('WebServer', 'webserver', 'web_server') -Default '')
                MatchedScopeIds  = @($matchedScopeIds)
                MatchedTypes     = @($matchedScopeTypes | Select-Object -Unique)
                Source           = 'native-http-fallback'
            }) | Out-Null
    }

    $summaryLine = "NATIVE_FALLBACK|input={0}|selected={1}|retained={2}|errors={3}|status_filtered={4}|noise={5}|duplicate={6}|excluded={7}|out_of_scope={8}|invalid_uri={9}" -f $InputUrls.Count, $selectedInputs.Count, $liveTargets.Count, $errorCount, $statusFilteredCount, $noiseCount, $duplicateCount, $excludedCount, $outOfScopeCount, $invalidUriCount
    if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Layout -and $script:ScopeForgeContext.Layout.HttpxBatchLog) {
        Write-ScopeForgeDiagnosticLine -Path $script:ScopeForgeContext.Layout.HttpxBatchLog -Line $summaryLine
    }
    Write-ReconLog -Level WARN -Message $summaryLine

    return @($liveTargets)
}

function Get-TriageReconData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$DiscoveredUrls,
        [Parameter(Mandatory)][pscustomobject]$TriageState
    )

    $TriageState = ConvertTo-ScopeForgeTriageState -State $TriageState

    $ignoreKeys = if ($TriageState -and $null -ne $TriageState.IgnoreKeys) {
        $TriageState.IgnoreKeys
    } else {
        New-ScopeForgeStringSet
    }

    $falsePositiveKeys = if ($TriageState -and $null -ne $TriageState.FalsePositiveKeys) {
        $TriageState.FalsePositiveKeys
    } else {
        New-ScopeForgeStringSet
    }

    $validatedKeys = if ($TriageState -and $null -ne $TriageState.ValidatedKeys) {
        $TriageState.ValidatedKeys
    } else {
        New-ScopeForgeStringSet
    }

    $seenKeysState = if ($TriageState -and $null -ne $TriageState.SeenKeys) {
        $TriageState.SeenKeys
    } else {
        New-ScopeForgeStringSet
    }

    $liveIndex = @{}
    foreach ($liveTarget in $LiveTargets) {
        $analysis = Get-ReviewUrlAnalysis -Url $liveTarget.Url -StatusCode ([int]$liveTarget.StatusCode)
        if (-not $liveIndex.ContainsKey($analysis.ReviewKey)) {
            $liveIndex[$analysis.ReviewKey] = $liveTarget
        }
    }

    $patterns = @(
        @{ Category = 'Auth'; Family = 'Auth'; Score = 4; Reason = 'Authentication surface'; Pattern = '(?i)(^|[/._?&=-])(login|signin|sign-in|logout|register|signup|auth|oauth|sso|session|token|refresh|mfa|verify|password|forgot-password)([/._?&=-]|$)' },
        @{ Category = 'Admin'; Family = 'Administrative'; Score = 4; Reason = 'Administrative surface'; Pattern = '(?i)(^|[/._?&=-])(admin|dashboard|manage|console|panel|backoffice|staff|portal)([/._?&=-]|$)' },
        @{ Category = 'API'; Family = 'API'; Score = 4; Reason = 'API or schema surface'; Pattern = '(?i)(/api(?:/|$)|/graphql(?:/|$)|swagger|openapi|graphiql|api-docs|/v[0-9]+(?:/|$))' },
        @{ Category = 'Redirect'; Family = 'Redirect'; Score = 3; Reason = 'Redirect or callback workflow'; Pattern = '(?i)(callback|redirect(?:_uri)?|return(?:url)?|continue|next=|url=|oidc_)' },
        @{ Category = 'Files'; Family = 'Files'; Score = 3; Reason = 'File handling workflow'; Pattern = '(?i)(upload|download|export|import|attachment|avatar|file|document)' },
        @{ Category = 'Debug'; Family = 'Operations'; Score = 3; Reason = 'Debug or verbose endpoint'; Pattern = '(?i)(debug|trace|stack|exception|error|dump|logs?)' },
        @{ Category = 'Config'; Family = 'Operations'; Score = 4; Reason = 'Configuration or backup artifact'; Pattern = '(?i)(config|env|backup|bak|old|zip|tar|yaml|yml)' },
        @{ Category = 'Operations'; Family = 'Operations'; Score = 3; Reason = 'Operational endpoint'; Pattern = '(?i)(status|health|metrics|actuator|prometheus|ready|live|monitoring)' },
        @{ Category = 'Discovery'; Family = 'Discovery'; Score = 2; Reason = 'Discovery helper'; Pattern = '(?i)(robots\.txt|sitemap\.xml|security\.txt|humans\.txt)' }
    )

    $filtered = [System.Collections.Generic.List[object]]::new()
    $reviewable = [System.Collections.Generic.List[object]]::new()
    $noise = [System.Collections.Generic.List[object]]::new()
    $seenReviewKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $DiscoveredUrls) {
        if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Url)) { continue }

        $contentType = Get-ObjectValue -InputObject $entry -Names @('ContentType') -Default ''
        $statusCodeValue = Get-ObjectValue -InputObject $entry -Names @('StatusCode') -Default 0

        $analysis = Get-ReviewUrlAnalysis -Url ([string]$entry.Url) -ContentType ([string]$contentType) -StatusCode ([int]$statusCodeValue)
        if ($seenReviewKeys.Contains($analysis.ReviewKey)) { continue }
        $null = $seenReviewKeys.Add($analysis.ReviewKey)

        $statusCode = [int]$statusCodeValue        
        $pathQuery = [string]$analysis.PathAndQuery
        $score = 0
        $reasons = [System.Collections.Generic.List[string]]::new()
        $categories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $familyScores = @{}
        $suppressionReason = ''

        switch ($statusCode) {
            0 {
                $suppressionReason = 'status-0'
                $reasons.Add('HTTP status unavailable during crawl') | Out-Null
                $categories.Add('Unstable') | Out-Null
            }
            404 {
                $suppressionReason = 'status-404'
                $reasons.Add('Missing endpoint during crawl validation') | Out-Null
                $categories.Add('Dead') | Out-Null
            }
            410 {
                $suppressionReason = 'status-410'
                $reasons.Add('Gone endpoint during crawl validation') | Out-Null
                $categories.Add('Dead') | Out-Null
            }
        }

        foreach ($pattern in $patterns) {
            if ($pathQuery -match $pattern.Pattern) {
                $score += [int]$pattern.Score
                $reasons.Add($pattern.Reason) | Out-Null
                $categories.Add($pattern.Category) | Out-Null
                if (-not $familyScores.ContainsKey($pattern.Family)) { $familyScores[$pattern.Family] = 0 }
                $familyScores[$pattern.Family] += [int]$pattern.Score
            }
        }

        if ($statusCode -in 401, 403) {
            $score += 3
            $reasons.Add('Access-controlled endpoint') | Out-Null
            $categories.Add('Protected') | Out-Null
            if (-not $familyScores.ContainsKey('Protected')) { $familyScores['Protected'] = 0 }
            $familyScores['Protected'] += 3
        } elseif ($statusCode -eq 405) {
            $score += 1
            $reasons.Add('Method-aware endpoint') | Out-Null
        }

        if ([string]$contentType -match '(?i)\b(?:application|text)/(?:problem\+)?json\b') {
            $score += 2
            $reasons.Add('Structured JSON response') | Out-Null
            $categories.Add('API') | Out-Null
            if (-not $familyScores.ContainsKey('API')) { $familyScores['API'] = 0 }
            $familyScores['API'] += 2
        }

        $liveMatch = $liveIndex[$analysis.ReviewKey]
        if ($liveMatch -and $liveMatch.Title) {
            if ($liveMatch.Title -match '(?i)(login|sign in|dashboard|portal|swagger|graphql|api)') {
                $score += 2
                $reasons.Add('Interesting page title') | Out-Null
            }
        }

        $priority = switch ($score) {
            { $_ -ge 9 } { 'Critical'; break }
            { $_ -ge 6 } { 'High'; break }
            { $_ -ge 3 } { 'Medium'; break }
            default { 'Low' }
        }

        $primaryFamily = if ($familyScores.Count -gt 0) {
            ($familyScores.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } | Select-Object -First 1 -ExpandProperty Key)
        } else {
            'General'
        }

        $stateStatus = 'new'

        if ($null -ne $ignoreKeys -and $ignoreKeys.Contains([string]$analysis.ReviewKey)) {
            $stateStatus = 'ignored'
        }
        elseif ($null -ne $falsePositiveKeys -and $falsePositiveKeys.Contains([string]$analysis.ReviewKey)) {
            $stateStatus = 'false-positive'
        }
        elseif ($null -ne $validatedKeys -and $validatedKeys.Contains([string]$analysis.ReviewKey)) {
            $stateStatus = 'validated'
        }
        elseif ($null -ne $seenKeysState -and $seenKeysState.Contains([string]$analysis.ReviewKey)) {
            $stateStatus = 'seen-before'
        }

        $record = [pscustomobject]@{
            Url           = $analysis.ReviewUrl
            OriginalUrl   = [string]$entry.Url
            ReviewKey     = $analysis.ReviewKey
            Host          = $analysis.Host
            StatusCode    = $statusCode
            Score         = $score
            Priority      = $priority
            PriorityRank  = switch ($priority) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } default { 3 } }
            PrimaryFamily = $primaryFamily
            Categories    = @($categories | Sort-Object)
            Reasons       = @($reasons | Select-Object -Unique)
            ScopeId       = $entry.ScopeId
            Source        = $entry.Source
            Title         = if ($liveMatch) { $liveMatch.Title } else { '' }
            ContentType   = [string]$contentType
            Technologies  = if ($liveMatch) { $liveMatch.Technologies } else { @() }
            PathAndQuery  = $analysis.PathAndQuery
            NoiseTags     = @($analysis.NoiseTags)
            StateStatus   = $stateStatus
            SeenBefore    = [bool]($stateStatus -eq 'seen-before')
            HasVolatileParams = [bool]$analysis.HasVolatileParams
            TriageSuppressionReason = $suppressionReason
        }

        if ($analysis.IsNoise) {
            $noise.Add($record) | Out-Null
            continue
        }

        $filtered.Add($record) | Out-Null

        $suppressedByState = $stateStatus -in @('ignored', 'false-positive')
        $suppressedByReachability = -not [string]::IsNullOrWhiteSpace($suppressionReason)
        $reviewableSignal = ($score -gt 0) -or ($statusCode -in 401,403,405)
        if (-not $suppressedByState -and -not $suppressedByReachability -and $reviewableSignal) {
            $reviewable.Add($record) | Out-Null
        }
    }

    $orderedReviewable = @($reviewable | Sort-Object -Property StateStatus, PriorityRank, @{ Expression = 'Score'; Descending = $true }, Url)
    $preferredShortlist = @($orderedReviewable | Where-Object { $_.StateStatus -eq 'new' })
    $shortlist = @($preferredShortlist | Select-Object -First 15)
    if ($shortlist.Count -lt 15) {
        $needed = 15 - $shortlist.Count
        $fill = @($orderedReviewable | Where-Object { $shortlist.ReviewKey -notcontains $_.ReviewKey } | Select-Object -First $needed)
        $shortlist += $fill
    }

    return [pscustomobject]@{
        FilteredFindings = @($filtered | Sort-Object -Property StateStatus, Host, Url)
        ReviewableFindings = $orderedReviewable
        NoiseFindings = @($noise | Sort-Object -Property Host, Url)
        Shortlist = @($shortlist | Sort-Object -Property PriorityRank, @{ Expression = 'Score'; Descending = $true }, Url)
        SeenReviewKeys = @($seenReviewKeys)
        StateSummary = [pscustomobject]@{
            IgnoredCount = @($filtered | Where-Object { $_.StateStatus -eq 'ignored' }).Count
            FalsePositiveCount = @($filtered | Where-Object { $_.StateStatus -eq 'false-positive' }).Count
            ValidatedCount = @($filtered | Where-Object { $_.StateStatus -eq 'validated' }).Count
            SeenBeforeCount = @($filtered | Where-Object { $_.StateStatus -eq 'seen-before' }).Count
        }
    }
}


function Get-ObjectValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$InputObject, [Parameter(Mandatory)][string[]]$Names, [object]$Default = $null)

    foreach ($name in $Names) {
        $current = $InputObject
        $resolved = $true
        foreach ($segment in $name -split '\.') {
            if ($current -is [System.Collections.IDictionary]) {
                if ($current.Contains($segment)) { $current = $current[$segment] } else { $resolved = $false; break }
            } else {
                $property = $current.PSObject.Properties[$segment]
                if ($property) { $current = $property.Value } else { $resolved = $false; break }
            }
        }
        if ($resolved -and $null -ne $current) { return $current }
    }
    return $Default
}

function ConvertTo-ArrayOrEmpty {
    [CmdletBinding()]
    param([AllowNull()][object]$Data)

    $items = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $Data) {
        return ,([object[]]$items.ToArray())
    }

    if ($Data -is [string]) {
        $items.Add([string]$Data) | Out-Null
        return ,([object[]]$items.ToArray())
    }

    if ($Data -is [System.Collections.IEnumerable] -and $Data -isnot [string]) {
        foreach ($item in $Data) {
            $items.Add($item) | Out-Null
        }
        return ,([object[]]$items.ToArray())
    }

    $items.Add($Data) | Out-Null
    return ,([object[]]$items.ToArray())
}

function Get-ScopeForgeItemCount {
    [CmdletBinding()]
    param([AllowNull()][object]$Data)

    if ($null -eq $Data) { return 0 }

    if ($Data -is [string]) {
        return $(if ([string]::IsNullOrWhiteSpace($Data)) { 0 } else { 1 })
    }

    if ($Data -is [System.Collections.ICollection]) {
        return [int]$Data.Count
    }

    if ($Data -is [System.Collections.IEnumerable]) {
        $count = 0
        foreach ($item in $Data) {
            $count++
        }
        return $count
    }

    return 1
}

function Write-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Data)

    Set-Content -LiteralPath $Path -Value ($Data | ConvertTo-Json -Depth 100) -Encoding utf8
}

function Export-FlatCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value '' -Encoding utf8
        return
    }

    $normalizedRows = foreach ($row in $Rows) {
        $projection = [ordered]@{}
        foreach ($property in $row.PSObject.Properties) {
            if ($property.Value -is [System.Collections.IEnumerable] -and $property.Value -isnot [string]) {
                $projection[$property.Name] = ($property.Value | ForEach-Object { [string]$_ }) -join '; '
            } else {
                $projection[$property.Name] = $property.Value
            }
        }
        [pscustomobject]$projection
    }
    $normalizedRows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
}

function Get-ErrorRecommendation {
    [CmdletBinding()]
    param(
        [string]$ErrorCode,
        [string]$Tool
    )

    switch ($ErrorCode) {
        'ToolMissing' { return "Install or restore '$Tool', or rerun with -NoInstall disabled." }
        'ToolExitCode' { return "Inspect tools.log for '$Tool', then retry with fewer threads or a higher timeout." }
        'ToolTimeout' { return "Increase timeoutSeconds or reduce concurrency for '$Tool'." }
        'ParseError' { return 'Inspect the raw output file and tool version; malformed output was skipped.' }
        'InvalidBooleanInConfig' { return 'Use JSON booleans true/false without quotes in 02-run-settings.json.' }
        default { return 'Inspect errors.log and tools.log for details, then rerun with a narrower scope or safer preset.' }
    }
}

function Add-ErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Message,
        [string]$Target,
        [string]$Details,
        [string]$Tool,
        [Nullable[int]]$ExitCode,
        [string]$ErrorCode,
        [string]$Recommendation
    )

    $resolvedErrorCode = if ($ErrorCode) {
        $ErrorCode
    } elseif ($Message -like 'Command timed out*') {
        'ToolTimeout'
    } elseif ($Message -like '*non-zero exit code*') {
        'ToolExitCode'
    } else {
        'RuntimeError'
    }
    $record = [pscustomobject]@{
        Timestamp      = [DateTimeOffset]::Now.ToString('o')
        Phase          = $Phase
        Tool           = $Tool
        ErrorCode      = $resolvedErrorCode
        ExitCode       = $ExitCode
        Target         = $Target
        Message        = $Message
        Details        = $Details
        Recommendation = $(if ($Recommendation) { $Recommendation } else { Get-ErrorRecommendation -ErrorCode $resolvedErrorCode -Tool $Tool })
    }
    if ($script:ScopeForgeContext) { $script:ScopeForgeContext.Errors.Add($record) }
    Write-ReconLog -Level ERROR -Message ("[{0}] {1}{2}" -f $Phase, $Message, $(if ($Target) { " :: $Target" } else { '' }))
}

function Add-ExclusionRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][pscustomobject]$ScopeItem, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][pscustomobject]$ExclusionResult)

    $record = [pscustomobject]@{
        Timestamp   = [DateTimeOffset]::Now.ToString('o')
        Phase       = $Phase
        ScopeId     = $ScopeItem.Id
        ScopeType   = $ScopeItem.Type
        ScopeValue  = $ScopeItem.NormalizedValue
        Target      = $Target
        Token       = $ExclusionResult.Token
        MatchedOn   = $ExclusionResult.MatchedOn
        MatchedText = $ExclusionResult.MatchedText
    }

    if ($script:ScopeForgeContext) { $script:ScopeForgeContext.Exclusions.Add($record) }

    $message = ("[{0}] Excluded by token '{1}' on {2}: {3}" -f $Phase, $ExclusionResult.Token, $ExclusionResult.MatchedOn, $Target)
    Write-ReconLog -Level EXCLUDED -Message $message -NoConsole
    Write-CompactedExclusionConsoleMessage -Record $record
}

function New-HostInventoryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetHost)

    return [ordered]@{
        Host           = $TargetHost
        Discovery      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        SourceScopeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        SourceTypes    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        CandidateUrls  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        RootDomains    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
}

function Get-OrCreateHostInventoryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$HostMap, [Parameter(Mandatory)][string]$TargetHost)

    if (-not $HostMap.ContainsKey($TargetHost)) {
        $HostMap[$TargetHost] = New-HostInventoryRecord -TargetHost $TargetHost
    }
    return $HostMap[$TargetHost]
}

function Get-PassiveSubdomains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootDomain,
        [Parameter(Mandatory)][string]$SubfinderPath,
        [Parameter(Mandatory)][string]$RawOutputPath,
        [int]$TimeoutSeconds = 60
    )

    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-subfinder-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-subfinder-{0}.err" -f ([Guid]::NewGuid().ToString('N')))

    try {
        $attemptTimeouts = @(
            [Math]::Max($TimeoutSeconds * 3, 120),
            [Math]::Max($TimeoutSeconds * 6, 240)
        )

        $result = $null
        $completed = $false

        for ($attempt = 0; $attempt -lt $attemptTimeouts.Count; $attempt++) {
            $currentTimeout = [int]$attemptTimeouts[$attempt]
            try {
                $result = Invoke-ExternalCommand -FilePath $SubfinderPath -Arguments @('-silent', '-d', $RootDomain) -TimeoutSeconds $currentTimeout -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
                $completed = $true
                break
            } catch {
                if ($attempt -lt ($attemptTimeouts.Count - 1)) {
                    Write-ReconLog -Level WARN -Message ("subfinder a depasse le delai pour {0}. Nouvelle tentative avec timeout={1}s." -f $RootDomain, $attemptTimeouts[$attempt + 1])
                    continue
                }

                $details = $_.Exception.Message
                if (Test-Path -LiteralPath $stderrFile) {
                    try {
                        $stderrContent = Get-Content -LiteralPath $stderrFile -Raw -Encoding utf8
                        if (-not [string]::IsNullOrWhiteSpace($stderrContent)) {
                            $details = "{0}`n{1}" -f $details, $stderrContent.Trim()
                        }
                    } catch {
                    }
                }

                Add-ErrorRecord -Phase 'PassiveDiscovery' -Target $RootDomain -Message 'subfinder execution failed or timed out.' -Details $details -Tool 'subfinder' -ErrorCode 'ToolTimeout'
                Write-ReconLog -Level WARN -Message ("subfinder timed out or failed for {0}. Passive discovery will continue without it." -f $RootDomain)

                if (-not (Test-Path -LiteralPath $RawOutputPath)) {
                    Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8
                }

                return @()
            }
        }

        if (-not $completed) { return @() }

        $rawLines = @(
            if (Test-Path -LiteralPath $stdoutFile) {
                Get-Content -LiteralPath $stdoutFile -Encoding utf8
            }
        )

        if ($rawLines.Count -gt 0) {
            Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
            Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
        } elseif (-not (Test-Path -LiteralPath $RawOutputPath)) {
            Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8
        }

        if ($result.ExitCode -ne 0) {
            Add-ErrorRecord -Phase 'PassiveDiscovery' -Target $RootDomain -Message 'subfinder returned a non-zero exit code.' -Details $result.StdErr -Tool 'subfinder' -ExitCode $result.ExitCode -ErrorCode 'ToolExitCode'
        }

        return @(
            $rawLines |
            ForEach-Object { $_.Trim().TrimEnd('.').ToLowerInvariant() } |
            Where-Object { $_ -and (Test-ValidDnsName -Name $_) } |
            Select-Object -Unique
        )
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-HistoricalUrls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$GauPath,
        [Parameter(Mandatory)][string]$RawOutputPath,
        [bool]$IncludeSubdomains = $false,
        [int]$TimeoutSeconds = 60
    )

    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-gau-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-gau-{0}.err" -f ([Guid]::NewGuid().ToString('N')))

    try {
        $arguments = @()
        if ($IncludeSubdomains) { $arguments += '--subs' }
        $arguments += $Target

        try {
            $result = Invoke-ExternalCommand `
                -FilePath $GauPath `
                -Arguments $arguments `
                -TimeoutSeconds ([Math]::Max($TimeoutSeconds * 4, 120)) `
                -StdOutPath $stdoutFile `
                -StdErrPath $stderrFile `
                -IgnoreExitCode
        } catch {
            Add-ErrorRecord `
                -Phase 'HistoricalDiscovery' `
                -Target $Target `
                -Message $_.Exception.Message `
                -Tool 'gau' `
                -ErrorCode $(if ($_.Exception.Message -like 'Command timed out*') { 'ToolTimeout' } else { 'RuntimeError' })

            Write-ReconLog -Level WARN -Message "gau a echoue pour $Target, poursuite sans URLs historiques gau."
            return @()
        }

        $rawLines = @(
            if (Test-Path -LiteralPath $stdoutFile) {
                Get-Content -LiteralPath $stdoutFile -Encoding utf8
            }
        )

        if ($rawLines.Count -gt 0) {
            Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
            Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
        }

        if ($result.ExitCode -ne 0) {
            Add-ErrorRecord `
                -Phase 'HistoricalDiscovery' `
                -Target $Target `
                -Message 'gau returned a non-zero exit code.' `
                -Details $result.StdErr `
                -Tool 'gau' `
                -ExitCode $result.ExitCode `
                -ErrorCode 'ToolExitCode'
        }

        $urls = @(
            $rawLines |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^https?://' } |
            ForEach-Object {
                $uri = $null
                if ([Uri]::TryCreate($_, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
                    $uri.AbsoluteUri
                }
            } |
            Where-Object { $_ } |
            Select-Object -Unique
        )

        return $urls
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-WaybackUrls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$WaybackUrlsPath,
        [Parameter(Mandatory)][string]$RawOutputPath,
        [int]$TimeoutSeconds = 60
    )

    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-wayback-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-wayback-{0}.err" -f ([Guid]::NewGuid().ToString('N')))

    try {
        $attemptTimeouts = @(
            [Math]::Max($TimeoutSeconds * 4, 180),
            [Math]::Max($TimeoutSeconds * 8, 300)
        )

        $result = $null
        $completed = $false

        for ($attempt = 0; $attempt -lt $attemptTimeouts.Count; $attempt++) {
            $currentTimeout = [int]$attemptTimeouts[$attempt]
            try {
                $result = Invoke-ExternalCommand -FilePath $WaybackUrlsPath -Arguments @($Target) -TimeoutSeconds $currentTimeout -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
                $completed = $true
                break
            } catch {
                if ($attempt -lt ($attemptTimeouts.Count - 1)) {
                    Write-ReconLog -Level WARN -Message ("waybackurls a depasse le delai pour {0}. Nouvelle tentative avec timeout={1}s." -f $Target, $attemptTimeouts[$attempt + 1])
                    continue
                }

                Add-ErrorRecord -Phase 'HistoricalDiscovery' -Target $Target -Message $_.Exception.Message -Tool 'waybackurls' -ErrorCode $(if ($_.Exception.Message -like 'Command timed out*') { 'ToolTimeout' } else { 'RuntimeError' })
                Write-ReconLog -Level WARN -Message ("waybackurls a echoue pour {0}, poursuite sans URLs historiques wayback." -f $Target)
                return @()
            }
        }

        if (-not $completed) { return @() }

        $rawLines = @(
            if (Test-Path -LiteralPath $stdoutFile) {
                Get-Content -LiteralPath $stdoutFile -Encoding utf8
            }
        )

        if ($rawLines.Count -gt 0) {
            Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
            Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
        }

        if ($result.ExitCode -ne 0) {
            Add-ErrorRecord -Phase 'HistoricalDiscovery' -Target $Target -Message 'waybackurls returned a non-zero exit code.' -Details $result.StdErr -Tool 'waybackurls' -ExitCode $result.ExitCode -ErrorCode 'ToolExitCode'
        }

        return @(
            $rawLines |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^https?://' } |
            ForEach-Object {
                $uri = $null
                if ([Uri]::TryCreate($_, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
                    $uri.AbsoluteUri
                }
            } |
            Where-Object { $_ } |
            Select-Object -Unique
        )
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-HakrawlerCrawl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][string]$HakrawlerPath,
        [Parameter(Mandatory)][string]$RawOutputPath,
        [Parameter(Mandatory)][string]$TempDirectory,
        [int]$Depth = 2,
        [int]$TimeoutSeconds = 30,
        [switch]$RespectSchemeOnly
    )

    if (-not $LiveTargets -or $LiveTargets.Count -eq 0) { return @() }

    $helpText = Get-ToolHelpText -ToolPath $HakrawlerPath
    $targetFile = Join-Path $TempDirectory ("hakrawler-input-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $driverFile = Join-Path $TempDirectory ("hakrawler-driver-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
    $stdoutFile = Join-Path $TempDirectory ("hakrawler-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $stderrFile = Join-Path $TempDirectory ("hakrawler-{0}.err" -f ([Guid]::NewGuid().ToString('N')))
    $argumentsFile = $null

    try {
        $seedUrls = $LiveTargets | Select-Object -ExpandProperty Url -Unique
        Set-Content -LiteralPath $targetFile -Value $seedUrls -Encoding utf8

        $driver = @'
param(
    [Parameter(Mandatory)][string]$InputFile,
    [Parameter(Mandatory)][string]$ToolPath,
    [Parameter(Mandatory)][string]$ArgumentsFile
)
$targets = Get-Content -LiteralPath $InputFile -Encoding utf8
$args = Get-Content -LiteralPath $ArgumentsFile -Encoding utf8
$targets | & $ToolPath @args
'@
        Set-Content -LiteralPath $driverFile -Value $driver -Encoding utf8

        $hakrawlerArgs = [System.Collections.Generic.List[string]]::new()
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-plain') { $hakrawlerArgs.Add('-plain') | Out-Null }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-depth') { $hakrawlerArgs.Add('-depth') | Out-Null; $hakrawlerArgs.Add([string]$Depth) | Out-Null }
        elseif (Test-ToolFlagSupport -HelpText $helpText -Flag '-d') { $hakrawlerArgs.Add('-d') | Out-Null; $hakrawlerArgs.Add([string]$Depth) | Out-Null }

        $argumentsFile = Join-Path $TempDirectory ("hakrawler-args-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $argumentsFile -Value @($hakrawlerArgs) -Encoding utf8

        $pwshCommand = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $pwshPath = if ($pwshCommand) { $pwshCommand.Source } else {
            $candidate = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            if (Test-Path -LiteralPath $candidate) { $candidate } else { $null }
        }
        if (-not $pwshPath) { throw 'pwsh executable not found for hakrawler driver execution.' }

        $result = Invoke-ExternalCommand -FilePath $pwshPath -Arguments @('-NoLogo', '-NoProfile', '-File', $driverFile, '-InputFile', $targetFile, '-ToolPath', $HakrawlerPath, '-ArgumentsFile', $argumentsFile) -TimeoutSeconds ([Math]::Max($TimeoutSeconds * 6, 60)) -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
        if ($result.ExitCode -ne 0) {
            Add-ErrorRecord -Phase 'SupplementalCrawl' -Message 'hakrawler returned a non-zero exit code.' -Details $result.StdErr -Tool 'hakrawler' -ExitCode $result.ExitCode -ErrorCode 'ToolExitCode'
        }

        $rawLines = @(
            if (Test-Path -LiteralPath $stdoutFile) {
                Get-Content -LiteralPath $stdoutFile -Encoding utf8
            }
        )
        if ($rawLines.Count -gt 0) {
            Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
            Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
        }

        $results = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $rawLines) {
            $candidate = $line.Trim()
            if ($candidate -notmatch '^https?://') { continue }
            $uri = $null
            if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri)) { continue }

            $matchedScopeItem = $null
            foreach ($scopeItem in $ScopeItems) {
                if (Test-ScopeMatch -ScopeItem $scopeItem -Url $candidate -RespectSchemeOnly:$RespectSchemeOnly) {
                    $matchedScopeItem = $scopeItem
                    break
                }
            }
            if (-not $matchedScopeItem) { continue }

            $resolvedHost = $uri.DnsSafeHost.ToLowerInvariant()
            $exclusion = Test-ExclusionMatch -ScopeItem $matchedScopeItem -TargetHost $resolvedHost -Url $candidate -Path $uri.AbsolutePath
            if ($exclusion.IsExcluded) {
                Add-ExclusionRecord -Phase 'SupplementalCrawl' -ScopeItem $matchedScopeItem -Target $candidate -ExclusionResult $exclusion
                continue
            }

            $key = Get-CanonicalUrlKey -Url $candidate
            if ($seen.Contains($key)) { continue }
            $null = $seen.Add($key)
            $results.Add([pscustomobject]@{
                    Url         = $candidate
                    Host        = $resolvedHost
                    Scheme      = $uri.Scheme.ToLowerInvariant()
                    Path        = $uri.AbsolutePath
                    Query       = $uri.Query
                    ScopeId     = $matchedScopeItem.Id
                    ScopeType   = $matchedScopeItem.Type
                    ScopeValue  = $matchedScopeItem.NormalizedValue
                    SeedUrl     = $candidate
                    Source      = 'hakrawler'
                    StatusCode  = 0
                    ContentType = ''
                })
        }

        return @($results)
    } finally {
        Remove-Item -LiteralPath $targetFile, $driverFile, $stdoutFile, $stderrFile, $argumentsFile -Force -ErrorAction SilentlyContinue
    }
}

function Merge-DiscoveredUrlResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Inputs)

    $merged = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $Inputs) {
        if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Url)) { continue }
        $key = Get-CanonicalUrlKey -Url ([string]$entry.Url)
        if ($seen.Contains($key)) { continue }
        $null = $seen.Add($key)
        $merged.Add($entry)
    }

    return @($merged | Sort-Object -Property Host, Url)
}

function Invoke-HttpProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$InputUrls,
        [Parameter(Mandatory)][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][string]$HttpxPath,
        [Parameter(Mandatory)][string]$RawOutputPath,
        [string]$UniqueUserAgent,
        [int]$Threads = 10,
        [int]$TimeoutSeconds = 30,
        [switch]$RespectSchemeOnly,
        [switch]$AppendOutput
    )

    if (-not $InputUrls -or $InputUrls.Count -eq 0) { return @() }

    $helpText = Get-ToolHelpText -ToolPath $HttpxPath
    $normalizedInputUrls = @(
        $InputUrls |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Sort-Object -Unique
    )

    if (-not $normalizedInputUrls -or $normalizedInputUrls.Count -eq 0) {
        Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8
        return @()
    }

    $batchSize = [Math]::Min([Math]::Max(($Threads * 15), 75), 150)
    if ($normalizedInputUrls.Count -lt $batchSize) { $batchSize = $normalizedInputUrls.Count }
    if ($batchSize -lt 1) { $batchSize = 1 }

    $baseArguments = @(
        '-silent',
        '-json',
        '-threads', [string]$Threads,
        '-timeout', [string]$TimeoutSeconds,
        '-title',
        '-status-code',
        '-content-length'
    )

    if (Test-ToolFlagSupport -HelpText $helpText -Flag '-content-type') { $baseArguments += '-content-type' }
    if (Test-ToolFlagSupport -HelpText $helpText -Flag '-tech-detect') { $baseArguments += '-tech-detect' }
    if (Test-ToolFlagSupport -HelpText $helpText -Flag '-follow-redirects') { $baseArguments += '-follow-redirects' }
    if (Test-ToolFlagSupport -HelpText $helpText -Flag '-location') { $baseArguments += '-location' }

    if ($UniqueUserAgent) {
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-H') {
            $baseArguments += @('-H', "User-Agent: $UniqueUserAgent")
        } elseif (Test-ToolFlagSupport -HelpText $helpText -Flag '-header') {
            $baseArguments += @('-header', "User-Agent: $UniqueUserAgent")
        }
    }

    if (-not $AppendOutput) {
        Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8
        Set-Content -LiteralPath $script:ScopeForgeContext.Layout.HttpxBatchLog -Value '' -Encoding utf8
    } else {
        if (-not (Test-Path -LiteralPath $RawOutputPath)) {
            Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8
        }
        if (-not (Test-Path -LiteralPath $script:ScopeForgeContext.Layout.HttpxBatchLog)) {
            Set-Content -LiteralPath $script:ScopeForgeContext.Layout.HttpxBatchLog -Value '' -Encoding utf8
        }
        Write-ScopeForgeDiagnosticLine -Path $script:ScopeForgeContext.Layout.HttpxBatchLog -Line ("RETRY|mode=reduced-httpx|input={0}" -f $normalizedInputUrls.Count)
    }

    $liveTargets = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $batchCount = [int][Math]::Ceiling($normalizedInputUrls.Count / [double]$batchSize)
    $emptyBatchDiagnosticsPerformed = 0
    $emptyBatchDiagnosticLimit = 3
    $emptyBatchSnapshotCaptured = $false

    for ($offset = 0; $offset -lt $normalizedInputUrls.Count; $offset += $batchSize) {
        $batchIndex = [int][Math]::Floor($offset / $batchSize) + 1
        $endIndex = [Math]::Min(($offset + $batchSize - 1), ($normalizedInputUrls.Count - 1))
        $currentBatch = @($normalizedInputUrls[$offset..$endIndex])

        Write-StageProgress -Step 4 -Title 'Validation HTTP' -Percent ([Math]::Floor(($batchIndex / $batchCount) * 100)) -Status ("Batch {0}/{1} - {2} URL(s)" -f $batchIndex, $batchCount, $currentBatch.Count)

        $inputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-input-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
        $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))
        $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-{0}.err" -f ([Guid]::NewGuid().ToString('N')))

        try {
            Set-Content -LiteralPath $inputFile -Value $currentBatch -Encoding utf8

            $arguments = @($baseArguments + @('-l', $inputFile))
            $batchTimeoutSeconds = [Math]::Max(($TimeoutSeconds * 6), 180)

            Write-ReconLog -Level INFO -Message ("httpx batch {0}/{1}: probing {2} URL(s)." -f $batchIndex, $batchCount, $currentBatch.Count)

            $result = $null
            try {
                $result = Invoke-ExternalCommand -FilePath $HttpxPath -Arguments $arguments -TimeoutSeconds $batchTimeoutSeconds -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
            } catch {
                $message = $_.Exception.Message
                if ($message -like 'Command timed out*') {
                    Add-ErrorRecord -Phase 'HttpProbe' -Message $message -Details ("batch {0}/{1}, size={2}, mode=full" -f $batchIndex, $batchCount, $currentBatch.Count) -Tool 'httpx' -ErrorCode 'ToolTimeout'
                    Write-ReconLog -Level WARN -Message ("httpx timed out on batch {0}/{1}. Retrying without redirect and tech detection." -f $batchIndex, $batchCount)

                    $fallbackArguments = @(
                        $arguments |
                        Where-Object { $_ -notin @('-tech-detect', '-follow-redirects', '-location') }
                    )

                    try {
                        $result = Invoke-ExternalCommand -FilePath $HttpxPath -Arguments $fallbackArguments -TimeoutSeconds ([Math]::Max(($TimeoutSeconds * 8), 240)) -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
                    } catch {
                        Add-ErrorRecord -Phase 'HttpProbe' -Message $_.Exception.Message -Details ("batch {0}/{1}, size={2}, mode=fallback" -f $batchIndex, $batchCount, $currentBatch.Count) -Tool 'httpx' -ErrorCode $(if ($_.Exception.Message -like 'Command timed out*') { 'ToolTimeout' } else { 'RuntimeError' })
                        Write-ReconLog -Level WARN -Message ("Skipping httpx batch {0}/{1} after repeated failure." -f $batchIndex, $batchCount)
                        continue
                    }
                } else {
                    Add-ErrorRecord -Phase 'HttpProbe' -Message $message -Details ("batch {0}/{1}, size={2}" -f $batchIndex, $batchCount, $currentBatch.Count) -Tool 'httpx' -ErrorCode 'RuntimeError'
                    Write-ReconLog -Level WARN -Message ("Skipping httpx batch {0}/{1} after runtime failure." -f $batchIndex, $batchCount)
                    continue
                }
            }

            $stdoutCaptured = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw -Encoding utf8 } else { '' }
            if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace([string]$stdoutCaptured)) {
                Write-ReconLog -Level WARN -Message ("httpx batch {0}/{1} returned empty stdout via redirected capture. Retrying with direct stdio capture." -f $batchIndex, $batchCount)
                try {
                    $retryResult = Invoke-ExternalCommandArgumentSafe -FilePath $HttpxPath -Arguments $arguments -TimeoutSeconds $batchTimeoutSeconds -IgnoreExitCode
                    Set-Content -LiteralPath $stdoutFile -Value ([string]$retryResult.StdOut) -Encoding utf8
                    Set-Content -LiteralPath $stderrFile -Value ([string]$retryResult.StdErr) -Encoding utf8
                    $result = [pscustomobject]@{
                        ExitCode   = $retryResult.ExitCode
                        StdOut     = $retryResult.StdOut
                        StdErr     = $retryResult.StdErr
                        StdOutPath = $stdoutFile
                        StdErrPath = $stderrFile
                        FilePath   = $retryResult.FilePath
                        Arguments  = $retryResult.Arguments
                    }
                } catch {
                    Write-ReconLog -Level WARN -Message ("httpx batch {0}/{1} direct stdio retry failed. Continuing with the original empty capture." -f $batchIndex, $batchCount)
                }
            }

            if (Test-Path -LiteralPath $stdoutFile) {
                $stdoutRaw = Get-Content -LiteralPath $stdoutFile -Raw -Encoding utf8
                if (-not [string]::IsNullOrWhiteSpace($stdoutRaw)) {
                    Add-Content -LiteralPath $RawOutputPath -Value $stdoutRaw -Encoding utf8
                    if (-not $stdoutRaw.EndsWith([Environment]::NewLine)) {
                        Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
                    }
                }
            }

            if ($result.ExitCode -ne 0) {
                Add-ErrorRecord -Phase 'HttpProbe' -Message 'httpx returned a non-zero exit code.' -Details $result.StdErr -Tool 'httpx' -ExitCode $result.ExitCode -ErrorCode 'ToolExitCode'
            }

            $lines = @(
                if (Test-Path -LiteralPath $stdoutFile) {
                    Get-Content -LiteralPath $stdoutFile -Encoding utf8
                }
            )
            $jsonParsedCount = 0
            $scopeCandidateCount = 0
            $parseErrors = 0
            $discardCounts = [ordered]@{
                missing_url = 0
                invalid_uri = 0
                out_of_scope = 0
                excluded = 0
                noise = 0
                duplicate = 0
            }
            $retainedBeforeBatch = $liveTargets.Count
            Write-ScopeForgeDiagnosticLine -Path $script:ScopeForgeContext.Layout.HttpxBatchLog -Line ("BATCH|index={0}/{1}|input={2}|stdout_lines={3}|exit={4}" -f $batchIndex, $batchCount, $currentBatch.Count, $lines.Count, $result.ExitCode)
            if (-not $emptyBatchSnapshotCaptured -and $lines.Count -eq 0 -and $script:ScopeForgeContext -and $script:ScopeForgeContext.Layout) {
                $snapshotLayout = $script:ScopeForgeContext.Layout
                $snapshotInputPath = $snapshotLayout.PSObject.Properties['HttpxEmptyBatchInput']
                $snapshotStdOutPath = $snapshotLayout.PSObject.Properties['HttpxEmptyBatchStdOut']
                $snapshotStdErrPath = $snapshotLayout.PSObject.Properties['HttpxEmptyBatchStdErr']
                $snapshotMetaPath = $snapshotLayout.PSObject.Properties['HttpxEmptyBatchMeta']
                if ($snapshotInputPath -and $snapshotStdOutPath -and $snapshotStdErrPath -and $snapshotMetaPath) {
                    if (-not (Test-Path -LiteralPath $snapshotLayout.HttpxEmptyBatchInput)) {
                        Set-Content -LiteralPath $snapshotLayout.HttpxEmptyBatchInput -Value $currentBatch -Encoding utf8
                        if (Test-Path -LiteralPath $stdoutFile) {
                            Copy-Item -LiteralPath $stdoutFile -Destination $snapshotLayout.HttpxEmptyBatchStdOut -Force
                        } else {
                            Set-Content -LiteralPath $snapshotLayout.HttpxEmptyBatchStdOut -Value '' -Encoding utf8
                        }
                        if (Test-Path -LiteralPath $stderrFile) {
                            Copy-Item -LiteralPath $stderrFile -Destination $snapshotLayout.HttpxEmptyBatchStdErr -Force
                        } else {
                            Set-Content -LiteralPath $snapshotLayout.HttpxEmptyBatchStdErr -Value '' -Encoding utf8
                        }
                        $snapshotMeta = [pscustomobject]@{
                            BatchIndex     = $batchIndex
                            BatchCount     = $batchCount
                            InputCount     = $currentBatch.Count
                            ExitCode       = $result.ExitCode
                            FirstInputUrl  = if ($currentBatch.Count -gt 0) { [string]$currentBatch[0] } else { '' }
                            CapturedAtUtc  = [DateTimeOffset]::UtcNow.ToString('o')
                        }
                        Set-Content -LiteralPath $snapshotLayout.HttpxEmptyBatchMeta -Value ($snapshotMeta | ConvertTo-Json -Depth 10) -Encoding utf8
                        Write-ScopeForgeDiagnosticLine -Path $script:ScopeForgeContext.Layout.HttpxBatchLog -Line ("BATCH_EMPTY_SNAPSHOT|index={0}/{1}|input={2}|stdout={3}|stderr={4}" -f $batchIndex, $batchCount, $currentBatch.Count, $snapshotLayout.HttpxEmptyBatchStdOut, $snapshotLayout.HttpxEmptyBatchStdErr)
                    }
                    $emptyBatchSnapshotCaptured = $true
                }
            }
            if ($lines.Count -eq 0 -and $emptyBatchDiagnosticsPerformed -lt $emptyBatchDiagnosticLimit) {
                $emptyBatchDiagnosticsPerformed++
                Invoke-HttpxEmptyBatchDiagnostic -HttpxPath $HttpxPath -HelpText $helpText -InputUrls $currentBatch -UniqueUserAgent $UniqueUserAgent -TimeoutSeconds $TimeoutSeconds -LogPath $script:ScopeForgeContext.Layout.HttpxBatchLog -BatchLabel ("index={0}/{1}" -f $batchIndex, $batchCount)
            }

            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                try {
                    $raw = $line | ConvertFrom-Json -Depth 100
                } catch {
                    $parseErrors++
                    Add-ErrorRecord -Phase 'HttpProbe' -Message 'Failed to parse httpx JSON line.' -Details $line -Tool 'httpx' -ErrorCode 'ParseError'
                    continue
                }
                $jsonParsedCount++

                $finalUrl = [string](Get-ObjectValue -InputObject $raw -Names @('url'))
                $inputValue = [string](Get-ObjectValue -InputObject $raw -Names @('input'))
                if ([string]::IsNullOrWhiteSpace($finalUrl)) {
                    $discardCounts['missing_url']++
                    continue
                }

                $uri = $null
                if (-not [Uri]::TryCreate($finalUrl, [UriKind]::Absolute, [ref]$uri)) {
                    $discardCounts['invalid_uri']++
                    continue
                }

                $resolvedHost = $uri.DnsSafeHost.ToLowerInvariant()
                $path = if ($uri.AbsolutePath) { $uri.AbsolutePath } else { '/' }
                $matchedScopeIds = [System.Collections.Generic.List[string]]::new()
                $matchedScopeTypes = [System.Collections.Generic.List[string]]::new()
                $matchedAnyScope = $false
                $excludedByScope = $false

                foreach ($scopeItem in $ScopeItems) {
                    if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $finalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                    $matchedAnyScope = $true

                    $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $resolvedHost -Url $finalUrl -Path $path
                    if ($exclusion.IsExcluded) {
                        $excludedByScope = $true
                        Add-ExclusionRecord -Phase 'HttpProbe' -ScopeItem $scopeItem -Target $finalUrl -ExclusionResult $exclusion
                        continue
                    }

                    $matchedScopeIds.Add($scopeItem.Id)
                    $matchedScopeTypes.Add($scopeItem.Type)
                }

                if ($matchedScopeIds.Count -eq 0) {
                    if ($matchedAnyScope -and $excludedByScope) {
                        $discardCounts['excluded']++
                    } else {
                        $discardCounts['out_of_scope']++
                        Write-ReconLog -Level WARN -Message ("Discarding out-of-scope live target after httpx: {0}" -f $finalUrl)
                    }
                    continue
                }

                $scopeCandidateCount++
                $reviewAnalysis = Get-ReviewUrlAnalysis -Url $finalUrl -StatusCode ([int](Get-ObjectValue -InputObject $raw -Names @('status-code', 'status_code') -Default 0))
                if ($reviewAnalysis.IsNoise) {
                    $discardCounts['noise']++
                    continue
                }
                $canonicalKey = $reviewAnalysis.ReviewKey
                if ($seen.Contains($canonicalKey)) {
                    $discardCounts['duplicate']++
                    continue
                }
                $null = $seen.Add($canonicalKey)
                $finalUrl = $reviewAnalysis.ReviewUrl

                $technologiesRaw = Get-ObjectValue -InputObject $raw -Names @('tech', 'technologies') -Default @()
                $technologies = if ($technologiesRaw -is [System.Collections.IEnumerable] -and $technologiesRaw -isnot [string]) {
                    @($technologiesRaw | ForEach-Object { [string]$_ } | Where-Object { $_ })
                } elseif ($technologiesRaw) {
                    @([string]$technologiesRaw)
                } else {
                    @()
                }

                $liveTargets.Add([pscustomobject]@{
                    Input            = $inputValue
                    Url              = $finalUrl
                    Host             = $resolvedHost
                    Scheme           = $uri.Scheme.ToLowerInvariant()
                    Port             = if ($uri.IsDefaultPort) { $null } else { $uri.Port }
                    Path             = $path
                    StatusCode       = [int](Get-ObjectValue -InputObject $raw -Names @('status-code', 'status_code') -Default 0)
                    Title            = [string](Get-ObjectValue -InputObject $raw -Names @('title') -Default '')
                    ContentType      = [string](Get-ObjectValue -InputObject $raw -Names @('content-type', 'content_type') -Default '')
                    ContentLength    = [int64](Get-ObjectValue -InputObject $raw -Names @('content-length', 'content_length') -Default 0)
                    Technologies     = $technologies
                    RedirectLocation = [string](Get-ObjectValue -InputObject $raw -Names @('location') -Default '')
                    WebServer        = [string](Get-ObjectValue -InputObject $raw -Names @('webserver', 'web_server') -Default '')
                    MatchedScopeIds  = @($matchedScopeIds)
                    MatchedTypes     = @($matchedScopeTypes | Select-Object -Unique)
                    Source           = 'httpx'
                })
            }
            $retainedAfterHttpx = $liveTargets.Count - $retainedBeforeBatch
            $discardedAfterHttpx = [int](($discardCounts.Values | Measure-Object -Sum).Sum)
            $reasonSummary = (
                $discardCounts.GetEnumerator() |
                Where-Object { $_.Value -gt 0 } |
                ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
            ) -join ','
            if ([string]::IsNullOrWhiteSpace($reasonSummary)) { $reasonSummary = 'none' }
            Write-ScopeForgeDiagnosticLine -Path $script:ScopeForgeContext.Layout.HttpxBatchLog -Line ("BATCH_SUMMARY|index={0}/{1}|input={2}|json_parsed={3}|in_scope_after_exclusions={4}|retained={5}|discarded={6}|parse_errors={7}|reasons={8}" -f $batchIndex, $batchCount, $currentBatch.Count, $jsonParsedCount, $scopeCandidateCount, $retainedAfterHttpx, $discardedAfterHttpx, $parseErrors, $reasonSummary)
        } finally {
            Remove-Item -LiteralPath $inputFile, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }

    return @($liveTargets)
}

function Get-KatanaScopeDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$ScopeItem, [Parameter(Mandatory)][string]$SeedUrl, [switch]$RespectSchemeOnly)

    $schemePattern = if ($ScopeItem.Scheme -and $RespectSchemeOnly) {
        [regex]::Escape($ScopeItem.Scheme)
    } elseif ($ScopeItem.Scheme) {
        '(?:' + [regex]::Escape($ScopeItem.Scheme) + '|http|https)'
    } else {
        'https?'
    }

    switch ($ScopeItem.Type) {
        'URL' {
            $scopeRegex = '^' + $schemePattern + '://' + [regex]::Escape($ScopeItem.Host)
            if ($ScopeItem.Port) { $scopeRegex += ':' + [regex]::Escape([string]$ScopeItem.Port) } else { $scopeRegex += '(?::\d+)?' }
            $scopeRegex += if ($ScopeItem.PathPrefix -eq '/') { '(?:/.*)?$' } else { [regex]::Escape($ScopeItem.PathPrefix) + '(?:$|/|[?#]).*' }
            return [pscustomobject]@{ SeedUrl = $ScopeItem.StartUrl; FieldScope = 'fqdn'; InScopeRegexes = @($scopeRegex); OutScopeRegexes = @(); PathPrefix = $ScopeItem.PathPrefix }
        }
        'Domain' {
            $scopeRegex = '^https?://' + [regex]::Escape($ScopeItem.Host) + '(?::\d+)?(?:/.*)?$'
            return [pscustomobject]@{ SeedUrl = $SeedUrl; FieldScope = 'fqdn'; InScopeRegexes = @($scopeRegex); OutScopeRegexes = @(); PathPrefix = '/' }
        }
        'Wildcard' {
            $hostPattern = if ($ScopeItem.IncludeApex) { '(?:[a-z0-9-]+\.)*' + [regex]::Escape($ScopeItem.RootDomain) } else { '(?:[a-z0-9-]+\.)+' + [regex]::Escape($ScopeItem.RootDomain) }
            $scopeRegex = '^' + $schemePattern + '://' + $hostPattern + '(?::\d+)?(?:/.*)?$'
            return [pscustomobject]@{ SeedUrl = $SeedUrl; FieldScope = 'rdn'; InScopeRegexes = @($scopeRegex); OutScopeRegexes = @(); PathPrefix = '/' }
        }
        default { throw "Unsupported scope type for katana definition: $($ScopeItem.Type)" }
    }
}

function Invoke-KatanaCrawl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][string]$KatanaPath,
        [Parameter(Mandatory)][string]$RawOutputPath,
        [Parameter(Mandatory)][string]$TempDirectory,
        [int]$Depth = 3,
        [int]$Threads = 10,
        [int]$TimeoutSeconds = 30,
        [string]$UniqueUserAgent,
        [switch]$RespectSchemeOnly
    )

    if (-not $LiveTargets -or $LiveTargets.Count -eq 0) { return @() }

    $helpText = Get-ToolHelpText -ToolPath $KatanaPath
    $scopeIndex = @{}
    foreach ($scopeItem in $ScopeItems) { $scopeIndex[$scopeItem.Id] = $scopeItem }

    $jobs = [System.Collections.Generic.List[object]]::new()
    $jobKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $skippedSeeds = 0

    foreach ($liveTarget in $LiveTargets) {
        $eligibility = Test-KatanaSeedEligibility -LiveTarget $liveTarget
        if (-not $eligibility.Eligible) {
            $skippedSeeds++
            Write-ScopeForgeDiagnosticLine -Path $script:ScopeForgeContext.Layout.KatanaSeedStatsLog -Line ("SKIP|seed={0}|status={1}|reason={2}" -f $liveTarget.Url, $liveTarget.StatusCode, $eligibility.Reason)
            continue
        }

        foreach ($scopeId in $liveTarget.MatchedScopeIds) {
            $scopeItem = $scopeIndex[$scopeId]
            $seedUrl = if ($scopeItem.Type -eq 'URL') { $scopeItem.StartUrl } else { $liveTarget.Url }
            $jobKey = '{0}|{1}' -f $scopeItem.Id, (Get-ReviewUrlAnalysis -Url $seedUrl).ReviewKey
            if ($jobKeys.Contains($jobKey)) { continue }
            $null = $jobKeys.Add($jobKey)
            $jobs.Add([pscustomobject]@{
                ScopeItem   = $scopeItem
                Definition  = Get-KatanaScopeDefinition -ScopeItem $scopeItem -SeedUrl $seedUrl -RespectSchemeOnly:$RespectSchemeOnly
                SeedStatus  = [int]$liveTarget.StatusCode
            }) | Out-Null
        }
    }

    Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8
    $results = [System.Collections.Generic.List[object]]::new()
    $seenUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $jobNumber = 0

    if ($jobs.Count -eq 0) {
        Write-ReconLog -Level WARN -Message ('Katana skipped all seeds after usefulness filtering. skipped={0}' -f $skippedSeeds)
    }

    foreach ($job in $jobs) {
        $jobNumber++
        Write-StageProgress -Step 5 -Title 'Crawl' -Percent ([Math]::Floor(($jobNumber / $jobs.Count) * 100)) -Status ("{0}/{1} {2}" -f $jobNumber, $jobs.Count, $job.Definition.SeedUrl)
        $scopeItem = $job.ScopeItem
        $definition = $job.Definition
        $inscopeFile = Join-Path $TempDirectory ("katana-inscope-{0}.regex" -f $scopeItem.Id)
        $outscopeFile = Join-Path $TempDirectory ("katana-outscope-{0}.regex" -f $scopeItem.Id)
        $stdoutFile = Join-Path $TempDirectory ("katana-{0}-{1}.jsonl" -f $scopeItem.Id, [Guid]::NewGuid().ToString('N'))
        $stderrFile = Join-Path $TempDirectory ("katana-{0}-{1}.err" -f $scopeItem.Id, [Guid]::NewGuid().ToString('N'))

        $outscopeRegexes = [System.Collections.Generic.List[string]]::new()
        foreach ($token in $scopeItem.Exclusions) { $outscopeRegexes.Add([regex]::Escape($token)) }
        Set-Content -LiteralPath $inscopeFile -Value ($definition.InScopeRegexes -join [Environment]::NewLine) -Encoding utf8
        Set-Content -LiteralPath $outscopeFile -Value ($outscopeRegexes -join [Environment]::NewLine) -Encoding utf8

        $arguments = @('-u', $definition.SeedUrl, '-silent', '-j', '-d', [string]$Depth)
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-cs') { $arguments += @('-cs', ($definition.InScopeRegexes -join '|')) }
        if ((Test-ToolFlagSupport -HelpText $helpText -Flag '-cos') -and $outscopeRegexes.Count -gt 0) { $arguments += @('-cos', '(?i)(' + (($scopeItem.Exclusions | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')') }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-fs') { $arguments += @('-fs', $definition.FieldScope) }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-jc') { $arguments += '-jc' }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-kf') { $arguments += @('-kf', 'all') }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-iqp') { $arguments += '-iqp' }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-c') { $arguments += @('-c', [string]$Threads) }
        if ($UniqueUserAgent) {
            if (Test-ToolFlagSupport -HelpText $helpText -Flag '-H') { $arguments += @('-H', "User-Agent: $UniqueUserAgent") }
            elseif (Test-ToolFlagSupport -HelpText $helpText -Flag '-header') { $arguments += @('-header', "User-Agent: $UniqueUserAgent") }
        }

        $rawCount = 0
        $keptCount = 0
        $duplicateCount = 0
        $excludedCount = 0
        $outOfScopeCount = 0
        $noiseCount = 0
        $parseErrors = 0
        $started = [DateTimeOffset]::UtcNow

        try {
            $result = Invoke-ExternalCommand -FilePath $KatanaPath -Arguments $arguments -TimeoutSeconds ([Math]::Max($TimeoutSeconds * 10, 90)) -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
            if ($result.ExitCode -ne 0) {
                Add-ErrorRecord -Phase 'Crawl' -Target $definition.SeedUrl -Message 'katana returned a non-zero exit code.' -Details $result.StdErr -Tool 'katana' -ExitCode $result.ExitCode -ErrorCode 'ToolExitCode'
            }

            $rawLines = @(
                if (Test-Path -LiteralPath $stdoutFile) {
                    Get-Content -LiteralPath $stdoutFile -Encoding utf8
                }
            )
            $rawCount = $rawLines.Count

            if ($rawLines.Count -gt 0) {
                Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
                Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
            }

            foreach ($line in $rawLines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $raw = $line | ConvertFrom-Json -Depth 100
                } catch {
                    $parseErrors++
                    Add-ErrorRecord -Phase 'Crawl' -Target $definition.SeedUrl -Message 'Failed to parse katana JSON line.' -Details $line -Tool 'katana' -ErrorCode 'ParseError'
                    continue
                }

                $url = [string](Get-ObjectValue -InputObject $raw -Names @('url', 'endpoint', 'request.endpoint'))
                if ([string]::IsNullOrWhiteSpace($url)) { continue }
                $analysis = Get-ReviewUrlAnalysis -Url $url -ContentType ([string](Get-ObjectValue -InputObject $raw -Names @('content_type', 'content-type', 'response.headers.content-type') -Default '')) -StatusCode ([int](Get-ObjectValue -InputObject $raw -Names @('status_code', 'status-code', 'response.status_code') -Default 0))
                if ($analysis.IsNoise) { $noiseCount++; continue }

                $uri = $null
                if (-not [Uri]::TryCreate($analysis.ReviewUrl, [UriKind]::Absolute, [ref]$uri)) { continue }
                $resolvedHost = $uri.DnsSafeHost.ToLowerInvariant()
                $path = if ($uri.AbsolutePath) { $uri.AbsolutePath } else { '/' }
                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $analysis.ReviewUrl -RespectSchemeOnly:$RespectSchemeOnly)) { $outOfScopeCount++; continue }
                $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $resolvedHost -Url $analysis.ReviewUrl -Path $path
                if ($exclusion.IsExcluded) { $excludedCount++; Add-ExclusionRecord -Phase 'Crawl' -ScopeItem $scopeItem -Target $analysis.ReviewUrl -ExclusionResult $exclusion; continue }
                $key = $analysis.ReviewKey
                if ($seenUrls.Contains($key)) { $duplicateCount++; continue }
                $null = $seenUrls.Add($key)
                $keptCount++
                $results.Add([pscustomobject]@{ Url = $analysis.ReviewUrl; Host = $resolvedHost; Scheme = $uri.Scheme.ToLowerInvariant(); Path = $path; Query = $uri.Query; ScopeId = $scopeItem.Id; ScopeType = $scopeItem.Type; ScopeValue = $scopeItem.NormalizedValue; SeedUrl = $definition.SeedUrl; Source = 'katana'; StatusCode = [int](Get-ObjectValue -InputObject $raw -Names @('status_code', 'status-code', 'response.status_code') -Default 0); ContentType = [string](Get-ObjectValue -InputObject $raw -Names @('content_type', 'content-type', 'response.headers.content-type') -Default '') }) | Out-Null
            }
        } catch {
            Add-ErrorRecord -Phase 'Crawl' -Target $definition.SeedUrl -Message $_.Exception.Message -Tool 'katana' -ErrorCode $(if ($_.Exception.Message -like 'Command timed out*') { 'ToolTimeout' } else { 'RuntimeError' })
        } finally {
            $duration = [Math]::Round(([DateTimeOffset]::UtcNow - $started).TotalSeconds, 1)
            Write-ScopeForgeDiagnosticLine -Path $script:ScopeForgeContext.Layout.KatanaSeedStatsLog -Line ("SEED|seed={0}|status={1}|raw={2}|kept={3}|noise={4}|dupes={5}|excluded={6}|out_of_scope={7}|parse_errors={8}|seconds={9}" -f $definition.SeedUrl, $job.SeedStatus, $rawCount, $keptCount, $noiseCount, $duplicateCount, $excludedCount, $outOfScopeCount, $parseErrors, $duration)
            Remove-Item -LiteralPath $stdoutFile, $stderrFile, $inscopeFile, $outscopeFile -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($liveTarget in $LiveTargets) {
        $seedEligibility = Test-KatanaSeedEligibility -LiveTarget $liveTarget
        if (-not $seedEligibility.Eligible) { continue }
        $analysis = Get-ReviewUrlAnalysis -Url $liveTarget.Url -StatusCode ([int]$liveTarget.StatusCode)
        if ($analysis.IsNoise) { continue }
        $key = $analysis.ReviewKey
        if ($seenUrls.Contains($key)) { continue }
        $null = $seenUrls.Add($key)
        $results.Add([pscustomobject]@{ Url = $analysis.ReviewUrl; Host = $liveTarget.Host; Scheme = $liveTarget.Scheme; Path = $liveTarget.Path; Query = ''; ScopeId = ($liveTarget.MatchedScopeIds -join ';'); ScopeType = ($liveTarget.MatchedTypes -join ';'); ScopeValue = 'live-target'; SeedUrl = $analysis.ReviewUrl; Source = 'seed'; StatusCode = $liveTarget.StatusCode; ContentType = [string](Get-ObjectValue -InputObject $liveTarget -Names @('ContentType') -Default '') }) | Out-Null
    }

    return @($results)
}

function Merge-ReconResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$HostsAll,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$DiscoveredUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Exclusions,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Errors,
        [Parameter(Mandatory)][string]$ProgramName,
        [string]$UniqueUserAgent
    )

    $statusCounts = @(
        $LiveTargets |
        Group-Object -Property StatusCode |
        Sort-Object -Property Name |
        ForEach-Object {
            [pscustomobject]@{
                StatusCode = $_.Name
                Count      = $_.Count
            }
        }
    )

    $technologyCounts = @(
        $LiveTargets |
        ForEach-Object { $_.Technologies } |
        Where-Object { $_ } |
        Group-Object |
        Sort-Object Count -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            [pscustomobject]@{
                Technology = $_.Name
                Count      = $_.Count
            }
        }
    )

    $subdomainCounts = @(
        $HostsAll |
        Group-Object -Property Host |
        Sort-Object Count -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            [pscustomobject]@{
                Host  = $_.Name
                Count = $_.Count
            }
        }
    )

    $interestingCategoryCounts = @(
        $InterestingUrls |
        ForEach-Object { $_.Categories } |
        Where-Object { $_ } |
        Group-Object |
        Sort-Object Count -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            [pscustomobject]@{
                Category = $_.Name
                Count    = $_.Count
            }
        }
    )

    $interestingFamilyCounts = @(
        $InterestingUrls |
        Group-Object -Property PrimaryFamily |
        Where-Object { $_.Name } |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name |
        Select-Object -First 10 |
        ForEach-Object {
            [pscustomobject]@{
                Family   = $_.Name
                Count    = $_.Count
                MaxScore = ($_.Group | Measure-Object -Property Score -Maximum).Maximum
                TopUrl   = ($_.Group | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, Url | Select-Object -First 1 -ExpandProperty Url)
            }
        }
    )

    $interestingPriorityCounts = @(
        $InterestingUrls |
        Group-Object -Property Priority |
        Where-Object { $_.Name } |
        Sort-Object -Property @{ Expression = { switch ($_.Name) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } default { 3 } } } }, Name |
        ForEach-Object {
            [pscustomobject]@{
                Priority = $_.Name
                Count    = $_.Count
            }
        }
    )

    $errorPhaseCounts = @(
        $Errors |
        Group-Object -Property Phase |
        Where-Object { $_.Name } |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name |
        ForEach-Object {
            [pscustomobject]@{
                Phase = $_.Name
                Count = $_.Count
            }
        }
    )

    $errorToolCounts = @(
        $Errors |
        Where-Object { $_.Tool } |
        Group-Object -Property Tool |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name |
        ForEach-Object {
            [pscustomobject]@{
                Tool  = $_.Name
                Count = $_.Count
            }
        }
    )

    [pscustomobject]@{
        ProgramName                     = $ProgramName
        GeneratedAtUtc                  = [DateTime]::UtcNow.ToString('o')
        PowerShellVersion               = $PSVersionTable.PSVersion.ToString()
        ScopeItemCount                  = $ScopeItems.Count
        ExcludedItemCount               = $Exclusions.Count
        DiscoveredHostCount             = @($HostsAll | Select-Object -ExpandProperty Host -Unique).Count
        LiveHostCount                   = @($LiveTargets | Select-Object -ExpandProperty Host -Unique).Count
        LiveTargetCount                 = $LiveTargets.Count
        DiscoveredUrlCount              = $DiscoveredUrls.Count
        InterestingUrlCount             = $InterestingUrls.Count
        ErrorCount                      = $Errors.Count
        ProtectedInterestingCount       = @($InterestingUrls | Where-Object { $_.Categories -contains 'Protected' }).Count
        UniqueUserAgent                 = $UniqueUserAgent
        StatusCodeDistribution          = $statusCounts
        TopTechnologies                 = $technologyCounts
        TopSubdomains                   = $subdomainCounts
        TopInterestingCategories        = $interestingCategoryCounts
        TopInterestingFamilies          = $interestingFamilyCounts
        InterestingPriorityDistribution = $interestingPriorityCounts
        ErrorPhaseDistribution          = $errorPhaseCounts
        ErrorToolDistribution           = $errorToolCounts
        FilteredUrlCount                = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { @($script:ScopeForgeContext.Triage.FilteredFindings).Count } else { $DiscoveredUrls.Count })
        ReviewableUrlCount              = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { @($script:ScopeForgeContext.Triage.ReviewableFindings).Count } else { $InterestingUrls.Count })
        NoiseRemovedCount               = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { @($script:ScopeForgeContext.Triage.NoiseFindings).Count } else { 0 })
        ShortlistCount                  = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { @($script:ScopeForgeContext.Triage.Shortlist).Count } else { 0 })
        StateIgnoredCount               = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { [int]$script:ScopeForgeContext.Triage.StateSummary.IgnoredCount } else { 0 })
        StateFalsePositiveCount         = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { [int]$script:ScopeForgeContext.Triage.StateSummary.FalsePositiveCount } else { 0 })
        StateValidatedCount             = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { [int]$script:ScopeForgeContext.Triage.StateSummary.ValidatedCount } else { 0 })
        SeenBeforeCount                 = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { [int]$script:ScopeForgeContext.Triage.StateSummary.SeenBeforeCount } else { 0 })
        TriageStatePath                 = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.TriageState) { $script:ScopeForgeContext.TriageState.Path } else { '' })
        TopAuthReviewable               = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { @($script:ScopeForgeContext.Triage.ReviewableFindings | Where-Object { $_.Categories -contains 'Auth' } | Select-Object -First 5 -ExpandProperty Url) } else { @() })
        TopApiReviewable                = $(if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Triage) { @($script:ScopeForgeContext.Triage.ReviewableFindings | Where-Object { $_.Categories -contains 'API' } | Select-Object -First 5 -ExpandProperty Url) } else { @() })
        TopProtectedReviewable          = @($InterestingUrls | Where-Object { $_.Categories -contains 'Protected' } | Select-Object -First 5 -ExpandProperty Url)
    }
}

function ConvertTo-HtmlSafe {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { ($Value | ForEach-Object { [string]$_ }) -join ', ' } else { [string]$Value }
    return [System.Net.WebUtility]::HtmlEncode($text)
}

function Get-InterestingReconFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$DiscoveredUrls
    )

    $triageState = if ($script:ScopeForgeContext -and $script:ScopeForgeContext.TriageState) { $script:ScopeForgeContext.TriageState } else { Get-ScopeForgeTriageState -ProgramName 'default-program' }
    $triageData = Get-TriageReconData -LiveTargets $LiveTargets -DiscoveredUrls $DiscoveredUrls -TriageState $triageState
    if ($script:ScopeForgeContext) {
        $script:ScopeForgeContext.Triage = $triageData
    }
    return @($triageData.ReviewableFindings)
}

function Get-PassiveLeadFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$HostsAll
    )

    $patterns = @(
        @{ Category = 'Identity/SCIM'; Family = 'Identity'; Priority = 'High'; Reason = 'Identity provisioning or SCIM-style asset'; Pattern = '(?i)(^|[.-])(scim|sso|oauth|auth|identity|login)([.-]|$)' },
        @{ Category = 'Admin'; Family = 'Administrative'; Priority = 'High'; Reason = 'Administrative or management naming'; Pattern = '(?i)(^|[.-])(admin|manage|portal|dashboard|console|staff|backoffice)([.-]|$)' },
        @{ Category = 'API'; Family = 'API'; Priority = 'High'; Reason = 'API-facing asset'; Pattern = '(?i)(^|[.-])(api|graphql|graphiql|swagger|openapi)([.-]|$)' },
        @{ Category = 'Files'; Family = 'Files'; Priority = 'Medium'; Reason = 'File, media, document, upload or storage naming'; Pattern = '(?i)(^|[.-])(file|files|media|upload|document|docs|cdn|assets)([.-]|$)' },
        @{ Category = 'Health/Metrics'; Family = 'Operations'; Priority = 'Medium'; Reason = 'Operational, monitoring or metrics naming'; Pattern = '(?i)(^|[.-])(health|status|metrics|prometheus|monitor|ready|live)([.-]|$)' },
        @{ Category = 'Config'; Family = 'Operations'; Priority = 'Medium'; Reason = 'Configuration, debug, internal or tooling naming'; Pattern = '(?i)(^|[.-])(debug|config|internal|ops|tooling|infra)([.-]|$)' },
        @{ Category = 'Payment'; Family = 'Business'; Priority = 'High'; Reason = 'Billing or payment related asset'; Pattern = '(?i)(^|[.-])(payment|payments|billing|invoice|checkout)([.-]|$)' },
        @{ Category = 'Chat/Business'; Family = 'Business'; Priority = 'Medium'; Reason = 'Business-critical workflow or chat-style service'; Pattern = '(?i)(^|[.-])(chat|medical|therapy|clinical|care|doctor)([.-]|$)' }
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($hostRecord in $HostsAll) {
        $targetHost = [string]$hostRecord.Host
        if ([string]::IsNullOrWhiteSpace($targetHost)) { continue }

        foreach ($pattern in $patterns) {
            if ($targetHost -notmatch $pattern.Pattern) { continue }

            $key = '{0}|{1}' -f $pattern.Category, $targetHost
            if ($seen.Contains($key)) { continue }
            $null = $seen.Add($key)

            $results.Add([pscustomobject]@{
                Severity        = 'Info'
                Confidence      = 'Passive'
                Priority        = $pattern.Priority
                Category        = $pattern.Category
                Family          = $pattern.Family
                Host            = $targetHost
                Url             = ''
                Evidence        = $pattern.Reason
                RecommendedChecks = switch ($pattern.Category) {
                    'Identity/SCIM' { 'Check login, SCIM, SSO, provisioning, user lifecycle, authz boundaries.' }
                    'Admin' { 'Check admin exposure, authz, role boundaries, tenant isolation, IDOR.' }
                    'API' { 'Check docs, schema exposure, versioned routes, auth, introspection.' }
                    'Files' { 'Check upload, download, content-type validation, path traversal, ACL.' }
                    'Health/Metrics' { 'Check health, actuator, metrics, version leaks, internal info.' }
                    'Config' { 'Check debug routes, backups, config exposure, stack traces.' }
                    'Payment' { 'Check billing flows, coupons, state changes, replay, authz.' }
                    'Chat/Business' { 'Check high-value workflows, object references, tenant isolation.' }
                    default { 'Manual review recommended.' }
                }
                Source          = 'passive-hostname'
            }) | Out-Null
        }
    }

    return @(
        $results |
        Sort-Object -Property @{ Expression = { switch ($_.Priority) { 'High' { 0 } 'Medium' { 1 } default { 2 } } } }, Host, Category
    )
}

function Get-UnifiedFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$PassiveLeads
    )

    $confirmed = @(
        $InterestingUrls | ForEach-Object {
            [pscustomobject]@{
                Severity          = $_.Priority
                Confidence        = 'Observed'
                Priority          = $_.Priority
                Category          = if ($_.Categories -and $_.Categories.Count -gt 0) { ($_.Categories -join ', ') } else { 'General' }
                Family            = $_.PrimaryFamily
                Host              = $_.Host
                Url               = $_.Url
                Evidence          = ($_.Reasons -join ', ')
                RecommendedChecks = 'Review manually and validate exploitability.'
                Source            = $_.Source
            }
        }
    )

    return @($confirmed + $PassiveLeads)
}

function Get-InterestingFamilySummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls)

    $priorityOrder = @{ Critical = 0; High = 1; Medium = 2; Low = 3 }
    return @(
        $InterestingUrls |
        Group-Object -Property PrimaryFamily |
        Where-Object { $_.Name } |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name |
        ForEach-Object {
            $group = $_.Group
            $priorities = $group | Group-Object -Property Priority | Sort-Object -Property @{ Expression = { $priorityOrder[$_.Name] } }, Name | ForEach-Object {
                [pscustomobject]@{
                    Priority = $_.Name
                    Count    = $_.Count
                }
            }

            [pscustomobject]@{
                Family         = $_.Name
                Count          = $_.Count
                MaxScore       = ($group | Measure-Object -Property Score -Maximum).Maximum
                Priorities     = @($priorities)
                TopUrls        = @($group | Sort-Object -Property PriorityRank, @{ Expression = 'Score'; Descending = $true }, Url | Select-Object -First 5 -ExpandProperty Url)
                TopCategories  = @($group | ForEach-Object { $_.Categories } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { $_.Name })
            }
        }
    )
}

function Get-SuggestedReviewAreas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Errors
    )

    $suggestions = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Add-Suggestion {
        param([string]$Key, [string]$Area, [string]$Reason)
        if ($seen.Add($Key)) {
            $suggestions.Add([pscustomobject]@{ Area = $Area; Reason = $Reason }) | Out-Null
        }
    }

    if ($InterestingUrls | Where-Object { $_.Categories -contains 'Auth' -or $_.Categories -contains 'Protected' -or $_.PrimaryFamily -eq 'Access' }) {
        Add-Suggestion -Key 'access' -Area 'Auth and session flows' -Reason 'Login, callback, SSO, or protected routes were surfaced.'
    }
    if ($InterestingUrls | Where-Object { $_.Categories -contains 'Admin' -or $_.PrimaryFamily -eq 'Administrative' }) {
        Add-Suggestion -Key 'admin' -Area 'Admin and portal surfaces' -Reason 'Administrative dashboards or staff-facing routes were detected.'
    }
    if ($InterestingUrls | Where-Object { $_.Categories -contains 'Files' -or $_.PrimaryFamily -eq 'Files' }) {
        Add-Suggestion -Key 'files' -Area 'Upload and file workflows' -Reason 'Import, export, media, or document handling routes were ranked.'
    }
    if ($InterestingUrls | Where-Object { $_.Categories -contains 'API' -or $_.PrimaryFamily -eq 'API' }) {
        Add-Suggestion -Key 'api' -Area 'API schemas and versioned endpoints' -Reason 'Swagger, GraphQL, or API paths were surfaced.'
    }
    if ($InterestingUrls | Where-Object { $_.Categories -contains 'Config' -or $_.Categories -contains 'Debug' -or $_.Categories -contains 'Infra' -or $_.PrimaryFamily -eq 'Operations' }) {
        Add-Suggestion -Key 'ops' -Area 'Operational and debug exposure' -Reason 'Config, metrics, debug, or health-check style routes were ranked.'
    }
    if ($LiveTargets | Where-Object { $_.StatusCode -in 401, 403 }) {
        Add-Suggestion -Key 'protected' -Area 'Protected endpoints' -Reason '401/403 live endpoints are present for access-control triage.'
    }
    if ($Errors.Count -gt 0) {
        Add-Suggestion -Key 'errors' -Area 'Retry noisy tools' -Reason 'Non-fatal runtime errors were captured; review logs before broadening the run.'
    }

    if ($suggestions.Count -eq 0) {
        Add-Suggestion -Key 'general' -Area 'General manual review' -Reason 'Prioritize confirmed live routes and compare them with program policy before deeper testing.'
    }

    return @($suggestions)
}

function Export-TriageMarkdownReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Summary,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingFamilies,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Exclusions,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Errors,
        [Parameter(Mandatory)][pscustomobject]$Layout
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# ScopeForge Triage") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add(("Generated: {0}" -f $Summary.GeneratedAtUtc)) | Out-Null
    $lines.Add(("Program: {0}" -f $Summary.ProgramName)) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Summary') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add(("- Scope items: {0}" -f $Summary.ScopeItemCount)) | Out-Null
    $lines.Add(("- Excluded assets: {0}" -f $Summary.ExcludedItemCount)) | Out-Null
    $lines.Add(("- Hosts discovered: {0}" -f $Summary.DiscoveredHostCount)) | Out-Null
    $lines.Add(("- Live hosts: {0}" -f $Summary.LiveHostCount)) | Out-Null
    $lines.Add(("- Live targets: {0}" -f $Summary.LiveTargetCount)) | Out-Null
    $lines.Add(("- URLs discovered: {0}" -f $Summary.DiscoveredUrlCount)) | Out-Null
    $lines.Add(("- Interesting URLs: {0}" -f $Summary.InterestingUrlCount)) | Out-Null
    $lines.Add(("- Protected interesting URLs: {0}" -f $Summary.ProtectedInterestingCount)) | Out-Null
    $lines.Add('') | Out-Null

    if ($Summary.InterestingPriorityDistribution -and $Summary.InterestingPriorityDistribution.Count -gt 0) {
        $lines.Add('## Priority Distribution') | Out-Null
        $lines.Add('') | Out-Null
        foreach ($item in $Summary.InterestingPriorityDistribution) {
            $lines.Add(("- {0}: {1}" -f $item.Priority, $item.Count)) | Out-Null
        }
        $lines.Add('') | Out-Null
    }

    $lines.Add('## Interesting Families') | Out-Null
    $lines.Add('') | Out-Null
    if (@($InterestingFamilies).Count -eq 0) {
        $lines.Add('- No interesting family groups were generated for this run.') | Out-Null
    } else {
        foreach ($family in ($InterestingFamilies | Select-Object -First 8)) {
            $priorityText = if ($family.Priorities) {
                ($family.Priorities | ForEach-Object { "{0}:{1}" -f $_.Priority, $_.Count }) -join ', '
            } else {
                'n/a'
            }
            $lines.Add(("### {0} ({1})" -f $family.Family, $family.Count)) | Out-Null
            $lines.Add(("- Max score: {0}" -f $family.MaxScore)) | Out-Null
            $lines.Add(("- Priorities: {0}" -f $priorityText)) | Out-Null
            if ($family.TopCategories -and $family.TopCategories.Count -gt 0) {
                $lines.Add(("- Top categories: {0}" -f (($family.TopCategories | ForEach-Object { [string]$_ }) -join ', '))) | Out-Null
            }
            foreach ($topUrl in ($family.TopUrls | Select-Object -First 3)) {
                $lines.Add(("- Seed URLs: {0}" -f $topUrl)) | Out-Null
            }
            $lines.Add('') | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $lines.Add('## Top Interesting URLs') | Out-Null
    $lines.Add('') | Out-Null
    if (@($InterestingUrls).Count -eq 0) {
        $lines.Add('- No interesting URLs were ranked for this run.') | Out-Null
    } else {
        foreach ($item in ($InterestingUrls | Select-Object -First 20)) {
            $lines.Add(("### [{0}/{1}] {2}" -f $item.Priority, $item.Score, $item.Url)) | Out-Null
            $lines.Add(("- Host: {0}" -f $item.Host)) | Out-Null
            $lines.Add(("- Status: {0}" -f $item.StatusCode)) | Out-Null
            if ($item.ContentType) {
                $lines.Add(("- Content-Type: {0}" -f $item.ContentType)) | Out-Null
            }
            $lines.Add(("- Family: {0}" -f $item.PrimaryFamily)) | Out-Null
            $lines.Add(("- Categories: {0}" -f (($item.Categories | ForEach-Object { [string]$_ }) -join ', '))) | Out-Null
            $lines.Add(("- Reasons: {0}" -f (($item.Reasons | ForEach-Object { [string]$_ }) -join ', '))) | Out-Null
            if ($item.Technologies -and $item.Technologies.Count -gt 0) {
                $lines.Add(("- Technologies: {0}" -f (($item.Technologies | ForEach-Object { [string]$_ }) -join ', '))) | Out-Null
            }
            if ($item.Title) {
                $lines.Add(("- Title: {0}" -f $item.Title)) | Out-Null
            }
            $lines.Add('') | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $protected = @($LiveTargets | Where-Object { $_.StatusCode -in 401, 403 } | Sort-Object -Property StatusCode, Url | Select-Object -First 25)
    $lines.Add('## Protected Endpoints') | Out-Null
    $lines.Add('') | Out-Null
    if (@($protected).Count -eq 0) {
        $lines.Add('- No 401/403 live targets captured in current results.') | Out-Null
    } else {
        foreach ($item in $protected) {
            $lines.Add(("- [{0}] {1}" -f $item.StatusCode, $item.Url)) | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $lines.Add('## Exclusion Summary') | Out-Null
    $lines.Add('') | Out-Null
    if (@($Exclusions).Count -eq 0) {
        $lines.Add('- No exclusions were recorded for this run.') | Out-Null
    } else {
        foreach ($group in ($Exclusions | Group-Object -Property Token | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name | Select-Object -First 10)) {
            $sample = $group.Group | Select-Object -First 1
            $phases = @($group.Group | Group-Object -Property Phase | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "{0}:{1}" -f $_.Name, $_.Count })
            $phaseText = if ($phases.Count -gt 0) { $phases -join ', ' } else { 'n/a' }
            $lines.Add(("- token={0}: {1} hit(s), phases={2}, sample={3}" -f $group.Name, $group.Count, $phaseText, $sample.Target)) | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $lines.Add('## Error Summary') | Out-Null
    $lines.Add('') | Out-Null
    if (@($Errors).Count -eq 0) {
        $lines.Add('- No non-fatal runtime errors were captured for this run.') | Out-Null
    } else {
        foreach ($group in ($Errors | Group-Object -Property Phase | Sort-Object Count -Descending | Select-Object -First 8)) {
            $sample = $group.Group | Select-Object -First 1
            $toolText = if ($sample.Tool) { $sample.Tool } else { 'n/a' }
            $codeText = if ($sample.ErrorCode) { $sample.ErrorCode } else { 'n/a' }
            $lines.Add(("- {0}: {1} issue(s), tool={2}, code={3}" -f $group.Name, $group.Count, $toolText, $codeText)) | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $lines.Add('## Suggested Test Areas') | Out-Null
    $lines.Add('') | Out-Null
    foreach ($suggestion in (Get-SuggestedReviewAreas -InterestingUrls $InterestingUrls -LiveTargets $LiveTargets -Errors $Errors)) {
        $lines.Add(("- {0}: {1}" -f $suggestion.Area, $suggestion.Reason)) | Out-Null
    }
    $lines.Add('') | Out-Null

    Set-Content -LiteralPath $Layout.TriageMarkdown -Value ($lines -join [Environment]::NewLine) -Encoding utf8
}

function Export-ReconReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Summary,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$HostsAll,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$HostsLive,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$DiscoveredUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Exclusions,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Errors,
        [Parameter(Mandatory)][pscustomobject]$Layout,
        [switch]$ExportJson,
        [switch]$ExportCsv,
        [switch]$ExportHtml
    )

    if ($ExportJson) { Write-JsonFile -Path $Layout.SummaryJson -Data $Summary }
    if ($ExportCsv) {
        Export-FlatCsv -Path $Layout.SummaryCsv -Rows @(
            [pscustomobject]@{ Metric = 'ProgramName'; Value = $Summary.ProgramName },
            [pscustomobject]@{ Metric = 'GeneratedAtUtc'; Value = $Summary.GeneratedAtUtc },
            [pscustomobject]@{ Metric = 'ScopeItemCount'; Value = $Summary.ScopeItemCount },
            [pscustomobject]@{ Metric = 'ExcludedItemCount'; Value = $Summary.ExcludedItemCount },
            [pscustomobject]@{ Metric = 'DiscoveredHostCount'; Value = $Summary.DiscoveredHostCount },
            [pscustomobject]@{ Metric = 'LiveHostCount'; Value = $Summary.LiveHostCount },
            [pscustomobject]@{ Metric = 'LiveTargetCount'; Value = $Summary.LiveTargetCount },
            [pscustomobject]@{ Metric = 'DiscoveredUrlCount'; Value = $Summary.DiscoveredUrlCount },
            [pscustomobject]@{ Metric = 'InterestingUrlCount'; Value = $Summary.InterestingUrlCount },
            [pscustomobject]@{ Metric = 'ErrorCount'; Value = $Summary.ErrorCount }
        )
        Export-FlatCsv -Path $Layout.HostsAllCsv -Rows $HostsAll
        Export-FlatCsv -Path $Layout.LiveTargetsCsv -Rows $LiveTargets
        Export-FlatCsv -Path $Layout.UrlsDiscoveredCsv -Rows $DiscoveredUrls
        Export-FlatCsv -Path $Layout.InterestingUrlsCsv -Rows $InterestingUrls
    }

    $triageData = if ($script:ScopeForgeContext) { $script:ScopeForgeContext.Triage } else { $null }
    if ($triageData) {
        $triageFilteredFindings = ConvertTo-ArrayOrEmpty -Data @($triageData.FilteredFindings)
        $triageNoiseFindings = ConvertTo-ArrayOrEmpty -Data @($triageData.NoiseFindings)
        $triageReviewableFindings = ConvertTo-ArrayOrEmpty -Data @($triageData.ReviewableFindings)
        $triageShortlist = ConvertTo-ArrayOrEmpty -Data @($triageData.Shortlist)

        Write-JsonFile -Path $Layout.FilteredUrlsJson -Data $triageFilteredFindings
        Write-JsonFile -Path $Layout.NoiseUrlsJson -Data $triageNoiseFindings
        Write-JsonFile -Path $Layout.ReviewableUrlsJson -Data $triageReviewableFindings
        Write-JsonFile -Path $Layout.ShortlistJson -Data $triageShortlist
        if ($ExportCsv) {
            Export-FlatCsv -Path $Layout.FilteredUrlsCsv -Rows $triageFilteredFindings
            Export-FlatCsv -Path $Layout.NoiseUrlsCsv -Rows $triageNoiseFindings
            Export-FlatCsv -Path $Layout.ReviewableUrlsCsv -Rows $triageReviewableFindings
        }

        $shortlistLines = [System.Collections.Generic.List[string]]::new()
        $shortlistLines.Add('# Shortlist') | Out-Null
        $shortlistLines.Add('') | Out-Null
        $shortlistLines.Add(('- reviewable: {0}' -f @($triageReviewableFindings).Count)) | Out-Null
        $shortlistLines.Add(('- filtered: {0}' -f @($triageFilteredFindings).Count)) | Out-Null
        $shortlistLines.Add(('- noise removed: {0}' -f @($triageNoiseFindings).Count)) | Out-Null
        $shortlistLines.Add('') | Out-Null
        foreach ($item in ($triageShortlist | Select-Object -First 20)) {
            $shortlistLines.Add(('## [{0}/{1}] {2}' -f $item.Priority, $item.Score, $item.Url)) | Out-Null
            if ($item.ContentType) {
                $shortlistLines.Add(('- Content-Type: {0}' -f $item.ContentType)) | Out-Null
            }
            $shortlistLines.Add(('- Family: {0}' -f $item.PrimaryFamily)) | Out-Null
            $shortlistLines.Add(('- Categories: {0}' -f ($item.Categories -join ', '))) | Out-Null
            $shortlistLines.Add(('- Reasons: {0}' -f ($item.Reasons -join ', '))) | Out-Null
            $shortlistLines.Add(('- State: {0}' -f $item.StateStatus)) | Out-Null
            $shortlistLines.Add('') | Out-Null
        }
        Set-Content -LiteralPath $Layout.ShortlistMarkdown -Value $shortlistLines -Encoding utf8
    }

    $interestingFamilies = Get-InterestingFamilySummary -InterestingUrls $InterestingUrls
    if ($null -eq $interestingFamilies) { $interestingFamilies = @() }
    Write-JsonFile -Path $Layout.InterestingUrlsJson -Data $InterestingUrls
    Write-JsonFile -Path $Layout.InterestingFamiliesJson -Data $interestingFamilies
    Export-TriageMarkdownReport -Summary $Summary -InterestingUrls $InterestingUrls -InterestingFamilies $interestingFamilies -LiveTargets $LiveTargets -Exclusions $Exclusions -Errors $Errors -Layout $Layout

    if (-not $ExportHtml) { return }

    function Get-HtmlTableBodyOrEmpty {
        param(
            [string]$Rows,
            [int]$ColumnCount,
            [string]$Message
        )

        if ([string]::IsNullOrWhiteSpace($Rows)) {
            return ('<tr><td colspan="{0}" class="empty-state">{1}</td></tr>' -f $ColumnCount, (ConvertTo-HtmlSafe $Message))
        }
        return $Rows
    }

    function Get-HtmlUrlCell {
        param([Parameter(Mandatory)][string]$Url)

        return ("<div class=""url-cell""><a href=""{0}"" target=""_blank"" rel=""noreferrer"">{0}</a><button type=""button"" class=""copy-btn"" data-copy=""{0}"">Copy</button></div>" -f (ConvertTo-HtmlSafe $Url))
    }

    function Get-PriorityClass {
        param([string]$Priority)

        switch ($Priority) {
            'Critical' { return 'priority-critical' }
            'High' { return 'priority-high' }
            'Medium' { return 'priority-medium' }
            default { return 'priority-low' }
        }
    }

    function Get-StatusClass {
        param([object]$StatusCode)

        $numericStatus = 0
        [int]::TryParse([string]$StatusCode, [ref]$numericStatus) | Out-Null

        switch ($numericStatus) {
            { $_ -eq 403 } { return 'status-danger' }
            { $_ -eq 401 } { return 'status-warning' }
            { $_ -ge 500 } { return 'status-danger' }
            { $_ -ge 400 } { return 'status-warning' }
            { $_ -ge 300 } { return 'status-info' }
            { $_ -ge 200 } { return 'status-ok' }
            default { return 'status-muted' }
        }
    }

    function Get-StatusBadgeHtml {
        param([object]$StatusCode)

        $safeStatus = ConvertTo-HtmlSafe ([string]$StatusCode)
        $statusClass = Get-StatusClass -StatusCode $StatusCode
        return "<span class=""status-badge $statusClass"">$safeStatus</span>"
    }

    function Format-RunDuration {
        param([TimeSpan]$Duration)

        if ($Duration.TotalHours -ge 1) {
            return ('{0}h {1}m {2}s' -f [int][Math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds)
        }
        if ($Duration.TotalMinutes -ge 1) {
            return ('{0}m {1}s' -f [int][Math]::Floor($Duration.TotalMinutes), $Duration.Seconds)
        }
        return ('{0}s' -f [int][Math]::Max([Math]::Floor($Duration.TotalSeconds), 0))
    }

    function Convert-ToReportDateTimeOffset {
        param([AllowNull()][object]$Value)

        if ($null -eq $Value) {
            return $null
        }
        if ($Value -is [DateTimeOffset]) {
            return [DateTimeOffset]$Value
        }
        if ($Value -is [DateTime]) {
            return [DateTimeOffset]$Value
        }

        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        $parsed = [DateTimeOffset]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [System.Globalization.DateTimeStyles]::RoundtripKind
        if ([DateTimeOffset]::TryParseExact($text, 'o', [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $parsed
        }
        if ([DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $parsed
        }
        if ([DateTimeOffset]::TryParse($text, [ref]$parsed)) {
            return $parsed
        }

        return $null
    }

    function Get-OAuthTenantLabel {
        param([pscustomobject]$Finding)

        if ($null -eq $Finding) { return '' }
        if ([string]$Finding.Host -ne 'descope.khealth.com') { return '' }
        if ([string]$Finding.PathAndQuery -match '^/([^/]+)/oauth2/') {
            return $Matches[1]
        }
        return ''
    }

    function Get-SuggestedActionText {
        param([pscustomobject]$Finding)

        if ($null -eq $Finding) { return 'Manual review.' }
        if (@($Finding.Categories) -contains 'Auth') {
            return 'Tester auth, tokens, method handling et rate-limit.'
        }
        if (@($Finding.Categories) -contains 'Admin' -or [string]$Finding.PrimaryFamily -eq 'Administrative') {
            return 'Verifier authz, role split et isolation tenant.'
        }
        if (@($Finding.Categories) -contains 'Files') {
            return 'Verifier upload, download, ACL et references d''objets.'
        }
        if (@($Finding.Categories) -contains 'Protected' -or [string]$Finding.StatusCode -in @('401', '403')) {
            return 'Verifier authz, redirections et protections contournables.'
        }
        if (@($Finding.Categories) -contains 'API' -or [string]$Finding.PrimaryFamily -eq 'API') {
            return 'Verifier schema, authz, parametres et erreurs verbeuses.'
        }
        return 'Triage manuel prioritaire.'
    }

    function Get-ToolVersionText {
        param([pscustomobject]$ToolInfo)

        $version = if ($ToolInfo -and $ToolInfo.PSObject.Properties['Version']) { [string]$ToolInfo.Version } else { '' }
        if ([string]::IsNullOrWhiteSpace($version)) { return 'version unavailable' }
        if ($version -match 'v\d+(?:\.\d+)+') { return $Matches[0] }
        if ($version -match '\d+\.\d+\.\d+') { return $Matches[0] }
        if ($version -match 'RemoteException|flag provided but not defined') { return 'version unavailable' }
        return $version.Trim()
    }

    function Get-ReportExclusionRecords {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$ScopeItems,
            [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Exclusions,
            [Parameter(Mandatory)][pscustomobject]$Layout
        )

        if (@($Exclusions).Count -gt 0) {
            return @($Exclusions)
        }
        if (-not (Test-Path -LiteralPath $Layout.ExclusionsLog)) {
            return @()
        }

        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($line in Get-Content -LiteralPath $Layout.ExclusionsLog -Encoding utf8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -notmatch "^(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{2}:\d{2}) \[EXCLUDED\] \[(?<phase>[^\]]+)\] Excluded by token '(?<token>[^']+)' on (?<matchedOn>[^:]+): (?<target>.+)$") {
                continue
            }

            $target = [string]$Matches.target
            $token = [string]$Matches.token
            $matchedOn = [string]$Matches.matchedOn
            $targetUrl = if ($target -match '^(?i)https?://') { $target } else { "https://$target" }
            $targetUri = $null
            $targetHost = $target
            $targetPath = '/'
            if ([Uri]::TryCreate($targetUrl, [UriKind]::Absolute, [ref]$targetUri)) {
                $targetHost = $targetUri.DnsSafeHost.ToLowerInvariant()
                $targetPath = $targetUri.AbsolutePath
            }

            $matchedScope = $null
            foreach ($scopeItem in $ScopeItems) {
                if (-not (@($scopeItem.Exclusions) -contains $token)) { continue }
                $exclusionResult = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $targetHost -Url $targetUrl -Path $targetPath
                if ($exclusionResult.IsExcluded) {
                    $matchedScope = $scopeItem
                    break
                }
            }

            $records.Add([pscustomobject]@{
                Timestamp = [string]$Matches.timestamp
                Phase     = [string]$Matches.phase
                ScopeId   = $(if ($matchedScope) { [string]$matchedScope.Id } else { '' })
                ScopeType = $(if ($matchedScope) { [string]$matchedScope.Type } else { '' })
                ScopeValue = $(if ($matchedScope) { [string]$matchedScope.NormalizedValue } else { '' })
                Target    = $target
                Token     = $token
                MatchedOn = $matchedOn
                MatchedText = $target
            }) | Out-Null
        }

        return @($records)
    }

    $reportExclusions = @(Get-ReportExclusionRecords -ScopeItems $ScopeItems -Exclusions $Exclusions -Layout $Layout)
    $reportExcludedCount = if ($reportExclusions.Count -gt 0) { $reportExclusions.Count } else { [int]$Summary.ExcludedItemCount }
    $scopeRows = ($ScopeItems | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Type) $(ConvertTo-HtmlSafe $_.NormalizedValue) $(ConvertTo-HtmlSafe ($_.Exclusions -join ' '))""><td>$(ConvertTo-HtmlSafe $_.Id)</td><td>$(ConvertTo-HtmlSafe $_.Type)</td><td>$(ConvertTo-HtmlSafe $_.NormalizedValue)</td><td>$(ConvertTo-HtmlSafe ($_.Exclusions -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $excludedRows = ($reportExclusions | Select-Object -First 500 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.ScopeId) $(ConvertTo-HtmlSafe $_.Target) $(ConvertTo-HtmlSafe $_.Token)""><td>$(ConvertTo-HtmlSafe $_.Phase)</td><td>$(ConvertTo-HtmlSafe $_.ScopeId)</td><td>$(ConvertTo-HtmlSafe $_.Target)</td><td>$(ConvertTo-HtmlSafe $_.Token)</td><td>$(ConvertTo-HtmlSafe $_.MatchedOn)</td></tr>" }) -join [Environment]::NewLine
    $liveRows = ($LiveTargets | Select-Object -First 1000 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) $(ConvertTo-HtmlSafe ($_.Technologies -join ' '))""><td>$(ConvertTo-HtmlSafe $_.Host)</td><td>$(Get-HtmlUrlCell -Url $_.Url)</td><td>$(ConvertTo-HtmlSafe $_.StatusCode)</td><td>$(ConvertTo-HtmlSafe $_.Title)</td><td>$(ConvertTo-HtmlSafe ($_.Technologies -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $urlRows = ($DiscoveredUrls | Select-Object -First 2000 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) $(ConvertTo-HtmlSafe $_.ScopeId)""><td>$(ConvertTo-HtmlSafe $_.Host)</td><td>$(Get-HtmlUrlCell -Url $_.Url)</td><td>$(ConvertTo-HtmlSafe $_.ScopeId)</td><td>$(ConvertTo-HtmlSafe $_.StatusCode)</td><td>$(ConvertTo-HtmlSafe $_.Source)</td></tr>" }) -join [Environment]::NewLine
    $interestingRows = ($InterestingUrls | Select-Object -First 250 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) $(ConvertTo-HtmlSafe $_.PrimaryFamily) $(ConvertTo-HtmlSafe $_.Priority) $(ConvertTo-HtmlSafe ($_.Categories -join ' '))""><td><span class=""priority-badge priority-$(ConvertTo-HtmlSafe $_.Priority.ToLowerInvariant())"">$(ConvertTo-HtmlSafe $_.Priority)</span></td><td>$(ConvertTo-HtmlSafe $_.Score)</td><td>$(ConvertTo-HtmlSafe $_.PrimaryFamily)</td><td>$(Get-HtmlUrlCell -Url $_.Url)</td><td>$(ConvertTo-HtmlSafe ($_.Categories -join ', '))</td><td>$(ConvertTo-HtmlSafe ($_.Reasons -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $protectedRows = ($LiveTargets | Where-Object { $_.StatusCode -in 401, 403 } | Select-Object -First 250 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) protected""><td>$(ConvertTo-HtmlSafe $_.StatusCode)</td><td>$(Get-HtmlUrlCell -Url $_.Url)</td><td>$(ConvertTo-HtmlSafe $_.Title)</td><td>$(ConvertTo-HtmlSafe ($_.Technologies -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $errorRows = ($Errors | Select-Object -First 500 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Phase) $(ConvertTo-HtmlSafe $_.Tool) $(ConvertTo-HtmlSafe $_.Target) $(ConvertTo-HtmlSafe $_.Message)""><td>$(ConvertTo-HtmlSafe $_.Phase)</td><td>$(ConvertTo-HtmlSafe $_.Tool)</td><td>$(ConvertTo-HtmlSafe $_.ErrorCode)</td><td>$(ConvertTo-HtmlSafe $_.Message)</td><td>$(ConvertTo-HtmlSafe $_.Recommendation)</td></tr>" }) -join [Environment]::NewLine
    $statusBars = ($Summary.StatusCodeDistribution | ForEach-Object { "<div class=""mini-row""><span>HTTP $(ConvertTo-HtmlSafe $_.StatusCode)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $technologyBars = ($Summary.TopTechnologies | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Technology)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $subdomainBars = ($Summary.TopSubdomains | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Host)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $interestingBars = ($Summary.TopInterestingCategories | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Category)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $familyBars = ($Summary.TopInterestingFamilies | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Family)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $priorityBars = ($Summary.InterestingPriorityDistribution | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Priority)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $errorPhaseBars = ($Summary.ErrorPhaseDistribution | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Phase)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $exclusionBars = (
        $reportExclusions |
        Group-Object -Property Token |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name |
        Select-Object -First 6 |
        ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Name)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }
    ) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($exclusionBars)) {
        $exclusionBars = '<div class="mini-row"><span>No exclusions recorded</span><strong>0</strong></div>'
    }
    $suggestedAreaRows = ((Get-SuggestedReviewAreas -InterestingUrls $InterestingUrls -LiveTargets $LiveTargets -Errors $Errors) | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Area)</span><strong>$(ConvertTo-HtmlSafe $_.Reason)</strong></div>" }) -join [Environment]::NewLine
    $familyRows = ($interestingFamilies | Select-Object -First 100 | ForEach-Object {
        $priorityText = if ($_.Priorities) { ($_.Priorities | ForEach-Object { "{0}:{1}" -f $_.Priority, $_.Count }) -join ', ' } else { '' }
        $topUrlText = if ($_.TopUrls) {
            (
                $_.TopUrls |
                Select-Object -First 3 |
                ForEach-Object { ConvertTo-HtmlSafe $_ }
            ) -join '<br />'
        } else { '' }
        "<tr data-search=""$(ConvertTo-HtmlSafe $_.Family) $(ConvertTo-HtmlSafe ($_.TopCategories -join ' ')) $(ConvertTo-HtmlSafe ($_.TopUrls -join ' '))""><td>$(ConvertTo-HtmlSafe $_.Family)</td><td>$(ConvertTo-HtmlSafe $_.Count)</td><td>$(ConvertTo-HtmlSafe $_.MaxScore)</td><td>$(ConvertTo-HtmlSafe $priorityText)</td><td>$(ConvertTo-HtmlSafe ($_.TopCategories -join ', '))</td><td>$topUrlText</td></tr>"
    }) -join [Environment]::NewLine
    $excludedRows = Get-HtmlTableBodyOrEmpty -Rows $excludedRows -ColumnCount 5 -Message 'No exclusions were recorded for this run.'
    $liveRows = Get-HtmlTableBodyOrEmpty -Rows $liveRows -ColumnCount 5 -Message 'No live HTTP(S) targets were retained for this run.'
    $urlRows = Get-HtmlTableBodyOrEmpty -Rows $urlRows -ColumnCount 5 -Message 'No URLs were discovered for this run.'
    $interestingRows = Get-HtmlTableBodyOrEmpty -Rows $interestingRows -ColumnCount 6 -Message 'No interesting URLs were ranked for this run.'
    $protectedRows = Get-HtmlTableBodyOrEmpty -Rows $protectedRows -ColumnCount 4 -Message 'No 401/403 live targets were captured for this run.'
    $errorRows = Get-HtmlTableBodyOrEmpty -Rows $errorRows -ColumnCount 5 -Message 'No non-fatal errors were captured for this run.'
    $familyRows = Get-HtmlTableBodyOrEmpty -Rows $familyRows -ColumnCount 6 -Message 'No interesting families were generated for this run.'
    $protectedTargetCount = @($LiveTargets | Where-Object { $_.StatusCode -in 401, 403 }).Count
    $interestingFamilyCount = @($interestingFamilies).Count
    $manifest = $null
    if ($Layout.PSObject.Properties.Name -contains 'RunManifestJson' -and -not [string]::IsNullOrWhiteSpace([string]$Layout.RunManifestJson) -and (Test-Path -LiteralPath $Layout.RunManifestJson)) {
        try {
            $manifest = Get-Content -LiteralPath $Layout.RunManifestJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        } catch {
            $manifest = $null
        }
    }

    $runSettings = if ($manifest -and $manifest.RunSettings) { $manifest.RunSettings } else { $null }
    $toolSnapshot = if ($manifest -and $manifest.ToolSnapshot) { @($manifest.ToolSnapshot) } else { @() }
    $shortlistItems = if ($triageData -and $triageData.Shortlist) { @($triageData.Shortlist | Select-Object -First 15) } else { @() }
    $programLabel = if ($manifest -and $manifest.ProgramName) { [string]$manifest.ProgramName } else { [string]$Summary.ProgramName }
    $runIdLabel = if ($manifest -and $manifest.RunId) { [string]$manifest.RunId } else { 'n/a' }
    $presetLabel = if ($runSettings) { '{0} / {1}' -f [string]$runSettings.PresetName, [string]$runSettings.ProfileName } else { 'n/a' }
    $userAgentLabel = if ($runSettings -and $runSettings.UniqueUserAgent) { [string]$runSettings.UniqueUserAgent } elseif ($Summary.UniqueUserAgent) { [string]$Summary.UniqueUserAgent } else { 'n/a' }
    $runStartedDisplay = 'n/a'
    $runEndedDisplay = if ($Summary.GeneratedAtUtc) { [string]$Summary.GeneratedAtUtc } else { 'n/a' }
    $durationDisplay = 'n/a'
    if ($manifest) {
        $parsedStart = Convert-ToReportDateTimeOffset -Value $manifest.StartTimeUtc
        $parsedEnd = Convert-ToReportDateTimeOffset -Value $manifest.EndTimeUtc
        if ($null -ne $parsedStart) { $runStartedDisplay = $parsedStart.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss ''UTC''') }
        if ($null -ne $parsedEnd) { $runEndedDisplay = $parsedEnd.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss ''UTC''') }
        if (($null -ne $parsedStart) -and ($null -ne $parsedEnd)) { $durationDisplay = Format-RunDuration -Duration ($parsedEnd - $parsedStart) }
    }

    $statusDistributionMap = @{}
    foreach ($statusEntry in @($Summary.StatusCodeDistribution)) {
        $statusDistributionMap[[string]$statusEntry.StatusCode] = [int]$statusEntry.Count
    }
    foreach ($knownStatus in @('200', '401', '403')) {
        if (-not $statusDistributionMap.ContainsKey($knownStatus)) {
            $statusDistributionMap[$knownStatus] = 0
        }
    }
    $maxStatusBar = [Math]::Max(($statusDistributionMap.Values | Measure-Object -Maximum).Maximum, 1)
    $statusChartHtml = @(
        foreach ($statusCode in @('200', '401', '403')) {
            $count = [int]$statusDistributionMap[$statusCode]
            $width = [int][Math]::Round(($count / $maxStatusBar) * 100)
            if ($count -gt 0 -and $width -lt 8) { $width = 8 }
            $barClass = switch ($statusCode) {
                '200' { 'status-ok' }
                '401' { 'status-warning' }
                default { 'status-danger' }
            }
            "<div class=""status-chart-row""><span class=""mono"">$statusCode</span><div class=""status-chart-track""><div class=""status-chart-bar $barClass"" style=""width:${width}%""></div></div><strong class=""mono"">$count</strong></div>"
        }
    ) -join [Environment]::NewLine

    $priorityOverviewHtml = @(
        foreach ($priorityName in @('Critical', 'High', 'Medium')) {
            $priorityItems = @($InterestingUrls | Where-Object { $_.Priority -eq $priorityName })
            $priorityClass = Get-PriorityClass -Priority $priorityName
            $priorityEntries = @(
                foreach ($item in $priorityItems) {
                    "<article class=""priority-entry"" data-search-card=""true"" data-search=""$(ConvertTo-HtmlSafe ($priorityName + ' ' + $item.Score + ' ' + $item.Url + ' ' + $item.PrimaryFamily + ' ' + ($item.Categories -join ' ')))""><div class=""priority-entry-head""><span class=""priority-badge $priorityClass"">$priorityName</span><span class=""score-pill mono"">[$priorityName/$($item.Score)]</span><button type=""button"" class=""copy-btn"" data-copy=""$(ConvertTo-HtmlSafe $item.Url)"">Copy</button></div><a class=""priority-url mono"" href=""$(ConvertTo-HtmlSafe $item.Url)"" target=""_blank"" rel=""noreferrer"" title=""$(ConvertTo-HtmlSafe $item.Url)"">$(ConvertTo-HtmlSafe $item.Url)</a></article>"
                }
            ) -join [Environment]::NewLine
            if ([string]::IsNullOrWhiteSpace($priorityEntries)) {
                $priorityEntries = '<div class="empty-card">No URLs in this priority.</div>'
            }
            "<section class=""priority-column $priorityClass""><div class=""priority-column-head""><div><h3>$priorityName</h3><small class=""mono"">$($priorityItems.Count) item(s)</small></div><span class=""priority-badge $priorityClass"">$($priorityItems.Count)</span></div><div class=""priority-column-body"">$priorityEntries</div></section>"
        }
    ) -join [Environment]::NewLine

    $shortlistCardsHtml = @(
        foreach ($item in $shortlistItems) {
            $priorityClass = Get-PriorityClass -Priority ([string]$item.Priority)
            $tenantLabel = Get-OAuthTenantLabel -Finding $item
            $tenantChip = if ($tenantLabel) { "<span class=""chip tenant-chip mono"">$(ConvertTo-HtmlSafe $tenantLabel)</span>" } else { '' }
            $categoryChips = if (@($item.Categories).Count -gt 0) {
                (@($item.Categories) | ForEach-Object { "<span class=""chip"">$(ConvertTo-HtmlSafe ([string]$_))</span>" }) -join ' '
            } else {
                '<span class="chip muted-chip">General</span>'
            }
            "<article class=""shortlist-card"" data-search-card=""true"" data-search=""$(ConvertTo-HtmlSafe ($item.Priority + ' ' + $item.Score + ' ' + $item.Url + ' ' + $item.PrimaryFamily + ' ' + ($item.Categories -join ' ') + ' ' + ($item.Reasons -join ' ')))""><div class=""shortlist-topline""><span class=""priority-badge $priorityClass"">$(ConvertTo-HtmlSafe ([string]$item.Priority))</span><span class=""score-pill mono"">Score $($item.Score)</span><span class=""family-pill mono"">$(ConvertTo-HtmlSafe ([string]$item.PrimaryFamily))</span>$(Get-StatusBadgeHtml -StatusCode $item.StatusCode)$tenantChip</div>$(Get-HtmlUrlCell -Url ([string]$item.Url))<div class=""chip-row"">$categoryChips</div><div class=""reason-copy"">$(ConvertTo-HtmlSafe ((@($item.Reasons) | ForEach-Object { [string]$_ }) -join '; '))</div></article>"
        }
    ) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($shortlistCardsHtml)) {
        $shortlistCardsHtml = '<div class="empty-card">No shortlist entries were generated for this run.</div>'
    }

    $authRows = @(
        foreach ($authUrl in @($Summary.TopAuthReviewable | Select-Object -First 5)) {
            $authFinding = @($InterestingUrls | Where-Object { $_.Url -eq $authUrl } | Select-Object -First 1)
            $authItem = if ($authFinding.Count -gt 0) { $authFinding[0] } else { $null }
            $reasonText = if ($authItem -and @($authItem.Reasons).Count -gt 0) { (@($authItem.Reasons) | ForEach-Object { [string]$_ }) -join ', ' } else { 'Authentication surface.' }
            "<tr data-search=""$(ConvertTo-HtmlSafe (([string]$authUrl) + ' ' + $reasonText))""><td>$(Get-HtmlUrlCell -Url ([string]$authUrl))</td><td>$(Get-StatusBadgeHtml -StatusCode $(if ($authItem) { $authItem.StatusCode } else { 0 }))</td><td>$(ConvertTo-HtmlSafe $reasonText)</td><td>$(ConvertTo-HtmlSafe (Get-SuggestedActionText -Finding $authItem))</td></tr>"
        }
    ) -join [Environment]::NewLine
    $authRows = Get-HtmlTableBodyOrEmpty -Rows $authRows -ColumnCount 4 -Message 'No authentication endpoints were ranked for this run.'

    $toolRows = @(
        foreach ($tool in $toolSnapshot) {
            "<tr data-search=""$(ConvertTo-HtmlSafe (([string]$tool.Name) + ' ' + (Get-ToolVersionText -ToolInfo $tool) + ' ' + ([string]$tool.BinaryPath)))""><td class=""mono"">$(ConvertTo-HtmlSafe ([string]$tool.Name))</td><td class=""mono"">$(ConvertTo-HtmlSafe (Get-ToolVersionText -ToolInfo $tool))</td><td class=""mono"">$(ConvertTo-HtmlSafe ([string]$tool.Binary))</td><td class=""mono"">$(ConvertTo-HtmlSafe ([string]$tool.BinaryPath))</td></tr>"
        }
    ) -join [Environment]::NewLine
    $toolRows = Get-HtmlTableBodyOrEmpty -Rows $toolRows -ColumnCount 4 -Message 'No tool snapshot was persisted for this run.'

    $nextActionChecklistHtml = @(
        foreach ($suggestion in (Get-SuggestedReviewAreas -InterestingUrls $InterestingUrls -LiveTargets $LiveTargets -Errors $Errors | Select-Object -First 6)) {
            "<label class=""action-item""><input type=""checkbox"" /><span class=""action-copy""><span class=""action-title"">$(ConvertTo-HtmlSafe ([string]$suggestion.Area))</span><span class=""action-reason"">$(ConvertTo-HtmlSafe ([string]$suggestion.Reason))</span></span></label>"
        }
    ) -join [Environment]::NewLine

    $kpiCardsHtml = @(
        "<div class=""kpi-card""><div class=""kpi-icon tone-accent""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><path d=""M4 7h16M4 12h16M4 17h16""/><rect x=""3"" y=""4"" width=""18"" height=""16"" rx=""2""/></svg></div><div><div class=""kpi-label"">Scope Items</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.ScopeItemCount))</div></div></div>"
        "<div class=""kpi-card""><div class=""kpi-icon tone-warning""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><circle cx=""12"" cy=""12"" r=""9""/><path d=""M8 8l8 8""/></svg></div><div><div class=""kpi-label"">Excluded</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.ExcludedItemCount))</div></div></div>"
        "<div class=""kpi-card""><div class=""kpi-icon tone-info""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><path d=""M4 12h16""/><path d=""M12 4a15 15 0 0 1 0 16""/><path d=""M12 4a15 15 0 0 0 0 16""/><circle cx=""12"" cy=""12"" r=""9""/></svg></div><div><div class=""kpi-label"">Hosts Discovered</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.DiscoveredHostCount))</div></div></div>"
        "<div class=""kpi-card""><div class=""kpi-icon tone-accent""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><path d=""M5 12l4 4L19 6""/><circle cx=""12"" cy=""12"" r=""9""/></svg></div><div><div class=""kpi-label"">Live Hosts</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.LiveHostCount))</div></div></div>"
        "<div class=""kpi-card""><div class=""kpi-icon tone-info""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><circle cx=""12"" cy=""12"" r=""8""/><circle cx=""12"" cy=""12"" r=""3""/><path d=""M12 2v3M12 19v3M2 12h3M19 12h3""/></svg></div><div><div class=""kpi-label"">Live Targets</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.LiveTargetCount))</div></div></div>"
        "<div class=""kpi-card""><div class=""kpi-icon tone-info""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><path d=""M10 13a5 5 0 0 1 0-7l1-1a5 5 0 0 1 7 7l-1 1""/><path d=""M14 11a5 5 0 0 1 0 7l-1 1a5 5 0 0 1-7-7l1-1""/></svg></div><div><div class=""kpi-label"">URLs Discovered</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.DiscoveredUrlCount))</div></div></div>"
        "<div class=""kpi-card""><div class=""kpi-icon tone-danger""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><path d=""M12 3l2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3 6.4 20.2l1.1-6.2L3 9.6l6.2-.9z""/></svg></div><div><div class=""kpi-label"">Interesting URLs</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.InterestingUrlCount))</div></div></div>"
        "<div class=""kpi-card""><div class=""kpi-icon tone-danger""><svg viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.8""><path d=""M12 3l7 3v5c0 5-3 8-7 10-4-2-7-5-7-10V6l7-3z""/><path d=""M9.5 12.5l1.8 1.8 3.7-4""/></svg></div><div><div class=""kpi-label"">Protected</div><div class=""kpi-value"">$(ConvertTo-HtmlSafe ([string]$Summary.ProtectedInterestingCount))</div></div></div>"
    ) -join [Environment]::NewLine
    $spotlightSections = $(
        foreach ($familyStat in ($Summary.TopInterestingFamilies | Select-Object -First 4)) {
            $familyName = [string]$familyStat.Family
            $categoryRows = (
                $InterestingUrls |
                Where-Object { $_.PrimaryFamily -eq $familyName } |
                Select-Object -First 5 |
                ForEach-Object {
                    "<div class=""mini-row""><span><a href=""$(ConvertTo-HtmlSafe $_.Url)"" target=""_blank"" rel=""noreferrer"">$(ConvertTo-HtmlSafe $_.Priority) | $(ConvertTo-HtmlSafe $_.Url)</a></span><strong>$(ConvertTo-HtmlSafe $_.Score)</strong></div>"
                }
            ) -join [Environment]::NewLine

            if (-not $categoryRows) {
                $categoryRows = '<div class="mini-row"><span>No URLs in this category.</span><strong>0</strong></div>'
            }

            "<section class=""card spotlight-card""><h2>Spotlight: $(ConvertTo-HtmlSafe $familyName)</h2>$categoryRows</section>"
        }
    ) -join [Environment]::NewLine

    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>ScopeForge Report - $(ConvertTo-HtmlSafe $programLabel)</title><link rel="preconnect" href="https://fonts.googleapis.com" /><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin /><link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet" /><style>
:root{--bg:#080d12;--panel:#0f1923;--panel2:#13202c;--panel3:#182a37;--text:#e7f0f7;--muted:#7f95a8;--accent:#00e5a0;--danger:#ff4757;--warning:#ffa502;--info:#5bc0ff;--border:rgba(255,255,255,.08);--shadow:0 22px 56px rgba(0,0,0,.34)}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;font-family:"IBM Plex Sans",sans-serif;background:var(--bg);color:var(--text)}a{color:var(--info);text-decoration:none}.mono,.url-cell a,.score-pill,.family-pill,.type-badge,.section-count,.status-badge{font-family:"JetBrains Mono",monospace}.wrap{max-width:1600px;margin:0 auto;padding:120px 20px 48px}.hero-header{position:fixed;top:0;left:0;right:0;z-index:40;background:rgba(8,13,18,.94);border-bottom:1px solid var(--border);backdrop-filter:blur(12px)}.hero-inner{max-width:1600px;margin:0 auto;padding:16px 20px;display:grid;grid-template-columns:2fr 1fr;gap:16px;align-items:start}.hero-title{display:flex;gap:14px;align-items:flex-start}.hero-badge{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;background:rgba(0,229,160,.12);border:1px solid rgba(0,229,160,.25);color:var(--accent)}.hero-badge svg{width:22px;height:22px}.hero-eyebrow{color:var(--accent);font-size:11px;letter-spacing:.14em;text-transform:uppercase;margin-bottom:4px}.hero-title h1{margin:0;font-size:28px;line-height:1.1}.hero-meta-line{margin-top:8px;color:var(--muted);font-size:14px}.hero-cards{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.hero-card,.hero,.card,.report-section,.toolbar-card{background:var(--panel);border:1px solid var(--border);box-shadow:var(--shadow)}.hero-card{border-radius:14px;padding:11px 12px}.hero-card-label{color:var(--muted);font-size:10px;letter-spacing:.08em;text-transform:uppercase;margin-bottom:5px}.hero-card-value{font-size:13px;line-height:1.35;word-break:break-word}.toolbar-card{position:sticky;top:12px;z-index:20;padding:18px;border-radius:18px;margin-bottom:18px;backdrop-filter:blur(12px)}.toolbar-row{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap}.toolbar-row+.toolbar-row{margin-top:14px}.toolbar-copy{color:var(--muted);font-size:13px}.toolbar-actions,.quick-filters,.quick-nav{display:flex;gap:10px;flex-wrap:wrap}.tool-btn,.filter-chip,.nav-pill{border:1px solid var(--border);background:rgba(8,13,18,.82);color:var(--text);border-radius:999px;padding:9px 14px;font-size:12px;cursor:pointer;text-decoration:none}.tool-btn:hover,.filter-chip:hover,.nav-pill:hover,.copy-btn:hover{border-color:rgba(91,192,255,.45);background:#122434}.nav-pill{display:inline-flex;align-items:center;gap:8px}.section-count{display:inline-flex;align-items:center;justify-content:center;min-width:28px;padding:2px 8px;border-radius:999px;background:rgba(0,229,160,.14);color:var(--accent);font-size:11px}.search{width:100%;margin:0 0 16px;padding:14px 16px;border:1px solid var(--border);border-radius:14px;background:rgba(8,13,18,.88);color:var(--text)}.search-inline{margin:0;flex:1 1 380px;min-width:260px}.grid{display:grid;grid-template-columns:repeat(8,minmax(0,1fr));gap:12px;margin:20px 0}.kpi-card{display:flex;gap:12px;align-items:center;border-radius:16px;padding:14px;min-height:94px}.kpi-icon{width:40px;height:40px;display:grid;place-items:center;border-radius:12px;border:1px solid currentColor;background:rgba(255,255,255,.04)}.kpi-icon svg{width:20px;height:20px}.kpi-label{font-size:11px;color:var(--muted);letter-spacing:.08em;text-transform:uppercase;margin-bottom:6px}.kpi-value{font-size:28px;font-weight:700;line-height:1}.tone-accent{color:var(--accent)}.tone-info{color:var(--info)}.tone-warning{color:var(--warning)}.tone-danger{color:var(--danger)}.dashboard-shell{display:grid;grid-template-columns:1.7fr 1fr;gap:18px;margin-bottom:18px}.panel-title{margin:0;font-size:18px}.panel-subtitle{margin-top:5px;color:var(--muted);font-size:13px}.priority-columns{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-top:16px}.priority-column{border:1px solid var(--border);border-radius:14px;min-height:430px;display:flex;flex-direction:column}.priority-column.priority-critical{background:rgba(255,71,87,.09);border-color:rgba(255,71,87,.26)}.priority-column.priority-high{background:rgba(255,165,2,.08);border-color:rgba(255,165,2,.24)}.priority-column.priority-medium{background:rgba(255,209,102,.08);border-color:rgba(255,209,102,.2)}.priority-column-head{padding:14px;border-bottom:1px solid var(--border);display:flex;align-items:flex-start;justify-content:space-between;gap:10px}.priority-column-head h3{margin:0;font-size:18px}.priority-column-body{padding:10px;display:grid;gap:10px;max-height:560px;overflow:auto}.priority-entry{background:rgba(8,13,18,.44);border:1px solid var(--border);border-radius:12px;padding:10px}.priority-entry-head{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px}.priority-url{display:block;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.score-pill,.family-pill,.chip,.type-badge{display:inline-flex;align-items:center;padding:4px 9px;border-radius:999px;border:1px solid var(--border);background:rgba(255,255,255,.04);font-size:11px}.priority-badge{display:inline-flex;align-items:center;justify-content:center;border-radius:999px;padding:4px 10px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.06em}.priority-critical{background:rgba(255,71,87,.18);color:#ffd6db}.priority-high{background:rgba(255,165,2,.18);color:#ffe4b0}.priority-medium{background:rgba(255,209,102,.18);color:#fff2c7}.priority-low{background:rgba(91,192,255,.16);color:#d9efff}.insight-stack{display:grid;gap:18px}.status-chart-row{display:grid;grid-template-columns:48px 1fr 44px;gap:12px;align-items:center}.status-chart-row+.status-chart-row{margin-top:10px}.status-chart-track{height:12px;border-radius:999px;background:rgba(255,255,255,.06);overflow:hidden}.status-chart-bar{height:100%;border-radius:999px}.status-chart-bar.status-ok{background:var(--accent)}.status-chart-bar.status-warning{background:var(--warning)}.status-chart-bar.status-danger{background:var(--danger)}.shortlist-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px}.shortlist-card{background:var(--panel);border:1px solid var(--border);border-radius:14px;box-shadow:var(--shadow);padding:14px;display:grid;gap:12px}.shortlist-topline,.chip-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.tenant-chip{background:rgba(91,192,255,.12);color:#d9efff}.muted-chip{color:var(--muted)}.reason-copy,.next-actions-copy{color:var(--muted);font-size:13px;line-height:1.45}.two-col{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;margin-bottom:18px}.mini-row{display:flex;justify-content:space-between;gap:16px;padding:10px 0;border-bottom:1px solid var(--border)}.mini-row strong{color:var(--text);font-weight:600}.hero,.card{padding:18px;border-radius:18px}.next-actions-panel{background:rgba(0,229,160,.08);border-color:rgba(0,229,160,.24)}.actions-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:14px}.action-item{display:flex;gap:12px;align-items:flex-start;background:rgba(8,13,18,.42);border:1px solid rgba(0,229,160,.14);border-radius:14px;padding:12px}.action-item input{width:18px;height:18px;margin-top:2px;accent-color:var(--accent)}.action-copy{display:grid;gap:4px}.action-title{font-weight:600}.action-reason{color:var(--muted);font-size:13px;line-height:1.4}.run-info-grid{display:grid;grid-template-columns:minmax(320px,420px) 1fr;gap:18px}.info-list{display:grid;gap:12px}.info-row{border:1px solid var(--border);border-radius:14px;background:rgba(8,13,18,.42);padding:12px}.info-label{color:var(--muted);font-size:10px;letter-spacing:.08em;text-transform:uppercase;margin-bottom:4px}.info-value{font-size:13px;line-height:1.4;word-break:break-word}.spotlight-card h2{margin:0 0 6px;font-size:18px}.spotlight-card .mini-row span{max-width:calc(100% - 64px)}details.report-section{margin-bottom:18px;border-radius:18px;overflow:hidden;scroll-margin-top:110px}details.report-section>summary{cursor:pointer;list-style:none;padding:18px 20px;background:var(--panel2);display:flex;justify-content:space-between;gap:16px;align-items:center}details.report-section>summary::-webkit-details-marker{display:none}.section-body{padding:18px}.table-scroll{overflow:auto;border-radius:14px}.table-scroll table{min-width:720px}table{width:100%;border-collapse:collapse}th,td{padding:10px 12px;text-align:left;border-bottom:1px solid var(--border);vertical-align:top;font-size:14px}td.empty-state{text-align:center;font-style:italic;color:var(--muted)}th{font-size:11px;text-transform:uppercase;letter-spacing:.08em}th button{all:unset;cursor:pointer;color:inherit}.url-cell{display:flex;flex-wrap:wrap;gap:8px;align-items:center}.url-cell a{overflow-wrap:anywhere;word-break:break-word}.copy-btn{border:1px solid var(--border);background:rgba(8,13,18,.82);color:var(--text);border-radius:999px;padding:4px 10px;font-size:11px;cursor:pointer}.status-badge{display:inline-flex;align-items:center;justify-content:center;min-width:44px;padding:4px 8px;border-radius:999px;font-size:11px;font-weight:700}.status-ok{background:rgba(0,229,160,.14);color:#bafee6}.status-warning{background:rgba(255,165,2,.16);color:#ffe2b2}.status-danger{background:rgba(255,71,87,.16);color:#ffd4d8}.status-info{background:rgba(91,192,255,.16);color:#d9efff}.status-muted{background:rgba(255,255,255,.08);color:#d2d9df}@media(max-width:1380px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}.shortlist-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:1080px){.hero-inner,.dashboard-shell,.run-info-grid{grid-template-columns:1fr}.priority-columns,.actions-grid{grid-template-columns:1fr}}@media(max-width:720px){.wrap{padding:132px 12px 32px}.hero-inner{padding:14px 12px}.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.shortlist-grid{grid-template-columns:1fr}.toolbar-card{position:static}.table-scroll table{min-width:640px}.url-cell{flex-direction:column;align-items:flex-start}}</style></head>
<body><header class="hero-header"><div class="hero-inner"><div class="hero-title"><div class="hero-badge"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 12h16"/><path d="M12 4v16"/><circle cx="12" cy="12" r="9"/></svg></div><div><div class="hero-eyebrow">Security Recon Dashboard</div><h1>$(ConvertTo-HtmlSafe $programLabel)</h1><div class="hero-meta-line">Run <span class="mono">$(ConvertTo-HtmlSafe $runIdLabel)</span> · Timestamp <span class="mono">$(ConvertTo-HtmlSafe $runEndedDisplay)</span> · Duration <span class="mono">$(ConvertTo-HtmlSafe $durationDisplay)</span></div></div></div><div class="hero-cards"><div class="hero-card"><div class="hero-card-label">Preset</div><div class="hero-card-value mono">$(ConvertTo-HtmlSafe $presetLabel)</div></div><div class="hero-card"><div class="hero-card-label">User-Agent</div><div class="hero-card-value mono">$(ConvertTo-HtmlSafe $userAgentLabel)</div></div><div class="hero-card"><div class="hero-card-label">Run Started</div><div class="hero-card-value mono">$(ConvertTo-HtmlSafe $runStartedDisplay)</div></div><div class="hero-card"><div class="hero-card-label">Run Ended</div><div class="hero-card-value mono">$(ConvertTo-HtmlSafe $runEndedDisplay)</div></div></div></div></header><div class="wrap">
<div class="toolbar-card"><div class="toolbar-row"><div class="toolbar-copy">Professional offensive-security layout with triage-first navigation.</div><div class="toolbar-actions"><button type="button" class="tool-btn" data-expand-sections="true">Expand All</button><button type="button" class="tool-btn" data-collapse-sections="true">Collapse All</button><button type="button" class="tool-btn" data-clear-search="true">Clear Filter</button></div></div><div class="toolbar-row"><input id="globalSearch" class="search search-inline" type="search" placeholder="Filter URLs, families, scopes, status codes..." /><div class="quick-filters"><button type="button" class="filter-chip" data-filter-value="critical">Critical</button><button type="button" class="filter-chip" data-filter-value="protected">Protected</button><button type="button" class="filter-chip" data-filter-value="api">API</button><button type="button" class="filter-chip" data-filter-value="auth">Auth</button><button type="button" class="filter-chip" data-filter-value="admin">Admin</button><button type="button" class="filter-chip" data-filter-value="401">401</button><button type="button" class="filter-chip" data-filter-value="403">403</button></div></div><nav class="quick-nav"><a class="nav-pill" href="#section-shortlist" data-open-section="section-shortlist">Shortlist <span class="section-count">$(@($shortlistItems).Count)</span></a><a class="nav-pill" href="#section-auth" data-open-section="section-auth">Auth <span class="section-count">$(@($Summary.TopAuthReviewable).Count)</span></a><a class="nav-pill" href="#section-interesting" data-open-section="section-interesting">Interesting <span class="section-count">$(@($InterestingUrls).Count)</span></a><a class="nav-pill" href="#section-protected" data-open-section="section-protected">Protected <span class="section-count">$protectedTargetCount</span></a><a class="nav-pill" href="#section-live" data-open-section="section-live">Live Targets <span class="section-count">$(@($LiveTargets).Count)</span></a><a class="nav-pill" href="#section-discovered" data-open-section="section-discovered">Discovered URLs <span class="section-count">$(@($DiscoveredUrls).Count)</span></a><a class="nav-pill" href="#section-excluded" data-open-section="section-excluded">Excluded <span class="section-count">$reportExcludedCount</span></a></nav></div>
<div class="grid">$kpiCardsHtml</div>
<div class="dashboard-shell"><section class="card"><h2 class="panel-title">Priority Overview</h2><div class="panel-subtitle">Critical, high and medium findings grouped for immediate triage. URLs stay fully clickable and copyable.</div><div class="priority-columns">$priorityOverviewHtml</div></section><div class="insight-stack"><section class="card"><h2 class="panel-title">HTTP Status Distribution</h2><div class="panel-subtitle">Current retained live-target mix by HTTP status.</div><div style="margin-top:16px;">$statusChartHtml</div></section><section class="card"><h2 class="panel-title">Run Snapshot</h2><div class="mini-row"><span>Preset / Profile</span><strong class="mono">$(ConvertTo-HtmlSafe $presetLabel)</strong></div><div class="mini-row"><span>User-Agent</span><strong class="mono">$(ConvertTo-HtmlSafe $userAgentLabel)</strong></div><div class="mini-row"><span>Interesting Families</span><strong class="mono">$interestingFamilyCount</strong></div><div class="mini-row"><span>Protected Endpoints</span><strong class="mono">$protectedTargetCount</strong></div></section></div></div>
<details open id="section-shortlist" class="report-section"><summary><span>Shortlist</span><small>Top 15 URLs to investigate first, kept inline as cards for fast review.</small></summary><div class="section-body"><div class="shortlist-grid">$shortlistCardsHtml</div></div></details>
<details open id="section-auth" class="report-section"><summary><span>Auth Endpoints</span><small>Top authentication reviewables with status, reason and suggested action.</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">URL</button></th><th><button type="button">Status</button></th><th><button type="button">Reason</button></th><th><button type="button">Suggested Action</button></th></tr></thead><tbody>$authRows</tbody></table></div></div></details>
<section class="card next-actions-panel"><h2 class="panel-title">Next Actions</h2><div class="panel-subtitle">Checklist built from the current triage signals.</div><div class="actions-grid">$nextActionChecklistHtml</div></section>
<details open id="section-runinfo" class="report-section"><summary><span>Run Info / Tools Snapshot</span><small>Run metadata, persisted tool snapshot and exact runtime context when available.</small></summary><div class="section-body"><div class="run-info-grid"><div class="info-list"><div class="info-row"><div class="info-label">Run ID</div><div class="info-value mono">$(ConvertTo-HtmlSafe $runIdLabel)</div></div><div class="info-row"><div class="info-label">Preset / Profile</div><div class="info-value mono">$(ConvertTo-HtmlSafe $presetLabel)</div></div><div class="info-row"><div class="info-label">User-Agent</div><div class="info-value mono">$(ConvertTo-HtmlSafe $userAgentLabel)</div></div><div class="info-row"><div class="info-label">Output</div><div class="info-value mono">$(ConvertTo-HtmlSafe ([string]$Layout.Root))</div></div></div><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Tool</button></th><th><button type="button">Version</button></th><th><button type="button">Binary</button></th><th><button type="button">Path</button></th></tr></thead><tbody>$toolRows</tbody></table></div></div></div></details>
<details open id="section-scope" class="report-section"><summary><span>In Scope</span><small>Normalized scope after validation and wildcard parsing. $(@($ScopeItems).Count) item(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">ID</button></th><th><button type="button">Type</button></th><th><button type="button">Value</button></th><th><button type="button">Exclusions</button></th></tr></thead><tbody>$scopeRows</tbody></table></div></div></details>
<details open id="section-excluded" class="report-section"><summary><span>Excluded</span><small>Assets removed because they matched exclusion strings before probe or after crawl filtering. $reportExcludedCount item(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Phase</button></th><th><button type="button">Scope</button></th><th><button type="button">Target</button></th><th><button type="button">Token</button></th><th><button type="button">Matched On</button></th></tr></thead><tbody>$excludedRows</tbody></table></div></div></details>
<details open id="section-live" class="report-section"><summary><span>Live Targets</span><small>Reachable HTTP(S) targets retained after in-scope validation. $(@($LiveTargets).Count) item(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Host</button></th><th><button type="button">URL</button></th><th><button type="button">Status</button></th><th><button type="button">Title</button></th><th><button type="button">Technologies</button></th></tr></thead><tbody>$liveRows</tbody></table></div></div></details>
<details open id="section-families" class="report-section"><summary><span>Interesting Families</span><small>Primary families used to group triage targets for manual review. $interestingFamilyCount group(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Family</button></th><th><button type="button">Count</button></th><th><button type="button">Max Score</button></th><th><button type="button">Priorities</button></th><th><button type="button">Top Categories</button></th><th><button type="button">Sample URLs</button></th></tr></thead><tbody>$familyRows</tbody></table></div></div></details>
<details open id="section-protected" class="report-section"><summary><span>Protected Endpoints</span><small>Live endpoints returning 401 or 403. $protectedTargetCount item(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Status</button></th><th><button type="button">URL</button></th><th><button type="button">Title</button></th><th><button type="button">Technologies</button></th></tr></thead><tbody>$protectedRows</tbody></table></div></div></details>
<details open id="section-interesting" class="report-section"><summary><span>Interesting Pages</span><small>Heuristically ranked URLs grouped by family and priority. $(@($InterestingUrls).Count) item(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Priority</button></th><th><button type="button">Score</button></th><th><button type="button">Family</button></th><th><button type="button">URL</button></th><th><button type="button">Categories</button></th><th><button type="button">Reasons</button></th></tr></thead><tbody>$interestingRows</tbody></table></div></div></details>
<details open id="section-discovered" class="report-section"><summary><span>Discovered URLs</span><small>Unique endpoints collected from katana and seeds. $(@($DiscoveredUrls).Count) item(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Host</button></th><th><button type="button">URL</button></th><th><button type="button">Scope</button></th><th><button type="button">Status</button></th><th><button type="button">Source</button></th></tr></thead><tbody>$urlRows</tbody></table></div></div></details>
<details open id="section-errors" class="report-section"><summary><span>Errors</span><small>Non-fatal errors captured during execution. $(@($Errors).Count) item(s).</small></summary><div class="section-body"><div class="table-scroll"><table data-filter-table="true" data-sort-table="true"><thead><tr><th><button type="button">Phase</button></th><th><button type="button">Tool</button></th><th><button type="button">Code</button></th><th><button type="button">Message</button></th><th><button type="button">Recommendation</button></th></tr></thead><tbody>$errorRows</tbody></table></div></div></details></div>
<script>const input=document.getElementById('globalSearch');const tables=Array.from(document.querySelectorAll('[data-filter-table=\"true\"]'));const sections=Array.from(document.querySelectorAll('details.report-section'));const cards=Array.from(document.querySelectorAll('[data-search-card=\"true\"]'));function applyFilter(){const query=input.value.trim().toLowerCase();tables.forEach(table=>{let visibleRows=0;table.querySelectorAll('tbody tr').forEach(row=>{const haystack=(row.dataset.search||row.textContent||'').toLowerCase();const visible=!query||haystack.includes(query);row.style.display=visible?'':'none';if(visible){visibleRows++;}});const section=table.closest('details.report-section');if(section&&query&&visibleRows>0){section.open=true;}});cards.forEach(card=>{const haystack=(card.dataset.search||card.textContent||'').toLowerCase();card.style.display=!query||haystack.includes(query)?'':'none';});}function wireSort(table){const headers=Array.from(table.querySelectorAll('thead th button'));headers.forEach((button,index)=>{button.addEventListener('click',()=>{const tbody=table.querySelector('tbody');const rows=Array.from(tbody.querySelectorAll('tr'));const ascending=button.dataset.sortDir!=='asc';headers.forEach(header=>{header.dataset.sortDir='';});button.dataset.sortDir=ascending?'asc':'desc';rows.sort((a,b)=>{const left=(a.children[index]?.innerText||'').trim();const right=(b.children[index]?.innerText||'').trim();const leftNumber=Number(left);const rightNumber=Number(right);const comparison=!Number.isNaN(leftNumber)&&!Number.isNaN(rightNumber)?leftNumber-rightNumber:left.localeCompare(right,undefined,{numeric:true,sensitivity:'base'});return ascending?comparison:-comparison;});rows.forEach(row=>tbody.appendChild(row));});});}document.querySelectorAll('[data-sort-table=\"true\"]').forEach(wireSort);document.querySelectorAll('.copy-btn').forEach(button=>{button.addEventListener('click',async()=>{const value=button.dataset.copy||'';const previous=button.textContent;try{if(navigator.clipboard&&value){await navigator.clipboard.writeText(value);button.textContent='Copied';setTimeout(()=>button.textContent=previous,1200);}}catch(_){button.textContent=previous;}});});document.querySelectorAll('[data-expand-sections=\"true\"]').forEach(button=>button.addEventListener('click',()=>sections.forEach(section=>section.open=true)));document.querySelectorAll('[data-collapse-sections=\"true\"]').forEach(button=>button.addEventListener('click',()=>sections.forEach(section=>section.open=false)));document.querySelectorAll('[data-clear-search=\"true\"]').forEach(button=>button.addEventListener('click',()=>{input.value='';applyFilter();input.focus();}));document.querySelectorAll('.filter-chip').forEach(button=>button.addEventListener('click',()=>{input.value=button.dataset.filterValue||'';applyFilter();input.focus();}));document.querySelectorAll('[data-open-section]').forEach(link=>link.addEventListener('click',()=>{const section=document.getElementById(link.dataset.openSection||'');if(section){section.open=true;}}));input.addEventListener('input',applyFilter);applyFilter();</script></body></html>
"@
    Set-Content -LiteralPath $Layout.ReportHtml -Value $html -Encoding utf8
}

function Invoke-BugBountyRecon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScopeFile,
        [ValidateRange(1, 20)][int]$Depth = 3,
        [ValidateNotNullOrEmpty()][string]$OutputDir = './output',
        [ValidateNotNullOrEmpty()][string]$ProgramName = 'default-program',
        [string]$UniqueUserAgent,
        [ValidateRange(1, 200)][int]$Threads = 10,
        [ValidateRange(5, 600)][int]$TimeoutSeconds = 30,
        [bool]$EnableGau = $true,
        [bool]$EnableWaybackUrls = $true,
        [bool]$EnableHakrawler = $true,
        [switch]$NoInstall,
        [switch]$Quiet,
        [switch]$IncludeApex,
        [switch]$RespectSchemeOnly,
        [switch]$ExportHtml,
        [switch]$ExportCsv,
        [switch]$ExportJson,
        [switch]$Resume
    )

    $exportFlagsSpecified = $PSBoundParameters.ContainsKey('ExportHtml') -or $PSBoundParameters.ContainsKey('ExportCsv') -or $PSBoundParameters.ContainsKey('ExportJson')
    $exportHtmlEnabled = if ($exportFlagsSpecified) { [bool]$ExportHtml } else { $true }
    $exportCsvEnabled = if ($exportFlagsSpecified) { [bool]$ExportCsv } else { $true }
    $exportJsonEnabled = if ($exportFlagsSpecified) { [bool]$ExportJson } else { $true }

    $layout = Get-OutputLayout -OutputDir $OutputDir
    Initialize-OutputDirectories -Layout $layout
    $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName $ProgramName -Quiet ([bool]$Quiet) -ExportJsonEnabled:$exportJsonEnabled -ExportCsvEnabled:$exportCsvEnabled -ExportHtmlEnabled:$exportHtmlEnabled
    $script:ScopeForgeContext.TriageState = Get-ScopeForgeTriageState -ProgramName $ProgramName
    Initialize-ScopeForgeProgressState -Layout $layout
    Write-ScopeForgeConsolePathsHint

    if (-not $UniqueUserAgent) {
        $warning = 'No -UniqueUserAgent was provided. Some bug bounty programs require a unique tracking User-Agent.'
        $script:ScopeForgeContext.Warnings.Add($warning)
        Write-ReconLog -Level WARN -Message $warning
    }

    $useResume = [bool]$Resume
    try {
        Write-StageBanner -Step 1 -Title 'Validation du scope'
        Write-StageProgress -Step 1 -Title 'Validation du scope' -Percent 10 -Status 'Loading scope file'
        $scopeItems = Read-ScopeFile -Path $ScopeFile -IncludeApex:$IncludeApex
        $scopeSnapshot = $scopeItems | ConvertTo-Json -Depth 100
        if ($useResume -and (Test-Path -LiteralPath $layout.ScopeNormalized)) {
            $previousSnapshot = Get-Content -LiteralPath $layout.ScopeNormalized -Raw -Encoding utf8
            if ($previousSnapshot -ne $scopeSnapshot) {
                $useResume = $false
                Write-ReconLog -Level WARN -Message 'Resume disabled because the normalized scope differs from the previous run.'
            }
        }
        Write-JsonFile -Path $layout.ScopeNormalized -Data $scopeItems
        Write-StageProgress -Step 1 -Title 'Validation du scope' -Percent 100 -Status "$($scopeItems.Count) scope items validated"

        Write-StageBanner -Step 2 -Title 'Préparation outils'
        $enabledSources = @('subfinder', 'httpx', 'katana')
        if ($EnableGau) { $enabledSources += 'gau' }
        if ($EnableWaybackUrls) { $enabledSources += 'waybackurls' }
        if ($EnableHakrawler) { $enabledSources += 'hakrawler' }
        Write-StageProgress -Step 2 -Title 'Préparation outils' -Percent 10 -Status ("Checking {0}" -f ($enabledSources -join '/'))
        $tools = Ensure-ReconTools -Layout $layout -NoInstall:$NoInstall -TimeoutSeconds $TimeoutSeconds -EnableGau:$EnableGau -EnableWaybackUrls:$EnableWaybackUrls -EnableHakrawler:$EnableHakrawler
        Write-ReconLog -Level INFO -Message ("Tool status: subfinder={0}, httpx={1}, katana={2}, gau={3}, waybackurls={4}, hakrawler={5}" -f `
            $(if ($tools.Subfinder) { 'ok' } else { 'off' }), `
            $(if ($tools.Httpx) { 'ok' } else { 'off' }), `
            $(if ($tools.Katana) { 'ok' } else { 'off' }), `
            $(if ($tools.Gau) { 'ok' } else { 'off' }), `
            $(if ($tools.WaybackUrls) { 'ok' } else { 'off' }), `
            $(if ($tools.Hakrawler) { 'ok' } else { 'off' }))
        Write-StageProgress -Step 2 -Title 'Préparation outils' -Percent 100 -Status 'Toolchain ready'

        if ($useResume -and (Test-Path -LiteralPath $layout.HostsAllJson)) {
            Write-StageBanner -Step 3 -Title 'Découverte passive'
            Write-ReconLog -Level INFO -Message 'Resume: loading cached host inventory.'
            $hostsAll = @(Get-Content -LiteralPath $layout.HostsAllJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
        } else {
            Write-StageBanner -Step 3 -Title 'Découverte passive'
            $hostMap = @{}
            $wildcardCache = @{}
            $historicalUrlCache = @{}
            $waybackUrlCache = @{}
            $scopeCounter = 0

            foreach ($scopeItem in $scopeItems) {
                $scopeCounter++
                Write-StageProgress -Step 3 -Title 'Découverte passive' -Percent ([Math]::Floor(($scopeCounter / $scopeItems.Count) * 100)) -Status ("{0}/{1} {2}" -f $scopeCounter, $scopeItems.Count, $scopeItem.NormalizedValue)

                switch ($scopeItem.Type) {
                    'URL' {
                        $targetHost = $scopeItem.Host
                        $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $targetHost -Url $scopeItem.StartUrl -Path ([Uri]$scopeItem.StartUrl).AbsolutePath
                        if ($exclusion.IsExcluded) { Add-ExclusionRecord -Phase 'TargetGeneration' -ScopeItem $scopeItem -Target $scopeItem.StartUrl -ExclusionResult $exclusion; continue }
                        $record = Get-OrCreateHostInventoryRecord -HostMap $hostMap -TargetHost $targetHost
                        $record.Discovery.Add('seed-url') | Out-Null; $record.SourceScopeIds.Add($scopeItem.Id) | Out-Null; $record.SourceTypes.Add($scopeItem.Type) | Out-Null; $record.RootDomains.Add($scopeItem.RootDomain) | Out-Null
                        foreach ($candidateUrl in Get-ProbeCandidateUrls -ScopeItem $scopeItem -RespectSchemeOnly:$RespectSchemeOnly) { $record.CandidateUrls.Add($candidateUrl) | Out-Null }

                        if ($tools.Gau) {
                            if (-not $historicalUrlCache.ContainsKey($targetHost)) {
                                $historicalUrlCache[$targetHost] = @(Get-HistoricalUrls -Target $targetHost -GauPath $tools.Gau.Path -RawOutputPath $layout.GauRaw -TimeoutSeconds $TimeoutSeconds)
                            }

                            foreach ($historicalUrl in $historicalUrlCache[$targetHost]) {
                                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $historicalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                                $historicalUri = [Uri]$historicalUrl
                                $historicalExclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $historicalUri.DnsSafeHost.ToLowerInvariant() -Url $historicalUrl -Path $historicalUri.AbsolutePath
                                if ($historicalExclusion.IsExcluded) { Add-ExclusionRecord -Phase 'HistoricalDiscovery' -ScopeItem $scopeItem -Target $historicalUrl -ExclusionResult $historicalExclusion; continue }
                                $record.CandidateUrls.Add($historicalUrl) | Out-Null
                                $record.Discovery.Add('gau') | Out-Null
                            }
                        }

                        if ($tools.WaybackUrls) {
                            if (-not $waybackUrlCache.ContainsKey($targetHost)) {
                                $waybackUrlCache[$targetHost] = @(Get-WaybackUrls -Target $targetHost -WaybackUrlsPath $tools.WaybackUrls.Path -RawOutputPath $layout.WaybackRaw -TimeoutSeconds $TimeoutSeconds)
                            }

                            foreach ($historicalUrl in $waybackUrlCache[$targetHost]) {
                                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $historicalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                                $historicalUri = [Uri]$historicalUrl
                                $historicalExclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $historicalUri.DnsSafeHost.ToLowerInvariant() -Url $historicalUrl -Path $historicalUri.AbsolutePath
                                if ($historicalExclusion.IsExcluded) { Add-ExclusionRecord -Phase 'HistoricalDiscovery' -ScopeItem $scopeItem -Target $historicalUrl -ExclusionResult $historicalExclusion; continue }
                                $record.CandidateUrls.Add($historicalUrl) | Out-Null
                                $record.Discovery.Add('waybackurls') | Out-Null
                            }
                        }
                    }
                    'Domain' {
                        $targetHost = $scopeItem.Host
                        $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $targetHost -Url ("https://$targetHost") -Path '/'
                        if ($exclusion.IsExcluded) { Add-ExclusionRecord -Phase 'TargetGeneration' -ScopeItem $scopeItem -Target $targetHost -ExclusionResult $exclusion; continue }
                        $record = Get-OrCreateHostInventoryRecord -HostMap $hostMap -TargetHost $targetHost
                        $record.Discovery.Add('seed-domain') | Out-Null; $record.SourceScopeIds.Add($scopeItem.Id) | Out-Null; $record.SourceTypes.Add($scopeItem.Type) | Out-Null; $record.RootDomains.Add($scopeItem.RootDomain) | Out-Null
                        foreach ($candidateUrl in Get-ProbeCandidateUrls -ScopeItem $scopeItem -RespectSchemeOnly:$RespectSchemeOnly) { $record.CandidateUrls.Add($candidateUrl) | Out-Null }

                        if ($tools.Gau) {
                            if (-not $historicalUrlCache.ContainsKey($targetHost)) {
                                $historicalUrlCache[$targetHost] = @(Get-HistoricalUrls -Target $targetHost -GauPath $tools.Gau.Path -RawOutputPath $layout.GauRaw -TimeoutSeconds $TimeoutSeconds)
                            }

                            foreach ($historicalUrl in $historicalUrlCache[$targetHost]) {
                                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $historicalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                                $historicalUri = [Uri]$historicalUrl
                                $historicalExclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $historicalUri.DnsSafeHost.ToLowerInvariant() -Url $historicalUrl -Path $historicalUri.AbsolutePath
                                if ($historicalExclusion.IsExcluded) { Add-ExclusionRecord -Phase 'HistoricalDiscovery' -ScopeItem $scopeItem -Target $historicalUrl -ExclusionResult $historicalExclusion; continue }
                                $record.CandidateUrls.Add($historicalUrl) | Out-Null
                                $record.Discovery.Add('gau') | Out-Null
                            }
                        }

                        if ($tools.WaybackUrls) {
                            if (-not $waybackUrlCache.ContainsKey($targetHost)) {
                                $waybackUrlCache[$targetHost] = @(Get-WaybackUrls -Target $targetHost -WaybackUrlsPath $tools.WaybackUrls.Path -RawOutputPath $layout.WaybackRaw -TimeoutSeconds $TimeoutSeconds)
                            }

                            foreach ($historicalUrl in $waybackUrlCache[$targetHost]) {
                                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $historicalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                                $historicalUri = [Uri]$historicalUrl
                                $historicalExclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $historicalUri.DnsSafeHost.ToLowerInvariant() -Url $historicalUrl -Path $historicalUri.AbsolutePath
                                if ($historicalExclusion.IsExcluded) { Add-ExclusionRecord -Phase 'HistoricalDiscovery' -ScopeItem $scopeItem -Target $historicalUrl -ExclusionResult $historicalExclusion; continue }
                                $record.CandidateUrls.Add($historicalUrl) | Out-Null
                                $record.Discovery.Add('waybackurls') | Out-Null
                            }
                        }
                    }
                    'Wildcard' {
                        if (-not $wildcardCache.ContainsKey($scopeItem.RootDomain)) {
                            $wildcardCache[$scopeItem.RootDomain] = @(Get-PassiveSubdomains -RootDomain $scopeItem.RootDomain -SubfinderPath $tools.Subfinder.Path -RawOutputPath $layout.SubfinderRaw -TimeoutSeconds $TimeoutSeconds)
                        }
                        if ($tools.Gau -and -not $historicalUrlCache.ContainsKey($scopeItem.RootDomain)) {
                            $historicalUrlCache[$scopeItem.RootDomain] = @(Get-HistoricalUrls -Target $scopeItem.RootDomain -GauPath $tools.Gau.Path -RawOutputPath $layout.GauRaw -IncludeSubdomains $true -TimeoutSeconds $TimeoutSeconds)
                        }
                        if ($tools.WaybackUrls -and -not $waybackUrlCache.ContainsKey($scopeItem.RootDomain)) {
                            $waybackUrlCache[$scopeItem.RootDomain] = @(Get-WaybackUrls -Target $scopeItem.RootDomain -WaybackUrlsPath $tools.WaybackUrls.Path -RawOutputPath $layout.WaybackRaw -TimeoutSeconds $TimeoutSeconds)
                        }
                        $candidateHosts = [System.Collections.Generic.List[string]]::new()
                        foreach ($discoveredHost in $wildcardCache[$scopeItem.RootDomain]) { $candidateHosts.Add($discoveredHost) | Out-Null }
                        if ($scopeItem.IncludeApex) { $candidateHosts.Add($scopeItem.RootDomain) | Out-Null }

                        foreach ($historicalUrl in @($historicalUrlCache[$scopeItem.RootDomain])) {
                            $historicalUri = $null
                            if (-not [Uri]::TryCreate($historicalUrl, [UriKind]::Absolute, [ref]$historicalUri)) { continue }
                            $historicalHost = $historicalUri.DnsSafeHost.ToLowerInvariant()
                            if ([regex]::IsMatch($historicalHost, $scopeItem.HostRegexString, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                                $candidateHosts.Add($historicalHost) | Out-Null
                            }
                        }
                        foreach ($historicalUrl in @($waybackUrlCache[$scopeItem.RootDomain])) {
                            $historicalUri = $null
                            if (-not [Uri]::TryCreate($historicalUrl, [UriKind]::Absolute, [ref]$historicalUri)) { continue }
                            $historicalHost = $historicalUri.DnsSafeHost.ToLowerInvariant()
                            if ([regex]::IsMatch($historicalHost, $scopeItem.HostRegexString, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                                $candidateHosts.Add($historicalHost) | Out-Null
                            }
                        }

                        foreach ($candidateHost in ($candidateHosts | Select-Object -Unique)) {
                            if (-not [regex]::IsMatch($candidateHost, $scopeItem.HostRegexString, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { continue }
                            $probePreview = if ($scopeItem.Scheme) { "{0}://{1}" -f $scopeItem.Scheme, $candidateHost } else { "https://$candidateHost" }
                            $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $candidateHost -Url $probePreview -Path '/'
                            if ($exclusion.IsExcluded) { Add-ExclusionRecord -Phase 'TargetGeneration' -ScopeItem $scopeItem -Target $candidateHost -ExclusionResult $exclusion; continue }
                            $record = Get-OrCreateHostInventoryRecord -HostMap $hostMap -TargetHost $candidateHost
                            if ($wildcardCache[$scopeItem.RootDomain] -contains $candidateHost) {
                                $record.Discovery.Add('subfinder') | Out-Null
                            } elseif ($candidateHost -eq $scopeItem.RootDomain) {
                                $record.Discovery.Add('wildcard-apex') | Out-Null
                            }
                            $record.SourceScopeIds.Add($scopeItem.Id) | Out-Null; $record.SourceTypes.Add($scopeItem.Type) | Out-Null; $record.RootDomains.Add($scopeItem.RootDomain) | Out-Null
                            foreach ($candidateUrl in Get-ProbeCandidateUrls -ScopeItem $scopeItem -TargetHost $candidateHost -RespectSchemeOnly:$RespectSchemeOnly) { $record.CandidateUrls.Add($candidateUrl) | Out-Null }

                            foreach ($historicalUrl in @($historicalUrlCache[$scopeItem.RootDomain])) {
                                $historicalUri = $null
                                if (-not [Uri]::TryCreate($historicalUrl, [UriKind]::Absolute, [ref]$historicalUri)) { continue }
                                if ($historicalUri.DnsSafeHost.ToLowerInvariant() -ne $candidateHost) { continue }
                                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $historicalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                                $historicalExclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $candidateHost -Url $historicalUrl -Path $historicalUri.AbsolutePath
                                if ($historicalExclusion.IsExcluded) { Add-ExclusionRecord -Phase 'HistoricalDiscovery' -ScopeItem $scopeItem -Target $historicalUrl -ExclusionResult $historicalExclusion; continue }
                                $record.CandidateUrls.Add($historicalUrl) | Out-Null
                                $record.Discovery.Add('gau') | Out-Null
                            }

                            foreach ($historicalUrl in @($waybackUrlCache[$scopeItem.RootDomain])) {
                                $historicalUri = $null
                                if (-not [Uri]::TryCreate($historicalUrl, [UriKind]::Absolute, [ref]$historicalUri)) { continue }
                                if ($historicalUri.DnsSafeHost.ToLowerInvariant() -ne $candidateHost) { continue }
                                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $historicalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                                $historicalExclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $candidateHost -Url $historicalUrl -Path $historicalUri.AbsolutePath
                                if ($historicalExclusion.IsExcluded) { Add-ExclusionRecord -Phase 'HistoricalDiscovery' -ScopeItem $scopeItem -Target $historicalUrl -ExclusionResult $historicalExclusion; continue }
                                $record.CandidateUrls.Add($historicalUrl) | Out-Null
                                $record.Discovery.Add('waybackurls') | Out-Null
                            }
                        }
                    }
                }
            }
            $hostsAll = @(
                $hostMap.Keys | Sort-Object | ForEach-Object {
                    $record = $hostMap[$_]
                    [pscustomobject]@{
                        Host           = $_
                        Discovery      = @($record.Discovery | Sort-Object)
                        SourceScopeIds = @($record.SourceScopeIds | Sort-Object)
                        SourceTypes    = @($record.SourceTypes | Sort-Object)
                        CandidateUrls  = @($record.CandidateUrls | Sort-Object)
                        RootDomains    = @($record.RootDomains | Sort-Object)
                    }
                }
            )
            Write-JsonFile -Path $layout.HostsAllJson -Data $hostsAll
        }
        if ($exportCsvEnabled) { Export-FlatCsv -Path $layout.HostsAllCsv -Rows $hostsAll }

        $probeInputs = @($hostsAll | ForEach-Object { $_.CandidateUrls } | Select-Object -Unique)

        if ($useResume -and (Test-Path -LiteralPath $layout.LiveTargetsJson)) {
            Write-StageBanner -Step 4 -Title 'Validation HTTP'
            Write-ReconLog -Level INFO -Message 'Resume: loading cached live targets.'
            $liveTargets = @(Get-Content -LiteralPath $layout.LiveTargetsJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
        } else {
            Write-StageBanner -Step 4 -Title 'Validation HTTP'
            Write-StageProgress -Step 4 -Title 'Validation HTTP' -Percent 10 -Status "$($probeInputs.Count) probe candidates"
            $liveTargets = ConvertTo-ArrayOrEmpty -Data (
                Invoke-HttpProbe -InputUrls $probeInputs -ScopeItems $scopeItems -HttpxPath $tools.Httpx.Path -RawOutputPath $layout.HttpxRaw -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -RespectSchemeOnly:$RespectSchemeOnly
            )

            if ((Get-ScopeForgeItemCount -Data $liveTargets) -eq 0) {
                $reducedHttpxInputs = @(Select-NativeProbeFallbackInputs -InputUrls $probeInputs -MaxPerHost 1 -MaxTotal ([Math]::Min([Math]::Max(($Threads * 20), 50), 250)))
                if ($reducedHttpxInputs.Count -gt 0) {
                    Write-ReconLog -Level WARN -Message ("Validation HTTP returned no retained live targets from httpx. Reduced httpx rescue will probe {0} bounded candidate(s) before native fallback." -f $reducedHttpxInputs.Count)
                    $liveTargets = ConvertTo-ArrayOrEmpty -Data (
                        Invoke-HttpProbe -InputUrls $reducedHttpxInputs -ScopeItems $scopeItems -HttpxPath $tools.Httpx.Path -RawOutputPath $layout.HttpxRaw -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -RespectSchemeOnly:$RespectSchemeOnly -AppendOutput
                    )
                    if ((Get-ScopeForgeItemCount -Data $liveTargets) -gt 0) {
                        Write-ReconLog -Level WARN -Message ("Reduced httpx rescue retained {0} live target(s) after the full pass returned none." -f $liveTargets.Count)
                    }
                }
            }

            if ((Get-ScopeForgeItemCount -Data $liveTargets) -eq 0) {
                Write-ReconLog -Level WARN -Message 'Validation HTTP returned no retained live targets from httpx. Native HTTP rescue will run on a reduced candidate set.'
                $liveTargets = ConvertTo-ArrayOrEmpty -Data (
                    Invoke-NativeHttpProbeFallback -InputUrls $probeInputs -ScopeItems $scopeItems -Threads $Threads -TimeoutSeconds $TimeoutSeconds -UniqueUserAgent $UniqueUserAgent -RespectSchemeOnly:$RespectSchemeOnly
                )
                if ((Get-ScopeForgeItemCount -Data $liveTargets) -eq 0) {
                    Write-ReconLog -Level WARN -Message 'Native HTTP rescue also returned no retained live targets. Empty result set will be written and the run will continue.'
                } else {
                    Write-ReconLog -Level WARN -Message ("Native HTTP rescue retained {0} live target(s) after httpx returned none." -f $liveTargets.Count)
                }
            }

            Write-JsonFile -Path $layout.LiveTargetsJson -Data $liveTargets
        }
        if ($exportCsvEnabled) { Export-FlatCsv -Path $layout.LiveTargetsCsv -Rows $liveTargets }

        $hostsLive = ConvertTo-ArrayOrEmpty -Data @(
            $liveTargets | Group-Object -Property Host | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{
                    Host         = $_.Name
                    Urls         = @($_.Group | Select-Object -ExpandProperty Url -Unique)
                    StatusCodes  = @($_.Group | Select-Object -ExpandProperty StatusCode -Unique)
                    Technologies = @($_.Group | ForEach-Object { $_.Technologies } | Where-Object { $_ } | Select-Object -Unique)
                    ScopeIds     = @($_.Group | ForEach-Object { $_.MatchedScopeIds } | Select-Object -Unique)
                }
            }
        )

        Write-JsonFile -Path $layout.HostsLiveJson -Data $hostsLive

        if ($useResume -and (Test-Path -LiteralPath $layout.UrlsDiscoveredJson)) {
            Write-StageBanner -Step 5 -Title 'Crawl'
            Write-ReconLog -Level INFO -Message 'Resume: loading cached discovered URLs.'
            $discoveredUrls = @(Get-Content -LiteralPath $layout.UrlsDiscoveredJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
        } else {
            Write-StageBanner -Step 5 -Title 'Crawl'

            if ((Get-ScopeForgeItemCount -Data $liveTargets) -eq 0) {
                Write-ReconLog -Level WARN -Message 'Skipping crawl because no live HTTP targets were retained after validation.'
                $discoveredUrls = @()
            } else {
                $discoveredUrls = Invoke-KatanaCrawl -LiveTargets $liveTargets -ScopeItems $scopeItems -KatanaPath $tools.Katana.Path -RawOutputPath $layout.KatanaRaw -TempDirectory $layout.Temp -Depth $Depth -Threads $Threads -TimeoutSeconds $TimeoutSeconds -UniqueUserAgent $UniqueUserAgent -RespectSchemeOnly:$RespectSchemeOnly

                if ($tools.Hakrawler) {
                    Write-ReconLog -Level INFO -Message 'Running hakrawler as a supplemental strictly in-scope crawl pass.'
                    $hakrawlerUrls = Invoke-HakrawlerCrawl -LiveTargets $liveTargets -ScopeItems $scopeItems -HakrawlerPath $tools.Hakrawler.Path -RawOutputPath $layout.HakrawlerRaw -TempDirectory $layout.Temp -Depth ([Math]::Max([Math]::Min($Depth, 3), 1)) -TimeoutSeconds $TimeoutSeconds -RespectSchemeOnly:$RespectSchemeOnly
                    $discoveredUrls = Merge-DiscoveredUrlResults -Inputs @($discoveredUrls + $hakrawlerUrls)
                } else {
                    $discoveredUrls = Merge-DiscoveredUrlResults -Inputs $discoveredUrls
                }
            }

            $discoveredUrls = ConvertTo-ArrayOrEmpty -Data $discoveredUrls
            Write-JsonFile -Path $layout.UrlsDiscoveredJson -Data $discoveredUrls
        }
        $endpointLines = @($discoveredUrls | Select-Object -ExpandProperty Url -Unique)
        if ($endpointLines.Count -eq 0) {
            $endpointLines = @('')
        }
        Set-Content -LiteralPath $layout.EndpointsUniqueTxt -Value $endpointLines -Encoding utf8
        if ($exportCsvEnabled) { Export-FlatCsv -Path $layout.UrlsDiscoveredCsv -Rows $discoveredUrls }

        Write-StageBanner -Step 6 -Title 'Génération des rapports'
        $triageData = Get-TriageReconData -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -TriageState $script:ScopeForgeContext.TriageState
        $script:ScopeForgeContext.Triage = $triageData
        $interestingUrls = ConvertTo-ArrayOrEmpty -Data @($triageData.ReviewableFindings)
        $liveTargets = ConvertTo-ArrayOrEmpty -Data $liveTargets
        $hostsLive = ConvertTo-ArrayOrEmpty -Data $hostsLive
        $discoveredUrls = ConvertTo-ArrayOrEmpty -Data $discoveredUrls
        $interestingUrls = ConvertTo-ArrayOrEmpty -Data $interestingUrls
        $passiveLeads = ConvertTo-ArrayOrEmpty -Data (Get-PassiveLeadFindings -HostsAll $hostsAll)
        $filteredUrls = ConvertTo-ArrayOrEmpty -Data @($triageData.FilteredFindings)
        $noiseUrls = ConvertTo-ArrayOrEmpty -Data @($triageData.NoiseFindings)
        $shortlist = ConvertTo-ArrayOrEmpty -Data @($triageData.Shortlist)
        $allFindings = ConvertTo-ArrayOrEmpty -Data (
            Get-UnifiedFindings -InterestingUrls $interestingUrls -PassiveLeads $passiveLeads
        )
        $null = $allFindings
        $summary = Merge-ReconResults -ScopeItems $scopeItems -HostsAll $hostsAll -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -InterestingUrls $interestingUrls -Exclusions @($script:ScopeForgeContext.Exclusions) -Errors @($script:ScopeForgeContext.Errors) -ProgramName $ProgramName -UniqueUserAgent $UniqueUserAgent
        Export-ReconReport -Summary $summary -ScopeItems $scopeItems -HostsAll $hostsAll -HostsLive $hostsLive -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -InterestingUrls $interestingUrls -Exclusions @($script:ScopeForgeContext.Exclusions) -Errors @($script:ScopeForgeContext.Errors) -Layout $layout -ExportJson:$exportJsonEnabled -ExportCsv:$exportCsvEnabled -ExportHtml:$exportHtmlEnabled
        Write-StageProgress -Step 6 -Title 'Génération des rapports' -Percent 100 -Status 'Reports completed'

        Save-ScopeForgeTriageState -State $script:ScopeForgeContext.TriageState -SeenReviewKeys @($triageData.SeenReviewKeys)
        $result = [pscustomobject]@{ ProgramName = $ProgramName; OutputDir = $layout.Root; ScopeItems = $scopeItems; HostsAll = $hostsAll; HostsLive = $hostsLive; LiveTargets = $liveTargets; DiscoveredUrls = $discoveredUrls; FilteredUrls = $filteredUrls; NoiseUrls = $noiseUrls; InterestingUrls = $interestingUrls; Shortlist = $shortlist; Summary = $summary; TriageStatePath = $script:ScopeForgeContext.TriageState.Path; Exclusions = @($script:ScopeForgeContext.Exclusions); Errors = @($script:ScopeForgeContext.Errors); ExportHtmlEnabled = $exportHtmlEnabled; ExportCsvEnabled = $exportCsvEnabled; ExportJsonEnabled = $exportJsonEnabled }
        if (-not $Quiet) {
            Write-Host ''
            Write-Host 'Recon summary' -ForegroundColor Green
            Write-Host ('  Scope items      : {0}' -f $summary.ScopeItemCount) -ForegroundColor Gray
            Write-Host ('  Excluded assets  : {0}' -f $summary.ExcludedItemCount) -ForegroundColor Gray
            Write-Host ('  Hosts discovered : {0}' -f $summary.DiscoveredHostCount) -ForegroundColor Gray
            Write-Host ('  Live hosts       : {0}' -f $summary.LiveHostCount) -ForegroundColor Gray
            Write-Host ('  Live targets     : {0}' -f $summary.LiveTargetCount) -ForegroundColor Gray
            Write-Host ('  URLs discovered  : {0}' -f $summary.DiscoveredUrlCount) -ForegroundColor Gray
            Write-Host ('  URLs filtrees    : {0}' -f $summary.FilteredUrlCount) -ForegroundColor Gray
            Write-Host ('  Reviewable       : {0}' -f $summary.ReviewableUrlCount) -ForegroundColor Gray
            Write-Host ('  Bruit retire     : {0}' -f $summary.NoiseRemovedCount) -ForegroundColor Gray
            Write-Host ('  Interesting URLs : {0}' -f $summary.InterestingUrlCount) -ForegroundColor Gray
            Write-Host ('  Errors           : {0}' -f $summary.ErrorCount) -ForegroundColor Gray
            Write-Host ('  Output           : {0}' -f $layout.Root) -ForegroundColor Gray
            Write-Host ('  Main log         : {0}' -f $layout.MainLog) -ForegroundColor Gray
            Write-Host ('  Errors log       : {0}' -f $layout.ErrorsLog) -ForegroundColor Gray
            Write-Host ('  Exclusions log   : {0}' -f $layout.ExclusionsLog) -ForegroundColor Gray
            Write-Host ('  Tools log        : {0}' -f $layout.ToolsLog) -ForegroundColor Gray
            Write-Host ('  Donnees brutes   : {0}' -f $layout.Raw) -ForegroundColor Gray
            Write-Host ('  Donnees norm.    : {0}' -f $layout.Normalized) -ForegroundColor Gray
            Write-Host ('  Rapport HTML     : {0}' -f $layout.ReportHtml) -ForegroundColor Gray
            Write-Host ('  Triage MD        : {0}' -f $layout.TriageMarkdown) -ForegroundColor Gray
            Write-Host ('  Shortlist MD     : {0}' -f $layout.ShortlistMarkdown) -ForegroundColor Gray
            Write-Host ('  Etat triage      : {0}' -f $script:ScopeForgeContext.TriageState.Path) -ForegroundColor Gray
            if ((Get-ScopeForgeItemCount -Data $interestingUrls) -gt 0) {
                Write-Host ''
                Write-Host 'Top interesting pages' -ForegroundColor Yellow
                foreach ($item in ($interestingUrls | Select-Object -First 10)) {
                    Write-Host ('  [{0}] {1}' -f $item.Score, $item.Url) -ForegroundColor DarkYellow
                }
            }
        }
        return $result
    } catch {
        Add-ErrorRecord -Phase 'Runtime' -Message $_.Exception.Message -Details $_.ScriptStackTrace -ErrorCode 'RuntimeError'
        throw
    } finally {
        Complete-ScopeForgeProgress 
    }
}

if ($MyInvocation.InvocationName -ne '.' -and $PSBoundParameters.ContainsKey('ScopeFile')) {
    $invokeParameters = @{}
    foreach ($name in @('ScopeFile', 'Depth', 'OutputDir', 'ProgramName', 'UniqueUserAgent', 'Threads', 'TimeoutSeconds', 'EnableGau', 'EnableWaybackUrls', 'EnableHakrawler', 'NoInstall', 'Quiet', 'IncludeApex', 'RespectSchemeOnly', 'ExportHtml', 'ExportCsv', 'ExportJson', 'Resume')) {
        if ($PSBoundParameters.ContainsKey($name)) { $invokeParameters[$name] = $PSBoundParameters[$name] }
    }
    if ($VerbosePreference -eq 'Continue') { $invokeParameters['Verbose'] = $true }
    Invoke-BugBountyRecon @invokeParameters
}

