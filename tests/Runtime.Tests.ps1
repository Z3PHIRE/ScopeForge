Describe 'ScopeForge passive discovery runtime safety' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

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
        Mock Get-PassiveLeadFindings { $null }
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
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

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

Describe 'ScopeForge triage content signals' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

    It 'promotes structured JSON responses into reviewable API findings even without an explicit api path' {
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
                Url         = 'https://app.example.com/compteur/compteur.php?format=json&source=js'
                Host        = 'app.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 200
                ContentType = 'application/json; charset=utf-8'
            }
        )

        $triage = Get-TriageReconData -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -TriageState $triageState

        if (@($triage.ReviewableFindings).Count -ne 1) { throw 'Expected the structured JSON response to become reviewable.' }
        if (@($triage.Shortlist).Count -ne 1) { throw 'Expected the structured JSON response to enter the shortlist when it is the only reviewable finding.' }

        $finding = @($triage.ReviewableFindings | Select-Object -First 1)
        if (-not $finding) { throw 'Expected a reviewable finding to exist.' }
        if ($finding[0].ContentType -ne 'application/json; charset=utf-8') { throw 'Expected the original JSON content type to be preserved on the finding.' }
        if ($finding[0].Categories -notcontains 'API') { throw 'Expected the structured JSON response to be categorized as API.' }
        if ($finding[0].Reasons -notcontains 'Structured JSON response') { throw 'Expected the structured JSON response reason to be recorded.' }
        if ($finding[0].PrimaryFamily -ne 'API') { throw 'Expected the structured JSON response to map to the API family.' }
    }

    It 'uses title-only signals to classify API documentation pages without path hints' {
        $triageState = [pscustomobject]@{
            Path              = Join-Path $TestDrive 'triage-state-title-only.json'
            Entries           = @{}
            IgnoreKeys        = New-ScopeForgeStringSet
            FalsePositiveKeys = New-ScopeForgeStringSet
            ValidatedKeys     = New-ScopeForgeStringSet
            SeenKeys          = New-ScopeForgeStringSet
        }

        $liveTargets = @(
            [pscustomobject]@{
                Url          = 'https://app.example.com/'
                Host         = 'app.example.com'
                StatusCode   = 200
                Title        = 'Swagger UI'
                ContentType  = 'text/html'
                Technologies = @()
                WebServer    = 'nginx'
                Source       = 'httpx'
            }
        )
        $discoveredUrls = @(
            [pscustomobject]@{
                Url         = 'https://app.example.com/'
                Host        = 'app.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 200
                ContentType = 'text/html'
            }
        )

        $triage = Get-TriageReconData -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -TriageState $triageState

        if (@($triage.ReviewableFindings).Count -ne 1) { throw 'Expected the title-only API page to become reviewable.' }
        $finding = @($triage.ReviewableFindings | Select-Object -First 1)
        if (-not $finding) { throw 'Expected a reviewable finding for the title-only API page.' }
        if ($finding[0].Categories -notcontains 'API') { throw 'Expected the title-only API page to be categorized as API.' }
        if ($finding[0].PrimaryFamily -ne 'API') { throw 'Expected the title-only API page to map to the API family.' }
        if ($finding[0].Reasons -notcontains 'API documentation title signal') { throw 'Expected the title-only API reason to be recorded.' }
    }

    It 'uses explicit query parameter signals to classify generic OAuth-style entry points and preserve parameter names in reports' {
        $triageState = [pscustomobject]@{
            Path              = Join-Path $TestDrive 'triage-state-parameter-signals.json'
            Entries           = @{}
            IgnoreKeys        = New-ScopeForgeStringSet
            FalsePositiveKeys = New-ScopeForgeStringSet
            ValidatedKeys     = New-ScopeForgeStringSet
            SeenKeys          = New-ScopeForgeStringSet
        }

        $liveTargets = @()
        $discoveredUrls = @(
            [pscustomobject]@{
                Url         = 'https://app.example.com/flow?client_id=webapp&response_type=code&scope=openid'
                Host        = 'app.example.com'
                ScopeId     = 'scope-001'
                Source      = 'seed'
                StatusCode  = 200
                ContentType = 'text/html'
            }
        )

        $triage = Get-TriageReconData -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -TriageState $triageState

        if (@($triage.ReviewableFindings).Count -ne 1) { throw 'Expected the generic OAuth-style entry point to become reviewable from query parameter signals.' }
        if (@($triage.Shortlist).Count -ne 1) { throw 'Expected the parameter-signaled entry point to enter the shortlist when it is the only reviewable finding.' }

        $finding = @($triage.ReviewableFindings | Select-Object -First 1)
        if (-not $finding) { throw 'Expected a reviewable finding for the parameter-signaled entry point.' }
        if ($finding[0].Categories -notcontains 'Auth') { throw 'Expected the parameter-signaled entry point to be categorized as Auth.' }
        if ($finding[0].PrimaryFamily -ne 'Auth') { throw 'Expected the parameter-signaled entry point to map to the Auth family.' }
        if ($finding[0].Reasons -notlike '*Authentication parameter signal: client_id, response_type, scope*') { throw 'Expected the authentication parameter signal reason to be recorded with matched names.' }
        if ((@($finding[0].Parameters) -join ',') -ne 'client_id,response_type,scope') { throw 'Expected normalized parameter names to be preserved on the finding.' }

        $layout = Get-OutputLayout -OutputDir (Join-Path $TestDrive 'parameter-signal-report-output')
        Initialize-OutputDirectories -Layout $layout
        $summary = [pscustomobject]@{
            GeneratedAtUtc               = '2026-04-07T12:00:00Z'
            ProgramName                  = 'parameter-signal-test'
            ScopeItemCount               = 1
            ExcludedItemCount            = 0
            DiscoveredHostCount          = 1
            LiveHostCount                = 0
            LiveTargetCount              = 0
            ReachableTargetCount         = 0
            DeadOrUnstableTargetCount    = 0
            DiscoveredUrlCount           = 1
            InterestingUrlCount          = 1
            ProtectedInterestingCount    = 0
            ShortlistCount               = 1
            BaselineShortlistCount       = 0
            DisplayedShortlistCount      = 1
            ReachableTopTechnologies     = @()
            InterestingPriorityDistribution = @()
        }

        Export-TriageMarkdownReport -Summary $summary -InterestingUrls @($finding) -InterestingFamilies @() -LiveTargets @() -Exclusions @() -Errors @() -Layout $layout
        $triageMarkdown = Get-Content -LiteralPath $layout.TriageMarkdown -Raw -Encoding utf8
        if ($triageMarkdown -notlike '*- Parameters: client_id, response_type, scope*') { throw 'Expected triage markdown to expose matched parameter names.' }
    }

    It 'removes Segment and Next.js volatile parameters from review keys while preserving functional parameters' {
        $analysis = Get-ReviewUrlAnalysis -Url 'https://auth.example.com/khealth/login?segment_anonymous_id=550e8400-e29b-41d4-a716-446655440000&_rsc=1a2b3c&returnUrl=%2Fhome'

        if (-not $analysis.HasVolatileParams) { throw 'Expected volatile tracking parameters to be flagged.' }
        if ($analysis.ReviewKey -ne 'https://auth.example.com/khealth/login?returnUrl=%2Fhome') { throw 'Expected volatile tracking parameters to be removed from the review key.' }
        if ((@($analysis.Parameters) -join ',') -ne 'returnUrl') { throw 'Expected only functional parameter names to remain after volatile filtering.' }
    }

    It 'forces Auth as the primary family when auth routes also match operations patterns' {
        $triageState = [pscustomobject]@{
            Path              = Join-Path $TestDrive 'triage-state-auth-operations.json'
            Entries           = @{}
            IgnoreKeys        = New-ScopeForgeStringSet
            FalsePositiveKeys = New-ScopeForgeStringSet
            ValidatedKeys     = New-ScopeForgeStringSet
            SeenKeys          = New-ScopeForgeStringSet
        }

        $triage = Get-TriageReconData -LiveTargets @() -DiscoveredUrls @(
            [pscustomobject]@{
                Url         = 'https://auth.example.com/login/status?trace=1'
                Host        = 'auth.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 403
                ContentType = 'text/html'
            }
        ) -TriageState $triageState

        $finding = @($triage.ReviewableFindings | Select-Object -First 1)
        if (-not $finding) { throw 'Expected the overlapping auth/operations route to remain reviewable.' }
        if ($finding[0].PrimaryFamily -ne 'Auth') { throw 'Expected Auth to override Operations for login-style routes.' }
        if ($finding[0].Categories -notcontains 'Auth') { throw 'Expected the overlapping route to keep its Auth category.' }
    }

    It 'deduplicates the shortlist by normalized base path when multiple reviewable URLs share the same endpoint path' {
        $triageState = [pscustomobject]@{
            Path              = Join-Path $TestDrive 'triage-state-shortlist-basepath.json'
            Entries           = @{}
            IgnoreKeys        = New-ScopeForgeStringSet
            FalsePositiveKeys = New-ScopeForgeStringSet
            ValidatedKeys     = New-ScopeForgeStringSet
            SeenKeys          = New-ScopeForgeStringSet
        }

        $triage = Get-TriageReconData -LiveTargets @() -DiscoveredUrls @(
            [pscustomobject]@{
                Url         = 'https://auth.example.com/khealth/login?returnUrl=%2Fhome'
                Host        = 'auth.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 403
                ContentType = 'text/html'
            },
            [pscustomobject]@{
                Url         = 'https://auth.example.com/khealth/login?returnUrl=%2Fbilling'
                Host        = 'auth.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 403
                ContentType = 'text/html'
            },
            [pscustomobject]@{
                Url         = 'https://app.example.com/graphql'
                Host        = 'app.example.com'
                ScopeId     = 'scope-002'
                Source      = 'katana'
                StatusCode  = 403
                ContentType = 'text/html'
            }
        ) -TriageState $triageState

        $loginShortlistEntries = @($triage.Shortlist | Where-Object { $_.Url -like 'https://auth.example.com/khealth/login*' })
        if (@($triage.ReviewableFindings).Count -ne 3) { throw 'Expected all three URLs to remain reviewable before shortlist shaping.' }
        if (@($triage.Shortlist).Count -ne 2) { throw 'Expected shortlist shaping to collapse duplicate base paths.' }
        if ($loginShortlistEntries.Count -ne 1) { throw 'Expected only one login base path entry to survive in the shortlist.' }
        if ((@($triage.Shortlist | Select-Object -ExpandProperty Url) -notcontains 'https://app.example.com/graphql')) { throw 'Expected the shortlist to keep the distinct secondary endpoint.' }
    }

    It 'promotes session, patient-data and telemetry endpoints with enriched API scoring' {
        $triageState = [pscustomobject]@{
            Path              = Join-Path $TestDrive 'triage-state-api-enrichment.json'
            Entries           = @{}
            IgnoreKeys        = New-ScopeForgeStringSet
            FalsePositiveKeys = New-ScopeForgeStringSet
            ValidatedKeys     = New-ScopeForgeStringSet
            SeenKeys          = New-ScopeForgeStringSet
        }

        $triage = Get-TriageReconData -LiveTargets @() -DiscoveredUrls @(
            [pscustomobject]@{
                Url         = 'https://accounts.example.com/api/account/session'
                Host        = 'accounts.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 403
                ContentType = 'application/json'
            },
            [pscustomobject]@{
                Url         = 'https://app.example.com/api/patient-onboarding-data'
                Host        = 'app.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 200
                ContentType = 'application/json'
            },
            [pscustomobject]@{
                Url         = 'https://otel-http.example.com/clienttoken/v1/traces'
                Host        = 'otel-http.example.com'
                ScopeId     = 'scope-001'
                Source      = 'katana'
                StatusCode  = 200
                ContentType = 'application/json'
            }
        ) -TriageState $triageState

        $sessionFinding = @($triage.ReviewableFindings | Where-Object { $_.Url -eq 'https://accounts.example.com/api/account/session' } | Select-Object -First 1)
        $patientFinding = @($triage.ReviewableFindings | Where-Object { $_.Url -eq 'https://app.example.com/api/patient-onboarding-data' } | Select-Object -First 1)
        $telemetryFinding = @($triage.ReviewableFindings | Where-Object { $_.Url -eq 'https://otel-http.example.com/clienttoken/v1/traces' } | Select-Object -First 1)

        if (-not $sessionFinding -or -not $patientFinding -or -not $telemetryFinding) { throw 'Expected all enriched API endpoints to remain reviewable.' }
        if ($sessionFinding[0].Priority -ne 'Critical') { throw 'Expected the session endpoint to be promoted to Critical.' }
        if ($sessionFinding[0].PrimaryFamily -ne 'API') { throw 'Expected the session endpoint to map to the API family.' }
        if ($sessionFinding[0].Reasons -notcontains 'Token or session management endpoint') { throw 'Expected the session endpoint to record the token/session reason.' }
        if ($patientFinding[0].Priority -ne 'Critical') { throw 'Expected the patient-data endpoint to be promoted to Critical.' }
        if ($patientFinding[0].Reasons -notcontains 'Sensitive data endpoint (medical/financial/PII)') { throw 'Expected the patient-data endpoint to record the sensitive-data reason.' }
        if ($telemetryFinding[0].Priority -ne 'Critical') { throw 'Expected the telemetry endpoint to accumulate enough API signal for Critical priority.' }
        if ($telemetryFinding[0].Reasons -notcontains 'Telemetry or observability ingestion endpoint') { throw 'Expected the telemetry endpoint to record the observability reason.' }
    }
}

