// ios6-revival App Store: logs every store request and how it ends (phase 1), drops the EV-certificate demand (phase 2)
// and accepts a verified-https bag whose signature check fails (phase 3, ASBag.m).
// itunesstored + AppStore, iOS 6. Manual retain/release (no ARC). Selectors checked at runtime on the 6.1.3 phone.
// Never logs request bodies, cookies or headers other than X-Apple-Store-Front; secret query values are blanked.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <objc/runtime.h>
#include <substrate.h>
#import "ASLog.h"
#import "ASHooks.h"

@interface NSURLConnection (ASPrivate)
- (NSURLRequest *)currentRequest;
@end
@interface ISOperation : NSOperation
- (NSError *)error;
- (BOOL)success;
@end
@interface ISURLOperation : ISOperation
- (id)requestProperties;
@end
@interface ISStoreURLOperation : ISURLOperation
@end
@interface ISLoadURLBagOperation : ISOperation
@end
@interface ISURLBag : NSObject
@end
@interface ISCertificate : NSObject
@end
@interface SSURLBag : NSObject
@end

static char asStateKey;   // associated NSMutableDictionary on each NSURLConnection

static NSMutableDictionary *ASState(NSURLConnection *c) {
    NSMutableDictionary *d = objc_getAssociatedObject(c, &asStateKey);
    if (!d) {
        d = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(c, &asStateKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return d;
}

static NSURL *ASConnURL(NSURLConnection *c) {
    return [c respondsToSelector:@selector(currentRequest)] ? [[c currentRequest] URL] : nil;
}

static NSString *ASBagKey(id op) {
    id props = [op respondsToSelector:@selector(requestProperties)] ? [op requestProperties] : nil;
    return [props respondsToSelector:@selector(URLBagKey)] ? [props performSelector:@selector(URLBagKey)] : nil;
}

// Read-only look at the server's certificate chain: what iOS itself thinks of it.
static void ASLogTrust(NSString *tag, NSURLAuthenticationChallenge *ch) {
    NSURLProtectionSpace *ps = [ch protectionSpace];
    NSString *method = [ps authenticationMethod];
    if (![method isEqualToString:@"NSURLAuthenticationMethodServerTrust"]) {   // literal: the constant is not exported on iOS 6
        ASLog(tag, @"host=%@ method=%@ (not server trust; not inspected)", [ps host], method);
        return;
    }
    SecTrustRef trust = [ps serverTrust];
    SecTrustResultType result = 0;
    OSStatus st = trust ? SecTrustEvaluate(trust, &result) : -1;
    CFIndex n = trust ? SecTrustGetCertificateCount(trust) : 0;
    NSMutableArray *names = [NSMutableArray array];
    for (CFIndex i = 0; i < n; i++) {
        CFStringRef s = SecCertificateCopySubjectSummary(SecTrustGetCertificateAtIndex(trust, i));
        [names addObject:s ? [(NSString *)s autorelease] : @"?"];
    }
    // result: 1 proceed, 4 unspecified (both = trusted), 5 recoverable failure, 6 fatal, 3 deny
    ASLog(tag, @"host=%@ servertrust eval=%d result=%d chain=[%@]", [ps host], (int)st, (int)result,
          [names componentsJoinedByString:@" < "]);
}

// What the store code decides about a challenge: hooked on the first challenge sender class seen.
// Logs only the decision and host, never the credential.
static IMP asOrigUse, asOrigContinue, asOrigCancel, asOrigDefault, asOrigReject;

// The decision is also kept on the connection (the sender): the bag fallback needs performDefaultHandling.
static void ASDecision(id conn, NSString *what, NSURLAuthenticationChallenge *ch) {
    // objc_getClass: a class ref would bind NSURLConnection to CFNetwork (9.3 stub); iOS 6 has it in Foundation.
    NSMutableDictionary *st = [conn isKindOfClass:objc_getClass("NSURLConnection")] ? ASState(conn) : nil;
    if (![st objectForKey:@"trust"] || ![what isEqualToString:@"performDefaultHandling"]) [st setObject:what forKey:@"trust"];
    ASLog(@"DECIDE", @"%@ host=%@ method=%@", what, [[ch protectionSpace] host], [[ch protectionSpace] authenticationMethod]);
}
static void asUse(id s, SEL c, NSURLCredential *cred, NSURLAuthenticationChallenge *ch) {
    ASDecision(s, @"useCredential", ch); ((void (*)(id, SEL, id, id))asOrigUse)(s, c, cred, ch);
}
static void asContinue(id s, SEL c, NSURLAuthenticationChallenge *ch) {
    ASDecision(s, @"continueWithoutCredential", ch); ((void (*)(id, SEL, id))asOrigContinue)(s, c, ch);
}
static void asCancel(id s, SEL c, NSURLAuthenticationChallenge *ch) {
    ASDecision(s, @"cancel", ch); ((void (*)(id, SEL, id))asOrigCancel)(s, c, ch);
}
static void asDefault(id s, SEL c, NSURLAuthenticationChallenge *ch) {
    ASDecision(s, @"performDefaultHandling", ch); ((void (*)(id, SEL, id))asOrigDefault)(s, c, ch);
}
static void asReject(id s, SEL c, NSURLAuthenticationChallenge *ch) {
    ASDecision(s, @"rejectProtectionSpace", ch); ((void (*)(id, SEL, id))asOrigReject)(s, c, ch);
}

static void ASWatchSender(id sender) {
    static Class watched;
    if (!sender) return;
    @synchronized (@"ASWatchSender") {
        Class cls = [sender class];
        if (watched) {
            if (cls != watched) ASLog(@"DECIDE", @"second sender class %@ not watched", NSStringFromClass(cls));
            return;
        }
        watched = cls;
        struct { SEL sel; IMP fn; IMP *orig; } h[] = {
            { @selector(useCredential:forAuthenticationChallenge:), (IMP)asUse, &asOrigUse },
            { @selector(continueWithoutCredentialForAuthenticationChallenge:), (IMP)asContinue, &asOrigContinue },
            { @selector(cancelAuthenticationChallenge:), (IMP)asCancel, &asOrigCancel },
            { @selector(performDefaultHandlingForAuthenticationChallenge:), (IMP)asDefault, &asOrigDefault },
            { @selector(rejectProtectionSpaceAndContinueWithChallenge:), (IMP)asReject, &asOrigReject },
        };
        for (unsigned i = 0; i < sizeof h / sizeof h[0]; i++)
            if (class_getInstanceMethod(cls, h[i].sel)) MSHookMessageEx(cls, h[i].sel, h[i].fn, h[i].orig);
        ASLog(@"DECIDE", @"watching %@", NSStringFromClass(cls));
    }
}

// ---- Every NSURLConnection in the process ----

%hook NSURLConnection
- (id)_initWithRequest:(NSURLRequest *)req delegate:(id)delegate usesCache:(BOOL)cache maxContentLength:(long long)max startImmediately:(BOOL)start connectionProperties:(id)props {
    ASLog(@"REQ", @"%@ %@ sf=%@ delegate=%@", [req HTTPMethod], ASSafeURL([req URL]),
          [req valueForHTTPHeaderField:@"X-Apple-Store-Front"] ?: @"-", delegate ? NSStringFromClass([delegate class]) : @"nil");
    ASWatchDelegate(delegate);
    return %orig;
}

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)req returningResponse:(NSURLResponse **)resp error:(NSError **)err {
    NSURLResponse *r = nil; NSError *e = nil;
    ASLog(@"SYNCREQ", @"%@ %@ sf=%@", [req HTTPMethod], ASSafeURL([req URL]),
          [req valueForHTTPHeaderField:@"X-Apple-Store-Front"] ?: @"-");
    NSData *data = %orig(req, &r, &e);
    ASLog(@"SYNCEND", @"%@ %@ bytes=%lu err=%@", ASSafeURL([req URL]), ASResponseText(r), (unsigned long)[data length], ASErrorText(e));
    if (data && ASIsBagURL([req URL])) ASLog(@"BAGSAVE", @"%@", ASSaveBag(data, [req URL]));
    if (resp) *resp = r;
    if (err) *err = e;
    return data;
}
%end

// Connection callbacks. Both the Foundation proxy and ISURLOperation (which iOS 6 calls directly)
// feed these; ASOnce drops the second sighting of the same callback object.
static BOOL ASOnce(NSURLConnection *c, NSString *kind, id obj) {
    NSMutableDictionary *st = ASState(c);
    NSValue *v = [NSValue valueWithPointer:obj];
    if ([[st objectForKey:kind] isEqual:v]) return NO;
    [st setObject:v forKey:kind];
    return YES;
}

void ASOnResponse(NSURLConnection *c, NSURLResponse *resp) {
    if (!ASOnce(c, @"resp", resp)) return;
    NSURL *url = [resp URL] ?: ASConnURL(c);
    ASLog(@"RESP", @"%@ %@", ASSafeURL(url), ASResponseText(resp));
    NSMutableDictionary *st = ASState(c);
    [st setObject:[NSNumber numberWithUnsignedLongLong:0] forKey:@"bytes"];
    if (url) [st setObject:url forKey:@"url"];
    // Body kept for bag.xml (saved) and any xml (the bag fallback looks for a signed bag in it).
    if (ASIsBagURL(url) || [[resp MIMEType] rangeOfString:@"xml"].location != NSNotFound) [st setObject:[NSMutableData data] forKey:@"bag"];
    else [st removeObjectForKey:@"bag"];
}

void ASOnData(NSURLConnection *c, NSData *data) {
    if (!ASOnce(c, @"data", data)) return;
    NSMutableDictionary *st = ASState(c);
    unsigned long long n = [[st objectForKey:@"bytes"] unsignedLongLongValue] + [data length];
    [st setObject:[NSNumber numberWithUnsignedLongLong:n] forKey:@"bytes"];
    if (n < 4 * 1024 * 1024) [[st objectForKey:@"bag"] appendData:data];
    else [st removeObjectForKey:@"bag"];
}

void ASOnFinish(NSURLConnection *c) {
    if (!ASOnce(c, @"end", c)) return;
    NSMutableDictionary *st = ASState(c);
    ASLog(@"DONE", @"%@ bytes=%llu", ASSafeURL(ASConnURL(c)), [[st objectForKey:@"bytes"] unsignedLongLongValue]);
    NSData *bag = [st objectForKey:@"bag"];
    NSURL *url = [st objectForKey:@"url"] ?: ASConnURL(c);
    if (bag && ASIsBagURL(url)) ASLog(@"BAGSAVE", @"%@ (%lu bytes)", ASSaveBag(bag, ASConnURL(c)), (unsigned long)[bag length]);
    if (bag) ASBagNoteFetch(url, [st objectForKey:@"trust"], bag);
    if (bag) ASAuthNoteResponse(url, bag);
    [st removeObjectForKey:@"bag"];
}

void ASOnFail(NSURLConnection *c, NSError *err) {
    if (!ASOnce(c, @"end", c)) return;
    ASLog(@"FAIL", @"%@ bytes=%llu err=%@", ASSafeURL(ASConnURL(c)),
          [[ASState(c) objectForKey:@"bytes"] unsignedLongLongValue], ASErrorText(err));
}

static void ASOnRedirect(NSURLConnection *c, NSURLRequest *req, NSURLResponse *redir, NSURLRequest *out) {
    if (!redir || !ASOnce(c, @"redir", redir)) return;
    ASLog(@"REDIR", @"%@ -> %@ (%@) followed=%@", ASSafeURL([redir URL]), ASSafeURL([req URL]),
          ASResponseText(redir), out ? ASSafeURL([out URL]) : @"no");
}

%hook NSURLConnectionDelegateProxy
- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)resp { ASOnResponse(c, resp); %orig; }
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data { ASOnData(c, data); %orig; }
- (void)connectionDidFinishLoading:(NSURLConnection *)c { ASOnFinish(c); %orig; }
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)err { ASOnFail(c, err); %orig; }

