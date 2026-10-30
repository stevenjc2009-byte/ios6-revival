// Settings > Clean Up System: free space, a description, one Clean button, then an alert saying how much was cleaned.
#import <UIKit/UIKit.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <unistd.h>
#import "RCCClean.h"

// From <crt_externs.h>, which the 9.3 SDK leaves out. A bundle cannot link environ itself (only executables
// get it): with environ, Settings could not load the pane at all.
extern char ***_NSGetEnviron(void);

// Theos's Preferences headers don't compile against the 9.3 SDK (newer availability macros), so only the
// members used here are declared. The real class lives in Preferences.framework.
@interface PSListController : UIViewController {
    NSMutableArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

@interface RCCListController : PSListController
@end

// Runs the setuid tool so root-owned crash logs and installers go too; NO if it could not run.
static BOOL RCCRunTool(unsigned long long *freed) {
    int fds[2];
    if (pipe(fds) != 0) return NO;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    pid_t pid;
    char *argv[] = { "revcacheclean", "-s", NULL };
    int err = posix_spawn(&pid, "/usr/bin/revcacheclean", &fa, NULL, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    if (err != 0) { close(fds[0]); return NO; }
    char buf[64];
    ssize_t n, len = 0;
    while (len < (ssize_t)sizeof buf - 1 && (n = read(fds[0], buf + len, sizeof buf - 1 - len)) > 0) len += n;
    buf[len] = 0;
    close(fds[0]);
    int status;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || len == 0) return NO;
    *freed = strtoull(buf, NULL, 10);
    return YES;
}

@implementation RCCListController

- (id)specifiers {
    if (!_specifiers) _specifiers = [[self loadSpecifiersFromPlistName:@"CacheCleaner" target:self] retain];
    return _specifiers;
}

// Free space on the data partition, where apps, photos and everything cleaned here live.
- (id)freeSpace:(id)specifier {
    struct statfs fs;
    if (statfs("/private/var", &fs) != 0) return @"-";
    double gb = (double)fs.f_bavail * fs.f_bsize / 1073741824.0;
    return gb >= 1 ? [NSString stringWithFormat:@"%.2f GB", gb]
                   : [NSString stringWithFormat:@"%.0f MB", gb * 1024];
}

- (void)clean:(id)specifier {
    unsigned long long freed = 0;
    if (!RCCRunTool(&freed)) freed = RCCClean(NO, NO);   // without the tool, clear what Settings itself may
    NSString *msg = [NSString stringWithFormat:@"Cleaned %.1f MB.", freed / 1048576.0];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"System Cleaned" message:msg delegate:nil
                                          cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
    [alert release];
    [self reloadSpecifiers];
}

@end
