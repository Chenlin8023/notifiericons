// NIAppPickerController.m — 应用选择页
//
// 应用来源：LSApplicationWorkspace（Preferences 进程内可用，Settings 自己就用它），
// 不引入 AppList/AltList 依赖，少一个包依赖就少一个失效点。
// 每个应用一个 PSSwitchCell，键名 "sel.<bundleID>"，直接写进
// com.chenlin8023.notifiericons 域 —— SpringBoard 侧用 CFPreferencesCopyKeyList
// 枚举 sel.* 键还原选中集合。
// specifier 全代码创建；全文件无 block。

#import "NIAppPickerController.h"
#import <Preferences/PSSpecifier.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kPrefDomain   = @"com.chenlin8023.notifiericons";
static NSString *const kNotifyReload = @"com.chenlin8023.notifiericons/reloadPrefs";

static NSString *L(NSString *zh, NSString *en) {
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    return [lang hasPrefix:@"zh"] ? zh : en;
}

// LSApplicationProxy 最小声明（属性走运行时探测，头文件只声明需要的）
@interface LSAppProxyStub : NSObject
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly, copy) NSString *localizedName;
@property (nonatomic, readonly, copy) NSString *applicationType;
@end

@implementation NIAppPickerController

+ (NSArray *)userApps {
    NSMutableArray *res = [NSMutableArray array];
    Class wsCls = objc_getClass("LSApplicationWorkspace");
    if (!wsCls) return res;
    id ws = [wsCls performSelector:@selector(defaultWorkspace)];
    if (!ws) return res;
    NSArray *all = [ws performSelector:@selector(allInstalledApplications)];
    if (!all) return res;

    for (id proxy in all) {
        @try {
            NSString *type = nil;
            if ([proxy respondsToSelector:@selector(applicationType)])
                type = [proxy applicationType];
            if (type && ![type isEqualToString:@"User"]) continue;

            NSString *bid = nil;
            if ([proxy respondsToSelector:@selector(bundleIdentifier)])
                bid = [proxy bundleIdentifier];
            if (![bid length]) continue;

            // 跳过明显不该出现在通知监控里的系统组件（白名单式的 User 应用已过滤大部分）
            if ([bid hasPrefix:@"com.apple.WebSheet"]) continue;

            NSString *name = nil;
            if ([proxy respondsToSelector:@selector(localizedName)]) name = [proxy localizedName];
            if (![name length]) name = bid;
            [res addObject:@{ @"bid": bid, @"name": name }];
        } @catch (NSException *e) {
            continue;
        }
    }
    // 无 block 排序（Preferences 进程也是 arm64e，禁止任何 block 字面量）：
    // NSSortDescriptor 内部不经过全局 block 的 objc_retain 路径
    NSSortDescriptor *d = [NSSortDescriptor sortDescriptorWithKey:@"name"
                                                        ascending:YES
                                                         selector:@selector(localizedStandardCompare:)];
    [res sortUsingDescriptors:@[ d ]];
    return res;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *specs = [NSMutableArray array];

    NSArray *apps = [NIAppPickerController userApps];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:L(@"监控的应用", @"Monitored Apps")];
    [group setProperty:[NSString stringWithFormat:
                            L(@"共 %lu 个用户应用。开关即保存，返回后立即生效（无需注销）。"
                              @"如果列表为空，说明 LSApplicationWorkspace 不可用，请反馈日志。",
                              @"%lu user apps. Toggles save instantly (no respring needed). "
                              @"Empty list means LSApplicationWorkspace is unavailable — send the log."),
                        (unsigned long)[apps count]]
                forKey:@"footerText"];
    [specs addObject:group];

    for (NSDictionary *app in apps) {
        NSString *bid = app[@"bid"];
        PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:app[@"name"]
                                                        target:self
                                                           set:@selector(setPreferenceValue:specifier:)
                                                           get:@selector(readPreferenceValue:)
                                                        detail:nil
                                                          cell:PSSwitchCell
                                                          edit:nil];
        [sw setProperty:kPrefDomain forKey:@"defaults"];
        [sw setProperty:[NSString stringWithFormat:@"sel.%@", bid] forKey:@"key"];
        [sw setProperty:@NO forKey:@"default"];
        [sw setProperty:kNotifyReload forKey:@"PostNotification"];
        [specs addObject:sw];
    }

    _specifiers = specs;
    return _specifiers;
}

@end
