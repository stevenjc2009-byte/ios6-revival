// revbgservices: turns Apple background services on or off (Settings > Background Services).
// Each switch saves <label> = YES/NO; this loads or unloads /System/Library/LaunchDaemons/<label>.plist with -w,
// so launchd remembers the choice across reboots. launchd runs this whenever a switch changes.
//   revbgservices          apply the switches (what launchd runs)
//   revbgservices init     save each service's current state as its switch, if nothing is saved yet (install)
//   revbgservices status   print each switch and whether the service is loaded
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

#define BG_PREFS @"/var/mobile/Library/Preferences/com.stevenjc.ios6revival.bgservices.plist"
#define BG_DIR   @"/System/Library/LaunchDaemons"

extern char **environ;

// The services the pane lists; each one's label is its switch's key.
static NSArray *BGLabels(void) {
    return [NSArray arrayWithObjects:@"com.apple.weibod", @"com.apple.twitterd", @"com.apple.sociald",
                                     @"com.apple.gamed", @"com.apple.aggregated", nil];
}

// Runs launchctl with its output thrown away; returns its exit code (-1 if it could not run).
static int BGLaunchctl(char *verb, char *flag, NSString *arg) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    char *argv[5] = { "launchctl", verb, flag, NULL, NULL };
    argv[flag ? 3 : 2] = (char *)[arg fileSystemRepresentation];
    pid_t pid;
    int status, err = posix_spawn(&pid, "/bin/launchctl", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (err != 0 || waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

static BOOL BGLoaded(NSString *label) {
    return BGLaunchctl("list", NULL, label) == 0;
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *cmd = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:BG_PREFS];

    if ([cmd isEqualToString:@"init"]) {
        if (!prefs) {
            NSMutableDictionary *now = [NSMutableDictionary dictionary];
            for (NSString *label in BGLabels())
                [now setObject:[NSNumber numberWithBool:BGLoaded(label)] forKey:label];
            [now writeToFile:BG_PREFS atomically:YES];
            chown([BG_PREFS fileSystemRepresentation], 501, 501);   // mobile, so Settings can save the switches
        }
        [pool drain];
        return 0;
    }

    for (NSString *label in BGLabels()) {
        id v = [prefs objectForKey:label];
        BOOL loaded = BGLoaded(label);
        if ([cmd isEqualToString:@"status"]) {
            printf("%s\tswitch %s\t%s\n", [label UTF8String],
                   ![v respondsToSelector:@selector(boolValue)] ? "unset" : [v boolValue] ? "on" : "off",
                   loaded ? "loaded" : "not loaded");
            continue;
        }
        if (![v respondsToSelector:@selector(boolValue)] || [v boolValue] == loaded) continue;   // unset: leave it
        NSString *plist = [NSString stringWithFormat:@"%@/%@.plist", BG_DIR, label];
        BGLaunchctl([v boolValue] ? "load" : "unload", "-w", plist);
        NSLog(@"revbgservices: %@ %@", label, BGLoaded(label) ? @"on" : @"off");
    }
    [pool drain];
    return 0;
}
