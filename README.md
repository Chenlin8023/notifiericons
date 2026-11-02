# NotifierIcons — 状态栏应用通知图标

在状态栏下方显示选中应用的通知小图标：**有未读角标才出现、阅读清零即消失**——即安卓状态栏通知语义。独立悬浮窗渲染（与灵动岛布局完全无关），位置/大小可调、改动即时生效，仅桌面显示（进 App 自动消失）。

- iOS 16–17 · rootless（/var/jb）· arm64 + arm64e · SpringBoard 单进程注入
- 已在 iPhone 15 Pro / iOS 17.2.1（RootHide）实机验证

## 设计文档

### 架构（SpringBoard 单进程注入）

```
┌─ SpringBoard ──────────────────────────────────────────────┐
│ hook -[SBApplication setBadgeValue:/setBadgeNumberOrString:│
│       /setBadgeNumber:]  → 角标事件（加速器，可失效）        │
│ NSTimer 2s 轮询 SBApplicationController → 主同步（兜底）    │
│        ↓ diff 出快照 NSArray {bid, badge, icon, name}       │
│ hook -[_UIStatusBarForegroundView layoutSubviews]           │
│        ↓ find-or-create NIIconRowView（自绘 UIView）        │
│ 图标：+[UIImage _applicationIconImageForBundleIdentifier:   │
│        format:scale:]（format 0–12 自动探测）+ 磁盘缓存      │
│        + 字母头像兜底                                        │
│ 位置：预设(居中/岛左/岛右) + 微调 offsetX/offsetY            │
└────────────────────────────────────────────────────────────┘
        ↑ Darwin 通知 reloadPrefs / dumpDiag
┌─ Preferences（NIPrefs.bundle）──────────────────────────────┐
│ specifier 全代码创建（RootHide 不走 Root.plist 的教训）      │
│ 选应用：LSApplicationWorkspace → PSSwitchCell sel.<bid>     │
└────────────────────────────────────────────────────────────┘
```

### 关键决策

| 决策 | 理由 |
|---|---|
| 只注入 SpringBoard | NotifierDots 同款取舍；App 内状态栏不显示（全 App 注入成本/风险高出一个量级） |
| 事件 hook + 2s 轮询双通道 | iOS 17 的 SBApplication badge setter 不确定是否还在（MooreBarX15 是 iOS 15）；轮询保证 hook 失效也能工作 |
| 图标行用自绘 UIView 叠加 | 不碰系统 status bar item 队列（STUIStatusBar 私有 API 年年变），跨版本稳 |
| 全文件零 block | arm64e PAC：clang19 全局 block isa 是无认证 plain bind，ARC retain → SIGBUS（LSTimeSeconds 0.0.7-3 教训）。定时器 target/selector、Darwin 回调 C 函数 |
| specifier 全代码创建 | RootHide jbroot 路径重写导致 loadSpecifiersFromPlistName 拿不到资源 → 面板闪退（LSTS 0.0.8 教训） |
| build 后 PAC 补丁 | `tools/patch_arm64e.py`：__cfstring isa（auth bind24, div=0x6AE1, addrDiv=1, key=2）+ __objc_data isa/superclass 认证，与 Xcode 链接器逐字节一致（LSTS 已验证的补丁器） |

### 偏好域

`com.chenlin8023.notifiericons`；选中的应用以 `sel.<bundleID> = YES` 键存储（CFPreferencesCopyKeyList 枚举还原）。

### 文件

- `NotifierIcons.m` — 主 tweak（~900 行，无 Logos，手写 MSHookMessageEx）
- `prefs/NIRootListController.m` — 设置面板根页
- `prefs/NIAppPickerController.m` — 应用选择页
- `build.sh` — WSL 构建（LSTimeSeconds 同款流水线）
- 产物：`com.chenlin8023.notifiericons_0.1.0_iphoneos-arm64.deb`

## 安装

### 方式一：越狱源（推荐）

Sileo / Zebra / Cydia 添加源：

```
https://chenlin8023.github.io/
```

搜索 **NotifierIcons** 安装，装完 Respring 一次。

### 方式二：deb 直装（iPhone 15 Pro / iOS 17.2.1 / RootHide 实测）

