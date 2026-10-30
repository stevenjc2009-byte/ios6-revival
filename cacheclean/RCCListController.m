// Settings > Clear Caches: one Clear button, then an alert saying how much space was freed.
#import <UIKit/UIKit.h>
#import "RCCClean.h"

// Theos's Preferences headers don't compile against the 9.3 SDK (newer availability macros), so only the two
// members used here are declared. The real class lives in Preferences.framework.
@interface PSListController : UIViewController {
    NSMutableArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface RCCListController : PSListController
@end

@implementation RCCListController

- (id)specifiers {
    if (!_specifiers) _specifiers = [[self loadSpecifiersFromPlistName:@"CacheCleaner" target:self] retain];
    return _specifiers;
}

- (void)clearCaches:(id)specifier {
    unsigned long long freed = RCCClean(NO, NO);
    NSString *msg = [NSString stringWithFormat:@"Freed %.1f MB.", freed / 1048576.0];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Caches Cleared" message:msg delegate:nil
                                          cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
    [alert release];
}

@end
