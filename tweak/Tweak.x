// ios6-revival: redirect the App Store YouTube app's dead Google API hosts to steve's server.
// Original code (not derived from TubeRepair's source). Manual retain/release (no ARC), iOS 6 safe.
#import <Foundation/Foundation.h>
#include <pthread.h>

#ifndef IR_PREFS_PATH
#define IR_PREFS_PATH @"/var/mobile/Library/Preferences/com.stevenjc.ios6revival.youtube.plist"
#endif
#define IR_DEFAULT_SERVER @"http://127.0.0.1:8080"
#define IR_CACHE_SECONDS 2.0

// ---- settings (re-read from the plist at most every IR_CACHE_SECONDS) ----

static NSString *gServerBase = nil;     // normalised, no trailing slash
static BOOL gDowngradeHTTPS = YES;
static CFAbsoluteTime gLoadedAt = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static NSSet *gDeadHosts = nil;

static BOOL IRIsDeadHost(NSString *host) { return host && [gDeadHosts containsObject:host]; }

// Splits "scheme://[host][:port]rest". Returns NO for anything that is not plain http(s) without userinfo/IPv6.
static BOOL IRParse(NSString *s, NSString **scheme, NSString **host, NSString **port, NSUInteger *restStart) {
    if (![s isKindOfClass:[NSString class]] || [s length] < 8) return NO;
    NSRange sep = [s rangeOfString:@"://"];
    if (sep.location == NSNotFound || sep.location > 5) return NO;
    NSString *sc = [[s substringToIndex:sep.location] lowercaseString];
    if (![sc isEqualToString:@"http"] && ![sc isEqualToString:@"https"]) return NO;
    NSUInteger start = sep.location + 3, len = [s length], end = start;
    while (end < len) {
        unichar c = [s characterAtIndex:end];
        if (c == '/' || c == '?' || c == '#') break;
        end++;
    }
    NSString *auth = [s substringWithRange:NSMakeRange(start, end - start)];
    if ([auth length] == 0 || [auth rangeOfString:@"@"].location != NSNotFound || [auth hasPrefix:@"["]) return NO;
    NSRange colon = [auth rangeOfString:@":"];
    NSString *h = (colon.location == NSNotFound) ? auth : [auth substringToIndex:colon.location];
    NSString *p = (colon.location == NSNotFound) ? @"" : [auth substringFromIndex:colon.location + 1];
    if ([h length] == 0) return NO;
    if (scheme) *scheme = sc;
    if (host) *host = [h lowercaseString];
    if (port) *port = p;
    if (restStart) *restStart = end;
    return YES;
}

// A usable server base ("http://host[:port][/prefix]") or nil.
static NSString *IRNormaliseServer(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *s = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s length] == 0 || [s length] > 512) return nil;
    if ([s rangeOfString:@"://"].location == NSNotFound) s = [@"http://" stringByAppendingString:s];
    while ([s hasSuffix:@"/"]) s = [s substringToIndex:[s length] - 1];
    if ([s rangeOfString:@"?"].location != NSNotFound || [s rangeOfString:@"#"].location != NSNotFound) return nil;
    NSString *host = nil;
    if (!IRParse(s, NULL, &host, NULL, NULL)) return nil;
    if (IRIsDeadHost(host)) return nil;              // would redirect to itself / a dead host
    CFURLRef u = CFURLCreateWithString(NULL, (CFStringRef)s, NULL);   // avoids our own NSURL hooks
    if (!u) return nil;
    CFRelease(u);
    return s;
}

// Returns the current server base (autoreleased copy) and downgrade flag; reloads the plist when stale.
static NSString *IRCurrentSettings(BOOL *downgrade) {
    NSString *result;
    pthread_mutex_lock(&gLock);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!gServerBase || now < gLoadedAt || now - gLoadedAt >= IR_CACHE_SECONDS) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:IR_PREFS_PATH];
        if (![d isKindOfClass:[NSDictionary class]]) d = nil;
        NSString *base = IRNormaliseServer([d objectForKey:@"ServerURL"]);
        if (!base) base = IR_DEFAULT_SERVER;
        id dg = [d objectForKey:@"DowngradeHTTPS"];
        BOOL dgv = [dg respondsToSelector:@selector(boolValue)] ? [dg boolValue] : YES;
        if (!gServerBase || ![gServerBase isEqualToString:base]) {
            NSLog(@"[IOS6RevivalYT] server = %@", base);
        }
        [gServerBase release];
        gServerBase = [base copy];
        gDowngradeHTTPS = dgv;
        gLoadedAt = now;
    }
    result = [[gServerBase copy] autorelease];
    if (downgrade) *downgrade = gDowngradeHTTPS;
    pthread_mutex_unlock(&gLock);
    return result;
}

