$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repoRoot 'Launch-ScopeForgeFromGitHub.ps1')

Describe 'ScopeForge bootstrap refresh' {
    It 'requests an auto-refresh when the cached bootstrap is stale' {
        $bootstrapRoot = Join-Path $TestDrive 'bootstrap-stale'
        $filesToFetch = Get-BootstrapFilesToFetch

        foreach ($relativePath in $filesToFetch) {
            $targetPath = Join-Path $bootstrapRoot $relativePath
            $targetDirectory = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDirectory)) {
                $null = New-Item -ItemType Directory -Path $targetDirectory -Force
            }
            Set-Content -LiteralPath $targetPath -Encoding utf8 -Value 'stale'
            (Get-Item -LiteralPath $targetPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-48)
        }

        if (-not (Test-BootstrapNeedsRefresh -BootstrapRoot $bootstrapRoot -FilesToFetch $filesToFetch -AutoRefreshHours 24)) {
            throw 'Expected stale cached bootstrap files to trigger auto-refresh.'
        }
    }

    It 'keeps a fresh bootstrap cache when files are recent' {
        $bootstrapRoot = Join-Path $TestDrive 'bootstrap-fresh'
        $filesToFetch = Get-BootstrapFilesToFetch

        foreach ($relativePath in $filesToFetch) {
            $targetPath = Join-Path $bootstrapRoot $relativePath
            $targetDirectory = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDirectory)) {
                $null = New-Item -ItemType Directory -Path $targetDirectory -Force
            }
            Set-Content -LiteralPath $targetPath -Encoding utf8 -Value 'fresh'
            (Get-Item -LiteralPath $targetPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-30)
        }

        if (Test-BootstrapNeedsRefresh -BootstrapRoot $bootstrapRoot -FilesToFetch $filesToFetch -AutoRefreshHours 24) {
            throw 'Expected fresh cached bootstrap files to stay reusable.'
        }
    }

    It 'writes bootstrap metadata for the cached files' {
        $bootstrapRoot = Join-Path $TestDrive 'bootstrap-manifest'
        $filesToFetch = Get-BootstrapFilesToFetch

        foreach ($relativePath in $filesToFetch) {
            $targetPath = Join-Path $bootstrapRoot $relativePath
            $targetDirectory = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDirectory)) {
                $null = New-Item -ItemType Directory -Path $targetDirectory -Force
            }
            Set-Content -LiteralPath $targetPath -Encoding utf8 -Value 'cached'
        }

        $manifestPath = Write-BootstrapManifest -BootstrapRoot $bootstrapRoot -RepositoryOwner 'Z3PHIRE' -RepositoryName 'ScopeForge' -Branch 'main' -FilesToFetch $filesToFetch -LastRefreshUtc ([DateTime]::UtcNow)
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Expected bootstrap-manifest.json to be written.' }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        if ($manifest.RepositoryName -ne 'ScopeForge') { throw 'Expected manifest to retain repository metadata.' }
        if (@($manifest.Files).Count -ne $filesToFetch.Count) { throw 'Expected manifest to describe each cached bootstrap file.' }
    }
}
