// =============================================================================
// NotifierIcons.m — 状态栏应用通知图标 (iOS 16–17, SpringBoard 单进程注入)
//
// 0.2.0 架构变更（0.1.1 真机日志驱动）：
//   - 渲染载体从「hook _UIStatusBarForegroundView 叠子视图」改为
//     **独立 UIWindow（状态栏层级）+ 绝对定位**（NotifierDots 原始方案）。
//     0.1.1 实测 STUI 前景视图被系统反复销毁重建（一次会话 15+ 次），
//     子视图被灵动岛布局系统拖着走、调位置要等遮挡才刷新 —— 窗口方案根治。
//   - 图标链：sel3 → sel2 → SBIconModel（iconModel.applicationIconForBundleIdentifier:）
//     → 字母头像。0.1.1 实测 sel3 全 format 返回 nil（字母头像上屏）。
//   - 角标读取逐项插桩（app=YES/NO + count），定位 0.1.1 "app dict 249 项但 badge 全 0"。
//
// arm64e 红线：全文件禁止 block 字面量（全局 block isa 无 PAC，ARC retain → SIGBUS）。
// =============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <sys/stat.h>
#include <ctype.h>
#include <stdlib.h>

// ------------------------------ 常量 ------------------------------
static NSString *const kPrefDomain       = @"com.chenlin8023.notifiericons";
static NSString *const kNotifyReload     = @"com.chenlin8023.notifiericons/reloadPrefs";
static NSString *const kNotifyDump       = @"com.chenlin8023.notifiericons/dumpDiag";
static const char    *kLogPath           = "/var/mobile/Library/NotifierIcons.log";
static const char    *kCacheDir          = "/var/mobile/Library/NotifierIcons/cache";
static const NSTimeInterval kPollInterval = 2.0;
// 默认垂直位置 60pt = 状态栏高度 54（灵动岛机型）+ 6pt 间距，即灵动岛正下方

// 诊断方法名扫描（定义在文件尾，前置声明供图标路线使用）
static void dumpMethodNames(Class cls, BOOL classMethods, const char *needle,
                            const char *tag);

// ------------------------------ 偏好 ------------------------------
static BOOL      pref_enabled     = YES;
// 0.9.2：角标（红点/数字）整体移除——图标出现与否即通知状态；
// 常显/样式开关一并删除（顺带修掉 0.1.0 起角标坐标漏加图标偏移、全部叠在
// 第一个图标右上的潜伏 bug）
static CGFloat   pref_iconSize    = 14.0;
static CGFloat   pref_spacing     = 3.0;   // 固定值（不再暴露）
static NSInteger pref_maxIcons    = 6;     // 固定值（用户要求默认 6，不再暴露）
static CGFloat   pref_posX        = 0.0;   // 水平位置：0=屏幕居中，负左正右
static CGFloat   pref_posY        = 60.0;  // 垂直位置：距屏幕顶部（默认灵动岛正下方）
static BOOL      pref_debug       = YES;

// ------------------------------ 全局状态 ------------------------------
static NSUInteger g_snapshotVersion = 0;
static NSArray *g_snapshot = nil;      // 当前显示快照
static NSUInteger g_appliedVersion = 0; // 已渲染到图标行上的快照版本（0.3.0 bug：itemsVersion
                                        // 预设"当前+1"恰好与首个快照版本相等，重建被永久跳过）
static CGFloat g_appliedSize = -1.0;   // 已渲染时的图标大小（0.4.0 bug：改大小不重建 →
                                        // 容器变宽而内容不动，看起来像"缩放滑块在左右移动"）
static UIWindow *g_window = nil;       // 独立覆盖窗口（状态栏层级）

// 0.9.0：iOS 17.2.1 无 +sharedInstance（init 改纯依赖注入）——启动期 hook 捕获活实例
static id g_sbIconController = nil;    // SBIconController（-[setModel:] 捕获）
static id g_sbIconModel = nil;         // SBIconModel/SBHIconModel（setModel:/setDelegate: 捕获）
static id g_sbIconManager = nil;       // SBHIconManager（-[SBHIconModel setDelegate:] 的
                                       // delegate 即 manager，其实现 SBHIconModelDelegate）
static BOOL g_captureLogged = NO;
static BOOL g_pollPending = NO;
static int  g_iconRoute = 0;           // 0未定 1=sel3 2=sel2 3=iconModel 4=字母
static int  g_diagPolls = 0;           // 前 N 次轮询输出逐项明细

// ------------------------------ 日志 ------------------------------
// 0.9.1：轮转 + 总量上限——128KB 触发轮转，保留 .1/.2 两份历史，
// 总占用封顶 ~384KB；调试日志默认开启（用户要求不关）
static void rotateLogIfNeeded(void) {
    static time_t lastCheck = 0;
    time_t now = time(NULL);
    if (now - lastCheck < 30) return;
    lastCheck = now;
    struct stat st;
    if (stat(kLogPath, &st) != 0 || st.st_size < 128 * 1024) return;
    char p1[512], p2[512];
    snprintf(p1, sizeof(p1), "%s.1", kLogPath);
    snprintf(p2, sizeof(p2), "%s.2", kLogPath);
    rename(p1, p2);          // .2 被更旧内容覆盖（最多两份历史）
    rename(kLogPath, p1);    // 当前转为 .1，新日志从头写
}

static void writeLog(const char *format, ...) {
    va_list args;
    va_start(args, format);
    char buf[1024];
    vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);

    if (pref_debug) NSLog(@"[NotifierIcons] %s", buf);
    rotateLogIfNeeded();
    FILE *f = fopen(kLogPath, "a");
    if (!f) return;
    time_t now = time(NULL);
    char tbuf[64];
    strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(f, "[%s] %s\n", tbuf, buf);
    fclose(f);
}

// ------------------------------ 偏好读取 ------------------------------
static NSString *prefsFilePaths[3] = {
    @"/var/mobile/Library/Preferences/com.chenlin8023.notifiericons.plist",
    @"/var/jb/var/mobile/Library/Preferences/com.chenlin8023.notifiericons.plist",
    @"/.jbroot/var/mobile/Library/Preferences/com.chenlin8023.notifiericons.plist"
};

static id readPref(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefDomain);
    CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                      (__bridge CFStringRef)kPrefDomain);
    if (val != NULL) return (__bridge_transfer id)val;
    for (int i = 0; i < 3; i++) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:prefsFilePaths[i]];
        if (d && [d objectForKey:key] != nil) return [d objectForKey:key];
    }
    return nil;
}

static BOOL boolPref(NSString *key, BOOL def) {
    id v = readPref(key);
    return v ? [v boolValue] : def;
}
static CGFloat floatPref(NSString *key, CGFloat def) {
    id v = readPref(key);
    return v ? [v floatValue] : def;
}

// 0.7.1：面板数字输入框（PSEditTextCell）会把值写成 NSString；规范化回 NSNumber，
// 避免原生滑杆读到字符串后显示/写入异常
static void normalizeNumericPref(NSString *key, CGFloat def) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kPrefDomain);
    if (!v) return;
    id obj = (__bridge_transfer id)v;
    if ([obj isKindOfClass:[NSNumber class]]) return;
    CGFloat d = [obj doubleValue];
    if (d != d) d = def; // NaN
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFNumberRef)@(d),
                             (__bridge CFStringRef)kPrefDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefDomain);
}

