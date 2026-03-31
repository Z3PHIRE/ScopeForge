function Get-ScopeForgeAnalysisPathDictionary {
    [CmdletBinding()]
    param(
        [ValidateSet('webapp','api','auth','balanced')]
        [string]$TargetProfile = 'balanced'
    )

    $common = @(
        '/',
        '/robots.txt',
        '/security.txt',
        '/.well-known/security.txt',
        '/sitemap.xml',
        '/favicon.ico'
    )

    $webapp = @(
        '/login', '/signin', '/sign-in', '/signup', '/register', '/session', '/logout',
        '/admin', '/dashboard', '/manage', '/portal', '/console', '/settings', '/profile',
        '/upload', '/uploads', '/download', '/export', '/import', '/documents', '/files'
    )

    $api = @(
        '/api', '/api/', '/api/v1', '/api/v2', '/v1', '/v2',
        '/swagger', '/swagger/index.html', '/swagger-ui', '/swagger-ui/index.html',
        '/openapi.json', '/openapi.yaml', '/api-docs', '/redoc',
        '/graphql', '/graphiql'
    )

    $ops = @(
        '/health', '/status', '/metrics', '/ready', '/live',
        '/actuator', '/actuator/health', '/actuator/metrics',
        '/debug', '/trace', '/version'
    )

    $auth = @(
        '/oauth', '/oauth/authorize', '/oauth/token', '/sso', '/scim', '/mfa', '/callback'
    )

    $paths = switch ($TargetProfile) {
        'webapp' { @($common + $webapp + $api + $ops) }
        'api'    { @($common + $api + $ops + $auth) }
        'auth'   { @($common + $auth + $webapp + $ops) }
        default  { @($common + $webapp + $api + $ops + $auth) }
    }

    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-ScopeForgeAnalysisSeedUrls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$HostsAll,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [int]$MaxHosts = 120,
        [int]$MaxHistoricalPerHost = 12
    )

    $urls = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($liveTarget in (ConvertTo-ArrayOrEmpty -Data $LiveTargets)) {
        $url = [string]$liveTarget.Url
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if ($seen.Add($url)) { $urls.Add($url) | Out-Null }
    }

    $selectedHosts = ConvertTo-ArrayOrEmpty -Data ($HostsAll | Select-Object -First $MaxHosts)
    foreach ($hostRecord in $selectedHosts) {
        $hostName = [string](Get-ObjectValue -InputObject $hostRecord -Names @('Host') -Default '')
        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }

        $candidateUrls = ConvertTo-ArrayOrEmpty -Data (Get-ObjectValue -InputObject $hostRecord -Names @('CandidateUrls') -Default @())
        $candidateCount = 0
        foreach ($candidateUrl in $candidateUrls) {
            $candidateUrlString = [string]$candidateUrl
            if ([string]::IsNullOrWhiteSpace($candidateUrlString)) { continue }
            if ($seen.Add($candidateUrlString)) {
                $urls.Add($candidateUrlString) | Out-Null
                $candidateCount++
            }
            if ($candidateCount -ge $MaxHistoricalPerHost) { break }
        }

        foreach ($fallbackScheme in @('https', 'http')) {
            $rootUrl = '{0}://{1}/' -f $fallbackScheme, $hostName
            if ($seen.Add($rootUrl)) { $urls.Add($rootUrl) | Out-Null }
        }
    }

    return @($urls | Sort-Object -Unique)
}

function Get-ScopeForgeAnalysisProbeCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$SeedUrls,
        [Parameter(Mandatory)][string[]]$DictionaryPaths,
        [int]$MaxProbeCandidates = 4000
    )

    $results = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $baseUrls = [System.Collections.Generic.List[string]]::new()

    foreach ($seedUrl in $SeedUrls) {
        $seedUrlString = [string]$seedUrl
        if ([string]::IsNullOrWhiteSpace($seedUrlString)) { continue }
        if ($seen.Add($seedUrlString)) { $results.Add($seedUrlString) | Out-Null }

        $uri = $null
        if (-not [Uri]::TryCreate($seedUrlString, [UriKind]::Absolute, [ref]$uri)) { continue }
        $baseUrl = '{0}://{1}' -f $uri.Scheme.ToLowerInvariant(), $uri.Authority.ToLowerInvariant()
        $baseUrls.Add($baseUrl) | Out-Null
    }

    foreach ($baseUrl in ($baseUrls | Sort-Object -Unique)) {
        foreach ($path in $DictionaryPaths) {
            $normalizedPath = if ($path.StartsWith('/')) { $path } else { '/' + $path }
            $candidate = '{0}{1}' -f $baseUrl.TrimEnd('/'), $normalizedPath
            if ($seen.Add($candidate)) { $results.Add($candidate) | Out-Null }
            if ($results.Count -ge $MaxProbeCandidates) { break }
        }
        if ($results.Count -ge $MaxProbeCandidates) { break }
    }

    return @($results | Select-Object -First $MaxProbeCandidates)
}

function Merge-ScopeForgeLiveTargets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Items)

    $results = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in (ConvertTo-ArrayOrEmpty -Data $Items)) {
        if ($null -eq $item) { continue }
        $url = [string](Get-ObjectValue -InputObject $item -Names @('Url') -Default '')
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $key = Get-CanonicalUrlKey -Url $url
        if (-not $seen.Add($key)) { continue }
        $results.Add($item) | Out-Null
    }

    return @($results | Sort-Object Url)
}

function Convert-ScopeForgeInterestingUrlsToFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$InterestingUrls)

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (ConvertTo-ArrayOrEmpty -Data $InterestingUrls)) {
        if ($null -eq $item) { continue }

        $priority = [string](Get-ObjectValue -InputObject $item -Names @('Priority') -Default 'Info')
        $family = [string](Get-ObjectValue -InputObject $item -Names @('PrimaryFamily') -Default 'General')
        $hostName = [string](Get-ObjectValue -InputObject $item -Names @('Host') -Default '')
        $urlValue = [string](Get-ObjectValue -InputObject $item -Names @('Url') -Default '')
        $sourceValue = [string](Get-ObjectValue -InputObject $item -Names @('Source') -Default 'analysis')
        $categories = ConvertTo-ArrayOrEmpty -Data (Get-ObjectValue -InputObject $item -Names @('Categories') -Default @())
        $reasons = ConvertTo-ArrayOrEmpty -Data (Get-ObjectValue -InputObject $item -Names @('Reasons') -Default @())

        $results.Add([pscustomobject]@{
            Severity          = $priority
            Confidence        = 'Observed'
            Priority          = $priority
            Category          = if ($categories.Count -gt 0) { ($categories -join ', ') } else { 'General' }
            Family            = if ([string]::IsNullOrWhiteSpace($family)) { 'General' } else { $family }
            Host              = $hostName
            Url               = $urlValue
            Evidence          = if ($reasons.Count -gt 0) { ($reasons -join ', ') } else { 'Interesting in-scope endpoint.' }
            RecommendedChecks = 'Review manually and validate exploitability.'
            Source            = $sourceValue
        }) | Out-Null
    }

    return @($results)
}

function Merge-ScopeForgeFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Items)

    $results = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in (ConvertTo-ArrayOrEmpty -Data $Items)) {
        if ($null -eq $item) { continue }

        $priority = [string](Get-ObjectValue -InputObject $item -Names @('Priority') -Default '')
        $category = [string](Get-ObjectValue -InputObject $item -Names @('Category') -Default '')
        $family = [string](Get-ObjectValue -InputObject $item -Names @('Family') -Default '')
        $hostName = [string](Get-ObjectValue -InputObject $item -Names @('Host') -Default '')
        $urlValue = [string](Get-ObjectValue -InputObject $item -Names @('Url') -Default '')
        $evidence = [string](Get-ObjectValue -InputObject $item -Names @('Evidence') -Default '')

        $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f $priority, $category, $family, $hostName, $urlValue, $evidence
        if (-not $seen.Add($key)) { continue }
        $results.Add($item) | Out-Null
    }

    return @($results)
}

function New-ScopeForgeAnalysisReviewQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Findings,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets
    )

    $priorityRank = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Info = 4 }

    $liveIndex = @{}
    foreach ($liveTarget in (ConvertTo-ArrayOrEmpty -Data $LiveTargets)) {
        $liveUrl = [string](Get-ObjectValue -InputObject $liveTarget -Names @('Url') -Default '')
        if ([string]::IsNullOrWhiteSpace($liveUrl)) { continue }
        $liveIndex[(Get-CanonicalUrlKey -Url $liveUrl)] = $liveTarget
    }

    $queue = foreach ($finding in (ConvertTo-ArrayOrEmpty -Data $Findings)) {
        $urlValue = [string](Get-ObjectValue -InputObject $finding -Names @('Url') -Default '')
        $liveMatch = if ([string]::IsNullOrWhiteSpace($urlValue)) { $null } else { $liveIndex[(Get-CanonicalUrlKey -Url $urlValue)] }

        [pscustomobject]@{
            Priority          = [string](Get-ObjectValue -InputObject $finding -Names @('Priority') -Default 'Info')
            Category          = [string](Get-ObjectValue -InputObject $finding -Names @('Category') -Default 'General')
            Family            = [string](Get-ObjectValue -InputObject $finding -Names @('Family') -Default 'General')
            Host              = [string](Get-ObjectValue -InputObject $finding -Names @('Host') -Default '')
            Url               = $urlValue
            StatusCode        = if ($liveMatch) { [int](Get-ObjectValue -InputObject $liveMatch -Names @('StatusCode') -Default 0) } else { 0 }
            Evidence          = [string](Get-ObjectValue -InputObject $finding -Names @('Evidence') -Default '')
            RecommendedChecks = [string](Get-ObjectValue -InputObject $finding -Names @('RecommendedChecks') -Default '')
            Source            = [string](Get-ObjectValue -InputObject $finding -Names @('Source') -Default '')
            SortRank          = if ($priorityRank.ContainsKey([string](Get-ObjectValue -InputObject $finding -Names @('Priority') -Default 'Info'))) { $priorityRank[[string](Get-ObjectValue -InputObject $finding -Names @('Priority') -Default 'Info')] } else { 4 }
        }
    }

    return @($queue | Sort-Object SortRank, Host, Url, Category | Select-Object Priority, Category, Family, Host, Url, StatusCode, Evidence, RecommendedChecks, Source)
}

