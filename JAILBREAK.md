# 越狱设备安装说明

> 目标：拿到未签名的 `.ipa`，装进越狱 iPhone，App Group 靠 ldid 注入 entitlements 解决。

---

## 一、拿到 IPA（三选一）

### 方案 A：GitHub Actions 云端编译（没有 Mac 也能用）

1. 新建一个 GitHub 私有仓库
2. 把整个 `deepeye/` 目录推上去（**包含 `Models/` 和 `.github/`**）
3. 推完 Actions 会自动跑（也可以用 Actions → Build unsigned IPA → Run workflow 手动触发）
4. 等 5–10 分钟
5. 进 Actions → 那次运行 → 底部 **Artifacts** → 下载 `DeepEye-unsigned-ipa`
6. 解压得到 `DeepEye-unsigned.ipa`

> 免费额度：私有仓库每月 2000 分钟 macOS，编译一次约 5 分钟，够跑 400 次。
> 编译日志里会打印「模型是否打包进去」「扩展是否嵌入」，这两个必须是 ✅。

### 方案 B：本地 Mac

```bash
cd deepeye
brew install xcodegen
xcodegen generate
xcodebuild -project DeepEye.xcodeproj -scheme DeepEye \
  -sdk iphoneos -configuration Release -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/DeepEye.app Payload/
zip -qr DeepEye-unsigned.ipa Payload
```

### 方案 C：让我在服务器上编

那台 ARTEX 是 Linux（Ubuntu 22.04），**编不了 iOS**。除非给它装 macOS 虚拟机（不现实）。

---

## 二、装进越狱设备

### 首选：TrollStore（巨魔）

支持 iOS 14.0 – 17.0（部分版本），**永久签名 + 保留 entitlements**，最适合我们。

1. 越狱设备装好 TrollStore
2. 把 `DeepEye-unsigned.ipa` 传到手机（AirDrop / Filza / 局域网）
3. TrollStore 里点 **+** → 选 IPA
4. 装完直接开

**TrollStore 会自动处理 entitlements**，App Group 一般能直接用。

### 备选：Filza 手动装

1. 解压 IPA，得到 `Payload/DeepEye.app`
2. Filza 里把 `DeepEye.app` 拷到 `/Applications/`
3. 设置权限：
   ```
   chown -R mobile:mobile /Applications/DeepEye.app
   chmod -R 755 /Applications/DeepEye.app
   chmod 777 /Applications/DeepEye.app/DeepEye
   ```
4. 刷新图标缓存：
   ```
   uicache -a
   ```
   （或 `killall -9 SpringBoard`）

### 需要注入 entitlements 时（App Group 不生效）

越狱环境下用 ldid 手动签：

```bash
# 在手机上（NewTerm / SSH）
cd /Applications/DeepEye.app

# 写 entitlements
cat > /tmp/ent.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key>
  <string>com.deepeye.app</string>
  <key>com.apple.developer.team-identifier</key>
  <string>X</string>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.deepeye.shared</string>
  </array>
  <key>get-task-allow</key>
  <true/>
  <key>platform-application</key>
  <true/>
</dict>
</plist>
EOF

# 签主二进制
ldid -S/tmp/ent.plist DeepEye

# 签扩展
ldid -S/tmp/ent.plist PlugIns/Broadcast.appex/Broadcast

# 刷新
uicache -a
```

> 越狱环境下 entitlement **不校验签名**，ldid 伪签就够。
> `platform-application = true` 让 App 拿到更高权限（可选，便于调试）。

---

## 三、App Group 在越狱设备上怎么工作

正常（未越狱）流程是系统按 entitlements 分配共享容器：
```
/var/mobile/Containers/Shared/AppGroup/<UUID>/
```

越狱设备上，只要 **主 App 和扩展都带同一个 `group.com.deepeye.shared` entitlement**，
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` 就会返回同一个目录。

**验证方法**：App 启动后，`FrameReader` 的 `status` 如果是「就绪，请从控制中心开启录屏广播」，
说明 App Group 拿到了；如果是「App Group 未配置」，说明 entitlements 没生效。

**兜底方案**（entitlements 死活不生效时）：

改 `SharedFrame.swift` 里的 `fileURL`，直接用绝对路径：

```swift
static var fileURL: URL? {
    // 越狱兜底：直接写死一个两边都能访问的路径
    URL(fileURLWithPath: "/var/mobile/Library/DeepEye/frame.bin")
}
```

然后在 `FrameWriter.init` 和 `FrameReader.openSharedMemory` 里先 `mkdir -p` 这个目录。
扩展和主 App 都以 `mobile` 用户运行，权限没问题。

---

## 四、验证清单

装好后：

- [ ] 桌面有 DeepEye 图标
- [ ] 打开 App，显示「就绪，请从控制中心开启录屏广播」（**不是**「App Group 未配置」）
- [ ] 控制中心 → 长按录屏 → 能看到 **DeepEye** 这个广播源
- [ ] 开播后切回 App，画面实时镜像屏幕
- [ ] 顶部 fps 15–30

前两条过了，说明 entitlements 和扩展都正常。

---

## 五、越狱设备的额外好处

| 好处 | 说明 |
|---|---|
| **不用 $99** | 免费，永久 |
| **App Group 不受限** | ldid 注入即可 |
| **可以 dump 他们的 App** | 越狱后能直接拿内存里的密钥/协议（比逆向二进制快） |
| **可以 hook** | 用 Frida 直接看他们的 ws3 协议、/robot/ask 的 data 格式 —— **这是拿下翻后决策最快的路** |

> 最后一条值得单独说：你手上有越狱设备，就意味着可以**动态分析他们的 App**。
> 装个 Frida，hook 掉 `URLSession` / `NWConnection`，一跑就能看到完整的请求体（包括翻后决策的 data 和 token）。
> 这比在二进制里一个个找快 10 倍。
