// ios6-revival App Store logger: shared log helpers. Phase 1 = observe only, never change a request.
#import <Foundation/Foundation.h>

#define AS_DIR         @"/var/mobile/Library/ios6revival"
#define AS_LOG_PATH    AS_DIR @"/appstore-log.txt"
#define AS_CAPTURE_DIR AS_DIR @"/appstore-capture"
#define AS_LOG_CAP     (1024 * 1024)   // bytes; past this the log is emptied and restarted
#define AS_BAG_KEEP    5               // saved bags kept in AS_CAPTURE_DIR; older ones are deleted

// One line: "<time> <process>[pid] <tag> <text>".
void ASLog(NSString *tag, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);

// URL without user/password/fragment, query values blanked for secret-looking keys.
NSString *ASSafeURL(NSURL *url);
// Any text with secret-looking ?key=value pairs blanked.
NSString *ASScrubText(NSString *s);
// "domain/code 'description' under=domain/code", scrubbed the same way.
NSString *ASErrorText(NSError *err);
// Status, Content-Type, expected length of a response ("-" for non-HTTP).
NSString *ASResponseText(NSURLResponse *resp);
// True for .../bag.xml (the only bodies ever saved).
BOOL ASIsBagURL(NSURL *url);
// Writes a bag body to AS_CAPTURE_DIR, keeping only the newest AS_BAG_KEEP; returns the file name.
NSString *ASSaveBag(NSData *body, NSURL *url);