static void loadPrefs(void) {
    normalizeNumericPref(@"posX", 0.0);
    normalizeNumericPref(@"posY", 60.0);
    normalizeNumericPref(@"iconSize", 14.0);
    pref_enabled     = boolPref(@"isEnable", YES);
    pref_iconSize    = floatPref(@"iconSize", 14.0);
    if (pref_iconSize < 8.0)  pref_iconSize = 8.0;
    if (pref_iconSize > 24.0) pref_iconSize = 24.0;
    pref_spacing     = 3.0;               // 固定
    pref_maxIcons    = 6;                 // 固定（用户要求）
    pref_posX        = floatPref(@"posX", 0.0);   // 0 = 居中
    if (pref_posX < -1000.0) pref_posX = -1000.0; // 只防荒谬值，允许移出屏幕
    if (pref_posX > 1000.0)  pref_posX = 1000.0;
    pref_posY        = floatPref(@"posY", 60.0);  // 灵动岛正下方（状态栏 54 + 6）
    if (pref_posY < -300.0) pref_posY = -300.0;   // 允许移出屏幕外
    if (pref_posY > 2000.0) pref_posY = 2000.0;
    pref_debug       = boolPref(@"debugLog", YES);
}

// 选中的应用（键名 sel.<bundleID> = YES）
static NSArray<NSString *> *selectedBundleIDs(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)kPrefDomain,
                                               kCFPreferencesCurrentUser,
                                               kCFPreferencesAnyHost);
    if (keys) {
        NSArray *keyArr = (__bridge NSArray *)keys; // 只借用，最后 CFRelease
        for (NSString *k in keyArr) {
            if ([k hasPrefix:@"sel."] && boolPref(k, NO)) {
                [out addObject:[k substringFromIndex:4]];
            }
        }
        CFRelease(keys);
    }
    if ([out count] == 0) {
        for (int i = 0; i < 3; i++) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:prefsFilePaths[i]];
            if (!d) continue;
            for (NSString *k in d) {
                if ([k hasPrefix:@"sel."] && [d[k] boolValue]) {
                    [out addObject:[k substringFromIndex:4]];
                }
            }
            if ([out count] > 0) break;
        }
    }
    return out;
}

// ------------------------------ 私有接口声明 ------------------------------
@interface SBApplication : NSObject
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)allApplications;
@end

// ------------------------------ 图标行视图 ------------------------------
// item = @{ @"icon": UIImage, @"count": NSNumber, @"name": NSString, @"bid": NSString }
@interface NIIconRowView : UIView
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, assign) NSUInteger itemsVersion;
- (void)rebuildWithItems:(NSArray *)items;
- (CGSize)rowSize;
@end

@implementation NIIconRowView

- (CGSize)rowSize {
    NSUInteger n = [_items count];
    if (n == 0) return CGSizeZero;
    CGFloat w = n * pref_iconSize + (n - 1) * pref_spacing;
    return CGSizeMake(w, pref_iconSize);
}

- (void)rebuildWithItems:(NSArray *)items {
    _items = [items copy];
    _itemsVersion = g_snapshotVersion;
    for (UIView *v in [self subviews]) [v removeFromSuperview];

    CGFloat sz = pref_iconSize;
    NSInteger idx = 0;
    for (NSDictionary *item in _items) {
        CGFloat x = idx * (sz + pref_spacing);

        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(x, 0, sz, sz)];
        iv.image = item[@"icon"];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.layer.cornerRadius = sz * 0.2237;
        iv.layer.borderWidth = 0.25;
        iv.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.55] CGColor];
        iv.userInteractionEnabled = NO;
        [self addSubview:iv];

        // 0.9.2：角标（红点/数字）整体移除——图标出现即通知，红点消即隐藏
        idx++;
    }
}

@end

// ------------------------------ 角标读取 ------------------------------
// 依次探测 badgeValue / badgeNumber / badgeNumberOrString / badgeCount / badge，
// 按方法签名自动解；探测结果只记一次日志，但"一个都没找到"也记。
static NSInteger readBadge(id app) {
    static SEL cachedSel = NULL;
    static BOOL probed = NO;
    if (!probed) {
        probed = YES;
        @try {
            SEL cand[5] = {
                NSSelectorFromString(@"badgeValue"),
                NSSelectorFromString(@"badgeNumber"),
                NSSelectorFromString(@"badgeNumberOrString"),
                NSSelectorFromString(@"badgeCount"),
                NSSelectorFromString(@"badge")
            };
            for (int i = 0; i < 5; i++) {
                if (![app respondsToSelector:cand[i]]) continue;
                NSMethodSignature *sig = [app methodSignatureForSelector:cand[i]];
                // 0.2.0 的 bug：无参 getter 签名是 self+_cmd=2 个参数，
                // 之前写 <3 把所有角标 getter 全跳过了（badge 全零真凶）
                if ([sig numberOfArguments] < 2) continue;
                cachedSel = cand[i];
                writeLog("badge getter probed: %s (ret %s)",
                         sel_getName(cachedSel), [sig methodReturnType]);
                break;
            }
            if (!cachedSel) {
                writeLog("!! badge getter probe: none of 5 selectors respond on %s",
                         NSStringFromClass([app class]).UTF8String);
            }
        } @catch (NSException *e) {
            writeLog("badge probe exception: %s", e.reason.UTF8String);
        }
    }
    if (!cachedSel || !app) return 0;
    @try {
        NSMethodSignature *sig = [app methodSignatureForSelector:cachedSel];
        const char *ret = [sig methodReturnType];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:app];
        [inv setSelector:cachedSel];
        [inv invoke];
        if (ret[0] == '@') {
            __unsafe_unretained id obj = nil;
            [inv getReturnValue:&obj];
            if ([obj isKindOfClass:[NSNumber class]]) return [obj integerValue];
            if ([obj isKindOfClass:[NSString class]]) return [obj integerValue];
            return 0;
        }
        if (ret[0] == 'q' || ret[0] == 'Q' || ret[0] == 'l' || ret[0] == 'L' ||
            ret[0] == 'i' || ret[0] == 'I') {
            long long v = 0;
            [inv getReturnValue:&v]; // 小类型只写低位；角标非负，高位 0 安全
            return (NSInteger)v;
        }
    } @catch (NSException *e) {
        static int errs = 0;
        if (errs++ < 5) writeLog("readBadge exception: %s", e.reason.UTF8String);
    }
    return 0;
}

// ------------------------------ 图标获取 ------------------------------
static NSString *cachePathForBid(NSString *bid) {
    NSString *safe = [[bid componentsSeparatedByCharactersInSet:
        [[NSCharacterSet alphanumericCharacterSet] invertedSet]]
        componentsJoinedByString:@"_"];
    return [NSString stringWithFormat:@"%s/%@.png", kCacheDir, safe];
}


// 用 NSInvocation 调 1 参数对象方法
static id callObjectMethod1(id target, SEL sel, NSString *arg) {
    if (!target || ![target respondsToSelector:sel]) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        [inv setArgument:&arg atIndex:2];
        [inv invoke];
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        return ret;
    } @catch (NSException *e) {
        return nil;
    }
}

