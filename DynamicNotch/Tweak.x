#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreTelephony/CTCall.h>
#import <CoreTelephony/CTCallCenter.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <math.h>

static NSMutableDictionary<NSString *, NSValue *> *gStatusBarOriginalIMPs = nil;
static char kDNOriginalStatusBarTransformKey;
static void DNStatusBarLayoutHook(id object, SEL selector);
static void DNMoveStatusBarChildren(UIView *statusBar);

#pragma mark - Device information

static NSString *DNHardwareModel(void) {
    size_t length = 0;
    if (sysctlbyname("hw.machine", NULL, &length, NULL, 0) != 0 || length == 0) {
        return @"unknown";
    }
    char *buffer = calloc(1, length);
    if (!buffer) return @"unknown";
    NSString *result = @"unknown";
    if (sysctlbyname("hw.machine", buffer, &length, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:buffer] ?: @"unknown";
    }
    free(buffer);
    return result;
}

typedef NS_ENUM(NSInteger, DNNotchProfile) {
    DNNotchProfileWide = 0,   // Visual profile modeled after iPhone X–12
    DNNotchProfileNarrow = 1  // Visual profile modeled after iPhone 13–14
};

static NSString * const kDNNotchProfileDefaultsKey = @"com.dynamicnotch.selectedNotchProfile";

static BOOL DNIsDynamicIslandModel(NSString *model) {
    // iPhone 14 Pro/Pro Max and later Dynamic-Island families.
    return [model hasPrefix:@"iPhone15,"] || [model hasPrefix:@"iPhone16,"] ||
           [model hasPrefix:@"iPhone17,"] || [model hasPrefix:@"iPhone18,"] ||
           [model hasPrefix:@"iPhone19,"];
}

static BOOL DNHasNarrowNotch(NSString *model) {
    // iPhone 13 (iPhone14,2–5) and standard iPhone 14 (iPhone14,7–8).
    return [model isEqualToString:@"iPhone14,2"] || [model isEqualToString:@"iPhone14,3"] ||
           [model isEqualToString:@"iPhone14,4"] || [model isEqualToString:@"iPhone14,5"] ||
           [model isEqualToString:@"iPhone14,7"] || [model isEqualToString:@"iPhone14,8"];
}

static BOOL DNHasKnownNotch(NSString *model) {
    // Exact model families. Avoid treating iPhone 8 (iPhone10,1/2/4/5) as iPhone X.
    BOOL iPhoneX = [model isEqualToString:@"iPhone10,3"] || [model isEqualToString:@"iPhone10,6"];
    BOOL xsFamily = [model isEqualToString:@"iPhone11,2"] || [model isEqualToString:@"iPhone11,4"] ||
                    [model isEqualToString:@"iPhone11,6"] || [model isEqualToString:@"iPhone11,8"];
    BOOL iPhone11 = [model isEqualToString:@"iPhone12,1"] || [model isEqualToString:@"iPhone12,3"] ||
                    [model isEqualToString:@"iPhone12,5"];
    BOOL iPhone12 = [model isEqualToString:@"iPhone13,1"] || [model isEqualToString:@"iPhone13,2"] ||
                    [model isEqualToString:@"iPhone13,3"] || [model isEqualToString:@"iPhone13,4"];
    return iPhoneX || xsFamily || iPhone11 || iPhone12 || DNHasNarrowNotch(model);
}

static BOOL DNIsVirtualNotchEligibleModel(NSString *model) {
    // Devices without a physical notch, including iPhone 7/7 Plus and 8/8 Plus.
    // Also cover older identifiers; actual installability still depends on iOS 15+.
    if ([model hasPrefix:@"iPhone5,"] || [model hasPrefix:@"iPhone6,"] ||
        [model hasPrefix:@"iPhone7,"] || [model hasPrefix:@"iPhone8,"] ||
        [model hasPrefix:@"iPhone9,"]) return YES;

    BOOL iPhone8 = [model isEqualToString:@"iPhone10,1"] || [model isEqualToString:@"iPhone10,2"] ||
                   [model isEqualToString:@"iPhone10,4"] || [model isEqualToString:@"iPhone10,5"];
    BOOL iPhoneSE2 = [model isEqualToString:@"iPhone12,8"];
    BOOL iPhoneSE3 = [model isEqualToString:@"iPhone14,6"];
    return iPhone8 || iPhoneSE2 || iPhoneSE3;
}

static UIColor *DNColorFromHexString(NSString *value) {
    NSString *hex = [[value stringByReplacingOccurrencesOfString:@"#" withString:@""]
                     stringByReplacingOccurrencesOfString:@"0x" withString:@""];
    if (hex.length != 6) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0 alpha:1.0];
}

