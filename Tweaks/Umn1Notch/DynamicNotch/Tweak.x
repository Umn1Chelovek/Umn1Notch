#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreTelephony/CTCall.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreFoundation/CoreFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <math.h>
#include <stdint.h>
#include <stdlib.h>

static NSMutableDictionary<NSString *, NSValue *> *gStatusBarOriginalIMPs = nil;
static char kDNOriginalStatusBarTransformKey;
static void DNStatusBarLayoutHook(id object, SEL selector);
static void DNMoveStatusBarChildren(UIView *statusBar);
static void DNPreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);
static void DNMediaRemoteChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);

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

static NSString * const kDNNotchProfileDefaultsKey = @"IslandProfile";
static NSString * const kDNPreferenceDomain = @"com.umn1notch.preferences";
static NSString * const kDNPreferencePath = @"/var/mobile/Library/Preferences/com.umn1notch.preferences.plist";
static CFStringRef const kDNPreferencesChangedNotification = CFSTR("com.umn1notch.preferences/Reload");

static NSDictionary *DNReadPreferences(void) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:kDNPreferencePath];
    return [preferences isKindOfClass:NSDictionary.class] ? preferences : @{};
}

static id DNPreferenceValue(NSString *key, id fallback) {
    id value = DNReadPreferences()[key];
    return value ?: fallback;
}

static BOOL DNPreferenceBool(NSString *key, BOOL fallback) {
    id value = DNPreferenceValue(key, @(fallback));
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSInteger DNPreferenceInteger(NSString *key, NSInteger fallback) {
    id value = DNPreferenceValue(key, @(fallback));
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void DNWritePreference(NSString *key, id value) {
    NSMutableDictionary *preferences = [DNReadPreferences() mutableCopy] ?: [NSMutableDictionary dictionary];
    preferences[key] = value;
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Preferences"
                              withIntermediateDirectories:YES attributes:nil error:&directoryError];
    [preferences writeToFile:kDNPreferencePath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          kDNPreferencesChangedNotification, NULL, NULL, YES);
}

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

static NSData *DNCreateMoltenBurstAudio(void) {
    const uint32_t sampleRate = 22050;
    const double duration = 0.62;
    const uint32_t sampleCount = (uint32_t)(sampleRate * duration);
    const uint32_t dataBytes = sampleCount * sizeof(int16_t);
    struct __attribute__((packed)) WAVHeader {
        char riff[4]; uint32_t fileSize; char wave[4];
        char fmt[4]; uint32_t fmtSize; uint16_t audioFormat; uint16_t channels;
        uint32_t rate; uint32_t byteRate; uint16_t blockAlign; uint16_t bits;
        char data[4]; uint32_t dataSize;
    } header = {{'R','I','F','F'}, 36 + dataBytes, {'W','A','V','E'},
                {'f','m','t',' '}, 16, 1, 1, sampleRate, sampleRate * 2, 2, 16,
                {'d','a','t','a'}, dataBytes};
    NSMutableData *wav = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    for (uint32_t i = 0; i < sampleCount; i++) {
        double t = (double)i / sampleRate;
        double envelope = exp(-5.2 * t) * fmin(1.0, t * 45.0);
        double sweep = 105.0 - 62.0 * (t / duration);
        double crackle = sin(2.0 * M_PI * (820.0 - 560.0 * t) * t) * exp(-13.0 * t);
        double body = sin(2.0 * M_PI * sweep * t) * 0.72 + crackle * 0.25;
        double shimmer = sin(2.0 * M_PI * 1780.0 * t) * exp(-24.0 * t) * 0.10;
        double sample = fmax(-1.0, fmin(1.0, (body + shimmer) * envelope));
        int16_t pcm = (int16_t)(sample * 30000.0);
        [wav appendBytes:&pcm length:sizeof(pcm)];
    }
    return wav;
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
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

#pragma mark - Notch view

@interface DNNotchView : UIView
@property(nonatomic, strong) CAShapeLayer *shapeLayer;
@property(nonatomic, strong) UIStackView *contentStack;
@property(nonatomic, strong) UIStackView *headerStack;
@property(nonatomic, strong) UIStackView *iconStack;
@property(nonatomic, strong) UIStackView *compactMediaStack;
@property(nonatomic, strong) UIImageView *artworkView;
@property(nonatomic, strong) UIImageView *compactArtworkView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) CAShapeLayer *greetingOutline;
@property(nonatomic, strong) NSMutableArray<UIView *> *visualizerBars;
@property(nonatomic, assign) BOOL visualizerRunning;
- (void)playGreetingWithColor:(UIColor *)color;
- (void)applyTriggerColor:(UIColor *)color;
- (void)setCompactMediaArtwork:(UIImage *)artwork active:(BOOL)active;
@end

@implementation DNNotchView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.layer.masksToBounds = NO;
    self.clipsToBounds = NO;

    _shapeLayer = [CAShapeLayer layer];
    _shapeLayer.fillColor = UIColor.blackColor.CGColor;
    _shapeLayer.shadowColor = UIColor.blackColor.CGColor;
    _shapeLayer.shadowOpacity = 0.18;
    _shapeLayer.shadowRadius = 5;
    _shapeLayer.shadowOffset = CGSizeMake(0, 2);
    [self.layer insertSublayer:_shapeLayer atIndex:0];

    _contentStack = [[UIStackView alloc] init];
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.alignment = UIStackViewAlignmentCenter;
    _contentStack.distribution = UIStackViewDistributionFill;
    _contentStack.spacing = 4;
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

    _compactMediaStack = [[UIStackView alloc] init];
    _compactMediaStack.axis = UILayoutConstraintAxisHorizontal;
    _compactMediaStack.alignment = UIStackViewAlignmentCenter;
    _compactMediaStack.distribution = UIStackViewDistributionFill;
    _compactMediaStack.spacing = 9;
    _compactMediaStack.hidden = YES;

    _compactArtworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _compactArtworkView.contentMode = UIViewContentModeScaleAspectFill;
    _compactArtworkView.clipsToBounds = YES;
    _compactArtworkView.layer.cornerRadius = 6;
    [_compactArtworkView.widthAnchor constraintEqualToConstant:25].active = YES;
    [_compactArtworkView.heightAnchor constraintEqualToConstant:25].active = YES;
    [_compactMediaStack addArrangedSubview:_compactArtworkView];

    _visualizerBars = [NSMutableArray array];
    UIStackView *bars = [[UIStackView alloc] init];
    bars.axis = UILayoutConstraintAxisHorizontal;
    bars.alignment = UIStackViewAlignmentCenter;
    bars.spacing = 3;
    for (NSInteger index = 0; index < 5; index++) {
        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
        bar.layer.cornerRadius = 1.5;
        [bar.widthAnchor constraintEqualToConstant:3].active = YES;
        [bar.heightAnchor constraintEqualToConstant:14].active = YES;
        [bars addArrangedSubview:bar];
        [_visualizerBars addObject:bar];
    }
    [_compactMediaStack addArrangedSubview:bars];

    [_contentStack addArrangedSubview:_headerStack];
    [_contentStack addArrangedSubview:_detailLabel];
    [_contentStack addArrangedSubview:_iconStack];
    [_contentStack addArrangedSubview:_compactMediaStack];

    [NSLayoutConstraint activateConstraints:@[
        [_contentStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:13],
        [_contentStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-13],
        [_contentStack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_contentStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_headerStack.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-26]
    ]];
    _titleLabel.hidden = YES;
    _detailLabel.hidden = YES;
    _iconStack.hidden = YES;
    return self;
}

