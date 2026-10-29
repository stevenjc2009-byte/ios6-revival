// ios6-revival App Store: read-only logging of loads Tweak.x cannot see (phase 3). Manual retain/release.
// 1. iTunesStoreX's CustomURLProtocol proxies store pages through its own NSURLConnection and handles the callbacks
//    itself, so they never reach Tweak.x's hooks. Hooked on first sight (iTunesStoreX loads after this dylib).
// 2. UIWebView / WebKit: page starts, finishes and failures, per-resource failures, and the page's console messages.
// No class is referenced directly, so nothing links UIKit into itunesstored. Every hook calls the original.
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <substrate.h>
#import "ASLog.h"
#import "ASHooks.h"

// ---- CustomURLProtocol ----
static IMP cpOrigResp, cpOrigData, cpOrigDone, cpOrigFail;

static void cpResp(id s, SEL c, NSURLConnection *conn, NSURLResponse *r) {
    ASOnResponse(conn, r); ((void (*)(id, SEL, id, id))cpOrigResp)(s, c, conn, r);
}
static void cpData(id s, SEL c, NSURLConnection *conn, NSData *d) {
    ASOnData(conn, d); ((void (*)(id, SEL, id, id))cpOrigData)(s, c, conn, d);
}
static void cpDone(id s, SEL c, NSURLConnection *conn) {
    ASOnFinish(conn); ((void (*)(id, SEL, id))cpOrigDone)(s, c, conn);
}
static void cpFail(id s, SEL c, NSURLConnection *conn, NSError *e) {
    ASOnFail(conn, e); ((void (*)(id, SEL, id, id))cpOrigFail)(s, c, conn, e);
}

void ASWatchDelegate(id delegate) {
    static BOOL done;
    if (done || !delegate) return;
    Class cls = objc_getClass("CustomURLProtocol");
    if (!cls || ![delegate isKindOfClass:cls]) return;
    @synchronized (@"ASWatchDelegate") {
        if (done) return;
        done = YES;
        struct { SEL sel; IMP fn; IMP *orig; } h[] = {
            { @selector(connection:didReceiveResponse:), (IMP)cpResp, &cpOrigResp },
            { @selector(connection:didReceiveData:), (IMP)cpData, &cpOrigData },
            { @selector(connectionDidFinishLoading:), (IMP)cpDone, &cpOrigDone },
            { @selector(connection:didFailWithError:), (IMP)cpFail, &cpOrigFail },
        };
        NSMutableArray *got = [NSMutableArray array];
        for (unsigned i = 0; i < sizeof h / sizeof h[0]; i++)
            if (class_getInstanceMethod(cls, h[i].sel)) {
                MSHookMessageEx(cls, h[i].sel, h[i].fn, h[i].orig);
                [got addObject:NSStringFromSelector(h[i].sel)];
            }
        ASLog(@"PROTO", @"watching CustomURLProtocol: %@", [got componentsJoinedByString:@" "]);
    }
}

// ---- UIWebView (the WebKit delegate behind every store page) ----
static NSString *ASFrameText(id webView, id frame, BOOL provisional) {
    id main = [webView respondsToSelector:@selector(mainFrame)] ? [webView performSelector:@selector(mainFrame)] : nil;
    SEL dsSel = provisional ? @selector(provisionalDataSource) : @selector(dataSource);
    id ds = [frame respondsToSelector:dsSel] ? [frame performSelector:dsSel] : nil;
    NSURLRequest *req = [ds respondsToSelector:@selector(request)] ? [ds performSelector:@selector(request)] : nil;
    return [NSString stringWithFormat:@"%@ %@", frame == main ? @"main" : @"sub", ASSafeURL([req URL])];
}

static NSString *ASFailingURL(NSError *e) {
    id u = [[e userInfo] objectForKey:@"NSErrorFailingURLKey"];
    if (![u isKindOfClass:[NSURL class]]) {
        id s = [[e userInfo] objectForKey:@"NSErrorFailingURLStringKey"];
        u = [s isKindOfClass:[NSString class]] ? [NSURL URLWithString:s] : nil;
    }
    return ASSafeURL(u);
}

static IMP wvOrigStart, wvOrigProvFail, wvOrigFail, wvOrigDone, wvOrigResFail, wvOrigIdent, wvOrigMainFail;