static UIColor *DNColorFromDevice(void) {
    typedef CFTypeRef (*MGCopyAnswerFunction)(CFStringRef);
    MGCopyAnswerFunction copyAnswer = (MGCopyAnswerFunction)dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (copyAnswer) {
        for (NSString *key in @[@"DeviceColor", @"DeviceEnclosureColor"]) {
            CFTypeRef raw = copyAnswer((__bridge CFStringRef)key);
            if (!raw) continue;
            id value = CFBridgingRelease(raw);
            if (![value isKindOfClass:[NSString class]]) continue;
            NSString *name = [(NSString *)value lowercaseString];
            UIColor *hexColor = DNColorFromHexString(name);
            if (hexColor) return hexColor;
            if ([name containsString:@"gold"]) return [UIColor colorWithRed:0.78 green:0.58 blue:0.25 alpha:1];
            if ([name containsString:@"blue"]) return [UIColor colorWithRed:0.30 green:0.53 blue:0.82 alpha:1];
            if ([name containsString:@"silver"] || [name containsString:@"white"])
                return [UIColor colorWithWhite:0.78 alpha:1];
            if ([name containsString:@"red"]) return [UIColor colorWithRed:0.78 green:0.20 blue:0.22 alpha:1];
            if ([name containsString:@"purple"])
                return [UIColor colorWithRed:0.48 green:0.36 blue:0.72 alpha:1];
            if ([name containsString:@"black"] || [name containsString:@"graphite"] ||
                [name containsString:@"gray"] || [name containsString:@"grey"])
                return [UIColor colorWithWhite:0.24 alpha:1];
        }
    }
    // Neutral fallback if MobileGestalt is unavailable or returns an unknown encoding.
    return [UIColor colorWithWhite:0.68 alpha:1.0];
}

#pragma mark - Overlay windows

@interface DNOverlayWindow : UIWindow
@property(nonatomic, assign) CGRect hitTestRect;
@end

@implementation DNOverlayWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // Allow full-screen hit testing while this window is presenting its demo alert.
    if (self.rootViewController.presentedViewController) return YES;
    return !CGRectIsEmpty(self.hitTestRect) && CGRectContainsPoint(self.hitTestRect, point);
}
@end

@interface DNRootViewController : UIViewController
@end
@implementation DNRootViewController
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = YES;
}
- (BOOL)prefersStatusBarHidden { return NO; }
@end

#pragma mark - Notch view

@interface DNNotchView : UIView
@property(nonatomic, strong) UIStackView *contentStack;
@property(nonatomic, strong) UIStackView *headerStack;
@property(nonatomic, strong) UIStackView *iconStack;
@property(nonatomic, strong) UIImageView *artworkView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) CAShapeLayer *greetingOutline;
- (void)playGreetingWithColor:(UIColor *)color;
- (void)applyTriggerColor:(UIColor *)color;
@end

@implementation DNNotchView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.blackColor;
    self.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
    self.layer.masksToBounds = NO;
    self.layer.shadowOpacity = 0;
    self.clipsToBounds = NO;

    _contentStack = [[UIStackView alloc] init];
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.alignment = UIStackViewAlignmentCenter;
    _contentStack.distribution = UIStackViewDistributionFill;
    _contentStack.spacing = 5;
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_contentStack];

    _headerStack = [[UIStackView alloc] init];
    _headerStack.axis = UILayoutConstraintAxisHorizontal;
    _headerStack.alignment = UIStackViewAlignmentCenter;
    _headerStack.spacing = 7;

    _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkView.clipsToBounds = YES;
    _artworkView.layer.cornerRadius = 7;
    _artworkView.hidden = YES;
    [_artworkView.widthAnchor constraintEqualToConstant:30].active = YES;
    [_artworkView.heightAnchor constraintEqualToConstant:30].active = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    [_headerStack addArrangedSubview:_artworkView];
    [_headerStack addArrangedSubview:_titleLabel];

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    _detailLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    _detailLabel.textAlignment = NSTextAlignmentCenter;
    _detailLabel.numberOfLines = 1;
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    _iconStack = [[UIStackView alloc] init];
    _iconStack.axis = UILayoutConstraintAxisHorizontal;
    _iconStack.alignment = UIStackViewAlignmentCenter;
    _iconStack.distribution = UIStackViewDistributionEqualSpacing;
    _iconStack.spacing = 12;

    [_contentStack addArrangedSubview:_headerStack];
    [_contentStack addArrangedSubview:_detailLabel];
    [_contentStack addArrangedSubview:_iconStack];

    [NSLayoutConstraint activateConstraints:@[
        [_contentStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:14],
        [_contentStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-14],
        [_contentStack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_contentStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_headerStack.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-28]
    ]];
    _titleLabel.hidden = YES;
    _detailLabel.hidden = YES;
    _iconStack.hidden = YES;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(CGRectGetHeight(self.bounds) / 2.0, 40.0);
    if (self.greetingOutline) {
        self.greetingOutline.frame = self.bounds;
        self.greetingOutline.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1.5, 1.5)
                                                               cornerRadius:self.layer.cornerRadius].CGPath;
    }
}

