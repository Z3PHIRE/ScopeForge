$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repoRoot 'Launch-ScopeForge.ps1')
. (Join-Path $repoRoot 'ScopeForge.ps1')

Describe 'ScopeForge rerun manifests' {
    BeforeEach {
        $script:testCatalogRoot = Join-Path $TestDrive '_catalog'
        $null = New-Item -ItemType Directory -Path $script:testCatalogRoot -Force

        Mock Get-LauncherRunCatalogRoot { $script:testCatalogRoot }
        Mock Get-LauncherUniqueRunDirectory { Join-Path $TestDrive '20260326-130000-rerun' }
        Mock Read-ScopeFile {
            @(
                [pscustomobject]@{
                    Id              = 'scope-001'
                    Type            = 'Domain'
                    NormalizedValue = 'example.com'
                    Exclusions      = @()
                }
            )
        }
        Mock Get-LauncherToolSnapshot {
            @(
                [pscustomobject]@{
                    Name             = 'httpx'
                    Binary           = 'httpx.exe'
                    BinaryPath       = 'C:\Tools\httpx.exe'
                    ProductVersion   = '1.3.0'
                    FileVersion      = '1.3.0'
                    LastWriteTimeUtc = '2026-03-26T12:00:00.0000000Z'
                }
            )
        }
    }

    It 'writes a run manifest with frozen scope and settings' {
        $outputDir = Join-Path $TestDrive 'run-output'
        $scopeFile = Join-Path $TestDrive 'scope.json'
        $null = New-Item -ItemType Directory -Path $outputDir -Force
        Set-Content -LiteralPath $scopeFile -Value @'
[
  {
    "type": "Domain",
    "value": "example.com",
    "exclusions": []
  }
]
'@ -Encoding utf8

        $runConfig = @{
            RunId              = 'run-123'
            ParentRunId        = 'run-parent'
            ScopeFile          = $scopeFile
            ProgramName        = 'demo'
            OutputDir          = $outputDir
            Depth              = 3
            UniqueUserAgent    = 'ua-test'
            Threads            = 10
            TimeoutSeconds     = 30
            EnableGau          = $true
            EnableWaybackUrls  = $true
            EnableHakrawler    = $false
            NoInstall          = $false
            Quiet              = $false
            IncludeApex        = $false
            RespectSchemeOnly  = $false
            Resume             = $true
            OpenReportOnFinish = $true
        }
        $result = [pscustomobject]@{
            ProgramName = 'demo'
            OutputDir   = $outputDir
            Summary     = [pscustomobject]@{
                ScopeItemCount             = 1
                ExcludedItemCount          = 0
                DiscoveredHostCount        = 2
                LiveHostCount              = 1
                LiveTargetCount            = 1
                DiscoveredUrlCount         = 3
                InterestingUrlCount        = 1
                ProtectedInterestingCount  = 1
                ErrorCount                 = 0
            }
        }

        $manifest = Save-LauncherRunManifest `
            -RunConfig $runConfig `
            -Result $result `
            -RunStartedAtUtc '2026-03-26T12:00:00.0000000Z' `
            -RunEndedAtUtc '2026-03-26T12:05:00.0000000Z'

        $manifestPath = Get-LauncherRunManifestPath -OutputDir $outputDir
        $frozenScopePath = Get-LauncherFrozenScopePath -OutputDir $outputDir
        $frozenSettingsPath = Get-LauncherFrozenSettingsPath -OutputDir $outputDir
        $catalogPath = Join-Path $script:testCatalogRoot 'run-123.json'

        foreach ($path in @($manifestPath, $frozenScopePath, $frozenSettingsPath, $catalogPath)) {
            if (-not (Test-Path -LiteralPath $path)) { throw "Expected file '$path' to exist." }
        }
        if ($manifest.RunId -ne 'run-123') { throw 'Expected manifest RunId to be preserved.' }
        if ($manifest.ParentRunId -ne 'run-parent') { throw 'Expected ParentRunId to be preserved.' }

        $savedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
        if ($savedManifest.RunSettings.Resume -ne $true) { throw 'Expected Resume to be saved in the manifest snapshot.' }
        if ($savedManifest.ToolSnapshot[0].ProductVersion -ne '1.3.0') { throw 'Expected tool snapshot version info to be present.' }
    }

    It 'builds a rerun config from a stored manifest with a new output directory' {
        $scopeFile = Join-Path $TestDrive 'scope-frozen.json'
        Set-Content -LiteralPath $scopeFile -Value @'
[
  {
    "type": "Domain",
    "value": "example.com",
    "exclusions": []
  }
]
'@ -Encoding utf8

        $manifest = [pscustomobject]@{
            RunId           = 'run-123'
            ProgramName     = 'demo'
            FrozenScopeFile = $scopeFile
            ManifestPath    = 'C:\ScopeForge\runs\_catalog\run-123.json'
            RunSettings     = [pscustomobject]@{
                ProgramName            = 'demo'
                PresetName             = 'balanced'
                PresetDescription      = 'Balanced'
                ProfileName            = 'webapp'
                ProfileDescription     = 'Web application'
                ProfileSourceExplanation = 'Default profile'
                Depth                  = 4
                Threads                = 12
                TimeoutSeconds         = 45
                EnableGau              = $true
                EnableWaybackUrls      = $false
                EnableHakrawler        = $true
                NoInstall              = $false
                Quiet                  = 'false'
                IncludeApex            = $true
                RespectSchemeOnly      = $false
                Resume                 = $true
                OpenReportOnFinish     = $true
                UniqueUserAgent        = 'ua-rerun'
            }
        }

        $config = New-LauncherRerunConfigFromManifest -Manifest $manifest

        if ($config.OutputDir -ne (Join-Path $TestDrive '20260326-130000-rerun')) { throw 'Expected rerun to use a newly allocated output directory.' }
        if ($config.ParentRunId -ne 'run-123') { throw 'Expected rerun config to preserve the parent run id.' }
        if ($config.RerunSourceManifest -ne 'C:\ScopeForge\runs\_catalog\run-123.json') { throw 'Expected rerun config to keep the source manifest path.' }
        if ($config.Quiet -ne $false) { throw 'Expected Quiet to be normalized to $false from the manifest.' }
        if ($config.Resume -ne $true) { throw 'Expected Resume to stay $true in rerun config.' }
        if ($config.ScopePreview.Count -ne 1) { throw 'Expected rerun config to preload the frozen scope preview.' }
    }
}
