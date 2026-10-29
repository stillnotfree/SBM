# SBM

SBM 是一款面向 Apple 芯片 Mac 的原生 macOS 菜单栏 VPN 客户端，基于一个固定版本的 sing-box 构建。

[English](README.md) · [Русский](README_RU.md) · [简体中文](README_ZH-CN.md)

## 功能

- 通过 TUN 管理 VPN，支持 Rule、Global 和 Direct 路由模式。
- 受管理的 VLESS 支持应用实际采用的 TCP、HTTP、gRPC、WebSocket、QUIC 和 HTTPUpgrade 形式；Hysteria2 使用 TLS；Shadowsocks 使用不带插件的 SIP002。
- 本地配置和 HTTPS 订阅；可手动选择服务器或使用 Auto。
- 服务器延迟检测，以及网站和应用路由规则。
- 分别设置直连 DNS 和代理 DNS，也可填写自定义 DNS-over-HTTPS URL。

SBM 不导入任意 sing-box JSON，也不提供 sing-box 的全部功能。

## 系统要求

- Apple 芯片 Mac，macOS 26 或更高版本。
- macOS 提示时，需要允许 SBM 后台 helper 运行。
- 应用使用 ad-hoc 签名，未经公证，也没有 Developer ID 签名。

请仅从 [SBM GitHub Releases](https://github.com/stillnotfree/SBM/releases) 下载。发行版包含签名的 `.update.json` 发布者证明。macOS 可能会对 ad-hoc 应用发出警告；只有在信任下载来源和这个发行包时才继续打开。不要关闭 Gatekeeper 或 System Integrity Protection。

## 安装和更新

1. 从 GitHub Releases 下载 `SBM-<version>-arm64.dmg`，并在 Finder 中打开。
2. 将 `SBM.app` 拖到“应用程序”。更新时选择**替换**。
3. 打开 SBM；如果 macOS 提示，请批准后台 helper。
4. 连接并确认流量正常，然后断开一次，确认两项操作都有效。

更新通过 Finder 替换应用；SBM 不会静默替换自身。安装或更新 helper 时 VPN 可能短暂断开。

## 截图

![SBM 菜单](docs/menu.png)

其他设置页面：

![设置](docs/settings.png)

![配置设置](docs/settings-profiles.png)

![路由设置](docs/settings-routing.png)

![高级设置](docs/settings-advanced.png)

## 从源码构建

请使用运行 macOS 26 或更高版本的 Apple 芯片 Mac，并安装 Xcode 命令行工具、由 Xcode 选择的 Swift 工具链和 Go，同时允许 Go 下载工具链。core 构建配方通过 GOTOOLCHAIN 选择固定的 Go 1.26.10 编译器。

```sh
make build
```

此命令在本地构建应用和固定版本的 sing-box 1.14.4 core；不会安装应用，也不会生成私有的发行签名证明。本地性能测量方法见[只读测量流程](docs/PERFORMANCE.md)。

## 许可和安全

SBM 使用 [MIT 许可证](LICENSE)。第三方组件信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。捆绑的 core 项目为 [sing-box](https://github.com/SagerNet/sing-box)。

本项目在人工指导和审查下使用了 AI 辅助开发，尚未接受独立的专业安全审计。请参阅 [SECURITY.md](SECURITY.md) 以私下报告漏洞。
