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
$script:ScopeForgeContext = $null

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

function Get-OutputLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputDir)

    $root = Resolve-AbsolutePath -Path $OutputDir
    [pscustomobject]@{
        Root               = $root
        Logs               = Join-Path $root 'logs'
        Raw                = Join-Path $root 'raw'
        Normalized         = Join-Path $root 'normalized'
        Reports            = Join-Path $root 'reports'
        Temp               = Join-Path $root 'temp'
        ToolsRoot          = Join-Path $root 'tools'
        ToolsBin           = Join-Path (Join-Path $root 'tools') 'bin'
        ToolsDownloads     = Join-Path (Join-Path $root 'tools') 'downloads'
        ToolsExtracted     = Join-Path (Join-Path $root 'tools') 'extracted'
        MainLog            = Join-Path (Join-Path $root 'logs') 'main.log'
        ErrorsLog          = Join-Path (Join-Path $root 'logs') 'errors.log'
        ExclusionsLog      = Join-Path (Join-Path $root 'logs') 'exclusions.log'
        ToolsLog           = Join-Path (Join-Path $root 'logs') 'tools.log'
        SubfinderRaw       = Join-Path (Join-Path $root 'raw') 'subfinder_raw.txt'
        GauRaw             = Join-Path (Join-Path $root 'raw') 'gau_raw.txt'
        WaybackRaw         = Join-Path (Join-Path $root 'raw') 'waybackurls_raw.txt'
        HttpxRaw           = Join-Path (Join-Path $root 'raw') 'httpx_raw.jsonl'
        KatanaRaw          = Join-Path (Join-Path $root 'raw') 'katana_raw.jsonl'
        HakrawlerRaw       = Join-Path (Join-Path $root 'raw') 'hakrawler_raw.txt'
        ScopeNormalized    = Join-Path (Join-Path $root 'normalized') 'scope_normalized.json'
        HostsAllJson       = Join-Path (Join-Path $root 'normalized') 'hosts_all.json'
        HostsAllCsv        = Join-Path (Join-Path $root 'normalized') 'hosts_all.csv'
        HostsLiveJson      = Join-Path (Join-Path $root 'normalized') 'hosts_live.json'
        LiveTargetsJson    = Join-Path (Join-Path $root 'normalized') 'live_targets.json'
        LiveTargetsCsv     = Join-Path (Join-Path $root 'normalized') 'live_targets.csv'
        UrlsDiscoveredJson = Join-Path (Join-Path $root 'normalized') 'urls_discovered.json'
        UrlsDiscoveredCsv  = Join-Path (Join-Path $root 'normalized') 'urls_discovered.csv'
        InterestingUrlsJson = Join-Path (Join-Path $root 'normalized') 'interesting_urls.json'
        InterestingUrlsCsv  = Join-Path (Join-Path $root 'normalized') 'interesting_urls.csv'
        InterestingFamiliesJson = Join-Path (Join-Path $root 'normalized') 'interesting_families.json'
        EndpointsUniqueTxt = Join-Path (Join-Path $root 'normalized') 'endpoints_unique.txt'
        SummaryJson        = Join-Path (Join-Path $root 'reports') 'summary.json'
        SummaryCsv         = Join-Path (Join-Path $root 'reports') 'summary.csv'
        ReportHtml         = Join-Path (Join-Path $root 'reports') 'report.html'
        TriageMarkdown     = Join-Path (Join-Path $root 'reports') 'triage.md'
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

    foreach ($file in @($Layout.MainLog, $Layout.ErrorsLog, $Layout.ExclusionsLog, $Layout.ToolsLog)) {
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
        Layout            = $Layout
        ProgramName       = $ProgramName
        Quiet             = $Quiet
        ExportJsonEnabled = $ExportJsonEnabled
        ExportCsvEnabled  = $ExportCsvEnabled
        ExportHtmlEnabled = $ExportHtmlEnabled
        Errors            = [System.Collections.Generic.List[object]]::new()
        Exclusions        = [System.Collections.Generic.List[object]]::new()
        Warnings          = [System.Collections.Generic.List[string]]::new()
        StartedAtUtc      = [DateTime]::UtcNow
    }
}

function Write-ReconLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'TOOL', 'EXCLUDED', 'VERBOSE')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Path
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
        Add-Content -LiteralPath $targetPath -Value $entry -Encoding utf8
        if (($Level -eq 'ERROR') -and $script:ScopeForgeContext -and ($targetPath -ne $script:ScopeForgeContext.Layout.MainLog)) {
            Add-Content -LiteralPath $script:ScopeForgeContext.Layout.MainLog -Value $entry -Encoding utf8
        }
    }

    if ($script:ScopeForgeContext -and $script:ScopeForgeContext.Quiet -and ($Level -notin @('WARN', 'ERROR'))) {
        return
    }

    switch ($Level) {
        'INFO' { Write-Host $Message -ForegroundColor Cyan }
        'WARN' { Write-Host $Message -ForegroundColor Yellow }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'EXCLUDED' { Write-Host $Message -ForegroundColor DarkYellow }
        default { Write-Verbose $Message }
    }
}

function Write-StageBanner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Step, [Parameter(Mandatory)][string]$Title)

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

    if ($script:ScopeForgeContext -and -not $script:ScopeForgeContext.Quiet) {
        Write-Progress -Id 1 -Activity ('[{0}/6] {1}' -f $Step, $Title) -PercentComplete $Percent -Status $Status
    }
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
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
        throw "Command timed out after $TimeoutSeconds seconds: $resolvedFilePath"
    }

    $stdout = if (Test-Path -LiteralPath $StdOutPath) { Get-Content -LiteralPath $StdOutPath -Raw -Encoding utf8 } else { '' }
    $stderr = if (Test-Path -LiteralPath $StdErrPath) { Get-Content -LiteralPath $StdErrPath -Raw -Encoding utf8 } else { '' }
    if ($stderr) { Write-ReconLog -Level TOOL -Message ($stderr.Trim()) }
    if (($process.ExitCode -ne 0) -and -not $IgnoreExitCode) { throw "Command failed with exit code $($process.ExitCode): $resolvedFilePath" }

    $result = [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr; StdOutPath = $StdOutPath; StdErrPath = $StdErrPath; FilePath = $resolvedFilePath; Arguments = $filteredArguments }
    if ($createdStdOut -and (Test-Path -LiteralPath $StdOutPath)) { Remove-Item -LiteralPath $StdOutPath -Force -ErrorAction SilentlyContinue }
    if ($createdStdErr -and (Test-Path -LiteralPath $StdErrPath)) { Remove-Item -LiteralPath $StdErrPath -Force -ErrorAction SilentlyContinue }
    return $result
}

