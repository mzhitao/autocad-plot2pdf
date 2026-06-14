param(
    [string]$InstallDir = "$env:ProgramFiles\PlotTools",
    [string]$Repo = "mzhitao/autocad-plot2pdf",
    [string]$Branch = "master"
)

$ErrorActionPreference = "Stop"

# --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "ERROR: Run as Administrator" -ForegroundColor Red; exit 1 }

# --- Detect AutoCAD ---
$autoCadPaths = @()
foreach ($base in "HKCU:\SOFTWARE\Autodesk\AutoCAD","HKLM:\SOFTWARE\Autodesk\AutoCAD","HKLM:\SOFTWARE\WOW6432Node\Autodesk\AutoCAD") {
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | ForEach-Object {
        $ver = $_
        Get-ChildItem -LiteralPath $ver.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            $loc = (Get-ItemProperty -LiteralPath $_.PSPath -Name "Location" -ErrorAction SilentlyContinue).Location
            if ($loc) { $autoCadPaths += @{ RegPath = $_.PSPath; Version = $ver.PSChildName; Product = $_.PSChildName } }
        }
    }
}
if ($autoCadPaths.Count -eq 0) { Write-Host "ERROR: AutoCAD not found" -ForegroundColor Red; exit 1 }
Write-Host "Found AutoCAD:" -ForegroundColor Cyan
$autoCadPaths | ForEach-Object { Write-Host "  $($_.Version) $($_.Product)" }

# --- Install files ---
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Write-Host "`nInstalling to: $InstallDir" -ForegroundColor Cyan

# Local mode = script was run from a file (not piped via iex)
$localMode = $false
if ($PSScriptRoot -and (Test-Path "$PSScriptRoot\plot-core.lsp")) { $localMode = $true }
$rawUrl = "https://raw.githubusercontent.com/$Repo/$Branch"
$files = @("plot-core.lsp","plot2pdf.lsp","plot2emf.lsp","plot-loader.lsp","plot-config.json","crop_pdf.exe")

foreach ($f in $files) {
    Write-Host "  $f ... " -NoNewline
    if ($localMode -and (Test-Path "$PSScriptRoot\$f")) {
        Copy-Item "$PSScriptRoot\$f" $InstallDir -Force
        Write-Host "OK (local)" -ForegroundColor Green
    } else {
        try {
            Invoke-WebRequest -Uri "$rawUrl/$f" -OutFile "$InstallDir\$f" -UseBasicParsing -ErrorAction Stop
            Write-Host "OK" -ForegroundColor Green
        } catch {
            Write-Host "skip" -ForegroundColor Yellow
        }
    }
}

# --- Config ---
$configPath = "$InstallDir\plot-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $config.modules_dir = $InstallDir.Replace("\", "\\") + "\\"
    $config | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    Write-Host "  config updated" -ForegroundColor Green
}

# --- Startup Suite ---
$loaderPath = "$InstallDir\plot-loader.lsp"
if (-not (Test-Path $loaderPath)) { Write-Host "`nERROR: plot-loader.lsp missing" -ForegroundColor Red; exit 1 }
$count = 0
foreach ($acad in $autoCadPaths) {
    $startupKey = "$($acad.RegPath)\Applications\AcadApp\Startup"
    if (-not (Test-Path $startupKey)) { New-Item -ItemType Directory -Path $startupKey -Force | Out-Null }
    $exists = $false
    $props = Get-ItemProperty -LiteralPath $startupKey -ErrorAction SilentlyContinue
    if ($props) { foreach ($p in $props.PSObject.Properties) { if ($p.Value -eq $loaderPath) { $exists = $true; break } } }
    if (-not $exists) {
        $next = 0
        if ($props) { $nums = $props.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }
            if ($nums) { $next = ($nums | ForEach-Object { [int]$_.Name } | Measure-Object -Maximum).Maximum + 1 } }
        Set-ItemProperty -LiteralPath $startupKey -Name "$next" -Value $loaderPath
        Write-Host "  added to $($acad.Version) startup" -ForegroundColor Green; $count++
    }
}
if ($count -eq 0) { Write-Host "  startup group already set" -ForegroundColor Yellow }

Write-Host "`nDone!" -ForegroundColor Green
Write-Host "  Install dir: $InstallDir"
Write-Host "  Commands: PLOT2PDF, PLOT2EMF"
Write-Host "  Restart AutoCAD to activate"
