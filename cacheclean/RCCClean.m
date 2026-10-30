// Clears caches the phone rebuilds by itself, crash logs, saved App Store bags and old app installers.
// Only files are deleted: every folder stays, so the app or daemon that owns it finds it on next use.
// Symlinks are never followed; inside the crash-log folders the LatestCrash-* links are deleted with their logs.
// revcacheclean runs this as root (setuid), so every folder is skipped unless its real path is the one listed.
#import "RCCClean.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#define RCC_CACHES @"/var/mobile/Library/Caches"
#define RCC_APPS   @"/var/mobile/Applications"

// Crash and low-memory reports: one folder for apps (mobile), one for system processes (root).
static NSArray *RCCCrashFolders(void) {
    return [NSArray arrayWithObjects:@"/var/mobile/Library/Logs/CrashReporter", @"/var/logs/CrashReporter", nil];
}

// Folders whose contents are only caches or leftovers.
static NSArray *RCCFolders(void) {
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:
        RCC_CACHES @"/MapTiles",                      // Maps tiles (MapTiles.sqlitedb), refetched as you browse
        RCC_CACHES @"/Snapshots",                     // pictures shown while built-in apps open
        RCC_CACHES @"/googleads.g.doubleclick.net",   // ad caches
        RCC_CACHES @"/pagead2.googlesyndication.com",
        RCC_CACHES @"/com.apple.iad.adlibd",
        RCC_CACHES @"/com.apple.AdSheetPhone",
        @"/var/mobile/Library/ios6revival/appstore-capture",   // store bags saved by the Revival App Store
        @"/var/mobile/Documents/ipa-backup", nil];             // installers kept when apps were replaced
    [dirs addObjectsFromArray:RCCCrashFolders()];
    // Pictures shown while App Store apps open, one folder per app.
    for (NSString *app in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:RCC_APPS error:NULL])
        [dirs addObject:[NSString stringWithFormat:@"%@/%@/Library/Caches/Snapshots", RCC_APPS, app]];
    return dirs;
}

// Single cache files outside those folders.
static NSArray *RCCFiles(void) {
    return [NSArray arrayWithObjects:RCC_CACHES @"/http_googleads.g.doubleclick.net_0.localstorage", nil];
}

// YES when no part of dir is a symlink (apart from /var itself), so a planted link cannot redirect a root delete.
static BOOL RCCRealFolder(NSString *dir) {
    char real[PATH_MAX];
    if (!realpath([dir fileSystemRepresentation], real)) return NO;
    NSString *expect = [dir hasPrefix:@"/var/"] ? [@"/private" stringByAppendingString:dir] : dir;
    return [[NSString stringWithUTF8String:real] isEqualToString:expect];
}

// Size of path if it is a regular file (not a folder or symlink), else -1.
static long long RCCFileSize(NSString *path) {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [[a fileType] isEqualToString:NSFileTypeRegular] ? (long long)[a fileSize] : -1;
}

static BOOL RCCIsLink(NSString *path) {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [[a fileType] isEqualToString:NSFileTypeSymbolicLink];
}

unsigned long long RCCClean(BOOL dryRun, BOOL verbose) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *crashDirs = RCCCrashFolders();
    // Collect first, delete after: deleting while enumerating a folder can skip files.
    NSMutableArray *paths = [NSMutableArray arrayWithArray:RCCFiles()], *links = [NSMutableArray array];
    for (NSString *dir in RCCFolders()) {
        if (!RCCRealFolder(dir)) continue;
        BOOL crash = [crashDirs containsObject:dir];
        for (NSString *rel in [fm enumeratorAtPath:dir]) {
            NSString *path = [dir stringByAppendingPathComponent:rel];
            if (crash && RCCIsLink(path)) [links addObject:path];
            else [paths addObject:path];
        }
    }

    unsigned long long freed = 0;
    for (NSString *path in paths) {
        long long size = RCCFileSize(path);
        if (size < 0) continue;
        if (!dryRun && ![fm removeItemAtPath:path error:NULL]) {
            if (verbose) printf("FAILED\t%s\n", [path UTF8String]);
            continue;
        }
        freed += size;
        if (verbose) printf("%lld\t%s\n", size, [path UTF8String]);
    }
    // LatestCrash-*.plist links point at the reports just deleted; removing a link removes only the link.
    for (NSString *path in links) {
        if (!dryRun) [fm removeItemAtPath:path error:NULL];
        if (verbose) printf("link\t%s\n", [path UTF8String]);
    }
    [pool drain];
    return freed;
}
