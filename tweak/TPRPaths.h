#import <Foundation/Foundation.h>

// Paths inside the jailbreak's root (/var/jb on rootless); libroot resolves it at runtime.
#if TPR_SIMULATOR
#define TPRRootPath(path) (path)
#else
#import <rootless.h>
#define TPRRootPath(path) ROOT_PATH_NS(path)
#endif

#if TPR_SIMULATOR   // the test bench's tmp dir, as in +[TPRConfig prefsPath]
#define TPRPrefsFile [NSTemporaryDirectory() stringByAppendingPathComponent:@"dev.rtrdd.toprow.plist"]
#else
#define TPRPrefsFile TPRRootPath(@"/var/mobile/Library/Preferences/dev.rtrdd.toprow.plist")
#endif
// Saved setups and backups (Settings only: keyboards never read it).
#if TPR_SIMULATOR
#define TPRSetupsFile [NSTemporaryDirectory() stringByAppendingPathComponent:@"dev.rtrdd.toprow.setups.plist"]
#else
#define TPRSetupsFile TPRRootPath(@"/var/mobile/Library/Preferences/dev.rtrdd.toprow.setups.plist")
#endif
#define TPRKillSwitchFile TPRRootPath(@"/var/mobile/Library/Preferences/dev.rtrdd.toprow.disabled")
