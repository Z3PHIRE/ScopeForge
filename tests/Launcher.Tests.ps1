$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repoRoot 'Launch-ScopeForge.ps1')
. (Join-Path $repoRoot 'ScopeForge.ps1')

function Get-TestFixtureContent {
    param([Parameter(Mandatory)][string]$Name)

    return [System.IO.File]::ReadAllText((Join-Path $repoRoot ("tests\fixtures\{0}" -f $Name)))
}

Describe 'ScopeForge launcher boolean handling' {
    Context 'ConvertTo-LauncherBoolean' {
        It 'keeps native booleans unchanged' {
            if (-not (ConvertTo-LauncherBoolean -Value $true)) { throw 'Expected $true to stay $true.' }
            if (ConvertTo-LauncherBoolean -Value $false) { throw 'Expected $false to stay $false.' }
        }

        It 'accepts legacy string and numeric boolean values' {
            if (-not (ConvertTo-LauncherBoolean -Value 'true' -Name 'quiet')) { throw 'Expected string true to convert to $true.' }
            if (ConvertTo-LauncherBoolean -Value 'false' -Name 'quiet') { throw 'Expected string false to convert to $false.' }
            if (-not (ConvertTo-LauncherBoolean -Value '1' -Name 'quiet')) { throw 'Expected string 1 to convert to $true.' }
            if (ConvertTo-LauncherBoolean -Value '0' -Name 'quiet') { throw 'Expected string 0 to convert to $false.' }
        }

        It 'rejects invalid boolean text with a clear error' {
            try {
                ConvertTo-LauncherBoolean -Value 'System.String' -Name 'quiet' | Out-Null
                throw "Expected invalid boolean text for 'quiet' to fail."
            } catch {
                if ($_.Exception.Message -notlike "*Champ 'quiet' invalide*") { throw }
            }
        }
    }

    Context 'Guidance helpers' {
        It 'marks dictionary support as not proven in the current version' {
            $status = Get-LauncherDictionarySupportStatus
            if ($status.Status -ne 'not_proven') { throw 'Expected dictionary support to stay not proven.' }
            if ($status.DisplayLabel -notlike '*Non pris en charge*') { throw 'Expected a clear user-facing dictionary support label.' }
        }

        It 'summarizes a mixed scope composition' {
            $scopeItems = @(
                [pscustomobject]@{ Type = 'Domain'; Exclusions = @() },
                [pscustomobject]@{ Type = 'Wildcard'; Exclusions = @('dev', 'staging') },
                [pscustomobject]@{ Type = 'URL'; Exclusions = @('beta') }
            )

            $summary = Get-LauncherScopeComposition -ScopeItems $scopeItems
            if ($summary.DomainCount -ne 1) { throw 'Expected one Domain item.' }
            if ($summary.WildcardCount -ne 1) { throw 'Expected one Wildcard item.' }
            if ($summary.UrlCount -ne 1) { throw 'Expected one URL item.' }
            if ($summary.TotalExclusions -ne 3) { throw 'Expected exclusion count to be aggregated.' }
            if (-not $summary.MixedTypes) { throw 'Expected the scope to be marked as mixed.' }
        }

        It 'produces an approximate time band from scope and run settings' {
            $scopeItems = @(
                [pscustomobject]@{ Type = 'Wildcard'; Exclusions = @('dev', 'qa') },
                [pscustomobject]@{ Type = 'URL'; Exclusions = @() },
                [pscustomobject]@{ Type = 'Domain'; Exclusions = @() }
            )
            $runConfig = @{
                Depth             = 4
                Threads           = 10
                EnableGau         = $true
                EnableWaybackUrls = $true
                EnableHakrawler   = $true
                IncludeApex       = $false
                Resume            = $false
            }

            $estimate = Get-LauncherApproximateTimeEstimate -ScopeItems $scopeItems -RunConfig $runConfig
            if ($estimate.Band -notin @('Tres court', 'Court', 'Moyen', 'Long', 'Tres long')) { throw 'Expected a supported estimate band.' }
            if ($estimate.ReasonText -notlike '*wildcard*' -and $estimate.ReasonText -notlike '*crawl*') { throw 'Expected the estimate to explain at least one visible factor.' }
        }

        It 'generates a START-HERE guide that explains scope types and next steps' {
            $content = Get-LauncherStartHereContent `
                -ScopePath 'C:\Temp\ScopeForge\01-scope.json' `
                -SettingsPath 'C:\Temp\ScopeForge\02-run-settings.json' `
                -DefaultOutputDir '.\output' `
                -ManagedScopeFile:$false

            foreach ($snippet in @('1. Domain', '2. Wildcard', '3. URL', 'Etape 2 - Construire un scope avec plusieurs cibles', 'Dictionnaires / wordlists', 'Le launcher valide les fichiers')) {
                if ($content -notlike ("*{0}*" -f $snippet)) {
                    throw ("Expected START-HERE content to contain '{0}'." -f $snippet)
                }
            }
        }

        It 'renders the pre-run summary without throwing' {
            $scopeItems = @(
                [pscustomobject]@{ Id = 'scope-001'; Type = 'Domain'; NormalizedValue = 'app.example.com'; Exclusions = @() },
                [pscustomobject]@{ Id = 'scope-002'; Type = 'Wildcard'; NormalizedValue = 'https://*.example.com'; Exclusions = @('dev', 'staging') },
                [pscustomobject]@{ Id = 'scope-003'; Type = 'URL'; NormalizedValue = 'https://api.example.com/v1'; Exclusions = @() }
            )
            $runConfig = @{
                OutputDir         = '.\output'
                Resume            = $false
                EnableGau         = $true
                EnableWaybackUrls = $true
                EnableHakrawler   = $true
                Depth             = 3
                Threads           = 10
                IncludeApex       = $false
            }

            Show-LauncherPreRunSummary -ScopeItems $scopeItems -RunConfig $runConfig
        }

        It 'distinguishes editable managed scopes from templates' {
            $workspace = [pscustomobject]@{
                RepoRoot         = $TestDrive
                ScopesRoot       = Join-Path $TestDrive 'scopes'
                Incoming         = Join-Path $TestDrive 'scopes\\incoming'
                Active           = Join-Path $TestDrive 'scopes\\active'
                Archived         = Join-Path $TestDrive 'scopes\\archived'
                Templates        = Join-Path $TestDrive 'scopes\\templates'
                TemplatesGuide   = Join-Path $TestDrive 'scopes\\templates\\README.md'
                StateRoot        = Join-Path $TestDrive 'state'
                RecentScopesPath = Join-Path $TestDrive 'state\\recent-scopes.json'
            }
            Mock Get-LauncherFileWorkspace { $workspace }
            $null = Initialize-LauncherFileWorkspace

            $activeScope = Join-Path $workspace.Active 'active.json'
            $templateScope = Join-Path $workspace.Templates 'template.json'
            Set-Content -LiteralPath $activeScope -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'
            Set-Content -LiteralPath $templateScope -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            if (-not (Test-LauncherEditableManagedScopePath -Path $activeScope)) { throw 'Expected active scopes to stay editable in place.' }
            if (Test-LauncherEditableManagedScopePath -Path $templateScope) { throw 'Expected templates to be copied into a session instead of being edited in place.' }
        }

        It 'prefers the selected scope path when updating recent scopes' {
            $selectedScope = Join-Path $TestDrive 'selected.json'
            $managedScope = Join-Path $TestDrive 'managed.json'
            $sessionScope = Join-Path $TestDrive 'session.json'
            foreach ($path in @($selectedScope, $managedScope, $sessionScope)) {
                Set-Content -LiteralPath $path -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'
            }

            $updatePath = Get-LauncherRecentScopeUpdatePath -RunConfig @{
                LauncherSelectedScopePath = $selectedScope
                ManagedScopeFile          = $managedScope
                ScopeFile                 = $sessionScope
            }

            if ($updatePath -ne (Resolve-LauncherScopePath -Path $selectedScope)) {
                throw 'Expected recent scope updates to prefer the user-selected scope path.'
            }
        }
    }

    Context 'Build-DocumentRunConfig' {
        BeforeEach {
            $script:launcherSettingsJson = $null

            Mock New-LauncherDocumentSet {
                [pscustomobject]@{
                    RootPath     = 'C:\Temp\ScopeForge\Session'
                    ReadmePath   = 'C:\Temp\ScopeForge\Session\README.md'
                    ScopePath    = 'C:\Temp\ScopeForge\Session\01-scope.json'
                    SettingsPath = 'C:\Temp\ScopeForge\Session\02-run-settings.json'
                }
            }

            Mock Open-LauncherDocument { }
            Mock Write-LauncherSection { }
            Mock Write-Host { }
            Mock Read-ScopeFile {
                @([pscustomobject]@{
                    Type       = 'Domain'
                    Value      = 'example.com'
                    Exclusions = @()
                })
            }
            Mock Get-LauncherPreset {
                [pscustomobject]@{
                    Name               = 'balanced'
                    Description        = 'Balanced'
                    Depth              = 3
                    Threads            = 10
                    TimeoutSeconds     = 30
                    RespectSchemeOnly  = $false
                    Resume             = $false
                    SuggestedDepth     = 0
                    SuggestedThreads   = 0
                    ForceRespectSchemeOnly = $false
                    ForceResume        = $false
                }
            }
            Mock Get-LauncherProgramProfile {
                [pscustomobject]@{
                    Name               = 'webapp'
                    Description        = 'Web application'
                    SourceExplanation  = 'Default webapp profile'
                    UseGau             = $true
                    UseWaybackUrls     = $true
                    UseHakrawler       = $true
                    SuggestedDepth     = 0
                    SuggestedThreads   = 0
                    ForceRespectSchemeOnly = $false
                    ForceResume        = $false
                }
            }
            Mock Get-Content { $script:launcherSettingsJson }
        }

        It 'normalizes native JSON booleans into native PowerShell booleans' {
            $script:launcherSettingsJson = @'
{
  "preset": "balanced",
  "profile": "webapp",
  "programName": "demo",
  "outputDir": "./output",
  "depth": 4,
  "threads": 12,
  "timeoutSeconds": 45,
  "uniqueUserAgent": "ua-test",
  "includeApex": true,
  "respectSchemeOnly": false,
  "enableGau": true,
  "enableWaybackUrls": false,
  "enableHakrawler": true,
  "noInstall": false,
  "quiet": true,
  "resume": true,
  "openReportOnFinish": false
}
'@

            $result = Build-DocumentRunConfig `
                -InitialScopeFile '.\scope.json' `
                -ProgramName 'demo' `
                -OutputDir '.\output' `
                -Depth 3 `
                -UniqueUserAgent 'ua-test' `
                -Threads 10 `
                -TimeoutSeconds 30 `
                -EnableGau $true `
                -EnableWaybackUrls $true `
                -EnableHakrawler $true `
                -NoInstall $false `
                -Quiet $false `
                -IncludeApex $false `
                -RespectSchemeOnly $false `
                -Resume $false `
                -OpenReportOnFinish $false

            if (-not $result.IncludeApex) { throw 'Expected IncludeApex to be $true.' }
            if ($result.RespectSchemeOnly) { throw 'Expected RespectSchemeOnly to be $false.' }
            if (-not $result.EnableGau) { throw 'Expected EnableGau to be $true.' }
            if ($result.EnableWaybackUrls) { throw 'Expected EnableWaybackUrls to be $false.' }
            if (-not $result.EnableHakrawler) { throw 'Expected EnableHakrawler to be $true.' }
            if ($result.NoInstall) { throw 'Expected NoInstall to be $false.' }
            if (-not $result.Quiet) { throw 'Expected Quiet to be $true.' }
            if (-not $result.Resume) { throw 'Expected Resume to be $true.' }
            if ($result.OpenReportOnFinish) { throw 'Expected OpenReportOnFinish to be $false.' }
            if ($result.Quiet.GetType().FullName -ne 'System.Boolean') { throw 'Expected Quiet to stay a native boolean.' }
        }

        It 'accepts legacy string values in run-settings without leaking strings downstream' {
            $script:launcherSettingsJson = Get-TestFixtureContent -Name 'run-settings-valid.json'

            $result = Build-DocumentRunConfig `
                -InitialScopeFile '.\scope.json' `
                -ProgramName 'demo' `
                -OutputDir '.\output' `
                -Depth 3 `
                -UniqueUserAgent 'ua-test' `
                -Threads 10 `
                -TimeoutSeconds 30 `
                -EnableGau $true `
                -EnableWaybackUrls $true `
                -EnableHakrawler $true `
                -NoInstall $false `
                -Quiet $true `
                -IncludeApex $false `
                -RespectSchemeOnly $false `
                -Resume $false `
                -OpenReportOnFinish $false

            if ($result.IncludeApex) { throw 'Expected IncludeApex to be $false.' }
            if (-not $result.RespectSchemeOnly) { throw 'Expected RespectSchemeOnly to be $true.' }
            if ($result.EnableGau) { throw 'Expected EnableGau to be $false.' }
            if (-not $result.EnableWaybackUrls) { throw 'Expected EnableWaybackUrls to be $true.' }
            if ($result.EnableHakrawler) { throw 'Expected EnableHakrawler to be $false.' }
            if (-not $result.NoInstall) { throw 'Expected NoInstall to be $true.' }
            if ($result.Quiet) { throw 'Expected Quiet to be $false.' }
            if ($result.Resume) { throw 'Expected Resume to be $false.' }
            if (-not $result.OpenReportOnFinish) { throw 'Expected OpenReportOnFinish to be $true.' }
            if ($result.Quiet.GetType().FullName -ne 'System.Boolean') { throw 'Expected Quiet to stay a native boolean.' }
            if ($result.EnableGau.GetType().FullName -ne 'System.Boolean') { throw 'Expected EnableGau to stay a native boolean.' }
            if ($result.NoInstall.GetType().FullName -ne 'System.Boolean') { throw 'Expected NoInstall to stay a native boolean.' }
            if ($result.Resume.GetType().FullName -ne 'System.Boolean') { throw 'Expected Resume to stay a native boolean.' }
        }

        It 'surfaces an invalid document boolean before accepting a corrected rerun' {
            $script:launcherSettingsReadCount = 0
            $script:launcherConfigIssueShown = $false

            Mock Show-LauncherConfigIssues { $script:launcherConfigIssueShown = $true }
            Mock Get-Content {
                $script:launcherSettingsReadCount++
                if ($script:launcherSettingsReadCount -eq 1) {
                    return (Get-TestFixtureContent -Name 'run-settings-invalid-bool.json')
                }
                return (Get-TestFixtureContent -Name 'run-settings-valid.json')
            }

            $result = Build-DocumentRunConfig `
                -InitialScopeFile '.\scope.json' `
                -ProgramName 'demo' `
                -OutputDir '.\output' `
                -Depth 3 `
                -UniqueUserAgent 'ua-test' `
                -Threads 10 `
                -TimeoutSeconds 30 `
                -EnableGau $true `
                -EnableWaybackUrls $true `
                -EnableHakrawler $true `
                -NoInstall $false `
                -Quiet $false `
                -IncludeApex $false `
                -RespectSchemeOnly $false `
                -Resume $false `
                -OpenReportOnFinish $false

            if (-not $script:launcherConfigIssueShown) { throw 'Expected invalid run-settings to trigger a validation summary.' }
            if ($script:launcherSettingsReadCount -lt 2) { throw 'Expected the launcher to reopen settings after the validation error.' }
            if ($result.Quiet) { throw 'Expected the corrected fixture to keep Quiet at $false.' }
        }
    }

    Context 'Get-LauncherInvokeParams' {
        It 'passes only true switch flags to recon invocation' {
            $invokeParams = Get-LauncherInvokeParams -RunConfig @{
                ScopeFile         = '.\scope.json'
                ProgramName       = 'demo'
                OutputDir         = '.\output'
                Depth             = 3
                UniqueUserAgent   = 'ua-test'
                Threads           = 10
                TimeoutSeconds    = 30
                EnableGau         = $true
                EnableWaybackUrls = $false
                EnableHakrawler   = $true
                NoInstall         = $false
                Quiet             = $true
                IncludeApex       = $false
                RespectSchemeOnly = $true
                Resume            = $false
            }

            if (-not $invokeParams.Quiet) { throw 'Expected Quiet to be passed when true.' }
            if ($invokeParams.ContainsKey('NoInstall')) { throw 'Expected NoInstall to be omitted when false.' }
            if ($invokeParams.ContainsKey('IncludeApex')) { throw 'Expected IncludeApex to be omitted when false.' }
            if ($invokeParams.ContainsKey('Resume')) { throw 'Expected Resume to be omitted when false.' }
            if ($invokeParams.EnableWaybackUrls) { throw 'Expected EnableWaybackUrls to remain $false.' }
        }

        It 'rejects non-boolean switch values before recon is called' {
            try {
                Get-LauncherInvokeParams -RunConfig @{
                    ScopeFile         = '.\scope.json'
                    ProgramName       = 'demo'
                    OutputDir         = '.\output'
                    Depth             = 3
                    UniqueUserAgent   = 'ua-test'
                    Threads           = 10
                    TimeoutSeconds    = 30
                    EnableGau         = $true
                    EnableWaybackUrls = $false
                    EnableHakrawler   = $true
                    Quiet             = 'System.String'
                } | Out-Null
                throw "Expected non-boolean Quiet to fail before recon."
            } catch {
                if ($_.Exception.Message -notlike "*Champ 'Quiet' invalide*" -and $_.Exception.Message -notlike "*Champ 'quiet' invalide*") { throw }
            }
        }
    }

    Context 'Console error summary' {
        It 'renders the error summary panel without throwing' {
            $result = [pscustomobject]@{
                Errors = @(
                    [pscustomobject]@{
                        Timestamp      = '2026-03-26T12:00:00.0000000+00:00'
                        Phase          = 'Probe'
                        Tool           = 'httpx'
                        ErrorCode      = 'ToolExitCode'
                        Target         = 'https://app.example.com'
                        Message        = 'httpx exited with code 1'
                        Recommendation = 'Inspect tools.log.'
                    }
                )
                OutputDir = 'C:\Temp\ScopeForge'
            }

            Show-ErrorSummaryPanel -Result $result
        }
    }

    Context 'Run manifest and rerun helpers' {
        BeforeEach {
            Mock Get-LauncherStorageRoot { Join-Path $TestDrive 'storage' }
            Mock Read-ScopeFile {
                @([pscustomobject]@{
                    Id              = 'scope-001'
                    Type            = 'Domain'
                    NormalizedValue = 'example.com'
                    Exclusions      = @()
                })
            }
            Mock Get-LauncherRepoVersionDescriptor {
                [pscustomobject]@{
                    Source    = 'git'
                    GitCommit = 'abc1234'
                }
            }
            Mock Get-LauncherToolSnapshot {
                @([pscustomobject]@{
                    Name       = 'httpx'
                    Binary     = 'httpx.exe'
                    BinaryPath = 'C:\Tools\httpx.exe'
                    Version    = 'httpx 1.7.0'
                })
            }
        }

        It 'writes a run manifest plus frozen inputs and registers it in the catalog' {
            $outputDir = Join-Path $TestDrive 'output'
            $scopeFile = Join-Path $TestDrive 'scope.json'
            Set-Content -LiteralPath $scopeFile -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            $runConfig = @{
                RunId               = 'run-001'
                ScopeFile           = $scopeFile
                ProgramName         = 'demo'
                OutputDir           = $outputDir
                Depth               = 3
                UniqueUserAgent     = 'ua-test'
                Threads             = 10
                TimeoutSeconds      = 30
                EnableGau           = $true
                EnableWaybackUrls   = $true
                EnableHakrawler     = $true
                NoInstall           = $false
                Quiet               = $false
                IncludeApex         = $false
                RespectSchemeOnly   = $false
                Resume              = $false
                OpenReportOnFinish  = $true
            }

            $summary = [pscustomobject]@{
                ScopeItemCount          = 1
                ExcludedItemCount       = 0
                DiscoveredHostCount     = 2
                LiveHostCount           = 1
                LiveTargetCount         = 1
                DiscoveredUrlCount      = 2
                InterestingUrlCount     = 1
                ProtectedInterestingCount = 1
                ErrorCount              = 0
            }
            $result = [pscustomobject]@{
                ProgramName = 'demo'
                OutputDir   = $outputDir
                Summary     = $summary
            }

            $manifest = Save-LauncherRunManifest -RunConfig $runConfig -Result $result -RunStartedAtUtc '2026-03-26T12:00:00Z' -RunEndedAtUtc '2026-03-26T12:05:00Z'

            if (-not (Test-Path -LiteralPath (Get-LauncherRunManifestPath -OutputDir $outputDir))) { throw 'Expected run-manifest.json to exist.' }
            if (-not (Test-Path -LiteralPath (Get-LauncherFrozenScopePath -OutputDir $outputDir))) { throw 'Expected frozen scope file to exist.' }
            if (-not (Test-Path -LiteralPath (Get-LauncherFrozenSettingsPath -OutputDir $outputDir))) { throw 'Expected frozen settings file to exist.' }
            if (-not (Test-Path -LiteralPath $manifest.CatalogPath)) { throw 'Expected a catalog copy of the manifest to exist.' }
            if ($manifest.RepoVersion.GitCommit -ne 'abc1234') { throw 'Expected manifest to capture repo version metadata.' }
            if ($manifest.ToolSnapshot[0].Version -ne 'httpx 1.7.0') { throw 'Expected manifest to capture tool snapshot metadata.' }
        }

        It 'creates a rerun config with a fresh output directory and frozen scope' {
            $frozenScopeFile = Join-Path $TestDrive 'scope-frozen.json'
            Set-Content -LiteralPath $frozenScopeFile -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            $manifest = [pscustomobject]@{
                RunId           = 'run-parent'
                ProgramName     = 'demo'
                OutputDir       = 'C:\Previous\Run'
                FrozenScopeFile = $frozenScopeFile
                ManifestPath    = (Join-Path $TestDrive 'run-manifest.json')
                RunSettings     = [pscustomobject]@{
                    ProgramName         = 'demo'
                    Depth               = 3
                    UniqueUserAgent     = 'ua-test'
                    Threads             = 10
                    TimeoutSeconds      = 30
                    EnableGau           = $true
                    EnableWaybackUrls   = $false
                    EnableHakrawler     = $true
                    NoInstall           = $false
                    Quiet               = $false
                    IncludeApex         = $false
                    RespectSchemeOnly   = $true
                    Resume              = $false
                    OpenReportOnFinish  = $true
                }
            }

            $rerunConfig = New-LauncherRerunConfigFromManifest -Manifest $manifest

            if ($rerunConfig.OutputDir -eq $manifest.OutputDir) { throw 'Expected rerun output directory to be new.' }
            if ($rerunConfig.ParentRunId -ne 'run-parent') { throw 'Expected rerun config to keep parent run id.' }
            if ($rerunConfig.ScopeFile -ne $frozenScopeFile) { throw 'Expected rerun config to use the frozen scope file.' }
            if ($rerunConfig.RespectSchemeOnly -ne $true) { throw 'Expected rerun config to preserve boolean settings.' }
            if ($rerunConfig.Quiet.GetType().FullName -ne 'System.Boolean') { throw 'Expected rerun Quiet to stay a native boolean.' }
        }
    }

    Context 'Guided scope file workflow' {
        BeforeEach {
            $script:launcherStorage = Join-Path $TestDrive '.launcher-storage'
            $script:fileWorkspace = [pscustomobject]@{
                RepoRoot         = $TestDrive
                ScopesRoot       = Join-Path $TestDrive 'scopes'
                Incoming         = Join-Path $TestDrive 'scopes\\incoming'
                Active           = Join-Path $TestDrive 'scopes\\active'
                Archived         = Join-Path $TestDrive 'scopes\\archived'
                Templates        = Join-Path $TestDrive 'scopes\\templates'
                TemplatesGuide   = Join-Path $TestDrive 'scopes\\templates\\README.md'
                StateRoot        = Join-Path $TestDrive 'state'
                RecentScopesPath = Join-Path $TestDrive 'state\\recent-scopes.json'
            }
            Mock Get-LauncherFileWorkspace { $script:fileWorkspace }
            Mock Get-LauncherStorageRoot { $script:launcherStorage }
            $script:fileWorkspace = Initialize-LauncherFileWorkspace
            $script:testScopePrefix = ('ut-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
        }

        AfterEach {
            if (-not (Get-Variable -Name fileWorkspace -Scope Script -ErrorAction SilentlyContinue)) { return }
            if (-not (Get-Variable -Name testScopePrefix -Scope Script -ErrorAction SilentlyContinue)) { return }
            foreach ($folderPath in @($script:fileWorkspace.Incoming, $script:fileWorkspace.Active, $script:fileWorkspace.Templates)) {
                Get-ChildItem -LiteralPath $folderPath -Filter "$($script:testScopePrefix)*.json" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }

        It 'updates recent scopes, preserves missing entries, and caps the list' {
            $existingScope = Join-Path $script:fileWorkspace.Active ("{0}-existing.json" -f $script:testScopePrefix)
            $missingScope = Join-Path $script:fileWorkspace.Active ("{0}-missing.json" -f $script:testScopePrefix)
            $null = New-Item -ItemType Directory -Path $script:fileWorkspace.Active -Force
            Set-Content -LiteralPath $existingScope -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            $null = Update-LauncherRecentScopes -ScopePath $missingScope -LastOutputDir 'C:\Runs\missing' -DisplayName 'missing'
            $null = Update-LauncherRecentScopes -ScopePath $existingScope -LastOutputDir 'C:\Runs\existing' -DisplayName 'existing'

            foreach ($index in 1..12) {
                $scopePath = Join-Path $script:fileWorkspace.Incoming ("{0}-scope-{1}.json" -f $script:testScopePrefix, $index)
                $null = New-Item -ItemType Directory -Path $script:fileWorkspace.Incoming -Force
                Set-Content -LiteralPath $scopePath -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'
                $null = Update-LauncherRecentScopes -ScopePath $scopePath -LastOutputDir ("C:\Runs\{0}" -f $index) -DisplayName ("scope-{0}" -f $index)
            }

            $items = @(Read-LauncherRecentScopes)
            if ($items.Count -ne (Get-LauncherRecentScopesLimit)) { throw 'Expected recent scopes to be capped to the configured limit.' }
            if ($items | Where-Object { $_.scope_path -eq (Resolve-LauncherScopePath -Path $missingScope) } | Measure-Object | Select-Object -ExpandProperty Count) {
                throw 'Expected the oldest missing entry to be discarded only by the list cap, not silently before then.'
            }

            $null = Update-LauncherRecentScopes -ScopePath $missingScope -LastOutputDir 'C:\Runs\missing-new' -DisplayName 'missing'
            $items = @(Read-LauncherRecentScopes)
            $missingItem = $items | Where-Object { $_.scope_path -eq (Resolve-LauncherScopePath -Path $missingScope) } | Select-Object -First 1
            if (-not $missingItem) { throw 'Expected a missing scope to remain tracked in recent scopes.' }
            if ($missingItem.exists) { throw 'Expected missing scope to be marked as not found.' }
            if ($missingItem.note -ne 'INTROUVABLE') { throw 'Expected missing scope to be marked as INTROUVABLE.' }
            if ($items[0].scope_path -ne (Resolve-LauncherScopePath -Path $missingScope)) { throw 'Expected the latest scope update to move to the top of the recent list.' }
        }

        It 'seeds built-in templates and help files that stay compatible with the scope parser' {
            $templates = @(Get-LauncherScopeTemplateFiles)
            if ($templates.Count -lt 3) { throw 'Expected the built-in minimal, standard and advanced templates to be available.' }

            $expectedTemplateFiles = @(
                '01-minimal-scope.json',
                '02-standard-scope.json',
                '03-advanced-scope.json'
            )
            $expectedHelpFiles = @(
                'README.md',
                '01-minimal-scope.help.md',
                '02-standard-scope.help.md',
                '03-advanced-scope.help.md'
            )

            foreach ($fileName in $expectedTemplateFiles) {
                $path = Join-Path $script:fileWorkspace.Templates $fileName
                if (-not (Test-Path -LiteralPath $path)) { throw ("Expected template file to exist: {0}" -f $fileName) }
                $parsedScope = @(Read-ScopeFile -Path $path)
                if ($parsedScope.Count -lt 1) { throw ("Expected template file to parse as a non-empty scope: {0}" -f $fileName) }
            }

            foreach ($fileName in $expectedHelpFiles) {
                $path = Join-Path $script:fileWorkspace.Templates $fileName
                if (-not (Test-Path -LiteralPath $path)) { throw ("Expected help file to exist: {0}" -f $fileName) }
            }
        }

        It 'creates and optionally opens a guided minimal scope file' {
            Mock Write-LauncherSection { }
            Mock Write-Host { }
            $script:openedDocuments = @()
            $script:choiceValues = @('1', '1')
            $expectedScopeName = "$($script:testScopePrefix)-demo-scope"
            $script:valueValues = @($expectedScopeName)
            $script:yesNoValues = @($true, $false)

            Mock Read-LauncherChoice {
                $next = $script:choiceValues[0]
                if ($script:choiceValues.Count -gt 1) {
                    $script:choiceValues = @($script:choiceValues[1..($script:choiceValues.Count - 1)])
                } else {
                    $script:choiceValues = @()
                }
                return $next
            }
            Mock Read-LauncherYesNo {
                $next = $script:yesNoValues[0]
                if ($script:yesNoValues.Count -gt 1) {
                    $script:yesNoValues = @($script:yesNoValues[1..($script:yesNoValues.Count - 1)])
                } else {
                    $script:yesNoValues = @()
                }
                return $next
            }
            Mock Open-LauncherDocument {
                param([string]$Path, [string]$Title)

                $script:openedDocuments += [pscustomobject]@{
                    Path  = $Path
                    Title = $Title
                }
            }
            Mock Show-LauncherCreatedScopeGuidance { }
            Mock Read-LauncherValue {
                $next = $script:valueValues[0]
                if ($script:valueValues.Count -gt 1) {
                    $script:valueValues = @($script:valueValues[1..($script:valueValues.Count - 1)])
                } else {
                    $script:valueValues = @()
                }
                return $next
            }

            $createdScope = New-LauncherScopeFromTemplate -PlannedOutputDir '.\output\guided'
            if (-not (Test-Path -LiteralPath $createdScope.Path)) { throw 'Expected the new scope file to be created.' }
            if ($createdScope.Path -ne (Join-Path $script:fileWorkspace.Incoming ("{0}.json" -f $expectedScopeName))) { throw 'Expected the new scope file to be created under scopes/incoming by default.' }
            if (-not $createdScope.OpenedScope) { throw 'Expected the created scope file to be flagged as opened.' }
            if ($createdScope.OpenedGuide) { throw 'Expected the guide file to stay closed when the prompt returns false.' }
            if ($createdScope.TemplateDisplayName -ne 'Modele minimal') { throw 'Expected the guided creation flow to use the minimal template.' }
            if ($script:openedDocuments.Count -ne 1) { throw 'Expected only the created scope file to be opened.' }
            if ($script:openedDocuments[0].Title -ne 'Fichier de scope') { throw 'Expected the created scope file to be opened with the scope title.' }

            $content = Get-Content -LiteralPath $createdScope.Path -Raw -Encoding utf8
            if ($content -notlike '*"value": "app.example.com"*') { throw 'Expected the minimal starter scope content to be written.' }
        }

        It 'creates a document session for a managed scope without coercion errors' {
            $managedScope = Join-Path $script:fileWorkspace.Active ("{0}-managed.json" -f $script:testScopePrefix)
            $launcherStorage = Join-Path $TestDrive '.launcher-storage'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $managedScope) -Force
            Set-Content -LiteralPath $managedScope -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            Mock Get-LauncherStorageRoot { $launcherStorage }

            $documentSet = New-LauncherDocumentSet -ManagedScopeFilePath $managedScope -ProgramName 'demo' -OutputDir '.\output\guided' -Depth 3 -UniqueUserAgent 'ua-demo' -Threads 10 -TimeoutSeconds 30 -EnableGau $true -EnableWaybackUrls $true -EnableHakrawler $true -NoInstall $false -Quiet $false -IncludeApex $false -RespectSchemeOnly $false -Resume $false -OpenReportOnFinish $true

            if (-not (Test-Path -LiteralPath $documentSet.ReadmePath)) { throw 'Expected the guided document session to create 00-START-HERE.txt.' }
            if ($documentSet.ScopePath -ne (Resolve-LauncherScopePath -Path $managedScope)) { throw 'Expected the managed scope path to be kept as-is.' }

            $readmeContent = Get-Content -LiteralPath $documentSet.ReadmePath -Raw -Encoding utf8
            if ($readmeContent -notlike '*Le scope sera edite directement dans son emplacement gere*') {
                throw 'Expected the START-HERE guide to explain that the managed scope is edited in place.'
            }
        }

        It 'discovers JSON files from the active and incoming scope folders and surfaces the last output' {
            $activeScope = Join-Path $script:fileWorkspace.Active ("{0}-active-scope.json" -f $script:testScopePrefix)
            $incomingScope = Join-Path $script:fileWorkspace.Incoming ("{0}-incoming-scope.json" -f $script:testScopePrefix)
            $templateScope = Join-Path $script:fileWorkspace.Templates ("{0}-template-scope.json" -f $script:testScopePrefix)

            foreach ($path in @($activeScope, $incomingScope, $templateScope)) {
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
                Set-Content -LiteralPath $path -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'
            }

            $null = Update-LauncherRecentScopes -ScopePath $activeScope -LastOutputDir 'C:\Runs\active' -DisplayName 'active-scope'
            $scopeFiles = @(Get-LauncherManagedScopeFiles)

            foreach ($expectedPath in @($activeScope, $incomingScope)) {
                if (-not ($scopeFiles | Where-Object { $_.scope_path -eq (Resolve-LauncherScopePath -Path $expectedPath) } | Select-Object -First 1)) {
                    throw ("Expected managed scope discovery to include {0}." -f $expectedPath)
                }
            }
            if ($scopeFiles | Where-Object { $_.scope_path -eq (Resolve-LauncherScopePath -Path $templateScope) } | Select-Object -First 1) {
                throw 'Expected templates to stay out of the existing-scope picker.'
            }
            $activeEntry = $scopeFiles | Where-Object { $_.scope_path -eq (Resolve-LauncherScopePath -Path $activeScope) } | Select-Object -First 1
            if (-not $activeEntry) { throw 'Expected the active scope to be present in the discovered list.' }
            if ($activeEntry.last_output_dir -ne 'C:\Runs\active') { throw 'Expected discovered scope files to surface the last known output directory.' }
        }

        It 'keeps the selected scope and output when switching to assistant console' {
            $activeScope = Join-Path $script:fileWorkspace.Active ("{0}-selected.json" -f $script:testScopePrefix)
            Set-Content -LiteralPath $activeScope -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            Mock Show-LauncherScopeSelection { }
            Mock Write-Host { }
            Mock Read-LauncherChoice { '12' }

            $plan = Select-LauncherGuidedStartupPlan -InitialScopeFile $activeScope -OutputDir '.\output\guided' -AllowRerun:$false

            if ($plan.Action -ne 'console') { throw 'Expected the guided plan to switch to assistant console.' }
            if ($plan.InitialScopeFile -ne (Resolve-LauncherScopePath -Path $activeScope)) { throw 'Expected the selected scope to be preserved for console mode.' }
            if ($plan.OutputDir -ne '.\output\guided') { throw 'Expected the planned output directory to be preserved for console mode.' }
        }
    }

    Context 'Saved session persistence and launcher logging' {
        BeforeEach {
            $script:launcherStorage = Join-Path $TestDrive '.launcher-storage'
            $script:fileWorkspace = [pscustomobject]@{
                RepoRoot         = $TestDrive
                ScopesRoot       = Join-Path $TestDrive 'scopes'
                Incoming         = Join-Path $TestDrive 'scopes\\incoming'
                Active           = Join-Path $TestDrive 'scopes\\active'
                Archived         = Join-Path $TestDrive 'scopes\\archived'
                Templates        = Join-Path $TestDrive 'scopes\\templates'
                TemplatesGuide   = Join-Path $TestDrive 'scopes\\templates\\README.md'
                StateRoot        = Join-Path $TestDrive 'state'
                RecentScopesPath = Join-Path $TestDrive 'state\\recent-scopes.json'
            }

            Mock Get-LauncherStorageRoot { $script:launcherStorage }
            Mock Get-LauncherFileWorkspace { $script:fileWorkspace }
            $null = Initialize-LauncherFileWorkspace
            Mock Write-Host { }
            Mock Write-LauncherSection { }
            Mock Write-LauncherTable { }
            Mock Write-LauncherKeyValue { }
            Mock Open-LauncherDocument { }
            Mock Open-LauncherPath { }
        }

        It 'stores the managed scope path and logging mode in session metadata' {
            $managedScope = Join-Path $script:fileWorkspace.Active 'managed.json'
            Set-Content -LiteralPath $managedScope -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            $documentSet = New-LauncherDocumentSet -ManagedScopeFilePath $managedScope -LoggingMode 'debug' -ProgramName 'demo' -OutputDir '.\output\guided' -Depth 3 -UniqueUserAgent 'ua-demo' -Threads 10 -TimeoutSeconds 30 -EnableGau $true -EnableWaybackUrls $true -EnableHakrawler $true -NoInstall $false -Quiet $false -IncludeApex $false -RespectSchemeOnly $false -Resume $false -OpenReportOnFinish $true
            $session = Read-LauncherSessionMetadata -SessionRoot $documentSet.RootPath

            if ($session.scope_path -ne (Resolve-LauncherScopePath -Path $managedScope)) { throw 'Expected the session metadata to keep the external managed scope path.' }
            if ($session.logging_mode -ne 'debug') { throw 'Expected the session metadata to persist the selected logging mode.' }
            if ($session.logs_root -ne (Join-Path $documentSet.RootPath 'logs')) { throw 'Expected the session metadata to keep the session logs root.' }
        }

        It 'duplicates a saved session into a new unique root and remaps copied files' {
            $sessionRoot = Get-LauncherUniqueSessionDirectory
            $null = New-Item -ItemType Directory -Path $sessionRoot -Force
            Set-Content -LiteralPath (Join-Path $sessionRoot '00-START-HERE.txt') -Encoding utf8 -Value 'demo'
            Set-Content -LiteralPath (Join-Path $sessionRoot '01-scope.json') -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'
            Set-Content -LiteralPath (Join-Path $sessionRoot '02-run-settings.json') -Encoding utf8 -Value '{"programName":"demo"}'
            $null = New-Item -ItemType Directory -Path (Join-Path $sessionRoot 'logs') -Force

            $session = Update-LauncherSessionMetadata -SessionRoot $sessionRoot -Values @{
                display_name = 'demo'
                note         = 'SESSION'
            }

            $copy = Copy-LauncherSavedSession -Session $session -NewDisplayName 'demo-copy'

            if ($copy.session_root -eq $session.session_root) { throw 'Expected the duplicated session to live in a new directory.' }
            if ($copy.scope_path -ne (Join-Path $copy.session_root '01-scope.json')) { throw 'Expected the duplicated session to point to its copied scope file.' }
            if ($copy.settings_path -ne (Join-Path $copy.session_root '02-run-settings.json')) { throw 'Expected the duplicated session to point to its copied settings file.' }
            if ($copy.display_name -ne 'demo-copy') { throw 'Expected the duplicated session display name to be updated.' }
        }

        It 'removes a saved session and clears the selected session pointer' {
            $sessionRoot = Get-LauncherUniqueSessionDirectory
            $null = New-Item -ItemType Directory -Path $sessionRoot -Force

            $session = Update-LauncherSessionMetadata -SessionRoot $sessionRoot -Values @{
                display_name = 'demo-delete'
                note         = 'SESSION'
            }
            Set-LauncherSelectedSession -SessionId $session.session_id

            if (-not (Remove-LauncherSavedSession -Session $session)) { throw 'Expected the session deletion helper to return $true.' }
            if (Test-Path -LiteralPath $session.session_root) { throw 'Expected the session directory to be removed.' }
            if (Get-LauncherSelectedSession | Where-Object { $_.session_id -eq $session.session_id }) { throw 'Expected the deleted session to be cleared from the selected-session pointer.' }
        }

        It 'persists the selected session across launcher restarts via UI state' {
            $sessionRoot = Get-LauncherUniqueSessionDirectory
            $null = New-Item -ItemType Directory -Path $sessionRoot -Force
            $session = Update-LauncherSessionMetadata -SessionRoot $sessionRoot -Values @{
                display_name = 'demo-persist'
                note         = 'SESSION'
            }

            Set-LauncherSelectedSession -SessionId $session.session_id
            $selected = Get-LauncherSelectedSession

            if (-not $selected) { throw 'Expected a selected session to be returned from persisted UI state.' }
            if ($selected.session_id -ne $session.session_id) { throw 'Expected the persisted selected session to be reloaded after the state file is written.' }
        }

        It 'computes a planned launcher log path from the session and run id' {
            $sessionRoot = Join-Path $script:launcherStorage 'launcher\\session-demo'
            $planned = Get-LauncherPlannedLogRoot -RunConfig @{
                LauncherSessionRoot = $sessionRoot
                RunId               = 'run-123'
            }

            $expected = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $sessionRoot 'logs') 'run-123'))
            if ($planned -ne $expected) { throw 'Expected the planned log path to use the session logs folder and run id.' }
        }

        It 'captures debug diagnostics in the launcher log folder' {
            $runConfig = @{
                LauncherSessionRoot = Join-Path $script:launcherStorage 'launcher\\session-debug'
                LauncherLogMode     = 'debug'
                RunId               = 'run-debug'
                ScopeFile           = Join-Path $TestDrive 'scope.json'
                OutputDir           = Join-Path $TestDrive 'output'
            }
            Set-Content -LiteralPath $runConfig.ScopeFile -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            $context = Start-LauncherLoggingContext -RunConfig $runConfig
            Write-LauncherDiagnosticLog -Message 'debug trace' -Level DEBUG
            Stop-LauncherLoggingContext

            if (-not (Test-Path -LiteralPath $context.LogPath)) { throw 'Expected the launcher log file to be created.' }
            $content = Get-Content -LiteralPath $context.LogPath -Raw -Encoding utf8
            if ($content -notlike '*debug trace*') { throw 'Expected debug mode to persist detailed launcher diagnostics.' }
        }

        It 'returns a saved-session documents plan from the guided menu' {
            $sessionRoot = Get-LauncherUniqueSessionDirectory
            $scopePath = Join-Path $script:fileWorkspace.Active 'saved-session-scope.json'
            Set-Content -LiteralPath $scopePath -Encoding utf8 -Value '[{"type":"Domain","value":"example.com","exclusions":[]}]'

            $session = Update-LauncherSessionMetadata -SessionRoot $sessionRoot -Values @{
                display_name = 'session-demo'
                scope_path   = $scopePath
                logging_mode = 'verbose'
                note         = 'SESSION'
            }

            Mock Show-LauncherScopeSelection { }
            Mock Manage-LauncherSavedSessions { [pscustomobject]@{ Action = 'launch'; Session = $session } }
            Mock Read-LauncherChoice { '4' }

            $plan = Select-LauncherGuidedStartupPlan -InitialScopeFile '' -OutputDir '.\output\guided' -AllowRerun:$false

            if ($plan.Action -ne 'saved-session-documents') { throw 'Expected the guided launcher to return a saved-session documents plan.' }
            if ($plan.SessionRoot -ne $session.session_root) { throw 'Expected the selected session root to be preserved.' }
            if ($plan.LoggingMode -ne 'verbose') { throw 'Expected the session logging mode to be reused.' }
            if ($plan.ManagedScopeFile -ne (Resolve-LauncherScopePath -Path $scopePath)) { throw 'Expected active managed scopes to stay editable in place when reopening a session.' }
        }

    }
}
