// revupdateblock: blocks or allows the iOS software update check (Settings > iOS Updates).
// iOS 6 finds updates at mesu.apple.com; pointing that name at this phone in /etc/hosts means Settings never
// offers iOS 7 (which would remove the jailbreak). launchd runs this at boot and whenever the switch changes.
//   revupdateblock           apply the switch (what launchd runs)
//   revupdateblock remove    take the block out whatever the switch says (package removal)
//   revupdateblock status    print the switch, the hosts lines and what mesu.apple.com resolves to
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>

#define UB_HOSTS  @"/private/etc/hosts"
#define UB_PREFS  @"/var/mobile/Library/Preferences/com.stevenjc.ios6revival.updateblock.plist"
#define UB_KEY    @"AllowUpdates"
#define UB_MARK   @"# ios6-revival: iOS updates blocked"

extern char **environ;

// The switch is off (updates blocked) unless Settings saved it on.
static BOOL UBAllowed(void) {
    id v = [[NSDictionary dictionaryWithContentsOfFile:UB_PREFS] objectForKey:UB_KEY];
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

static NSArray *UBBlockLines(void) {
    return [NSArray arrayWithObjects:[NSString stringWithFormat:@"127.0.0.1\tmesu.apple.com\t%@", UB_MARK],
                                     [NSString stringWithFormat:@"::1\tmesu.apple.com\t%@", UB_MARK], nil];
}

// The hosts file without our lines, every other line kept exactly as it was.
static NSMutableArray *UBOtherLines(NSString *hosts) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [hosts componentsSeparatedByString:@"\n"])
        if ([line rangeOfString:UB_MARK].location == NSNotFound) [out addObject:line];
    while ([out count] && [[out lastObject] length] == 0) [out removeLastObject];
    return out;
}

// Atomic replace, root:wheel 0644 like the original; nothing is written when nothing changes.
static BOOL UBWriteHosts(NSString *old, NSString *new) {
    if ([old isEqualToString:new]) return NO;
    NSString *tmp = [UB_HOSTS stringByAppendingString:@".revupdateblock-tmp"];
    if (![new writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:NULL]) {
        fprintf(stderr, "revupdateblock: cannot write %s\n", [tmp UTF8String]);
        return NO;
    }
    chown([tmp fileSystemRepresentation], 0, 0);
    chmod([tmp fileSystemRepresentation], 0644);
    if (rename([tmp fileSystemRepresentation], [UB_HOSTS fileSystemRepresentation]) != 0) {
        unlink([tmp fileSystemRepresentation]);
        fprintf(stderr, "revupdateblock: cannot replace %s\n", [UB_HOSTS UTF8String]);
        return NO;
    }
    return YES;
}

// mDNSResponder answers name lookups and keeps its own cache; HUP makes it drop the cache and reread hosts.
static void UBFlushDNS(void) {
    pid_t pid;
    char *args[] = { "killall", "-HUP", "mDNSResponder", NULL };
    if (posix_spawnp(&pid, "killall", NULL, NULL, args, environ) == 0) waitpid(pid, NULL, 0);
}

static void UBPrintLookup(void) {
    struct addrinfo hints = { 0 }, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    int err = getaddrinfo("mesu.apple.com", "443", &hints, &res);
    if (err) { printf("mesu.apple.com: lookup failed (%s)\n", gai_strerror(err)); return; }
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        char ip[INET6_ADDRSTRLEN] = "";
        void *addr = a->ai_family == AF_INET6 ? (void *)&((struct sockaddr_in6 *)a->ai_addr)->sin6_addr
                                              : (void *)&((struct sockaddr_in *)a->ai_addr)->sin_addr;
        inet_ntop(a->ai_family, addr, ip, sizeof(ip));
        printf("mesu.apple.com -> %s\n", ip);
    }
    freeaddrinfo(res);
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *cmd = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
    NSString *hosts = [NSString stringWithContentsOfFile:UB_HOSTS encoding:NSUTF8StringEncoding error:NULL];
    if (!hosts) {
        fprintf(stderr, "revupdateblock: cannot read %s\n", [UB_HOSTS UTF8String]);
        [pool drain];
        return 1;
    }

    if ([cmd isEqualToString:@"status"]) {
        printf("switch: %s\n", UBAllowed() ? "updates allowed" : "updates blocked");
        for (NSString *line in [hosts componentsSeparatedByString:@"\n"])
            if ([line rangeOfString:UB_MARK].location != NSNotFound) printf("hosts: %s\n", [line UTF8String]);
        UBPrintLookup();
        [pool drain];
        return 0;
    }

    BOOL block = ![cmd isEqualToString:@"remove"] && !UBAllowed();
    NSMutableArray *lines = UBOtherLines(hosts);
    if (block) [lines addObjectsFromArray:UBBlockLines()];
    NSString *updated = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    if (UBWriteHosts(hosts, updated)) {
        UBFlushDNS();
        NSLog(@"revupdateblock: iOS updates %@", block ? @"blocked" : @"allowed");
    }
    [pool drain];
    return 0;
}
