// ios6-revival App Store logger: log file, redaction and bag capture. Manual retain/release (no ARC).
#import "ASLog.h"
#include <sys/time.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

static NSObject *asLock;
static NSRegularExpression *asSecretRe;   // ?key=value / &key=value with a secret-looking key

static void ASSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        asLock = [[NSObject alloc] init];
        // Keeps the key, blanks the value. appleid/email/user/account/dsperson added: no account ids.
        asSecretRe = [[NSRegularExpression alloc]
            initWithPattern:@"([?&;][^=&#;\\s]*(?:pass|token|guid|dsid|kbsync|sig|cookie|auth|appleid|email|user|account|dsperson)[^=&#;\\s]*=)[^&#;\\s]*"
                    options:NSRegularExpressionCaseInsensitive error:NULL];
    });
}

NSString *ASScrubText(NSString *s) {
    if (!s) return @"-";
    ASSetup();
    return [asSecretRe stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, [s length])
                                           withTemplate:@"$1<redacted>"];
}

// Both processes append here (one may run as root), so the file is left writable by all.
// O_APPEND keeps each line whole when itunesstored and the App Store write at the same moment.
static void ASWriteLine(NSData *bytes) {
    const char *path = [AS_LOG_PATH fileSystemRepresentation];
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd < 0) return;
    fchmod(fd, 0666);
    struct stat sb;
    if (fstat(fd, &sb) == 0 && sb.st_size > AS_LOG_CAP) {
        ftruncate(fd, 0);
        const char *note = "--- log passed 1 MB, emptied ---\n";
        write(fd, note, strlen(note));
    }
    write(fd, [bytes bytes], [bytes length]);
    close(fd);
}

void ASLog(NSString *tag, NSString *fmt, ...) {
    ASSetup();
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; time_t secs = tv.tv_sec; localtime_r(&secs, &tm);
    char stamp[32]; strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tm);
    NSString *line = [NSString stringWithFormat:@"%s.%03d %@[%d] %@ %@\n", stamp, (int)(tv.tv_usec / 1000),
                      [[NSProcessInfo processInfo] processName], getpid(), tag, body];
    [body release];
    @synchronized (asLock) { ASWriteLine([line dataUsingEncoding:NSUTF8StringEncoding]); }
}

NSString *ASSafeURL(NSURL *url) {
    if (!url) return @"-";
    NSString *s = [url absoluteString];
    if ([url user] || [url password]) {   // rebuild without the user:password part
        NSString *port = [url port] ? [NSString stringWithFormat:@":%@", [url port]] : @"";
        NSString *query = [url query] ? [@"?" stringByAppendingString:[url query]] : @"";
        s = [NSString stringWithFormat:@"%@://%@%@%@%@", [url scheme], [url host], port, [url path], query];
    }
    NSRange hash = [s rangeOfString:@"#"];
    if (hash.location != NSNotFound) s = [s substringToIndex:hash.location];
    return ASScrubText(s);
}

NSString *ASErrorText(NSError *err) {
    if (!err) return @"nil";
    NSError *under = [[err userInfo] objectForKey:NSUnderlyingErrorKey];
    NSString *u = [under isKindOfClass:[NSError class]]
        ? [NSString stringWithFormat:@" under=%@/%ld '%@'", [under domain], (long)[under code], ASScrubText([under localizedDescription])]
        : @"";
    return [NSString stringWithFormat:@"%@/%ld '%@'%@", [err domain], (long)[err code], ASScrubText([err localizedDescription]), u];
}

NSString *ASResponseText(NSURLResponse *resp) {
    if (!resp) return @"no-response";
    long status = -1;
    NSString *type = [resp MIMEType];
    if ([resp respondsToSelector:@selector(statusCode)]) {   // no class reference: the 9.3 stub links it from the wrong library for iOS 6
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        status = (long)[h statusCode];
        for (NSString *k in [h allHeaderFields])   // header names are not case-normalised on iOS 6
            if ([k caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) type = [[h allHeaderFields] objectForKey:k];
    }
    return [NSString stringWithFormat:@"status=%ld type='%@' expected=%lld", status, type ?: @"-",
            (long long)[resp expectedContentLength]];
}

BOOL ASIsBagURL(NSURL *url) {
    return [[url lastPathComponent] caseInsensitiveCompare:@"bag.xml"] == NSOrderedSame;
}

NSString *ASSaveBag(NSData *body, NSURL *url) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:AS_CAPTURE_DIR]) {
        [fm createDirectoryAtPath:AS_CAPTURE_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
        chmod([AS_CAPTURE_DIR fileSystemRepresentation], 0777);
    }
    struct timeval tv; gettimeofday(&tv, NULL);
    NSString *name = [NSString stringWithFormat:@"%@-%ld%03d-%@-bag.xml", [[NSProcessInfo processInfo] processName],
                      (long)tv.tv_sec, (int)(tv.tv_usec / 1000), [url host] ?: @"nohost"];
    NSString *path = [AS_CAPTURE_DIR stringByAppendingPathComponent:name];
    if (![body writeToFile:path atomically:NO]) return @"(write failed)";
    chmod([path fileSystemRepresentation], 0666);
    return name;
}