- (CGPathRef)topAttachedPathForBounds:(CGRect)bounds inset:(CGFloat)inset {
    CGRect r = CGRectInset(bounds, inset, inset);
    CGFloat radius = MIN(25.0, MIN(CGRectGetWidth(r) * 0.13, CGRectGetHeight(r) * 0.48));
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r))];
    [path addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))];
    [path addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - radius)];
    [path addQuadCurveToPoint:CGPointMake(CGRectGetMaxX(r) - radius, CGRectGetMaxY(r))
                 controlPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
    [path addLineToPoint:CGPointMake(CGRectGetMinX(r) + radius, CGRectGetMaxY(r))];
    [path addQuadCurveToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r) - radius)
                 controlPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))];
    [path closePath];
    return path.CGPath;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.shapeLayer.frame = self.bounds;
    self.shapeLayer.path = [self topAttachedPathForBounds:self.bounds inset:0];
    self.shapeLayer.shadowPath = self.shapeLayer.path;
    if (self.greetingOutline) {
        self.greetingOutline.frame = self.bounds;
        self.greetingOutline.path = [self topAttachedPathForBounds:self.bounds inset:1.5];
    }
}

- (void)playGreetingWithColor:(UIColor *)color {
    [self.greetingOutline removeFromSuperlayer];
    CAShapeLayer *outline = [CAShapeLayer layer];
    outline.frame = self.bounds;
    outline.path = [self topAttachedPathForBounds:self.bounds inset:1.5];
    outline.fillColor = UIColor.clearColor.CGColor;
    outline.strokeColor = color.CGColor;
    outline.lineWidth = 2.5;
    outline.strokeEnd = 0;
    [self.layer addSublayer:outline];
    self.greetingOutline = outline;

    CABasicAnimation *draw = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    draw.fromValue = @0; draw.toValue = @1; draw.duration = 0.85;
    draw.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [outline addAnimation:draw forKey:@"umn1.outline.draw"];
    outline.strokeEnd = 1;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.82 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.shapeLayer.shadowColor = color.CGColor;
        self.shapeLayer.shadowRadius = 18;
        self.shapeLayer.shadowOpacity = 0.8;
        CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"fillColor"];
        glow.fromValue = (id)self.shapeLayer.fillColor;
        glow.toValue = (id)[color colorWithAlphaComponent:0.30].CGColor;
        glow.duration = 0.38;
        [self.shapeLayer addAnimation:glow forKey:@"umn1.greeting.fill"];
        self.shapeLayer.fillColor = [color colorWithAlphaComponent:0.30].CGColor;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CABasicAnimation *restore = [CABasicAnimation animationWithKeyPath:@"fillColor"];
            restore.fromValue = (id)self.shapeLayer.fillColor;
            restore.toValue = (id)UIColor.blackColor.CGColor;
            restore.duration = 0.55;
            [self.shapeLayer addAnimation:restore forKey:@"umn1.greeting.restore"];
            self.shapeLayer.fillColor = UIColor.blackColor.CGColor;
            self.shapeLayer.shadowOpacity = 0.15;
            [self.greetingOutline removeFromSuperlayer];
            self.greetingOutline = nil;
        });
    });
}

- (void)applyTriggerColor:(UIColor *)color {
    UIColor *target = color ?: UIColor.blackColor;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"fillColor"];
    animation.fromValue = (id)self.shapeLayer.fillColor;
    animation.toValue = (id)target.CGColor;
    animation.duration = 0.22;
    [self.shapeLayer addAnimation:animation forKey:@"umn1.trigger.fill"];
    self.shapeLayer.fillColor = target.CGColor;
}