- (NSURLRequest *)connection:(NSURLConnection *)c willSendRequest:(NSURLRequest *)req redirectResponse:(NSURLResponse *)redir {
    NSURLRequest *out = %orig;
    ASOnRedirect(c, req, redir, out);
    return out;
}

- (void)connection:(NSURLConnection *)c didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)ch {
    ASLogTrust(@"CHAL", ch);
    %orig;
}
%end

// ---- iTunesStore.framework: operations, bag and signature checks ----

%hook ISURLOperation
- (BOOL)_runRequestWithURL:(NSURL *)url {
    ASLog(@"ISRUN", @"%@ start %@ bagKey=%@", NSStringFromClass([self class]), ASSafeURL(url), ASBagKey(self) ?: @"-");
    BOOL ok = %orig;
    ASLog(@"ISRUN", @"%@ end ok=%d %@", NSStringFromClass([self class]), ok, ASSafeURL(url));
    return ok;
}

- (void)connection:(NSURLConnection *)c willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)ch {
    ASLogTrust(@"ISCHAL", ch);
    id props = [self requestProperties];
    ASLog(@"ISCHAL", @"requiresEV=%@ sender=%@",
          [props respondsToSelector:@selector(requiresExtendedValidationCertificates)]
              ? ([props performSelector:@selector(requiresExtendedValidationCertificates)] ? @"YES" : @"NO") : @"?",
          NSStringFromClass([[ch sender] class]));
    ASWatchSender([ch sender]);
    %orig;
}

- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)resp { ASOnResponse(c, resp); %orig; }
- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data { ASOnData(c, data); %orig; }
- (void)connectionDidFinishLoading:(NSURLConnection *)c { ASOnFinish(c); %orig; }
- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)err { ASOnFail(c, err); %orig; }

- (NSURLRequest *)connection:(NSURLConnection *)c willSendRequest:(NSURLRequest *)req redirectResponse:(NSURLResponse *)redir {
    NSURLRequest *out = %orig;
    ASOnRedirect(c, req, redir, out);
    return out;
}
%end

%hook ISStoreURLOperation
- (id)_urlFromURLBagForRequestProperties:(id)props inBagContext:(id)ctx {
    id url = %orig;
    NSString *key = [props respondsToSelector:@selector(URLBagKey)] ? [props performSelector:@selector(URLBagKey)] : nil;
    ASLog(@"BAGURL", @"key=%@ -> %@", key ?: @"-", [url isKindOfClass:[NSURL class]] ? ASSafeURL(url) : (url ? @"(non-URL)" : @"nil"));
    return url;
}
%end

%hook ISOperation
- (void)setError:(NSError *)err {
    if (err) ASLog(@"OPERR", @"%@ %@", NSStringFromClass([self class]), ASErrorText(err));
    %orig;
}