- (void)playGreetingWithColor:(UIColor *)color {
    [self.greetingOutline removeFromSuperlayer];
    CAShapeLayer *outline = [CAShapeLayer layer];
    outline.frame = self.bounds;
    outline.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1.5, 1.5)
                                              cornerRadius:self.layer.cornerRadius].CGPath;
    outline.fillColor = UIColor.clearColor.CGColor;
    outline.strokeColor = color.CGColor;
    outline.lineWidth = 2.5;
    outline.strokeEnd = 0;
    [self.layer addSublayer:outline];
    self.greetingOutline = outline;

    CABasicAnimation *draw = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    draw.fromValue = @0;
    draw.toValue = @1;
    draw.duration = 0.85;
    draw.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [outline addAnimation:draw forKey:@"dn.outline.draw"];
    outline.strokeEnd = 1;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.82 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.layer.shadowColor = color.CGColor;
        self.layer.shadowRadius = 19;
        self.layer.shadowOpacity = 0.85;
        self.layer.shadowOffset = CGSizeZero;
        [UIView animateWithDuration:0.42 animations:^{
            self.backgroundColor = [color colorWithAlphaComponent:0.32];
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.75 delay:0.35 options:UIViewAnimationOptionCurveEaseOut animations:^{
                self.backgroundColor = UIColor.blackColor;
                self.layer.shadowOpacity = 0;
            } completion:^(BOOL done) {
                [self.greetingOutline removeFromSuperlayer];
                self.greetingOutline = nil;
            }];
        }];
    });
}

- (void)applyTriggerColor:(UIColor *)color {
    [UIView animateWithDuration:0.22 animations:^{ self.backgroundColor = color ?: UIColor.blackColor; }];
}
@end

#pragma mark - Controller and trigger priorities

typedef NS_ENUM(NSInteger, DNTriggerPriority) {
    DNTriggerPriorityMedia = 1,
    DNTriggerPrioritySilent = 2,
    DNTriggerPriorityCall = 3,
    DNTriggerPriorityAccessory = 4,
    DNTriggerPriorityCharging = 5
};

@interface DNController : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) DNOverlayWindow *window;
@property(nonatomic, strong) DNNotchView *notch;
@property(nonatomic, strong) CTCallCenter *callCenter;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, copy) NSString *hardwareModel;
@property(nonatomic, strong) UIColor *deviceColor;
@property(nonatomic, assign) BOOL narrowNotch;
@property(nonatomic, assign) BOOL virtualNotch;
@property(nonatomic, assign) BOOL shouldShowProfilePicker;
@property(nonatomic, assign) BOOL expanded;
@property(nonatomic, assign) BOOL charging;
@property(nonatomic, assign) BOOL accessoryConnected;
@property(nonatomic, assign) BOOL callActive;
@property(nonatomic, assign) BOOL silentActive;
@property(nonatomic, assign) BOOL mediaPlaying;
@property(nonatomic, copy) NSString *mediaTitle;
@property(nonatomic, strong) UIImage *mediaArtwork;
@property(nonatomic, assign) CGFloat expandedWidth;
@property(nonatomic, assign) NSInteger tapCount;
@property(nonatomic, assign) NSTimeInterval lastTapTime;
@property(nonatomic, assign) BOOL holdActive;
@property(nonatomic, assign) BOOL detonationFinished;
@property(nonatomic, assign) NSInteger holdPhase;
@property(nonatomic, strong) DNOverlayWindow *explosionWindow;
+ (instancetype)shared;
- (void)start;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)refreshEvents;
- (void)presentSOSDemo;
- (void)beginHoldSequence;
- (void)showDecorativeBurst;
- (void)presentNotchStylePicker;
- (void)handleProfileTap:(UITapGestureRecognizer *)recognizer;
- (void)selectNotchProfile:(DNNotchProfile)profile;
@end

@implementation DNController

+ (instancetype)shared {
    static DNController *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [DNController new]; });
    return instance;
}

