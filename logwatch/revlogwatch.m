// revlogwatch: checks the phone's system log (/var/log/syslog) once an hour (launchd runs it).
// When the log reaches the size set in Settings > Phone Log, shows a banner; that many days later deletes the log.
//   revlogwatch           hourly check (what launchd runs)
//   revlogwatch status    print size, limit and deletion time
#import <Foundation/Foundation.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define LW_LOG        "/var/log/syslog"
#define LW_SYSLOG_PID "/var/run/syslog.pid"
#define LW_PREFS      @"/var/mobile/Library/Preferences/com.stevenjc.ios6revival.logwatch.plist"
#define LW_STATE      @"/var/mobile/Library/ios6revival/logwatch-state.plist"
#define LW_KEY_WARNED @"WarnedAt"
#define LW_MB         (1024.0 * 1024.0)

// Settings writes numbers as strings; anything missing, unreadable or not above zero falls back to the default.
static double LWPref(NSDictionary *prefs, NSString *key, double fallback) {
    id v = [prefs objectForKey:key];
    double d = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
    return d > 0 ? d : fallback;
}

static NSString *LWNumber(double d) {
    return d == floor(d) ? [NSString stringWithFormat:@"%.0f", d] : [NSString stringWithFormat:@"%.1f", d];
}

static void LWNotify(NSString *title, NSString *message) {
    char *argv[] = { "revnotify", (char *)[title UTF8String], (char *)[message UTF8String], NULL };
    pid_t pid;
    extern char **environ;
    if (posix_spawn(&pid, "/usr/bin/revnotify", NULL, NULL, argv, environ) == 0) waitpid(pid, NULL, 0);
}

// Deletes the log, then tells syslogd to reopen (it creates a new empty file).
static void LWDeleteLog(void) {
    unlink(LW_LOG);
    FILE *f = fopen(LW_SYSLOG_PID, "r");
    int pid = 0;
    if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; fclose(f); }
    if (pid > 1) kill(pid, SIGHUP);
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:LW_PREFS];
    double limitMB = LWPref(prefs, @"SizeMB", 90);
    double days = LWPref(prefs, @"Days", 2);

    struct stat st;
    double sizeMB = stat(LW_LOG, &st) == 0 ? st.st_size / LW_MB : 0;
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithContentsOfFile:LW_STATE] ?: [NSMutableDictionary dictionary];
    NSDate *warned = [state objectForKey:LW_KEY_WARNED];
    if (![warned isKindOfClass:[NSDate class]]) warned = nil;
    NSDate *deleteAt = warned ? [warned dateByAddingTimeInterval:days * 86400] : nil;

    if (argc > 1 && [[NSString stringWithUTF8String:argv[1]] isEqualToString:@"status"]) {
        printf("log %.2f MB, limit %s MB, %s days\n", sizeMB, [LWNumber(limitMB) UTF8String], [LWNumber(days) UTF8String]);
        printf("warned %s, deletes %s\n", warned ? [[warned description] UTF8String] : "no",
               deleteAt ? [[deleteAt description] UTF8String] : "not scheduled");
        [pool drain];
        return 0;
    }

    if (sizeMB < limitMB) {
        // Back under the limit (deleted or uploaded by hand, or the limit was raised): forget the warning.
        if (warned) [[NSFileManager defaultManager] removeItemAtPath:LW_STATE error:NULL];
    } else if (!warned) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[LW_STATE stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [state setObject:[NSDate date] forKey:LW_KEY_WARNED];
        [state writeToFile:LW_STATE atomically:YES];
        // Banners show one short line, so the size goes in the title.
        NSString *size = LWNumber(sizeMB >= 1 ? floor(sizeMB) : floor(sizeMB * 10) / 10);
        LWNotify([NSString stringWithFormat:@"System log is at %@ megabytes", size],
                 [NSString stringWithFormat:@"%@ %@ until deletion.", LWNumber(days), days == 1 ? @"day" : @"days"]);
    } else if ([deleteAt timeIntervalSinceNow] <= 0) {
        LWDeleteLog();
        [[NSFileManager defaultManager] removeItemAtPath:LW_STATE error:NULL];
    }
    [pool drain];
    return 0;
}
