// revnotify: show a banner on the iPhone from the command line.
//   revnotify "Title" "Message" [bundle id for the icon]
// Writes the message into the spool folder and pokes SpringBoard (ios6-revival Notify tweak).
#import <Foundation/Foundation.h>
#include <notify.h>
#include <stdio.h>
#include <unistd.h>
#import "RNShared.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: revnotify \"Title\" \"Message\" [bundle id for the icon]\n");
        return 2;
    }
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *owner = @{ NSFileOwnerAccountID: @(RN_MOBILE_UID), NSFileGroupOwnerAccountID: @(RN_MOBILE_UID) };
    if (![fm fileExistsAtPath:RN_SPOOL_DIR]) {
        // SpringBoard runs as mobile and must be able to delete the files it has shown.
        NSString *parent = [RN_SPOOL_DIR stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:RN_SPOOL_DIR withIntermediateDirectories:YES attributes:owner error:NULL];
        [fm setAttributes:owner ofItemAtPath:parent error:NULL];
        [fm setAttributes:owner ofItemAtPath:RN_SPOOL_DIR error:NULL];
    }
    NSMutableDictionary *msg = [NSMutableDictionary dictionary];
    [msg setObject:[NSString stringWithUTF8String:argv[1]] forKey:RN_KEY_TITLE];
    [msg setObject:[NSString stringWithUTF8String:argv[2]] forKey:RN_KEY_MESSAGE];
    if (argc > 3) [msg setObject:[NSString stringWithUTF8String:argv[3]] forKey:RN_KEY_SECTION];

    NSString *name = [NSString stringWithFormat:@"%.0f-%d.plist", [[NSDate date] timeIntervalSince1970] * 1000, getpid()];
    NSString *path = [RN_SPOOL_DIR stringByAppendingPathComponent:name];
    int rc = 0;
    if ([msg writeToFile:path atomically:YES]) {
        [fm setAttributes:owner ofItemAtPath:path error:NULL];
        notify_post(RN_DARWIN_NAME);
    } else {
        fprintf(stderr, "revnotify: could not write %s\n", [path UTF8String]);
        rc = 1;
    }
    [pool drain];
    return rc;
}
