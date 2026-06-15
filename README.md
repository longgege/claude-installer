# Claude Code Native Installer (Windows)

Claude Code Windows 原生版本安装器。从 GitHub Releases 自动下载、解压、配置 PATH，支持国内代理加速、版本管理、缓存复用。

适用场景：国内网络环境安装 Claude Code、替代手动下载配置、版本升级降级管理。

## 一键安装

```powershell
irm https://raw.githubusercontent.com/longgege/claude-installer/main/claude-installer.ps1 -o claude-installer.ps1; .\claude-installer.ps1
```

国内网络（启用代理）：

```powershell
irm https://raw.githubusercontent.com/longgege/claude-installer/main/claude-installer.ps1 -o claude-installer.ps1; .\claude-installer.ps1 -p
```

## 用法

```powershell
# 基础安装
.\claude-installer.ps1

# 国内网络加速（推荐）
.\claude-installer.ps1 -p

# 安装指定版本
.\claude-installer.ps1 -v "1.2.0"

# 自定义安装目录
.\claude-installer.ps1 -t "D:\tools\claude"

# 使用自定义代理
.\claude-installer.ps1 -proxy-url "https://my-proxy.com/"

# 清理旧版本
.\claude-installer.ps1 -p -c
```

安装完成后运行 `claude --version` 验证。如命令未识别，重启终端刷新 PATH。

## 参数

| 参数 | 别名 | 说明 |
|------|------|------|
| `-version` | `-v` | 目标版本（默认最新） |
| `-target-dir` | `-t` | 安装目录（默认 `~/.local/bin`） |
| `-proxy` | `-p` | 启用内置代理池 |
| `-proxy-url` | `-pu` | 自定义代理 URL |
| `-clean-npm` | `-c` | 移除旧版本 |
| `-yes` | `-y` | 自动确认降级 |
| `-help` | `-h` | 显示帮助 |

## 常见问题

**安装失败？**

1. 检查网络，尝试 `-p` 启用代理
2. 关闭正在运行的 Claude Code 后重试
3. 删除 `%TEMP%\claude-win32-*.zip` 缓存后重试

## 相关资源

- [Claude Code 官方仓库](https://github.com/anthropics/claude-code)
- [Claude Code 文档](https://docs.anthropic.com/claude-code)