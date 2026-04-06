$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repoRoot 'ScopeForge.ps1')

Describe 'ScopeForge passive discovery runtime safety' {
    It 'builds probe candidates for a domain without composite-format crashes' {
        $scopeItem = [pscustomobject]@{
            Type = 'Domain'
            Host = 'example.com'
        }

        $urls = @(Get-ProbeCandidateUrls -ScopeItem $scopeItem)

        if ($urls.Count -ne 2) { throw 'Expected a domain scope item to yield two probe candidates.' }
        if ($urls -notcontains 'https://example.com') { throw 'Expected HTTPS candidate for a domain scope item.' }
        if ($urls -notcontains 'http://example.com') { throw 'Expected HTTP candidate for a domain scope item.' }
    }

    It 'builds probe candidates for a wildcard target host without composite-format crashes' {
        $scopeItem = [pscustomobject]@{
            Type   = 'Wildcard'
            Scheme = 'https'
        }

        $urls = @(Get-ProbeCandidateUrls -ScopeItem $scopeItem -TargetHost 'api.example.com')

        if ($urls.Count -ne 2) { throw 'Expected a wildcard scope item to yield both scheme candidates by default.' }
        if ($urls -notcontains 'https://api.example.com') { throw 'Expected the configured wildcard scheme to be preserved.' }
        if ($urls -notcontains 'http://api.example.com') { throw 'Expected the alternate wildcard scheme when RespectSchemeOnly is disabled.' }
    }

    It 'keeps URL probe candidates unchanged' {
        $scopeItem = [pscustomobject]@{
            Type     = 'URL'
            StartUrl = 'https://app.example.com/login?next=%2Fhome'
        }

        $urls = @(Get-ProbeCandidateUrls -ScopeItem $scopeItem)

        if ($urls.Count -ne 1) { throw 'Expected a URL scope item to keep a single seed URL.' }
        if ($urls[0] -ne 'https://app.example.com/login?next=%2Fhome') { throw 'Expected URL probe candidate generation to stay unchanged.' }
    }

    It 'runs a mixed scope beyond passive discovery even when hakrawler is unavailable' {
        $scopePath = Join-Path $TestDrive 'mixed-scope.json'
        $outputDir = Join-Path $TestDrive 'output'
        $script:capturedProbeInputs = @()
        @'
[
  { "type": "Domain", "value": "khealth.com", "exclusions": ["staging", "legacy"] },
  { "type": "Wildcard", "value": "https://*.khealth.io", "exclusions": ["internal", "sandbox"] },
  { "type": "URL", "value": "https://app.khealth.com/login?next=%2Fhome", "exclusions": ["logout", "beta"] }
]
'@ | Set-Content -LiteralPath $scopePath -Encoding utf8

        Mock Write-StageBanner {}
        Mock Write-StageProgress {}
        Mock Write-ReconLog {}
        Mock Ensure-ReconTools {
            [pscustomobject]@{
                Subfinder   = [pscustomobject]@{ Path = 'subfinder.exe' }
                Httpx       = [pscustomobject]@{ Path = 'httpx.exe' }
                Katana      = [pscustomobject]@{ Path = 'katana.exe' }
                Gau         = [pscustomobject]@{ Path = 'gau.exe' }
                WaybackUrls = [pscustomobject]@{ Path = 'waybackurls.exe' }
                Hakrawler   = $null
            }
        }
        Mock Get-PassiveSubdomains { @('api.khealth.io') }
        Mock Get-HistoricalUrls { @() }
        Mock Get-WaybackUrls { @() }
        Mock Invoke-HttpProbe {
            param($InputUrls)
            $script:capturedProbeInputs = @($InputUrls)
            @(
                foreach ($url in @($InputUrls)) {
                    $uri = [Uri]$url
                    [pscustomobject]@{
                        Host            = $uri.DnsSafeHost.ToLowerInvariant()
                        Url             = $uri.AbsoluteUri
                        StatusCode      = 200
                        Title           = 'ok'
                        Technologies    = @()
                        MatchedScopeIds = @()
                    }
                }
            )
        }
        Mock Invoke-KatanaCrawl {
            @(
                [pscustomobject]@{
                    Host            = 'app.khealth.com'
                    Url             = 'https://app.khealth.com/dashboard'
                    MatchedScopeIds = @('scope-003')
                }
            )
        }
        Mock Merge-DiscoveredUrlResults {
            @(
                [pscustomobject]@{
                    Host       = 'app.khealth.com'
                    Url        = 'https://app.khealth.com/dashboard'
                    ScopeId    = 'scope-003'
                    ScopeType  = 'URL'
                    ScopeValue = 'https://app.khealth.com/login?next=%2Fhome'
                    SeedUrl    = 'https://app.khealth.com/login?next=%2Fhome'
                    Source     = 'katana'
                    StatusCode = 200
                }
            )
        }
        Mock Get-InterestingReconFindings {
            @(
                [pscustomobject]@{
                    Url   = 'https://app.khealth.com/dashboard'
                    Score = 0
                }
            )
        }
        Mock Write-JsonFile {}
        Mock Set-Content {}
        Mock Export-FlatCsv {}
        Mock Get-ScopeForgeTriageState {
            [pscustomobject]@{
                Path              = Join-Path $TestDrive 'triage-state.json'
                IgnoreKeys        = New-ScopeForgeStringSet
                FalsePositiveKeys = New-ScopeForgeStringSet
                ValidatedKeys     = New-ScopeForgeStringSet
                SeenKeys          = New-ScopeForgeStringSet
            }
        }
        Mock Save-ScopeForgeTriageState {}
        Mock Merge-ReconResults {
            param($ScopeItems, $HostsAll, $LiveTargets, $DiscoveredUrls, $InterestingUrls, $Exclusions, $Errors, $ProgramName)
            [pscustomobject]@{
                GeneratedAtUtc            = [DateTimeOffset]::UtcNow.ToString('o')
                ProgramName               = $ProgramName
                ScopeItemCount            = @($ScopeItems).Count
                ExcludedItemCount         = @($Exclusions).Count
                DiscoveredHostCount       = @($HostsAll).Count
                LiveHostCount             = @($LiveTargets | Group-Object -Property Host).Count
                LiveTargetCount           = @($LiveTargets).Count
                DiscoveredUrlCount        = @($DiscoveredUrls).Count
                InterestingUrlCount       = @($InterestingUrls).Count
                ProtectedInterestingCount = 0
                StatusFamilies            = @()
                TopTechnologies           = @()
                TopSubdomains             = @()
                InterestingFamilies       = @()
                InterestingPriorities     = @()
                InterestingCategories     = @()
                SuggestedAreas            = @()
            }
        }
        Mock Export-ReconReport {}

        $result = Invoke-BugBountyRecon -ScopeFile $scopePath -OutputDir $outputDir -ProgramName 'runtime-passive-test' -UniqueUserAgent 'scopeforge-runtime-test' -EnableGau:$true -EnableWaybackUrls:$true -EnableHakrawler:$true -NoInstall -Quiet

        if (-not $result) { throw 'Expected the mixed-scope run to complete without a passive discovery crash.' }
        if ($script:capturedProbeInputs.Count -lt 5) { throw 'Expected passive discovery to produce non-empty probe candidates before HTTP validation.' }
        if ($script:capturedProbeInputs -notcontains 'https://khealth.com') { throw 'Expected the mixed scope to reach HTTP validation with the exact-domain HTTPS candidate.' }
        if ($script:capturedProbeInputs -notcontains 'http://api.khealth.io') { throw 'Expected the mixed scope to reach HTTP validation with the wildcard alternate-scheme candidate.' }
        if ($script:capturedProbeInputs -notcontains 'https://app.khealth.com/login?next=%2Fhome') { throw 'Expected the mixed scope to reach HTTP validation with the original URL seed.' }
        if (@($result.HostsAll).Count -ne 3) { throw 'Expected passive discovery to emit host inventory records for URL, domain, and wildcard inputs.' }

        $domainRecord = $result.HostsAll | Where-Object { $_.Host -eq 'khealth.com' } | Select-Object -First 1
        $wildcardRecord = $result.HostsAll | Where-Object { $_.Host -eq 'api.khealth.io' } | Select-Object -First 1
        $urlRecord = $result.HostsAll | Where-Object { $_.Host -eq 'app.khealth.com' } | Select-Object -First 1

        if (-not $domainRecord) { throw 'Expected the exact-domain host to survive passive discovery.' }
        if (-not $wildcardRecord) { throw 'Expected the wildcard-discovered host to survive passive discovery.' }
        if (-not $urlRecord) { throw 'Expected the URL seed host to survive passive discovery.' }

        if ($domainRecord.CandidateUrls -notcontains 'https://khealth.com') { throw 'Expected the domain host inventory to contain the HTTPS probe candidate.' }
        if ($domainRecord.CandidateUrls -notcontains 'http://khealth.com') { throw 'Expected the domain host inventory to contain the HTTP probe candidate.' }
        if ($wildcardRecord.CandidateUrls -notcontains 'https://api.khealth.io') { throw 'Expected the wildcard host inventory to contain the configured scheme candidate.' }
        if ($wildcardRecord.CandidateUrls -notcontains 'http://api.khealth.io') { throw 'Expected the wildcard host inventory to contain the alternate scheme candidate.' }
        if ($urlRecord.CandidateUrls -notcontains 'https://app.khealth.com/login?next=%2Fhome') { throw 'Expected the URL seed to survive candidate generation unchanged.' }
    }

    It 'uses native HTTP rescue when httpx returns no retained live targets' {
        $scopePath = Join-Path $TestDrive 'fallback-scope.json'
        $outputDir = Join-Path $TestDrive 'fallback-output'
        $scopeJson = @'
[
  { "type": "Domain", "value": "khealth.com", "exclusions": [] },
  { "type": "Domain", "value": "accounts.khealth.com", "exclusions": [] }
]
'@
        [System.IO.File]::WriteAllText($scopePath, $scopeJson, [System.Text.Encoding]::UTF8)

        $script:nativeFallbackCalled = $false

        Mock Write-StageBanner {}
        Mock Write-StageProgress {}
        Mock Write-ReconLog {}
        Mock Ensure-ReconTools {
            [pscustomobject]@{
                Subfinder   = [pscustomobject]@{ Path = 'subfinder.exe' }
                Httpx       = [pscustomobject]@{ Path = 'httpx.exe' }
                Katana      = [pscustomobject]@{ Path = 'katana.exe' }
                Gau         = [pscustomobject]@{ Path = 'gau.exe' }
                WaybackUrls = [pscustomobject]@{ Path = 'waybackurls.exe' }
                Hakrawler   = $null
            }
        }
        Mock Get-PassiveSubdomains { @() }
        Mock Get-HistoricalUrls { @() }
        Mock Get-WaybackUrls { @() }
        Mock Invoke-HttpProbe { @() }
        Mock Invoke-NativeHttpProbeFallback {
            $script:nativeFallbackCalled = $true
            @(
                [pscustomobject]@{
                    Input            = 'https://accounts.khealth.com/'
                    Url              = 'https://accounts.khealth.com/'
                    Host             = 'accounts.khealth.com'
                    Scheme           = 'https'
                    Port             = $null
                    Path             = '/'
                    StatusCode       = 200
                    Title            = ''
                    ContentLength    = 0
                    Technologies     = @()
                    RedirectLocation = ''
                    WebServer        = ''
                    MatchedScopeIds  = @('scope-002')
                    MatchedTypes     = @('Domain')
                    Source           = 'native-http-fallback'
                }
            )
        }
        Mock Invoke-KatanaCrawl {
            @(
                [pscustomobject]@{
                    Host       = 'accounts.khealth.com'
                    Url        = 'https://accounts.khealth.com/login'
                    ScopeId    = 'scope-002'
                    ScopeType  = 'Domain'
                    ScopeValue = 'accounts.khealth.com'
                    SeedUrl    = 'https://accounts.khealth.com/'
                    Source     = 'katana'
                    StatusCode = 200
                }
            )
        }
        Mock Merge-DiscoveredUrlResults {
            @(
                [pscustomobject]@{
                    Host       = 'accounts.khealth.com'
                    Url        = 'https://accounts.khealth.com/login'
                    ScopeId    = 'scope-002'
                    ScopeType  = 'Domain'
                    ScopeValue = 'accounts.khealth.com'
                    SeedUrl    = 'https://accounts.khealth.com/'
                    Source     = 'katana'
                    StatusCode = 200
                }
            )
        }
        Mock Get-InterestingReconFindings { @() }
        Mock Get-PassiveLeadFindings {
            @(
                [pscustomobject]@{
                    Url      = 'https://accounts.khealth.com/'
                    Host     = 'accounts.khealth.com'
                    Category = 'PassiveLead'
                    Family   = 'Passive'
                    Score    = 0
                }
            )
        }
        Mock Get-UnifiedFindings { @() }
        Mock Write-JsonFile {}
        Mock Set-Content {}
        Mock Export-FlatCsv {}
        Mock Get-ScopeForgeTriageState {
            [pscustomobject]@{
                Path              = Join-Path $TestDrive 'triage-state.json'
                IgnoreKeys        = New-ScopeForgeStringSet
                FalsePositiveKeys = New-ScopeForgeStringSet
                ValidatedKeys     = New-ScopeForgeStringSet
                SeenKeys          = New-ScopeForgeStringSet
            }
        }
        Mock Save-ScopeForgeTriageState {}
        Mock Merge-ReconResults {
            param($ScopeItems, $HostsAll, $LiveTargets, $DiscoveredUrls, $InterestingUrls, $Exclusions, $Errors, $ProgramName)
            [pscustomobject]@{
                GeneratedAtUtc            = [DateTimeOffset]::UtcNow.ToString('o')
                ProgramName               = $ProgramName
                ScopeItemCount            = @($ScopeItems).Count
                ExcludedItemCount         = @($Exclusions).Count
                DiscoveredHostCount       = @($HostsAll).Count
                LiveHostCount             = @($LiveTargets | Group-Object -Property Host).Count
                LiveTargetCount           = @($LiveTargets).Count
                DiscoveredUrlCount        = @($DiscoveredUrls).Count
                InterestingUrlCount       = @($InterestingUrls).Count
                ProtectedInterestingCount = 0
                StatusFamilies            = @()
                TopTechnologies           = @()
                TopSubdomains             = @()
                InterestingFamilies       = @()
                InterestingPriorities     = @()
                InterestingCategories     = @()
                SuggestedAreas            = @()
            }
        }
        Mock Export-ReconReport {}

        $result = Invoke-BugBountyRecon -ScopeFile $scopePath -OutputDir $outputDir -ProgramName 'runtime-native-fallback-test' -UniqueUserAgent 'scopeforge-runtime-test' -EnableGau:$true -EnableWaybackUrls:$true -EnableHakrawler:$true -NoInstall -Quiet

        if (-not $script:nativeFallbackCalled) { throw 'Expected native HTTP rescue to run when httpx returned no live targets.' }
        if (@($result.LiveTargets).Count -ne 1) { throw 'Expected the native HTTP rescue target to be retained.' }
        if ($result.LiveTargets[0].Source -ne 'native-http-fallback') { throw 'Expected the retained live target to expose the native fallback source.' }
    }

    It 'retries httpx on a reduced bounded candidate set before using native fallback' {
        $scopePath = Join-Path $TestDrive 'reduced-httpx-scope.json'
        $outputDir = Join-Path $TestDrive 'reduced-httpx-output'
        $scopeJson = @'
[
  { "type": "Domain", "value": "khealth.com", "exclusions": [] },
  { "type": "Domain", "value": "accounts.khealth.com", "exclusions": [] }
]
'@
        [System.IO.File]::WriteAllText($scopePath, $scopeJson, [System.Text.Encoding]::UTF8)

        $script:nativeFallbackCalled = $false
        $script:httpxInputCounts = @()

        Mock Write-StageBanner {}
        Mock Write-StageProgress {}
        Mock Write-ReconLog {}
        Mock Ensure-ReconTools {
            [pscustomobject]@{
                Subfinder   = [pscustomobject]@{ Path = 'subfinder.exe' }
                Httpx       = [pscustomobject]@{ Path = 'httpx.exe' }
                Katana      = [pscustomobject]@{ Path = 'katana.exe' }
                Gau         = [pscustomobject]@{ Path = 'gau.exe' }
                WaybackUrls = [pscustomobject]@{ Path = 'waybackurls.exe' }
                Hakrawler   = $null
            }
        }
        Mock Get-PassiveSubdomains { @() }
        Mock Get-HistoricalUrls { @() }
        Mock Get-WaybackUrls { @() }
        Mock Invoke-HttpProbe {
            param($InputUrls)
            $script:httpxInputCounts += @(@($InputUrls).Count)
            if ($script:httpxInputCounts.Count -eq 1) { return @() }
            @(
                [pscustomobject]@{
                    Input            = 'https://accounts.khealth.com/'
                    Url              = 'https://accounts.khealth.com/'
                    Host             = 'accounts.khealth.com'
                    Scheme           = 'https'
                    Port             = $null
                    Path             = '/'
                    StatusCode       = 403
                    Title            = 'Just a moment...'
                    ContentType      = 'text/html'
                    ContentLength    = 4698
                    Technologies     = @('Cloudflare')
                    RedirectLocation = ''
                    WebServer        = 'cloudflare'
                    MatchedScopeIds  = @('scope-002')
                    MatchedTypes     = @('Domain')
                    Source           = 'httpx'
                }
            )
        }
        Mock Invoke-NativeHttpProbeFallback {
            $script:nativeFallbackCalled = $true
            @()
        }
        Mock Invoke-KatanaCrawl { ,@() }
        Mock Merge-DiscoveredUrlResults { @() }
        Mock Get-PassiveLeadFindings { ,@() }
        Mock Get-UnifiedFindings { ,@() }
        Mock Write-JsonFile {}
        Mock Set-Content {}
        Mock Export-FlatCsv {}
        Mock Get-ScopeForgeTriageState {
            [pscustomobject]@{
                Path              = Join-Path $TestDrive 'triage-state.json'
                IgnoreKeys        = New-ScopeForgeStringSet
                FalsePositiveKeys = New-ScopeForgeStringSet
                ValidatedKeys     = New-ScopeForgeStringSet
                SeenKeys          = New-ScopeForgeStringSet
            }
        }
        Mock Save-ScopeForgeTriageState {}
        Mock Merge-ReconResults {
            param($ScopeItems, $HostsAll, $LiveTargets, $DiscoveredUrls, $InterestingUrls, $Exclusions, $Errors, $ProgramName)
            [pscustomobject]@{
                GeneratedAtUtc            = [DateTimeOffset]::UtcNow.ToString('o')
                ProgramName               = $ProgramName
                ScopeItemCount            = @($ScopeItems).Count
                ExcludedItemCount         = @($Exclusions).Count
                DiscoveredHostCount       = @($HostsAll).Count
                LiveHostCount             = @($LiveTargets | Group-Object -Property Host).Count
                LiveTargetCount           = @($LiveTargets).Count
                DiscoveredUrlCount        = @($DiscoveredUrls).Count
                InterestingUrlCount       = @($InterestingUrls).Count
                ProtectedInterestingCount = 0
                StatusFamilies            = @()
                TopTechnologies           = @()
                TopSubdomains             = @()
                InterestingFamilies       = @()
                InterestingPriorities     = @()
                InterestingCategories     = @()
                SuggestedAreas            = @()
            }
        }
        Mock Export-ReconReport {}

        $result = Invoke-BugBountyRecon -ScopeFile $scopePath -OutputDir $outputDir -ProgramName 'runtime-reduced-httpx-test' -UniqueUserAgent 'scopeforge-runtime-test' -EnableGau:$true -EnableWaybackUrls:$true -EnableHakrawler:$true -NoInstall -Quiet

        if ($script:httpxInputCounts.Count -ne 2) { throw 'Expected httpx to be attempted twice: full pass then reduced rescue.' }
        if ($script:httpxInputCounts[0] -le $script:httpxInputCounts[1]) { throw 'Expected the reduced httpx rescue to probe fewer candidates than the full pass.' }
        if ($script:nativeFallbackCalled) { throw 'Expected native fallback to stay unused when reduced httpx rescue succeeds.' }
        if (@($result.LiveTargets).Count -ne 1) { throw 'Expected the reduced httpx rescue to retain one live target.' }
        if ($result.LiveTargets[0].Source -ne 'httpx') { throw 'Expected the retained live target to remain attributed to httpx.' }
    }
}