- (void)setCompactMediaArtwork:(UIImage *)artwork active:(BOOL)active {
    self.compactArtworkView.image = artwork;
    self.compactMediaStack.hidden = !active;
    if (self.visualizerRunning == active) return;
    self.visualizerRunning = active;
    for (NSUInteger index = 0; index < self.visualizerBars.count; index++) {
        UIView *bar = self.visualizerBars[index];
        [bar.layer removeAnimationForKey:@"umn1.visualizer"];
        if (active) {
            CAKeyframeAnimation *wave = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
            wave.values = @[@0.30, @0.72, @1.0, @0.46, @0.86, @0.30];
            wave.duration = 0.56 + (index * 0.075);
            wave.repeatCount = HUGE_VALF;
            wave.autoreverses = NO;
            wave.calculationMode = kCAAnimationCubic;
            wave.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [bar.layer addAnimation:wave forKey:@"umn1.visualizer"];
        }
    }
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
@property(nonatomic, assign) NSInteger emergencyTapCount;
@property(nonatomic, assign) NSTimeInterval heatDuration;
@property(nonatomic, assign) BOOL mediaEnabled;
@property(nonatomic, assign) BOOL chargingEnabled;
@property(nonatomic, assign) BOOL accessoriesEnabled;
@property(nonatomic, assign) BOOL callsEnabled;
@property(nonatomic, assign) BOOL silentEnabled;
@property(nonatomic, assign) BOOL settingsEnabled;
@property(nonatomic, assign) BOOL sosGestureEnabled;
@property(nonatomic, assign) BOOL moltenEffectEnabled;
@property(nonatomic, assign) BOOL greetingEnabled;
@property(nonatomic, assign) BOOL preferencesObserverInstalled;
@property(nonatomic, assign) BOOL mediaRequestInFlight;
@property(nonatomic, assign) NSUInteger mediaRequestGeneration;
@property(nonatomic, assign) NSInteger configuredIslandProfile;
@property(nonatomic, strong) DNOverlayWindow *explosionWindow;
@property(nonatomic, strong) NSTimer *mediaIntroTimer;
@property(nonatomic, strong) NSTimer *silentTransitionTimer;
@property(nonatomic, strong) AVAudioPlayer *explosionAudioPlayer;
@property(nonatomic, copy) NSString *mediaTrackKey;
@property(nonatomic, copy) NSString *silentTransitionTitle;
@property(nonatomic, assign) BOOL mediaCompactMode;
@property(nonatomic, assign) BOOL mediaExpandedByHold;
@property(nonatomic, assign) BOOL mediaIntroInProgress;
@property(nonatomic, assign) BOOL silentStateKnown;
@property(nonatomic, assign) BOOL silentTransitionVisible;
@property(nonatomic, assign) BOOL silentAnimationEnabled;
@property(nonatomic, assign) BOOL cameraHideEnabled;
@property(nonatomic, assign) BOOL explosionSoundEnabled;
@property(nonatomic, assign) BOOL easterEggsEnabled;
@property(nonatomic, assign) BOOL isCameraVisible;
@property(nonatomic, assign) BOOL isLandscape;

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
- (void)reloadPreferences;
- (void)refreshMediaInformation;
- (NSString *)frontmostApplicationBundleIdentifier;
- (void)endSilentTransition;
- (void)cancelHoldSequence;
- (void)configurePrimaryIndicator:(NSDictionary *)primary items:(NSArray<NSDictionary *> *)items;
- (void)playMoltenBurstSound;
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

    [self reloadPreferences];
    // Register before checking Enabled, so the Settings switch can turn the overlay back on
    // without requiring a respring after it was disabled.
    if (!self.preferencesObserverInstalled) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self),
                                        DNPreferencesChangedCallback, kDNPreferencesChangedNotification,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        self.preferencesObserverInstalled = YES;
    }
    if (!self.settingsEnabled) return;

    self.hardwareModel = DNHardwareModel();
    if (DNIsDynamicIslandModel(self.hardwareModel)) return;

    BOOL hasPhysicalIslandArea = DNHasKnownNotch(self.hardwareModel);
    self.virtualNotch = !hasPhysicalIslandArea && DNIsVirtualNotchEligibleModel(self.hardwareModel);
    if (!hasPhysicalIslandArea && !self.virtualNotch) return;

    id savedProfile = DNReadPreferences()[kDNNotchProfileDefaultsKey];
    self.shouldShowProfilePicker = (self.virtualNotch && savedProfile == nil);
    if (savedProfile && [savedProfile integerValue] != -1) {
        self.narrowNotch = ([savedProfile integerValue] == DNNotchProfileNarrow);
    } else {
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

    CGFloat collapsedWidth = self.narrowNotch ? 154.0 : 188.0;
    CGFloat collapsedHeight = self.narrowNotch ? 35.0 : 39.0;
    self.expandedWidth = MIN(CGRectGetWidth(screen) - 24.0, self.narrowNotch ? 318.0 : 342.0);
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

    // Quick two-finger shortcut is retained; the full selector is also available in Settings > Umn1Notch.
    if (self.virtualNotch) {
        UITapGestureRecognizer *profileTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                       action:@selector(handleProfileTap:)];
        profileTap.numberOfTapsRequired = 1;
        profileTap.numberOfTouchesRequired = 2;
        profileTap.cancelsTouchesInView = YES;
        [self.notch addGestureRecognizer:profileTap];
    }

    [self refreshHitRegion];
    if (self.greetingEnabled) [self.notch playGreetingWithColor:self.deviceColor];
    [self installSystemObservers];
    [self installStatusBarHooks];
    [self refreshEvents];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.25 target:self selector:@selector(pollSystemState)
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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pollSystemState)
                                                 name:UIDeviceOrientationDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pollSystemState)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
    // Private SpringBoard app-transition notifications are optional; they make
    // Camera hiding react faster than the periodic fallback poll when available.
    for (NSString *notificationName in @[@"SBApplicationDidActivate", @"SBApplicationDidDeactivate",
                                         @"SBApplicationDidLaunch", @"SBApplicationDidTerminate"]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pollSystemState)
                                                     name:notificationName object:nil];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMediaInformation)
                                                 name:@"SBMediaControllerNowPlayingInfoDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMediaInformation)
                                                 name:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification" object:nil];
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), (__bridge const void *)(self),
                                    DNMediaRemoteChangedCallback,
                                    CFSTR("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
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
    if (!self.settingsEnabled) return;
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
    BOOL silentValueAvailable = NO;
    BOOL mutedNow = self.silentActive;
    if (mediaControllerClass && [mediaControllerClass respondsToSelector:sharedSelector]) {
        id mediaController = ((id (*)(id, SEL))objc_msgSend)(mediaControllerClass, sharedSelector);
        if ([mediaController respondsToSelector:mutedSelector]) {
            mutedNow = ((BOOL (*)(id, SEL))objc_msgSend)(mediaController, mutedSelector);
            silentValueAvailable = YES;
        }
    }
    // On iOS 13+, SpringBoard commonly exposes SBRingerControl from its workspace.
    // Resolve it dynamically so this source does not need private framework headers.
    if (!silentValueAvailable) {
        Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
        SEL workspaceShared = NSSelectorFromString(@"sharedInstance");
        id workspace = (workspaceClass && [workspaceClass respondsToSelector:workspaceShared])
            ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, workspaceShared) : nil;
        for (NSString *controlSelectorName in @[@"ringerControl", @"soundController"]) {
            SEL controlSelector = NSSelectorFromString(controlSelectorName);
            id ringerControl = (workspace && [workspace respondsToSelector:controlSelector])
                ? ((id (*)(id, SEL))objc_msgSend)(workspace, controlSelector) : nil;
            for (NSString *stateSelectorName in @[@"isRingerMuted", @"ringerMuted", @"isMuted", @"lastSavedRingerMutedState"]) {
                SEL stateSelector = NSSelectorFromString(stateSelectorName);
                if (ringerControl && [ringerControl respondsToSelector:stateSelector]) {
                    mutedNow = ((BOOL (*)(id, SEL))objc_msgSend)(ringerControl, stateSelector);
                    silentValueAvailable = YES;
                    break;
                }
            }
            if (silentValueAvailable) break;
        }
    }
    // A few iOS builds expose the state on SBSilentModeController instead.
    if (!silentValueAvailable) {
        Class silentClass = NSClassFromString(@"SBSilentModeController");
        SEL silentShared = NSSelectorFromString(@"sharedInstance");
        id silentController = (silentClass && [silentClass respondsToSelector:silentShared])
            ? ((id (*)(id, SEL))objc_msgSend)(silentClass, silentShared) : nil;
        for (NSString *selectorName in @[@"isSilentModeEnabled", @"isRingerMuted", @"isSilent"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (silentController && [silentController respondsToSelector:selector]) {
                mutedNow = ((BOOL (*)(id, SEL))objc_msgSend)(silentController, selector);
                silentValueAvailable = YES;
                break;
            }
        }
    }
    if (silentValueAvailable) {
        if (self.silentStateKnown && mutedNow != self.silentActive && self.silentEnabled && self.silentAnimationEnabled) {
            self.silentTransitionVisible = YES;
            self.silentTransitionTitle = mutedNow ? @"Silent Mode On" : @"Silent Mode Off";
            [self.silentTransitionTimer invalidate];
            self.silentTransitionTimer = [NSTimer scheduledTimerWithTimeInterval:1.35
                target:self selector:@selector(endSilentTransition) userInfo:nil repeats:NO];
        }
        self.silentActive = mutedNow;
        self.silentStateKnown = YES;
    }

    UIInterfaceOrientation orientation = UIApplication.sharedApplication.statusBarOrientation;
    self.isLandscape = UIInterfaceOrientationIsLandscape(orientation);
    NSString *frontmostBundle = [self frontmostApplicationBundleIdentifier];
    self.isCameraVisible = [frontmostBundle isEqualToString:@"com.apple.camera"];
    BOOL shouldHideForCamera = self.cameraHideEnabled && self.isCameraVisible;
    BOOL shouldHideForRotation = self.isLandscape;
    if (shouldHideForCamera || shouldHideForRotation || !self.settingsEnabled) {
        [self cancelHoldSequence];
        self.tapCount = 0;
    }
    self.window.hidden = !self.settingsEnabled || shouldHideForCamera || shouldHideForRotation;
    if (self.window.hidden) {
        self.tapCount = 0;
        [self.notch setCompactMediaArtwork:nil active:NO];
        [self setStatusBarAvoidanceExpanded:NO];
        [self refreshHitRegion];
    }

    [self refreshMediaInformation];
    [self refreshEvents];
}

- (NSString *)frontmostApplicationBundleIdentifier {
    NSArray<NSString *> *classNames = @[@"SBMainWorkspace", @"SBApplicationController", @"SpringBoard"];
    NSArray<NSString *> *selectors = @[@"activeApplicationBundleIdentifier", @"frontmostApplicationBundleIdentifier"];
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        SEL shared = NSSelectorFromString(@"sharedInstance");
        id object = (cls && [cls respondsToSelector:shared]) ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
        if (!object) continue;
        for (NSString *selectorName in selectors) {
            SEL selector = NSSelectorFromString(selectorName);
            if ([object respondsToSelector:selector]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
                if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
            }
        }
        for (NSString *applicationSelectorName in @[@"frontmostApplication", @"activeApplication", @"foregroundApplication"]) {
            SEL applicationSelector = NSSelectorFromString(applicationSelectorName);
            if (![object respondsToSelector:applicationSelector]) continue;
            id app = ((id (*)(id, SEL))objc_msgSend)(object, applicationSelector);
            for (NSString *bundleSelectorName in @[@"bundleIdentifier", @"applicationBundleID"]) {
                SEL bundleID = NSSelectorFromString(bundleSelectorName);
                if (![app respondsToSelector:bundleID]) continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(app, bundleID);
                if ([value isKindOfClass:NSString.class]) return value;
            }
        }
    }
    return nil;
}