static void wvStart(id s, SEL c, id wv, id frame) {
    ASLog(@"WEBSTART", @"%@", ASFrameText(wv, frame, YES));
    ((void (*)(id, SEL, id, id))wvOrigStart)(s, c, wv, frame);
}
static void wvProvFail(id s, SEL c, id wv, NSError *e, id frame) {
    ASLog(@"WEBFAIL", @"provisional %@ err=%@", ASFrameText(wv, frame, YES), ASErrorText(e));
    ((void (*)(id, SEL, id, id, id))wvOrigProvFail)(s, c, wv, e, frame);
}
static void wvFail(id s, SEL c, id wv, NSError *e, id frame) {
    ASLog(@"WEBFAIL", @"load %@ err=%@", ASFrameText(wv, frame, NO), ASErrorText(e));
    ((void (*)(id, SEL, id, id, id))wvOrigFail)(s, c, wv, e, frame);
}
static void wvDone(id s, SEL c, id wv, id frame) {
    ASLog(@"WEBDONE", @"%@", ASFrameText(wv, frame, NO));
    ((void (*)(id, SEL, id, id))wvOrigDone)(s, c, wv, frame);
}
static void wvResFail(id s, SEL c, id wv, id ident, NSError *e, id ds) {
    ASLog(@"WEBRES", @"failed %@ err=%@", ASFailingURL(e), ASErrorText(e));
    ((void (*)(id, SEL, id, id, id, id))wvOrigResFail)(s, c, wv, ident, e, ds);
}
static id wvIdent(id s, SEL c, id wv, NSURLRequest *req, id ds) {
    NSURL *u = [req URL];   // inline data: images would put whole base64 blobs in the log
    if ([[u scheme] isEqualToString:@"data"]) ASLog(@"WEBREQ", @"data: URL (%lu chars)", (unsigned long)[[u absoluteString] length]);
    else ASLog(@"WEBREQ", @"%@", ASSafeURL(u));
    return ((id (*)(id, SEL, id, id, id))wvOrigIdent)(s, c, wv, req, ds);
}
static void wvMainFail(id s, SEL c, id wv, NSError *e) {
    ASLog(@"WEBFAIL", @"main frame err=%@", ASErrorText(e));
    ((void (*)(id, SEL, id, id))wvOrigMainFail)(s, c, wv, e);
}

// ---- Page console (JavaScript errors). UIWebBrowserView has the method; other document views get a log-only copy. ----
static IMP conOrig;

static void conLog(NSDictionary *m, NSString *source) {
    if (![m isKindOfClass:[NSDictionary class]]) return;
    NSString *msg = [[m objectForKey:@"message"] description] ?: @"-";
    if ([msg length] > 300) msg = [[msg substringToIndex:300] stringByAppendingString:@"..."];
    id src = [m objectForKey:@"sourceURL"];
    ASLog(@"WEBCONSOLE", @"level=%@ src=%@ line=%@ msg=%@", [m objectForKey:@"MessageLevel"] ?: @"-",
          [src isKindOfClass:[NSString class]] ? ASSafeURL([NSURL URLWithString:src]) : @"-",
          [m objectForKey:@"lineNumber"] ?: @"-", ASScrubText(msg));
}
static void conHook(id s, SEL c, id wv, NSDictionary *m, NSString *source) {
    conLog(m, source);
    ((void (*)(id, SEL, id, id, id))conOrig)(s, c, wv, m, source);
}
static void conAdded(id s, SEL c, id wv, NSDictionary *m, NSString *source) { conLog(m, source); }   // nothing to call through to

static void ASHookAll(const char *name, SEL sel, IMP fn, IMP *orig) {
    Class cls = objc_getClass(name);
    if (cls && class_getInstanceMethod(cls, sel)) MSHookMessageEx(cls, sel, fn, orig);
    else ASLog(@"WEBHOOK", @"skipped %s %@ (not present)", name, NSStringFromSelector(sel));
}

void ASDelegatesInit(void) {
    if (!objc_getClass("UIWebView")) return;   // itunesstored has no UIKit
    ASHookAll("UIWebView", @selector(webView:didStartProvisionalLoadForFrame:), (IMP)wvStart, &wvOrigStart);
    ASHookAll("UIWebView", @selector(webView:didFailProvisionalLoadWithError:forFrame:), (IMP)wvProvFail, &wvOrigProvFail);
    ASHookAll("UIWebView", @selector(webView:didFailLoadWithError:forFrame:), (IMP)wvFail, &wvOrigFail);
    ASHookAll("UIWebView", @selector(webView:didFinishLoadForFrame:), (IMP)wvDone, &wvOrigDone);
    ASHookAll("UIWebView", @selector(webView:resource:didFailLoadingWithError:fromDataSource:), (IMP)wvResFail, &wvOrigResFail);
    ASHookAll("UIWebView", @selector(webView:identifierForInitialRequest:fromDataSource:), (IMP)wvIdent, &wvOrigIdent);
    ASHookAll("UIWebView", @selector(webViewMainFrameDidFailLoad:withError:), (IMP)wvMainFail, &wvOrigMainFail);

    SEL con = @selector(webView:addMessageToConsole:withSource:);
    ASHookAll("UIWebBrowserView", con, (IMP)conHook, &conOrig);
    Class doc = objc_getClass("UIWebDocumentView");   // store pages use SUWebDocumentView, a sibling of UIWebBrowserView
    if (doc && !class_getInstanceMethod(doc, con)) class_addMethod(doc, con, (IMP)conAdded, "v20@0:4@8@12@16");
    ASLog(@"WEBHOOK", @"UIWebView hooks ready");
}