// 用 NSInvocation 调 2 参数对象方法
static id callObjectMethod2(id target, SEL sel, id a1, id a2) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        [inv setArgument:&a1 atIndex:2];
        [inv setArgument:&a2 atIndex:3];
        [inv invoke];
        __unsafe_unretained id ret = nil;
        [inv getReturnValue:&ret];
        return ret;
    } @catch (NSException *e) {
        return nil;
    }
}

// 路线 A/B：UIImage 私有类方法（0.1.1 实测 sel3 响应但全 format 返回 nil，
// 且当时 else-if 逻辑导致 sel2 永远轮不到 —— 本版两条都跑）
static UIImage *iconViaUIImageAPI(NSString *bid, int which) {
    Class UI = objc_getClass("UIImage");
    if (!UI) return nil;
    SEL sel = (which == 1)
        ? NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:")
        : NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:");
    if (![UI respondsToSelector:sel]) return nil;
    CGFloat scale = 2.0;
    for (int fmt = 0; fmt <= 12; fmt++) {
        @try {
            NSMethodSignature *sig = [UI methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setArgument:&bid atIndex:2];
            [inv setArgument:&fmt atIndex:3];
            if (which == 1) [inv setArgument:&scale atIndex:4];
            [inv invoke];
            __unsafe_unretained UIImage *img = nil;
            [inv getReturnValue:&img];
            if (img && img.size.width >= 20.0) return img;
        } @catch (NSException *e) {
            return nil;
        }
    }
    return nil;
}

// 找 SpringBoard 的图标模型：0.3.0 实测 SBIconController 不响应 iconModel 且
// ivar 扫描也找不到（iOS 17 模型挪走了）。四级探测：
//   1. SBIconManager.sharedManager.iconModel / sharedInstance.iconModel
//   2. SBIconController 直选方法 → KVC → ivar 类型扫描
//   3. SBIconModel / SBHomeIconModel 类方法（sharedInstance/sharedIconModel）
static id findIconModel(void) {
    // --- 0) 启动期捕获的实例（0.9.0，iOS 17 无 +sharedInstance 时的正路）---
    if (g_sbIconModel) return g_sbIconModel;
    // --- 1) SBIconManager 路线 ---
    Class mgrCls = objc_getClass("SBIconManager");
    if (mgrCls) {
        id mgr = nil;
        SEL mSels2[2] = { NSSelectorFromString(@"sharedManager"),
                          NSSelectorFromString(@"sharedInstance") };
        for (int i = 0; i < 2 && !mgr; i++) {
            if ([mgrCls respondsToSelector:mSels2[i]]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                mgr = [mgrCls performSelector:mSels2[i]];
#pragma clang diagnostic pop
            }
        }
        if (mgr) {
            SEL imSels[2] = { NSSelectorFromString(@"iconModel"),
                              NSSelectorFromString(@"homeIconModel") };
            for (int i = 0; i < 2; i++) {
                if ([mgr respondsToSelector:imSels[i]]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id m = [mgr performSelector:imSels[i]];
#pragma clang diagnostic pop
                    if (m) return m;
                }
            }
        }
    }

    // --- 2) SBIconController 路线 ---
    Class icCls = objc_getClass("SBIconController");
    if (icCls) {
        id ic = callObjectMethod1(icCls, NSSelectorFromString(@"sharedInstance"), nil);
        if (ic) {
            // 0.5.0 SCAN 实锤：iOS 17 的访问器是 model（不是 iconModel）
            SEL mSels[4] = {
                NSSelectorFromString(@"model"),
                NSSelectorFromString(@"iconModel"),
                NSSelectorFromString(@"currentIconModel"),
                NSSelectorFromString(@"homeIconModel")
            };
            for (int i = 0; i < 3; i++) {
                if ([ic respondsToSelector:mSels[i]]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id m = [ic performSelector:mSels[i]];
#pragma clang diagnostic pop
                    if (m) return m;
                }
            }
            NSString *kvs[3] = { @"iconModel", @"_iconModel", @"model" };
            for (int i = 0; i < 3; i++) {
                @try {
                    id m = [ic valueForKey:kvs[i]];
                    if (m) return m;
                } @catch (NSException *e) {}
            }
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(object_getClass(ic), &count);
            id found = nil;
            for (unsigned int i = 0; i < count && !found; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type && strstr(type, "IconModel")) {
                    found = object_getIvar(ic, ivars[i]);
                }
            }
            if (ivars) free(ivars);
            if (found) return found;
        }
    }

    // --- 3) SBIconModel / SBHomeIconModel 类方法 ---
    const char *mdlClasses[2] = { "SBIconModel", "SBHomeIconModel" };
    for (int c = 0; c < 2; c++) {
        Class mCls = objc_getClass(mdlClasses[c]);
        if (!mCls) continue;
        SEL cSels[2] = { NSSelectorFromString(@"sharedInstance"),
                         NSSelectorFromString(@"sharedIconModel") };
        for (int i = 0; i < 2; i++) {
            if ([mCls respondsToSelector:cSels[i]]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id m = [mCls performSelector:cSels[i]];
#pragma clang diagnostic pop
                if (m) return m;
            }
        }
    }
    return nil;
}

// 彩色字母头像（最终兜底）：按 bundleID 哈希出稳定色相，
// 灰色方块难以分辨也是"角标标错图标"观感的帮凶
static UIImage *coloredLetterIcon(NSString *bid, NSString *name, CGFloat px) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(px, px), NO, 1.0);
    if (!UIGraphicsGetCurrentContext()) return nil;
    NSUInteger h = 0;
    for (NSUInteger i = 0; i < [bid length]; i++) {
        h = h * 31 + [bid characterAtIndex:i];
    }
    CGFloat hue = (h % 360) / 360.0;
    [[UIColor colorWithHue:hue saturation:0.55 brightness:0.62 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, 0, px, px));
    NSString *letter = @"";
    for (NSUInteger i = 0; i < [name length]; i++) {
        unichar c = [name characterAtIndex:i];
        if (c >= 128) { letter = [NSString stringWithFormat:@"%C", c]; break; }
        if (isalpha((int)c)) {
            letter = [[NSString stringWithFormat:@"%C", (unichar)toupper((int)c)] copy];
            break;
        }
    }
    if ([letter length] == 0) letter = @"?";
    CGFloat fs = px * 0.55;
    UIFont *font = [UIFont boldSystemFontOfSize:fs];
    CGSize ts = [letter sizeWithAttributes:@{NSFontAttributeName: font}];
    [[UIColor whiteColor] setFill];
    [letter drawAtPoint:CGPointMake((px - ts.width) / 2.0, (px - ts.height) / 2.0)
         withAttributes:@{NSFontAttributeName: font}];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// 路线 B2：LSApplicationProxy iconDataForVariant:（公开头文件证实签名 `- (id)iconDataForVariant:(int)`，
