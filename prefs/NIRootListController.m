// NIRootListController.m — NotifierIcons 设置面板（根页面）
//
// 0.7.1 回归全原生控件（0.7.0 教训：自定义 @"cell" 单元格在 iOS 17 Preferences
// 未实例化，回落的原生滑杆又无绑定 → 整组失效）：
//   - 滑杆：原生 PSSliderCell + defaults/key + setPreferenceValue:/readPreferenceValue:
//     + PostNotification（0.5.0 同设备已验证可用）
//   - 数字微调：原生 PSEditTextCell + 同键标准绑定（若仍不渲染则仅损失微调功能，
//     滑杆不受影响）；tweak 侧 loadPrefs 会把输入的字符串值规范化回 NSNumber，
//     避免污染滑杆取值
//   - 位置允许移出屏幕（滑杆量程内显示；越界钳制在 tweak 侧已取消）
//
// 铁律：specifier 全代码创建（RootHide 不走 Root.plist）；全文件禁止 block。

#import "NIRootListController.h"
#import "NIAppPickerController.h"
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <unistd.h>
#import <Foundation/Foundation.h>

extern char **environ;

static NSString *const kPrefDomain   = @"com.chenlin8023.notifiericons";
static NSString *const kNotifyReload = @"com.chenlin8023.notifiericons/reloadPrefs";
static NSString *const kNotifyDump   = @"com.chenlin8023.notifiericons/dumpDiag";

// 面板文案内联，避免 NSLocalizedString 再去读 bundle 资源
static NSString *L(NSString *zh, NSString *en) {
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    return [lang hasPrefix:@"zh"] ? zh : en;
}

