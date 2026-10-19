<p align="center">
  <img src="assets/branding/app-icon.png" width="96" alt="轻小说文库" />
</p>

<h1 align="center">轻小说文库</h1>

<p align="center">基于 Flutter 的 Android 轻小说阅读客户端</p>

<p align="center">
  <a href="https://github.com/mikufoxxx/Wenku8_Flutter/releases"><img src="https://img.shields.io/github/v/release/mikufoxxx/Wenku8_Flutter?style=flat-square&color=555555" alt="Release" /></a>
  <a href="https://github.com/mikufoxxx/Wenku8_Flutter/actions/workflows/flutter-ci.yml"><img src="https://github.com/mikufoxxx/Wenku8_Flutter/actions/workflows/flutter-ci.yml/badge.svg?branch=master" alt="Build" /></a>
  <img src="https://img.shields.io/badge/Platform-Android-555555?style=flat-square" alt="Android" />
  <a href="assets/licenses/GPL-3.0.txt"><img src="https://img.shields.io/badge/License-GPL--3.0-555555?style=flat-square" alt="GPL 3.0" /></a>
</p>

<p align="center">
  <a href="https://git.3952039.xyz/#releases">下载</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="https://github.com/mikufoxxx/Wenku8_Flutter/issues">问题反馈</a> ·
  <a href="docs/RELEASING.md">构建指南</a>
</p>

## 简介

轻小说文库是面向 Android 手机与平板的轻小说阅读客户端，集成书籍发现、书架管理、本地书库、离线阅读与在线听书。奶白玻璃材质、档案式排版与立体书架贯穿界面，阅读器支持滚动、横排翻页、竖排翻页和大屏对页。

## 界面预览

<p align="center">
  <img src="docs/images/discovery.png" width="30%" alt="发现" />
  &nbsp;
  <img src="docs/images/reader.png" width="30%" alt="阅读器" />
  &nbsp;
  <img src="docs/images/settings.png" width="30%" alt="设置" />
</p>

## 功能特性

- **书籍发现**：分类、排行、出版文库；按书名、作者或标签筛选搜索，点击详情页作者或标签查看相应书单。
- **书架管理**：立体书架支持循环轮播、惯性滚动、吸附与触觉反馈，可切换为纯列表；与本地书库共用自定义分类，分类可与阅读状态、书籍来源叠加筛选。
- **阅读排版**：上下滚动、横排翻页与竖排翻页，大屏对页；可选逐段接续、平移、覆盖、纸页翻动或无动画。配色、字号、行距、页边距、段落间距、缩进与对齐支持实时预览；支持导入 TTF／OTF，App 与阅读器可分别设置字体。
- **阅读工具**：可展开的分卷目录、书签定位与高亮、章内查找、封面与插图大图查看、双指缩放与原图保存、分区点按与音量键翻页、自动滚动与跨章衔接；可选择点书直接续读，在阅读器打开书籍详情。
- **离线阅读**：App 内章节缓存、缓存管理、阅读历史、进度续读与本地备份。
- **本地书库**：多选导入 TXT、EPUB、Kindle、FB2、PDF、DOCX、RTF、HTML、Markdown 与 ZIP；支持扫描共享存储或指定文件夹，勾选后导入。同系列分卷可合并，保留目录、插图与阅读记录；支持分类整理、书籍信息编辑与分卷顺序调整，可单独管理或与缓存书籍合并展示，并按来源筛选。
- **网盘与同步**：OpenList／WebDAV、夸克网盘导入（实验性），通过 OneDrive、Google Drive 等系统云文档入口手动合并同步原书与阅读记录。
- **在线听书**：中文音色、自定义 Microsoft SSML 接口、0.5～3 倍速、段落跟随、睡眠定时、后台与锁屏控制。
- **账号与社区**：文库账号、云书架、书评与回复。
- **中文支持**：简体中文、香港繁体与台湾繁体，可跟随系统或手动选择。
- **性能设置**：帧率偏好与低性能设备模式，可独立调整玻璃折射、模糊、动效与立体书架。
- **使用方式**：离线时隐藏发现、保留可离线阅读的书；阅读器模式保留本地或合并书架与「我的」，随书库展示方式联动。

