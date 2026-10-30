// Clears caches the phone rebuilds by itself as it is used. Only files are deleted: every folder stays,
// so the app or daemon that owns it finds it on next use. Symlinks are never followed or deleted.
#import "RCCClean.h"
#include <stdio.h>

#define RCC_CACHES @"/var/mobile/Library/Caches"
#define RCC_APPS   @"/var/mobile/Applications"

// Folders whose contents are only caches.
static NSArray *RCCFolders(void) {
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:
        RCC_CACHES @"/MapTiles",                      // Maps tiles (MapTiles.sqlitedb), refetched as you browse
        RCC_CACHES @"/Snapshots",                     // pictures shown while built-in apps open
        RCC_CACHES @"/googleads.g.doubleclick.net",   // ad caches
        RCC_CACHES @"/pagead2.googlesyndication.com",
        RCC_CACHES @"/com.apple.iad.adlibd",
        RCC_CACHES @"/com.apple.AdSheetPhone", nil];
    // Pictures shown while App Store apps open, one folder per app.
    for (NSString *app in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:RCC_APPS error:NULL])
        [dirs addObject:[NSString stringWithFormat:@"%@/%@/Library/Caches/Snapshots", RCC_APPS, app]];
    return dirs;
}

// Single cache files outside those folders.
static NSArray *RCCFiles(void) {
    return [NSArray arrayWithObjects:RCC_CACHES @"/http_googleads.g.doubleclick.net_0.localstorage", nil];
}

// Size of path if it is a regular file (not a folder or symlink), else -1.
static long long RCCFileSize(NSString *path) {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [[a fileType] isEqualToString:NSFileTypeRegular] ? (long long)[a fileSize] : -1;
}

unsigned long long RCCClean(BOOL dryRun, BOOL verbose) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    // Collect first, delete after: deleting while enumerating a folder can skip files.
    NSMutableArray *paths = [NSMutableArray arrayWithArray:RCCFiles()];
    for (NSString *dir in RCCFolders())
        for (NSString *rel in [fm enumeratorAtPath:dir]) [paths addObject:[dir stringByAppendingPathComponent:rel]];

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
    [pool drain];
    return freed;
}