function Get-ToolHelpText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolPath, [int]$TimeoutSeconds = 15)

    try {
        $result = Invoke-ExternalCommand -FilePath $ToolPath -Arguments @('-h') -TimeoutSeconds $TimeoutSeconds -IgnoreExitCode
        return ('{0}`n{1}' -f $result.StdOut, $result.StdErr)
    } catch {
        try {
            $result = Invoke-ExternalCommand -FilePath $ToolPath -Arguments @('--help') -TimeoutSeconds $TimeoutSeconds -IgnoreExitCode
            return ('{0}`n{1}' -f $result.StdOut, $result.StdErr)
        } catch {
            return ''
        }
    }
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
    if ($ArchivePath -match '\.zip$') { [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath, $true); return }
    if ($ArchivePath -match '\.tar\.gz$') {
        $tarCommand = Get-Command -Name 'tar' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $tarCommand) { throw 'Unable to extract tar.gz archive because tar is not available.' }
        $null = Invoke-ExternalCommand -FilePath $tarCommand.Source -Arguments @('-xzf', $ArchivePath, '-C', $DestinationPath) -TimeoutSeconds 120
        return
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
    $release = Invoke-RestMethod -Uri ("https://api.github.com/repos/$Repository/releases/latest") -Headers $headers -Method Get -TimeoutSec $TimeoutSeconds
    if (-not $release.assets) { throw "Unable to find release assets for $ToolName." }

    $platformAliases = switch ($PlatformInfo.Os) {
        'windows' { @('windows', 'win') }
        'linux' { @('linux') }
        'darwin' { @('darwin', 'macos', 'mac') }
        default { throw "Unsupported bootstrap platform: $($PlatformInfo.Os)" }
    }
    $archAliases = switch ($PlatformInfo.Architecture) {
        'amd64' { @('amd64', 'x86_64') }
        'arm64' { @('arm64', 'aarch64') }
        '386' { @('386', 'x86') }
        default { @($PlatformInfo.Architecture) }
    }

    $asset = $release.assets | Where-Object {
        $name = [string]$_.name
        ($name -match "(?i)$([regex]::Escape($ToolName))") -and
        ($platformAliases | Where-Object { $name -match "(?i)$([regex]::Escape($_))" }) -and
        ($archAliases | Where-Object { $name -match "(?i)$([regex]::Escape($_))" })
    } | Select-Object -First 1
    if (-not $asset) { throw "Unable to select a release asset for $ToolName." }

    $downloadUri = [Uri]([string]$asset.browser_download_url)
    if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -notmatch '(^|\.)(github\.com|githubusercontent\.com)$') { throw "Refusing unexpected download host for ${ToolName}: $downloadUri" }

    $archivePath = Join-Path $Layout.ToolsDownloads $asset.name
    $extractPath = Join-Path $Layout.ToolsExtracted ("{0}-{1}" -f $ToolName, [Guid]::NewGuid().ToString('N'))
    Invoke-WebRequest -Uri $downloadUri.AbsoluteUri -Headers @{ 'User-Agent' = 'ScopeForge/1.0' } -OutFile $archivePath -TimeoutSec $TimeoutSeconds

    $downloadedInfo = Get-Item -LiteralPath $archivePath
    if ($downloadedInfo.Length -le 0) { throw "Downloaded archive for $ToolName is empty." }
    if ($asset.size -and ([int64]$asset.size -ne [int64]$downloadedInfo.Length)) { throw "Downloaded archive size mismatch for $ToolName." }

    Expand-CompressedArchive -ArchivePath $archivePath -DestinationPath $extractPath
    $binaryName = if ($IsWindows) { "$BinaryName.exe" } else { $BinaryName }
    $binary = Get-ChildItem -Path $extractPath -Recurse -File | Where-Object { $_.Name -ieq $binaryName } | Select-Object -First 1
    if (-not $binary) { throw "Unable to locate extracted binary for $ToolName." }

    $destination = Join-Path $Layout.ToolsBin $binary.Name
    Copy-Item -LiteralPath $binary.FullName -Destination $destination -Force
    if (-not $IsWindows) {
        $chmod = Get-Command -Name 'chmod' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($chmod) { $null = Invoke-ExternalCommand -FilePath $chmod.Source -Arguments @('755', $destination) -TimeoutSeconds 15 }
    }

    return (Resolve-Path -LiteralPath $destination).Path
}

function Ensure-ReconTools {
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
        if (-not $toolPath) {
            if ($tool.Required) {
                if ($NoInstall) { throw "Required tool '$($tool.Name)' not found and -NoInstall was specified." }
                $toolPath = Install-ExternalTool -ToolName $tool.Name -Repository $tool.Repository -BinaryName $tool.BinaryName -PlatformInfo $platformInfo -Layout $Layout -TimeoutSeconds $TimeoutSeconds
            } elseif (-not $NoInstall) {
                try {
                    $toolPath = Install-ExternalTool -ToolName $tool.Name -Repository $tool.Repository -BinaryName $tool.BinaryName -PlatformInfo $platformInfo -Layout $Layout -TimeoutSeconds $TimeoutSeconds
                } catch {
                    Write-ReconLog -Level WARN -Message "Optional tool '$($tool.Name)' is unavailable: $($_.Exception.Message)"
                    $toolPath = $null
                }
            } else {
                Write-ReconLog -Level WARN -Message "Optional tool '$($tool.Name)' not found. Related enrichment will be skipped."
            }
        }
        $resolvedTools[$tool.Name] = if ($toolPath) { [pscustomobject]@{ Path = $toolPath; HelpText = Get-ToolHelpText -ToolPath $toolPath } } else { $null }
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

function Normalize-Exclusions {
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

function Normalize-PathPrefix {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq '/') { return '/' }
    $normalized = if ($Path.StartsWith('/')) { $Path } else { '/' + $Path }
    if ($normalized.Length -gt 1) { $normalized = $normalized.TrimEnd('/') }
    return $(if ($normalized) { $normalized } else { '/' })
}

function Normalize-ScopeItem {
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
    $exclusions = Normalize-Exclusions -InputObject $(if ($exclusionsProperty) { $exclusionsProperty.Value } else { @() })

    switch ($normalizedType) {
        'URL' {
            $uri = $null
            if (-not [Uri]::TryCreate($normalizedValue, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) { throw "Scope item #$Index contains an invalid absolute HTTP(S) URL: $normalizedValue" }
            $targetHost = $uri.DnsSafeHost.ToLowerInvariant()
            if (-not (Test-ValidDnsName -Name $targetHost)) { throw "Scope item #$Index contains an invalid hostname in URL: $targetHost" }
            $pathPrefix = Normalize-PathPrefix -Path $uri.AbsolutePath
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
    try { $parsed = ConvertFrom-Json -InputObject $raw -Depth 100 } catch { throw "Scope file is not valid JSON: $($_.Exception.Message)" }
    if ($parsed -isnot [System.Collections.IEnumerable] -or $parsed -is [string]) { throw 'Scope file must contain a JSON array.' }
    $items = [System.Collections.Generic.List[object]]::new(); $index = 0
    foreach ($item in $parsed) { $index++; $items.Add((Normalize-ScopeItem -InputObject $item -Index $index -IncludeApex:$IncludeApex)) }
    if ($items.Count -eq 0) { throw 'Scope file does not contain any scope items.' }
    return @($items)
}

function Test-PathPrefixMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CandidatePath, [Parameter(Mandatory)][string]$Prefix)

    $normalizedCandidate = if ([string]::IsNullOrWhiteSpace($CandidatePath)) { '/' } else { $CandidatePath }
    $normalizedPrefix = Normalize-PathPrefix -Path $Prefix
    if ($normalizedPrefix -eq '/') { return $true }
    if ($normalizedCandidate -ceq $normalizedPrefix) { return $true }
    return $normalizedCandidate.StartsWith($normalizedPrefix + '/', [System.StringComparison]::Ordinal)
}

function Test-ExclusionMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$ScopeItem, [string]$TargetHost, [string]$Url, [string]$Path)

    $result = [pscustomobject]@{ IsExcluded = $false; Token = $null; MatchedOn = $null; MatchedText = $null }
    foreach ($token in $ScopeItem.Exclusions) {
        foreach ($entry in @(@{ Name = 'host'; Value = $TargetHost }, @{ Name = 'url'; Value = $Url }, @{ Name = 'path'; Value = $Path })) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) { continue }
            if ([string]$entry.Value.ToLowerInvariant() -like "*$token*") {
                $result.IsExcluded = $true; $result.Token = $token; $result.MatchedOn = $entry.Name; $result.MatchedText = [string]$entry.Value
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
        'Domain' { foreach ($scheme in @('https', 'http')) { $null = $urls.Add("{0}://{1}" -f $scheme, $ScopeItem.Host) } }
        'Wildcard' {
            if (-not $TargetHost) { return @() }
            if ($ScopeItem.Scheme) {
                $null = $urls.Add("{0}://{1}" -f $ScopeItem.Scheme, $TargetHost)
                if (-not $RespectSchemeOnly) {
                    $alternate = if ($ScopeItem.Scheme -eq 'https') { 'http' } else { 'https' }
                    $null = $urls.Add("{0}://{1}" -f $alternate, $TargetHost)
                }
            } else {
                foreach ($scheme in @('https', 'http')) { $null = $urls.Add("{0}://{1}" -f $scheme, $TargetHost) }
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

function Add-ErrorRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string]$Message, [string]$Target, [string]$Details)

    $record = [pscustomobject]@{ Timestamp = [DateTimeOffset]::Now.ToString('o'); Phase = $Phase; Target = $Target; Message = $Message; Details = $Details }
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
    Write-ReconLog -Level EXCLUDED -Message ("[{0}] Excluded by token '{1}' on {2}: {3}" -f $Phase, $ExclusionResult.Token, $ExclusionResult.MatchedOn, $Target)
}

function New-HostInventoryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Host)

    return [ordered]@{
        Host           = $Host
        Discovery      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        SourceScopeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        SourceTypes    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        CandidateUrls  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        RootDomains    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
}

