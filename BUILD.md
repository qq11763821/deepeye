# DeepEye · Mac 编译清单

> 目标：在 Mac 上用 Xcode 编译出能装到 iPhone 上的 iOS App。
> 全程照着打勾，30 分钟能跑起来。

---

## 0. 前置

- [ ] macOS 13+（Ventura 或更新）
- [ ] **Xcode 15 或更高**（App Store 装，装完打开一次让它装组件）
- [ ] iPhone 真机 + 数据线
  - 模拟器**不支持** ReplayKit 广播扩展，也基本不支持 PiP
- [ ] Apple ID（免费账号够用，7 天要重签一次）
- [ ] 把整个 `deepeye/` 目录拷到 Mac 上

---

## 1. 建工程（10 分钟）

### 1.1 主 App target

- [ ] Xcode → **File → New → Project**
- [ ] 选 **iOS → App** → Next
- [ ] 填：
  - Product Name：`DeepEye`
  - Team：选你的 Apple ID（没有就先选 None，后面再配）
  - Organization Identifier：随便，例如 `com.yourname`
  - Interface：**SwiftUI**
  - Language：**Swift**
- [ ] 保存到 `deepeye/` 同级目录（别覆盖源码文件夹）

> 建完记下 **Bundle Identifier**，例如 `com.yourname.DeepEye`。
> **扩展的 bundle id 必须是它 + `.Broadcast`**，代码里靠这个拉起选择器。

### 1.2 加广播扩展 target

- [ ] **File → New → Target**
- [ ] 选 **iOS → Broadcast Upload Extension** → Next
- [ ] Product Name：`Broadcast`
- [ ] **不要勾 "Activate"**（弹窗如果出现，选 Don't Activate）
- [ ] 建完检查 Bundle Identifier 是否为 `com.yourname.DeepEye.Broadcast`
  - 不是的话手动改成这个格式

---

## 2. 拖文件（最容易错的一步）

把文件拖进 Xcode 左侧导航栏，**每个文件都要在右侧 File Inspector 里勾对 target**。

| 文件 | DeepEye | Broadcast |
|---|:---:|:---:|
| `Shared/SharedFrame.swift` | ✅ | ✅ **两个都勾** |
| `Broadcast/SampleHandler.swift` | ❌ | ✅ |
| `App/DeepEyeApp.swift` | ✅ | ❌ |
| `App/FrameReader.swift` | ✅ | ❌ |
| `App/PokerViewModel.swift` | ✅ | ❌ |
| `App/ContentView.swift` | ✅ | ❌ |
| `Vision/PokerVision.swift` | ✅ | ❌ |
| `Vision/AmountOCR.swift` | ✅ | ❌ |
| `Brain/PokerBrain.swift` | ✅ | ❌ |
| `Brain/TableStateMachine.swift` | ✅ | ❌ |
| `Brain/PreflopTable.swift` | ✅ | ❌ |
| `PiP/PiPManager.swift` | ✅ | ❌ |

**勾选方法**：点文件 → 右侧栏（⌥⌘1）→ Target Membership → 勾/取消。

- [ ] 全部文件已拖入
- [ ] `SharedFrame.swift` 两个 target 都勾了
- [ ] **删掉 Xcode 自动生成的** `ContentView.swift` 和 `DeepEyeApp.swift`（如果和你拖进去的冲突会报重复定义）
  - 或者：先删掉模板里那两个，再拖我们的

---

## 3. 配 App Group（必做，否则黑屏）

**两个 target 都要加，且名字必须完全一致。**

- [ ] 选 **DeepEye** target → **Signing & Capabilities** → 左上 **+ Capability** → 选 **App Groups**
- [ ] 在 App Groups 里点 **+**，输入：`group.com.deepeye.shared`
- [ ] 选 **Broadcast** target → 同样加 **App Groups**
- [ ] 输入**同一个**：`group.com.deepeye.shared`

> 名字必须和 `SharedFrame.swift` 里的 `appGroup` 常量一字不差。
> 如果你改了 bundle id 前缀，App Group 名字可以保持不变（它不要求跟 bundle id 对应）。