- (void)endSilentTransition {
    self.silentTransitionVisible = NO;
    self.silentTransitionTimer = nil;
    [self refreshEvents];
}

- (void)refreshMediaInformation {
    if (!self.mediaEnabled) {
        self.mediaPlaying = NO;
        self.mediaTitle = nil;
        self.mediaArtwork = nil;
        [self refreshEvents];
        return;
    }

    static void *mediaRemoteHandle = NULL;
    typedef void (*DNMediaRemoteGetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
    typedef void (*DNMediaRemoteRegisterForNowPlayingNotifications)(dispatch_queue_t);
    static DNMediaRemoteGetNowPlayingInfo getInfo = NULL;
    static DNMediaRemoteRegisterForNowPlayingNotifications registerForNowPlaying = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaRemoteHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mediaRemoteHandle) {
            getInfo = (DNMediaRemoteGetNowPlayingInfo)dlsym(mediaRemoteHandle, "MRMediaRemoteGetNowPlayingInfo");
            registerForNowPlaying = (DNMediaRemoteRegisterForNowPlayingNotifications)dlsym(mediaRemoteHandle, "MRMediaRemoteRegisterForNowPlayingNotifications");
            if (registerForNowPlaying) registerForNowPlaying(dispatch_get_main_queue());
        }
    });

    if (getInfo && !self.mediaRequestInFlight) {
        self.mediaRequestInFlight = YES;
        NSUInteger requestGeneration = ++self.mediaRequestGeneration;
        __weak typeof(self) weakSelf = self;
        getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef information) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.mediaRequestGeneration != requestGeneration) return;
            self.mediaRequestInFlight = NO;
            NSDictionary *info = information ? [(__bridge NSDictionary *)information copy] : @{};
            if (info.count == 0) {
                [self refreshMediaFallback];
                [self refreshEvents];
                return;
            }
            NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: info[MPNowPlayingInfoPropertyPlaybackRate];
            id titleValue = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: info[MPMediaItemPropertyTitle] ?: info[@"title"];
            id artistValue = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: info[MPMediaItemPropertyArtist] ?: info[@"artist"];
            NSString *title = [titleValue isKindOfClass:NSString.class] ? titleValue : nil;
            NSString *artist = [artistValue isKindOfClass:NSString.class] ? artistValue : nil;
            id artworkObject = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] ?: info[@"kMRMediaRemoteNowPlayingInfoArtwork"] ?: info[MPMediaItemPropertyArtwork];
            UIImage *artwork = nil;
            if ([artworkObject isKindOfClass:NSData.class]) artwork = [UIImage imageWithData:artworkObject];
            else if ([artworkObject isKindOfClass:UIImage.class]) artwork = artworkObject;
            else if ([artworkObject isKindOfClass:MPMediaItemArtwork.class]) artwork = [artworkObject imageWithSize:CGSizeMake(64, 64)];

            self.mediaTitle = title.length ? (artist.length ? [NSString stringWithFormat:@"%@ — %@", title, artist] : title) : @"Now Playing";
            self.mediaArtwork = artwork;
            if (rate) self.mediaPlaying = rate.doubleValue > 0.0;
            else [self refreshMediaFallback];
            [self refreshEvents];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !self.mediaRequestInFlight || self.mediaRequestGeneration != requestGeneration) return;
            self.mediaRequestInFlight = NO;
            [self refreshMediaFallback];
            [self refreshEvents];
        });
        return;
    }

    // Fallback to SpringBoard's media controller on iOS builds where MediaRemote is unavailable.
    [self refreshMediaFallback];
}