- (BOOL)loadURLBagWithContext:(id)ctx returningError:(NSError **)err {
    NSError *e = nil;
    BOOL ok = %orig(ctx, &e);
    ASLog(@"BAGCTX", @"%@ ok=%d err=%@", NSStringFromClass([self class]), ok, ASErrorText(e));
    if (err) *err = e;
    return ok;
}
%end

%hook ISLoadURLBagOperation
- (void)_loadURLBagFromURL:(NSURL *)url {
    ASLog(@"BAGLOAD", @"start %@", ASSafeURL(url));
    %orig;
    ASLog(@"BAGLOAD", @"end %@ success=%d err=%@", ASSafeURL(url), [self success], ASErrorText([self error]));
}

- (void)run {
    %orig;
    ASLog(@"BAGOP", @"run finished success=%d err=%@", [self success], ASErrorText([self error]));
}
%end

%hook ISURLBag
+ (BOOL)_allowUnsignedBags {
    BOOL r = %orig;
    ASLog(@"BAGUNSIGNED", @"allowUnsignedBags=%d", r);
    return r;
}

- (BOOL)loadFromDictionary:(NSDictionary *)dict returningError:(NSError **)err {
    NSError *e = nil;
    BOOL ok = %orig(dict, &e);
    ASLog(@"BAGDICT", @"ok=%d keys=%lu err=%@", ok, (unsigned long)[dict count], ASErrorText(e));
    if (err) *err = e;
    return ok;
}

