#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name
                                  target:(id)target;
@end

@interface Umn1NotchRootListController : PSListController

@property(nonatomic, strong) NSArray *dnSpecifiers;

@end

static NSString * const DNPreferencesPath =
    @"/var/mobile/Library/Preferences/com.umn1notch.preferences.plist";

static CFStringRef const DNPreferencesNotification =
    CFSTR("com.umn1notch.preferences/Reload");

@implementation Umn1NotchRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Umn1Notch";
}

- (NSArray *)specifiers {
    if (!self.dnSpecifiers) {
        NSArray *loaded =
            [self loadSpecifiersFromPlistName:@"Root" target:self];

        self.dnSpecifiers =
            [loaded isKindOfClass:NSArray.class] ? loaded : @[];
    }

    return self.dnSpecifiers;
}

- (NSDictionary *)preferencesDictionary {
    NSDictionary *preferences =
        [NSDictionary dictionaryWithContentsOfFile:DNPreferencesPath];

    if (![preferences isKindOfClass:NSDictionary.class]) {
        return @{};
    }

    return preferences;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];

    if (![key isKindOfClass:NSString.class] || key.length == 0) {
        return nil;
    }

    id value = [self preferencesDictionary][key];

    if (value != nil) {
        return value;
    }

    id defaultValue = [specifier propertyForKey:@"default"];

    return defaultValue;
}

- (id)validatedValue:(id)value forKey:(NSString *)key {
    if ([key isEqualToString:@"IslandProfile"]) {
        NSInteger profile = [value respondsToSelector:@selector(integerValue)]
            ? [value integerValue]
            : -1;

        if (profile != -1 && profile != 0 && profile != 1) {
            profile = -1;
        }

        return @(profile);
    }

    if ([key isEqualToString:@"EmergencyTapCount"]) {
        NSInteger taps = [value respondsToSelector:@selector(integerValue)]
            ? [value integerValue]
            : 5;

        return @(MIN(25, MAX(5, taps)));
    }

    if ([key isEqualToString:@"HeatDuration"]) {
        CGFloat duration =
            [value respondsToSelector:@selector(doubleValue)]
                ? [value doubleValue]
                : 4.5;

        duration = MIN(8.0, MAX(2.5, duration));

        return @(duration);
    }

    NSArray *booleanKeys = @[
        @"Enabled",
        @"EnableMediaPlayer",
        @"EnableVisualizer",
        @"EnableCharging",
        @"EnableAccessories",
        @"EnableCalls",
        @"EnableSilentMode",
        @"HideInCamera",
        @"HideInLandscape",
        @"EnableEasterEggs",
        @"EnableSOSGesture",
        @"EnableMoltenEffect",
        @"EnableExplosionSound",
        @"EnableGreeting"
    ];

    if ([booleanKeys containsObject:key]) {
        BOOL enabled =
            [value respondsToSelector:@selector(boolValue)]
                ? [value boolValue]
                : NO;

        return @(enabled);
    }

    return value;
}

- (void)setPreferenceValue:(id)value
             forSpecifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];

    if (![key isKindOfClass:NSString.class] ||
        key.length == 0 ||
        value == nil) {
        return;
    }

    id validatedValue = [self validatedValue:value forKey:key];

    if (!validatedValue) {
        return;
    }

    NSMutableDictionary *preferences =
        [[self preferencesDictionary] mutableCopy];

    if (!preferences) {
        preferences = [NSMutableDictionary dictionary];
    }

    preferences[key] = validatedValue;

    NSString *directory =
        [DNPreferencesPath stringByDeletingLastPathComponent];

    NSError *directoryError = nil;

    BOOL directoryCreated =
        [[NSFileManager defaultManager]
            createDirectoryAtPath:directory
            withIntermediateDirectories:YES
            attributes:nil
            error:&directoryError];

    if (!directoryCreated) {
        NSLog(@"[Umn1Notch] Cannot create preferences directory: %@",
              directoryError);
        return;
    }

    NSError *writeError = nil;

    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:preferences
        format:NSPropertyListXMLFormat_v1_0
        options:0
        error:&writeError];

    if (!data) {
        NSLog(@"[Umn1Notch] Cannot serialize preferences: %@",
              writeError);
        return;
    }

    BOOL saved =
        [data writeToFile:DNPreferencesPath
                  options:NSDataWritingAtomic
                    error:&writeError];

    if (!saved) {
        NSLog(@"[Umn1Notch] Cannot save preferences: %@",
              writeError);
        return;
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        DNPreferencesNotification,
        NULL,
        NULL,
        YES
    );
}

@end
