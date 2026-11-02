ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------------------
# 动态库：注入 SpringBoard（单进程），负责角标事件 / 轮询同步 / 状态栏图标行
# ---------------------------------------------------------------------------
TWEAK_NAME = NotifierIcons
NotifierIcons_FILES = NotifierIcons.m
NotifierIcons_FRAMEWORKS = UIKit Foundation CoreFoundation
# rootless 链接标准 substrate stub（ElleKit 在 /var/jb 下提供），补 /var/jb rpath
NotifierIcons_LDFLAGS = -lsubstrate -Wl,-rpath,/var/jb/Library/Frameworks -Wl,-rpath,/var/jb/usr/lib
NotifierIcons_CFLAGS = -fobjc-arc -Wall -Wno-unused-function -Wno-unused-variable
NotifierIcons_OBJCCFLAGS = -fno-modules

# ---------------------------------------------------------------------------
# 设置面板（PreferenceBundle）：prefs/ 源码编译，arm64 + arm64e
# specifier 全代码创建，不依赖 Root.plist
# ---------------------------------------------------------------------------
BUNDLE_NAME = NIPrefs
NIPrefs_FILES = prefs/NIRootListController.m prefs/NIAppPickerController.m
NIPrefs_INSTALL_PATH = /Library/PreferenceBundles
NIPrefs_FRAMEWORKS = UIKit Foundation
NIPrefs_PRIVATE_FRAMEWORKS = Preferences
NIPrefs_CFLAGS = -fobjc-arc -Wall

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