Describe 'ScopeForge discovered URL context propagation' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

    It 'propagates exact live-target context to discovered URL exports and reports' {
        $liveTargets = @(
            [pscustomobject]@{
                Url          = 'https://app.example.com/'
                Host         = 'app.example.com'
                StatusCode   = 200
                Title        = 'Example App'
                ContentType  = 'text/html; charset=utf-8'
                Technologies = @('nginx', 'HSTS')
                WebServer    = 'nginx'
                Source       = 'httpx'
            }
        )

        $discoveredUrls = @(
            [pscustomobject]@{
                Url         = 'https://app.example.com/'
                Host        = 'app.example.com'
                ScopeId     = 'scope-001'
                ScopeType   = 'Domain'
                ScopeValue  = 'app.example.com'
                SeedUrl     = 'https://app.example.com/'
                Source      = 'katana'
                StatusCode  = 200
                ContentType = 'text/html; charset=utf-8'
            }
        )

        $enriched = Add-DiscoveredUrlContext -DiscoveredUrls $discoveredUrls -LiveTargets $liveTargets
        if (@($enriched).Count -ne 1) { throw 'Expected one discovered URL after context propagation.' }
        if ($enriched[0].Title -ne 'Example App') { throw 'Expected the live target title to be propagated to the discovered URL.' }
        if ($enriched[0].WebServer -ne 'nginx') { throw 'Expected the live target web server to be propagated to the discovered URL.' }
        if ((@($enriched[0].Technologies) -join ',') -ne 'nginx,HSTS') { throw 'Expected the live target technologies to be propagated to the discovered URL.' }

        $outputDir = Join-Path $TestDrive 'discovered-context-output'
        $layout = Get-OutputLayout -OutputDir $outputDir
        Initialize-OutputDirectories -Layout $layout
        $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName 'discovered-context-test' -Quiet:$true -ExportJsonEnabled:$true -ExportCsvEnabled:$true -ExportHtmlEnabled:$true
        $script:ScopeForgeContext.Triage = [pscustomobject]@{
            FilteredFindings   = @()
            NoiseFindings      = @()
            ReviewableFindings = @()
            Shortlist          = @()
        }

        $summary = [pscustomobject]@{
            ProgramName                     = 'discovered-context-test'
            GeneratedAtUtc                  = [DateTimeOffset]::UtcNow.ToString('o')
            ScopeItemCount                  = 1
            ExcludedItemCount               = 0
            DiscoveredHostCount             = 1
            LiveHostCount                   = 1
            LiveTargetCount                 = 1
            ReachableTargetCount            = 1
            DeadOrUnstableTargetCount       = 0
            DiscoveredUrlCount              = 1
            InterestingUrlCount             = 0
            ErrorCount                      = 0
            ProtectedInterestingCount       = 0
            UniqueUserAgent                 = 'scopeforge-test'
            StatusCodeDistribution          = @([pscustomobject]@{ StatusCode = '200'; Count = 1 })
            TopTechnologies                 = @()
            ReachableTopTechnologies        = @()
            TopSubdomains                   = @()
            TopInterestingCategories        = @()
            TopInterestingFamilies          = @()
            InterestingPriorityDistribution = @()
            ErrorPhaseDistribution          = @()
            ErrorToolDistribution           = @()
            TopAuthReviewable               = @()
            TopApiReviewable                = @()
            TopProtectedReviewable          = @()
        }

        try {
            Export-ReconReport -Summary $summary -ScopeItems @([pscustomobject]@{ Id = 'scope-001'; Type = 'Domain'; NormalizedValue = 'app.example.com'; Exclusions = @() }) -HostsAll @() -HostsLive @() -LiveTargets $liveTargets -DiscoveredUrls $enriched -InterestingUrls @() -Exclusions @() -Errors @() -Layout $layout -ExportHtml
            $reportHtml = Get-Content -LiteralPath $layout.ReportHtml -Raw -Encoding utf8
        } finally {
            $script:ScopeForgeContext = $null
        }

        if ($reportHtml -notlike '*Discovered URLs*') { throw 'Expected the discovered URLs section to be present.' }
        if ($reportHtml -notlike '*Example App*') { throw 'Expected the discovered URLs table to expose the propagated title.' }
        if ($reportHtml -notlike '*text/html; charset=utf-8*') { throw 'Expected the discovered URLs table to expose the propagated content type.' }
    }
}