- (void)start {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"] || self.window) return;

    self.hardwareModel = DNHardwareModel();
    if (DNIsDynamicIslandModel(self.hardwareModel)) return;

    BOOL hasPhysicalNotch = DNHasKnownNotch(self.hardwareModel);
    self.virtualNotch = !hasPhysicalNotch && DNIsVirtualNotchEligibleModel(self.hardwareModel);
    if (!hasPhysicalNotch && !self.virtualNotch) return;

    if (self.virtualNotch) {
        id savedProfile = [NSUserDefaults.standardUserDefaults objectForKey:kDNNotchProfileDefaultsKey];
        self.shouldShowProfilePicker = (savedProfile == nil);
        NSInteger profileValue = [savedProfile respondsToSelector:@selector(integerValue)]
            ? [savedProfile integerValue] : DNNotchProfileWide;
        self.narrowNotch = (profileValue == DNNotchProfileNarrow);
    } else {
        // On devices with a physical notch, choose the profile automatically.
        self.narrowNotch = DNHasNarrowNotch(self.hardwareModel);
    }
    self.deviceColor = DNColorFromDevice();

    CGRect screen = UIScreen.mainScreen.bounds;
    self.window = [[DNOverlayWindow alloc] initWithFrame:screen];
    self.window.backgroundColor = UIColor.clearColor;
    self.window.windowLevel = UIWindowLevelStatusBar + 1;
    self.window.hitTestRect = CGRectZero;

    DNRootViewController *root = [DNRootViewController new];
    self.window.rootViewController = root;
    self.window.hidden = NO;

    CGFloat collapsedWidth = self.narrowNotch ? 164.0 : 205.0;
    CGFloat collapsedHeight = self.narrowNotch ? 33.0 : 35.0;
    self.expandedWidth = MIN(CGRectGetWidth(screen) - 24.0, self.narrowNotch ? 360.0 : 334.0);
    self.notch = [[DNNotchView alloc] initWithFrame:CGRectMake((CGRectGetWidth(screen) - collapsedWidth) / 2.0,
                                                               0, collapsedWidth, collapsedHeight)];
    [root.view addSubview:self.notch];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = YES;
    [self.notch addGestureRecognizer:tap];

    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHold:)];
    hold.minimumPressDuration = 0.35;
    hold.cancelsTouchesInView = YES;
    [self.notch addGestureRecognizer:hold];
    [tap requireGestureRecognizerToFail:hold];

    // On notchless devices, a two-finger tap reopens the profile selector.
    // It does not interfere with the one-finger tap counter or long-press easter egg.
    if (self.virtualNotch) {
        UITapGestureRecognizer *profileTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                       action:@selector(handleProfileTap:)];
        profileTap.numberOfTapsRequired = 1;
        profileTap.numberOfTouchesRequired = 2;
        profileTap.cancelsTouchesInView = YES;
        [self.notch addGestureRecognizer:profileTap];
    }

    [self refreshHitRegion];
    [self.notch playGreetingWithColor:self.deviceColor];
    [self installSystemObservers];
    [self installStatusBarHooks];
    [self refreshEvents];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(pollSystemState)
                                                    userInfo:nil repeats:YES];

    if (self.virtualNotch && self.shouldShowProfilePicker) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self presentNotchStylePicker];
        });
    }
}

- (void)installSystemObservers {
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pollSystemState)
                                                 name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pollSystemState)
                                                 name:AVAudioSessionRouteChangeNotification object:nil];

    __weak typeof(self) weakSelf = self;
    self.callCenter = [CTCallCenter new];
    self.callCenter.callEventHandler = ^(CTCall *call) {
        BOOL active = [call.callState isEqualToString:CTCallStateIncoming] ||
                      [call.callState isEqualToString:CTCallStateDialing] ||
                      [call.callState isEqualToString:CTCallStateConnected];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.callActive = active;
            [weakSelf refreshEvents];
        });
    };
}

- (void)pollSystemState {
    UIDeviceBatteryState battery = UIDevice.currentDevice.batteryState;
    self.charging = (battery == UIDeviceBatteryStateCharging || battery == UIDeviceBatteryStateFull);

    BOOL hasAccessory = NO;
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs) {
        NSString *type = port.portType;
        if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
            [type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
            hasAccessory = YES;
            break;
        }
    }
    self.accessoryConnected = hasAccessory;

    // Private API, queried only when present. It is intentionally optional because
    // selector availability differs between iOS builds.
    Class mediaControllerClass = NSClassFromString(@"SBMediaController");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    SEL mutedSelector = NSSelectorFromString(@"isRingerMuted");
    if (mediaControllerClass && [mediaControllerClass respondsToSelector:sharedSelector]) {
        id mediaController = ((id (*)(id, SEL))objc_msgSend)(mediaControllerClass, sharedSelector);
        if ([mediaController respondsToSelector:mutedSelector]) {
            self.silentActive = ((BOOL (*)(id, SEL))objc_msgSend)(mediaController, mutedSelector);
        }
    }

    NSDictionary *nowPlaying = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    NSNumber *rate = nowPlaying[MPNowPlayingInfoPropertyPlaybackRate];
    self.mediaPlaying = (nowPlaying.count > 0 && rate.doubleValue > 0.0);
    self.mediaTitle = nowPlaying[MPMediaItemPropertyTitle] ?: @"Now Playing";
    MPMediaItemArtwork *artwork = nowPlaying[MPMediaItemPropertyArtwork];
    self.mediaArtwork = [artwork isKindOfClass:MPMediaItemArtwork.class]
        ? [artwork imageWithSize:CGSizeMake(48, 48)] : nil;

    [self refreshEvents];
}

