$ErrorActionPreference = "Stop"
$InstallDir = "$env:ProgramFiles\PlotTools"
$Repo = "mzhitao/autocad-plot2pdf"
$Branch = "master"

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { echo "ERROR: Run as Administrator"; exit 1 }

# Detect AutoCAD
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
if ($autoCadPaths.Count -eq 0) { echo "ERROR: AutoCAD not found"; exit 1 }
echo "Found AutoCAD:"
$autoCadPaths | ForEach-Object { echo "  $($_.Version) $($_.Product)" }

# Install
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
echo "`nInstalling to: $InstallDir"

$rawUrl = "https://raw.githubusercontent.com/$Repo/$Branch"
foreach ($f in @("plot-core.lsp","plot2pdf.lsp","plot2emf.lsp","plot-loader.lsp","plot-config.json","crop_pdf.exe")) {
    echo "  $f ..."
    try {
        Invoke-WebRequest -Uri "$rawUrl/$f" -OutFile "$InstallDir\$f" -UseBasicParsing -ErrorAction Stop
        echo "OK"
    } catch {
        echo "skip"
    }
}

# Config
$configPath = "$InstallDir\plot-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $config.modules_dir = $InstallDir.Replace("\", "\\") + "\\"
    $config | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    echo "  config updated"
}

# Startup Suite
$loaderPath = "$InstallDir\plot-loader.lsp"
if (-not (Test-Path $loaderPath)) { echo "ERROR: plot-loader.lsp missing"; exit 1 }
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
        echo "  added to $($acad.Version) startup"; $count++
    }
}
if ($count -eq 0) { echo "  startup group already set" }

echo "`nDone!"
echo "  Install dir: $InstallDir"
echo "  Commands: PLOT2PDF, PLOT2EMF"
echo "  Restart AutoCAD to activate"