// 返回 id——可能是 NSData 也可能直接是 UIImage！0.7.x 只认 NSData，真图标可能被类型检查拒掉）
static UIImage *iconViaLSProxy(id proxy) {
    if (!proxy) return nil;
    SEL s = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:s]) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; writeLog("LS proxy iconDataForVariant: NOT available"); }
        return nil;
    }
    for (NSInteger variant = 0; variant <= 3; variant++) {
        @try {
            NSMethodSignature *sig = [proxy methodSignatureForSelector:s];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:proxy];
            [inv setSelector:s];
            [inv setArgument:&variant atIndex:2];
            [inv invoke];
            __unsafe_unretained id ret = nil;
            [inv getReturnValue:&ret];
            UIImage *imgU = ret;
            if ([ret isKindOfClass:[UIImage class]] && imgU.size.width >= 20.0) {
                static BOOL logged = NO;
                if (!logged) { logged = YES; writeLog("LS icon variant %ld -> UIImage %.0fpx", (long)variant, imgU.size.width); }
                return imgU;
            }
            if ([ret isKindOfClass:[NSData class]] && [ret length] > 1000) {
                UIImage *img = [UIImage imageWithData:ret];
                if (img && img.size.width >= 20.0) {
                    static BOOL logged2 = NO;
                    if (!logged2) { logged2 = YES; writeLog("LS icon variant %ld -> NSData %.0fpx", (long)variant, img.size.width); }
                    return img;
                }
            }
        } @catch (NSException *e) {
            return nil;
        }
    }
    return nil;
}