- (NSArray<NSDictionary *> *)activeIndicators {
    NSMutableArray *items = [NSMutableArray array];
    if (self.charging) [items addObject:@{@"priority": @(DNTriggerPriorityCharging), @"title": @"Charging", @"detail": @"Power connected", @"symbol": @"bolt.fill"}];
    if (self.accessoryConnected) [items addObject:@{@"priority": @(DNTriggerPriorityAccessory), @"title": @"Accessory", @"detail": @"Audio device connected", @"symbol": @"headphones"}];
    if (self.callActive) [items addObject:@{@"priority": @(DNTriggerPriorityCall), @"title": @"Call", @"detail": @"Active call", @"symbol": @"phone.fill"}];
    if (self.silentActive) [items addObject:@{@"priority": @(DNTriggerPrioritySilent), @"title": @"Silent Mode", @"detail": @"Ringer muted", @"symbol": @"bell.slash.fill"}];
    if (self.mediaPlaying) [items addObject:@{@"priority": @(DNTriggerPriorityMedia), @"title": self.mediaTitle ?: @"Media", @"detail": @"Playing", @"symbol": @"waveform"}];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"priority"] compare:a[@"priority"]];
    }];
    return items;
}

- (void)refreshEvents {
    if (!self.notch) return;
    NSArray<NSDictionary *> *items = [self activeIndicators];
    if (items.count == 0) {
        self.notch.titleLabel.hidden = YES;
        self.notch.detailLabel.hidden = YES;
        self.notch.iconStack.hidden = YES;
        self.notch.artworkView.hidden = YES;
        [self.notch applyTriggerColor:UIColor.blackColor];
        [self setExpanded:NO animated:YES];
        return;
    }

    NSDictionary *primary = items.firstObject;
    self.notch.titleLabel.text = primary[@"title"];
    self.notch.detailLabel.text = primary[@"detail"];
    self.notch.titleLabel.hidden = NO;
    self.notch.detailLabel.hidden = NO;
    self.notch.iconStack.hidden = NO;

    BOOL mediaIsPrimary = [primary[@"priority"] integerValue] == DNTriggerPriorityMedia;
    self.notch.artworkView.image = mediaIsPrimary ? self.mediaArtwork : nil;
    self.notch.artworkView.hidden = !(mediaIsPrimary && self.mediaArtwork != nil);

    for (UIView *view in self.notch.iconStack.arrangedSubviews) {
        [self.notch.iconStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSInteger maximumIcons = self.narrowNotch ? 4 : 2;
    NSInteger count = MIN(items.count, maximumIcons);
    for (NSInteger index = 0; index < count; index++) {
        NSString *symbol = items[index][@"symbol"];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        icon.tintColor = UIColor.whiteColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [icon.widthAnchor constraintEqualToConstant:15].active = YES;
        [icon.heightAnchor constraintEqualToConstant:15].active = YES;
        [self.notch.iconStack addArrangedSubview:icon];
    }
    [self.notch applyTriggerColor:UIColor.blackColor];
    [self setExpanded:YES animated:YES];
}

- (void)refreshHitRegion {
    if (!self.window || !self.notch) return;
    self.window.hitTestRect = self.notch.frame;
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (!self.notch || !self.window) return;

    self.expanded = expanded;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat width = expanded ? self.expandedWidth : (self.narrowNotch ? 164.0 : 205.0);
    CGFloat height = expanded ? 108.0 : (self.narrowNotch ? 33.0 : 35.0);
    CGRect targetBounds = CGRectMake(0, 0, width, height);
    CGPoint targetPosition = CGPointMake(CGRectGetMidX(screen), height / 2.0);
    CGRect currentBounds = self.notch.layer.bounds;
    CGPoint currentPosition = self.notch.layer.position;
    BOOL geometryChanged = fabs(CGRectGetWidth(currentBounds) - width) > 0.5 ||
                           fabs(CGRectGetHeight(currentBounds) - height) > 0.5 ||
                           fabs(currentPosition.y - targetPosition.y) > 0.5 ||
                           fabs(currentPosition.x - targetPosition.x) > 0.5;

    if (animated && geometryChanged) {
        CASpringAnimation *boundsAnimation = [CASpringAnimation animationWithKeyPath:@"bounds"];
        boundsAnimation.fromValue = [NSValue valueWithCGRect:currentBounds];
        boundsAnimation.toValue = [NSValue valueWithCGRect:targetBounds];
        boundsAnimation.damping = 22;
        boundsAnimation.stiffness = 230;
        boundsAnimation.mass = 1;
        boundsAnimation.initialVelocity = 0.4;
        boundsAnimation.duration = boundsAnimation.settlingDuration;
        [self.notch.layer addAnimation:boundsAnimation forKey:@"dn.spring.bounds"];

        CASpringAnimation *positionAnimation = [CASpringAnimation animationWithKeyPath:@"position"];
        positionAnimation.fromValue = [NSValue valueWithCGPoint:currentPosition];
        positionAnimation.toValue = [NSValue valueWithCGPoint:targetPosition];
        positionAnimation.damping = 22;
        positionAnimation.stiffness = 230;
        positionAnimation.mass = 1;
        positionAnimation.duration = boundsAnimation.duration;
        [self.notch.layer addAnimation:positionAnimation forKey:@"dn.spring.position"];
    }
    self.notch.layer.bounds = targetBounds;
    self.notch.layer.position = targetPosition;
    self.notch.layer.cornerRadius = height / 2.0;
    self.notch.titleLabel.hidden = !expanded || self.activeIndicators.count == 0;
    self.notch.detailLabel.hidden = !expanded || self.activeIndicators.count == 0;
    self.notch.iconStack.hidden = !expanded || self.activeIndicators.count == 0;
    [self.notch setNeedsLayout];
    [self.notch layoutIfNeeded];
    [self refreshHitRegion];
    [self setStatusBarAvoidanceExpanded:expanded];
}

#pragma mark - Virtual notch profile selection

- (void)handleProfileTap:(UITapGestureRecognizer *)recognizer {
    if (!self.virtualNotch || recognizer.state != UIGestureRecognizerStateEnded) return;
    [self presentNotchStylePicker];
}

- (void)presentNotchStylePicker {
    if (!self.virtualNotch || !self.window.rootViewController) return;
    UIViewController *presented = self.window.rootViewController.presentedViewController;
    if (presented) return;

    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Choose a Notch Style"
                                                                     message:@"This iPhone does not have a physical notch, so DynamicNotch will display a virtual one. Choose a layout. You can change it later by tapping the notch with two fingers."
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    [picker addAction:[UIAlertAction actionWithTitle:@"Wide — iPhone X–12"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self selectNotchProfile:DNNotchProfileWide];
    }]];
    [picker addAction:[UIAlertAction actionWithTitle:@"Narrow — iPhone 13–14"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self selectNotchProfile:DNNotchProfileNarrow];
    }]];
    if (!self.shouldShowProfilePicker) {
        [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    }
    // Action sheets need a source rectangle on iPad; this tweak primarily targets iPhone,
    // but setting it makes the controller safe if run in an iPad-compatible environment.
    picker.popoverPresentationController.sourceView = self.notch;
    picker.popoverPresentationController.sourceRect = self.notch.bounds;
    [self.window.rootViewController presentViewController:picker animated:YES completion:nil];
}

