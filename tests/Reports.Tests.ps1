$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repoRoot 'ScopeForge.ps1')

Describe 'ScopeForge reports' {
    It 'generates self-contained HTML and actionable triage markdown' {
        $layout = Get-OutputLayout -OutputDir (Join-Path $TestDrive 'output')
        Initialize-OutputDirectories -Layout $layout

        $summary = [pscustomobject]@{
            ProgramName                  = 'demo'
            GeneratedAtUtc               = '2026-03-26T12:00:00Z'
            PowerShellVersion            = '7.5.0'
            ScopeItemCount               = 1
            ExcludedItemCount            = 1
            DiscoveredHostCount          = 2
            LiveHostCount                = 1
            LiveTargetCount              = 1
            ReachableTargetCount         = 1
            DeadOrUnstableTargetCount    = 0
            DiscoveredUrlCount           = 2
            InterestingUrlCount          = 1
            ProtectedInterestingCount    = 1
            ErrorCount                   = 1
            UniqueUserAgent              = 'scopeforge-test'
            StatusCodeDistribution       = @([pscustomobject]@{ StatusCode = 403; Count = 1 })
            TopTechnologies              = @([pscustomobject]@{ Technology = 'nginx'; Count = 1 })
            ReachableTopTechnologies     = @([pscustomobject]@{ Technology = 'nginx'; Count = 1 })
            TopSubdomains                = @([pscustomobject]@{ Host = 'app.example.com'; Count = 1 })
            TopInterestingCategories     = @([pscustomobject]@{ Category = 'Auth'; Count = 1 })
            TopInterestingFamilies       = @([pscustomobject]@{ Family = 'Access'; Count = 1 })
            InterestingPriorityDistribution = @([pscustomobject]@{ Priority = 'High'; Count = 1 })
            ErrorPhaseDistribution       = @([pscustomobject]@{ Phase = 'Probe'; Count = 1 })
            ErrorToolDistribution        = @([pscustomobject]@{ Tool = 'httpx'; Count = 1 })
            TopAuthReviewable            = @('https://app.example.com/login')
            TopApiReviewable             = @()
            TopProtectedReviewable       = @('https://app.example.com/login')
        }

        $scopeItems = @(
            [pscustomobject]@{
                Id              = 'scope-001'
                Type            = 'Wildcard'
                NormalizedValue = 'https://*.example.com'
                Exclusions      = @('dev', 'staging')
            }
        )
        $liveTargets = @(
            [pscustomobject]@{
                Host         = 'app.example.com'
                Url          = 'https://app.example.com/login'
                StatusCode   = 403
                Title        = 'Sign in'
                Technologies = @('nginx')
            }
        )
        $discoveredUrls = @(
            [pscustomobject]@{
                Host       = 'app.example.com'
                Url        = 'https://app.example.com/login'
                ScopeId    = 'scope-001'
                StatusCode = 403
                Source     = 'katana'
            }
        )
        $interestingUrls = @(
            [pscustomobject]@{
                Priority     = 'High'
                PriorityRank = 2
                Score        = 95
                PrimaryFamily = 'Access'
                Url          = 'https://app.example.com/login'
                Host         = 'app.example.com'
                StatusCode   = 403
                ContentType  = 'text/html'
                Categories   = @('Auth', 'Protected')
                Reasons      = @('login route', '403 status')
                Technologies = @('nginx')
                Title        = 'Sign in'
            }
        )
        $exclusions = @(
            [pscustomobject]@{
                Phase     = 'TargetGeneration'
                ScopeId   = 'scope-001'
                Target    = 'https://dev.example.com'
                Token     = 'dev'
                MatchedOn = 'Host'
            }
        )
        $errors = @(
            [pscustomobject]@{
                Phase          = 'Probe'
                Tool           = 'httpx'
                ErrorCode      = 'ToolExitCode'
                Target         = 'https://app.example.com/login'
                Message        = 'httpx exited with code 1'
                Recommendation = 'Inspect tools.log.'
            }
        )

        Export-ReconReport `
            -Summary $summary `
            -ScopeItems $scopeItems `
            -HostsAll @() `
            -HostsLive @() `
            -LiveTargets $liveTargets `
            -DiscoveredUrls $discoveredUrls `
            -InterestingUrls $interestingUrls `
            -Exclusions $exclusions `
            -Errors $errors `
            -Layout $layout `
            -ExportHtml

        if (-not (Test-Path -LiteralPath $layout.ReportHtml)) { throw 'Expected report.html to be generated.' }
        if (-not (Test-Path -LiteralPath $layout.TriageMarkdown)) { throw 'Expected triage.md to be generated.' }

        $html = Get-Content -LiteralPath $layout.ReportHtml -Raw -Encoding utf8
        $markdown = Get-Content -LiteralPath $layout.TriageMarkdown -Raw -Encoding utf8

        foreach ($expected in @('Next Actions', 'Excluded', 'Live Targets')) {
            if ($html -notlike "*$expected*") { throw "Expected report.html to contain '$expected'." }
        }
        foreach ($expected in @('section-excluded', 'section-live', 'section-interesting', 'Shortlist')) {
            if ($html -notlike "*$expected*") { throw "Expected report.html structure to contain '$expected'." }
        }
        foreach ($expected in @('## Exclusion Summary', '## Error Summary', '## Suggested Test Areas')) {
            if ($markdown -notlike "*$expected*") { throw "Expected triage.md to contain '$expected'." }
        }
    }

    It 'preserves single-item collections as JSON arrays' {
        $jsonPath = Join-Path $TestDrive 'single-item.json'

        Write-JsonFile -Path $jsonPath -Data @(
            [pscustomobject]@{
                Id   = 'scope-001'
                Host = 'app.example.com'
            }
        )

        $json = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8
        if (-not $json.TrimStart().StartsWith('[')) { throw 'Expected Write-JsonFile to preserve array brackets for a single item.' }

        $parsed = @(Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10)
        if ($parsed.Count -ne 1) { throw 'Expected the serialized JSON array to contain exactly one item.' }
        if ($parsed[0].Id -ne 'scope-001') { throw 'Expected the serialized JSON item to preserve its content.' }
    }

    It 'generates run health JSON with overall status' {
        $layout = Get-OutputLayout -OutputDir (Join-Path $TestDrive 'output-health')
        Initialize-OutputDirectories -Layout $layout

        $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName 'health-test' -Quiet:$true `
            -ExportJsonEnabled:$true -ExportCsvEnabled:$true -ExportHtmlEnabled:$true
        $script:ScopeForgeContext.Triage = [pscustomobject]@{
            FilteredFindings   = @()
            NoiseFindings      = @()
            ReviewableFindings = @()
            Shortlist          = @()
        }

        try {
            $summary = [pscustomobject]@{
                ProgramName                     = 'health-test'
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
                UniqueUserAgent                 = 'test'
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

            Export-ReconReport -Summary $summary -ScopeItems @() -HostsAll @() -HostsLive @() `
                -LiveTargets @() -DiscoveredUrls @() -InterestingUrls @() `
                -Exclusions @() -Errors @() -Layout $layout -ExportJson

            if (-not (Test-Path -LiteralPath $layout.RunHealthJson)) { throw 'Expected run_health.json to be generated.' }
            $health = Get-Content -LiteralPath $layout.RunHealthJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
            if ($health.OverallStatus -notin @('Healthy', 'Limited', 'Degraded')) { throw 'Expected OverallStatus to be a valid status.' }
            if (-not $health.Checks) { throw 'Expected health checks to be populated.' }
        } finally {
            $script:ScopeForgeContext = $null
        }
    }

    It 'ensures remote triage bundle has required top-level fields' {
        $layout = Get-OutputLayout -OutputDir (Join-Path $TestDrive 'output-bundle')
        Initialize-OutputDirectories -Layout $layout

        $script:ScopeForgeContext = New-ScopeForgeContext -Layout $layout -ProgramName 'bundle-test' -Quiet:$true `
            -ExportJsonEnabled:$true -ExportCsvEnabled:$true -ExportHtmlEnabled:$true
        $script:ScopeForgeContext.Triage = [pscustomobject]@{
            FilteredFindings   = @()
            NoiseFindings      = @()
            ReviewableFindings = @()
            Shortlist          = @()
        }

        try {
            $summary = [pscustomobject]@{
                ProgramName                     = 'bundle-test'
                GeneratedAtUtc                  = [DateTimeOffset]::UtcNow.ToString('o')
                ScopeItemCount                  = 1
                ExcludedItemCount               = 0
                DiscoveredHostCount             = 0
                LiveHostCount                   = 0
                LiveTargetCount                 = 0
                ReachableTargetCount            = 0
                DeadOrUnstableTargetCount       = 0
                DiscoveredUrlCount              = 0
                InterestingUrlCount             = 0
                ErrorCount                      = 0
                ProtectedInterestingCount       = 0
                UniqueUserAgent                 = 'test'
                StatusCodeDistribution          = @()
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

            Export-ReconReport -Summary $summary -ScopeItems @() -HostsAll @() -HostsLive @() `
                -LiveTargets @() -DiscoveredUrls @() -InterestingUrls @() `
                -Exclusions @() -Errors @() -Layout $layout -ExportJson

            if (-not (Test-Path -LiteralPath $layout.RemoteTriageBundleJson)) { throw 'Expected remote_triage_bundle.json to be generated.' }
            $bundle = Get-Content -LiteralPath $layout.RemoteTriageBundleJson -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10

            foreach ($field in @('GeneratedAtUtc', 'ProgramName', 'Summary', 'RunHealth', 'Paths', 'Signals', 'Targets', 'Errors')) {
                if ($null -eq $bundle.$field) { throw "Expected remote triage bundle to contain field '$field'." }
            }
        } finally {
            $script:ScopeForgeContext = $null
        }
    }
}
