// Shared by the Settings pane and the revcacheclean tool, so both clear exactly the same files.
#import <Foundation/Foundation.h>

// Deletes (or with dryRun only counts) caches, crash logs, saved App Store bags and old installers; returns the bytes freed.
// verbose prints each file and its size to stdout (the tool uses it, Settings does not).
unsigned long long RCCClean(BOOL dryRun, BOOL verbose);
