// ios6-revival Notify: banners on the iPhone for app installs and for messages from revnotify.
// SpringBoard, iOS 6. Manual retain/release (no ARC). Selectors checked against the iOS 6.1.3 SpringBoard binary.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <notify.h>
#import "RNShared.h"

@interface BBBulletinRequest : NSObject
@property (copy) NSString *title, *message, *sectionID, *bulletinID, *recordID, *publisherBulletinID;
@property (retain) NSDate *date;
@end
@interface SBBulletinBannerController : NSObject
+ (id)sharedInstance;
- (void)observer:(id)observer addBulletin:(id)bulletin forFeed:(unsigned)feed;
@end
@interface SBAwayController : NSObject
+ (id)sharedAwayControllerIfExists;
- (BOOL)isLocked;
@end
@interface SBApplication : NSObject
- (NSString *)displayName;
- (NSString *)displayIdentifier;
- (NSBundle *)bundle;
@end
@interface SBApplicationController : NSObject
+ (id)sharedInstance;
- (SBApplication *)applicationWithDisplayIdentifier:(NSString *)ident;
- (NSArray *)allApplications;
@end

static NSMutableArray *rnWaiting;   // banners held back while the phone is locked
static BOOL rnReady;                // SpringBoard finished launching; before this nothing is shown
static NSMutableDictionary *rnVersions;   // display identifier -> version last seen, so a rescan (uicache) is not an update

static void RNShowNow(NSString *title, NSString *message, NSString *section) {
    Class cls = %c(BBBulletinRequest);
    SBBulletinBannerController *banner = [%c(SBBulletinBannerController) sharedInstance];
    if (!cls || !banner) { NSLog(@"[RevivalNotify] banner classes missing: %@: %@", title, message); return; }
    BBBulletinRequest *b = [[cls alloc] init];
    NSString *uid = [[NSProcessInfo processInfo] globallyUniqueString];
    b.title = title;
    b.message = message;
    b.sectionID = section ?: RN_DEFAULT_SECTION;
    b.bulletinID = uid; b.recordID = uid; b.publisherBulletinID = uid;
    b.date = [NSDate date];
    [banner observer:nil addBulletin:b forFeed:2];
    [b release];
    NSLog(@"[RevivalNotify] banner: %@: %@", title, message);
}

static void RNShow(NSString *title, NSString *message, NSString *section) {
    // IfExists: never create the lock screen controller from here (doing work during launch hung SpringBoard).
    Class away = %c(SBAwayController);
    id lock = [away respondsToSelector:@selector(sharedAwayControllerIfExists)] ? [away sharedAwayControllerIfExists] : nil;
    if ([lock isLocked]) {
        if (!rnWaiting) rnWaiting = [[NSMutableArray alloc] init];
        [rnWaiting addObject:@{ RN_KEY_TITLE: title ?: @"", RN_KEY_MESSAGE: message ?: @"", RN_KEY_SECTION: section ?: RN_DEFAULT_SECTION }];
        return;
    }
    RNShowNow(title, message, section);
}

static void RNFlushWaiting(void) {
    NSArray *items = [rnWaiting autorelease];
    rnWaiting = nil;
    NSTimeInterval delay = 0.8;   // let the unlock animation finish; space banners out
    for (NSDictionary *d in items) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RNShowNow([d objectForKey:RN_KEY_TITLE], [d objectForKey:RN_KEY_MESSAGE], [d objectForKey:RN_KEY_SECTION]);
        });
        delay += 4.0;
    }
}

// Shows and deletes every message revnotify left in the spool folder.
static void RNDrainSpool(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [[fm contentsOfDirectoryAtPath:RN_SPOOL_DIR error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (![name hasSuffix:@".plist"]) continue;
        NSString *path = [RN_SPOOL_DIR stringByAppendingPathComponent:name];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        [fm removeItemAtPath:path error:NULL];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        RNShow([d objectForKey:RN_KEY_TITLE], [d objectForKey:RN_KEY_MESSAGE], [d objectForKey:RN_KEY_SECTION]);
    }
}

static void RNSpoolPosted(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (rnReady) RNDrainSpool(); });
}

static NSString *RNVersion(SBApplication *app) {
    NSDictionary *info = [[app bundle] infoDictionary];
    return [info objectForKey:@"CFBundleShortVersionString"] ?: [info objectForKey:@"CFBundleVersion"];
}

static NSString *RNVersionKey(SBApplication *app) {
    NSDictionary *info = [[app bundle] infoDictionary];
    return [NSString stringWithFormat:@"%@/%@", [info objectForKey:@"CFBundleShortVersionString"], [info objectForKey:@"CFBundleVersion"]];
}

static void RNRememberVersions(void) {
    rnVersions = [[NSMutableDictionary alloc] init];
    for (SBApplication *app in [[%c(SBApplicationController) sharedInstance] allApplications]) {
        NSString *ident = [app displayIdentifier];
        if (ident) [rnVersions setObject:RNVersionKey(app) forKey:ident];
    }
}

// The sets may hold display identifiers or SBApplication objects; accept both.
// Updates are only announced when the version really changed.
static void RNAnnounceApps(NSSet *items, BOOL onlyIfChanged) {
    for (id item in items) {
        NSString *ident = [item isKindOfClass:[NSString class]] ? item
                        : ([item respondsToSelector:@selector(displayIdentifier)] ? [item displayIdentifier] : nil);
        if (!ident) continue;
        SBApplication *app = [[%c(SBApplicationController) sharedInstance] applicationWithDisplayIdentifier:ident];
        NSString *key = RNVersionKey(app);
        BOOL same = [[rnVersions objectForKey:ident] isEqualToString:key];
        [rnVersions setObject:key forKey:ident];
        if (onlyIfChanged && same) continue;
        NSString *name = [app displayName] ?: ident;
        NSString *version = RNVersion(app);
        NSString *msg = version ? [NSString stringWithFormat:@"%@ version %@ was installed.", name, version]
                                : [NSString stringWithFormat:@"%@ was installed.", name];
        RNShow(@"App installed", msg, ident);
    }
}

%hook SBApplicationController
- (void)_sendInstalledAppsDidChangeNotification:(NSSet *)added removed:(NSSet *)removed modified:(NSSet *)modified {
    %orig;
    // Boot loads every app through here; only announce real installs, and never from inside this call.
    if (!rnReady) return;
    NSSet *a = [added copy], *m = [modified copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        RNAnnounceApps(a, NO);
        RNAnnounceApps(m, YES);
        [a release]; [m release];
    });
}
%end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // Wait for the home screen to settle, then start listening and show what queued up while SpringBoard was down.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RNRememberVersions();
        rnReady = YES;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, RNSpoolPosted,
                                        CFSTR(RN_DARWIN_NAME), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        RNDrainSpool();
    });
}
%end

%hook SBAwayController
- (void)_finishUnlockWithSound:(BOOL)sound unlockSource:(int)source isAutoUnlock:(BOOL)autoUnlock {
    %orig;
    if ([rnWaiting count]) RNFlushWaiting();
}
%end
