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
}
