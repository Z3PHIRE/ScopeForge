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
            DiscoveredUrlCount           = 2
            InterestingUrlCount          = 1
            ProtectedInterestingCount    = 1
            ErrorCount                   = 1
            StatusCodeDistribution       = @([pscustomobject]@{ StatusCode = 403; Count = 1 })
            TopTechnologies              = @([pscustomobject]@{ Technology = 'nginx'; Count = 1 })
            TopSubdomains                = @([pscustomobject]@{ Host = 'app.example.com'; Count = 1 })
            TopInterestingCategories     = @([pscustomobject]@{ Category = 'Auth'; Count = 1 })
            TopInterestingFamilies       = @([pscustomobject]@{ Family = 'Access'; Count = 1 })
            InterestingPriorityDistribution = @([pscustomobject]@{ Priority = 'High'; Count = 1 })
            ErrorPhaseDistribution       = @([pscustomobject]@{ Phase = 'Probe'; Count = 1 })
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

        foreach ($expected in @('Next Actions', 'Exclusion Tokens', 'Live Targets')) {
            if ($html -notlike "*$expected*") { throw "Expected report.html to contain '$expected'." }
        }
        foreach ($expected in @('## Exclusion Summary', '## Error Summary', '## Suggested Test Areas')) {
            if ($markdown -notlike "*$expected*") { throw "Expected triage.md to contain '$expected'." }
        }
    }
}
