# ScopeForge - Améliorations et Correctifs Appliqués

## Correctifs d'erreurs (V1)

### 1. CI/CD - Version Pester
**Fichier:** `.github/workflows/ci.yml`

**Problème:** La CI utilisait Pester 3.4.0 mais les tests étaient écrits en syntaxe Pester 5.

**Solution:** Mise à jour vers Pester 5.x avec `New-PesterConfiguration`

```yaml
# Avant
$requiredPesterVersion = [version]'3.4.0'

# Après
Install-Module -Name Pester -MinimumVersion 5.0
$config = New-PesterConfiguration
$config.Run.Path = '.\tests'
$config.Run.Exit = $true
```

### 2. Compatibilité PowerShell 5.1 et Linux
**Fichier:** `ScopeForge.ps1` - Fonction `Get-PlatformInfo`

**Problème:** Utilisation de variables PowerShell 7+ (`$IsWindows`, `$IsLinux`, `$IsMacOS`) non disponibles dans PowerShell 5.1.

**Solution:** Détection multi-plateforme avec fallback :

```powershell
# Compatibilite PowerShell 5.1 et PowerShell 7+
$os = $null
if (Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue) {
    # PowerShell 7+
    if ($IsWindows) { $os = 'windows' }
    elseif ($IsLinux) { $os = 'linux' }
    elseif ($IsMacOS) { $os = 'darwin' }
} else {
    # PowerShell 5.1 (Windows-only) ou fallback
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $os = 'windows'
    } else {
        $envOS = [System.Environment]::OSVersion.Platform
        if ($envOS -match 'Win') { $os = 'windows' }
        elseif ($envOS -match 'Unix') { $os = 'linux' }
        else { $os = 'windows' }
    }
}
```

## Améliorations de Couverture (V2 - À implémenter)

### Nouveaux outils de reconnaissance

| Outil | Purpose | Repository |
|-------|---------|------------|
| `nuclei` | Scan de vulnérabilités | `projectdiscovery/nuclei` |
| `ffuf` | Fuzzing web | `joohoi/ffuf` |
| `dnsx` | DNS toolkit | `projectdiscovery/dnsx` |
| `nmap` | Port scanning | `nmap/nmap` |
| `whatweb` | Web fingerprinting | `urbanadventurer/WhatWeb` |
| `dirsearch` | Directory brute-forcing | `maurosoria/dirsearch` |

### Paramètres à ajouter dans `ScopeForge.ps1`

```powershell
# Nouveaux paramètres pour Invoke-BugBountyRecon
[bool]$EnableNuclei = $false,
[bool]$EnableFfuf = $false,
[bool]$EnableDnsx = $false,
[bool]$EnableNmap = $false,
[string]$NucleiTemplates = '',
[string]$FfufWordlist = '',
[ValidateSet('none', 'fast', 'normal', 'aggressive')][string]$ScanProfile = 'fast'
```

### Fonction de scan parallèle

Pour lancer plusieurs fenêtres/processus en parallèle et aller plus vite :

```powershell
function Start-ParallelRecon {
    param(
        [string[]]$Targets,
        [int]$MaxConcurrency = 5,
        [scriptblock]$ScanScript
    )
    
    $jobs = @()
    foreach ($target in $Targets) {
        while ((Get-Job -State Running).Count -ge $MaxConcurrency) {
            Start-Sleep -Milliseconds 500
        }
        $jobs += Start-Job -ScriptBlock $ScanScript -ArgumentList $target
    }
    
    $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job
}
```

## Améliorations de Fiabilité (V3 - À implémenter)

### 1. Retry avec backoff exponentiel

```powershell
function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$BaseDelaySeconds = 5
    )
    
    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        try {
            return & $ScriptBlock
        } catch {
            $attempt++
            if ($attempt -ge $MaxAttempts) { throw }
            $delay = $BaseDelaySeconds * [Math]::Pow(2, $attempt)
            Write-Warning "Attempt $attempt failed. Retrying in ${delay}s..."
            Start-Sleep -Seconds $delay
        }
    }
}
```

### 2. Health checks des outils

```powershell
function Test-ToolHealth {
    param([string]$ToolPath)
    
    try {
        $version = & $ToolPath -version 2>&1
        return $null -ne $version
    } catch {
        return $false
    }
}
```

## Améliorations Interface Utilisateur (V4 - À implémenter)

### Dashboard temps réel

```powershell
function Show-ReconDashboard {
    param(
        [string]$Status,
        [int]$Progress,
        [string]$CurrentTool,
        [hashtable]$Stats
    )
    
    Clear-Host
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  ScopeForge - Reconnaissance Dashboard" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Status: $Status" -ForegroundColor $(if ($Status -eq 'Running') { 'Green' } else { 'Yellow' })
    Write-Host "  Progress: $Progress%" -ForegroundColor Green
    Write-Host "  Current: $CurrentTool" -ForegroundColor White
    Write-Host ""
    Write-Host "  Statistics:" -ForegroundColor Cyan
    foreach ($key in $Stats.Keys) {
        Write-Host "    $key`: $($Stats[$key])" -ForegroundColor Gray
    }
}
```

## Utilisation Recommandée

### Pour les contrats d'analyse

1. **Scope minimal** (test rapide) :
```powershell
Invoke-BugBountyRecon -ScopeFile ./scopes/minimal.json -Depth 2 -ScanProfile fast
```

2. **Scope standard** (analyse complète) :
```powershell
Invoke-BugBountyRecon -ScopeFile ./scopes/standard.json -Depth 4 -ScanProfile normal -EnableNuclei
```

3. **Scope avancé** (maximum coverage) :
```powershell
Invoke-BugBountyRecon -ScopeFile ./scopes/advanced.json -Depth 6 -ScanProfile aggressive -EnableNuclei -EnableFfuf -EnableDnsx
```

### Parallélisation pour vitesse maximale

```powershell
# Lancer plusieurs instances en parallèle
$targets = Get-ScopeTargets -ScopeFile ./scope.json
Start-ParallelRecon -Targets $targets -MaxConcurrency 3 -ScanScript {
    param($target)
    Invoke-BugBountyRecon -ScopeFile $target -OutputDir "./output/$([System.IO.Path]::GetFileNameWithoutExtension($target))"
}
```

## Fichiers Modifiés

| Fichier | Modification | Status |
|---------|-------------|--------|
| `.github/workflows/ci.yml` | Pester 5.x | ✅ Appliqué |
| `ScopeForge.ps1` | Get-PlatformInfo PS5.1 compatible | ✅ Appliqué |
| `ScopeForge.ps1` | EnableNuclei, EnableFfuf, EnableDnsx | ⏳ À faire |
| `ScopeForge.ps1` | Start-ParallelRecon | ⏳ À faire |
| `Launch-ScopeForge.ps1` | Dashboard amélioré | ⏳ À faire |

## Prochaines Étapes

1. Ajouter les nouveaux outils (nuclei, ffuf, dnsx)
2. Implémenter le scanning parallèle
3. Améliorer le dashboard UI
4. Ajouter des templates nuclei custom
5. Créer des profiles de scan prédéfinis