- (void)refreshMediaFallback {
    Class mediaClass = NSClassFromString(@"SBMediaController");
    id mediaController = nil;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (mediaClass && [mediaClass respondsToSelector:shared]) {
        mediaController = ((id (*)(id, SEL))objc_msgSend)(mediaClass, shared);
    }

    SEL isPlayingSelector = NSSelectorFromString(@"isPlaying");
    if (mediaController && [mediaController respondsToSelector:isPlayingSelector]) {
        self.mediaPlaying = ((BOOL (*)(id, SEL))objc_msgSend)(mediaController, isPlayingSelector);
    }

    NSDictionary *fallbackInfo = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    SEL currentInfoSelector = NSSelectorFromString(@"currentNowPlayingInfo");
    SEL nowPlayingInfoSelector = NSSelectorFromString(@"nowPlayingInfo");
    if (mediaController && [mediaController respondsToSelector:currentInfoSelector]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(mediaController, currentInfoSelector);
        if ([candidate isKindOfClass:NSDictionary.class] && [candidate count] > 0) fallbackInfo = candidate;
    } else if (mediaController && [mediaController respondsToSelector:nowPlayingInfoSelector]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(mediaController, nowPlayingInfoSelector);
        if ([candidate isKindOfClass:NSDictionary.class] && [candidate count] > 0) fallbackInfo = candidate;
    }

    id fallbackTitleValue = fallbackInfo[MPMediaItemPropertyTitle] ?: fallbackInfo[@"title"];
    id fallbackArtistValue = fallbackInfo[MPMediaItemPropertyArtist] ?: fallbackInfo[@"artist"];
    NSString *fallbackTitle = [fallbackTitleValue isKindOfClass:NSString.class] ? fallbackTitleValue : nil;
    NSString *fallbackArtist = [fallbackArtistValue isKindOfClass:NSString.class] ? fallbackArtistValue : nil;

    // Some iOS 15 SpringBoard builds expose metadata as individual selectors instead
    // of a complete nowPlayingInfo dictionary.
    if (fallbackTitle.length == 0 && mediaController) {
        SEL titleSelector = NSSelectorFromString(@"nowPlayingTitle");
        if ([mediaController respondsToSelector:titleSelector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(mediaController, titleSelector);
            if ([value isKindOfClass:NSString.class]) fallbackTitle = value;
        }
    }
    if (fallbackArtist.length == 0 && mediaController) {
        SEL artistSelector = NSSelectorFromString(@"nowPlayingArtist");
        if ([mediaController respondsToSelector:artistSelector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(mediaController, artistSelector);
            if ([value isKindOfClass:NSString.class]) fallbackArtist = value;
        }
    }

    if (fallbackTitle.length > 0 || fallbackArtist.length > 0) {
        self.mediaTitle = fallbackTitle.length ? (fallbackArtist.length ? [NSString stringWithFormat:@"%@ — %@", fallbackTitle, fallbackArtist] : fallbackTitle) : fallbackArtist;
        id artworkValue = fallbackInfo[MPMediaItemPropertyArtwork] ?: fallbackInfo[@"artwork"] ?: fallbackInfo[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([artworkValue isKindOfClass:MPMediaItemArtwork.class]) {
            self.mediaArtwork = [(MPMediaItemArtwork *)artworkValue imageWithSize:CGSizeMake(64, 64)];
        } else if ([artworkValue isKindOfClass:UIImage.class]) {
            self.mediaArtwork = artworkValue;
        } else if ([artworkValue isKindOfClass:NSData.class]) {
            self.mediaArtwork = [UIImage imageWithData:artworkValue];
        }
        NSNumber *rate = fallbackInfo[MPNowPlayingInfoPropertyPlaybackRate] ?: fallbackInfo[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        if (rate) self.mediaPlaying = rate.doubleValue > 0.0;
        else if (mediaController && [mediaController respondsToSelector:isPlayingSelector]) {
            self.mediaPlaying = ((BOOL (*)(id, SEL))objc_msgSend)(mediaController, isPlayingSelector);
        } else {
            self.mediaPlaying = YES;
        }
    } else if (self.mediaPlaying) {
        self.mediaTitle = @"Now Playing";
        self.mediaArtwork = nil;
    } else {
        self.mediaTitle = nil;
        self.mediaArtwork = nil;
    }
}

- (void)reloadPreferences {
    self.settingsEnabled = DNPreferenceBool(@"Enabled", YES);
    self.sosGestureEnabled = DNPreferenceBool(@"EnableSOSGesture", YES);
    self.moltenEffectEnabled = DNPreferenceBool(@"EnableMoltenEffect", YES);
    self.greetingEnabled = DNPreferenceBool(@"EnableGreeting", YES);
    self.emergencyTapCount = MAX(5, MIN(25, DNPreferenceInteger(@"EmergencyTapCount", 5)));
    self.heatDuration = MAX(2.5, MIN(8.0, [DNPreferenceValue(@"HeatDuration", @4.5) doubleValue]));
    self.mediaEnabled = DNPreferenceBool(@"EnableMediaPlayer", YES);
    self.chargingEnabled = DNPreferenceBool(@"EnableCharging", YES);
    self.accessoriesEnabled = DNPreferenceBool(@"EnableAccessories", YES);
    self.callsEnabled = DNPreferenceBool(@"EnableCalls", YES);
    self.silentEnabled = DNPreferenceBool(@"EnableSilentMode", YES);
    self.silentAnimationEnabled = DNPreferenceBool(@"EnableSilentAnimation", YES);
    self.cameraHideEnabled = DNPreferenceBool(@"HideInCamera", YES);
    self.explosionSoundEnabled = DNPreferenceBool(@"EnableExplosionSound", YES);
    self.easterEggsEnabled = DNPreferenceBool(@"EnableEasterEggs", YES);

    id profile = DNReadPreferences()[kDNNotchProfileDefaultsKey];
    self.configuredIslandProfile = profile ? [profile integerValue] : -1;
    if (self.window && profile) {
        BOOL newNarrow = ([profile integerValue] == -1)
            ? DNHasNarrowNotch(self.hardwareModel)
            : ([profile integerValue] == DNNotchProfileNarrow);
        if (newNarrow != self.narrowNotch) {
            self.narrowNotch = newNarrow;
            CGRect screen = UIScreen.mainScreen.bounds;
            self.expandedWidth = MIN(CGRectGetWidth(screen) - 24.0, self.narrowNotch ? 318.0 : 342.0);
            [self setExpanded:self.expanded animated:YES];
        }
    }
    if (self.window) {
        if (!self.settingsEnabled) {
            [self setExpanded:NO animated:YES];
            self.window.hidden = YES;
            [self setStatusBarAvoidanceExpanded:NO];
            self.tapCount = 0;
        } else {
            self.window.hidden = NO;
            [self refreshEvents];
        }
    }
}

- (NSArray<NSDictionary *> *)activeIndicators {
    NSMutableArray *items = [NSMutableArray array];
    if (self.chargingEnabled && self.charging) [items addObject:@{@"priority": @(DNTriggerPriorityCharging), @"title": @"Charging", @"detail": @"Power connected", @"symbol": @"bolt.fill"}];
    if (self.accessoriesEnabled && self.accessoryConnected) [items addObject:@{@"priority": @(DNTriggerPriorityAccessory), @"title": @"Accessory", @"detail": @"Audio device connected", @"symbol": @"headphones"}];
    if (self.callsEnabled && self.callActive) [items addObject:@{@"priority": @(DNTriggerPriorityCall), @"title": @"Call", @"detail": @"Active call", @"symbol": @"phone.fill"}];
    if (self.silentEnabled && self.silentTransitionVisible) {
        [items addObject:@{@"priority": @(DNTriggerPrioritySilent), @"title": self.silentTransitionTitle ?: (self.silentActive ? @"Silent Mode On" : @"Silent Mode Off"), @"detail": self.silentActive ? @"Ringer muted" : @"Ringer enabled", @"symbol": self.silentActive ? @"bell.slash.fill" : @"bell.fill"}];
    }
    if (self.mediaEnabled && self.mediaPlaying) [items addObject:@{@"priority": @(DNTriggerPriorityMedia), @"title": self.mediaTitle ?: @"Now Playing", @"detail": @"Playing", @"symbol": @"waveform"}];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"priority"] compare:a[@"priority"]];
    }];
    return items;
}

