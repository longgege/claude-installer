# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Single-script PowerShell installer for Anthropic's Claude Code native Windows binary. Downloads `claude-win32-{x64,arm64}.zip` from GitHub Releases, extracts to `~/.local/bin`, manages PATH, supports proxy pooling for Chinese users bypassing GitHub restrictions.

## Commands

```powershell
# Basic install (latest version)
.\claude-installer.ps1

# With built-in proxy pool (recommended for China)
.\claude-installer.ps1 -p

# Specific version
.\claude-installer.ps1 -v "1.2.0"

# Custom install directory
.\claude-installer.ps1 -t "D:\tools\claude"

# Custom proxy URL (skips speed test)
.\claude-installer.ps1 -proxy-url "https://my-proxy.com/"

# Remove npm global version only (standalone clean)
.\claude-installer.ps1 -c

# Clean npm + install with proxy
.\claude-installer.ps1 -p -c

# Auto-confirm downgrade
.\claude-installer.ps1 -p -y
```

There are **no tests, no build scripts, no CI/CD** — the script is standalone. Validate changes by running the script with relevant flags against a test directory (`-t`).

## Script Architecture (`claude-installer.ps1`)

Requirements: `#Requires -Version 5.1`, targets Windows 10/11 (x64 and ARM64). Rejects 32-bit (WOW64).

### Parameters

| Switch/Param    | Alias   | Default         | Purpose                              |
|-----------------|---------|-----------------|--------------------------------------|
| `-version`      | `-v`    | `"latest"`      | Target version string                 |
| `-targetDir`    | `-t`    | `~/.local/bin`  | Installation directory                |
| `-proxy`        | `-p`    | `$false`        | Enable built-in proxy pool            |
| `-proxyUrl`     | `-pu`   | `""`            | Custom proxy URL (skips speed test)   |
| `-cleanNpm`     | `-c`    | `$false`        | Remove npm global `@anthropic-ai/claude-code` |
| `-autoConfirm`  | `-y`    | `$false`        | Auto-confirm downgrade (skip prompt)  |
| `-showHelp`     | `-h`    | `$false`        | Show help text and exit               |

### Execution Flow (linear, in order)

1. **Proxy init** — parse `-proxyUrl` custom proxy; optionally merge with built-in pool (`-proxy`)
2. **Architecture check** — detect x64 vs ARM64; reject WOW64 (32-bit)
3. **Target dir** — default `~/.local/bin`, normalize with `Convert-Path`-like logic
4. **Standalone clean** — if only `-c` is passed, remove npm global version and exit immediately
5. **Version resolution** — if `-v latest`, query npm registry (primary `registry.npmmirror.com` with proxy, `registry.npmjs.org` without; fallback swapped), then GitHub API as last resort
6. **Combined clean** — if `-c` is paired with other flags, run npm cleanup before install
7. **Existing install detection** — check `~/.local/bin/claude.exe`, scan PATH, detect winget-installed claude.exe interactively
8. **Version comparison** — determine upgrade/downgrade/fresh; prompt for downgrade (Y/n with 10s timeout, default Y)
9. **Cache check** — search `%TEMP%` for `claude-win32-*.zip` > 20MB; reuse if valid
10. **Proxy speed test** — only if multiple proxies available AND no valid cache AND no custom URL
11. **Download** — download ZIP with proxy fallback rotation; validate > 20MB
12. **Extract** — check file locks; `Expand-Archive` to target dir
13. **PATH update** — add target dir to user PATH if not present
14. **Verification** — run `claude.exe --version` to confirm

### Internal Functions

| Function | Purpose |
|----------|---------|
| `Find-FastestProxyIndex` | Tests built-in proxies with 1500ms timeout; short-circuits on < 350ms |
| `Build-Url` | Prepends proxy URL (when proxy mode enabled) |
| `Invoke-DownloadWithFallback` | Downloads with proxy rotation; `$ProgressPreference = 'SilentlyContinue'` |
| `Invoke-ApiRequest` | REST API calls directly (bypasses GitHub file proxies); used for npm/GitHub API |
| `Normalize-Version` | Ensures `v` prefix |
| `Compare-Versions` | Semver comparison via `[version]` type, strips pre-release suffixes |
| `Extract-VersionNumber` | Extracts `x.y.z` from version string |
| `Remove-CachedZips` | Deletes cached ZIPs from `%TEMP%` by pattern; skips locked files |
| `Test-FileLocked` | Detects if a file is in use by another process |
| `Test-ZipValid` | Validates zip > 20MB; silent on nonexistent |

### Built-in Proxy Pool (ordered by preference)

```
https://ghproxy.net/
https://gh-proxy.org/
https://v4.gh-proxy.org/
https://v6.gh-proxy.org/
https://cdn.gh-proxy.org/
```

### Source URLs (download targets)

- **GitHub API**: `https://api.github.com/repos/anthropics/claude-code/releases/latest`
- **npm registry (with proxy)**: `registry.npmmirror.com` (primary), `registry.npmjs.org` (fallback)
- **npm registry (no proxy)**: `registry.npmjs.org` (primary), `registry.npmmirror.com` (fallback)

### Design Conventions

- **All messages in Chinese** — Write-Host output, prompts, error messages, help text
- **Color-coded output** — `$Host.UI.RawUI.ForegroundColor` for status messages (green=success, yellow=warning, red=error, cyan=info)
- **Interactive prompts** — `$Host.UI.PromptForChoice()` for Y/N, `Read-Host` for path input; 10s timeout on downgrade prompt
- **Silent progress** — `$ProgressPreference = 'SilentlyContinue'` before all downloads
- **No external dependencies** — pure PowerShell, no modules, no NuGet packages
- **Cache path**: `$env:TEMP\claude-win32-{arch}-{version}.zip`