function Get-OrCreateHostInventoryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$HostMap, [Parameter(Mandatory)][string]$Host)

    if (-not $HostMap.ContainsKey($Host)) {
        $HostMap[$Host] = New-HostInventoryRecord -Host $Host
    }
    return $HostMap[$Host]
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
        $result = Invoke-ExternalCommand -FilePath $SubfinderPath -Arguments @('-silent', '-d', $RootDomain) -TimeoutSeconds $TimeoutSeconds -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
        $rawLines = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Encoding utf8 } else { @() }
        if ($rawLines.Count -gt 0) {
            Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
            Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
        }
        if ($result.ExitCode -ne 0) { Add-ErrorRecord -Phase 'PassiveDiscovery' -Target $RootDomain -Message 'subfinder returned a non-zero exit code.' -Details $result.StdErr }
        return @($rawLines | ForEach-Object { $_.Trim().TrimEnd('.').ToLowerInvariant() } | Where-Object { $_ -and (Test-ValidDnsName -Name $_) } | Select-Object -Unique)
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

        $result = Invoke-ExternalCommand -FilePath $GauPath -Arguments $arguments -TimeoutSeconds $TimeoutSeconds -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
        $rawLines = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Encoding utf8 } else { @() }

        if ($rawLines.Count -gt 0) {
            Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
            Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
        }

        if ($result.ExitCode -ne 0) {
            Add-ErrorRecord -Phase 'HistoricalDiscovery' -Target $Target -Message 'gau returned a non-zero exit code.' -Details $result.StdErr
        }

        $urls = $rawLines |
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

        return @($urls)
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
        $result = Invoke-ExternalCommand -FilePath $WaybackUrlsPath -Arguments @($Target) -TimeoutSeconds $TimeoutSeconds -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
        $rawLines = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Encoding utf8 } else { @() }

        if ($rawLines.Count -gt 0) {
            Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
            Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
        }

        if ($result.ExitCode -ne 0) {
            Add-ErrorRecord -Phase 'HistoricalDiscovery' -Target $Target -Message 'waybackurls returned a non-zero exit code.' -Details $result.StdErr
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
        [Parameter(Mandatory)][pscustomobject[]]$LiveTargets,
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
            Add-ErrorRecord -Phase 'SupplementalCrawl' -Message 'hakrawler returned a non-zero exit code.' -Details $result.StdErr
        }

        $rawLines = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Encoding utf8 } else { @() }
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

            $host = $uri.DnsSafeHost.ToLowerInvariant()
            $exclusion = Test-ExclusionMatch -ScopeItem $matchedScopeItem -TargetHost $host -Url $candidate -Path $uri.AbsolutePath
            if ($exclusion.IsExcluded) {
                Add-ExclusionRecord -Phase 'SupplementalCrawl' -ScopeItem $matchedScopeItem -Target $candidate -ExclusionResult $exclusion
                continue
            }

            $key = Get-CanonicalUrlKey -Url $candidate
            if ($seen.Contains($key)) { continue }
            $null = $seen.Add($key)
            $results.Add([pscustomobject]@{
                    Url         = $candidate
                    Host        = $host
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
        [switch]$RespectSchemeOnly
    )

    if (-not $InputUrls -or $InputUrls.Count -eq 0) { return @() }

    $helpText = Get-ToolHelpText -ToolPath $HttpxPath
    $inputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-input-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scopeforge-httpx-{0}.err" -f ([Guid]::NewGuid().ToString('N')))

    try {
        Set-Content -LiteralPath $inputFile -Value ($InputUrls | Sort-Object -Unique) -Encoding utf8
        $arguments = @('-silent', '-json', '-l', $inputFile, '-threads', [string]$Threads, '-timeout', [string]$TimeoutSeconds, '-title', '-status-code', '-content-length')
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-tech-detect') { $arguments += '-tech-detect' }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-follow-redirects') { $arguments += '-follow-redirects' }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-location') { $arguments += '-location' }
        if ($UniqueUserAgent) {
            if (Test-ToolFlagSupport -HelpText $helpText -Flag '-H') { $arguments += @('-H', "User-Agent: $UniqueUserAgent") }
            elseif (Test-ToolFlagSupport -HelpText $helpText -Flag '-header') { $arguments += @('-header', "User-Agent: $UniqueUserAgent") }
        }

        $result = Invoke-ExternalCommand -FilePath $HttpxPath -Arguments $arguments -TimeoutSeconds ([Math]::Max($TimeoutSeconds * 4, 60)) -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
        if (Test-Path -LiteralPath $stdoutFile) { Copy-Item -LiteralPath $stdoutFile -Destination $RawOutputPath -Force } else { Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8 }
        if ($result.ExitCode -ne 0) { Add-ErrorRecord -Phase 'HttpProbe' -Message 'httpx returned a non-zero exit code.' -Details $result.StdErr }

        $liveTargets = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $lines = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Encoding utf8 } else { @() }

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $raw = $line | ConvertFrom-Json -Depth 100 } catch { Add-ErrorRecord -Phase 'HttpProbe' -Message 'Failed to parse httpx JSON line.' -Details $line; continue }

            $finalUrl = [string](Get-ObjectValue -InputObject $raw -Names @('url'))
            $inputValue = [string](Get-ObjectValue -InputObject $raw -Names @('input'))
            if ([string]::IsNullOrWhiteSpace($finalUrl)) { continue }

            $uri = $null
            if (-not [Uri]::TryCreate($finalUrl, [UriKind]::Absolute, [ref]$uri)) { continue }
            $resolvedHost = $uri.DnsSafeHost.ToLowerInvariant()
            $path = if ($uri.AbsolutePath) { $uri.AbsolutePath } else { '/' }
            $matchedScopeIds = [System.Collections.Generic.List[string]]::new()
            $matchedScopeTypes = [System.Collections.Generic.List[string]]::new()

            foreach ($scopeItem in $ScopeItems) {
                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $finalUrl -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $resolvedHost -Url $finalUrl -Path $path
                if ($exclusion.IsExcluded) { Add-ExclusionRecord -Phase 'HttpProbe' -ScopeItem $scopeItem -Target $finalUrl -ExclusionResult $exclusion; continue }
                $matchedScopeIds.Add($scopeItem.Id); $matchedScopeTypes.Add($scopeItem.Type)
            }

            if ($matchedScopeIds.Count -eq 0) { Write-ReconLog -Level WARN -Message "Discarding out-of-scope live target after httpx: $finalUrl"; continue }
            $canonicalKey = Get-CanonicalUrlKey -Url $finalUrl
            if ($seen.Contains($canonicalKey)) { continue }
            $null = $seen.Add($canonicalKey)

            $technologiesRaw = Get-ObjectValue -InputObject $raw -Names @('tech', 'technologies') -Default @()
            $technologies = if ($technologiesRaw -is [System.Collections.IEnumerable] -and $technologiesRaw -isnot [string]) { @($technologiesRaw | ForEach-Object { [string]$_ } | Where-Object { $_ }) } elseif ($technologiesRaw) { @([string]$technologiesRaw) } else { @() }

            $liveTargets.Add([pscustomobject]@{
                    Input = $inputValue; Url = $finalUrl; Host = $resolvedHost; Scheme = $uri.Scheme.ToLowerInvariant(); Port = if ($uri.IsDefaultPort) { $null } else { $uri.Port }; Path = $path
                    StatusCode = [int](Get-ObjectValue -InputObject $raw -Names @('status-code', 'status_code') -Default 0)
                    Title = [string](Get-ObjectValue -InputObject $raw -Names @('title') -Default '')
                    ContentLength = [int64](Get-ObjectValue -InputObject $raw -Names @('content-length', 'content_length') -Default 0)
                    Technologies = $technologies
                    RedirectLocation = [string](Get-ObjectValue -InputObject $raw -Names @('location') -Default '')
                    WebServer = [string](Get-ObjectValue -InputObject $raw -Names @('webserver', 'web_server') -Default '')
                    MatchedScopeIds = @($matchedScopeIds)
                    MatchedTypes = @($matchedScopeTypes | Select-Object -Unique)
                    Source = 'httpx'
                })
        }

        return @($liveTargets)
    } finally {
        Remove-Item -LiteralPath $inputFile, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
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
        [Parameter(Mandatory)][pscustomobject[]]$LiveTargets,
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
    $scopeIndex = @{}; foreach ($scopeItem in $ScopeItems) { $scopeIndex[$scopeItem.Id] = $scopeItem }
    $jobs = [System.Collections.Generic.List[object]]::new()
    $jobKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($liveTarget in $LiveTargets) {
        foreach ($scopeId in $liveTarget.MatchedScopeIds) {
            $scopeItem = $scopeIndex[$scopeId]
            $seedUrl = if ($scopeItem.Type -eq 'URL') { $scopeItem.StartUrl } else { $liveTarget.Url }
            $jobKey = '{0}|{1}' -f $scopeItem.Id, (Get-CanonicalUrlKey -Url $seedUrl)
            if ($jobKeys.Contains($jobKey)) { continue }
            $jobKeys.Add($jobKey) | Out-Null
            $jobs.Add([pscustomobject]@{ ScopeItem = $scopeItem; Definition = Get-KatanaScopeDefinition -ScopeItem $scopeItem -SeedUrl $seedUrl -RespectSchemeOnly:$RespectSchemeOnly })
        }
    }

    Set-Content -LiteralPath $RawOutputPath -Value '' -Encoding utf8
    $results = [System.Collections.Generic.List[object]]::new()
    $seenUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $jobNumber = 0

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
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-cos' -and $outscopeRegexes.Count -gt 0) { $arguments += @('-cos', '(?i)(' + (($scopeItem.Exclusions | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')') }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-fs') { $arguments += @('-fs', $definition.FieldScope) }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-jc') { $arguments += '-jc' }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-kf') { $arguments += @('-kf', 'all') }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-iqp') { $arguments += '-iqp' }
        if (Test-ToolFlagSupport -HelpText $helpText -Flag '-c') { $arguments += @('-c', [string]$Threads) }
        if ($UniqueUserAgent) {
            if (Test-ToolFlagSupport -HelpText $helpText -Flag '-H') { $arguments += @('-H', "User-Agent: $UniqueUserAgent") }
            elseif (Test-ToolFlagSupport -HelpText $helpText -Flag '-header') { $arguments += @('-header', "User-Agent: $UniqueUserAgent") }
        }

        try {
            $result = Invoke-ExternalCommand -FilePath $KatanaPath -Arguments $arguments -TimeoutSeconds ([Math]::Max($TimeoutSeconds * 10, 90)) -StdOutPath $stdoutFile -StdErrPath $stderrFile -IgnoreExitCode
            if ($result.ExitCode -ne 0) { Add-ErrorRecord -Phase 'Crawl' -Target $definition.SeedUrl -Message 'katana returned a non-zero exit code.' -Details $result.StdErr }
            $rawLines = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Encoding utf8 } else { @() }
            if ($rawLines.Count -gt 0) {
                Add-Content -LiteralPath $RawOutputPath -Value ($rawLines -join [Environment]::NewLine) -Encoding utf8
                Add-Content -LiteralPath $RawOutputPath -Value [Environment]::NewLine -Encoding utf8
            }

            foreach ($line in $rawLines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $raw = $line | ConvertFrom-Json -Depth 100 } catch { Add-ErrorRecord -Phase 'Crawl' -Target $definition.SeedUrl -Message 'Failed to parse katana JSON line.' -Details $line; continue }
                $url = [string](Get-ObjectValue -InputObject $raw -Names @('url', 'endpoint', 'request.endpoint'))
                if ([string]::IsNullOrWhiteSpace($url)) { continue }
                $uri = $null
                if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { continue }
                $resolvedHost = $uri.DnsSafeHost.ToLowerInvariant()
                $path = if ($uri.AbsolutePath) { $uri.AbsolutePath } else { '/' }
                if (-not (Test-ScopeMatch -ScopeItem $scopeItem -Url $url -RespectSchemeOnly:$RespectSchemeOnly)) { continue }
                $exclusion = Test-ExclusionMatch -ScopeItem $scopeItem -TargetHost $resolvedHost -Url $url -Path $path
                if ($exclusion.IsExcluded) { Add-ExclusionRecord -Phase 'Crawl' -ScopeItem $scopeItem -Target $url -ExclusionResult $exclusion; continue }
                $key = Get-CanonicalUrlKey -Url $url
                if ($seenUrls.Contains($key)) { continue }
                $null = $seenUrls.Add($key)
                $results.Add([pscustomobject]@{ Url = $url; Host = $resolvedHost; Scheme = $uri.Scheme.ToLowerInvariant(); Path = $path; Query = $uri.Query; ScopeId = $scopeItem.Id; ScopeType = $scopeItem.Type; ScopeValue = $scopeItem.NormalizedValue; SeedUrl = $definition.SeedUrl; Source = 'katana'; StatusCode = [int](Get-ObjectValue -InputObject $raw -Names @('status_code', 'status-code', 'response.status_code') -Default 0); ContentType = [string](Get-ObjectValue -InputObject $raw -Names @('content_type', 'content-type', 'response.headers.content-type') -Default '') })
            }
        } catch {
            Add-ErrorRecord -Phase 'Crawl' -Target $definition.SeedUrl -Message $_.Exception.Message
        } finally {
            Remove-Item -LiteralPath $stdoutFile, $stderrFile, $inscopeFile, $outscopeFile -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($liveTarget in $LiveTargets) {
        $key = Get-CanonicalUrlKey -Url $liveTarget.Url
        if ($seenUrls.Contains($key)) { continue }
        $null = $seenUrls.Add($key)
        $results.Add([pscustomobject]@{ Url = $liveTarget.Url; Host = $liveTarget.Host; Scheme = $liveTarget.Scheme; Path = $liveTarget.Path; Query = ''; ScopeId = ($liveTarget.MatchedScopeIds -join ';'); ScopeType = ($liveTarget.MatchedTypes -join ';'); ScopeValue = 'live-target'; SeedUrl = $liveTarget.Url; Source = 'seed'; StatusCode = $liveTarget.StatusCode; ContentType = '' })
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

    $statusCounts = $LiveTargets | Group-Object -Property StatusCode | Sort-Object -Property Name | ForEach-Object { [pscustomobject]@{ StatusCode = $_.Name; Count = $_.Count } }
    $technologyCounts = $LiveTargets | ForEach-Object { $_.Technologies } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Technology = $_.Name; Count = $_.Count } }
    $subdomainCounts = $HostsAll | Group-Object -Property Host | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Host = $_.Name; Count = $_.Count } }
    $interestingCategoryCounts = $InterestingUrls | ForEach-Object { $_.Categories } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Category = $_.Name; Count = $_.Count } }
    $interestingFamilyCounts = $InterestingUrls | Group-Object -Property PrimaryFamily | Where-Object { $_.Name } | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name | Select-Object -First 10 | ForEach-Object {
        [pscustomobject]@{
            Family    = $_.Name
            Count     = $_.Count
            MaxScore  = ($_.Group | Measure-Object -Property Score -Maximum).Maximum
            TopUrl    = ($_.Group | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, Url | Select-Object -First 1 -ExpandProperty Url)
        }
    }
    $interestingPriorityCounts = $InterestingUrls | Group-Object -Property Priority | Where-Object { $_.Name } | Sort-Object -Property @{ Expression = { switch ($_.Name) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } default { 3 } } } }, Name | ForEach-Object {
        [pscustomobject]@{
            Priority = $_.Name
            Count    = $_.Count
        }
    }

    [pscustomobject]@{
        ProgramName            = $ProgramName
        GeneratedAtUtc         = [DateTime]::UtcNow.ToString('o')
        PowerShellVersion      = $PSVersionTable.PSVersion.ToString()
        ScopeItemCount         = $ScopeItems.Count
        ExcludedItemCount      = $Exclusions.Count
        DiscoveredHostCount    = ($HostsAll | Select-Object -ExpandProperty Host -Unique).Count
        LiveHostCount          = ($LiveTargets | Select-Object -ExpandProperty Host -Unique).Count
        LiveTargetCount        = $LiveTargets.Count
        DiscoveredUrlCount     = $DiscoveredUrls.Count
        InterestingUrlCount    = $InterestingUrls.Count
        ErrorCount             = $Errors.Count
        ProtectedInterestingCount = @($InterestingUrls | Where-Object { $_.Categories -contains 'Protected' }).Count
        UniqueUserAgent        = $UniqueUserAgent
        StatusCodeDistribution = $statusCounts
        TopTechnologies        = $technologyCounts
        TopSubdomains          = $subdomainCounts
        TopInterestingCategories = $interestingCategoryCounts
        TopInterestingFamilies = $interestingFamilyCounts
        InterestingPriorityDistribution = $interestingPriorityCounts
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

    $liveIndex = @{}
    foreach ($liveTarget in $LiveTargets) { $liveIndex[(Get-CanonicalUrlKey -Url $liveTarget.Url)] = $liveTarget }

    $patterns = @(
        @{ Category = 'Auth'; Family = 'Access'; Score = 3; Reason = 'Authentication surface'; Pattern = '(?i)(^|[/?#._-])(login|signin|sign-in|auth|oauth|sso|register|signup|session|mfa)([/?#._-]|$)' },
        @{ Category = 'Admin'; Family = 'Administrative'; Score = 4; Reason = 'Administrative surface'; Pattern = '(?i)(^|[/?#._-])(admin|dashboard|manage|console|panel|backoffice|staff|portal)([/?#._-]|$)' },
        @{ Category = 'API'; Family = 'API'; Score = 4; Reason = 'API or schema surface'; Pattern = '(?i)(swagger|openapi|redoc|graphql|graphiql|api-docs|/api/|/v[0-9]+/)' },
        @{ Category = 'Files'; Family = 'Files'; Score = 3; Reason = 'File handling surface'; Pattern = '(?i)(upload|import|export|download|attachment|avatar|media|document|file)' },
        @{ Category = 'Infra'; Family = 'Operations'; Score = 3; Reason = 'Operational surface'; Pattern = '(?i)(status|health|metrics|actuator|prometheus|ready|live|heartbeat)' },
        @{ Category = 'Debug'; Family = 'Operations'; Score = 4; Reason = 'Debug or verbose endpoint'; Pattern = '(?i)(debug|trace|stack|exception|error|dump|logs?)' },
        @{ Category = 'Config'; Family = 'Operations'; Score = 4; Reason = 'Configuration or backup artifact'; Pattern = '(?i)(config|env|backup|bak|old|zip|tar|yaml|yml|json|xml)' },
        @{ Category = 'Discovery'; Family = 'Discovery'; Score = 2; Reason = 'Discovery helper'; Pattern = '(?i)(robots\.txt|sitemap\.xml|security\.txt|humans\.txt)' },
        @{ Category = 'Redirect'; Family = 'Access'; Score = 2; Reason = 'Callback or redirect workflow'; Pattern = '(?i)(callback|redirect|return|continue|next=|url=)' }
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in $DiscoveredUrls) {
        $url = [string]$entry.Url
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $key = Get-CanonicalUrlKey -Url $url
        if ($seen.Contains($key)) { continue }
        $null = $seen.Add($key)

        $score = 0
        $reasons = [System.Collections.Generic.List[string]]::new()
        $categories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $familyScores = @{}
        foreach ($pattern in $patterns) {
            if ($url -match $pattern.Pattern) {
                $score += [int]$pattern.Score
                $reasons.Add($pattern.Reason) | Out-Null
                $categories.Add($pattern.Category) | Out-Null
                if (-not $familyScores.ContainsKey($pattern.Family)) { $familyScores[$pattern.Family] = 0 }
                $familyScores[$pattern.Family] += [int]$pattern.Score
            }
        }

        $statusCode = [int]$entry.StatusCode
        if ($statusCode -in 401, 403) {
            $score += 2
            $reasons.Add('Access-controlled endpoint') | Out-Null
            $categories.Add('Protected') | Out-Null
            if (-not $familyScores.ContainsKey('Access')) { $familyScores['Access'] = 0 }
            $familyScores['Access'] += 2
        }

        $liveMatch = $liveIndex[$key]
        if ($liveMatch) {
            if ($liveMatch.Technologies -and $liveMatch.Technologies.Count -gt 0) {
                $score += 1
                $categories.Add('Live') | Out-Null
            }
            if ($liveMatch.Title -and $liveMatch.Title -match '(?i)(admin|login|dashboard|swagger|graphql|portal)') {
                $score += 2
                $reasons.Add('Interesting page title') | Out-Null
                if ($liveMatch.Title -match '(?i)(admin|dashboard|portal)') {
                    if (-not $familyScores.ContainsKey('Administrative')) { $familyScores['Administrative'] = 0 }
                    $familyScores['Administrative'] += 2
                } elseif ($liveMatch.Title -match '(?i)(login|auth)') {
                    if (-not $familyScores.ContainsKey('Access')) { $familyScores['Access'] = 0 }
                    $familyScores['Access'] += 2
                } elseif ($liveMatch.Title -match '(?i)(swagger|graphql|api)') {
                    if (-not $familyScores.ContainsKey('API')) { $familyScores['API'] = 0 }
                    $familyScores['API'] += 2
                }
            }
        }

        if ($score -le 0) { continue }

        $primaryFamily = if ($familyScores.Count -gt 0) {
            ($familyScores.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } | Select-Object -First 1 -ExpandProperty Key)
        } elseif ($categories.Count -gt 0) {
            @($categories | Sort-Object)[0]
        } else {
            'General'
        }

        $priority = switch ($score) {
            { $_ -ge 10 } { 'Critical'; break }
            { $_ -ge 7 } { 'High'; break }
            { $_ -ge 4 } { 'Medium'; break }
            default { 'Low' }
        }

        $results.Add([pscustomobject]@{
                Url          = $url
                Host         = $entry.Host
                StatusCode   = $statusCode
                Score        = $score
                Priority     = $priority
                PriorityRank = switch ($priority) { 'Critical' { 0 } 'High' { 1 } 'Medium' { 2 } default { 3 } }
                PrimaryFamily = $primaryFamily
                Categories   = @($categories | Sort-Object)
                Reasons      = @($reasons | Select-Object -Unique)
                ScopeId      = $entry.ScopeId
                Source       = $entry.Source
                Title        = if ($liveMatch) { $liveMatch.Title } else { '' }
                Technologies = if ($liveMatch) { $liveMatch.Technologies } else { @() }
            })
    }

    return @($results | Sort-Object -Property PriorityRank, @{ Expression = 'Score'; Descending = $true }, Url)
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