- (void)selectNotchProfile:(DNNotchProfile)profile {
    self.narrowNotch = (profile == DNNotchProfileNarrow);
    self.shouldShowProfilePicker = NO;
    [NSUserDefaults.standardUserDefaults setInteger:profile forKey:kDNNotchProfileDefaultsKey];

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat collapsedWidth = self.narrowNotch ? 164.0 : 205.0;
    CGFloat collapsedHeight = self.narrowNotch ? 33.0 : 35.0;
    CGFloat preferredExpandedWidth = self.narrowNotch ? 360.0 : 334.0;
    self.expandedWidth = MIN(CGRectGetWidth(screen) - 24.0, preferredExpandedWidth);

    // Re-apply dimensions with the spring animation, whether the notch is expanded or idle.
    [self setExpanded:self.expanded animated:YES];
    if (!self.expanded) {
        // Keep the collapsed virtual notch centered after changing its profile.
        self.notch.layer.bounds = CGRectMake(0, 0, collapsedWidth, collapsedHeight);
        self.notch.layer.position = CGPointMake(CGRectGetMidX(screen), collapsedHeight / 2.0);
        self.notch.layer.cornerRadius = collapsedHeight / 2.0;
        [self.notch setNeedsLayout];
        [self.notch layoutIfNeeded];
        [self refreshHitRegion];
    }
    [self.notch playGreetingWithColor:self.deviceColor];
}

