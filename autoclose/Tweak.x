// ios6-revival AutoClose: when an app opens and too many apps are running, close all the others.
// Keeps the app you are on, the app playing audio, and Phone (iOS relaunches it straight away).
// SpringBoard, iOS 6. Manual retain/release (no ARC). Selectors checked against the iOS 6.1.3 SpringBoard binary.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <signal.h>

#define AC_PREFS_PATH @"/var/mobile/Library/Preferences/com.stevenjc.ios6revival.autoclose.plist"
#define AC_DEFAULT_LIMIT 5
#define AC_MIN_LIMIT 2
#define AC_CHECK_DELAY 1.0      // seconds after an app opens, so its launch settles first

@interface SBApplication : NSObject
- (NSString *)displayIdentifier;
- (BOOL)isRunning;
- (BOOL)isWebApplication;
- (int)pid;
@end
@interface SBApplicationController : NSObject
+ (id)sharedInstance;
- (NSArray *)allApplications;
@end
@interface SBMediaController : NSObject
+ (id)sharedInstance;
- (SBApplication *)nowPlayingApplication;
- (BOOL)isPlaying;
@end
@interface SBAppSwitcherModel : NSObject
+ (id)sharedInstance;
- (void)remove:(NSString *)displayIdentifier;
@end
@interface SpringBoard : NSObject
- (SBApplication *)_accessibilityFrontMostApplication;
@end

typedef void (*ACTerminateFn)(NSString *bundleID, int reason, BOOL report, NSString *description);

static BOOL ACEnabled(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:AC_PREFS_PATH];
    id v = [d isKindOfClass:[NSDictionary class]] ? [d objectForKey:@"Enabled"] : nil;
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;
}

static NSInteger ACLimit(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:AC_PREFS_PATH];
    id v = [d isKindOfClass:[NSDictionary class]] ? [d objectForKey:@"Limit"] : nil;
    NSInteger n = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : AC_DEFAULT_LIMIT;
    return n < AC_MIN_LIMIT ? AC_DEFAULT_LIMIT : n;
}

// Same call the iOS 6 app switcher uses to quit an app; falls back to SIGKILL if it is missing.
static void ACTerminate(SBApplication *app) {
    static ACTerminateFn terminate = NULL;
    static BOOL looked = NO;
    if (!looked) {
        terminate = (ACTerminateFn)dlsym(RTLD_DEFAULT, "BKSTerminateApplicationForReasonAndReportWithDescription");
        looked = YES;
    }
    NSString *ident = [app displayIdentifier];
    if (terminate) terminate(ident, 1, NO, @"AutoClose: too many apps open");
    else if ([app pid] > 0) kill([app pid], SIGKILL);
    [[%c(SBAppSwitcherModel) sharedInstance] remove:ident];
}

static void ACCheck(NSString *openedIdent) {
    if (!ACEnabled()) return;
    NSInteger limit = ACLimit();
    SBApplication *front = [(SpringBoard *)[UIApplication sharedApplication] _accessibilityFrontMostApplication];
    NSString *keep = front ? [front displayIdentifier] : openedIdent;
    SBMediaController *media = [%c(SBMediaController) sharedInstance];
    NSString *playing = [media isPlaying] ? [[media nowPlayingApplication] displayIdentifier] : nil;

    NSMutableArray *running = [NSMutableArray array];
    for (SBApplication *app in [[%c(SBApplicationController) sharedInstance] allApplications]) {
        if ([app isRunning] && ![app isWebApplication] && [app displayIdentifier]) [running addObject:app];
    }
    if ((NSInteger)[running count] < limit) return;

    NSMutableArray *closed = [NSMutableArray array];
    for (SBApplication *app in running) {
        NSString *ident = [app displayIdentifier];
        if ([ident isEqualToString:keep] || [ident isEqualToString:playing] ||
            [ident isEqualToString:@"com.apple.mobilephone"]) continue;
        ACTerminate(app);
        [closed addObject:ident];
    }
    NSLog(@"[AutoClose] %d apps running (limit %d), kept %@%@, closed: %@",
          (int)[running count], (int)limit, keep, playing ? [@" + playing " stringByAppendingString:playing] : @"",
          [closed componentsJoinedByString:@", "]);
}

%hook SBApplication
- (void)didActivate {
    %orig;
    NSString *ident = [[[self displayIdentifier] copy] autorelease];
    if (!ident) return;
    [ident retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(AC_CHECK_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ACCheck(ident);
        [ident release];
    });
}
%end
