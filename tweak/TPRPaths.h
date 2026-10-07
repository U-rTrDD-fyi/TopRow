#import <Foundation/Foundation.h>

// Paths inside the jailbreak's root (/var/jb on rootless); libroot resolves it at runtime.
#if TPR_SIMULATOR
#define TPRRootPath(path) (path)
#else
#import <rootless.h>
#define TPRRootPath(path) ROOT_PATH_NS(path)
#endif

#define TPRPrefsFile TPRRootPath(@"/var/mobile/Library/Preferences/dev.rtrdd.toprow.plist")
#define TPRKillSwitchFile TPRRootPath(@"/var/mobile/Library/Preferences/dev.rtrdd.toprow.disabled")
