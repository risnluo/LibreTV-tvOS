# LibreTV tvOS

一个连接自建 [LibreTV](https://github.com/LibreSpark/LibreTV) 服务的原生 Apple TV 客户端。使用遥控器浏览海报榜单、搜索影片、阅读完整简介、选择剧集，并通过系统播放器观看。

这是独立开发的非官方客户端，与 LibreTV 上游项目没有隶属关系。仓库不包含 LibreTV 服务端、影视文件或预置片源地址。

<p align="center"><img src="Artwork/icon-preview.png" alt="LibreTV tvOS 图标" width="400"></p>

## 功能

- 连接自己的 LibreTV 服务器，支持密码登录和服务端默认片源。
- 沿用网页的电影周榜、国产剧周榜、海外剧周榜、国内综艺、海外综艺、百度热播剧。
- 加入热门电影、热门剧集、豆瓣高分电影和动漫新番，共十类推荐。
- 首页显示海报、片名和可用评分；缺图、缺评分时保留明确占位。
- 点海报后按片名搜索，核对片源与年份，再进入详情和选集。
- 详情支持海报、导演、演员和完整简介；长简介可用遥控器滚动阅读。
- 使用 AVPlayerViewController 播放 HLS，支持系统播放、暂停和进度控制。
- 榜单失败可重试或继续搜索；片源失败不丢弃其他搜索结果。

## 环境

- Apple TV：tvOS 17 或更新版本。
- Mac：完整 Xcode 和 tvOS SDK；Command Line Tools 不能构建电视界面。
- 一个自己部署并配置好默认片源的 LibreTV 服务。当前接口适配版本为 **2.16.12**，其他版本未经验证。
- Apple TV 与服务器之间可访问的局域网连接。

## 编译与安装

1. 下载本仓库，打开 `LibreTV.xcodeproj`，选择 `LibreTV` scheme。
2. 在 **Signing & Capabilities** 中选择自己的 Apple ID / Personal Team。
3. 将 Bundle Identifier 从示例 `org.example.LibreTV` 改成自己唯一的标识，例如 `com.yourname.LibreTV`；后续覆盖更新保持同一标识与团队。
4. 在 Apple TV 打开 **设置 → 遥控器与设备 → 远程 App 与设备**，在 Xcode 的 Device Hub 中配对。较旧 Xcode 的入口叫 Devices and Simulators。
5. 选择目标 Apple TV，点击 Run。首次运行时填入自己的服务器地址，例如 `http://libretv.local:8899`，然后登录。

免费 Personal Team 测试签名通常7天到期，需要重新签名安装；本项目不包含自动续签。仓库不提供个人签名IPA，使用者需用自己的开发签名安装，也未发布到 App Store。

## 使用流程

**连接服务器 → 登录 → 选择榜单或搜索 → 选择片源 → 阅读简介/选择剧集 → 播放**

榜单只提供推荐信息，不保证每部影片都有可用片源。标题可能重名，请核对年份和来源。简介来自选定片源，缺少简介时会明确提示。某些上游榜单（例如动漫新番）可能超时，切换榜单或重试即可。

## 隐私与网络

- 服务器地址仅保存在本机；密码和会话Cookie只在当前进程内，断开或重启后需要重新登录。
- 搜索、详情、推荐和封面读取都经过用户配置的 LibreTV 服务。NAS登录Cookie不会发送给第三方片源。
- 封面仅接受有效HTTP(S)地址及图片响应，限制单图5MiB，内存缓存32MiB/60项。
- 允许局域网地址访问；其余连接继续使用系统默认传输安全规则。公网连接应使用HTTPS。
- 本仓库没有统计上报、第三方Swift依赖、证书、访问令牌或预设家庭服务器地址。

## 开发与测试

核心使用 Foundation；界面使用 SwiftUI/UIKit/ImageIO，播放器使用 AVKit。

```sh
swift test --scratch-path /tmp/libretv-core-tests

xcodebuild -project LibreTV.xcodeproj -scheme LibreTV \
  -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath /tmp/libretv-simulator CODE_SIGNING_ALLOWED=NO build
```

如果系统当前选择的是 Command Line Tools，可在命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

核心测试覆盖地址与查询编码、十类推荐映射、数据清洗、图片大小与类型、缓存清理、会话过期及并发旧响应隔离。1.1开发验收包含模拟器登录、海报榜单、缺图占位、40段简介滚动、单集影片焦点、HLS播放/暂停与失败重试；目标Apple TV用户确认榜单、简介、选集、音画正常。未保证所有上游服务或所有影视资源始终可用，也未进行长时间整片覆盖测试。

仅有Command Line Tools时，可运行不依赖XCTest运行器的核心检查：

```sh
swiftc -swift-version 5 -D LIBRETV_SELF_CHECK \
  -module-cache-path /tmp/libretv-core-module-cache \
  Core/Models.swift Core/Recommendations.swift Core/LibreTVClient.swift Tests/LibreTVCoreTests.swift \
  -o /tmp/libretv-core-self-check
/tmp/libretv-core-self-check
```

目录：`Core/`接口与会话、`App/`界面和资源、`Tests/`合成测试、`Artwork/`图标源图与提示、`Tools/`尺寸导出工具。

## 已知边界

不包含自动续签、观看历史、收藏、跨设备同步或服务端部署功能。字幕、音轨和清晰度取决于片源；网页的广告过滤与分片缓存不自动继承到原生播放器。正常观看不需要开启Xcode远程屏幕共享。

## 许可证与致谢

本仓库独立编写的客户端代码和随附原创图标按 [MIT License](LICENSE) 发布。图标由AI生成，原图及生成说明在 `Artwork/`。

[LibreTV 服务端](https://github.com/LibreSpark/LibreTV) 是独立的上游项目，其代码使用 [AGPL-3.0](https://github.com/LibreSpark/LibreTV/blob/main/LICENSE)。本仓库仅通过HTTP接口与用户自己的服务通信，不包含或重新许可其服务端代码。第三方海报、影片和元数据不属于本仓库MIT许可范围；使用者需自行配置有权访问的内容来源。