Describe 'ScopeForge crawl seed preservation' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

    It 'does not re-add dead live targets as synthetic crawl seeds' {
        $tempDir = Join-Path $TestDrive 'katana-seed-filter'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $rawOutputPath = Join-Path $tempDir 'katana.jsonl'

        $scopeItem = [pscustomobject]@{
            Id               = 'scope-001'
            Index            = 1
            Type             = 'Wildcard'
            OriginalValue    = 'https://*.example.com'
            NormalizedValue  = 'https://*.example.com'
            Scheme           = 'https'
            Host             = '*.example.com'
            Port             = $null
            RootDomain       = 'example.com'
            PathPrefix       = '/'
            StartUrl         = ''
            IncludeApex      = $false
            Exclusions       = @()
            HostRegexString  = '^(?:[a-z0-9-]+\.)+example\.com$'
            ScopeRegexString = '^https?://(?:[a-z0-9-]+\.)+example\.com(?::\d+)?(?:/.*)?$'
            Description      = 'Wildcard scope https://*.example.com'
        }

        $liveTargets = @(
            [pscustomobject]@{
                Input            = 'https://app.example.com/'
                Url              = 'https://app.example.com/'
                Host             = 'app.example.com'
                Scheme           = 'https'
                Port             = $null
                Path             = '/'
                StatusCode       = 200
                Title            = 'App'
                ContentType      = 'text/html'
                ContentLength    = 100
                Technologies     = @('nginx')
                RedirectLocation = ''
                WebServer        = 'nginx'
                MatchedScopeIds  = @('scope-001')
                MatchedTypes     = @('Wildcard')
                Source           = 'httpx'
            },
            [pscustomobject]@{
                Input            = 'https://app.example.com/missing'
                Url              = 'https://app.example.com/missing'
                Host             = 'app.example.com'
                Scheme           = 'https'
                Port             = $null
                Path             = '/missing'
                StatusCode       = 404
                Title            = '404 Not Found'
                ContentType      = 'text/html'
                ContentLength    = 50
                Technologies     = @('nginx')
                RedirectLocation = ''
                WebServer        = 'nginx'
                MatchedScopeIds  = @('scope-001')
                MatchedTypes     = @('Wildcard')
                Source           = 'httpx'
            }
        )

        $layout = Get-OutputLayout -OutputDir (Join-Path $TestDrive 'output')
        Initialize-OutputDirectories -Layout $layout
        $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName 'katana-seed-filter-test' -Quiet:$true -ExportJsonEnabled:$true -ExportCsvEnabled:$true -ExportHtmlEnabled:$true

        Mock Write-StageProgress {}
        Mock Write-ReconLog {}
        Mock Get-ToolHelpText { 'usage' }
        Mock Invoke-ExternalCommand {
            param($FilePath, $Arguments, $TimeoutSeconds, $StdOutPath, $StdErrPath, $IgnoreExitCode)

            Set-Content -LiteralPath $StdOutPath -Value @() -Encoding utf8
            Set-Content -LiteralPath $StdErrPath -Value '' -Encoding utf8

            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = ''
                StdErr    = ''
                FilePath  = $FilePath
                Arguments = @($Arguments)
            }
        }

        try {
            $results = @(Invoke-KatanaCrawl -LiveTargets $liveTargets -ScopeItems @($scopeItem) -KatanaPath 'katana.exe' -RawOutputPath $rawOutputPath -TempDirectory $tempDir -Depth 2 -Threads 1 -TimeoutSeconds 10)
        } finally {
            $script:ScopeForgeContext = $null
        }

        if ($results.Count -ne 1) { throw 'Expected only the reachable live target to be preserved as a synthetic crawl seed.' }
        if ($results[0].Url -ne 'https://app.example.com/') { throw 'Expected the reachable live target URL to remain preserved.' }
        if ($results[0].Source -ne 'seed') { throw 'Expected the preserved reachable target to stay marked as a seed.' }
    }
}

