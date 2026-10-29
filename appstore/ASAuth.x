// ios6-revival App Store: sign-in fix (phase 4).
// Apple's bag now sends iOS 6 to sign in at https://auth.itunes.apple.com/auth/v1/native/fast (older bags:
// .../MZFinance.woa/wa/authenticate). Since about 2026-09-29 Apple only answers those at the same path with a
// trailing "/"; the bare path gives 301/204/HTML, which iOS reports as "Cannot connect to iTunes Store".
// So the bag's authenticateAccount URL gets the trailing "/" (the approach NewerStoreLoginFix and AppStoreFix v3
// use; code written fresh here). Nothing else about the sign-in request changes, and nothing in it is logged
// beyond the URL. Also logs why a purchase was refused (failureType / customerMessage of the buy response).
#import <Foundation/Foundation.h>
#import "ASLog.h"
#import "ASHooks.h"

@interface ISURLBag : NSObject
- (NSURL *)urlForKey:(NSString *)key;
@end

static NSString *const ASAuthKey = @"authenticateAccount";

// "https://host.apple.com/a/b?q" -> "https://host.apple.com/a/b/?q"; nil when it needs no change.
NSString *ASAuthSlashedURL(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || ![[s lowercaseString] hasPrefix:@"https://"]) return nil;
    NSURL *url = [NSURL URLWithString:s];
    NSString *host = [[url host] lowercaseString];
    if (!([host isEqualToString:@"apple.com"] || [host hasSuffix:@".apple.com"])) return nil;
    NSUInteger q = [s rangeOfString:@"?"].location;
    NSUInteger end = q == NSNotFound ? [s length] : q;
    NSUInteger hostEnd = [s rangeOfString:@"/" options:0 range:NSMakeRange(8, [s length] - 8)].location;
    if (hostEnd == NSNotFound || hostEnd >= end) return nil;   // no path: nothing to fix
    if ([s characterAtIndex:end - 1] == '/') return nil;     // already slashed
    return [s stringByReplacingCharactersInRange:NSMakeRange(end, 0) withString:@"/"];
}

static int asAuthLogs;   // the bag is read often; log the first few rewrites only

static id ASAuthFix(NSString *key, id value, NSString *via) {
    if (![key isEqualToString:ASAuthKey] || !value) return value;
    BOOL isURL = [value isKindOfClass:[NSURL class]];
    NSString *fixed = ASAuthSlashedURL(isURL ? [value absoluteString] : value);
    if (asAuthLogs < 6) {
        asAuthLogs++;
        ASLog(@"AUTHURL", @"%@ %@ -> %@", via, isURL ? ASSafeURL(value) : ASScrubText([value description]),
              fixed ? ASScrubText(fixed) : @"(unchanged)");
    }
    if (!fixed) return value;
    if (!isURL) return fixed;
    return [NSURL URLWithString:fixed] ?: value;
}

%group ASAuthValue
%hook ISURLBag
- (id)valueForKey:(NSString *)key {
    return ASAuthFix(key, %orig, @"valueForKey");
}
%end
%end

%group ASAuthURL
%hook ISURLBag
- (NSURL *)urlForKey:(NSString *)key {
    return ASAuthFix(key, %orig, @"urlForKey");
}
%end
%end

// Called with every finished xml body (Tweak.x). Only the buy endpoint's refusal reason is logged: its
// failureType and customerMessage, plus the names (never values) of the other keys.
void ASAuthNoteResponse(NSURL *url, NSData *body) {
    if ([[url path] rangeOfString:@"/MZBuy.woa/wa/buyProduct"].location == NSNotFound || [body length] > 64 * 1024) return;
    id plist = [NSPropertyListSerialization propertyListWithData:body options:0 format:NULL error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        ASLog(@"BUYRESP", @"not a plist (%lu bytes)", (unsigned long)[body length]);
        return;
    }
    NSArray *keys = [[plist allKeys] sortedArrayUsingSelector:@selector(compare:)];
    ASLog(@"BUYRESP", @"failureType=%@ customerMessage=%@ keys=[%@]", [plist objectForKey:@"failureType"] ?: @"-",
          [plist objectForKey:@"customerMessage"] ?: @"-", [keys componentsJoinedByString:@","]);
}

// Rewrite rules checked once per launch, so a wrong rule shows in the log before it matters.
static void ASAuthSelfTest(void) {
    NSString *cases[][2] = {
        { @"https://auth.itunes.apple.com/auth/v1/native/fast", @"https://auth.itunes.apple.com/auth/v1/native/fast/" },
        { @"https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=1", @"https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/?guid=1" },
        { @"https://auth.itunes.apple.com/auth/v1/native/fast/", nil },
        { @"http://auth.itunes.apple.com/auth/v1/native/fast", nil },
        { @"https://auth.itunes.apple.com.example.com/x", nil },
        { @"https://example.com/apple.com/x", nil },
        { @"https://auth.itunes.apple.com", nil },
    };
    int bad = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        NSString *got = ASAuthSlashedURL(cases[i][0]);
        if (!(got == cases[i][1] || [got isEqualToString:cases[i][1]])) {
            bad++;
            ASLog(@"AUTHTEST", @"FAIL %@ -> %@ (want %@)", cases[i][0], got, cases[i][1]);
        }
    }
    ASLog(@"AUTHTEST", @"%d/%lu rules ok", (int)(sizeof(cases) / sizeof(cases[0])) - bad, (unsigned long)(sizeof(cases) / sizeof(cases[0])));
}

void ASAuthInit(void) {
    Class bag = NSClassFromString(@"ISURLBag");
    BOOL hasURL = [bag instancesRespondToSelector:@selector(urlForKey:)];
    ASLog(@"AUTHINIT", @"ISURLBag=%d urlForKey=%d", bag != Nil, hasURL);
    if (!bag) return;
    %init(ASAuthValue);
    if (hasURL) %init(ASAuthURL);
    ASAuthSelfTest();
}
