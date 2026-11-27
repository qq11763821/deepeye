# DeepEye · 全自动扑克辅助（iOS）

**目标**：跟他们一样 —— 录屏 → 自动识别 → 自动决策 → 显示"跟/弃/加"。

```
┌── BroadcastUploadExtension ──────────────────────────┐
│ ReplayKit 采样整屏帧 → 降采样 640×360 BGRA            │
│ → mmap 共享内存 + Darwin 通知                         │
└───────────────────────┬──────────────────────────────┘
                        ▼
┌── 主 App ────────────────────────────────────────────┐
│ FrameReader      读共享内存 → UIImage + CVPixelBuffer │
│        ↓                                             │
│ PokerVision      best_wk 定位 → 裁牌区 → model_lan2  │
│                  → 点数+花色                          │
│ AmountOCR        Vision OCR 读底池/跟注               │
│        ↓                                             │
│ TableStateMachine  逐帧累积成一手牌（街道/底牌/公共牌）│
│        ↓                                             │
│ PokerBrain       翻前查表 / 翻后蒙特卡洛 → 决策        │
│        ↓                                             │
│ ContentView      画面 + 检测框 + 大字建议             │
└──────────────────────────────────────────────────────┘
```

## 文件清单

| 文件 | 作用 | 加到哪个 target |
|---|---|---|
| `Shared/SharedFrame.swift` | mmap 共享帧通道 | **两个都勾** |
| `Broadcast/SampleHandler.swift` | 录屏扩展 | Broadcast |
| `App/FrameReader.swift` | 读帧 → UIImage + CVPixelBuffer | 主 App |
| `App/PokerViewModel.swift` | 串起识别→状态机→决策 | 主 App |
| `App/ContentView.swift` | UI + 检测框 + 决策面板 | 主 App |
| `Vision/PokerVision.swift` | 两阶段 YOLO 识别 | 主 App |
| `Vision/AmountOCR.swift` | 金额 OCR | 主 App |
| `Brain/PokerBrain.swift` | 决策引擎（翻前表 + 翻后蒙特卡洛） | 主 App |
| `Brain/TableStateMachine.swift` | 状态机 | 主 App |
| `Brain/PreflopTable.swift` | 翻前策略表（自动生成） | 主 App |
| `PiP/PiPManager.swift` | 画中画悬浮窗 | 主 App |

## 资源（必须拖进主 App bundle）

从逆向的真实包里拷：

```
sharkpoker/real/Payload/wPhcNm9RYb.app/best_wk.mlmodelc
sharkpoker/real/Payload/wPhcNm9RYb.app/model_lan2.mlmodelc
```

拖进 Xcode 时选 **Copy items if needed** + 主 App target。

> 模型是 CoreML 编译产物（`.mlmodelc`），Xcode 当作资源打包即可，不会重新编译。

## 编译步骤

1. Xcode 15+，建 **App** + **Broadcast Upload Extension** 两个 target
2. 按上表把文件拖进对应 target（`SharedFrame.swift` 两边都勾）
3. 两个 target 都加 App Group：`group.com.deepeye.shared`
4. 替换两份 Info.plist（`App/Info.plist`、`Broadcast/Info.plist`）
5. 两个 target 选同一个 Team 签名
6. 把两个 `.mlmodelc` 拖进主 App
7. 真机 Run

## 验证顺序（重要）

**别一次全开，按顺序验，出问题好定位。**

### 第 1 步：只验采集（P0）

把 `ContentView` 里的 `reader.onPixelBuffer` 那行注释掉，只看画面能不能实时显示。

- ✅ 画面跟着屏幕变、fps 15–30 → 采集通了
- ❌ 黑屏 → App Group 没配对

### 第 2 步：验识别

打开管线，看画面上的**检测框**：
- 黄色框 = 牌面，青色 = 玩家，橙色 = 金额
- 顶部 `recognizedCards` 显示识别到的牌（如 `As Kh`）