Describe 'ScopeForge HTML report segmentation' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

    It 'separates reachable targets from dead or unstable targets in the HTML report' {
        $outputDir = Join-Path $TestDrive 'report-segmentation-output'
        $layout = Get-OutputLayout -OutputDir $outputDir
        Initialize-OutputDirectories -Layout $layout

        $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName 'html-report-segmentation-test' -Quiet:$true -ExportJsonEnabled:$true -ExportCsvEnabled:$true -ExportHtmlEnabled:$true
        $script:ScopeForgeContext.Triage = [pscustomobject]@{
            FilteredFindings   = @(
                [pscustomobject]@{
                    ReviewKey   = 'https://app.example.com/'
                    Url         = 'https://app.example.com/'
                    StateStatus = 'seen-before'
                    SeenBefore  = $true
                }
            )
            NoiseFindings      = @()
            ReviewableFindings = @()
            Shortlist          = @()
        }

        $summary = [pscustomobject]@{
            ProgramName                   = 'html-report-segmentation-test'
            GeneratedAtUtc                = [DateTimeOffset]::UtcNow.ToString('o')
            ScopeItemCount                = 1
            ExcludedItemCount             = 0
            DiscoveredHostCount           = 1
            LiveHostCount                 = 1
            LiveTargetCount               = 2
            DiscoveredUrlCount            = 1
            InterestingUrlCount           = 0
            ErrorCount                    = 0
            ProtectedInterestingCount     = 0
            UniqueUserAgent               = 'scopeforge-test'
            StatusCodeDistribution        = @([pscustomobject]@{ StatusCode = '200'; Count = 1 })
            TopTechnologies               = @()
            TopSubdomains                 = @()
            TopInterestingCategories      = @()
            TopInterestingFamilies        = @()
            InterestingPriorityDistribution = @()
            ErrorPhaseDistribution        = @()
            ErrorToolDistribution         = @()
            TopAuthReviewable             = @()
            TopApiReviewable              = @()
            TopProtectedReviewable        = @()
        }

        $scopeItems = @(
            [pscustomobject]@{
                Id = 'scope-001'
                Type = 'Domain'
                NormalizedValue = 'app.example.com'
                Exclusions = @()
            }
        )

        $hostsAll = @()
        $hostsLive = @()
        $liveTargets = @(
            [pscustomobject]@{
                Host = 'app.example.com'
                Url = 'https://app.example.com/'
                StatusCode = 200
                Title = 'App'
                Technologies = @('nginx')
            },
            [pscustomobject]@{
                Host = 'app.example.com'
                Url = 'https://app.example.com/missing'
                StatusCode = 404
                Title = '404 Not Found'
                Technologies = @('nginx')
            }
        )
        $discoveredUrls = @(
            [pscustomobject]@{
                Host = 'app.example.com'
                Url = 'https://app.example.com/'
                ScopeId = 'scope-001'
                Source = 'katana'
                StatusCode = 200
            }
        )

        try {
            Export-ReconReport -Summary $summary -ScopeItems $scopeItems -HostsAll $hostsAll -HostsLive $hostsLive -LiveTargets $liveTargets -DiscoveredUrls $discoveredUrls -InterestingUrls @() -Exclusions @() -Errors @() -Layout $layout -ExportHtml -ExportCsv
            $reportHtml = Get-Content -LiteralPath $layout.ReportHtml -Raw -Encoding utf8
            $shortlistMarkdown = Get-Content -LiteralPath $layout.ShortlistMarkdown -Raw -Encoding utf8
            $displayedShortlistJson = @()
            if (Test-Path -LiteralPath $layout.DisplayedShortlistJson) {
                $displayedShortlistJson = @(Get-Content -LiteralPath $layout.DisplayedShortlistJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
            }
            $displayedShortlistCsv = Get-Content -LiteralPath $layout.DisplayedShortlistCsv -Raw -Encoding utf8
            $suggestedAreasJson = @()
            if (Test-Path -LiteralPath $layout.SuggestedAreasJson) {
                $suggestedAreasJson = @(Get-Content -LiteralPath $layout.SuggestedAreasJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
            }
            $suggestedAreasCsv = Get-Content -LiteralPath $layout.SuggestedAreasCsv -Raw -Encoding utf8
            $actionQueueJson = @()
            if (Test-Path -LiteralPath $layout.ActionQueueJson) {
                $actionQueueJson = @(Get-Content -LiteralPath $layout.ActionQueueJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
            }
            $actionQueueCsv = Get-Content -LiteralPath $layout.ActionQueueCsv -Raw -Encoding utf8
            $contentSignalsJson = @()
            if (Test-Path -LiteralPath $layout.ContentSignalsJson) {
                $contentSignalsJson = @(Get-Content -LiteralPath $layout.ContentSignalsJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100)
            }
            $contentSignalsCsv = Get-Content -LiteralPath $layout.ContentSignalsCsv -Raw -Encoding utf8
            $remoteTriageBundle = Get-Content -LiteralPath $layout.RemoteTriageBundleJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
            $runHealthJson = Get-Content -LiteralPath $layout.RunHealthJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
            $runHealthCsv = Get-Content -LiteralPath $layout.RunHealthCsv -Raw -Encoding utf8
        } finally {
            $script:ScopeForgeContext = $null
        }

        if ($reportHtml -notlike '*HTTP Targets*') { throw 'Expected the KPI label to use HTTP Targets.' }
        if ($reportHtml -notlike '*Shortlist <span class="section-count">1</span>*') { throw 'Expected the shortlist quick navigation count to reflect the displayed fallback card.' }
        if ($reportHtml -notlike '*Reachable <span class="section-count">1</span>*') { throw 'Expected the quick navigation to expose one reachable target.' }
        if ($reportHtml -notlike '*Dead / Unstable <span class="section-count">1</span>*') { throw 'Expected the quick navigation to expose one dead or unstable target.' }
        if ($reportHtml -notlike '*No scored shortlist entries were generated; retained reachable targets are shown here for first-pass manual review.*') { throw 'Expected the shortlist section to explain the fallback baseline view.' }
        if ($reportHtml -notlike '*Baseline*') { throw 'Expected the fallback shortlist card to be labeled as baseline.' }
        if ($reportHtml -notlike '*State: seen-before*') { throw 'Expected the fallback shortlist card to surface the triage state when it is known.' }
        if ($reportHtml -notlike '*https://app.example.com/*') { throw 'Expected the fallback shortlist card to expose the reachable URL.' }
        if ($reportHtml -notlike '*Reachable HTTP(S) targets retained after in-scope validation. 1 item(s).*') { throw 'Expected the live section summary to count only reachable targets.' }
        if ($reportHtml -notlike '*Dead or unstable HTTP targets preserved for evidence and noise separation. 1 item(s).*') { throw 'Expected the dead/unstable section summary to be present.' }
        if ($shortlistMarkdown -notlike '*## Baseline Reachable Targets*') { throw 'Expected shortlist markdown to include baseline reachable targets when no scored shortlist exists.' }
        if (-not $shortlistMarkdown.Contains('### [Baseline/200] https://app.example.com/')) { throw 'Expected shortlist markdown to surface the reachable baseline URL.' }
        if ($shortlistMarkdown -notlike '*- State: seen-before*') { throw 'Expected shortlist markdown to surface the baseline triage state when it is known.' }
        if ($displayedShortlistJson.Count -ne 1) { throw 'Expected a single displayed shortlist export entry for the fallback baseline target.' }
        if ($displayedShortlistJson[0].DisplayKind -ne 'Baseline') { throw 'Expected the displayed shortlist export to label the fallback entry as baseline.' }
        if ($displayedShortlistJson[0].IsScored -ne $false) { throw 'Expected the displayed shortlist export to mark the fallback entry as non-scored.' }
        if ($displayedShortlistJson[0].Url -ne 'https://app.example.com/') { throw 'Expected the displayed shortlist export to preserve the baseline reachable URL.' }
        if ($displayedShortlistJson[0].StateStatus -ne 'seen-before') { throw 'Expected the displayed shortlist export to preserve the baseline triage state.' }
        if ($displayedShortlistCsv -notlike '*Baseline*') { throw 'Expected the displayed shortlist CSV to label the baseline entry.' }
        if ($displayedShortlistCsv -notlike '*seen-before*') { throw 'Expected the displayed shortlist CSV to preserve the baseline triage state.' }
        if ($suggestedAreasJson.Count -ne 1) { throw 'Expected a single structured suggested review area export entry.' }
        if ($suggestedAreasJson[0].Area -ne 'Baseline reachable targets') { throw 'Expected the structured suggested review area export to preserve the baseline reachable guidance.' }
        if ($suggestedAreasCsv -notlike '*Baseline reachable targets*') { throw 'Expected the structured suggested review area CSV to preserve the baseline reachable guidance.' }
        if ($actionQueueJson.Count -ne 2) { throw 'Expected the structured action queue to include the baseline target and the matching suggested area.' }
        if ($actionQueueJson[0].EntryType -ne 'Target' -or $actionQueueJson[0].DisplayKind -ne 'Baseline') { throw 'Expected the first action queue entry to be the displayed baseline target.' }
        if ($actionQueueJson[0].StateStatus -ne 'seen-before') { throw 'Expected the action queue to preserve the displayed target triage state.' }
        if ($actionQueueJson[1].EntryType -ne 'Suggestion' -or $actionQueueJson[1].Label -ne 'Baseline reachable targets') { throw 'Expected the second action queue entry to preserve the baseline suggested area.' }
        if ($actionQueueCsv -notlike '*Baseline reachable target*') { throw 'Expected the action queue CSV to preserve the baseline target entry.' }
        if ($actionQueueCsv -notlike '*Baseline reachable targets*') { throw 'Expected the action queue CSV to preserve the suggested area entry.' }
        if ($contentSignalsJson.Count -ne 1) { throw 'Expected one structured content signal export entry for the retained reachable target.' }
        if ($contentSignalsJson[0].SignalStrength -ne 'High') { throw 'Expected the retained reachable baseline signal to be classified as high-value for remote triage.' }
        if ($contentSignalsJson[0].DisplayKind -ne 'Baseline') { throw 'Expected the content signal export to preserve the displayed baseline kind.' }
        if (@($contentSignalsJson[0].SignalTags) -notcontains 'displayed-shortlist') { throw 'Expected the content signal export to preserve the displayed-shortlist tag.' }
        if (@($contentSignalsJson[0].SignalTags) -notcontains 'technology-stack') { throw 'Expected the content signal export to preserve the technology-stack tag.' }
        if (@($contentSignalsJson[0].SignalTags) -notcontains 'triage-state-known') { throw 'Expected the content signal export to preserve the triage-state-known tag.' }
        if ($contentSignalsCsv -notlike '*displayed-shortlist*') { throw 'Expected the content signal CSV to preserve the displayed-shortlist signal tag.' }
        if ($contentSignalsCsv -notlike '*technology-stack*') { throw 'Expected the content signal CSV to preserve the technology-stack signal tag.' }
        if ($runHealthJson.OverallStatus -ne 'Limited') { throw 'Expected the run health export to classify the baseline-only case as limited rather than degraded.' }
        if (@($runHealthJson.Checks | Where-Object { $_.Check -eq 'TriageCoverage' -and $_.Status -eq 'Limited' }).Count -ne 1) { throw 'Expected the run health export to preserve the limited triage coverage check for the baseline-only case.' }
        if ($runHealthCsv -notlike '*TriageCoverage*') { throw 'Expected the run health CSV to preserve the triage coverage check.' }
        if ($runHealthCsv -notlike '*RemoteSupportArtifacts*') { throw 'Expected the run health CSV to preserve the remote support artifact check.' }
        if ($remoteTriageBundle.Summary.DisplayedShortlistCount -ne 1) { throw 'Expected the remote triage bundle to preserve the displayed shortlist count.' }
        if ($remoteTriageBundle.PrimaryAction.Label -ne 'Baseline reachable target') { throw 'Expected the remote triage bundle to expose the primary baseline action directly.' }
        if (@($remoteTriageBundle.ActionQueue).Count -ne 2) { throw 'Expected the remote triage bundle to expose the direct action queue view for remote consumers.' }
        if (@($remoteTriageBundle.HighValueContentSignals).Count -ne 1) { throw 'Expected the remote triage bundle to expose the direct high-value content signals view.' }
        if (@($remoteTriageBundle.ReachableTargets).Count -ne 1) { throw 'Expected the remote triage bundle to expose the direct reachable target snapshot.' }
        if (@($remoteTriageBundle.RuntimeErrors).Count -ne 0) { throw 'Expected the remote triage bundle to expose an empty direct runtime error list in the clean baseline scenario.' }
        if ($remoteTriageBundle.RunHealth.OverallStatus -ne 'Limited') { throw 'Expected the remote triage bundle to embed the run health status directly.' }
        if ($remoteTriageBundle.RemoteQueue.PrimaryAction.Label -ne 'Baseline reachable target') { throw 'Expected the remote triage bundle to preserve the primary baseline action.' }
        if (@($remoteTriageBundle.RemoteQueue.ActionQueue).Count -ne 2) { throw 'Expected the remote triage bundle to preserve the remote action queue entries.' }
        if (@($remoteTriageBundle.Signals.HighValue).Count -ne 1) { throw 'Expected the remote triage bundle to preserve the high-value content signals.' }
        if ($remoteTriageBundle.Signals.HighValue[0].DisplayKind -ne 'Baseline') { throw 'Expected the remote triage bundle to preserve the baseline content signal kind.' }
        if (@($remoteTriageBundle.Targets.Reachable).Count -ne 1) { throw 'Expected the remote triage bundle to preserve the reachable target snapshot.' }
        if ($remoteTriageBundle.Paths.ActionQueueJson -ne $layout.ActionQueueJson) { throw 'Expected the remote triage bundle to expose the action queue path for remote support.' }
        if ($remoteTriageBundle.Paths.RunHealthJson -ne $layout.RunHealthJson) { throw 'Expected the remote triage bundle to expose the run health path for remote support.' }
    }
}

Describe 'ScopeForge suggested review areas' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

    It 'prefers baseline reachable guidance over the generic fallback when no scored findings exist but reachable targets remain' {
        $suggestions = @(Get-SuggestedReviewAreas -InterestingUrls @() -LiveTargets @(
                [pscustomobject]@{
                    Host         = 'app.example.com'
                    Url          = 'https://app.example.com/'
                    StatusCode   = 200
                    Title        = 'Example App'
                    ContentType  = 'text/html'
                    Technologies = @('nginx')
                }
            ) -Errors @())

        if (@($suggestions | Where-Object { $_.Area -eq 'Baseline reachable targets' }).Count -ne 1) { throw 'Expected a dedicated baseline reachable suggestion when no scored findings exist.' }
        if (@($suggestions | Where-Object { $_.Area -eq 'General manual review' }).Count -ne 0) { throw 'Expected the generic fallback to stay hidden when a baseline reachable suggestion exists.' }
    }
}

Describe 'ScopeForge bootstrap cache coherence' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

    It 'prefers newer local workspace files over a stale temp bootstrap cache' {
        $bootstrapRoot = Join-Path $TestDrive 'ScopeForge-Bootstrap'
        $filesToFetch = @('ScopeForge.ps1', 'Launch-ScopeForge.ps1')
        $null = New-Item -ItemType Directory -Path $bootstrapRoot -Force

        foreach ($relativePath in $filesToFetch) {
            $targetPath = Join-Path $bootstrapRoot $relativePath
            $targetDirectory = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDirectory)) {
                $null = New-Item -ItemType Directory -Path $targetDirectory -Force
            }
            Set-Content -LiteralPath $targetPath -Value 'stale bootstrap cache' -Encoding utf8
            (Get-Item -LiteralPath $targetPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddYears(-10)
        }

        $localSourceRoot = Get-LocalBootstrapSourceRoot -BootstrapRoot $bootstrapRoot -FilesToFetch $filesToFetch
        $refreshPlan = Get-LocalBootstrapRefreshPlan -BootstrapRoot $bootstrapRoot -SourceRoot $localSourceRoot -FilesToFetch $filesToFetch

        if (-not $localSourceRoot) { throw 'Expected the local workspace root to be detected when the bootstrap runs from the repository checkout.' }
        if ($localSourceRoot -ne $repoRoot.Path) { throw 'Expected the detected local bootstrap source root to match the repository root.' }
        if (-not $refreshPlan.WillRefresh) { throw 'Expected the stale bootstrap cache to be refreshed from the newer local workspace files.' }
        if ($refreshPlan.NewerFiles -notcontains 'ScopeForge.ps1') { throw 'Expected ScopeForge.ps1 to be flagged as newer in the local workspace.' }
        if ($refreshPlan.VersionCheckStatus -ne 'Local workspace source detected.') { throw 'Expected the local workspace version check status to be explicit.' }
    }
}

