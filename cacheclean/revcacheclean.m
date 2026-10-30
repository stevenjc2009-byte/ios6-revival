// revcacheclean: clears Maps tiles, app snapshots and ad caches, the same files as Settings > Clear Caches.
//   revcacheclean      delete them, printing each file and the total freed
//   revcacheclean -n   only list what would be deleted
#import <Foundation/Foundation.h>
#include <stdio.h>
#import "RCCClean.h"

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    BOOL dryRun = [args count] > 1 && [[args objectAtIndex:1] isEqualToString:@"-n"];
    unsigned long long freed = RCCClean(dryRun, YES);
    printf("%s %llu bytes (%.1f MB)\n", dryRun ? "would free" : "freed", freed, freed / 1048576.0);
    [pool drain];
    return 0;
}