Describe 'ScopeForge triage reachability guardrails' {
    It 'keeps dead or unstable interesting paths out of reviewable and shortlist while preserving them in filtered outputs' {
        $triageState = [pscustomobject]@{
            Path              = Join-Path $TestDrive 'triage-state.json'
            IgnoreKeys        = New-ScopeForgeStringSet
            FalsePositiveKeys = New-ScopeForgeStringSet
            ValidatedKeys     = New-ScopeForgeStringSet
            SeenKeys          = New-ScopeForgeStringSet
        }

        $liveTargets = @()
        $discoveredUrls = @(
            [pscustomobject]@{
                Url        = 'https://app.example.com/login'
                Host       = 'app.example.com'
                ScopeId    = 'scope-001'
                Source     = 'katana'
                StatusCode = 404
                ContentType = 'text/html'
            },
            [pscustomobject]@{
                Url        = 'https://app.example.com/admin'
                Host       = 'app.example.com'
                ScopeId    = 'scope-001'
                Source     = 'katana'
                StatusCode = 0
                ContentType = 'text/html'
            },
            [pscustomobject]@{
                Url        = 'https://app.example.com/graphql'
                Host       = 'app.example.com'
                ScopeId    = 'scope-001'
                Source     = 'katana'
                StatusCode = 403
                ContentType = 'text/html'
            }
        )

        $triage = Get-TriageReconData -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -TriageState $triageState

        if (@($triage.FilteredFindings).Count -ne 3) { throw 'Expected all non-noise findings to remain preserved in filtered outputs.' }
        if (@($triage.ReviewableFindings).Count -ne 1) { throw 'Expected only the reachable protected endpoint to remain reviewable.' }
        if (@($triage.Shortlist).Count -ne 1) { throw 'Expected only the reachable protected endpoint to remain in the shortlist.' }

        $filtered404 = @($triage.FilteredFindings | Where-Object { $_.Url -eq 'https://app.example.com/login' } | Select-Object -First 1)
        $filtered0 = @($triage.FilteredFindings | Where-Object { $_.Url -eq 'https://app.example.com/admin' } | Select-Object -First 1)
        $reviewableUrls = @($triage.ReviewableFindings | Select-Object -ExpandProperty Url)

        if (-not $filtered404) { throw 'Expected the 404 login route to remain available in filtered findings.' }
        if (-not $filtered0) { throw 'Expected the status-0 admin route to remain available in filtered findings.' }
        if ($filtered404[0].TriageSuppressionReason -ne 'status-404') { throw 'Expected the 404 route to expose a suppression reason.' }
        if ($filtered0[0].TriageSuppressionReason -ne 'status-0') { throw 'Expected the status-0 route to expose a suppression reason.' }
        if ($reviewableUrls -contains 'https://app.example.com/login') { throw 'Expected the 404 route to stay out of reviewable findings.' }
        if ($reviewableUrls -contains 'https://app.example.com/admin') { throw 'Expected the status-0 route to stay out of reviewable findings.' }
        if ($reviewableUrls -notcontains 'https://app.example.com/graphql') { throw 'Expected the 403 route to remain reviewable.' }
    }
}