// 路线 C：iOS 14+ 主屏图标中枢 SBHIconManager（SpringBoardHome.framework，公开头文件
// Tweaker177/iOS-14-16-Private-System-API-headers 证实：iconModel/iconImageCache/
// applicationWithBundleIdentifier:）。入口 = 启动期捕获的实例（iOS 17 无 +sharedInstance）
// 或旧 sharedInstance（iOS 16 及以前）。
static id findIconManager(void) {
    if (g_sbIconManager) return g_sbIconManager;
    if (g_sbIconController) {
        SEL s = NSSelectorFromString(@"iconManager");
        if ([g_sbIconController respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id im = [g_sbIconController performSelector:s];
#pragma clang diagnostic pop
            if (im) return im;
        }
    }
    Class icCls = objc_getClass("SBIconController");
    if (!icCls) return nil;
    id ic = callObjectMethod1(icCls, NSSelectorFromString(@"sharedInstance"), nil);
    if (!ic) return nil;
    SEL s = NSSelectorFromString(@"iconManager");
    if (![ic respondsToSelector:s]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id im = [ic performSelector:s];
#pragma clang diagnostic pop
    return im;
}

// SBIcon / 图标对象 → UIImage（多选择器探测）
static UIImage *imageFromIconObject(id iconObj) {
    if (!iconObj) return nil;
    SEL imgSels[5] = {
        NSSelectorFromString(@"iconImage"),
        NSSelectorFromString(@"smallIconImage"),
        NSSelectorFromString(@"largeIconImage"),
        NSSelectorFromString(@"_iconImage"),
        NSSelectorFromString(@"displayedImage")
    };
    for (int i = 0; i < 5; i++) {
        if (![iconObj respondsToSelector:imgSels[i]]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        UIImage *img = [iconObj performSelector:imgSels[i]];
#pragma clang diagnostic pop
        if ([img isKindOfClass:[UIImage class]] && img.size.width >= 20.0) return img;
    }
    return nil;
}

static UIImage *iconViaIconManager(NSString *bid) {
    id im = findIconManager();
    if (!im) return nil;

    id cache = nil;
    SEL cacheS = NSSelectorFromString(@"iconImageCache");
    if ([im respondsToSelector:cacheS]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        cache = [im performSelector:cacheS];
#pragma clang diagnostic pop
    }
    id model = nil;
    SEL modelS = NSSelectorFromString(@"iconModel");
    if ([im respondsToSelector:modelS]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        model = [im performSelector:modelS];
#pragma clang diagnostic pop
    }
    id iconObj = nil;
    if (model) {
        iconObj = callObjectMethod1(model, NSSelectorFromString(@"leafIconForIdentifier:"), bid);
    }
    if (!iconObj) {
        iconObj = callObjectMethod1(im, NSSelectorFromString(@"applicationWithBundleIdentifier:"), bid);
    }

    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        writeLog("iconManager chain: im=%s(%s) cache=%s(%s) model=%s(%s) icon=%s(%s)",
                 im ? "YES" : "nil", im ? NSStringFromClass([im class]).UTF8String : "-",
                 cache ? "YES" : "nil", cache ? NSStringFromClass([cache class]).UTF8String : "-",
                 model ? "YES" : "nil", model ? NSStringFromClass([model class]).UTF8String : "-",
                 iconObj ? "YES" : "nil", iconObj ? NSStringFromClass([iconObj class]).UTF8String : "-");
        if (cache) dumpMethodNames([cache class], NO, "mage", "SCAN iconImageCache inst");
    }

    // 缓存取图：imageForIcon: / iconImageForIcon: / imageForIdentifier: / imageForBundleIdentifier:
    if (cache) {
        SEL cs[4] = {
            NSSelectorFromString(@"imageForIcon:"),
            NSSelectorFromString(@"iconImageForIcon:"),
            NSSelectorFromString(@"imageForIdentifier:"),
            NSSelectorFromString(@"imageForBundleIdentifier:")
        };
        for (int i = 0; i < 4; i++) {
            id arg = (i >= 2) ? (id)bid : iconObj;
            if (!arg || ![cache respondsToSelector:cs[i]]) continue;
            UIImage *img = callObjectMethod1(cache, cs[i], arg);
            if ([img isKindOfClass:[UIImage class]] && img.size.width >= 20.0) return img;
        }
    }
    return imageFromIconObject(iconObj);
}

// 路线 C2：控制器实例（启动期捕获）的图标缓存 + SO 记载的控制器级访问器
static UIImage *iconViaController(NSString *bid) {
    id ic = g_sbIconController;
    if (!ic) {
        Class icCls = objc_getClass("SBIconController");
        if (!icCls) return nil;
        ic = callObjectMethod1(icCls, NSSelectorFromString(@"sharedInstance"), nil);
    }
    if (!ic) return nil;

    // 0.9.0：SCAN 证实控制器持有四类图标图像缓存（notification/appSwitcher/tableUI）
    SEL cacheSels[4] = {
        NSSelectorFromString(@"notificationIconImageCache"),
        NSSelectorFromString(@"appSwitcherHeaderIconImageCache"),
        NSSelectorFromString(@"tableUIIconImageCache"),
        NSSelectorFromString(@"appSwitcherUnmaskedIconImageCache")
    };
    SEL getSels[4] = {
        NSSelectorFromString(@"imageForIdentifier:"),
        NSSelectorFromString(@"imageForBundleIdentifier:"),
        NSSelectorFromString(@"imageForApplicationWithBundleIdentifier:"),
        NSSelectorFromString(@"imageForIcon:")
    };
    for (int c = 0; c < 4; c++) {
        if (![ic respondsToSelector:cacheSels[c]]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id cache = [ic performSelector:cacheSels[c]];
#pragma clang diagnostic pop
        if (!cache) continue;

        static BOOL cacheLogged = NO;
        if (!cacheLogged) {
            cacheLogged = YES;
            writeLog("controller cache: %s", NSStringFromClass([cache class]).UTF8String);
            dumpMethodNames([cache class], NO, "mage", "SCAN SBIconCache inst");
        }
        for (int g = 0; g < 4; g++) {
            if (![cache respondsToSelector:getSels[g]]) continue;
            UIImage *img = callObjectMethod1(cache, getSels[g], bid);
            if ([img isKindOfClass:[UIImage class]] && img.size.width >= 20.0) return img;
        }
    }

    // SO 记载的控制器级访问器
    SEL s = NSSelectorFromString(@"applicationIconForBundleIdentifier:");
    if (![ic respondsToSelector:s]) return nil;
    id iconObj = callObjectMethod1(ic, s, bid);
    return imageFromIconObject(iconObj);
}
static UIImage *iconViaIconModel(NSString *bid) {
    id model = findIconModel();
    id iconObj = nil;
    if (model) {
        SEL getSels[3] = {
            NSSelectorFromString(@"applicationIconForBundleIdentifier:"),
            NSSelectorFromString(@"iconForIdentifer:"),
            NSSelectorFromString(@"expectedIconForDisplayIdentifier:")
        };
        for (int i = 0; i < 3 && !iconObj; i++) {
            iconObj = callObjectMethod1(model, getSels[i], bid);
        }
        // 0.5.0 SCAN 发现的两参便捷访问器：iconModel:applicationWithBundleIdentifier:
        if (!iconObj) {
            Class icCls = objc_getClass("SBIconController");
            id ic = icCls ? callObjectMethod1(icCls, NSSelectorFromString(@"sharedInstance"), nil)
                          : nil;
            if (ic && model) {
                iconObj = callObjectMethod2(ic,
                    NSSelectorFromString(@"iconModel:applicationWithBundleIdentifier:"),
                    model, bid);
            }
        }
    }
    if (!iconObj) return nil;

    // 记录一次图标对象类名（下一轮扩展取图方法的依据）
    static BOOL clsLogged = NO;
    if (!clsLogged) {
        clsLogged = YES;
        writeLog("icon object class: %s", NSStringFromClass([iconObj class]).UTF8String);
    }

    SEL imgSels[5] = {
        NSSelectorFromString(@"iconImage"),
        NSSelectorFromString(@"smallIconImage"),
        NSSelectorFromString(@"largeIconImage"),
        NSSelectorFromString(@"_iconImage"),
        NSSelectorFromString(@"icon")
    };
    for (int i = 0; i < 5; i++) {
        if (![iconObj respondsToSelector:imgSels[i]]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        UIImage *img = [iconObj performSelector:imgSels[i]];
#pragma clang diagnostic pop
        if ([img isKindOfClass:[UIImage class]] && img.size.width >= 20.0) return img;
    }
    return nil;
}

static NSCache *g_iconCache = nil;

// 捕获到真图标实例时重置缓存：彩色字母曾写盘（0.8.x），不清会导致
// 真图标到手后仍从缓存读字母图
static void resetIconCaches(void) {
    if (g_iconCache) [g_iconCache removeAllObjects];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@(kCacheDir) error:nil];
    for (NSString *f in files) {
        [fm removeItemAtPath:[NSString stringWithFormat:@"%s/%@", kCacheDir, f]
                       error:nil];
    }
    writeLog("icon caches reset (memory + disk)");
}

static UIImage *iconForBundleID(NSString *bid, NSString *name, id proxy) {
    if (!g_iconCache) {
        g_iconCache = [[NSCache alloc] init];
        [g_iconCache setCountLimit:64];
    }
    UIImage *cached = [g_iconCache objectForKey:bid];
    if (cached) return cached;

    NSString *diskPath = cachePathForBid(bid);
    UIImage *img = [UIImage imageWithContentsOfFile:diskPath];
    if (!img) {
        img = iconViaUIImageAPI(bid, 1);
        if (img) g_iconRoute = 1;
        if (!img) {
            img = iconViaUIImageAPI(bid, 2);
            if (img) g_iconRoute = 2;
        }
        if (!img) {
            img = iconViaLSProxy(proxy);
            if (img) g_iconRoute = 3;
        }
        if (!img) {
            img = iconViaController(bid);   // SO 记载的控制器级访问器
            if (img) g_iconRoute = 4;
        }
        if (!img) {
            img = iconViaIconManager(bid);  // iOS 14+ SBHIconManager 链
            if (img) g_iconRoute = 5;
        }
        if (!img) {
            img = iconViaIconModel(bid);    // 旧模型链（兜底保留）
            if (img) g_iconRoute = 6;
        }
        if (img) {
            NSData *png = UIImagePNGRepresentation(img);
            if (png) [png writeToFile:diskPath atomically:YES];
        } else {
            g_iconRoute = 7;
            // 彩色字母只进内存缓存，不落盘——捕获成功后立即可被真图标替换
            img = coloredLetterIcon(bid, name ?: @"A", 42.0);
        }
        static BOOL routeLogged = NO;
        if (!routeLogged) {
            routeLogged = YES;
            writeLog("icon route resolved: %d (1=sel3 2=sel2 3=LSproxy 4=ctrl 5=Mgr "
                     "6=oldModel 7=colored)",
                     g_iconRoute);
        }
    }
    if (img) [g_iconCache setObject:img forKey:bid];
    return img;
}

// ------------------------------ 管理器 ------------------------------
@interface NIManager : NSObject
- (void)reloadPrefs;
- (void)startOnMain;
- (void)pollTick;
- (void)pollTickCoalesced;
- (void)pollSoon;
- (void)dumpDiagnostics;
@end

@implementation NIManager

+ (instancetype)shared {
    static NIManager *m = nil;
    @synchronized(self) {
        if (!m) m = [[NIManager alloc] init];
        return m;
    }
}

// 独立覆盖窗口：状态栏层级，整屏宽，不接收触摸。
// 绝对定位在屏幕坐标系 —— 不挂在 STUI 状态栏视图下，不受岛布局牵连，
// 调整位置即时生效（0.1.1 的"依附灵动岛 + 遮挡才刷新"根治）。
// SpringBoard 进程的窗口只在本进程前台（桌面/多任务）渲染，进 App 自动消失，
// 与 0.1.x 的可见范围一致。
// 0.3.0 教训：SpringBoard 有 3 个 scene，"第一个前台活跃"会抓到
// SBSystemApertureCurtainWindowScene（灵动岛帘幕场景），挂上去的窗口只在岛区域渲染 = 看不见。
// 这里必须挑主场景：按类名过滤掉 Curtain/Aperture，优先 SBWindowScene。
static UIWindowScene *sbActiveScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    NSSet *scenes = [app connectedScenes];
    if (![scenes count]) return nil;
    UIWindowScene *nonCurtain = nil;
    UIWindowScene *nonCurtainActive = nil;
    UIWindowScene *anyActive = nil;
    UIWindowScene *any = nil;
    for (UIScene *s in scenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (!any) any = ws;
        if (ws.activationState == UISceneActivationStateForegroundActive && !anyActive)
            anyActive = ws;
        NSString *cls = NSStringFromClass([ws class]);
        if ([cls containsString:@"Curtain"] || [cls containsString:@"Aperture"]) continue;
        if (!nonCurtain) nonCurtain = ws;
        if (ws.activationState == UISceneActivationStateForegroundActive && !nonCurtainActive)
            nonCurtainActive = ws;
    }
    if (nonCurtainActive) return nonCurtainActive;
    if (nonCurtain) return nonCurtain;
    if (anyActive) return anyActive;
    return any;
}

- (void)ensureWindow {
    if (g_window) return;
    UIWindowScene *scene = sbActiveScene();
    if (!scene) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; writeLog("no UIWindowScene yet — retry on next poll"); }
        return;
    }
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = UIWindowLevelStatusBar + 1.0;
    w.userInteractionEnabled = NO;
    w.backgroundColor = [UIColor clearColor];
    w.hidden = YES;

    NIIconRowView *row = [[NIIconRowView alloc] initWithFrame:CGRectZero];
    row.userInteractionEnabled = NO;
    row.itemsVersion = g_snapshotVersion + 1; // 强制首次重建
    [w addSubview:row];

    g_window = w;
    objc_setAssociatedObject(w, @selector(rowRef), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    writeLog("overlay window created (scene=%s) %.0fx%.0f level=%.1f",
             NSStringFromClass([scene class]).UTF8String,
             w.frame.size.width, w.frame.size.height, w.windowLevel);
}

- (NIIconRowView *)row {
    if (!g_window) return nil;
    return (NIIconRowView *)objc_getAssociatedObject(g_window, @selector(rowRef));
}

// 立即按当前偏好重算图标行 frame（屏幕绝对坐标），不依赖任何系统布局回调。
// 坐标语义（用户 0.2.0 反馈定稿）：
//   垂直位置 = 图标行顶部距屏幕顶部的距离（默认 60 = 灵动岛正下方）
//   水平位置 = 相对屏幕居中的偏移（0 = 居中，负左正右）
- (void)updateRowFrame {
    if (!g_window) return;
    NIIconRowView *row = [self row];
    CGSize sz = [row rowSize];
    if (!pref_enabled || sz.width <= 0) {
        if (!g_window.hidden) g_window.hidden = YES;
        return;
    }
    CGFloat W = g_window.bounds.size.width;

    CGFloat x = roundf((W - sz.width) / 2.0 + pref_posX);
    CGFloat y = roundf(pref_posY);
    // 0.7.0：不做越界钳制（用户要求允许移出屏幕外，防止输入数值被截断）

    CGRect f = CGRectMake(x, y, sz.width, sz.height);
    if (!CGRectEqualToRect(f, row.frame)) {
        row.frame = f;
        static int logs = 0;
        if (logs++ < 60) {
            writeLog("row frame: pos=(%.1f,%.1f) -> x=%.1f y=%.1f w=%.1f",
                     pref_posX, pref_posY, x, y, sz.width);
        }
    }
    if (g_window.hidden) {
        g_window.hidden = NO;
        writeLog("window shown (posX=%.1f posY=%.1f)", pref_posX, pref_posY);
    }
}

- (void)applySnapshot {
    NIIconRowView *row = [self row];
    if (!row) return;
    // 快照版本 / 图标大小 / 角标数字开关 任一变化都重建（否则改大小只有容器变宽、
    // 内部图标不动）
    if (g_appliedVersion != g_snapshotVersion ||
        g_appliedSize != pref_iconSize) {
        [row rebuildWithItems:g_snapshot ?: @[]];
        g_appliedVersion = g_snapshotVersion;
        g_appliedSize = pref_iconSize;
    }
    [self updateRowFrame];
}

- (void)startOnMain {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(startOnMain) withObject:nil waitUntilDone:NO];
        return;
    }
    [self ensureWindow];
    [self reloadPrefs];
    NSTimer *t = [NSTimer timerWithTimeInterval:kPollInterval
                                         target:self
                                       selector:@selector(pollTick)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    [self pollTick];
    writeLog("poll timer started (%.1fs)", kPollInterval);
}