function Invoke-ScopeForgeAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Layout,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$ScopeItems,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$HostsAll,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$LiveTargets,
        [Parameter(Mandatory)][string]$HttpxPath,
        [Parameter(Mandatory)][string]$KatanaPath,
        [string]$UniqueUserAgent,
        [ValidateSet('webapp','api','auth','balanced')]
        [string]$TargetProfile = 'balanced',
        [int]$Threads = 10,
        [int]$TimeoutSeconds = 30,
        [int]$Depth = 3,
        [int]$MaxHosts = 120,
        [int]$MaxProbeCandidates = 4000,
        [switch]$RespectSchemeOnly
    )

    $analysisCandidatesTxt = Join-Path $Layout.Normalized 'analysis_probe_candidates.txt'
    $analysisLiveJson = Join-Path $Layout.Normalized 'analysis_live_targets.json'
    $analysisLiveCsv = Join-Path $Layout.Normalized 'analysis_live_targets.csv'
    $analysisUrlsJson = Join-Path $Layout.Normalized 'analysis_urls_discovered.json'
    $analysisUrlsCsv = Join-Path $Layout.Normalized 'analysis_urls_discovered.csv'
    $analysisFindingsJson = Join-Path $Layout.Normalized 'analysis_findings.json'
    $analysisFindingsCsv = Join-Path $Layout.Normalized 'analysis_findings.csv'
    $analysisReviewJson = Join-Path $Layout.Reports 'analysis_review_queue.json'
    $analysisReviewCsv = Join-Path $Layout.Reports 'analysis_review_queue.csv'
    $analysisHttpxRaw = Join-Path $Layout.Raw 'analysis_httpx_raw.jsonl'
    $analysisKatanaRaw = Join-Path $Layout.Raw 'analysis_katana_raw.jsonl'

    $seedUrls = Get-ScopeForgeAnalysisSeedUrls -HostsAll $HostsAll -LiveTargets $LiveTargets -MaxHosts $MaxHosts
    $dictionaryPaths = Get-ScopeForgeAnalysisPathDictionary -TargetProfile $TargetProfile
    $probeCandidates = Get-ScopeForgeAnalysisProbeCandidates -SeedUrls $seedUrls -DictionaryPaths $dictionaryPaths -MaxProbeCandidates $MaxProbeCandidates

    Set-Content -LiteralPath $analysisCandidatesTxt -Value $probeCandidates -Encoding utf8
    Write-ReconLog -Level INFO -Message ("Analysis module: probing {0} curated candidate URL(s)." -f $probeCandidates.Count)

    $analysisLiveTargets = ConvertTo-ArrayOrEmpty -Data (
        Invoke-HttpProbe -InputUrls $probeCandidates -ScopeItems $ScopeItems -HttpxPath $HttpxPath -RawOutputPath $analysisHttpxRaw -UniqueUserAgent $UniqueUserAgent -Threads $Threads -TimeoutSeconds $TimeoutSeconds -RespectSchemeOnly:$RespectSchemeOnly
    )

    $analysisLiveTargets = Merge-ScopeForgeLiveTargets -Items @($analysisLiveTargets)
    Write-JsonFile -Path $analysisLiveJson -Data $analysisLiveTargets
    Export-FlatCsv -Path $analysisLiveCsv -Rows $analysisLiveTargets

    $analysisUrls = @()
    if ((Get-ScopeForgeItemCount -Data $analysisLiveTargets) -gt 0) {
        Write-ReconLog -Level INFO -Message ("Analysis module: crawling {0} validated analysis target(s) with katana." -f (Get-ScopeForgeItemCount -Data $analysisLiveTargets))
        $analysisUrls = ConvertTo-ArrayOrEmpty -Data (
            Invoke-KatanaCrawl -LiveTargets $analysisLiveTargets -ScopeItems $ScopeItems -KatanaPath $KatanaPath -RawOutputPath $analysisKatanaRaw -TempDirectory $Layout.Temp -Depth ([Math]::Max([Math]::Min($Depth + 1, 4), 2)) -Threads $Threads -TimeoutSeconds $TimeoutSeconds -UniqueUserAgent $UniqueUserAgent -RespectSchemeOnly:$RespectSchemeOnly
        )
    }

    $analysisUrls = Merge-DiscoveredUrlResults -Inputs $analysisUrls
    Write-JsonFile -Path $analysisUrlsJson -Data $analysisUrls
    Export-FlatCsv -Path $analysisUrlsCsv -Rows $analysisUrls

    $analysisInteresting = ConvertTo-ArrayOrEmpty -Data (
        Get-InterestingReconFindings -LiveTargets $analysisLiveTargets -DiscoveredUrls $analysisUrls
    )
    $analysisFindings = Merge-ScopeForgeFindings -Items (Convert-ScopeForgeInterestingUrlsToFindings -InterestingUrls $analysisInteresting)
    $reviewQueue = New-ScopeForgeAnalysisReviewQueue -Findings $analysisFindings -LiveTargets $analysisLiveTargets

    Write-JsonFile -Path $analysisFindingsJson -Data $analysisFindings
    Export-FlatCsv -Path $analysisFindingsCsv -Rows $analysisFindings
    Write-JsonFile -Path $analysisReviewJson -Data $reviewQueue
    Export-FlatCsv -Path $analysisReviewCsv -Rows $reviewQueue

    return [pscustomobject]@{
        ProbeCandidates = $probeCandidates
        LiveTargets     = $analysisLiveTargets
        DiscoveredUrls  = $analysisUrls
        InterestingUrls = $analysisInteresting
        Findings        = $analysisFindings
        ReviewQueue     = $reviewQueue
        Summary         = [pscustomobject]@{
            ProbeCandidateCount = (Get-ScopeForgeItemCount -Data $probeCandidates)
            LiveTargetCount     = (Get-ScopeForgeItemCount -Data $analysisLiveTargets)
            DiscoveredUrlCount  = (Get-ScopeForgeItemCount -Data $analysisUrls)
            FindingCount        = (Get-ScopeForgeItemCount -Data $analysisFindings)
        }
    }
}
