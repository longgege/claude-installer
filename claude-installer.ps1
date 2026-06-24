#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code Native Installer (replaces npm version)

.DESCRIPTION
    Downloads Claude Code native Windows version from GitHub Releases and installs to ~/.local/bin.
    Also removes old npm version and sets PATH environment variable.

.EXAMPLE
    .\claude-installer.ps1
    .\claude-installer.ps1 -proxy
    .\claude-installer.ps1 -version "1.2.3"
    .\claude-installer.ps1 -clean-npm
    .\claude-installer.ps1 -proxy -clean-npm
    # Short aliases
    .\claude-installer.ps1 -p
    .\claude-installer.ps1 -v "1.2.3"
    .\claude-installer.ps1 -t "D:\tools\claude"
    .\claude-installer.ps1 -p -c

.NOTES
    Supports Windows 10/11, x64 and ARM64 architectures
#>

param(
    [Alias('v')]
    [string]$version = "latest",

    [Alias('t', 'target-dir')]
    [string]$targetDir = "",

    [Alias('p')]
    [switch]$proxy,

    [Alias('pu')]
    [string]$proxyUrl = "",

    [Alias('c', 'clean-npm')]
    [switch]$cleanNpm,

    [Alias('y', 'yes')]
    [switch]$autoConfirm,

    [Alias('h', 'help')]
    [switch]$showHelp
)

# Show help and exit
if ($showHelp) {
    Write-Host @"
Claude Code 原生版本安装器（Windows）

用法：
    .\claude-installer.ps1 [选项]

选项：
    -v, -version <字符串>    要安装的目标版本（默认：latest）
    -t, -target-dir <字符串> 自定义安装目录
                              （默认：~/.local/bin）
    -p, -proxy               启用内置代理池访问 GitHub
                              自动测试选择最快代理
    -pu, -proxy-url <字符串> 使用自定义代理 URL（跳过测速）
                              示例：-proxy-url "https://my-proxy.com/"
    -c, -clean-npm           安装前移除旧 npm 版本
    -y, -yes                 自动确认降级操作（跳过用户确认）
    -h, -help                显示此帮助信息

内置代理池：
    https://ghproxy.net/        (新增)
    https://gh-proxy.org/
    https://v4.gh-proxy.org/
    https://v6.gh-proxy.org/
    https://cdn.gh-proxy.org/

智能特性：
    - 下载缓存：复用缓存的 ZIP 文件避免重复下载
    - ZIP 验证：使用前验证下载/缓存的文件完整性
    - 文件占用检测：检测 claude.exe 是否正在使用
    - 重试支持：如果文件被占用，关闭 Claude 后重新运行即可完成

示例：
    # 基本安装
    .\claude-installer.ps1

    # 使用内置代理池（推荐国内用户）
    .\claude-installer.ps1 -p

    # 使用自定义代理 URL
    .\claude-installer.ps1 -proxy-url "https://my-proxy.com/"

    # 安装指定版本
    .\claude-installer.ps1 -v "1.2.3"

    # 自定义安装目录
    .\claude-installer.ps1 -target-dir "D:\tools\claude"

    # 自动降级（跳过确认）
    .\claude-installer.ps1 -v "1.2.0" -y

    # 清理 npm 版本 + 使用代理安装原生版本
    .\claude-installer.ps1 -p -c

"@ -ForegroundColor Cyan
    exit 0
}

# Color scheme
$ColorInfo    = "Cyan"
$ColorSuccess = "Green"
$ColorWarning = "Yellow"
$ColorError   = "Red"
$ColorDim     = "Gray"

$ErrorActionPreference = "Stop"

# Proxy pool - will rotate through these if one fails
$proxyPool = @(
    "https://ghproxy.net/",
    "https://gh-proxy.org/",
    "https://v4.gh-proxy.org/",
    "https://v6.gh-proxy.org/",
    "https://cdn.gh-proxy.org/"
)
$currentProxyIndex = 0

# Speed test timeout (milliseconds)
$speedTestTimeout = 8000

<#
.SYNOPSIS
    Test proxy speed using concurrent GET requests