Describe 'ScopeForge httpx diagnostics' {
    BeforeEach {
        $layout = Get-OutputLayout -OutputDir (Join-Path $TestDrive 'output')
        Initialize-OutputDirectories -Layout $layout
        $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName 'httpx-diagnostics-test' -Quiet:$true -ExportJsonEnabled:$true -ExportCsvEnabled:$true -ExportHtmlEnabled:$true

        Mock Write-StageProgress {}
        Mock Write-ReconLog {}
        Mock Get-ToolHelpText { 'usage' }
    }

    AfterEach {
        $script:ScopeForgeContext = $null
    }

    It 'logs retained and discarded httpx results by reason without changing retained targets' {
        $scopeItem = [pscustomobject]@{
            Id              = 'scope-001'
            Index           = 1
            Type            = 'URL'
            OriginalValue   = 'https://app.example.com/'
            NormalizedValue = 'https://app.example.com/'
            Scheme          = 'https'
            Host            = 'app.example.com'
            Port            = $null
            RootDomain      = 'app.example.com'
            PathPrefix      = '/'
            StartUrl        = 'https://app.example.com/'
            IncludeApex     = $false
            Exclusions      = @('logout')
            HostRegexString = '^app\.example\.com$'
            ScopeRegexString = ''
            Description     = 'URL seed https://app.example.com/'
        }

        Mock Invoke-ExternalCommand {
            param($FilePath, $Arguments, $TimeoutSeconds, $StdOutPath, $StdErrPath, $IgnoreExitCode)

            $lines = @(
                ([pscustomobject]@{ input = 'https://app.example.com/'; url = 'https://app.example.com/login'; 'status-code' = 200; title = 'Sign in' } | ConvertTo-Json -Compress),
                ([pscustomobject]@{ input = 'https://app.example.com/'; url = 'https://app.example.com/login'; 'status-code' = 200; title = 'Sign in' } | ConvertTo-Json -Compress),
                ([pscustomobject]@{ input = 'https://app.example.com/'; url = 'https://app.example.com/_next/static/chunk.js'; 'status-code' = 200; title = '' } | ConvertTo-Json -Compress),
                ([pscustomobject]@{ input = 'https://app.example.com/'; url = 'https://other.example.net/login'; 'status-code' = 200; title = 'External' } | ConvertTo-Json -Compress),
                ([pscustomobject]@{ input = 'https://app.example.com/'; url = 'https://app.example.com/logout'; 'status-code' = 200; title = 'Sign out' } | ConvertTo-Json -Compress),
                ([pscustomobject]@{ input = 'https://app.example.com/'; 'status-code' = 200; title = 'Missing URL' } | ConvertTo-Json -Compress),
                ([pscustomobject]@{ input = 'https://app.example.com/'; url = 'not-a-valid-uri'; 'status-code' = 200; title = 'Broken URL' } | ConvertTo-Json -Compress),
                '{"url":'
            )

            Set-Content -LiteralPath $StdOutPath -Value $lines -Encoding utf8
            Set-Content -LiteralPath $StdErrPath -Value '' -Encoding utf8

            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = ''
                StdErr    = ''
                FilePath  = $FilePath
                Arguments = @($Arguments)
            }
        }

        $liveTargets = @(Invoke-HttpProbe -InputUrls @('https://app.example.com/') -ScopeItems @($scopeItem) -HttpxPath 'httpx.exe' -RawOutputPath $script:ScopeForgeContext.Layout.HttpxRaw -Threads 1 -TimeoutSeconds 10)
        $batchLog = Get-Content -LiteralPath $script:ScopeForgeContext.Layout.HttpxBatchLog -Raw -Encoding utf8

        if ($liveTargets.Count -ne 1) { throw 'Expected only one live target to survive the diagnostic batch.' }
        if ($liveTargets[0].Url -ne 'https://app.example.com/login') { throw 'Expected the retained live target URL to remain unchanged.' }
        if ($batchLog -notlike '*BATCH|index=1/1|input=1|stdout_lines=8|exit=0*') { throw 'Expected the batch log to record the raw stdout line count.' }
        if ($batchLog -notlike '*BATCH_SUMMARY|index=1/1|input=1|json_parsed=7|in_scope_after_exclusions=3|retained=1|discarded=6|parse_errors=1|reasons=missing_url=1,invalid_uri=1,out_of_scope=1,excluded=1,noise=1,duplicate=1*') {
            throw ("Expected the batch summary to expose retained/discarded counts and detailed discard reasons. Actual log: {0}" -f $batchLog)
        }
    }

    It 'logs a diagnostic sample when an httpx batch returns no JSON lines' {
        $scopeItem = [pscustomobject]@{
            Id              = 'scope-001'
            Index           = 1
            Type            = 'URL'
            OriginalValue   = 'https://app.example.com/'
            NormalizedValue = 'https://app.example.com/'
            Scheme          = 'https'
            Host            = 'app.example.com'
            Port            = $null
            RootDomain      = 'app.example.com'
            PathPrefix      = '/'
            StartUrl        = 'https://app.example.com/'
            IncludeApex     = $false
            Exclusions      = @()
            HostRegexString = '^app\.example\.com$'
            ScopeRegexString = ''
            Description     = 'URL seed https://app.example.com/'
        }

        Mock Get-ToolHelpText { '-duc -H -header -probe -status-code -follow-redirects -location -tech-detect' }
        Mock Invoke-ExternalCommand {
            param($FilePath, $Arguments, $TimeoutSeconds, $StdOutPath, $StdErrPath, $IgnoreExitCode)

            if ((@($Arguments) -contains '-probe') -and (@($Arguments) -contains '-u')) {
                $diagLine = ([pscustomobject]@{
                        timestamp   = '2026-04-03T15:23:40.1020496+02:00'
                        url         = 'https://app.example.com/'
                        input       = 'https://app.example.com/'
                        error       = 'cause="no address found for host"'
                        status_code = 0
                        failed      = $true
                    } | ConvertTo-Json -Compress)
                Set-Content -LiteralPath $StdOutPath -Value $diagLine -Encoding utf8
            } else {
                Set-Content -LiteralPath $StdOutPath -Value @() -Encoding utf8
            }

            Set-Content -LiteralPath $StdErrPath -Value '' -Encoding utf8

            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = ''
                StdErr    = ''
                FilePath  = $FilePath
                Arguments = @($Arguments)
            }
        }

        $liveTargets = @(Invoke-HttpProbe -InputUrls @('https://app.example.com/') -ScopeItems @($scopeItem) -HttpxPath 'httpx.exe' -RawOutputPath $script:ScopeForgeContext.Layout.HttpxRaw -Threads 1 -TimeoutSeconds 10)
        $batchLog = Get-Content -LiteralPath $script:ScopeForgeContext.Layout.HttpxBatchLog -Raw -Encoding utf8
        $snapshotInput = Get-Content -LiteralPath $script:ScopeForgeContext.Layout.HttpxEmptyBatchInput -Raw -Encoding utf8
        $snapshotMeta = Get-Content -LiteralPath $script:ScopeForgeContext.Layout.HttpxEmptyBatchMeta -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10

        if ($liveTargets.Count -ne 0) { throw 'Expected an empty primary httpx batch to keep zero retained targets.' }
        if ($batchLog -notlike '*BATCH|index=1/1|input=1|stdout_lines=0|exit=0*') { throw ("Expected the batch log to record the empty primary batch. Actual log: {0}" -f $batchLog) }
        if ($batchLog -notlike '*BATCH_EMPTY_SNAPSHOT|index=1/1|input=1*') { throw ("Expected the empty primary batch to preserve a raw snapshot. Actual log: {0}" -f $batchLog) }
        if ($batchLog -notlike '*BATCH_EMPTY_DIAG|index=1/1|sample=1|diag_lines=0|diag_exit=0|parse_errors=0|reasons=no-json-output*') {
            throw ("Expected the empty-batch list diagnostic to record the empty list-mode behavior. Actual log: {0}" -f $batchLog)
        }
        if ($batchLog -notlike '*BATCH_EMPTY_DIAG_SINGLE|index=1/1|url=https://app.example.com/|diag_lines=1|diag_exit=0|parse_errors=0|reasons=no address found for host=1*') {
            throw ("Expected the empty-batch single-target diagnostic to capture the failed probe reason. Actual log: {0}" -f $batchLog)
        }
        if (-not (Test-Path -LiteralPath $script:ScopeForgeContext.Layout.HttpxEmptyBatchStdOut)) { throw 'Expected the empty-batch stdout snapshot to exist.' }
        if (-not (Test-Path -LiteralPath $script:ScopeForgeContext.Layout.HttpxEmptyBatchStdErr)) { throw 'Expected the empty-batch stderr snapshot to exist.' }
        if ($snapshotInput -notlike '*https://app.example.com/*') { throw 'Expected the empty-batch input snapshot to preserve the original URL.' }
        if ($snapshotMeta.InputCount -ne 1 -or $snapshotMeta.FirstInputUrl -ne 'https://app.example.com/') { throw 'Expected the empty-batch context snapshot to preserve the first input URL and input count.' }
    }
}