如果框偏 / 认错：
- 检查输入分辨率（模型固定 640×640）
- 检查坐标是否归一化（YOLO 输出 `cx,cy,w,h`）
- 两个模型的 `coordinates` 是否都是 0–1（如果输出像素值，要除以 640）

### 第 3 步：验决策

切到真实牌桌，看底部大字：
- `RAISE 6` 绿色 / `CALL` 蓝色 / `FOLD` 红色
- 旁边显示胜率

如果一直"等待牌局"：
- 底牌没识别到 → 调 `TableConfig.holeArea`（默认 `y 0.72~0.88`）
- 或者庄位/人数没识别

## 平台适配（必调）

`TableStateMachine.swift` 里的 `TableConfig` 是**按常见竖屏布局估的**，实际必须按平台改：

```swift
var holeArea   = CGRect(x: 0.30, y: 0.72, width: 0.40, height: 0.16)  // 我的底牌
var boardArea  = CGRect(x: 0.15, y: 0.38, width: 0.70, height: 0.14)  // 公共牌
var potArea    = CGRect(x: 0.30, y: 0.32, width: 0.40, height: 0.06)  // 底池
var toCallArea = CGRect(x: 0.20, y: 0.62, width: 0.60, height: 0.08)  // 跟注额
```

调法：截一张牌桌图，用画图工具量比例，填这四个矩形。

## 决策逻辑说明

### 翻前（用 9901 扒的表）

`PreflopTable.swift` 由 `fetch_table.py` 自动生成，169 手 × 4 位置（UTG/MP/CO/BTN）。

表里没有的组合走内置回退：`PokerBrain.preflopFallback`（蒙特卡洛 + 位置加成）。

### 翻后（蒙特卡洛）

```swift
胜率 = 1200 次模拟（我的底牌+公共牌 vs 1 个随机对手）
决策 = 胜率 vs 底池赔率
  ├ 胜率 > 赔率+25% 且 > 55%  → RAISE 75% 底池
  ├ 胜率 > 赔率+5%            → CALL
  └ 否则                      → FOLD
```

调阈值在 `PokerBrain.decide` 里。

## 已知限制

| 项 | 状态 |
|---|---|
| 只识别底牌+公共牌 | 对手手牌识别不到（正常，本来就看不到） |
| 底池/跟注靠 OCR | 数字小、字体花时可能读错，读不到就用上次的值 |
| 人数/位置 | 目前靠 `TableConfig` 固定，没做动态识别 |
| **PiP 悬浮窗** | ✅ 已实现（`PiPManager`），用 AVSampleBufferDisplayLayer 自绘帧 |
| 多桌 | 不支持 |
| 分发 | Xcode 直装，7 天重签 |

## 画中画（PiP）说明

`PiPManager` 用**正统方案**：把决策画成帧 → 喂 `AVSampleBufferDisplayLayer` → `AVPictureInPictureController` 悬浮。

**必须满足三件事，否则启动失败：**

1. `Info.plist` 里有 `UIBackgroundModes = [audio]`（已加）
2. `AVAudioSession` 处于 `.playback` 活跃状态（`activateAudioSession()` 已做）
3. `displayLayer` 在视图树里且有非零尺寸（`PiPHostView` 用 1×1 隐形挂载）

**用法**：点「悬浮窗」按钮 → 系统 PiP 小窗出现 → 切到牌桌 → 小窗显示 `RAISE 6 / 胜率 62%`

**注意**：PiP 必须真机测试，模拟器大概率不支持。如果 `isSupported == false`，按钮会禁用。

## 下一步

1. **PiP 悬浮窗** —— iOS 上唯一能"悬浮"的方案（他们的 App 也是这么做的，二进制里有 `UIPiPView`）
2. **人数/位置动态识别** —— 用 `player` 框的数量 + `btn` 框位置推
3. **平台适配** —— 每个平台一套 `TableConfig`