```bash
# 方法一：scp + ssh
scp com.chenlin8023.notifiericons_0.1.0_iphoneos-arm64.deb mobile@<IP>:/var/mobile/Documents/
ssh mobile@<IP>
su root    # 默认密码 alpine
dpkg -i /var/mobile/Documents/com.chenlin8023.notifiericons_0.1.0_iphoneos-arm64.deb
killall -9 SpringBoard

# 方法二：Filza 直接点 deb → Install
```

## 测试清单（0.1.0 诊断版）

1. **安装后 respring**：SpringBoard 正常起来（若进安全模式 = RootHide Safe Mode 弹窗 → Disable Tweaks → 卸载，见下方回退）
2. **设置 → NotifierIcons**：面板能打开、不闪退（面板 PAC 已补，预期正常）
3. **选应用**：列表能列出全部用户应用（LSApplicationWorkspace），勾 2–3 个常收通知的（如微信/QQ/邮箱）
4. **触发通知**：给选中应用发消息 → 状态栏出现图标行（默认居中，灵动岛黑色区域内）
5. **清角标**：点开应用清掉通知 → 图标 2 秒内消失（轮询周期）
6. **进 App**：App 内状态栏无图标（设计如此）
7. **锁屏**：锁屏状态栏同样显示
8. **灵动岛展开**（听歌/计时）：岛展开时图标被盖住/重叠——0.1.0 已知限制，用「岛左/岛右」预设规避

## 日志采集

日志文件：`/var/mobile/Library/NotifierIcons.log`（256KB 自动轮转为 `.1`）

```bash
# SSH 拉取
scp mobile@<IP>:/var/mobile/Library/NotifierIcons.log ./
# 或 Filza 里直接查看/分享
```

**出问题时必须采集**：
1. 设置 → NotifierIcons → 确认「写调试日志」开启
2. 点「导出状态栏视图层级到日志」（会写入类存在性、badge API 探测结果、完整状态栏视图层级）
3. 拉取 `NotifierIcons.log` 全文回传

预期日志关键行：
```
[ctor] hooked _UIStatusBarForegroundView layoutSubviews   ← 若写 MISSING 则锚点类名变了
[ctor] hooked SBApplication setBadgeValue:                ← 若没有，则轮询兜底
badge getter probed: badgeValue (ret @)                   ← iOS 17 实际 getter 名
icon API works: format=7                                  ← 实际可用的图标 format
row layout: fg W=393.0 H=54.0 -> x=...
```

## 已知风险与回退

**会不会变砖：不会。** 本插件只注入 SpringBoard 用户态进程，不碰内核、基带、系统分区；
deb 随时可卸载。最坏情况是 SpringBoard 崩溃循环（安全模式），恢复路径：

1. RootHide 检测到 SpringBoard 反复崩溃会自动弹 **Safe Mode** → 选 Disable Tweaks →
   Sileo 卸载 NotifierIcons → respring
2. 若没弹 Safe Mode：SSH 登录 → `dpkg -r com.chenlin8023.notifiericons` → `killall SpringBoard`
3. 终极兜底：删除 `/var/jb/Library/MobileSubstrate/DynamicLibraries/NotifierIcons.dylib` → respring

已知技术风险（0.1.0 待真机验证）：
- `_UIStatusBarForegroundView` 类名在 iOS 17.2.1 可能变化（MooreBarX15 证明 iOS 15 存在；17 未验证）→ 若 hook 落空，靠日志的候选类名输出定位新锚点
- SBApplication badge getter/setter 在 iOS 17 可能迁移（SBFBadgeManager 等）→ 轮询读值路径靠 `badge getter probed` 日志确认
- 居中位置在灵动岛机型上可能与传感器开孔重叠 → 岛左/岛右预设 + 微调
- PSSegmentCell 的 titles/values 绑定若不生效 → 直接用「水平微调」滑杆代替

## 致谢

本项目形态与实现参考了以下项目，特此致谢：