- (void)configurePrimaryIndicator:(NSDictionary *)primary items:(NSArray<NSDictionary *> *)items {
    self.notch.titleLabel.text = primary[@"title"];
    self.notch.detailLabel.text = primary[@"detail"];
    self.notch.titleLabel.hidden = NO;
    self.notch.detailLabel.hidden = NO;
    self.notch.iconStack.hidden = NO;
    NSInteger maximumIcons = self.narrowNotch ? 4 : 2;
    NSInteger count = MIN(items.count, maximumIcons);
    for (UIView *view in self.notch.iconStack.arrangedSubviews) {
        [self.notch.iconStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSInteger index = 0; index < count; index++) {
        NSString *symbol = items[index][@"symbol"];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        icon.tintColor = UIColor.whiteColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [icon.widthAnchor constraintEqualToConstant:15].active = YES;
        [icon.heightAnchor constraintEqualToConstant:15].active = YES;
        [self.notch.iconStack addArrangedSubview:icon];
    }
    self.notch.artworkView.image = ([primary[@"priority"] integerValue] == DNTriggerPriorityMedia) ? self.mediaArtwork : nil;
    self.notch.artworkView.hidden = (self.notch.artworkView.image == nil);
}

- (void)cancelHoldSequence {
    if (!self.holdActive) return;
    self.holdActive = NO;
    self.detonationFinished = YES; // Invalidates the delayed detonation callback.
    CALayer *presentation = self.notch.shapeLayer.presentationLayer;
    CGColorRef visibleColor = presentation ? ((CAShapeLayer *)presentation).fillColor : self.notch.shapeLayer.fillColor;
    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.color"];
    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glow"];
    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glowColor"];
    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glowOpacity"];
    CABasicAnimation *reset = [CABasicAnimation animationWithKeyPath:@"fillColor"];
    reset.fromValue = visibleColor ? (__bridge id)visibleColor : (id)UIColor.blackColor.CGColor;
    reset.toValue = (id)UIColor.blackColor.CGColor;
    reset.duration = 0.24;
    [self.notch.shapeLayer addAnimation:reset forKey:@"umn1.heat.interrupted"];
    self.notch.shapeLayer.fillColor = UIColor.blackColor.CGColor;
    self.notch.shapeLayer.shadowColor = UIColor.blackColor.CGColor;
    self.notch.shapeLayer.shadowOpacity = 0.15;
    self.notch.shapeLayer.shadowRadius = 3;
}

- (void)refreshEvents {
    if (!self.notch || !self.settingsEnabled || self.window.hidden) return;
    NSArray<NSDictionary *> *items = [self activeIndicators];
    if (items.count > 0) {
        [self cancelHoldSequence];
        self.tapCount = 0;
    }
    if (items.count == 0) {
        [self.mediaIntroTimer invalidate]; self.mediaIntroTimer = nil;
        self.mediaIntroInProgress = NO;
        self.mediaCompactMode = NO;
        self.mediaExpandedByHold = NO;
        self.mediaTrackKey = nil;
        self.notch.titleLabel.hidden = YES;
        self.notch.detailLabel.hidden = YES;
        self.notch.iconStack.hidden = YES;
        self.notch.artworkView.hidden = YES;
        [self.notch setCompactMediaArtwork:nil active:NO];
        [self.notch applyTriggerColor:UIColor.blackColor];
        [self setExpanded:NO animated:YES];
        return;
    }

    NSDictionary *primary = items.firstObject;
    BOOL mediaIsPrimary = [primary[@"priority"] integerValue] == DNTriggerPriorityMedia;
    BOOL mediaIsOnlyTrigger = mediaIsPrimary && items.count == 1;

    if (mediaIsOnlyTrigger) {
        NSString *trackKey = self.mediaTitle ?: @"unknown-track";
        if (![self.mediaTrackKey isEqualToString:trackKey]) {
            self.mediaTrackKey = trackKey;
            self.mediaIntroInProgress = YES;
            self.mediaCompactMode = NO;
            self.mediaExpandedByHold = NO;
            [self configurePrimaryIndicator:primary items:items];
            [self.notch setCompactMediaArtwork:self.mediaArtwork active:NO];
            [self setExpanded:YES animated:YES];
            [self.mediaIntroTimer invalidate];
            __weak typeof(self) weakSelf = self;
            self.mediaIntroTimer = [NSTimer scheduledTimerWithTimeInterval:0.82 repeats:NO block:^(NSTimer *timer) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || !self.mediaPlaying || self.callActive || self.charging || self.accessoryConnected) return;
                self.mediaIntroInProgress = NO;
                self.mediaCompactMode = !self.mediaExpandedByHold;
                [self refreshEvents];
            }];
            return;
        }
        if (self.mediaIntroInProgress) {
            [self configurePrimaryIndicator:primary items:items];
            [self setExpanded:YES animated:YES];
            return;
        }
        if (self.mediaExpandedByHold) {
            self.mediaCompactMode = NO;
            [self configurePrimaryIndicator:primary items:items];
            [self.notch setCompactMediaArtwork:self.mediaArtwork active:NO];
            [self setExpanded:YES animated:YES];
            return;
        }
        self.mediaCompactMode = YES;
        self.notch.titleLabel.hidden = YES;
        self.notch.detailLabel.hidden = YES;
        self.notch.iconStack.hidden = YES;
        self.notch.artworkView.hidden = YES;
        [self.notch setCompactMediaArtwork:self.mediaArtwork active:YES];
        [self setExpanded:NO animated:YES];
        return;
    }

    [self.mediaIntroTimer invalidate]; self.mediaIntroTimer = nil;
    self.mediaIntroInProgress = NO;
    self.mediaCompactMode = NO;
    self.mediaExpandedByHold = NO;
    [self.notch setCompactMediaArtwork:nil active:NO];
    [self configurePrimaryIndicator:primary items:items];
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
    CGFloat width;
    CGFloat height;
    if (self.mediaCompactMode && !expanded) {
        width = self.narrowNotch ? 150.0 : 164.0;
        height = 43.0;
    } else if (expanded) {
        width = MIN(self.expandedWidth, CGRectGetWidth(screen) - 24.0);
        height = 100.0;
    } else {
        width = self.narrowNotch ? 154.0 : 188.0;
        height = self.narrowNotch ? 35.0 : 39.0;
    }

    CGRect targetBounds = CGRectMake(0, 0, width, height);
    // The notch remains attached to the top edge; only its lower edge moves.
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
        boundsAnimation.damping = 24;
        boundsAnimation.stiffness = 245;
        boundsAnimation.mass = 1;
        boundsAnimation.initialVelocity = 0.25;
        boundsAnimation.duration = boundsAnimation.settlingDuration;
        [self.notch.layer addAnimation:boundsAnimation forKey:@"umn1.notch.spring.bounds"];

        CASpringAnimation *positionAnimation = [CASpringAnimation animationWithKeyPath:@"position"];
        positionAnimation.fromValue = [NSValue valueWithCGPoint:currentPosition];
        positionAnimation.toValue = [NSValue valueWithCGPoint:targetPosition];
        positionAnimation.damping = 24;
        positionAnimation.stiffness = 245;
        positionAnimation.mass = 1;
        positionAnimation.duration = boundsAnimation.duration;
        [self.notch.layer addAnimation:positionAnimation forKey:@"umn1.notch.spring.position"];
    }
    self.notch.layer.bounds = targetBounds;
    self.notch.layer.position = targetPosition;

    BOOL hasItems = [self activeIndicators].count > 0;
    BOOL compactMedia = self.mediaCompactMode && self.mediaPlaying && !expanded;
    self.notch.titleLabel.hidden = !expanded || !hasItems;
    self.notch.detailLabel.hidden = !expanded || !hasItems;
    self.notch.iconStack.hidden = !expanded || !hasItems;
    self.notch.headerStack.hidden = !expanded || !hasItems;
    [self.notch setCompactMediaArtwork:self.mediaArtwork active:compactMedia];
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
                                                                     message:@"This iPhone has no physical notch. Umn1Notch can display a virtual notch attached to the top edge. Change its profile any time in Settings → Umn1Notch."
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    [picker addAction:[UIAlertAction actionWithTitle:@"Use device default"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self setAutomaticIslandProfile];
    }]];
    [picker addAction:[UIAlertAction actionWithTitle:@"Wide Notch — iPhone X–12"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self selectNotchProfile:DNNotchProfileWide];
    }]];
    [picker addAction:[UIAlertAction actionWithTitle:@"Compact Notch — iPhone 13–14"
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
    DNWritePreference(kDNNotchProfileDefaultsKey, @(profile));

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat collapsedWidth = self.narrowNotch ? 154.0 : 188.0;
    CGFloat collapsedHeight = self.narrowNotch ? 35.0 : 39.0;
    CGFloat preferredExpandedWidth = self.narrowNotch ? 318.0 : 342.0;
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
    if (self.greetingEnabled) [self.notch playGreetingWithColor:self.deviceColor];
}

- (void)setAutomaticIslandProfile {
    DNWritePreference(kDNNotchProfileDefaultsKey, @(-1));
    self.narrowNotch = DNHasNarrowNotch(self.hardwareModel);
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat width = self.narrowNotch ? 318.0 : 342.0;
    self.expandedWidth = MIN(CGRectGetWidth(screen) - 24.0, width);
    CGFloat collapsedWidth = self.narrowNotch ? 154.0 : 188.0;
    CGFloat collapsedHeight = self.narrowNotch ? 35.0 : 39.0;
    [self setExpanded:self.expanded animated:YES];
    if (!self.expanded) {
        self.notch.layer.bounds = CGRectMake(0, 0, collapsedWidth, collapsedHeight);
        self.notch.layer.position = CGPointMake(CGRectGetMidX(screen), collapsedHeight / 2.0);
        self.notch.layer.cornerRadius = collapsedHeight / 2.0;
        [self refreshHitRegion];
    }
}

#pragma mark - Emergency tap confirmation

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    if (!self.sosGestureEnabled || !self.easterEggsEnabled || recognizer.state != UIGestureRecognizerStateEnded) return;
    // Easter-egg gestures are disabled while charging, connected to an accessory,
    // in a call, during a silent-mode transition, or while media is active.
    if ([self activeIndicators].count > 0 || self.mediaIntroInProgress || self.isCameraVisible || self.isLandscape) {
        self.tapCount = 0;
        return;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.lastTapTime > 3.0) self.tapCount = 0;
    self.lastTapTime = now;
    self.tapCount += 1;
    if (self.tapCount >= self.emergencyTapCount) {
        self.tapCount = 0;
        [self presentSOSDemo];
    }
}

