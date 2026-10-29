// ios6-revival App Store: functions shared between Tweak.x, ASDelegates.m and ASBag.m.
#import <Foundation/Foundation.h>

// Tweak.x: one log line per connection event, deduped per connection (whoever calls first wins).
void ASOnResponse(NSURLConnection *c, NSURLResponse *resp);
void ASOnData(NSURLConnection *c, NSData *data);
void ASOnFinish(NSURLConnection *c);
void ASOnFail(NSURLConnection *c, NSError *err);

// ASDelegates.m: read-only hooks on iTunesStoreX's CustomURLProtocol and on UIWebView / WebKit loads.
void ASWatchDelegate(id delegate);   // called for every new connection; hooks CustomURLProtocol on first sight
void ASDelegatesInit(void);

// ASBag.m: signed-bag fallback. nil = acceptable, else why not.
NSString *ASBagRejectReason(NSURL *finalURL, NSString *trustDecision, BOOL finishedOK);
void ASBagNoteFetch(NSURL *finalURL, NSString *trustDecision, NSData *body);
BOOL ASBagAcceptUnsigned(id bag, NSDictionary *dict, NSError *why);
void ASBagCheckSignedPath(id bag, NSDictionary *dict);
void ASBagSelfTest(void);

// ASAuth.x: sign-in URL fix (trailing slash on the bag's authenticateAccount) and buy-refusal logging.
NSString *ASAuthSlashedURL(NSString *s);
void ASAuthNoteResponse(NSURL *url, NSData *body);
void ASAuthInit(void);
