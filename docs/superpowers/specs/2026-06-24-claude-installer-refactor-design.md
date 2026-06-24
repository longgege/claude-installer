# Claude Installer 轻量重构设计文档

## 概述

对 `claude-installer.ps1` 进行轻量重构（方案 A），保持单文件结构不变，修复 bug、统一风格、提升健壮性和可维护性。

## 变更清单

### 1. 架构检测（替换为官方方式）

**现状：** 使用 `[Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')`，
对 WOW64（32-bit PowerShell on 64-bit Windows）返回 `"x86"`。

**改为：**

```powershell
if (-not [Environment]::Is64BitProcess) {
    Write-Host "不支持 32-bit Windows，请使用 64 位 Windows" -ForegroundColor $ColorError
    exit 1
}

if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $archSuffix = "arm64"
} else {
    $archSuffix = "x64"
}
```

参考自 <https://claude.ai/install.ps1>。

### 2. 颜色体系统一

**现状：** 15+ 处 `-ForegroundColor Cyan/Green/Yellow/Red/Gray` 硬编码。

**改为：** 脚本顶部定义语义化颜色变量：

| 变量 | 用途 | 色值 |
|------|------|------|
| `$ColorInfo` | 进度/信息提示 | Cyan |
| `$ColorSuccess` | 成功完成 | Green |
| `$ColorWarning` | 警告 | Yellow |
| `$ColorError` | 错误 | Red |
| `$ColorDim` | 次要/辅助信息 | Gray |

所有 `Write-Host` 调用改为引用变量。帮助信息（`showHelp`）保持 Cyan 不变（集中在一处，不需变量化）。

### 3. 文件锁检测修复

**现状：** `Test-FileLocked` 用 `[System.IO.File]::OpenWrite($FilePath)`，存在两个问题：
- 文件不存在时 **会创建新文件**（首次安装误判为未锁定）
- 正常检查与使用之间有时窗竞争

**改为：**

```powershell
function Test-FileLocked {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $false }
    try {
        $fs = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch { return $true }
}
```

- 先检查文件存在性，不存在返回 `$false`
- `Open` + `FileShare.None` 确保文件当前没有被任何进程以写入方式打开

### 4. 错误处理优化

#### 4a. 错误信息去重

**现状：** `Invoke-WebRequestWithFallback` 内 `throw "请求失败: ..."`，调用方 `catch` 又 `Write-Host`，导致同一个错误输出两次。

**改为：** `Invoke-WebRequestWithFallback` 只 throw，调用方统一用 `Write-Host "$($_.Exception.Message)" -ForegroundColor $ColorError` 输出一次。

#### 4b. `Remove-CachedZips` 空 catch

**现状：** `catch {}` 静默吞错误，删除失败无任何输出。

**改为：** `catch { Write-Verbose "无法删除缓存文件: $($_.FullName)" }`。

#### 4c. `Compare-Versions` 预发布版本

**现状：** 形如 `1.2.3-beta` 的版本号转 `[version]` 会抛异常，`catch { return 0 }` 导致错误判断。

**改为：** 剥离 `-*` 后缀后再转换：

```powershell
function Compare-Versions {
    param([string]$v1, [string]$v2)
    try {
        $v1 = [version](($v1 -replace '^v', '') -replace '-.*$', '')
        $v2 = [version](($v2 -replace '^v', '') -replace '-.*$', '')
        return $v1.CompareTo($v2)
    } catch { return 0 }
}
```

### 5. 函数职责拆分

**现状：** `Invoke-WebRequestWithFallback` 同时处理文件下载和 API 调用，`$SkipProxy` 分支增加逻辑复杂度。

**改为：** 拆分为两个函数：

| 新函数 | 职责 | 代理 |
|--------|------|------|
| `Invoke-DownloadWithFallback` | 下载 ZIP 文件，支持代理池轮换 | ✅ |
| `Invoke-ApiRequest` | 调用 npm/GitHub API 获取版本信息 | ❌（直连） |

### 6. 代码风格整理

| 项目 | 做法 |
|------|------|
| 尾部空行 | 删除文件末尾多余的 6 行空行 |
| 空格统一 | `if(` → `if (`, `函数名(` → `函数名 (` |
| 大括号风格 | 统一为 `if (条件) {` 同行风格 |
| 布尔变量命名 | `$zipValid` → `$isZipValid` |
| 函数注释 | 所有函数添加 `<# .SYNOPSIS #>` 标准注释 |
| PowerShell 标准动词 | 已有较规范，微调几处 |

## 不变的部分

- 单文件结构（保持一键安装体验）
- 代理池逻辑（Find-FastestProxyIndex 的 Start-Job 方案虽然非最优，但对用户可接受）
- 参数接口（参数名、别名、行为均不变）
- ZIP 验证逻辑（Test-ZipValid 的大小阈值方案合理）
- 主流程顺序（读取版本 → 检查当前 → 比较 → 下载 → 解压 → 配置 PATH）
