Describe 'ScopeForge tool bootstrap and safety' {
    BeforeAll {
        $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        . (Join-Path $script:repoRoot 'ScopeForge.ps1')
    }

    BeforeEach {
        $script:ScopeForgeToolHelpCache = @{}
    }

    It 'selects a Windows asset without matching darwin by substring' {
        $assets = @(
            [pscustomobject]@{ name = 'gau_2.2.4_darwin_amd64.tar.gz' },
            [pscustomobject]@{ name = 'gau_2.2.4_windows_amd64.zip' },
            [pscustomobject]@{ name = 'gau_2.2.4_linux_amd64.tar.gz' }
        )

        $selected = Select-ToolReleaseAsset -ToolName 'gau' -ReleaseAssets $assets -PlatformInfo ([pscustomobject]@{ Os = 'windows'; Architecture = 'amd64' })

        if (-not $selected) { throw 'Expected a Windows asset to be selected.' }
        if ($selected.name -ne 'gau_2.2.4_windows_amd64.zip') { throw 'Expected Windows asset selection to avoid matching darwin by substring.' }
    }

    It 'classifies tgz archives as tar-gzip and rejects unsupported formats' {
        if ((Get-CompressedArchiveKind -ArchivePath 'C:\Temp\waybackurls.tgz') -ne 'tar-gzip') { throw 'Expected .tgz to be treated as tar-gzip.' }
        if ((Get-CompressedArchiveKind -ArchivePath 'C:\Temp\archive.tar.gz') -ne 'tar-gzip') { throw 'Expected .tar.gz to be treated as tar-gzip.' }
        if ((Get-CompressedArchiveKind -ArchivePath 'C:\Temp\archive.7z') -ne 'unsupported') { throw 'Expected unsupported archive kinds to stay explicit.' }
    }

    It 'extracts a real tgz archive from a OneDrive-like path with spaces' {
        $tarCommand = Get-Command -Name 'tar' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $workspace = Join-Path $TestDrive 'OneDrive Demo\Documents With Spaces\deep path'
        $sourceDirectory = Join-Path $workspace 'source files'
        $extractDirectory = Join-Path $workspace 'extract target'
        $archivePath = Join-Path $workspace 'sample archive.tgz'
        $sourceFile = Join-Path $sourceDirectory 'sample.txt'

        $null = New-Item -ItemType Directory -Path $sourceDirectory -Force
        Set-Content -LiteralPath $sourceFile -Encoding utf8 -NoNewline -Value 'hello-from-scopeforge'
        & $tarCommand.Source -czf $archivePath -C $sourceDirectory 'sample.txt'
        if ($LASTEXITCODE -ne 0) { throw 'Expected tar to create the sample archive successfully.' }

        $result = Expand-CompressedArchive -ArchivePath $archivePath -DestinationPath $extractDirectory
        $extractedFile = Join-Path $extractDirectory 'sample.txt'

        if ($result.ArchiveKind -ne 'tar-gzip') { throw 'Expected real archive extraction to report tar-gzip.' }
        if (-not (Test-Path -LiteralPath $extractedFile)) { throw 'Expected the sample file to be extracted from the tgz archive.' }
        if ((Get-Content -LiteralPath $extractedFile -Raw -Encoding utf8) -ne 'hello-from-scopeforge') {
            throw 'Expected the extracted file contents to match the archived file.'
        }
    }

    It 'uses argument-safe tar extraction for archives in paths with spaces' {
        $archivePath = Join-Path $TestDrive 'OneDrive Demo\Documents With Spaces\tool archive.tgz'
        $destinationPath = Join-Path $TestDrive 'extract target'
        $archiveDirectory = Split-Path -Parent $archivePath
        $null = New-Item -ItemType Directory -Path $archiveDirectory -Force
        Set-Content -LiteralPath $archivePath -Encoding utf8 -Value 'placeholder'

        $script:capturedExtraction = $null
        Mock Get-Command {
            [pscustomobject]@{ Source = 'C:\Windows\System32\tar.exe' }
        } -ParameterFilter { $Name -eq 'tar' -and $CommandType -eq 'Application' }
        Mock Invoke-ExternalCommandArgumentSafe {
            param($FilePath, $Arguments, $TimeoutSeconds)
            $script:capturedExtraction = [pscustomobject]@{
                FilePath       = $FilePath
                Arguments      = @($Arguments)
                TimeoutSeconds = $TimeoutSeconds
            }
            [pscustomobject]@{
                ExitCode  = 0
                StdOut    = ''
                StdErr    = ''
                FilePath  = $FilePath
                Arguments = @($Arguments)
            }
        }

        $result = Expand-CompressedArchive -ArchivePath $archivePath -DestinationPath $destinationPath

        if (-not (Test-Path -LiteralPath $destinationPath)) { throw 'Expected the extraction directory to be created.' }
        if ($result.ArchiveKind -ne 'tar-gzip') { throw 'Expected tar extraction metadata to report tar-gzip.' }
        if (-not $script:capturedExtraction) { throw 'Expected tar extraction to use the argument-safe command wrapper.' }
        if ($script:capturedExtraction.Arguments[1] -ne $archivePath) { throw 'Expected the archive path with spaces to stay a single argument.' }
        if ($script:capturedExtraction.Arguments[3] -ne $destinationPath) { throw 'Expected the extraction directory with spaces to stay a single argument.' }
    }

    It 'reuses cached help text and avoids duplicate help probes' {
        $script:helpProbeCount = 0
        Mock Invoke-ExternalCommand {
            $script:helpProbeCount++
            [pscustomobject]@{
                ExitCode = 0
                StdOut   = 'usage'
                StdErr   = ''
            }
        }

        $first = Get-ToolHelpText -ToolPath 'C:\Tools\httpx.exe'
        $second = Get-ToolHelpText -ToolPath 'C:\Tools\httpx.exe'

        if ($first -notlike '*usage*') { throw 'Expected help text to be returned from the first probe.' }
        if ($second -notlike '*usage*') { throw 'Expected cached help text to be reused.' }
        if ($script:helpProbeCount -ne 1) { throw 'Expected only one help probe for the same tool path.' }
    }

    It 'prefers cached tools without forcing a download' {
        $layout = [pscustomobject]@{
            ToolsBin       = Join-Path $TestDrive 'tools\bin'
            ToolsDownloads = Join-Path $TestDrive 'tools\downloads'
            ToolsExtracted = Join-Path $TestDrive 'tools\extracted'
        }
        foreach ($path in @($layout.ToolsBin, $layout.ToolsDownloads, $layout.ToolsExtracted)) {
            $null = New-Item -ItemType Directory -Path $path -Force
        }

        Mock Get-PlatformInfo { [pscustomobject]@{ Os = 'windows'; Architecture = 'amd64'; Description = 'test' } }
        Mock Resolve-ToolPath { param($Name, $ToolsBin) "C:\Tools\$Name.exe" }
        Mock Install-ExternalTool { throw 'Cached tools should not trigger a download.' }
        Mock Get-ToolHelpText { 'usage' }
        Mock Write-ReconLog { }

        $tools = Ensure-ReconTools -Layout $layout -EnableGau:$false -EnableWaybackUrls:$false -EnableHakrawler:$false

        if ($tools.Subfinder.Path -ne 'C:\Tools\subfinder.exe') { throw 'Expected cached required tools to be reused.' }
        if ($tools.Httpx.Path -ne 'C:\Tools\httpx.exe') { throw 'Expected cached httpx to be reused.' }
        if ($tools.Katana.Path -ne 'C:\Tools\katana.exe') { throw 'Expected cached katana to be reused.' }
    }

    It 'keeps optional bootstrap failures non-fatal and explains skipped enrichment' {
        $layout = [pscustomobject]@{
            ToolsBin       = Join-Path $TestDrive 'tools\bin'
            ToolsDownloads = Join-Path $TestDrive 'tools\downloads'
            ToolsExtracted = Join-Path $TestDrive 'tools\extracted'
        }
        foreach ($path in @($layout.ToolsBin, $layout.ToolsDownloads, $layout.ToolsExtracted)) {
            $null = New-Item -ItemType Directory -Path $path -Force
        }

        $script:warnings = @()
        Mock Get-PlatformInfo { [pscustomobject]@{ Os = 'windows'; Architecture = 'amd64'; Description = 'test' } }
        Mock Resolve-ToolPath {
            param($Name, $ToolsBin)
            switch ($Name) {
                'subfinder' { return 'C:\Tools\subfinder.exe' }
                'httpx' { return 'C:\Tools\httpx.exe' }
                'katana' { return 'C:\Tools\katana.exe' }
                default { return $null }
            }
        }
        Mock Install-ExternalTool { throw 'api.github.com:443' }
        Mock Get-ToolHelpText { 'usage' }
        Mock Write-ReconLog {
            param($Level, $Message, $Path)
            if ($Level -eq 'WARN') {
                $script:warnings += $Message
            }
        }

        $tools = Ensure-ReconTools -Layout $layout -EnableGau:$true -EnableWaybackUrls:$true -EnableHakrawler:$true

        if ($null -ne $tools.Gau) { throw 'Expected gau to stay optional after a download failure.' }
        if ($null -ne $tools.WaybackUrls) { throw 'Expected waybackurls to stay optional after a download failure.' }
        if ($null -ne $tools.Hakrawler) { throw 'Expected hakrawler to stay optional after a download failure.' }
        if ($script:warnings.Count -lt 3) { throw 'Expected an explicit warning for each optional bootstrap failure.' }
        if (-not ($script:warnings | Where-Object { $_ -like "*GitHub download failed or is blocked*" } | Select-Object -First 1)) {
            throw 'Expected optional download failures to explain that GitHub access may be blocked or offline.'
        }
    }

    It 'does not collide with the PowerShell Host automatic variable when building host records' {
        $record = New-HostInventoryRecord -TargetHost 'example.com'
        $hostMap = @{}
        $resolved = Get-OrCreateHostInventoryRecord -HostMap $hostMap -TargetHost 'example.com'

        if ($record.Host -ne 'example.com') { throw 'Expected host inventory records to preserve the target host name.' }
        if ($resolved.Host -ne 'example.com') { throw 'Expected host inventory lookup to return the created host record.' }
        if (-not $hostMap.ContainsKey('example.com')) { throw 'Expected host inventory lookup to populate the host map.' }
    }
}
