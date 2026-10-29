// ios6-revival Notify: shared between the SpringBoard tweak and the revnotify command.
// revnotify drops one plist per message into RN_SPOOL_DIR and posts RN_DARWIN_NAME;
// SpringBoard picks the files up, shows each as a banner and deletes it.
#define RN_SPOOL_DIR    @"/var/mobile/Library/ios6revival/notify"
#define RN_DARWIN_NAME  "com.stevenjc.ios6revival.notify"
#define RN_KEY_TITLE    @"Title"
#define RN_KEY_MESSAGE  @"Message"
#define RN_KEY_SECTION  @"Section"   // bundle id whose icon the banner shows
#define RN_DEFAULT_SECTION @"com.apple.Preferences"
#define RN_MOBILE_UID   501
