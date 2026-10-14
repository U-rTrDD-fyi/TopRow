#import <Foundation/Foundation.h>

// Setups: named copies of TopRow's settings in their own file (keyboards never read it),
// plus automatic backups made before something replaces the settings. A setup is
// @{ID, Name, Date, Settings}; Settings holds every setting except Enabled, and only the
// values that differ from the defaults. Also the text format setups are shared in.

#define TPRMaxSetups 50
#define TPRMaxBackups 3
#define TPRMaxSetupNameLength 40

// Posted (Darwin) after every change to the setups file.
extern NSString *const TPRSetupsChangedNotification;

NSArray<NSDictionary *> *TPRSetupsSaved(void);     // newest first
NSArray<NSDictionary *> *TPRSetupsBackups(void);   // newest first
NSDictionary *TPRSetupWithID(NSString *setupID);   // saved or backup
BOOL TPRSetupIsBackup(NSString *setupID);

// The current settings as a setup holds them. Excluded Apps is always there (maybe empty),
// so applying the setup later brings that list back too.
NSDictionary *TPRSetupCurrentSettings(void);

// nil if it worked, else why not (shown to the user).
NSString *TPRSetupsSave(NSString *name, NSDictionary *settings);
NSString *TPRSetupsRename(NSString *setupID, NSString *name);
NSString *TPRSetupNameProblem(NSString *name);   // just the name rules, for names not saved
void TPRSetupsDelete(NSString *setupID);
// The first free "Setup N".
NSString *TPRSetupsSuggestedName(void);
// `name`, or "name 2", "name 3", ... if a saved setup already has it.
NSString *TPRSetupsUniqueName(NSString *name);

// Saves the current settings as a backup named `reason`, unless they're all defaults or the
// same as the newest backup. YES if it saved one.
BOOL TPRSetupsBackUp(NSString *reason);
// Backs up, then replaces the settings with the setup's. Enabled stays as it is, and so does
// Excluded Apps when the setup has no list (shared setups usually don't). YES if it backed up.
BOOL TPRSetupApply(NSDictionary *setup, NSString *backupReason);

// One-time flags kept with the setups ("KeysPageSeen").
BOOL TPRSetupsFlag(NSString *flag);
void TPRSetupsSetFlag(NSString *flag);

// The setups file as bytes (empty if missing), and what this process last wrote there.
NSData *TPRSetupsFileData(void);
NSData *TPRSetupsLastWrittenData(void);

// ---- sharing ----

// "Label: value" for each setting in `settings` that isn't at its default, in Settings order.
NSArray<NSString *> *TPRSetupLines(NSDictionary *settings, BOOL includeExcludedApps);
// The shared text: a "TopRow setup: <name>" line, a note, then TPRSetupLines.
NSString *TPRSetupText(NSString *name, NSDictionary *settings, BOOL includeExcludedApps);
// Reads shared text. nil if it isn't a setup; else its settings (valid, non-default values
// only), with *name from its "TopRow setup:" line (or "Imported Setup") and *problems
// naming each line that was skipped and why.
NSDictionary *TPRSetupParse(NSString *text, NSString **name, NSArray<NSString *> **problems);