#pragma mark - Five-tap demo

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.lastTapTime > 1.45) self.tapCount = 0;
    self.lastTapTime = now;
    self.tapCount += 1;
    if (self.tapCount >= 5) {
        self.tapCount = 0;
        [self presentSOSDemo];
    }
}

- (void)presentSOSDemo {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback prepare];
    [feedback impactOccurred];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Contact Emergency Services?"
                                                                   message:@"This is a demo Easter egg. Confirming will not place a call. In a real emergency, use the iPhone Emergency SOS feature."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Demo Mode" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIImpactFeedbackGenerator *confirm = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [confirm impactOccurred];
        UIAlertController *info = [UIAlertController alertControllerWithTitle:@"DynamicNotch"
                                                                      message:@"Demo mode activated. No phone call was placed."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [info addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self.window.rootViewController presentViewController:info animated:YES completion:nil];
    }]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Long-press sequence and decorative burst

- (void)handleHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        self.holdActive = YES;
        self.detonationFinished = NO;
        self.holdPhase = 0;
        [self beginHoldSequence];
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled ||
               recognizer.state == UIGestureRecognizerStateFailed) {
        self.holdActive = NO;
        if (!self.detonationFinished) {
            [self.notch applyTriggerColor:UIColor.blackColor];
        }
    }
}

- (void)beginHoldSequence {
    NSArray<UIColor *> *phases = @[
        UIColor.blackColor,
        [UIColor colorWithRed:0.82 green:0.04 blue:0.07 alpha:1],
        [UIColor colorWithRed:0.04 green:0.22 blue:0.95 alpha:1],
        UIColor.whiteColor
    ];
    __weak typeof(self) weakSelf = self;
    __block void (^advance)(void);
    advance = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.holdActive || self.detonationFinished) { advance = nil; return; }
        if (self.holdPhase < 3) {
            self.holdPhase += 1;
            [UIView animateWithDuration:0.58 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
                [self.notch applyTriggerColor:phases[self.holdPhase]];
            } completion:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.66 * NSEC_PER_SEC)), dispatch_get_main_queue(), advance);
        } else {
            self.detonationFinished = YES;
            self.holdActive = NO;
            UIImpactFeedbackGenerator *impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [impact prepare];
            [impact impactOccurred];
            [self showDecorativeBurst];
            advance = nil;
        }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.66 * NSEC_PER_SEC)), dispatch_get_main_queue(), advance);
}

- (UIImage *)particleImage {
    CGSize size = CGSizeMake(28, 28);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect circle = CGRectMake(2, 2, 24, 24);
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.72 green:0.015 blue:0.035 alpha:1].CGColor);
    CGContextFillEllipseInRect(context, circle);
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:1 green:0.45 blue:0.43 alpha:0.9].CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(7, 5, 8, 5));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)showDecorativeBurst {
    CGRect screen = UIScreen.mainScreen.bounds;
    DNOverlayWindow *burstWindow = [[DNOverlayWindow alloc] initWithFrame:screen];
    burstWindow.windowLevel = UIWindowLevelAlert + 20;
    burstWindow.backgroundColor = UIColor.clearColor;
    burstWindow.hitTestRect = CGRectZero;
    DNRootViewController *root = [DNRootViewController new];
    burstWindow.rootViewController = root;
    burstWindow.hidden = NO;
    self.explosionWindow = burstWindow;

    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.frame = root.view.bounds;
    emitter.emitterPosition = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
    emitter.emitterShape = kCAEmitterLayerPoint;
    emitter.emitterMode = kCAEmitterLayerPoints;
    emitter.renderMode = kCAEmitterLayerOldestFirst;

    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.contents = (id)[self particleImage].CGImage;
    cell.birthRate = 210;
    cell.lifetime = 0.28;
    cell.lifetimeRange = 0.04;
    cell.velocity = 620;
    cell.velocityRange = 260;
    cell.emissionRange = (CGFloat)(M_PI * 2.0);
    cell.scale = 0.48;
    cell.scaleRange = 0.42;
    cell.spinRange = 5.5;
    cell.alphaSpeed = -1.7;
    cell.color = [UIColor colorWithRed:0.85 green:0.02 blue:0.04 alpha:1].CGColor;
    emitter.emitterCells = @[cell];
    [root.view.layer addSublayer:emitter];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [emitter removeFromSuperlayer];
        burstWindow.hidden = YES;
        self.explosionWindow = nil;
        [self.notch applyTriggerColor:UIColor.blackColor];
        [self setExpanded:(self.activeIndicators.count > 0) animated:YES];
    });
}