## 下载与更新

当前正式版为 **[0.4.1 · build 88](https://github.com/mikufoxxx/Wenku8_Flutter/releases/tag/v0.4.1)**，功能与 0.3.7 一致，提供更高构建号供 0.4.0 用户覆盖升级回来。保留原有阅读器、书架、UI、动效、听书与本地导入；本次未加入其他功能调整或问题修复。详见[完整更新说明](CHANGELOG.md)。

> [!IMPORTANT]
> **本 APP 以后只保留轻小说文库源和本地导入功能，不再支持任何其他源以及自定义书源。**
>
> 应用名称保持 **「轻小说文库」**。0.4.0 已撤回；历史正式版安装包与对应源码包已恢复提供。
>
> **0.4.0 用户请覆盖升级到 0.4.1，不要先卸载。** 0.4.1 沿用原包名和签名，构建号 88 高于 0.4.0 的 87。建议升级前备份阅读记录，不要用原版 0.3.7 尝试普通覆盖降级。

常见 Android 手机与平板请选择 **ARM64**：

| 设备 | 安装包 |
| --- | --- |
| 常见手机、平板（推荐） | [ARM64 · arm64-v8a](https://git.3952039.xyz/#releases) |
| 旧款 32 位 ARM 设备 | [ARMv7 · armeabi-v7a](https://git.3952039.xyz/#releases) |
| x86_64 设备或模拟器 | [x86_64](https://git.3952039.xyz/#releases) |

可在 **我的 → 关于 → 检查更新** 获取 0.4.1。0.3.2 及以上正式版开启自动检查后，可收到新版本弹窗；选择稍后提醒，同一版本 24 小时内不再弹出。正式版沿用同一签名，0.3.7 和 0.4.0 均可覆盖升级到 0.4.1。

源码与其他版本见 [GitHub Releases](https://github.com/mikufoxxx/Wenku8_Flutter/releases)。

阅读与自定义语音见 [阅读器与本地书库](docs/READER.md)，网盘连接见 [网盘导入指南](docs/CLOUD_IMPORT.md)，标签与关键词用法见 [搜索指南](docs/SEARCH.md)。

## 构建

开发环境：**Flutter 3.41.5 / Dart 3.11.3、JDK 17、Android SDK**。

```sh
git clone https://github.com/mikufoxxx/Wenku8_Flutter.git
cd Wenku8_Flutter
flutter pub get
flutter build apk --release --target-platform android-arm64
```

### GitHub Actions

- [Flutter Android](https://github.com/mikufoxxx/Wenku8_Flutter/actions/workflows/flutter-ci.yml)：代码检查、自动测试与 ARM64 APK 构建。
- [Build Android APKs](https://github.com/mikufoxxx/Wenku8_Flutter/actions/workflows/android-release.yml)：三架构签名 APK、源码归档与版本发布候选，支持版本标签触发和手动运行。

签名配置与发布流程见 [构建发布指南](docs/RELEASING.md)。

## 友情链接

[LINUX DO 社区](https://linux.do/)

## 贡献

欢迎通过 [Issues](https://github.com/mikufoxxx/Wenku8_Flutter/issues) 反馈问题或提出建议，通过 Pull Request 参与开发。提交问题时请提供应用版本、Android 版本和复现步骤。

## 致谢与许可

本项目基于 [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android) 重构。感谢 MewX、Baby Pepper（SeraphRoy）、Jack Liu（aaassseee）及原项目贡献者。

- 应用源码：保留原项目 [GPL v2 或后续版本声明](LICENSE)，本 Flutter 组合版本按 [GPL v3](assets/licenses/GPL-3.0.txt) 分发。
- 内置字体：[Adobe Source Han Serif CN](https://github.com/adobe-fonts/source-han-serif)，[SIL OFL 1.1](assets/fonts/OFL-SourceHanSerif.txt)。
- 在线语音协议适配：[rany2/edge-tts](https://github.com/rany2/edge-tts)，[LGPL v3](assets/licenses/edge-tts.txt)。

完整版权声明与接口运行库分发条件见 [NOTICE](NOTICE) 和 [第三方组件许可](docs/THIRD_PARTY.md)。
