// Shared by the Settings pane and the revcacheclean tool, so both clear exactly the same files.
#import <Foundation/Foundation.h>

// Deletes (or with dryRun only counts) Maps tiles, app snapshots and ad caches; returns the bytes freed.
// verbose prints each file and its size to stdout (the tool uses it, Settings does not).
unsigned long long RCCClean(BOOL dryRun, BOOL verbose);