- (void)reloadPrefs {
    loadPrefs();
    writeLog("prefs: enable=%d posX=%.1f posY=%.1f size=%.1f debug=%d",
             pref_enabled, pref_posX, pref_posY, pref_iconSize, pref_debug);
    [self ensureWindow]; // scene 就绪前每次偏好变更/轮询都重试建窗
    [self pollTick];
    [self applySnapshot];
    // 位置类偏好变化：立即重算 frame（不等轮询）
    [self updateRowFrame];
}

- (void)pollSoon {
    if (g_pollPending) return;
    g_pollPending = YES;
    [self performSelector:@selector(pollTickCoalesced) withObject:nil afterDelay:0.3];
}

- (void)pollTickCoalesced {
    g_pollPending = NO;
    [self pollTick];
}

// ---------------- 快照构建与轮询 ----------------
- (void)pollTick {
    if (!g_window) {
        [self ensureWindow]; // scene 就绪前重试（ctor 后前几秒可能拿不到）
        if (!g_window) return;
    }
    if (!pref_enabled) {
        [self applySnapshot]; // pref_enabled=0 时 updateRowFrame 会隐藏窗口
        return;
    }
    @try {
        NSArray<NSString *> *selected = selectedBundleIDs();
        if ([selected count] == 0) {
            if ([g_snapshot count] > 0) {
                g_snapshot = @[];
                g_snapshotVersion++;
                [self applySnapshot];
            }
            return;
        }
        NSSet *selSet = [NSSet setWithArray:selected];

        // 名称/图标代理来源：LSApplicationWorkspace（SpringBoard 内可用）
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        NSMutableDictionary *proxies = [NSMutableDictionary dictionary];
        Class wsCls = objc_getClass("LSApplicationWorkspace");
        if (wsCls) {
            id ws = [wsCls performSelector:@selector(defaultWorkspace)];
            NSArray *all = [ws performSelector:@selector(allInstalledApplications)];
            for (id proxy in all) {
                if (![proxy respondsToSelector:@selector(bundleIdentifier)]) continue;
                NSString *bid = [proxy bundleIdentifier];
                if (![selSet containsObject:bid]) continue;
                NSString *nm = nil;
                if ([proxy respondsToSelector:@selector(localizedName)]) nm = [proxy localizedName];
                names[bid] = nm ?: bid;
                proxies[bid] = proxy;
            }
        }

        // 角标来源：SBApplicationController.allApplications 直接遍历
        //（0.1.1 的 applicationWithBundleIdentifier: 选择器在但返回 nil）
        Class ctrlCls = objc_getClass("SBApplicationController");
        id ctrl = ctrlCls ? [ctrlCls performSelector:@selector(sharedInstance)] : nil;
        if (!ctrl) {
            static BOOL logged = NO;
            if (!logged) { logged = YES; writeLog("SBApplicationController unavailable"); }
            return;
        }
        if (![ctrl respondsToSelector:@selector(allApplications)]) {
            static BOOL logged2 = NO;
            if (!logged2) { logged2 = YES; writeLog("!! allApplications not implemented"); }
            return;
        }

        // 按应用显示名排序（0.4.0 用户反馈：按 bundle ID 排序导致图标字母与位置
        // 对不上，角标看起来"标错图标"）
        NSMutableArray *selItems = [NSMutableArray array];
        for (NSString *bid in selected) {
            [selItems addObject:@{ @"bid": bid, @"name": names[bid] ?: bid }];
        }
        NSSortDescriptor *nameDesc =
            [NSSortDescriptor sortDescriptorWithKey:@"name"
                                          ascending:YES
                                           selector:@selector(localizedStandardCompare:)];
        [selItems sortUsingDescriptors:@[ nameDesc ]];

        NSMutableArray *items = [NSMutableArray array];
        BOOL detailed = (g_diagPolls < 3);
        NSArray *apps = [ctrl allApplications];
        NSMutableDictionary *badgeByBid = [NSMutableDictionary dictionary];
        for (id a in apps) {
            if (![a respondsToSelector:@selector(bundleIdentifier)]) continue;
            NSString *bid = [a bundleIdentifier];
            if (![bid length] || ![selSet containsObject:bid]) continue;
            badgeByBid[bid] = @(readBadge(a));
        }
        for (NSDictionary *selItem in selItems) {
            NSString *bid = selItem[@"bid"];
            NSInteger count = badgeByBid[bid] ? [badgeByBid[bid] integerValue] : 0;
            if (detailed) {
                writeLog("poll detail: %s app=YES count=%ld",
                         [bid UTF8String], (long)count);
            }
            if (count <= 0) continue; // 无角标不显示（0.9.2 移除常显开关）

            NSString *name = names[bid] ?: bid;
            UIImage *icon = iconForBundleID(bid, name, proxies[bid]);
            if (!icon) continue;
            [items addObject:@{
                @"icon": icon,
                @"count": @(count),
                @"name": name,
                @"bid": bid
            }];
            if ((NSInteger)[items count] >= pref_maxIcons) break;
        }
        if (detailed) g_diagPolls++;

        if (![items isEqualToArray:g_snapshot]) {
            g_snapshot = [items copy];
            g_snapshotVersion++;
            writeLog("snapshot v%lu: %lu item(s)", (unsigned long)g_snapshotVersion,
                     (unsigned long)[g_snapshot count]);
            for (NSDictionary *it in g_snapshot) {
                writeLog("  - %s badge=%ld", [it[@"bid"] UTF8String],
                         (long)[it[@"count"] integerValue]);
            }
        }
        [self applySnapshot];
    } @catch (NSException *e) {
        static int errs = 0;
        if (errs++ < 10) writeLog("pollTick exception: %s", e.reason.UTF8String);
    }
}

