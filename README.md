# Grokoo

Grokoo 是 Grok Bot 的 macOS 桌面状态伙伴。在普通应用后方显示最多 6 只角色，通过底部工作区呈现任务状态，并保留已完成结果供用户收起。

## 使用

- 在设置中选择显示的 Bot、MBTI 和工作区顺序。
- 从“工作区”菜单进入角色区域，支持鼠标、Tab 和键盘操作。
- `⌘⌥W` 进入工作区，Delete 收起当前完成结果，`⌘⌥D` 全部收起，Escape 退出焦点。
- 完成通知需在设置中开启；三秒内完成的任务合并提醒，等待回复不会触发通知。
- 系统开启“减少动态效果”时停止巡游和循环动作。

Grokoo 只读取本机 Gateway 的身份与状态元数据，不保存 Prompt、回复正文、文件名或详细错误。真实受阻状态仍需要 Gateway 提供结构化信号。

## 构建

需要 macOS 14 或更高版本、支持 Swift 6 的 Xcode，以及 XcodeGen。

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Grokoo.xcodeproj -scheme Grokoo -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/Grokoo.app
```

运行时需在本机安装并登录 Grok Bot。当前版本为 1.1，build 11。

## 验证

```sh
xcodegen generate
xcodebuild -project Grokoo.xcodeproj -scheme Grokoo -configuration Debug -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
```

完整的 Debug、测试、Release 与资源检查可运行 `./scripts/verify.sh`，另需安装 `ripgrep` 和 `jq`。生成的工程、构建产物与检查输出不进入版本库。

Debug 构建包含 Experience Check，可在“工作区”菜单切换布局与状态。

```sh
open -n --env GROKOO_EXPERIENCE_FIXTURE=idle .build/Build/Products/Debug/Grokoo.app
```

首次用 Grokoo 替换旧名称的应用时，退出旧实例后再启动。应用沿用原有身份，以保留设置和完成记录。

第三方代码来源与许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