function Export-TriageMarkdownReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Summary,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingFamilies,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
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
        foreach ($item in ($InterestingUrls | Select-Object -First 25)) {
            $lines.Add(("### [{0}/{1}] {2}" -f $item.Priority, $item.Score, $item.Url)) | Out-Null
            $lines.Add(("- Host: {0}" -f $item.Host)) | Out-Null
            $lines.Add(("- Status: {0}" -f $item.StatusCode)) | Out-Null
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

    $lines.Add('## Suggested Manual Review') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('- Review auth, admin, API documentation, file upload, and debug surfaces first.') | Out-Null
    $lines.Add('- Compare interesting URLs against program policy before deeper manual testing.') | Out-Null
    $lines.Add('- Re-check exclusions if noisy environments such as staging or sandbox are still visible.') | Out-Null
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

    $interestingFamilies = Get-InterestingFamilySummary -InterestingUrls $InterestingUrls
    if ($null -eq $interestingFamilies) { $interestingFamilies = @() }
    Write-JsonFile -Path $Layout.InterestingUrlsJson -Data $InterestingUrls
    Write-JsonFile -Path $Layout.InterestingFamiliesJson -Data $interestingFamilies
    Export-TriageMarkdownReport -Summary $Summary -InterestingUrls $InterestingUrls -InterestingFamilies $interestingFamilies -LiveTargets $LiveTargets -Layout $Layout

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

    $scopeRows = ($ScopeItems | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Type) $(ConvertTo-HtmlSafe $_.NormalizedValue) $(ConvertTo-HtmlSafe ($_.Exclusions -join ' '))""><td>$(ConvertTo-HtmlSafe $_.Id)</td><td>$(ConvertTo-HtmlSafe $_.Type)</td><td>$(ConvertTo-HtmlSafe $_.NormalizedValue)</td><td>$(ConvertTo-HtmlSafe ($_.Exclusions -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $excludedRows = ($Exclusions | Select-Object -First 500 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.ScopeId) $(ConvertTo-HtmlSafe $_.Target) $(ConvertTo-HtmlSafe $_.Token)""><td>$(ConvertTo-HtmlSafe $_.Phase)</td><td>$(ConvertTo-HtmlSafe $_.ScopeId)</td><td>$(ConvertTo-HtmlSafe $_.Target)</td><td>$(ConvertTo-HtmlSafe $_.Token)</td><td>$(ConvertTo-HtmlSafe $_.MatchedOn)</td></tr>" }) -join [Environment]::NewLine
    $liveRows = ($LiveTargets | Select-Object -First 1000 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) $(ConvertTo-HtmlSafe ($_.Technologies -join ' '))""><td>$(ConvertTo-HtmlSafe $_.Host)</td><td><a href=""$(ConvertTo-HtmlSafe $_.Url)"" target=""_blank"" rel=""noreferrer"">$(ConvertTo-HtmlSafe $_.Url)</a></td><td>$(ConvertTo-HtmlSafe $_.StatusCode)</td><td>$(ConvertTo-HtmlSafe $_.Title)</td><td>$(ConvertTo-HtmlSafe ($_.Technologies -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $urlRows = ($DiscoveredUrls | Select-Object -First 2000 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) $(ConvertTo-HtmlSafe $_.ScopeId)""><td>$(ConvertTo-HtmlSafe $_.Host)</td><td><a href=""$(ConvertTo-HtmlSafe $_.Url)"" target=""_blank"" rel=""noreferrer"">$(ConvertTo-HtmlSafe $_.Url)</a></td><td>$(ConvertTo-HtmlSafe $_.ScopeId)</td><td>$(ConvertTo-HtmlSafe $_.StatusCode)</td><td>$(ConvertTo-HtmlSafe $_.Source)</td></tr>" }) -join [Environment]::NewLine
    $interestingRows = ($InterestingUrls | Select-Object -First 250 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) $(ConvertTo-HtmlSafe $_.PrimaryFamily) $(ConvertTo-HtmlSafe $_.Priority) $(ConvertTo-HtmlSafe ($_.Categories -join ' '))""><td>$(ConvertTo-HtmlSafe $_.Priority)</td><td>$(ConvertTo-HtmlSafe $_.Score)</td><td>$(ConvertTo-HtmlSafe $_.PrimaryFamily)</td><td><a href=""$(ConvertTo-HtmlSafe $_.Url)"" target=""_blank"" rel=""noreferrer"">$(ConvertTo-HtmlSafe $_.Url)</a></td><td>$(ConvertTo-HtmlSafe ($_.Categories -join ', '))</td><td>$(ConvertTo-HtmlSafe ($_.Reasons -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $protectedRows = ($LiveTargets | Where-Object { $_.StatusCode -in 401, 403 } | Select-Object -First 250 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Host) $(ConvertTo-HtmlSafe $_.Url) protected""><td>$(ConvertTo-HtmlSafe $_.StatusCode)</td><td><a href=""$(ConvertTo-HtmlSafe $_.Url)"" target=""_blank"" rel=""noreferrer"">$(ConvertTo-HtmlSafe $_.Url)</a></td><td>$(ConvertTo-HtmlSafe $_.Title)</td><td>$(ConvertTo-HtmlSafe ($_.Technologies -join ', '))</td></tr>" }) -join [Environment]::NewLine
    $errorRows = ($Errors | Select-Object -First 500 | ForEach-Object { "<tr data-search=""$(ConvertTo-HtmlSafe $_.Phase) $(ConvertTo-HtmlSafe $_.Target) $(ConvertTo-HtmlSafe $_.Message)""><td>$(ConvertTo-HtmlSafe $_.Phase)</td><td>$(ConvertTo-HtmlSafe $_.Target)</td><td>$(ConvertTo-HtmlSafe $_.Message)</td><td>$(ConvertTo-HtmlSafe $_.Details)</td></tr>" }) -join [Environment]::NewLine
    $statusBars = ($Summary.StatusCodeDistribution | ForEach-Object { "<div class=""mini-row""><span>HTTP $(ConvertTo-HtmlSafe $_.StatusCode)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $technologyBars = ($Summary.TopTechnologies | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Technology)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $subdomainBars = ($Summary.TopSubdomains | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Host)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $interestingBars = ($Summary.TopInterestingCategories | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Category)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $familyBars = ($Summary.TopInterestingFamilies | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Family)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
    $priorityBars = ($Summary.InterestingPriorityDistribution | ForEach-Object { "<div class=""mini-row""><span>$(ConvertTo-HtmlSafe $_.Priority)</span><strong>$(ConvertTo-HtmlSafe $_.Count)</strong></div>" }) -join [Environment]::NewLine
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
    $errorRows = Get-HtmlTableBodyOrEmpty -Rows $errorRows -ColumnCount 4 -Message 'No non-fatal errors were captured for this run.'
    $familyRows = Get-HtmlTableBodyOrEmpty -Rows $familyRows -ColumnCount 6 -Message 'No interesting families were generated for this run.'
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

            "<section><h2>Spotlight: $(ConvertTo-HtmlSafe $familyName)</h2>$categoryRows</section>"
        }
    ) -join [Environment]::NewLine

    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>ScopeForge Report - $(ConvertTo-HtmlSafe $Summary.ProgramName)</title><style>
:root{--bg:#0a1016;--panel:#111c25;--panel2:#162633;--text:#edf4f8;--muted:#9eb4c2;--accent:#51d0b1;--border:rgba(255,255,255,.08);--shadow:0 24px 80px rgba(0,0,0,.35)}*{box-sizing:border-box}body{margin:0;font-family:"Segoe UI","Helvetica Neue",sans-serif;background:radial-gradient(circle at top right,rgba(81,208,177,.15),transparent 28%),radial-gradient(circle at top left,rgba(109,184,255,.12),transparent 22%),linear-gradient(180deg,#091018 0%,#0b141b 100%);color:var(--text)}.wrap{max-width:1500px;margin:0 auto;padding:32px 20px 60px}.hero,section,.card{background:rgba(17,28,37,.9);border:1px solid var(--border);box-shadow:var(--shadow)}.hero{padding:24px;border-radius:22px;margin-bottom:24px}.hero h1{margin:0 0 8px;font-size:30px}.hero p,.hint,.mini-row,.label,th{color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin:24px 0}.card{padding:18px;border-radius:18px}.value{margin-top:10px;font-size:28px;font-weight:700}.two-col{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;margin-bottom:24px}.mini-row{display:flex;justify-content:space-between;gap:16px;padding:10px 0;border-bottom:1px solid var(--border)}.mini-row strong{color:var(--text)}.search{width:100%;margin:0 0 16px;padding:14px 16px;border:1px solid var(--border);border-radius:14px;background:rgba(10,16,22,.8);color:var(--text)}section{margin-bottom:24px;padding:18px;border-radius:18px}table{width:100%;border-collapse:collapse}th,td{padding:10px 12px;text-align:left;border-bottom:1px solid var(--border);vertical-align:top;font-size:14px}td.empty-state{text-align:center;font-style:italic;color:var(--muted)}th{font-size:11px;text-transform:uppercase;letter-spacing:.08em}a{color:#6db8ff;text-decoration:none}@media(max-width:720px){.wrap{padding:20px 12px 40px}.hero h1{font-size:24px}}</style></head>
<body><div class="wrap"><div class="hero"><h1>ScopeForge Recon Report</h1><p>Program: $(ConvertTo-HtmlSafe $Summary.ProgramName) | Generated: $(ConvertTo-HtmlSafe $Summary.GeneratedAtUtc) | PowerShell $(ConvertTo-HtmlSafe $Summary.PowerShellVersion)</p></div>
<div class="grid"><div class="card"><div class="label">Scope Items</div><div class="value">$(ConvertTo-HtmlSafe $Summary.ScopeItemCount)</div></div><div class="card"><div class="label">Excluded</div><div class="value">$(ConvertTo-HtmlSafe $Summary.ExcludedItemCount)</div></div><div class="card"><div class="label">Hosts Found</div><div class="value">$(ConvertTo-HtmlSafe $Summary.DiscoveredHostCount)</div></div><div class="card"><div class="label">Live Hosts</div><div class="value">$(ConvertTo-HtmlSafe $Summary.LiveHostCount)</div></div><div class="card"><div class="label">Live Targets</div><div class="value">$(ConvertTo-HtmlSafe $Summary.LiveTargetCount)</div></div><div class="card"><div class="label">URLs Found</div><div class="value">$(ConvertTo-HtmlSafe $Summary.DiscoveredUrlCount)</div></div><div class="card"><div class="label">Interesting</div><div class="value">$(ConvertTo-HtmlSafe $Summary.InterestingUrlCount)</div></div></div>
<div class="two-col"><section><h2>HTTP Codes</h2>$statusBars</section><section><h2>Top Technologies</h2>$technologyBars</section><section><h2>Top Subdomains</h2>$subdomainBars</section><section><h2>Interesting Families</h2>$familyBars</section><section><h2>Interesting Priorities</h2>$priorityBars</section><section><h2>Interesting Categories</h2>$interestingBars</section></div>
<div class="two-col">$spotlightSections</div>
<input id="globalSearch" class="search" type="search" placeholder="Filter all tables..." />
<section><h2>In Scope</h2><p class="hint">Normalized scope after validation and wildcard parsing.</p><table data-filter-table="true"><thead><tr><th>ID</th><th>Type</th><th>Value</th><th>Exclusions</th></tr></thead><tbody>$scopeRows</tbody></table></section>
<section><h2>Excluded</h2><p class="hint">Assets removed because they matched exclusion strings before probe or after crawl filtering.</p><table data-filter-table="true"><thead><tr><th>Phase</th><th>Scope</th><th>Target</th><th>Token</th><th>Matched On</th></tr></thead><tbody>$excludedRows</tbody></table></section>
<section><h2>Live Hosts</h2><p class="hint">Reachable HTTP(S) targets retained after in-scope validation.</p><table data-filter-table="true"><thead><tr><th>Host</th><th>URL</th><th>Status</th><th>Title</th><th>Technologies</th></tr></thead><tbody>$liveRows</tbody></table></section>
<section><h2>Interesting Families</h2><p class="hint">Primary families used to group triage targets for manual review.</p><table data-filter-table="true"><thead><tr><th>Family</th><th>Count</th><th>Max Score</th><th>Priorities</th><th>Top Categories</th><th>Sample URLs</th></tr></thead><tbody>$familyRows</tbody></table></section>
<section><h2>Protected Endpoints</h2><p class="hint">Live endpoints returning 401 or 403, often useful for manual access-control triage.</p><table data-filter-table="true"><thead><tr><th>Status</th><th>URL</th><th>Title</th><th>Technologies</th></tr></thead><tbody>$protectedRows</tbody></table></section>
<section><h2>Interesting Pages</h2><p class="hint">Heuristically ranked URLs grouped by family and priority to accelerate manual bug bounty review.</p><table data-filter-table="true"><thead><tr><th>Priority</th><th>Score</th><th>Family</th><th>URL</th><th>Categories</th><th>Reasons</th></tr></thead><tbody>$interestingRows</tbody></table></section>
<section><h2>Discovered URLs</h2><p class="hint">Unique endpoints collected from katana and seed URLs.</p><table data-filter-table="true"><thead><tr><th>Host</th><th>URL</th><th>Scope</th><th>Status</th><th>Source</th></tr></thead><tbody>$urlRows</tbody></table></section>
<section><h2>Errors</h2><p class="hint">Non-fatal errors captured during execution.</p><table data-filter-table="true"><thead><tr><th>Phase</th><th>Target</th><th>Message</th><th>Details</th></tr></thead><tbody>$errorRows</tbody></table></section></div>
<script>const input=document.getElementById('globalSearch');const tables=Array.from(document.querySelectorAll('[data-filter-table="true"]'));function applyFilter(){const query=input.value.trim().toLowerCase();tables.forEach(table=>{table.querySelectorAll('tbody tr').forEach(row=>{const haystack=(row.dataset.search||row.textContent||'').toLowerCase();row.style.display=!query||haystack.includes(query)?'':'none';});});}input.addEventListener('input',applyFilter);</script></body></html>
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
    $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName $ProgramName -Quiet:[bool]$Quiet -ExportJsonEnabled:$exportJsonEnabled -ExportCsvEnabled:$exportCsvEnabled -ExportHtmlEnabled:$exportHtmlEnabled

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
                        $record = Get-OrCreateHostInventoryRecord -HostMap $hostMap -Host $targetHost
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
                        $record = Get-OrCreateHostInventoryRecord -HostMap $hostMap -Host $targetHost
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
                            $record = Get-OrCreateHostInventoryRecord -HostMap $hostMap -Host $candidateHost
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

            $hostsAll = $hostMap.Keys | Sort-Object | ForEach-Object {
                $record = $hostMap[$_]
                [pscustomobject]@{ Host = $_; Discovery = @($record.Discovery | Sort-Object); SourceScopeIds = @($record.SourceScopeIds | Sort-Object); SourceTypes = @($record.SourceTypes | Sort-Object); CandidateUrls = @($record.CandidateUrls | Sort-Object); RootDomains = @($record.RootDomains | Sort-Object) }
            }
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
            $liveTargets = Invoke-HttpProbe -InputUrls $probeInputs -ScopeItems $scopeItems -HttpxPath $tools.Httpx.Path -RawOutputPath $layout.HttpxRaw -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -RespectSchemeOnly:$RespectSchemeOnly
            Write-JsonFile -Path $layout.LiveTargetsJson -Data $liveTargets
        }
        if ($exportCsvEnabled) { Export-FlatCsv -Path $layout.LiveTargetsCsv -Rows $liveTargets }

        $hostsLive = $liveTargets | Group-Object -Property Host | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{
                Host         = $_.Name
                Urls         = @($_.Group | Select-Object -ExpandProperty Url -Unique)
                StatusCodes  = @($_.Group | Select-Object -ExpandProperty StatusCode -Unique)
                Technologies = @($_.Group | ForEach-Object { $_.Technologies } | Where-Object { $_ } | Select-Object -Unique)
                ScopeIds     = @($_.Group | ForEach-Object { $_.MatchedScopeIds } | Select-Object -Unique)
            }
        }
        Write-JsonFile -Path $layout.HostsLiveJson -Data $hostsLive

        if ($useResume -and (Test-Path -LiteralPath $layout.UrlsDiscoveredJson)) {
            Write-StageBanner -Step 5 -Title 'Crawl'
            Write-ReconLog -Level INFO -Message 'Resume: loading cached discovered URLs.'
            $discoveredUrls = @(Get-Content -LiteralPath $layout.UrlsDiscoveredJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
        } else {
            Write-StageBanner -Step 5 -Title 'Crawl'
            $discoveredUrls = Invoke-KatanaCrawl -LiveTargets $liveTargets -ScopeItems $scopeItems -KatanaPath $tools.Katana.Path -RawOutputPath $layout.KatanaRaw -TempDirectory $layout.Temp -Depth $Depth -Threads $Threads -TimeoutSeconds $TimeoutSeconds -UniqueUserAgent $UniqueUserAgent -RespectSchemeOnly:$RespectSchemeOnly
            if ($tools.Hakrawler) {
                Write-ReconLog -Level INFO -Message 'Running hakrawler as a supplemental strictly in-scope crawl pass.'
                $hakrawlerUrls = Invoke-HakrawlerCrawl -LiveTargets $liveTargets -ScopeItems $scopeItems -HakrawlerPath $tools.Hakrawler.Path -RawOutputPath $layout.HakrawlerRaw -TempDirectory $layout.Temp -Depth ([Math]::Max([Math]::Min($Depth, 3), 1)) -TimeoutSeconds $TimeoutSeconds -RespectSchemeOnly:$RespectSchemeOnly
                $discoveredUrls = Merge-DiscoveredUrlResults -Inputs @($discoveredUrls + $hakrawlerUrls)
            } else {
                $discoveredUrls = Merge-DiscoveredUrlResults -Inputs $discoveredUrls
            }
            Write-JsonFile -Path $layout.UrlsDiscoveredJson -Data $discoveredUrls
        }
        Set-Content -LiteralPath $layout.EndpointsUniqueTxt -Value ($discoveredUrls | Select-Object -ExpandProperty Url -Unique) -Encoding utf8
        if ($exportCsvEnabled) { Export-FlatCsv -Path $layout.UrlsDiscoveredCsv -Rows $discoveredUrls }

        Write-StageBanner -Step 6 -Title 'Génération des rapports'
        $interestingUrls = Get-InterestingReconFindings -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls
        $summary = Merge-ReconResults -ScopeItems $scopeItems -HostsAll $hostsAll -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -InterestingUrls $interestingUrls -Exclusions @($script:ScopeForgeContext.Exclusions) -Errors @($script:ScopeForgeContext.Errors) -ProgramName $ProgramName -UniqueUserAgent $UniqueUserAgent
        Export-ReconReport -Summary $summary -ScopeItems $scopeItems -HostsAll $hostsAll -HostsLive $hostsLive -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -InterestingUrls $interestingUrls -Exclusions @($script:ScopeForgeContext.Exclusions) -Errors @($script:ScopeForgeContext.Errors) -Layout $layout -ExportJson:$exportJsonEnabled -ExportCsv:$exportCsvEnabled -ExportHtml:$exportHtmlEnabled
        Write-StageProgress -Step 6 -Title 'Génération des rapports' -Percent 100 -Status 'Reports completed'

        $result = [pscustomobject]@{ ProgramName = $ProgramName; OutputDir = $layout.Root; ScopeItems = $scopeItems; HostsAll = $hostsAll; HostsLive = $hostsLive; LiveTargets = $liveTargets; DiscoveredUrls = $discoveredUrls; InterestingUrls = $interestingUrls; Summary = $summary; Exclusions = @($script:ScopeForgeContext.Exclusions); Errors = @($script:ScopeForgeContext.Errors); ExportHtmlEnabled = $exportHtmlEnabled; ExportCsvEnabled = $exportCsvEnabled; ExportJsonEnabled = $exportJsonEnabled }
        if (-not $Quiet) {
            Write-Host ''
            Write-Host 'Recon summary' -ForegroundColor Green
            Write-Host ('  Scope items      : {0}' -f $summary.ScopeItemCount) -ForegroundColor Gray
            Write-Host ('  Excluded assets  : {0}' -f $summary.ExcludedItemCount) -ForegroundColor Gray
            Write-Host ('  Hosts discovered : {0}' -f $summary.DiscoveredHostCount) -ForegroundColor Gray
            Write-Host ('  Live hosts       : {0}' -f $summary.LiveHostCount) -ForegroundColor Gray
            Write-Host ('  Live targets     : {0}' -f $summary.LiveTargetCount) -ForegroundColor Gray
            Write-Host ('  URLs discovered  : {0}' -f $summary.DiscoveredUrlCount) -ForegroundColor Gray
            Write-Host ('  Interesting URLs : {0}' -f $summary.InterestingUrlCount) -ForegroundColor Gray
            Write-Host ('  Errors           : {0}' -f $summary.ErrorCount) -ForegroundColor Gray
            Write-Host ('  Output           : {0}' -f $layout.Root) -ForegroundColor Gray
            if ($interestingUrls.Count -gt 0) {
                Write-Host ''
                Write-Host 'Top interesting pages' -ForegroundColor Yellow
                foreach ($item in ($interestingUrls | Select-Object -First 10)) {
                    Write-Host ('  [{0}] {1}' -f $item.Score, $item.Url) -ForegroundColor DarkYellow
                }
            }
        }
        return $result
    } catch {
        Add-ErrorRecord -Phase 'Runtime' -Message $_.Exception.Message -Details $_.ScriptStackTrace
        throw
    } finally {
        if ($script:ScopeForgeContext -and -not $script:ScopeForgeContext.Quiet) { Write-Progress -Id 1 -Activity 'ScopeForge' -Completed }
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