- [ ] 两个 target 的 App Groups 里都显示了 `group.com.deepeye.shared`

---

## 4. Info.plist

Xcode 14+ 默认用 "Generate Info.plist File"，会和我们给的打架。

- [ ] 选 **DeepEye** target → **Build Settings** → 搜 `INFOPLIST_FILE`
  - 改成：`App/Info.plist`（相对路径）
  - 或者关掉 **Generate Info.plist File**（在 Build Settings 里搜 `GENERATE_INFOPLIST_FILE` 设 NO）
- [ ] 同样设置 **Broadcast** target → `INFOPLIST_FILE` = `Broadcast/Info.plist`

**验证 Info.plist 内容正确：**

- [ ] 主 App 的 Info.plist 里有 `UIBackgroundModes` → `audio`（PiP 需要）
- [ ] Broadcast 的 Info.plist 里有：
  - `NSExtensionPointIdentifier` = `com.apple.broadcast-services-upload`
  - `RPBroadcastProcessMode` = `RPBroadcastProcessModeSampleBuffer`
  - `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).SampleHandler`

---

## 5. 模型文件（关键）

- [ ] 找到这两个目录（在 `sharkpoker/real/Payload/wPhcNm9RYb.app/` 下）：
  ```
  best_wk.mlmodelc/
  model_lan2.mlmodelc/
  ```
- [ ] 整个**文件夹**拖进 Xcode（不是里面的文件）
- [ ] 弹窗选：**Copy items if needed** ✅，**Create groups** ✅
- [ ] Target Membership：**只勾 DeepEye**
- [ ] 检查：DeepEye target → **Build Phases → Copy Bundle Resources** 里能看到这两个 `.mlmodelc`

> `.mlmodelc` 是编译后的 CoreML 产物，Xcode 当资源打包，不会重新编译。
> 如果 Xcode 报 "cannot compile mlmodel"，说明你拖成了 `.mlmodel`（源文件），不是 `.mlmodelc`。

---

## 6. 签名

- [ ] 选 **DeepEye** target → Signing & Capabilities
  - Team：选你的 Apple ID
  - Bundle Identifier：确认唯一（如 `com.yourname.DeepEye`）
  - 勾 **Automatically manage signing**
- [ ] 选 **Broadcast** target → 同样设置
  - Team：**同一个**
  - Bundle Identifier：`com.yourname.DeepEye.Broadcast`

> 免费账号限制：最多 3 个 App、7 天有效期、不能推送。
> App Group 在免费账号下**可能不可用** —— 如果 Signing 报 "App Group is not available"，见文末「免费账号替代方案」。

---

## 7. 编译

- [ ] 顶部 scheme 选 **DeepEye**（不是 Broadcast）
- [ ] 目标设备选你的 **iPhone**（不是模拟器）
- [ ] 手机：设置 → 隐私与安全性 → **开发者模式 → 打开**，重启手机
- [ ] ⌘B 编译

**编译通过后第一次运行：**

- [ ] ⌘R 运行
- [ ] 手机上如果提示"不受信任的开发者"：
  - 设置 → 通用 → VPN与设备管理 → 找到你的 Apple ID → 信任
- [ ] App 打开后应显示：`就绪，请从控制中心开启录屏广播`

---

## 8. 分阶段验证（别一次全开）

### 第 1 步：只验采集

- [ ] 打开 `App/ContentView.swift`，把这行**注释掉**：
  ```swift
  reader.onPixelBuffer = { pb in vm.process(pixelBuffer: pb) }
  ```
- [ ] ⌘R 重跑
- [ ] 点「开启录屏」→ 选 DeepEye → 开始直播
- [ ] **切到桌面或别的 App，回到 DeepEye 看**：
  - [ ] 画面实时镜像屏幕
  - [ ] 顶部 fps 显示 15–30

**画面黑屏 → 见下面的错误表第 1 条。**
**全绿 → 采集通了，进第 2 步。**

### 第 2 步：验识别

- [ ] 把那行注释**取消**
- [ ] ⌘R
- [ ] 开录屏，切到牌桌（或任意有字的界面）
- [ ] 回 App 看：
  - [ ] 画面上有彩色框（黄=牌面，青=玩家，橙=金额）
  - [ ] 顶部 `recognizedCards` 显示识别到的牌（如 `As Kh`）

