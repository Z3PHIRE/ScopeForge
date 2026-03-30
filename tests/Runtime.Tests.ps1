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
}
