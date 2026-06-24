# Claude Installer 轻量重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 对 `claude-installer.ps1` 进行轻量重构，修复 bug、统一风格、提升健壮性

**Architecture:** 单文件 PowerShell 脚本，保持现有结构不变，逐块替换代码

**Tech Stack:** PowerShell 5.1+

**文件:** `claude-installer.ps1`（仅修改，不新增/删除文件）

---

### Task 1: 架构检测替换 + 颜色变量定义

**Files:**
- Modify: `claude-installer.ps1:108-118`（架构检测替换）
- Modify: `claude-installer.ps1:108`（插入颜色变量）

- [ ] **Step 1: 替换架构检测代码**

用官方方式替换当前架构检测：

```powershell
# Color scheme
$ColorInfo    = "Cyan"
$ColorSuccess = "Green"
$ColorWarning = "Yellow"
$ColorError   = "Red"
$ColorDim     = "Gray"

$ErrorActionPreference = "Stop"

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
```

- [ ] **Step 2: 确认替换位置正确**

读取 `$ErrorActionPreference` 所在行，确认 Task 1 的插入点准确。

- [ ] **Step 3: Commit**

```bash
git add claude-installer.ps1
git commit -m "refactor: 替换架构检测为官方方式，添加颜色变量定义"
```

---

### Task 2: 全局颜色引用替换

**Files:**
- Modify: `claude-installer.ps1`（全文替换 ForegroundColor 引用）

- [ ] **Step 1: 替换所有 `-ForegroundColor Cyan` → `-ForegroundColor $ColorInfo`**

涉及行：帮助信息保留 Cyan 硬编码不变量化，其余 `Cyan` 全部替换。

- [ ] **Step 2: 替换 `-ForegroundColor Green` → `-ForegroundColor $ColorSuccess`**

- [ ] **Step 3: 替换 `-ForegroundColor Yellow` → `-ForegroundColor $ColorWarning`**

- [ ] **Step 4: 替换 `-ForegroundColor Red` → `-ForegroundColor $ColorError`**（排除 `Write-Error` 自带红色除外）

- [ ] **Step 5: 替换 `-ForegroundColor Gray` → `-ForegroundColor $ColorDim`**

- [ ] **Step 6: Commit**

```bash
git add claude-installer.ps1
git commit -m "refactor: 统一输出颜色为语义化变量"
```

---

### Task 3: Test-FileLocked 修复

**Files:**
- Modify: `claude-installer.ps1`（函数定义替换）

- [ ] **Step 1: 替换 `Test-FileLocked` 函数**

```powershell
# Helper: Check if a file is locked
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
```

- [ ] **Step 2: Commit**

```bash
git add claude-installer.ps1
git commit -m "fix: 修复 Test-FileLocked 在文件不存在时误创建文件的问题"
```

---

### Task 4: 错误处理优化

**Files:**
- Modify: `claude-installer.ps1`

- [ ] **Step 1: 修复错误信息去重**

`Invoke-WebRequestWithFallback` 函数中，将 `throw "请求失败: $($_.Exception.Message)"` 改为 `throw $_.Exception.Message`（不拼接前缀）。

在下载调用方的 `catch` 块中，将：
```powershell
Write-Host "下载失败: $($_.Exception.Message)" -ForegroundColor Red
Write-Host "尝试使用代理: -p 或自定义代理: -proxy-url 'url'" -ForegroundColor Yellow
```
改为：
```powershell
Write-Host $_.Exception.Message -ForegroundColor $ColorError
Write-Host "尝试使用代理: -p 或自定义代理: -proxy-url 'url'" -ForegroundColor $ColorWarning
```

- [ ] **Step 2: 修复 `Remove-CachedZips` 空 catch**

```powershell
catch { Write-Verbose "无法删除缓存文件: $($_.FullName)" }
```

- [ ] **Step 3: 修复 `Compare-Versions` 预发布版本兼容**

```powershell
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
```

- [ ] **Step 4: Commit**

```bash
git add claude-installer.ps1
git commit -m "fix: 优化错误处理——去重、空 catch 日志、预发布版本兼容"
```

---

### Task 5: 函数职责拆分 + 注释

**Files:**
- Modify: `claude-installer.ps1`

- [ ] **Step 1: 拆分 `Invoke-WebRequestWithFallback`**

保留原函数为下载专用，改名为 `Invoke-DownloadWithFallback`：

```powershell
# Helper: Download file with proxy pool fallback
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
```

新增 `Invoke-ApiRequest`：

```powershell
# Helper: Call REST API (bypasses GitHub file proxies)
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
```

- [ ] **Step 2: 更新调用点**

将原来调用 `Invoke-WebRequestWithFallback -SkipProxy` 的地方改为 `Invoke-ApiRequest`。

将原来调用 `Invoke-WebRequestWithFallback` 下载的地方改为 `Invoke-DownloadWithFallback`。

- [ ] **Step 3: 为所有函数添加标准注释块**

为以下函数添加 `<# .SYNOPSIS #>` 注释：
- Find-FastestProxyIndex
- Build-Url
- Invoke-DownloadWithFallback
- Invoke-ApiRequest
- Normalize-Version
- Compare-Versions
- Extract-VersionNumber
- Remove-CachedZips
- Test-FileLocked
- Test-ZipValid

- [ ] **Step 4: Commit**

```bash
git add claude-installer.ps1
git commit -m "refactor: 拆分下载/API 函数，添加标准注释块"
```

---

### Task 6: 代码风格整理

**Files:**
- Modify: `claude-installer.ps1`

- [ ] **Step 1: 删除文件末尾多余空行（6 行）**

- [ ] **Step 2: 统一 `if(` / `函数名(` 空格**

搜索 `if(` -> `if (`, 搜索 `函数名(` 添加空格。

- [ ] **Step 3: 布尔变量重命名**

`$zipValid` → `$isZipValid`

- [ ] **Step 4: Commit**

```bash
git add claude-installer.ps1
git commit -m "style: 清理尾部空行，统一空格风格，变量命名规范化"
```

---

### Task 7: 最终验证

- [ ] **Step 1: 语法检查**

```powershell
powershell -NoProfile -Command "& { Set-StrictMode -Version Latest; .\claude-installer.ps1 -h }"
```

预期：正确显示帮助信息，无语法错误。

- [ ] **Step 2: 确认所有变更已提交**

```bash
git log --oneline -10
git diff --stat HEAD~6..HEAD
```

- [ ] **Step 3: 检查最终脚本行数变化**

```bash
gc claude-installer.ps1 | measure -Line
```