Describe 'ScopeForge summary reachability split' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

    It 'exports reachable and dead-or-unstable target counts in summaries and triage markdown' {
        $summary = Merge-ReconResults -ScopeItems @([pscustomobject]@{ Id = 'scope-001' }) -HostsAll @([pscustomobject]@{ Host = 'app.example.com' }) -LiveTargets @(
            [pscustomobject]@{ Host = 'app.example.com'; Url = 'https://app.example.com/'; StatusCode = 200; Technologies = @('Apache HTTP Server', 'YouTube') },
            [pscustomobject]@{ Host = 'app.example.com'; Url = 'https://app.example.com/missing'; StatusCode = 404; Technologies = @('Apache HTTP Server') },
            [pscustomobject]@{ Host = 'app.example.com'; Url = 'https://app.example.com/gone'; StatusCode = 410; Technologies = @('Apache HTTP Server') }
        ) -DiscoveredUrls @() -InterestingUrls @() -Exclusions @() -Errors @() -ProgramName 'summary-split-test' -UniqueUserAgent 'scopeforge-test'

        if ($summary.LiveTargetCount -ne 3) { throw 'Expected the total HTTP target count to stay unchanged.' }
        if ($summary.ReachableTargetCount -ne 1) { throw 'Expected one reachable target in the summary split.' }
        if ($summary.DeadOrUnstableTargetCount -ne 2) { throw 'Expected two dead or unstable targets in the summary split.' }
        if ($summary.ShortlistCount -ne 0) { throw 'Expected the scored shortlist count to remain zero without reviewable findings.' }
        if ($summary.BaselineShortlistCount -ne 1) { throw 'Expected one baseline shortlist entry when no scored shortlist exists.' }
        if ($summary.DisplayedShortlistCount -ne 1) { throw 'Expected the displayed shortlist count to expose the fallback baseline entry.' }
        if (@($summary.ReachableTopTechnologies | Where-Object { $_.Technology -eq 'Apache HTTP Server' -and $_.Count -eq 1 }).Count -ne 1) { throw 'Expected reachable technologies to count only reachable targets.' }
        if (@($summary.ReachableTopTechnologies | Where-Object { $_.Technology -eq 'YouTube' -and $_.Count -eq 1 }).Count -ne 1) { throw 'Expected reachable technologies to preserve unique reachable stack signals.' }

        $outputDir = Join-Path $TestDrive 'summary-split-output'
        $layout = Get-OutputLayout -OutputDir $outputDir
        Initialize-OutputDirectories -Layout $layout
        Export-TriageMarkdownReport -Summary $summary -InterestingUrls @() -InterestingFamilies @() -LiveTargets @() -Exclusions @() -Errors @() -Layout $layout
        $triageMarkdown = Get-Content -LiteralPath $layout.TriageMarkdown -Raw -Encoding utf8
        Export-ReconReport -Summary $summary -ScopeItems @() -HostsAll @() -HostsLive @() -LiveTargets @() -DiscoveredUrls @() -InterestingUrls @() -Exclusions @() -Errors @() -Layout $layout -ExportCsv
        $summaryCsv = Get-Content -LiteralPath $layout.SummaryCsv -Raw -Encoding utf8

        if ($triageMarkdown -notlike '*- HTTP targets: 3*') { throw 'Expected triage markdown to expose the total HTTP target count.' }
        if ($triageMarkdown -notlike '*- Reachable targets: 1*') { throw 'Expected triage markdown to expose the reachable target count.' }
        if ($triageMarkdown -notlike '*- Dead or unstable targets: 2*') { throw 'Expected triage markdown to expose the dead or unstable target count.' }
        if ($triageMarkdown -notlike '*- Scored shortlist entries: 0*') { throw 'Expected triage markdown to expose the scored shortlist count.' }
        if ($triageMarkdown -notlike '*- Displayed shortlist entries: 1*') { throw 'Expected triage markdown to expose the displayed shortlist count.' }
        if ($triageMarkdown -notlike '*- Baseline shortlist fallback: 1*') { throw 'Expected triage markdown to expose the baseline shortlist count.' }
        if ($summaryCsv -notlike '*"ShortlistCount","0"*') { throw 'Expected summary CSV to keep the scored shortlist count.' }
        if ($summaryCsv -notlike '*"BaselineShortlistCount","1"*') { throw 'Expected summary CSV to export the baseline shortlist count.' }
        if ($summaryCsv -notlike '*"DisplayedShortlistCount","1"*') { throw 'Expected summary CSV to export the displayed shortlist count.' }
        if ($triageMarkdown -notlike '*## Reachable Technology Signals*') { throw 'Expected triage markdown to expose reachable technology signals.' }
        if ($triageMarkdown -notlike '*- Apache HTTP Server: 1*') { throw 'Expected triage markdown to list reachable technology counts only.' }
        if ($triageMarkdown -notlike '*- YouTube: 1*') { throw 'Expected triage markdown to include additional reachable technologies.' }
    }
}

