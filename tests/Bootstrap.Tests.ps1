$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
. (Join-Path $repoRoot 'Launch-ScopeForgeFromGitHub.ps1')

Describe 'ScopeForge bootstrap refresh' {
    It 'renders bootstrap status when cache timestamps are unavailable' {
        Mock Write-Host { }

        Show-BootstrapStatusPanel -BootstrapRoot (Join-Path $TestDrive 'bootstrap-null-status') -RepositoryOwner 'Z3PHIRE' -RepositoryName 'ScopeForge' -Branch 'main' -LauncherPath (Join-Path $TestDrive 'Launch-ScopeForge.ps1') -UpdatedUtc $null -WillRefresh:$true -ForcedRefresh:$false -RefreshReason 'First download' -RemoteVersionKey $null -AppliedVersionKey $null -VersionCheckStatus 'Remote version key unavailable.' -CheckedAtUtc $null -AutoRefreshHours 24
    }

    It 'writes bootstrap metadata when the last checked timestamp is unavailable' {
        $bootstrapRoot = Join-Path $TestDrive 'bootstrap-null-manifest'
        $filesToFetch = Get-BootstrapFilesToFetch

        foreach ($relativePath in $filesToFetch) {
            $targetPath = Join-Path $bootstrapRoot $relativePath
            $targetDirectory = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $targetDirectory)) {
                $null = New-Item -ItemType Directory -Path $targetDirectory -Force
            }
            Set-Content -LiteralPath $targetPath -Encoding utf8 -Value 'cached'
        }

        $manifestPath = Write-BootstrapManifest -BootstrapRoot $bootstrapRoot -RepositoryOwner 'Z3PHIRE' -RepositoryName 'ScopeForge' -Branch 'main' -FilesToFetch $filesToFetch -LastRefreshUtc ([DateTime]::UtcNow) -LastCheckedUtc $null -AppliedVersionKey $null -RemoteVersionKey $null -VersionCheckStatus 'Remote version key unavailable.' -RefreshReason 'Initial cache'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10

        if ($null -ne $manifest.LastCheckedUtc) { throw 'Expected LastCheckedUtc to remain null when the remote version check has not completed.' }
    }

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

        $manifestPath = Write-BootstrapManifest -BootstrapRoot $bootstrapRoot -RepositoryOwner 'Z3PHIRE' -RepositoryName 'ScopeForge' -Branch 'main' -FilesToFetch $filesToFetch -LastRefreshUtc ([DateTime]::UtcNow) -LastCheckedUtc ([DateTime]::UtcNow) -AppliedVersionKey 'abc123' -RemoteVersionKey 'def456' -VersionCheckStatus 'Remote version key differs from the local cache.' -RefreshReason 'A newer upstream version key was detected; refreshing the bootstrap cache.'
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Expected bootstrap-manifest.json to be written.' }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        if ($manifest.RepositoryName -ne 'ScopeForge') { throw 'Expected manifest to retain repository metadata.' }
        if (@($manifest.Files).Count -ne $filesToFetch.Count) { throw 'Expected manifest to describe each cached bootstrap file.' }
        if ($manifest.AppliedVersionKey -ne 'abc123') { throw 'Expected manifest to retain the applied version key.' }
        if ($manifest.RemoteVersionKey -ne 'def456') { throw 'Expected manifest to retain the remote version key.' }
    }

    It 'refreshes when the upstream version key changes' {
        Mock Read-BootstrapManifest {
            [pscustomobject]@{
                AppliedVersionKey = 'old-version'
            }
        }
        Mock Get-BootstrapFileEntries {
            @(
                [pscustomobject]@{
                    RelativePath = 'Launch-ScopeForge.ps1'
                    FullPath     = 'C:\Temp\Launch-ScopeForge.ps1'
                    Exists       = $true
                }
            )
        }
        Mock Test-BootstrapNeedsRefresh { $false }
        Mock Get-BootstrapRemoteVersionKey {
            [pscustomobject]@{
                Success      = $true
                Key          = 'new-version'
                CheckedAtUtc = [DateTime]::UtcNow
                Status       = 'Remote version key loaded from GitHub.'
                Source       = 'github-commit'
                ErrorMessage = $null
            }
        }

        $plan = Get-BootstrapRefreshPlan -BootstrapRoot (Join-Path $TestDrive 'bootstrap-plan') -RepositoryOwner 'Z3PHIRE' -RepositoryName 'ScopeForge' -Branch 'main' -FilesToFetch @('Launch-ScopeForge.ps1') -ForceRefresh:$false -AutoRefreshHours 24

        if (-not $plan.WillRefresh) { throw 'Expected a refresh when the remote version key changes.' }
        if ($plan.RemoteVersionKey -ne 'new-version') { throw 'Expected the remote version key to be surfaced in the plan.' }
        if ($plan.RefreshReason -notlike '*newer upstream version key*') { throw 'Expected a clear refresh reason when a newer upstream version exists.' }
    }

    It 'reuses the cache when the upstream version key matches' {
        Mock Read-BootstrapManifest {
            [pscustomobject]@{
                AppliedVersionKey = 'same-version'
            }
        }
        Mock Get-BootstrapFileEntries {
            @(
                [pscustomobject]@{
                    RelativePath = 'Launch-ScopeForge.ps1'
                    FullPath     = 'C:\Temp\Launch-ScopeForge.ps1'
                    Exists       = $true
                }
            )
        }
        Mock Test-BootstrapNeedsRefresh { $false }
        Mock Get-BootstrapRemoteVersionKey {
            [pscustomobject]@{
                Success      = $true
                Key          = 'same-version'
                CheckedAtUtc = [DateTime]::UtcNow
                Status       = 'Remote version key loaded from GitHub.'
                Source       = 'github-commit'
                ErrorMessage = $null
            }
        }

        $plan = Get-BootstrapRefreshPlan -BootstrapRoot (Join-Path $TestDrive 'bootstrap-plan-match') -RepositoryOwner 'Z3PHIRE' -RepositoryName 'ScopeForge' -Branch 'main' -FilesToFetch @('Launch-ScopeForge.ps1') -ForceRefresh:$false -AutoRefreshHours 24

        if ($plan.WillRefresh) { throw 'Expected the cache to be reused when the version key matches.' }
        if ($plan.VersionCheckStatus -notlike '*matches the local cache*') { throw 'Expected the plan to explain that the version key matches.' }
    }
}