// ---------------- 诊断 ----------------
// 扫描类的方法名（找 iOS 17 图标模型访问器用）
static void dumpMethodNames(Class cls, BOOL classMethods, const char *needle,
                            const char *tag) {
    if (!cls) return;
    unsigned int count = 0;
    Method *list = class_copyMethodList(classMethods ? object_getClass(cls) : cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(list[i]));
        if (strstr(name, needle)) writeLog("%s -> %s", tag, name);
    }
    if (list) free(list);
}

- (void)dumpDiagnostics {
    writeLog("========== DIAGNOSTICS DUMP ==========");
    writeLog("pid=%d process=%s", getpid(), getprogname());

    const char *classes[] = {
        "STUIStatusBar", "STUIStatusBarForegroundView", "SBApplication",
        "SBApplicationController", "SBIconController", "SBIconModel",
        "LSApplicationWorkspace"
    };
    for (unsigned i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
        Class c = objc_getClass(classes[i]);
        writeLog("class %s : %s", classes[i], c ? "YES" : "NO");
    }

    // UIWindowScene 托管情况（0.2.0 窗口不渲染的根因排查项）
    UIApplication *app = [UIApplication sharedApplication];
    NSSet *scenes = [app connectedScenes];
    writeLog("connectedScenes=%lu windowScene=%s",
             (unsigned long)[scenes count],
             g_window.windowScene ? "attached" : "nil");

    // 图标模型探测结果 + SBIconController 的 ivar 清单（下一轮锁定模型位置用）
    id model = findIconModel();
    writeLog("iconModel probe: %s (%s)",
             model ? "FOUND" : "nil",
             model ? NSStringFromClass([model class]).UTF8String : "-");
    if (model) {
        writeLog("model responds applicationIconForBundleIdentifier=%d iconForIdentifer=%d",
                 [model respondsToSelector:NSSelectorFromString(
                     @"applicationIconForBundleIdentifier:")],
                 [model respondsToSelector:NSSelectorFromString(@"iconForIdentifer:")]);
    }
    Class icCls = objc_getClass("SBIconController");
    if (icCls) {
        id ic = callObjectMethod1(icCls, NSSelectorFromString(@"sharedInstance"), nil);
        if (ic) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(object_getClass(ic), &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type && strstr(type, "Icon") && strstr(type, "@")) {
                    writeLog("SBIconController ivar: %s : %s",
                             ivar_getName(ivars[i]), type);
                }
            }
            if (ivars) free(ivars);
        }
    }
    // 方法名扫描：把 iOS 17 图标模型的真实访问器名字挖出来
    dumpMethodNames(objc_getClass("SBIconController"), NO, "odel", "SCAN SBIconController inst");
    dumpMethodNames(objc_getClass("SBIconController"), NO, "anager", "SCAN SBIconController inst");
    dumpMethodNames(objc_getClass("SBIconController"), NO, "IconImage", "SCAN SBIconController inst");

    // 0.8.1：17.2.1 版本的"真头文件"——运行时枚举 SpringBoardHome 镜像里的图标类
    //（公开 dump 只到 15.7，17.x 的类清单只能从设备现挖）
    unsigned int imgCount = 0;
    const char **images = objc_copyImageNames(&imgCount);
    for (unsigned int i = 0; i < imgCount; i++) {
        const char *img = images[i];
        if (strstr(img, "SpringBoardHome") || (strstr(img, "SpringBoard.framework") && !strstr(img, "Server"))) {
            unsigned int clsCount = 0;
            const char **classNames = objc_copyClassNamesForImage(img, &clsCount);
            for (unsigned int j = 0; j < clsCount; j++) {
                const char *cn = classNames[j];
                if (strstr(cn, "IconManager") || strstr(cn, "IconModel") ||
                    strstr(cn, "IconImageCache") || strstr(cn, "ApplicationIcon") ||
                    strstr(cn, "SBIconImage")) {
                    writeLog("17.2.1 class [%s]: %s", img, cn);
                }
            }
            if (classNames) free(classNames);
        }
    }
    if (images) free(images);

    // SBHIconManager 的类方法（找 17 版单例入口，15.7 头里没有 +shared）
    dumpMethodNames(objc_getClass("SBHIconManager"), YES, "shared", "SCAN SBHIconManager cls");
    dumpMethodNames(objc_getClass("SBHIconManager"), YES, "anager", "SCAN SBHIconManager cls");
    dumpMethodNames(objc_getClass("SBHIconModel"), YES, "shared", "SCAN SBHIconModel cls");

    // 图标缓存目录清单（磁盘直读备选路线）
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cacheDirs = @[
        @"/var/mobile/Library/Caches/SpringBoard",
        @"/var/mobile/Library/Caches"
    ];
    for (NSString *dir in cacheDirs) {
        NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *e in entries) {
            if ([e localizedCaseInsensitiveContainsString:@"icon"]) {
                writeLog("cache entry [%@]: %@", dir, e);
            }
        }
    }
    Class mgrCls = objc_getClass("SBIconManager");
    if (mgrCls) {
        writeLog("class SBIconManager : YES");
        dumpMethodNames(mgrCls, YES, "odel", "SCAN SBIconManager cls");
        dumpMethodNames(mgrCls, NO, "odel", "SCAN SBIconManager inst");
        dumpMethodNames(mgrCls, YES, "shared", "SCAN SBIconManager cls-shared");
    } else {
        writeLog("class SBIconManager : NO");
    }
    dumpMethodNames(objc_getClass("SBIconModel"), YES, "shared", "SCAN SBIconModel cls-shared");
    dumpMethodNames(objc_getClass("SBHomeIconModel"), YES, "shared", "SCAN SBHomeIconModel cls-shared");

    // 直接读 3 个样本的角标（readBadge 的 args<2 bug 已修，现在应出真实数字）
    Class ctrlCls = objc_getClass("SBApplicationController");
    id ctrl = ctrlCls ? [ctrlCls performSelector:@selector(sharedInstance)] : nil;
    if (ctrl && [ctrl respondsToSelector:@selector(allApplications)]) {
        NSArray *apps = [ctrl allApplications];
        writeLog("app count=%lu", (unsigned long)[apps count]);
        for (NSUInteger i = 0; i < MIN((NSUInteger)3, [apps count]); i++) {
            id a = apps[i];
            NSString *bid = [a respondsToSelector:@selector(bundleIdentifier)]
                                ? [a bundleIdentifier] : @"(nil)";
            NSInteger b = readBadge(a);
            writeLog("badge direct-read[%lu] %s -> %ld",
                     (unsigned long)i, [bid UTF8String], (long)b);
        }
    }

    Class UI = objc_getClass("UIImage");
    writeLog("UIImage sel3=%d sel2=%d iconRoute=%d",
             [UI respondsToSelector:NSSelectorFromString(
                 @"_applicationIconImageForBundleIdentifier:format:scale:")],
             [UI respondsToSelector:NSSelectorFromString(
                 @"_applicationIconImageForBundleIdentifier:format:")],
             g_iconRoute);

    writeLog("window=%s row items=%lu version=%lu",
             g_window ? (g_window.hidden ? "hidden" : "visible") : "nil",
             [self row] ? (unsigned long)[[[self row] items] count] : 0,
             (unsigned long)g_snapshotVersion);
    if ([self row]) {
        CGRect f = [[self row] frame];
        writeLog("row frame: (%.1f %.1f; %.1f %.1f)",
                 f.origin.x, f.origin.y, f.size.width, f.size.height);
    }
    writeLog("========== END DIAGNOSTICS ==========");
}