#pragma mark - Status bar reflow (private API, best effort)

- (void)installStatusBarHooks {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    if (!gStatusBarOriginalIMPs) gStatusBarOriginalIMPs = [NSMutableDictionary dictionary];

    NSArray<NSString *> *classNames = @[@"UIStatusBar_Modern", @"_UIStatusBar", @"UIStatusBar"];
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        SEL selector = @selector(layoutSubviews);
        Method inheritedOrOwn = class_getInstanceMethod(cls, selector);
        if (!inheritedOrOwn) continue;
        IMP original = method_getImplementation(inheritedOrOwn);
        if (original == (IMP)DNStatusBarLayoutHook) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        Method ownMethod = NULL;
        for (unsigned int index = 0; index < methodCount; index++) {
            if (method_getName(methods[index]) == selector) { ownMethod = methods[index]; break; }
        }
        free(methods);

        gStatusBarOriginalIMPs[name] = [NSValue valueWithPointer:original];
        if (ownMethod) {
            method_setImplementation(ownMethod, (IMP)DNStatusBarLayoutHook);
        } else {
            class_addMethod(cls, selector, (IMP)DNStatusBarLayoutHook,
                            method_getTypeEncoding(inheritedOrOwn));
        }
    }
}

- (void)setStatusBarAvoidanceExpanded:(BOOL)expanded {
    // Walk SpringBoard's current windows because private status-bar instances may
    // be recreated after display, orientation, or status changes.
    NSMutableArray<UIView *> *pending = [NSMutableArray array];
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        [pending addObject:candidate];
    }
    NSInteger visited = 0;
    while (pending.count > 0 && visited++ < 800) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        NSString *className = NSStringFromClass(view.class);
        if ([className containsString:@"StatusBar"]) {
            DNMoveStatusBarChildren(view);
        }
        for (UIView *child in view.subviews) [pending addObject:child];
    }
}

@end

#pragma mark - Runtime status-bar layout helpers

static IMP DNOriginalStatusBarIMPForObject(id object) {
    Class cls = object_getClass(object);
    while (cls) {
        NSString *name = NSStringFromClass(cls);
        NSValue *value = gStatusBarOriginalIMPs[name];
        if (value) return (IMP)value.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void DNMoveStatusBarChildren(UIView *statusBar) {
    DNController *manager = [DNController shared];
    CGFloat width = CGRectGetWidth(statusBar.bounds);
    if (width <= 0) return;
    CGFloat center = width / 2.0;
    CGFloat reservedHalfWidth = manager.expanded ? manager.expandedWidth / 2.0 : 0;

    for (UIView *child in statusBar.subviews) {
        if (child.hidden || child.alpha < 0.05 || CGRectGetHeight(child.bounds) > 55 ||
            CGRectGetWidth(child.bounds) > width * 0.65 || CGRectGetWidth(child.bounds) < 5) continue;

        NSValue *saved = objc_getAssociatedObject(child, &kDNOriginalStatusBarTransformKey);
        if (!saved) {
            saved = [NSValue valueWithCGAffineTransform:child.transform];
            objc_setAssociatedObject(child, &kDNOriginalStatusBarTransformKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGAffineTransform original = saved.CGAffineTransformValue;
        CGFloat dx = 0;
        if (manager.expanded) {
            CGRect frame = child.frame;
            if (CGRectGetMidX(frame) < center) {
                CGFloat boundary = center - reservedHalfWidth;
                if (CGRectGetMaxX(frame) > boundary) dx = -(CGRectGetMaxX(frame) - boundary + 5);
            } else {
                CGFloat boundary = center + reservedHalfWidth;
                if (CGRectGetMinX(frame) < boundary) dx = boundary - CGRectGetMinX(frame) + 5;
            }
        }
        [UIView animateWithDuration:0.20 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            child.transform = CGAffineTransformTranslate(original, dx, 0);
        } completion:nil];
    }
}

static void DNStatusBarLayoutHook(id object, SEL selector) {
    IMP original = DNOriginalStatusBarIMPForObject(object);
    if (original && original != (IMP)DNStatusBarLayoutHook) {
        ((void (*)(id, SEL))original)(object, selector);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([object isKindOfClass:UIView.class]) DNMoveStatusBarChildren((UIView *)object);
    });
}

#pragma mark - Gestures and startup

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[DNController shared] start];
        });
    }
}