- (void)presentSOSDemo {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback prepare];
    [feedback impactOccurred];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Call emergency services?"
                                                                   message:@"Use this only for a genuine emergency. Calling is never automatic: you must confirm this action explicitly."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Call emergency services (112)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        UIImpactFeedbackGenerator *confirm = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [confirm impactOccurred];
        NSURL *phoneURL = [NSURL URLWithString:@"tel:112"];
        // The system phone UI is opened only from this explicit confirmation action.
        [UIApplication.sharedApplication openURL:phoneURL options:@{} completionHandler:nil];
    }]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Long-press sequence and decorative burst

- (void)handleHold:(UILongPressGestureRecognizer *)recognizer {
    NSArray<NSDictionary *> *items = [self activeIndicators];
    BOOL mediaOnly = (items.count == 1 && [items.firstObject[@"priority"] integerValue] == DNTriggerPriorityMedia);

    if (mediaOnly) {
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            self.mediaExpandedByHold = YES;
            self.mediaCompactMode = NO;
            [self refreshEvents];
        } else if (recognizer.state == UIGestureRecognizerStateEnded ||
                   recognizer.state == UIGestureRecognizerStateCancelled ||
                   recognizer.state == UIGestureRecognizerStateFailed) {
            self.mediaExpandedByHold = NO;
            self.mediaCompactMode = YES;
            [self refreshEvents];
        }
        return;
    }

    // Never start Easter eggs while any system trigger is active.
    if (items.count > 0 || !self.easterEggsEnabled || !self.moltenEffectEnabled ||
        self.isCameraVisible || self.isLandscape) return;

    if (recognizer.state == UIGestureRecognizerStateBegan) {
        self.holdActive = YES;
        self.detonationFinished = NO;
        [self beginHoldSequence];
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled ||
               recognizer.state == UIGestureRecognizerStateFailed) {
        self.holdActive = NO;
        if (!self.detonationFinished) {
            [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.color"];
            [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glow"];
            [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glowColor"];
            [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glowOpacity"];
            CABasicAnimation *reset = [CABasicAnimation animationWithKeyPath:@"fillColor"];
            reset.fromValue = (id)self.notch.shapeLayer.presentationLayer.fillColor;
            reset.toValue = (id)UIColor.blackColor.CGColor;
            reset.duration = 0.28;
            [self.notch.shapeLayer addAnimation:reset forKey:@"umn1.heat.reset"];
            self.notch.shapeLayer.fillColor = UIColor.blackColor.CGColor;
            self.notch.shapeLayer.shadowOpacity = 0.12;
            self.notch.shapeLayer.shadowRadius = 2;
        }
    }
}

- (void)beginHoldSequence {
    // Continuous blackbody-style heating: charcoal -> deep red -> orange -> yellow -> white-hot.
    NSArray<UIColor *> *heatColors = @[
        [UIColor colorWithWhite:0.015 alpha:1],
        [UIColor colorWithRed:0.24 green:0.005 blue:0.008 alpha:1],
        [UIColor colorWithRed:0.68 green:0.025 blue:0.008 alpha:1],
        [UIColor colorWithRed:1.0 green:0.19 blue:0.015 alpha:1],
        [UIColor colorWithRed:1.0 green:0.66 blue:0.12 alpha:1],
        [UIColor colorWithRed:1.0 green:0.96 blue:0.78 alpha:1],
        UIColor.whiteColor
    ];
    NSMutableArray *cgColors = [NSMutableArray array];
    for (UIColor *color in heatColors) [cgColors addObject:(id)color.CGColor];

    self.notch.shapeLayer.fillColor = heatColors.firstObject.CGColor;
    self.notch.shapeLayer.shadowColor = [UIColor colorWithRed:1 green:0.20 blue:0.015 alpha:1].CGColor;
    self.notch.shapeLayer.shadowOffset = CGSizeZero;
    self.notch.shapeLayer.shadowOpacity = 0.15;
    self.notch.shapeLayer.shadowRadius = 2;

    CAKeyframeAnimation *heat = [CAKeyframeAnimation animationWithKeyPath:@"fillColor"];
    heat.values = cgColors;
    heat.keyTimes = @[@0.0, @0.12, @0.30, @0.49, @0.68, @0.87, @1.0];
    heat.duration = self.heatDuration;
    heat.calculationMode = kCAAnimationLinear;
    heat.fillMode = kCAFillModeForwards;
    heat.removedOnCompletion = NO;
    [self.notch.shapeLayer addAnimation:heat forKey:@"umn1.heat.color"];

    CAKeyframeAnimation *glow = [CAKeyframeAnimation animationWithKeyPath:@"shadowRadius"];
    glow.values = @[@2, @4, @8, @13, @19, @25];
    glow.keyTimes = @[@0.0, @0.18, @0.38, @0.58, @0.80, @1.0];
    glow.duration = self.heatDuration;
    glow.fillMode = kCAFillModeForwards;
    glow.removedOnCompletion = NO;
    [self.notch.shapeLayer addAnimation:glow forKey:@"umn1.heat.glow"];

    CAKeyframeAnimation *glowColor = [CAKeyframeAnimation animationWithKeyPath:@"shadowColor"];
    glowColor.values = @[
        (id)[UIColor colorWithRed:0.18 green:0.005 blue:0.01 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.75 green:0.025 blue:0.008 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.25 blue:0.015 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.78 blue:0.35 alpha:1].CGColor,
        (id)UIColor.whiteColor.CGColor
    ];
    glowColor.keyTimes = @[@0.0, @0.30, @0.55, @0.82, @1.0];
    glowColor.duration = self.heatDuration;
    glowColor.fillMode = kCAFillModeForwards;
    glowColor.removedOnCompletion = NO;
    [self.notch.shapeLayer addAnimation:glowColor forKey:@"umn1.heat.glowColor"];

    CAKeyframeAnimation *glowOpacity = [CAKeyframeAnimation animationWithKeyPath:@"shadowOpacity"];
    glowOpacity.values = @[@0.12, @0.28, @0.48, @0.72, @0.95];
    glowOpacity.keyTimes = @[@0.0, @0.22, @0.48, @0.75, @1.0];
    glowOpacity.duration = self.heatDuration;
    glowOpacity.fillMode = kCAFillModeForwards;
    glowOpacity.removedOnCompletion = NO;
    [self.notch.shapeLayer addAnimation:glowOpacity forKey:@"umn1.heat.glowOpacity"];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.heatDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.holdActive || self.detonationFinished) return;
        self.detonationFinished = YES;
        self.holdActive = NO;
        self.notch.shapeLayer.fillColor = UIColor.whiteColor.CGColor;
        UIImpactFeedbackGenerator *impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [impact prepare];
        [impact impactOccurred];
        [self showDecorativeBurst];
    });
}

- (void)playMoltenBurstSound {
    if (!self.explosionSoundEnabled) return;
    NSError *sessionError = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback
              withOptions:AVAudioSessionCategoryOptionMixWithOthers
                    error:&sessionError];
    [session setActive:YES error:nil];
    NSError *playerError = nil;
    self.explosionAudioPlayer = [[AVAudioPlayer alloc] initWithData:DNCreateMoltenBurstAudio() error:&playerError];
    self.explosionAudioPlayer.volume = 0.72;
    [self.explosionAudioPlayer prepareToPlay];
    [self.explosionAudioPlayer play];
}