Describe 'ScopeForge httpx diagnostics' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
        . (Join-Path $script:repoRoot 'Launch-ScopeForgeFromGitHub.ps1')
    }

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

        Mock Invoke-ExternalCommandArgumentSafe {
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

            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = ($lines -join [Environment]::NewLine)
                StdErr    = ''
                FilePath  = 'httpx.exe'
                Arguments = @()
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
        Mock Invoke-ExternalCommandArgumentSafe {
            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = ''
                StdErr    = ''
                FilePath  = 'httpx.exe'
                Arguments = @()
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

    It 'uses direct stdio capture for httpx batches without falling back to redirected execution' {
        $scopeItem = [pscustomobject]@{
            Id               = 'scope-001'
            Index            = 1
            Type             = 'URL'
            OriginalValue    = 'https://app.example.com/'
            NormalizedValue  = 'https://app.example.com/'
            Scheme           = 'https'
            Host             = 'app.example.com'
            Port             = $null
            RootDomain       = 'app.example.com'
            PathPrefix       = '/'
            StartUrl         = 'https://app.example.com/'
            IncludeApex      = $false
            Exclusions       = @()
            HostRegexString  = '^app\.example\.com$'
            ScopeRegexString = ''
            Description      = 'URL seed https://app.example.com/'
        }

        $script:httpxRedirectedInvocationCount = 0
        Mock Invoke-ExternalCommand {
            $script:httpxRedirectedInvocationCount++
            throw 'Invoke-ExternalCommand should not be used for httpx batch probing.'
        }

        Mock Invoke-ExternalCommandArgumentSafe {
            $script:httpxDirectInvocationCount = $(if (Get-Variable -Name httpxDirectInvocationCount -Scope Script -ErrorAction SilentlyContinue) { $script:httpxDirectInvocationCount + 1 } else { 1 })
            $jsonLine = ([pscustomobject]@{
                    input         = 'https://app.example.com/'
                    url           = 'https://app.example.com/api/profile'
                    title         = 'Profile API'
                    status_code   = 200
                    content_type  = 'application/json'
                    content_length = 123
                    webserver     = 'nginx'
                    tech          = @('nginx', 'React')
                } | ConvertTo-Json -Compress)

            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = $jsonLine
                StdErr    = ''
                FilePath  = 'httpx.exe'
                Arguments = @()
            }
        }

        $liveTargets = @(Invoke-HttpProbe -InputUrls @('https://app.example.com/') -ScopeItems @($scopeItem) -HttpxPath 'httpx.exe' -RawOutputPath $script:ScopeForgeContext.Layout.HttpxRaw -Threads 1 -TimeoutSeconds 10)
        $batchLog = Get-Content -LiteralPath $script:ScopeForgeContext.Layout.HttpxBatchLog -Raw -Encoding utf8

        if ($liveTargets.Count -ne 1) { throw 'Expected the direct stdio capture to retain one live target.' }
        if ($liveTargets[0].Url -ne 'https://app.example.com/api/profile') { throw 'Expected the retained target URL to come from the direct stdio capture.' }
        if ($liveTargets[0].Title -ne 'Profile API') { throw 'Expected the retained target title to be preserved.' }
        if ($liveTargets[0].Technologies.Count -ne 2) { throw 'Expected the retained technologies to be preserved.' }
        if ($script:httpxDirectInvocationCount -ne 1) { throw 'Expected httpx to run exactly once via direct stdio capture.' }
        if ($script:httpxRedirectedInvocationCount -ne 0) { throw 'Expected redirected process capture to stay unused for httpx.' }
        if ($batchLog -notlike '*BATCH|index=1/1|input=1|stdout_lines=1|exit=0*') {
            throw ("Expected the batch log to reflect the direct stdout line. Actual log: {0}" -f $batchLog)
        }
    }

    It 'retries gau once with a higher timeout after an initial timeout' {
        $rawOutputPath = Join-Path $TestDrive 'gau-raw.txt'
        $script:gauTimeoutAttempts = @()
        $script:gauWarnings = @()
        $script:gauErrorRecords = @()

        Mock Write-ReconLog {
            param($Level, $Message)
            if ($Level -eq 'WARN') {
                $script:gauWarnings += [string]$Message
            }
        }

        Mock Add-ErrorRecord {
            param($Phase, $Target, $Message, $Details, $Tool, $ExitCode, $ErrorCode)
            $script:gauErrorRecords += [pscustomobject]@{
                Phase     = $Phase
                Target    = $Target
                Message   = $Message
                Tool      = $Tool
                ExitCode  = $ExitCode
                ErrorCode = $ErrorCode
            }
        }

        Mock Invoke-ExternalCommand {
            param($FilePath, $Arguments, $TimeoutSeconds, $StdOutPath, $StdErrPath, $IgnoreExitCode)

            $script:gauTimeoutAttempts += [int]$TimeoutSeconds
            if ($script:gauTimeoutAttempts.Count -eq 1) {
                throw 'Command timed out after 120 seconds: gau.exe'
            }

            Set-Content -LiteralPath $StdOutPath -Value @(
                'https://example.com/login'
                'https://example.com/api/docs'
                'not-a-url'
            ) -Encoding utf8
            Set-Content -LiteralPath $StdErrPath -Value '' -Encoding utf8

            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = ''
                StdErr    = ''
                FilePath  = $FilePath
                Arguments = @($Arguments)
            }
        }

        $urls = @(Get-HistoricalUrls -Target 'example.com' -GauPath 'gau.exe' -RawOutputPath $rawOutputPath -TimeoutSeconds 30)
        $rawOutput = Get-Content -LiteralPath $rawOutputPath -Raw -Encoding utf8

        if ($script:gauTimeoutAttempts.Count -ne 2) { throw 'Expected gau to retry exactly once after a timeout.' }
        if ($script:gauTimeoutAttempts[0] -ne 120) { throw 'Expected the initial gau timeout to stay bounded at 120 seconds.' }
        if ($script:gauTimeoutAttempts[1] -ne 240) { throw 'Expected the retry gau timeout to increase to 240 seconds.' }
        if ($script:gauWarnings -notlike '*Nouvelle tentative avec timeout=240s.*') { throw 'Expected a retry warning that surfaces the increased gau timeout.' }
        if ($script:gauErrorRecords.Count -ne 0) { throw 'Expected a successful gau retry to avoid recording a historical discovery error.' }
        if ($urls.Count -ne 2) { throw 'Expected the successful gau retry to retain the two valid historical URLs.' }
        if ($urls -notcontains 'https://example.com/login') { throw 'Expected the successful gau retry to keep the first historical URL.' }
        if ($urls -notcontains 'https://example.com/api/docs') { throw 'Expected the successful gau retry to keep the second historical URL.' }
        if ($rawOutput -notlike '*https://example.com/login*') { throw 'Expected the raw gau output to preserve the retried stdout.' }
        if ($rawOutput -notlike '*https://example.com/api/docs*') { throw 'Expected the raw gau output to preserve all successful retried URLs.' }
    }
}
