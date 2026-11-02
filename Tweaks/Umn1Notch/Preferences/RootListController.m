#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// Minimal declarations for the private Preferences framework APIs used by
// PreferenceLoader. These are resolved by Preferences.app at runtime.
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

static NSString * const kUmn1NotchPrefsPath = @"/var/mobile/Library/Preferences/com.umn1notch.preferences.plist";
static CFStringRef const kUmn1NotchPrefsChanged = CFSTR("com.umn1notch.preferences/Reload");

@interface Umn1NotchRootListController : PSListController
@property(nonatomic, strong) NSArray *dnSpecifiers;
@end

@implementation Umn1NotchRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Umn1Notch";
}

- (NSArray *)specifiers {
    if (!self.dnSpecifiers) {
        self.dnSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return self.dnSpecifiers;
}

- (NSDictionary *)preferencesDictionary {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:kUmn1NotchPrefsPath];
    return [preferences isKindOfClass:NSDictionary.class] ? preferences : @{};
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id value = key ? [self preferencesDictionary][key] : nil;
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0 || value == nil) return;

    NSMutableDictionary *preferences = [[self preferencesDictionary] mutableCopy];
    preferences[key] = value;

    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Preferences"
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&directoryError];
    BOOL saved = [preferences writeToFile:kUmn1NotchPrefsPath atomically:YES];
    if (!saved) {
        NSLog(@"[Umn1Notch] Failed to save preferences: %@", directoryError);
        return;
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          kUmn1NotchPrefsChanged, NULL, NULL, YES);
}

@end
 