@implementation NIRootListController

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *specs = [NSMutableArray array];

    // ---- 启用 ----
    PSSpecifier *g1 = [PSSpecifier groupSpecifierWithName:L(@"启用", @"Enable")];
    [g1 setProperty:L(@"状态栏下方显示选中应用的通知小图标（红点标识，无数字），"
                      @"有角标才出现、清零即消失，默认最多 6 个。"
                      @"独立悬浮窗渲染，与灵动岛布局完全无关，改动即时生效。",
                      @"Shows app icons below the status bar (max 6). Icons appear ONLY while the app "
                      @"has an unread badge and vanish once read — an empty row means no "
                      @"notifications, which is expected. Floating window; changes apply live.")
             forKey:@"footerText"];
    [specs addObject:g1];

    PSSpecifier *enable = [PSSpecifier preferenceSpecifierNamed:L(@"启用插件", @"Enable")
                                                        target:self
                                                           set:@selector(setPreferenceValue:specifier:)
                                                           get:@selector(readPreferenceValue:)
                                                        detail:nil
                                                          cell:PSSwitchCell
                                                          edit:nil];
    [enable setProperty:kPrefDomain forKey:@"defaults"];
    [enable setProperty:@"isEnable" forKey:@"key"];
    [enable setProperty:@YES forKey:@"default"];
    [enable setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:enable];

    // ---- 图标行调整（原生滑杆 + 原生数字输入，同键绑定）----
    PSSpecifier *g2 = [PSSpecifier groupSpecifierWithName:L(@"图标行调整（拖动即生效）",
                                                            @"Icon Row (live)")];
    [g2 setProperty:L(@"默认位置：灵动岛正下方、水平居中。\n"
                      @"• 垂直位置：图标行距屏幕顶部的距离（默认 60，0 = 紧贴顶部，可输负值移出屏外）；\n"
                      @"• 水平位置：相对屏幕居中的偏移（0 = 居中，负 = 左移，正 = 右移，可移出屏外）；\n"
                      @"• 图标大小：单个图标边长（10–20）。\n"
                      @"位置数值不做边界截断（允许移出屏幕外）。",
                      @"Default: centered below the Dynamic Island.\n"
                      @"Vertical = distance from screen top (default 60). Horizontal = offset "
                      @"from center. Icon Size = edge length. No clamping.")
             forKey:@"footerText"];
    [specs addObject:g2];

    PSSpecifier *posY = [PSSpecifier preferenceSpecifierNamed:L(@"垂直位置", @"Vertical Position")
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:nil
                                                        cell:PSSliderCell
                                                        edit:nil];
    [posY setProperty:kPrefDomain forKey:@"defaults"];
    [posY setProperty:@"posY" forKey:@"key"];
    [posY setProperty:@(60.0) forKey:@"default"];
    [posY setProperty:@(0.0) forKey:@"min"];
    [posY setProperty:@(300.0) forKey:@"max"];
    [posY setProperty:@YES forKey:@"showValue"];
    [posY setProperty:@YES forKey:@"isContinuous"];
    [posY setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:posY];

    PSSpecifier *posYText = [PSSpecifier preferenceSpecifierNamed:L(@"└ 垂直位置数值", @"└ Vertical value")
                                                          target:self
                                                             set:@selector(setPreferenceValue:specifier:)
                                                             get:@selector(readPreferenceValue:)
                                                          detail:nil
                                                            cell:PSEditTextCell
                                                            edit:nil];
    [posYText setProperty:kPrefDomain forKey:@"defaults"];
    [posYText setProperty:@"posY" forKey:@"key"];
    [posYText setProperty:@"NumbersAndPunctuation" forKey:@"keyboard"];
    [posYText setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:posYText];

    PSSpecifier *posX = [PSSpecifier preferenceSpecifierNamed:L(@"水平位置", @"Horizontal Position")
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:nil
                                                        cell:PSSliderCell
                                                        edit:nil];
    [posX setProperty:kPrefDomain forKey:@"defaults"];
    [posX setProperty:@"posX" forKey:@"key"];
    [posX setProperty:@(0.0) forKey:@"default"];
    [posX setProperty:@(-180.0) forKey:@"min"];
    [posX setProperty:@(180.0) forKey:@"max"];
    [posX setProperty:@YES forKey:@"showValue"];
    [posX setProperty:@YES forKey:@"isContinuous"];
    [posX setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:posX];

    PSSpecifier *posXText = [PSSpecifier preferenceSpecifierNamed:L(@"└ 水平位置数值", @"└ Horizontal value")
                                                          target:self
                                                             set:@selector(setPreferenceValue:specifier:)
                                                             get:@selector(readPreferenceValue:)
                                                          detail:nil
                                                            cell:PSEditTextCell
                                                            edit:nil];
    [posXText setProperty:kPrefDomain forKey:@"defaults"];
    [posXText setProperty:@"posX" forKey:@"key"];
    [posXText setProperty:@"NumbersAndPunctuation" forKey:@"keyboard"];
    [posXText setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:posXText];

    PSSpecifier *iconSize = [PSSpecifier preferenceSpecifierNamed:L(@"图标大小", @"Icon Size")
                                                          target:self
                                                             set:@selector(setPreferenceValue:specifier:)
                                                             get:@selector(readPreferenceValue:)
                                                          detail:nil
                                                            cell:PSSliderCell
                                                            edit:nil];
    [iconSize setProperty:kPrefDomain forKey:@"defaults"];
    [iconSize setProperty:@"iconSize" forKey:@"key"];
    [iconSize setProperty:@(14.0) forKey:@"default"];
    [iconSize setProperty:@(10.0) forKey:@"min"];
    [iconSize setProperty:@(20.0) forKey:@"max"];
    [iconSize setProperty:@YES forKey:@"showValue"];
    [iconSize setProperty:@NO forKey:@"isContinuous"];
    [iconSize setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:iconSize];

    PSSpecifier *sizeText = [PSSpecifier preferenceSpecifierNamed:L(@"└ 图标大小数值", @"└ Icon size value")
                                                          target:self
                                                             set:@selector(setPreferenceValue:specifier:)
                                                             get:@selector(readPreferenceValue:)
                                                          detail:nil
                                                            cell:PSEditTextCell
                                                            edit:nil];
    [sizeText setProperty:kPrefDomain forKey:@"defaults"];
    [sizeText setProperty:@"iconSize" forKey:@"key"];
    [sizeText setProperty:@"NumbersAndPunctuation" forKey:@"keyboard"];
    [sizeText setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:sizeText];


    // ---- 选择应用 ----
    PSSpecifier *g3 = [PSSpecifier groupSpecifierWithName:L(@"选择应用", @"Select Apps")];
    [g3 setProperty:L(@"勾选需要监控的应用，按应用名排序，默认最多显示 6 个。开关即保存。",
                      @"Pick apps to monitor. Sorted by name, max 6 shown.")
             forKey:@"footerText"];
    [specs addObject:g3];

    PSSpecifier *picker = [PSSpecifier preferenceSpecifierNamed:L(@"选择应用", @"Choose Apps")
                                                        target:self
                                                           set:NULL
                                                           get:NULL
                                                        detail:[NIAppPickerController class]
                                                          cell:PSLinkCell
                                                          edit:nil];
    [specs addObject:picker];

    // ---- 诊断 ----
    PSSpecifier *g4 = [PSSpecifier groupSpecifierWithName:L(@"诊断", @"Diagnostics")];
    [g4 setProperty:L(@"日志：/var/mobile/Library/NotifierIcons.log（256KB 自动轮转）。",
                      @"Log: /var/mobile/Library/NotifierIcons.log (256KB rotated).")
             forKey:@"footerText"];
    [specs addObject:g4];

    PSSpecifier *dbg = [PSSpecifier preferenceSpecifierNamed:L(@"写调试日志", @"Debug Logging")
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:nil
                                                       cell:PSSwitchCell
                                                       edit:nil];
    [dbg setProperty:kPrefDomain forKey:@"defaults"];
    [dbg setProperty:@"debugLog" forKey:@"key"];
    [dbg setProperty:@YES forKey:@"default"];
    [dbg setProperty:kNotifyReload forKey:@"PostNotification"];
    [specs addObject:dbg];

    PSSpecifier *dump = [PSSpecifier preferenceSpecifierNamed:L(@"导出诊断信息到日志", @"Dump Diagnostics to Log")
                                                      target:self
                                                         set:NULL
                                                         get:NULL
                                                      detail:nil
                                                        cell:PSButtonCell
                                                        edit:nil];
    dump.buttonAction = @selector(dumpDiag);
    [dump setProperty:@"dumpDiag" forKey:@"action"];
    [specs addObject:dump];

    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:L(@"注销 SpringBoard 生效", @"Respring to Apply")
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:nil
                                                            cell:PSButtonCell
                                                            edit:nil];
    respring.buttonAction = @selector(respring);
    [respring setProperty:@"respring" forKey:@"action"];
    [specs addObject:respring];

    PSSpecifier *credits = [PSSpecifier groupSpecifierWithName:@""];
    [credits setProperty:L(@"NotifierIcons 0.9.2 beta\n独立悬浮窗（灵动岛正下方默认位）· 红点角标 · 彩色字母兜底\n"
                           @"rootless (/var/jb) arm64 + arm64e，SpringBoard 单进程注入",
                           @"NotifierIcons 0.9.2 beta\nFloating window · red-dot badges\n"
                           @"rootless (/var/jb) arm64 + arm64e, SpringBoard only")
                  forKey:@"footerText"];
    [specs addObject:credits];

    _specifiers = specs;
    return _specifiers;
}

// 「导出诊断信息」→ Darwin 通知 SpringBoard 写日志（无 block）
- (void)dumpDiag {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kNotifyDump, NULL, NULL, YES);
}

// rootless 的 killall 在 /var/jb/usr/bin；保留 /usr/bin 兜底
- (void)respring {
    const char *candidates[] = { "/var/jb/usr/bin/killall", "/usr/bin/killall" };
    for (unsigned int i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if (access(candidates[i], X_OK) != 0) continue;
        pid_t pid = 0;
        const char *argv[] = { candidates[i], "-9", "SpringBoard", NULL };
        if (posix_spawn(&pid, candidates[i], NULL, NULL, (char *const *)argv, environ) == 0) {
            return;
        }
    }
}

@end