.DESCRIPTION
    Tests all proxies concurrently and returns the index of the fastest one.
    Uses background jobs to measure connection latency.
#>
function Find-FastestProxyIndex {
    param(
        [string[]]$Proxies,
        [string]$TestUrl,
        [int]$TimeoutMs
    )

    Write-Host "测试代理速度 ($($Proxies.Count) 个代理)..." -ForegroundColor $ColorInfo

    # Create background jobs for concurrent testing
    $jobs = @()
    $jobMap = @{}  # Map job ID to proxy index

    for ($i = 0; $i -lt $Proxies.Count; $i++) {
        $proxy = $Proxies[$i]
        $testUri = "$proxy$TestUrl"

        $job = Start-Job -ScriptBlock {
            param($Uri, $Timeout)
            $latency = [double]::MaxValue
            $errorMsg = ""
            try {
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                # Use GET request (HEAD may be rejected by proxies)
                $request = [System.Net.WebRequest]::Create($Uri)
                $request.Method = "GET"
                $request.Timeout = $Timeout
                $request.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
                # Get response but don't read the body (just measure connection time)
                $response = $request.GetResponse()
                $timer.Stop()
                $latency = $timer.ElapsedMilliseconds
                $response.Close()
            } catch {
                # Timeout, connection error, or proxy rejection
                $errorMsg = $_.Exception.Message
            }
            # Return hashtable for proper deserialization
            return @{ Latency = $latency; Error = $errorMsg }
        } -ArgumentList $testUri, $TimeoutMs

        $jobs += $job
        $jobMap[$job.Id] = $i
    }

    # Wait for all jobs (timeout = max test timeout + buffer)
    $null = Wait-Job -Job $jobs -Timeout ([int]($TimeoutMs / 1000) + 3)

    # Collect results
    $results = @()
    foreach ($job in $jobs) {
        $output = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($output -and $output.Latency) {
            # Convert hashtable to PSCustomObject for proper sorting
            $results += [PSCustomObject]@{
                Index = $jobMap[$job.Id]
                Latency = $output.Latency
                Proxy = $Proxies[$jobMap[$job.Id]]
            }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    # Find fastest proxy (lowest latency)
    $validResults = $results | Where-Object { $_.Latency -lt [double]::MaxValue }

    if ($validResults.Count -gt 0) {
        $fastest = $validResults | Sort-Object -Property Latency | Select-Object -First 1
        Write-Host "最快代理: $($fastest.Proxy) ($($fastest.Latency)ms)" -ForegroundColor $ColorSuccess

        # Display all results for transparency
        $sorted = $validResults | Sort-Object -Property Latency
        $sorted | ForEach-Object {
            $color = if ($_.Proxy -eq $fastest.Proxy) { $ColorSuccess } else { $ColorDim }
            Write-Host "  $($_.Proxy): $($_.Latency)ms" -ForegroundColor $color
        }

        return $fastest.Index
    }

    # All proxies failed - use first as fallback
    Write-Host "警告: 所有代理测试超时，使用第一个代理" -ForegroundColor $ColorWarning
    return 0
}

# Handle custom proxy URL
if ($proxyUrl -ne "") {
    # Validate proxy URL format
    if ($proxyUrl -notmatch '^https?://') {
        Write-Host "警告：代理 URL 应以 http:// 或 https:// 开头" -ForegroundColor $ColorWarning
        $proxyUrl = "https://$proxyUrl"
    }

    # Ensure trailing slash for URL concatenation
    if ($proxyUrl -notmatch '/$') {
        $proxyUrl = "$proxyUrl/"
    }

    if ($proxy) {
        # Custom proxy with fallback to built-in pool
        $proxyPool = @($proxyUrl) + $proxyPool
    } else {
        # Only use custom proxy, no fallback
        $proxyPool = @($proxyUrl)
        $proxy = $true  # Enable proxy mode
    }
}

# Check for 32-bit Windows (reject WOW64)
if (-not [Environment]::Is64BitProcess) {
    Write-Host "不支持 32-bit Windows，请使用 64 位 Windows" -ForegroundColor $ColorError
    exit 1
}

# Use native ARM64 binary on ARM64 Windows, x64 otherwise
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $archSuffix = "arm64"
} else {
    $archSuffix = "x64"
}

# Set target directory
if ([string]::IsNullOrEmpty($targetDir)) {
    $targetDir = Join-Path $env:USERPROFILE ".local\bin"
}

# Display configuration
Write-Host "架构: $archSuffix | 安装目录: $targetDir" -ForegroundColor $ColorInfo
if ($proxy) {
    if ($proxyUrl -ne "") {
        Write-Host "代理: 用户指定 ($proxyUrl)" -ForegroundColor $ColorInfo
    } elseif ($proxyPool.Count -gt 1) {
        Write-Host "代理: 已启用 (将测试 $($proxyPool.Count) 个代理)" -ForegroundColor $ColorInfo
    } else {
        Write-Host "代理: 已启用" -ForegroundColor $ColorInfo
    }
}

<#
.SYNOPSIS
    Build URL with current proxy prefix
.DESCRIPTION
    Prepends the current proxy URL to the given URL if proxy mode is enabled.
    Returns the original URL unchanged if proxy mode is off.
#>
function Build-Url {
    param([string]$Url)
    if ($proxy) { return "$($proxyPool[$currentProxyIndex])$Url" }
    return $Url
}

<#
.SYNOPSIS
    Download file with proxy pool fallback
.DESCRIPTION
    Downloads a file with support for proxy pool rotation.
    Retries with each proxy in the pool until one succeeds.
#>
function Invoke-DownloadWithFallback {
    param(
        [string]$Uri,
        [string]$OutFile,
        [int]$TimeoutSec = 0
    )

    $maxAttempts = if ($proxy) { $proxyPool.Count } else { 1 }
    $attempt = 0

    while ($attempt -lt $maxAttempts) {
        $actualUri = Build-Url -Url $Uri
        Write-Host "下载: $actualUri" -ForegroundColor $ColorInfo
        try {
            Invoke-WebRequest -Uri $actualUri -UseBasicParsing -OutFile $OutFile
            return $true
        } catch {
            $attempt++
            if ($attempt -lt $maxAttempts -and $proxy) {
                $currentProxyIndex++
                if ($currentProxyIndex -lt $proxyPool.Count) {
                    Write-Host "切换代理: $($proxyPool[$currentProxyIndex])" -ForegroundColor $ColorWarning
                }
            } else {
                throw $_.Exception.Message
            }
        }
    }
}

<#
.SYNOPSIS
    Call REST API (bypasses GitHub file proxies)
.DESCRIPTION
    Makes a REST API call directly without using GitHub file proxies.
    Used for getting version info from npm registry or GitHub API.
#>
function Invoke-ApiRequest {
    param(
        [string]$Uri,
        [int]$TimeoutSec = 15
    )

    try {
        $params = @{ Uri = $Uri; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
        return Invoke-RestMethod @params
    } catch {
        throw $_.Exception.Message
    }
}

<#
.SYNOPSIS
    Normalize version format (ensure 'v' prefix for GitHub downloads)
#>
function Normalize-Version {
    param([string]$ver)
    if ($ver -notmatch '^v') {
        return "v$ver"
    }
    return $ver
}

<#
.SYNOPSIS
    Compare semantic versions using [version] type
.DESCRIPTION
    Compares two version strings. Strips pre-release suffixes (e.g. -beta) before comparison.
    Returns -1, 0, or 1 for less, equal, or greater.
#>
function Compare-Versions {
    param([string]$v1, [string]$v2)

    try {
        $v1 = [version](($v1 -replace '^v', '') -replace '-.*$', '')
        $v2 = [version](($v2 -replace '^v', '') -replace '-.*$', '')
        return $v1.CompareTo($v2)
    } catch {
        return 0
    }
}

<#
.SYNOPSIS
    Extract version number from version string
.DESCRIPTION
    Extracts the first x.y.z pattern from a version string.
    Returns the full string if no pattern is found.
#>
function Extract-VersionNumber {
    param([string]$versionString)
    if ($versionString -match '(\d+\.\d+\.\d+)') {
        return $Matches[1]
    }
    return $versionString
}

<#
.SYNOPSIS
    Remove cached ZIP files safely
.DESCRIPTION
    Removes cached ZIP files matching the given pattern.
    Silently skips files that cannot be deleted.
#>
function Remove-CachedZips {
    param([string]$Pattern)

    Get-ChildItem -Path $env:TEMP -Filter $Pattern -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { Write-Verbose "无法删除缓存文件: $($_.FullName)" }
        }
}

<#
.SYNOPSIS
    Check if a file is locked by another process
#>
function Test-FileLocked {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return $false }

    try {
        $fs = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

<#
.SYNOPSIS
    Validate ZIP file by checking size
.DESCRIPTION
    Checks if a ZIP file exists and is larger than 20MB (minimum valid size threshold).
#>
function Test-ZipValid {
    param([string]$ZipPath)

    if (-not (Test-Path $ZipPath)) { return $false }

    $file = Get-Item $ZipPath -ErrorAction SilentlyContinue
    # Check if file size > 20MB (minimum valid size threshold)
    return $file -and $file.Length -gt 20971520
}

# Determine if user specified version manually
$userSpecifiedVersion = $version -ne "latest"

# Get latest version info only if user didn't specify one
if (-not $userSpecifiedVersion) {
    $latestVersion = $null

    # Try npm registry first (skip GitHub file proxy)
    try {
        $response = Invoke-ApiRequest -Uri "https://registry.npmjs.org/@anthropic-ai/claude-code/latest"
        $latestVersion = $response.version
    } catch {}

    # Fallback to GitHub API (skip GitHub file proxy)
    if (-not $latestVersion) {
        try {
            $response = Invoke-ApiRequest -Uri "https://api.github.com/repos/anthropics/claude-code/releases/latest"
            $latestVersion = $response.tag_name
        } catch {}
    }

    if (-not $latestVersion) {
        Write-Error "无法获取版本信息"
        Write-Host "请手动指定版本: -v 'v1.0.0'" -ForegroundColor $ColorWarning
        exit 1
    }

    $version = Normalize-Version $latestVersion
} else {
    $version = Normalize-Version $version
}

# Check current installed version
$claudeExe = Join-Path $targetDir "claude.exe"
$currentInstalled = $null

if (Test-Path $claudeExe) {
    try {
        $versionOutput = (& $claudeExe --version 2>&1 | Out-String).Trim()
        $currentInstalled = Extract-VersionNumber $versionOutput
    } catch {
        # Version check failed, continue with installation
    }
}

# Compare versions and determine action
$targetVersionNum = Extract-VersionNumber $version

if ($currentInstalled) {
    $comparison = Compare-Versions $targetVersionNum $currentInstalled

    if ($comparison -eq 0) {
        Write-Host "已是最新版本 ($currentInstalled)，无需更新" -ForegroundColor $ColorSuccess
        exit 0
    } elseif ($comparison -lt 0) {
        # Downgrade - require user confirmation (unless -y is specified)
        Write-Host "降级: $currentInstalled -> $targetVersionNum" -ForegroundColor $ColorWarning

        if (-not $autoConfirm) {
            $confirm = Read-Host "确认降级? (y/N)"
            if ($confirm -notin @('y', 'Y')) {
                Write-Host "已取消" -ForegroundColor $ColorWarning
                exit 0
            }
        }
    } else {
        Write-Host "升级: $currentInstalled -> $targetVersionNum" -ForegroundColor $ColorInfo
    }
} else {
    Write-Host "安装: $targetVersionNum" -ForegroundColor $ColorInfo
}

# Build download URL (base URL without proxy prefix)
$baseUrl = "https://github.com/anthropics/claude-code/releases/download/$version/claude-win32-$archSuffix.zip"

# Create target directory
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

# Download path in TEMP directory
$zipPattern = "claude-win32-$archSuffix-$version*.zip"

# Find valid cached file (PowerShell 5.1 compatible)
$validCache = $null
$candidates = Get-ChildItem -Path $env:TEMP -Filter $zipPattern -ErrorAction SilentlyContinue |
              Where-Object { $_.Length -gt 20971520 } |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 3

# Validate candidates in a loop (avoid function call in pipeline for PS 5.1 compatibility)
foreach ($candidate in $candidates) {
    if (Test-ZipValid -ZipPath $candidate.FullName) {
        $validCache = $candidate
        break
    }
}

$skipDownload = $false
$zipPath = Join-Path $env:TEMP "claude-win32-$archSuffix-$version.zip"

if ($validCache) {
    $skipDownload = $true
    $zipPath = $validCache.FullName
    Write-Host "使用缓存: $zipPath" -ForegroundColor $ColorDim
} elseif (Test-Path $zipPath) {
    try { Remove-Item $zipPath -Force -ErrorAction Stop } catch {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $zipPath = Join-Path $env:TEMP "claude-win32-$archSuffix-$version-$timestamp.zip"
    }
}

# Test proxy speed only if we need to download
# Only test when: proxy enabled AND multiple built-in proxies AND no custom proxy specified AND no valid cache
if (-not $skipDownload -and $proxy -and $proxyPool.Count -gt 1 -and [string]::IsNullOrEmpty($proxyUrl)) {
    $currentProxyIndex = Find-FastestProxyIndex -Proxies $proxyPool -TestUrl $baseUrl -TimeoutMs $speedTestTimeout
} else {
    # Reset proxy index for download attempt
    $currentProxyIndex = 0
}

# Download if not cached
if (-not $skipDownload) {
    try {
        $null = Invoke-DownloadWithFallback -Uri $baseUrl -OutFile $zipPath

        # Validate downloaded ZIP file
        $isZipValid = Test-ZipValid -ZipPath $zipPath
        if (-not $isZipValid) {
            Write-Host "下载文件损坏" -ForegroundColor $ColorError
            Remove-Item $zipPath -Force
            exit 1
        }
    } catch {
        Write-Host "下载失败: $($_.Exception.Message)" -ForegroundColor $ColorError
        Write-Host "尝试使用代理: -p 或自定义代理: -proxy-url 'url'" -ForegroundColor $ColorWarning
        exit 1
    }
}

# Extract
Write-Host "解压: claude.exe..." -ForegroundColor $ColorInfo

# Check if claude.exe is currently in use
$fileLocked = Test-FileLocked -FilePath $claudeExe

if ($fileLocked) {
    Write-Host @"

========================================
  Claude Code 当前正在运行
========================================

"@ -ForegroundColor $ColorError
    Write-Host "无法替换正在使用中的 claude.exe。" -ForegroundColor $ColorError
    Write-Host ""
    Write-Host "解决方案：" -ForegroundColor $ColorDim
    Write-Host "  1. 关闭 Claude Code（按 Ctrl+C 或关闭终端）" -ForegroundColor $ColorDim
    Write-Host "  2. 重新运行此脚本 - 将自动使用缓存文件" -ForegroundColor $ColorDim
    Write-Host ""
    exit 1
}

try {
    Expand-Archive -Path $zipPath -DestinationPath $targetDir -Force
    Remove-CachedZips -Pattern $zipPattern
} catch {
    Write-Host @"

解压失败: 缓存文件可能损坏

解决方案：
  1. 删除损坏的缓存文件:
     Remove-Item "$zipPath" -Force

  2. 重新运行脚本重新下载

"@ -ForegroundColor $ColorError
    exit 1
}

# Remove old npm version (optional)
if ($cleanNpm) {
    npm uninstall -g @anthropic-ai/claude-code 2>&1 | Out-Null
}

# Add to PATH
$currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')

if ($currentPath -notmatch [regex]::Escape($targetDir)) {
    [Environment]::SetEnvironmentVariable('PATH', "$currentPath;$targetDir", 'User')
}

# Refresh current session PATH
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

# Verify installation
if (Test-Path $claudeExe) {
    try {
        $versionOutput = (& $claudeExe --version 2>&1 | Out-String).Trim()
        Write-Host "完成: $versionOutput" -ForegroundColor $ColorSuccess
    } catch {
        Write-Host "完成: claude.exe 已安装" -ForegroundColor $ColorSuccess
    }
} else {
    Write-Error "安装失败: 未找到 claude.exe"
    exit 1
}