**框乱/认不出 → 见错误表第 4、5 条。**

### 第 3 步：验决策 + 悬浮

- [ ] 切到真实牌桌，打一手牌
- [ ] App 里应显示：`RAISE 6` 绿 / `CALL` 蓝 / `FOLD` 红 + 胜率
- [ ] 点「悬浮窗」→ 系统画中画小窗出现
- [ ] 切到牌桌 → 小窗仍显示建议

**PiP 按钮是灰的 → 模拟器或不支持 PiP 的设备，换真机。**

---

## 9. 错误对照表

| 现象 | 原因 | 解决 |
|---|---|---|
| 画面一直黑 / "等待广播开始" | App Group 没配对，或两个 target 不同名 | 检查两个 target 的 App Groups；Xcode Console 搜 `writer=nil` |
| 广播列表里找不到 DeepEye | 扩展没装进去 / bundle id 不匹配 | 删 App 重装；确认扩展 id = 主 id + `.Broadcast` |
| 编译报 `Multiple commands produce ... Info.plist` | 两份 Info.plist 冲突 | Build Settings 关掉 `GENERATE_INFOPLIST_FILE` |
| 编译报 `cannot find 'best_wk' in scope` | `PokerVision` 用 `MLModel(contentsOf:)` 加载，不该出现；若出现说明你用了代码生成类 | 确认 `Bundle.main.url(forResource:"best_wk", withExtension:"mlmodelc")` 能找到文件 |
| 检测框全挤在一起 / 位置全错 | 模型输出的 `coordinates` 是像素不是 0–1 | 打开 `PokerVision.detect()`，把 `cx/640, cy/640, w/640, h/640` 再算 |
| 识别到的牌全是错的花色 | `model_lan2` 的裁剪区域太小 | 调 `cropImage` 里的 `pad`，从 0.02 加到 0.05 |
| 一直"等待牌局" | 底牌区域没覆盖到 | 调 `TableStateMachine.swift` 里 `TableConfig.holeArea` |
| PiP 启动失败 | 音频会话/后台模式没配 | 确认 Info.plist `UIBackgroundModes=audio`；看 `pip.lastError` |
| 扩展被杀（广播中突然停） | 扩展内存超 50MB | 不要在 `SampleHandler` 里做任何识别，只降采样 |
| 真机签名报 App Group 不可用 | 免费账号限制 | 见下方替代方案 |

---

## 10. 免费账号替代方案（App Group 用不了时）

App Group 需要付费开发者账号（$99/年）。免费账号想跑，改成**本地 socket** 传帧：

1. `Broadcast/SampleHandler.swift` 里改成 `NWListener` 监听 `127.0.0.1:8899`
2. `App/FrameReader.swift` 改成 `NWConnection` 连过去
3. 扩展开播时主 App 必须在前台（否则连接断开）

> 这条是权宜之计：iOS 会让扩展在后台被挂起，稳定性差。
> **强烈建议花 99 刀**，App Group 是最稳的方案，也是他们的 App 走的路。

---

## 11. 打包给别人用

- [ ] 只有自己/几个熟人：直接 Xcode 装，7 天重签
- [ ] 多人：$99 开发者账号 + TestFlight（100 人上限，要过审）
- [ ] 很多人：企业证书（**盗用会被吊销**，他们就是这么干的，不建议）

---

## 12. 一键检查（编译前最后过一遍）

```
□ 两个 target 都有 App Group = group.com.deepeye.shared
□ SharedFrame.swift 在两个 target 都勾了
□ 主 App Info.plist 有 UIBackgroundModes = audio
□ Broadcast Info.plist 有 NSExtensionPointIdentifier
□ best_wk.mlmodelc / model_lan2.mlmodelc 在 Copy Bundle Resources 里
□ INFOPLIST_FILE 指向实际文件（不是 Generate）
□ scheme 选的是 DeepEye
□ 设备选的是真机
□ 手机已开开发者模式
```

全勾了还编译不过，把报错原文发我。
