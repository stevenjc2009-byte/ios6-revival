// ios6-revival App Store: signed-bag fallback (phase 3, approved by steve 2026-10-29). Manual retain/release.
// Apple's bag.xml now carries a corrupted "certs" blob (DER bytes replaced by U+FFFD), so itunesstored's
// signature check fails before it can run. Only when that check fails, the bag is still accepted if these exact
// bytes arrived over https from apple.com (or a subdomain), through iOS's own trust check, with no error.
// allowUnsignedBags is never touched, and a bag whose signature check passes is never handled here.
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#import "ASLog.h"
#import "ASHooks.h"

static NSMutableDictionary *asFetches;   // bag "signature" bytes -> {url, why}; why absent = verified fetch

static NSMutableDictionary *ASFetches(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ asFetches = [[NSMutableDictionary alloc] init]; });
    return asFetches;
}

// The single decision rule, used by the real path and by the load-time self-test.
NSString *ASBagRejectReason(NSURL *url, NSString *trust, BOOL finishedOK) {
    if (!url) return @"no final URL";
    if (![[[url scheme] lowercaseString] isEqualToString:@"https"]) return @"not https";
    NSString *host = [[url host] lowercaseString];
    if (!([host isEqualToString:@"apple.com"] || [host hasSuffix:@".apple.com"])) return @"host is not apple.com";
    if (![trust isEqualToString:@"performDefaultHandling"])
        return [NSString stringWithFormat:@"trust decision was %@", trust ?: @"never seen"];
    if (!finishedOK) return @"load did not finish cleanly";
    return nil;
}

static NSDictionary *ASPlist(NSData *data) {
    if (![data isKindOfClass:[NSData class]]) return nil;
    id pl = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [pl isKindOfClass:[NSDictionary class]] ? pl : nil;
}

// Called when an xml body finished loading. Remembers the bag's signature bytes and whether the fetch qualifies.
void ASBagNoteFetch(NSURL *url, NSString *trust, NSData *body) {
    NSData *sig = [ASPlist(body) objectForKey:@"signature"];
    if (![sig isKindOfClass:[NSData class]]) return;   // not a signed bag
    NSString *why = ASBagRejectReason(url, trust, YES);
    NSMutableDictionary *rec = [NSMutableDictionary dictionaryWithObject:ASSafeURL(url) forKey:@"url"];
    if (why) [rec setObject:why forKey:@"why"];
    @synchronized (ASFetches()) {
        if ([asFetches count] > 16) [asFetches removeAllObjects];
        [asFetches setObject:rec forKey:sig];
    }
    ASLog(@"BAGFETCH", @"%@ trust=%@ -> %@", ASSafeURL(url), trust ?: @"never seen", why ?: @"verified");
}

// Failure path of -[ISURLBag _loadFromSignedDictionary:returningError:] only. YES = bag loaded.
BOOL ASBagAcceptUnsigned(id bag, NSDictionary *dict, NSError *err) {
    NSData *sig = [dict isKindOfClass:[NSDictionary class]] ? [dict objectForKey:@"signature"] : nil;
    NSDictionary *rec = nil;
    if ([sig isKindOfClass:[NSData class]])
        @synchronized (ASFetches()) { rec = [[[asFetches objectForKey:sig] retain] autorelease]; }
    NSString *url = [rec objectForKey:@"url"] ?: @"-";
    NSString *why = ![sig isKindOfClass:[NSData class]] ? @"bag has no signature"
                  : !rec ? @"no fetch of these bytes seen in this process" : [rec objectForKey:@"why"];
    NSDictionary *inner = nil;
    if (!why) {
        inner = ASPlist([dict objectForKey:@"bag"]);
        if (!inner) why = @"bag payload is not a dictionary";
        else if (![bag respondsToSelector:@selector(_setDictionary:)]) why = @"ISURLBag has no _setDictionary:";
    }
    if (why) {
        ASLog(@"BAGFIX", @"REJECT %@ reason=%@ (signature check: %@)", url, why, ASErrorText(err));
        return NO;
    }
    [bag performSelector:@selector(_setDictionary:) withObject:inner];
    ASLog(@"BAGFIX", @"ACCEPT %@ reason=signature check failed (%@) but bytes came over verified https from apple.com; %lu keys",
          url, ASErrorText(err), (unsigned long)[inner count]);
    return YES;
}

// Success path, read-only: proves the fallback stores what the real signed load stores (first time only).
void ASBagCheckSignedPath(id bag, NSDictionary *dict) {
    static BOOL done;
    if (done || ![bag respondsToSelector:@selector(URLBagDictionary)]) return;
    NSDictionary *inner = ASPlist([dict isKindOfClass:[NSDictionary class]] ? [dict objectForKey:@"bag"] : nil);
    if (!inner) return;
    done = YES;
    id stored = [bag performSelector:@selector(URLBagDictionary)];
    ASLog(@"BAGFIX", @"signed load ok: decoded payload %@ URLBagDictionary (%lu vs %lu keys)",
          [inner isEqual:stored] ? @"equals" : @"DIFFERS FROM", (unsigned long)[inner count],
          (unsigned long)([stored respondsToSelector:@selector(count)] ? [stored count] : 0));
}

// One line at load: the decision rule on fixed inputs, so the REJECT arms are seen running.
void ASBagSelfTest(void) {
    struct { NSString *url, *trust; } t[] = {
        { @"https://init.itunes.apple.com/bag.xml", @"performDefaultHandling" },
        { @"http://init.itunes.apple.com/bag.xml", @"performDefaultHandling" },
        { @"https://example.com/bag.xml", @"performDefaultHandling" },
        { @"https://init.itunes.apple.com.example.com/bag.xml", @"performDefaultHandling" },
        { @"https://evilapple.com/bag.xml", @"performDefaultHandling" },
        { @"https://init.itunes.apple.com/bag.xml", @"cancel" },
        { @"https://init.itunes.apple.com/bag.xml", nil },
    };
    NSMutableArray *out = [NSMutableArray array];
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) {
        NSString *why = ASBagRejectReason([NSURL URLWithString:t[i].url], t[i].trust, YES);
        [out addObject:[NSString stringWithFormat:@"%@ trust=%@ -> %@", t[i].url, t[i].trust ?: @"none",
                        why ? [@"REJECT " stringByAppendingString:why] : @"ACCEPT"]];
    }
    ASLog(@"BAGTEST", @"%@", [out componentsJoinedByString:@" | "]);
}