// ---- rewriting ----

static BOOL IRIsImageHost(NSString *h) {
    return [h isEqualToString:@"ytimg.com"] || [h hasSuffix:@".ytimg.com"] || [h isEqualToString:@"img.youtube.com"];
}

static NSString *IRRewriteString(NSString *s) {
    NSString *scheme = nil, *host = nil, *port = nil;
    NSUInteger restStart = 0;
    if (!IRParse(s, &scheme, &host, &port, &restStart)) return s;
    NSString *rest = [s substringFromIndex:restStart];

    BOOL dead = IRIsDeadHost(host);
    BOOL keepHostDowngrade = NO;   // live hosts the iPhone 4 cannot reach over TLS: just drop to http
    if ([host isEqualToString:@"www.google.com"]) {
        if ([rest hasPrefix:@"/complete/"]) { dead = NO; keepHostDowngrade = YES; }   // search suggestions are still alive
    } else if (IRIsImageHost(host)) {
        keepHostDowngrade = YES;                                                        // thumbnails
    }

    if (dead) {
        NSString *base = IRCurrentSettings(NULL);
        if ([rest length] && ([rest hasPrefix:@"?"] || [rest hasPrefix:@"#"])) rest = [@"/" stringByAppendingString:rest];
        NSString *out = [base stringByAppendingString:rest];
        NSRange q = [rest rangeOfString:@"?"];
        NSLog(@"[IOS6RevivalYT] %@ -> %@%@", host, base, (q.location == NSNotFound) ? rest : [rest substringToIndex:q.location]);
        return out;
    }
    if (keepHostDowngrade && [scheme isEqualToString:@"https"]) {
        BOOL downgrade = YES;
        IRCurrentSettings(&downgrade);
        if (!downgrade) return s;
        NSString *p = ([port length] && ![port isEqualToString:@"443"]) ? [@":" stringByAppendingString:port] : @"";
        return [NSString stringWithFormat:@"http://%@%@%@", host, p, rest];
    }
    return s;
}

static NSURL *IRRewriteURL(NSURL *u) {
    if (![u isKindOfClass:[NSURL class]]) return u;
    NSString *abs = [u absoluteString];
    NSString *n = IRRewriteString(abs);
    if (n == abs || [n isEqualToString:abs]) return u;
    CFURLRef r = CFURLCreateWithString(NULL, (CFStringRef)n, NULL);
    return r ? [(NSURL *)r autorelease] : u;
}

static id IRRewriteObject(id o) {
    if ([o isKindOfClass:[NSString class]]) return IRRewriteString(o);
    if ([o isKindOfClass:[NSURL class]]) return IRRewriteURL(o);
    return o;
}

// ---- hooks ----

%hook NSURL
+ (id)URLWithString:(NSString *)string { return %orig(IRRewriteString(string)); }
+ (id)URLWithString:(NSString *)string relativeToURL:(NSURL *)base { return %orig(IRRewriteString(string), base); }
%end

%hook NSURLRequest
- (id)initWithURL:(NSURL *)url { return %orig(IRRewriteURL(url)); }
- (id)initWithURL:(NSURL *)url cachePolicy:(NSUInteger)policy timeoutInterval:(NSTimeInterval)timeout {
    return %orig(IRRewriteURL(url), policy, timeout);
}
%end

%hook NSMutableURLRequest
- (void)setURL:(NSURL *)url { %orig(IRRewriteURL(url)); }
%end

// The app's own settings object hands out the API base; point it at the server too.
%hook YTSettings
- (id)GDataURLHost { return IRRewriteObject(%orig); }
- (id)apiaryURLHost { return IRRewriteObject(%orig); }
%end

%ctor {
    gDeadHosts = [[NSSet alloc] initWithObjects:
        @"gdata.youtube.com", @"uploads.gdata.youtube.com", @"www.google.com", @"accounts.google.com",
        @"www.googleapis.com", @"youtube.googleapis.com", @"oauth2.googleapis.com", nil];
    IRCurrentSettings(NULL);
    %init;
}