- (UIImage *)particleImage {
    CGSize size = CGSizeMake(34, 52);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect shape = CGRectMake(7, 3, 20, 46);
    UIBezierPath *drop = [UIBezierPath bezierPath];
    [drop moveToPoint:CGPointMake(CGRectGetMidX(shape), CGRectGetMinY(shape))];
    [drop addCurveToPoint:CGPointMake(CGRectGetMaxX(shape), CGRectGetMidY(shape))
            controlPoint1:CGPointMake(CGRectGetMaxX(shape), CGRectGetMinY(shape) + 5)
            controlPoint2:CGPointMake(CGRectGetMaxX(shape), CGRectGetMidY(shape) - 8)];
    [drop addCurveToPoint:CGPointMake(CGRectGetMinX(shape), CGRectGetMidY(shape))
            controlPoint1:CGPointMake(CGRectGetMaxX(shape) - 3, CGRectGetMaxY(shape))
            controlPoint2:CGPointMake(CGRectGetMinX(shape), CGRectGetMidY(shape) + 8)];
    [drop addCurveToPoint:CGPointMake(CGRectGetMidX(shape), CGRectGetMinY(shape))
            controlPoint1:CGPointMake(CGRectGetMinX(shape), CGRectGetMinY(shape) + 5)
            controlPoint2:CGPointMake(CGRectGetMidX(shape), CGRectGetMinY(shape))];
    [drop closePath];

    CGContextSaveGState(context);
    [drop addClip];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[] = {
        0.18, 0.015, 0.012, 1,
        0.95, 0.055, 0.018, 1,
        1.0, 0.34, 0.12, 1,
        0.46, 0.012, 0.018, 1
    };
    CGFloat locations[] = {0, 0.38, 0.62, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 4);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 0), CGPointMake(size.width, size.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(context);

    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.88].CGColor);
    CGContextSetLineWidth(context, 2.0);
    CGContextMoveToPoint(context, 15, 12);
    CGContextAddCurveToPoint(context, 11, 20, 12, 29, 15, 36);
    CGContextStrokePath(context);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)showDecorativeBurst {
    [self playMoltenBurstSound];
    CGRect screen = UIScreen.mainScreen.bounds;
    DNOverlayWindow *burstWindow = [[DNOverlayWindow alloc] initWithFrame:screen];
    burstWindow.windowLevel = UIWindowLevelAlert + 20;
    burstWindow.backgroundColor = UIColor.clearColor;
    burstWindow.hitTestRect = CGRectZero;
    DNRootViewController *root = [DNRootViewController new];
    burstWindow.rootViewController = root;
    burstWindow.hidden = NO;
    self.explosionWindow = burstWindow;

    // A soft flash and a plume of stylized molten-metal droplets erupt from the top-attached notch.
    UIView *flash = [[UIView alloc] initWithFrame:root.view.bounds];
    flash.userInteractionEnabled = NO;
    flash.backgroundColor = [UIColor colorWithRed:0.55 green:0.015 blue:0.018 alpha:0.16];
    flash.alpha = 0;
    [root.view addSubview:flash];
    [UIView animateWithDuration:0.12 animations:^{ flash.alpha = 1.0; } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.75 animations:^{ flash.alpha = 0.0; }];
    }];

    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.frame = root.view.bounds;
    emitter.emitterPosition = CGPointMake(CGRectGetMidX(screen), CGRectGetMinY(self.notch.frame) + CGRectGetHeight(self.notch.frame) + 3.0);
    emitter.emitterShape = kCAEmitterLayerLine;
    emitter.emitterMode = kCAEmitterLayerSurface;
    emitter.emitterSize = CGSizeMake(MIN(CGRectGetWidth(screen) * 0.82, CGRectGetWidth(self.notch.bounds) * 1.35), 3.0);
    emitter.renderMode = kCAEmitterLayerOldestFirst;

    CAEmitterCell *molten = [CAEmitterCell emitterCell];
    molten.name = @"molten-metal";
    molten.contents = (id)[self particleImage].CGImage;
    molten.birthRate = 520;
    molten.lifetime = 1.55;
    molten.lifetimeRange = 0.35;
    molten.velocity = 880;
    molten.velocityRange = 560;
    molten.emissionLongitude = (CGFloat)M_PI_2;
    molten.emissionRange = (CGFloat)(M_PI * 0.52);
    molten.xAcceleration = 0;
    molten.yAcceleration = 1180;
    molten.scale = 0.38;
    molten.scaleRange = 0.30;
    molten.scaleSpeed = -0.08;
    molten.spin = 0.8;
    molten.spinRange = 5.5;
    molten.alphaSpeed = -0.58;

    CAEmitterCell *brightCore = [CAEmitterCell emitterCell];
    brightCore.name = @"hot-core";
    brightCore.contents = (id)[self particleImage].CGImage;
    brightCore.birthRate = 230;
    brightCore.lifetime = 0.82;
    brightCore.lifetimeRange = 0.20;
    brightCore.velocity = 520;
    brightCore.velocityRange = 330;
    brightCore.emissionLongitude = (CGFloat)M_PI_2;
    brightCore.emissionRange = (CGFloat)(M_PI * 0.45);
    brightCore.yAcceleration = 720;
    brightCore.scale = 0.18;
    brightCore.scaleRange = 0.16;
    brightCore.alphaSpeed = -0.9;
    brightCore.color = [UIColor colorWithRed:1 green:0.58 blue:0.28 alpha:1].CGColor;

    CAEmitterCell *smallSplashes = [CAEmitterCell emitterCell];
    smallSplashes.name = @"small-splashes";
    smallSplashes.contents = (id)[self particleImage].CGImage;
    smallSplashes.birthRate = 150;
    smallSplashes.lifetime = 1.45;
    smallSplashes.lifetimeRange = 0.3;
    smallSplashes.velocity = 390;
    smallSplashes.velocityRange = 240;
    smallSplashes.emissionLongitude = (CGFloat)M_PI_2;
    smallSplashes.emissionRange = (CGFloat)(M_PI * 0.92);
    smallSplashes.yAcceleration = 980;
    smallSplashes.scale = 0.12;
    smallSplashes.scaleRange = 0.16;
    smallSplashes.alphaSpeed = -0.48;

    emitter.emitterCells = @[molten, brightCore, smallSplashes];
    [root.view.layer addSublayer:emitter];

    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.color"];
    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glow"];
    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glowColor"];
    [self.notch.shapeLayer removeAnimationForKey:@"umn1.heat.glowOpacity"];
    self.notch.shapeLayer.fillColor = UIColor.blackColor.CGColor;
    self.notch.shapeLayer.shadowOpacity = 0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        emitter.birthRate = 0;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [emitter removeFromSuperlayer];
        burstWindow.hidden = YES;
        self.explosionWindow = nil;
        self.explosionAudioPlayer = nil;
        [self refreshEvents];
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


static void DNMediaRemoteChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                          const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DNController *controller = [DNController shared];
        if (!controller.settingsEnabled || !controller.window || controller.window.hidden) return;
        [controller refreshMediaInformation];
    });
}

static void DNPreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DNController *controller = [DNController shared];
        [controller reloadPreferences];
        if (controller.settingsEnabled && !controller.window) {
            [controller start];
        } else {
            [controller refreshMediaInformation];
            [controller refreshEvents];
        }
    });
}

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