- (BOOL)_loadFromSignedDictionary:(NSDictionary *)dict returningError:(NSError **)err {
    NSError *e = nil;
    BOOL ok = %orig(dict, &e);
    NSArray *keys = [dict isKindOfClass:[NSDictionary class]] ? [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)] : nil;
    ASLog(@"BAGSIGNED", @"ok=%d topkeys=[%@] err=%@", ok, [keys componentsJoinedByString:@","], ASErrorText(e));
    if (ok) ASBagCheckSignedPath(self, dict);
    else if (ASBagAcceptUnsigned(self, dict, e)) { ok = YES; e = nil; }   // phase 3 fallback, see ASBag.m
    if (err) *err = e;
    return ok;
}
%end

%hook ISCertificate
- (BOOL)checkData:(NSData *)data againstSignature:(NSData *)sig {
    BOOL ok = %orig;
    ASLog(@"CERTCHECK", @"againstSignature ok=%d data=%lu sig=%lu", ok, (unsigned long)[data length], (unsigned long)[sig length]);
    return ok;
}

- (BOOL)checkData:(NSData *)data againstAppleSignature:(NSData *)sig {
    BOOL ok = %orig;
    ASLog(@"CERTCHECK", @"againstAppleSignature ok=%d data=%lu sig=%lu", ok, (unsigned long)[data length], (unsigned long)[sig length]);
    return ok;
}
%end

// App side: bag lookups the app asks itunesstored for.
%hook SSURLBag
- (void)_drainPendingLookupsWithError:(NSError *)err {
    if (err) ASLog(@"SSBAG", @"lookups failed err=%@", ASErrorText(err));
    %orig;
}
%end

// ---- Phase 2 fix: drop the EV requirement ----
// Apple's store certs now chain to DigiCert Global Root G2, which iOS 6 never treats as EV, so the store
// cancelled every https request (-1012) although iOS trusted the chain. Only the EV demand is removed;
// the normal iOS trust check still runs and still rejects untrusted certificates.
static int asEVLogs;   // first few calls only, the getter runs on every request

%hook SSURLRequestProperties
- (BOOL)requiresExtendedValidationCertificates {
    BOOL was = %orig;
    if (asEVLogs < 5) { asEVLogs++; ASLog(@"EVOFF", @"requiresEV was=%d -> 0", was); }
    return NO;
}
%end

%hook SSMutableURLRequestProperties
- (void)setRequiresExtendedValidationCertificates:(BOOL)ev {
    if (ev && asEVLogs < 5) { asEVLogs++; ASLog(@"EVOFF", @"setRequiresEV:1 -> 0"); }
    %orig(NO);
}
%end

%hook ISURLOperation
- (BOOL)_isTrustExtendedValidation:(SecTrustRef)trust {
    BOOL ev = %orig;   // observed only, not changed
    ASLog(@"EVCHECK", @"%@ isTrustEV=%d", NSStringFromClass([self class]), ev);
    return ev;
}
%end

%ctor {
    @autoreleasepool {
        NSArray *names = [NSArray arrayWithObjects:@"NSURLConnectionDelegateProxy", @"ISURLOperation", @"ISStoreURLOperation",
                          @"ISOperation", @"ISLoadURLBagOperation", @"ISURLBag", @"ISCertificate", @"SSURLBag", @"SSURLRequestProperties", @"SSMutableURLRequestProperties", nil];
        NSMutableArray *missing = [NSMutableArray array];
        for (NSString *n in names) if (!NSClassFromString(n)) [missing addObject:n];
        ASLog(@"LOAD", @"logger 0.0.4 loaded; missing classes: %@", [missing count] ? [missing componentsJoinedByString:@","] : @"none");
        %init;
        ASDelegatesInit();
        ASBagSelfTest();
        ASAuthInit();
    }
}
