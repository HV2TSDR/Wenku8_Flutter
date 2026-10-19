# 原应用内嵌的 API 运行库

各 ABI 目录中的 `libcpp.so` 来自原版文库 Android v1.30 应用的内嵌运行库，用于既有 `TokenManager.getMagicVersionCpp` JNI 入口。Flutter 工程原样复用，没有修改这些二进制。

项目维护者确认可在保持原样的条件下再分发。构建配置对该文件关闭符号裁剪，发布工作流逐架构核对 APK 内的原始字节。对应 JNI 源码未包含在本工作区；独立授权条件见根目录 `docs/THIRD_PARTY.md`。
