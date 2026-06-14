param(
    [string]$InstallDir = "$env:ProgramFiles\PlotTools",
    [string]$Repo = "mzhitao/autocad-plot2pdf",
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"

# ---------- 管理员权限 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host "需要管理员权限" -ForegroundColor Red; exit 1 }

# ---------- 检测 AutoCAD ----------
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
if ($autoCadPaths.Count -eq 0) { Write-Host "未检测到 AutoCAD" -ForegroundColor Red; exit 1 }
Write-Host "检测到 AutoCAD:" -ForegroundColor Cyan
$autoCadPaths | ForEach-Object { Write-Host "  $($_.Version) $($_.Product)" }

# ---------- 安装 ----------
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

Write-Host "`n安装到: $InstallDir" -ForegroundColor Cyan

# 本地模式: 从同目录复制
$localMode = Test-Path "$PSScriptRoot\plot-core.lsp"
$rawUrl = "https://raw.githubusercontent.com/$Repo/$Branch"

$files = @("plot-core.lsp","plot2pdf.lsp","plot2emf.lsp","plot-loader.lsp","plot-config.json","crop_pdf.exe")
foreach ($f in $files) {
    Write-Host "  $f ..." -NoNewline
    if ($localMode -and (Test-Path "$PSScriptRoot\$f")) {
        Copy-Item "$PSScriptRoot\$f" $InstallDir -Force
        Write-Host " OK (本地)" -ForegroundColor Green
    } else {
        try {
            Invoke-WebRequest -Uri "$rawUrl/$f" -OutFile "$InstallDir\$f" -UseBasicParsing -ErrorAction Stop
            Write-Host " OK" -ForegroundColor Green
        } catch {
            Write-Host " 跳过" -ForegroundColor Yellow
        }
    }
}

# ---------- 配置 ----------
$configPath = "$InstallDir\plot-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $config.modules_dir = $InstallDir.Replace("\", "\\") + "\\"
    $config | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    Write-Host "  plot-config.json 已更新" -ForegroundColor Green
}

# ---------- 添加启动组 ----------
$loaderPath = "$InstallDir\plot-loader.lsp"
if (-not (Test-Path $loaderPath)) { Write-Host "`n错误: plot-loader.lsp 未安装" -ForegroundColor Red; exit 1 }
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
        Write-Host "  已添加到 $($acad.Version) 启动组" -ForegroundColor Green; $count++
    }
}
if ($count -eq 0) { Write-Host "  启动组已存在，跳过" -ForegroundColor Yellow }

Write-Host "`n安装完成!" -ForegroundColor Green
Write-Host "  目录: $InstallDir"
Write-Host "  命令: PLOT2PDF, PLOT2EMF"
Write-Host "  重启 AutoCAD 生效"