@end

// ------------------------------ Hook 函数 ------------------------------
// 只保留角标写入事件（加速器）。渲染层已改为独立窗口，不再 hook 状态栏视图。
static void (*orig_setBadgeValue)(id, SEL, id);
static void my_setBadgeValue(id self, SEL _cmd, id v) {
    orig_setBadgeValue(self, _cmd, v);
    [[NIManager shared] pollSoon];
}

// ---------------- 0.9.0 启动期实例捕获 ----------------
// iOS 17.2.1 的 SBIconController 无 +sharedInstance（init 是 12 参依赖注入），
// SBHIconManager/SBHIconModel 也无类级单例。我们的 dylib 在 respring 时早于
// SpringBoard UI 加载，hook 两个短签名方法即可在启动期把活实例送上门：
//   -[SBIconController setModel:]       → controller + model
//   -[SBHIconModel setDelegate:]        → model + delegate(= SBHIconManager)
static void (*orig_iconCtl_setModel)(id, SEL, id);
static void my_iconCtl_setModel(id self, SEL _cmd, id model) {
    orig_iconCtl_setModel(self, _cmd, model);
    if (!g_sbIconController && self) g_sbIconController = self;
    if (!g_sbIconModel && model) g_sbIconModel = model;
    if (!g_captureLogged) {
        g_captureLogged = YES;
        writeLog("captured via setModel: controller=%s model=%s",
                 g_sbIconController ? NSStringFromClass([g_sbIconController class]).UTF8String : "nil",
                 g_sbIconModel ? NSStringFromClass([g_sbIconModel class]).UTF8String : "nil");
        resetIconCaches();
    }
}

static void (*orig_iconModel_setDelegate)(id, SEL, id);
static void my_iconModel_setDelegate(id self, SEL _cmd, id delegate) {
    orig_iconModel_setDelegate(self, _cmd, delegate);
    if (!g_sbIconModel && self) g_sbIconModel = self;
    if (!g_sbIconManager && delegate) g_sbIconManager = delegate;
    if (!g_captureLogged) {
        g_captureLogged = YES;
        writeLog("captured via setDelegate: model=%s manager=%s",
                 g_sbIconModel ? NSStringFromClass([g_sbIconModel class]).UTF8String : "nil",
                 g_sbIconManager ? NSStringFromClass([g_sbIconManager class]).UTF8String : "nil");
        resetIconCaches();
    }
}

// ------------------------------ Darwin 回调 ------------------------------
static void darwinReloadCB(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    [[NIManager shared] performSelectorOnMainThread:@selector(reloadPrefs)
                                         withObject:nil waitUntilDone:NO];
}

static void darwinDumpCB(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object,
                         CFDictionaryRef userInfo) {
    [[NIManager shared] performSelectorOnMainThread:@selector(dumpDiagnostics)
                                         withObject:nil waitUntilDone:NO];
}

// ------------------------------ 构造函数 ------------------------------
__attribute__((constructor)) static void NIInit(void) {
    @try {
        loadPrefs();
        writeLog("ctor: %s pid=%d debug=%d", getprogname(), getpid(), pref_debug);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            darwinReloadCB, (__bridge CFStringRef)kNotifyReload,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            darwinDumpCB, (__bridge CFStringRef)kNotifyDump,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 缓存目录
        mkdir("/var/mobile/Library/NotifierIcons", 0755);
        mkdir(kCacheDir, 0755);

        // hook 角标写入事件（加速器；主同步靠 2s 轮询）
        Class sbAppCls = objc_getClass("SBApplication");
        if (sbAppCls && [sbAppCls instancesRespondToSelector:@selector(setBadgeValue:)]) {
            MSHookMessageEx(sbAppCls, @selector(setBadgeValue:),
                            (IMP)my_setBadgeValue, (IMP *)&orig_setBadgeValue);
            writeLog("hooked SBApplication setBadgeValue:");
        } else {
            writeLog("setBadgeValue: not hookable — polling only");
        }

        // 0.9.0 启动期实例捕获（iOS 17 无 +sharedInstance）
        Class icCtlCls = objc_getClass("SBIconController");
        if (icCtlCls && [icCtlCls instancesRespondToSelector:@selector(setModel:)]) {
            MSHookMessageEx(icCtlCls, @selector(setModel:),
                            (IMP)my_iconCtl_setModel, (IMP *)&orig_iconCtl_setModel);
            writeLog("hooked SBIconController setModel: (instance capture)");
        }
        Class imCls = objc_getClass("SBHIconModel");
        if (imCls && [imCls instancesRespondToSelector:@selector(setDelegate:)]) {
            MSHookMessageEx(imCls, @selector(setDelegate:),
                            (IMP)my_iconModel_setDelegate, (IMP *)&orig_iconModel_setDelegate);
            writeLog("hooked SBHIconModel setDelegate: (instance capture)");
        }

        [[NIManager shared] performSelectorOnMainThread:@selector(startOnMain)
                                             withObject:nil waitUntilDone:NO];
        writeLog("ctor done");
    } @catch (NSException *e) {
        writeLog("ctor EXCEPTION: %s", e.reason.UTF8String);
    }
}
