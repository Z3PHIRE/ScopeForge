$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repoRoot 'Launch-ScopeForge.ps1')
. (Join-Path $repoRoot 'ScopeForge.ps1')

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
            $script:launcherSettingsJson = @'
{
  "preset": "balanced",
  "profile": "webapp",
  "programName": "demo",
  "outputDir": "./output",
  "depth": "4",
  "threads": "12",
  "timeoutSeconds": "45",
  "uniqueUserAgent": "ua-test",
  "includeApex": "false",
  "respectSchemeOnly": "true",
  "enableGau": "false",
  "enableWaybackUrls": "1",
  "enableHakrawler": "0",
  "noInstall": "true",
  "quiet": "false",
  "resume": "false",
  "openReportOnFinish": "true"
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
                if ($_.Exception.Message -notlike "*launcher*") { throw }
            }
        }
    }
}