- **[NotifierDots](https://iamalive2008.github.io/repo/depiction/web/com.mumiantech.notifierdots.html)**（mumiantech，iOS 11–14.3）——
  "状态栏通知图标"这一形态的开创者，本项目的注入架构（SpringBoard 单进程 +
  角标事件 + 状态栏叠加）以其为蓝本做了 iOS 16/17 现代化重构（独立 UIWindow +
  启动期实例捕获）。闭源，通过其 deb 逆向考证确认架构可行性。
- **[MooreBarX15](https://www.tateu.net/repo/html/?p=moorebarx15)**（tateu / Josh Harris）——
  同期状态栏图标类插件的另一种实现思路（自建 customStatusBar 第二行），其 deb
  的 hook 目标清单（SBApplication setBadgeValue: / _UIStatusBarForegroundView）
  为本项目提供了关键考证依据。闭源。
- **[Tweaker177/iOS-14-16-Private-System-API-headers](https://github.com/Tweaker177/iOS-14-16-Private-System-API-headers)** ——
  iOS 15.7.1 SpringBoardHome 私有头文件，SBHIconManager/SBHIconModel/SBHIconImageCache
  链路的定位依据（公开资料中唯一的 SBH 类头文件）。
- 以及越狱社区长期积累的运行时调试方法论（方法名扫描 / 防御式类探测）。

## 版本

- **0.9.2 (2026-11-03) — 形态定稿：去角标化**（0.9.1 真机反馈：红点/数字只出现在
  第一个图标上——实为 0.1.0 起的潜伏 bug，角标 x 坐标漏加图标偏移量致全部叠画在
  第一位右上角）。按用户决策**整体移除角标（红点+数字）与全部相关开关**
  （角标显示数字/无角标也常显）：**图标出现即通知、清零即隐藏**，语义即安卓。
  面板脚注明示"无通知时图标行不显示是正常现象"，防误解。日志/缓存重置逻辑不变。
- - **0.9.1 (2026-11-03) — 角标样式开关 + 日志上限**（用户定稿前最后一改）
  1. 新增「角标显示数字（默认红点）」开关：默认纯红点；开启后显示数字角标，
     且数字压到红点级别（字号 7 / 高 9pt / 上限 99），避免 0.7.0 反馈的"数字大占篇幅"。
  2. 日志不关但防膨胀：128KB 触发轮转，保留 .1/.2 两份历史，总占用封顶 ~384KB
     （此前 256KB 单历史无总量概念）。
  3. roothide 双包暂缓（用户指示，等本改动验收）。
- - **0.9.0 真机验证 ✓（2026-11-03）— 真图标打通**
  日志实证：`captured via setModel: controller=SBIconController model=SBIconModel` →
  `iconManager chain: im=YES(SBHIconManager) cache=YES(SBHIconImageCache)
  model=YES(SBIconModel) icon=YES(SBApplicationIcon)` → `icon route resolved: 5 (Mgr)`。
  **胜利链路：启动期捕获 controller → iconManager → iconModel.leafIconForIdentifier: →
  SBIconImageCache.imageForIcon:**。磁盘缓存已存真图标（下次启动即使捕获时序偏晚也有兜底）。
  面板/滑杆/红点/角标全部验收通过。
- - **0.9.0 (2026-11-03) — 实例捕获：绕过 +sharedInstance 的消失**（0.8.0 真机日志
  决定性发现：`-[SBIconController iconManager]` 存在 ✓、SBH 全家桶类在
  SpringBoardHome ✓（SBHIconManager/SBHIconModel/SBHIconImageCache/SBHApplicationIcon），
  但 **+sharedInstance 已不存在**（init 改 12 参依赖注入）→ 0.8.0 的
  iconManager 链从第一步就断）。
  解法 = **启动期 hook 捕获活实例**（dylib 注入早于 SB UI）：
  hook `-[SBIconController setModel:]`（拿 controller+model）与
  `-[SBHIconModel setDelegate:]`（delegate 即 SBHIconManager），各带一次性日志 +
  触发缓存重置。配套修复：彩色字母不再落盘（否则真图标到手后仍被磁盘字母缓存
  遮蔽）；捕获成功即清内存+磁盘图标缓存；路线 4 扩展为控制器四类图标缓存
  （notification/appSwitcherHeader/tableUI/appSwitcherUnmasked，SCAN 证实属性存在）
  逐个探测 imageFor*。
- - **0.8.0 (2026-11-03) — 真图标总攻**（公开资料考古结论落地）
  资料源：SO 经典帖（控制器级 applicationIconForBundleIdentifier:）、
  Tweaker177/iOS-14-16-Private-System-API-headers（**iOS 14+ 主屏类迁到
  SpringBoardHome.framework，SBH 前缀**：SBHIconManager 持有 iconModel/iconImageCache/
  applicationWithBundleIdentifier:）、iOS10-Runtime-Headers（iconDataForVariant:
  签名 `- (id)` **可能直接返回 UIImage** —— 0.7.x 只认 NSData 是自摆乌龙）。
  图标链扩到 7 路：sel3 → sel2 → LSproxy(修 id/UIImage 双认 + variant 0-3 + 日志)
  → 控制器级 → **SBHIconManager 链**（iconManager → iconModel.leafIconForIdentifier:
  → iconImageCache.imageForIcon:* 探测 + 一次性方法扫描）→ 旧模型链 → 彩色字母。
  诊断加 SBIconController "anager"/"IconImage" 方法扫描。
- - **0.7.1 (2026-11-03) — 面板回归全原生**（0.7.0 截图/日志：自定义 @"cell" 单元格在
  iOS 17 Preferences 未实例化 → 回落无绑定滑杆整组失效）。滑杆/数字输入全部改回
  原生 PSSliderCell + PSEditTextCell 标准绑定（0.5.0 同设备已验证）；tweak 侧
  loadPrefs 把输入框写入的字符串规范化回 NSNumber（normalizeNumericPref），
  防止污染滑杆。删除 NISliderInputCell。
  另发现：SBWindowScene 悬浮窗实际全局渲染（App 内也可见），暂按 Android 语义保留。
- - **0.7.0 (2026-11-03) — 面板重构 + 红点 + LS 图标路线**（0.6.0 反馈）
  1. "数字输入框没出现/滑块太长" → 自定义单元格 **NISliderInputCell**（@"cell" 属性挂
     PSTableCellClassKey）：标题 + 短滑杆 + 数字输入框同一行，拖动即写即生效、输入回车生效；
     实例化失败回落原生滑杆。删除独立 PSEditTextCell 行与"显示角标数字"开关。
  2. **取消越界钳制**：位置数值不做边界截断，允许移出屏幕外（loadPrefs 只防荒谬值）。
  3. **角标改纯红点**（直径 ~0.42*图标边长，白描边），去掉数字标注。
  4. 真图标仍失败（[SBIconController model] 返回 nil）→ 图标链插入
     **LSApplicationProxy iconDataForVariant:**（variant 0-2 探测）路线；
     最终兜底从灰底字母升级为**按 bundleID 哈希色相的彩色字母**（route=5）。
- **0.6.0** — SCAN 扫到 `-[SBIconController model]` + 两参便捷方法；PSEditTextCell
  微调框方案（未渲染成功，被 0.7.0 取代）。
- **0.5.0** — 垂直位置下限 0 贴顶；图标大小变化触发重建（修复"缩放滑块只会平移"）；
  按 App 显示名排序（修复"角标标错图标"感）；常显开关即"无角标也常显"调试开关。
- **0.4.0** — scene 按类名过滤（Aperture/Curtain 岛帘幕）+ 独立 g_appliedVersion 重建
  追踪：**悬浮窗渲染打通**，位置滑杆实时生效，badge 真值（badgeValue ret @）。
- **0.3.0** — 窗口挂 UIWindowScene（裸 initWithFrame: 窗口 iOS 13+ 不渲染）；badge
  探测修复（无参 getter 签名 = 2 个参数）；面板按用户意见精简为 3 滑杆。
- **0.2.0** — 渲染层改独立 UIWindow 绝对定位，脱离灵动岛布局（用户核心诉求）。
- **0.1.1** — STUI 三锚点（iOS 17 状态栏迁移 SystemStatusUI 家族的发现）。
- **0.1.0** — 首个诊断版（NotifierDots 架构复刻 + iOS 17 防御式探测）。


