// revcacheclean: clears caches, crash logs, saved App Store bags and old installers, the same files as
// Settings > Clean Up System. Installed setuid root so the Settings pane can also clear root-owned crash logs.
//   revcacheclean      delete them, printing each file and the total freed
//   revcacheclean -n   only list what would be deleted
//   revcacheclean -s   delete them and print only the bytes freed (what Settings runs)
#import <Foundation/Foundation.h>
#include <stdio.h>
#import "RCCClean.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    NSString *flag = [args count] > 1 ? [args objectAtIndex:1] : @"";
    BOOL dryRun = [flag isEqualToString:@"-n"], summary = [flag isEqualToString:@"-s"];
    unsigned long long freed = RCCClean(dryRun, !summary);
    if (summary) printf("%llu\n", freed);
    else printf("%s %llu bytes (%.1f MB)\n", dryRun ? "would free" : "freed", freed, freed / 1048576.0);
    [pool drain];
    return 0;
}
