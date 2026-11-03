
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreTelephony/CTCall.h>
#import <CoreTelephony/CTCallCenter.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CoreFoundation/CoreFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <math.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - Constants

static NSString * const DNPreferencesPath =
    @"/var/mobile/Library/Preferences/com.umn1notch.preferences.plist";

static CFStringRef const DNPreferencesNotification =
    CFSTR("com.umn1notch.preferences/Reload");

typedef NS_ENUM(NSInteger, DNNotchProfile) {
    DNNotchProfileAuto = -1,
    DNNotchProfileWide = 0,
    DNNotchProfileCompact = 1
};

typedef NS_ENUM(NSInteger, DNDisplayMode) {
    DNDisplayModeHidden = 0,
    DNDisplayModeCollapsed,
    DNDisplayModeTransient,
    DNDisplayModeMediaCompact,
    DNDisplayModeMediaExpanded
};

typedef NS_ENUM(NSInteger, DNTrigger) {
    DNTriggerNone = 0,
    DNTriggerMedia,
    DNTriggerSilent,
    DNTriggerCall,
    DNTriggerAccessory,
    DNTriggerCharging
};

#pragma mark - Preferences

static NSDictionary *DNReadPreferences(void) {
    NSDictionary *dictionary =
        [NSDictionary dictionaryWithContentsOfFile:DNPreferencesPath];

    return [dictionary isKindOfClass:NSDictionary.class] ?
        dictionary : @{};
}

static id DNPreferenceValue(NSString *key, id fallback) {
    id value = DNReadPreferences()[key];
    return value ?: fallback;
}

static BOOL DNPreferenceBool(NSString *key, BOOL fallback) {
    id value = DNPreferenceValue(key, @(fallback));

    return [value respondsToSelector:@selector(boolValue)] ?
        [value boolValue] : fallback;
}

static NSInteger DNPreferenceInteger(NSString *key, NSInteger fallback) {
    id value = DNPreferenceValue(key, @(fallback));

    return [value respondsToSelector:@selector(integerValue)] ?
        [value integerValue] : fallback;
}

static CGFloat DNPreferenceFloat(NSString *key, CGFloat fallback) {
    id value = DNPreferenceValue(key, @(fallback));

    return [value respondsToSelector:@selector(doubleValue)] ?
        [value doubleValue] : fallback;
}

#pragma mark - Device detection

static NSString *DNHardwareModel(void) {
    size_t length = 0;

    if (sysctlbyname("hw.machine", NULL, &length, NULL, 0) != 0 ||
        length == 0) {
        return @"unknown";
    }

    char *buffer = calloc(1, length);

    if (!buffer) {
        return @"unknown";
    }

    NSString *model = @"unknown";

    if (sysctlbyname("hw.machine", buffer, &length, NULL, 0) == 0) {
        model = [NSString stringWithUTF8String:buffer] ?: @"unknown";
    }

    free(buffer);
    return model;
}

static BOOL DNHasPhysicalNotch(NSString *model) {
    if ([model isEqualToString:@"iPhone10,3"] ||
        [model isEqualToString:@"iPhone10,6"] ||
        [model hasPrefix:@"iPhone11,"] ||
        [model isEqualToString:@"iPhone12,1"] ||
        [model isEqualToString:@"iPhone12,3"] ||
        [model isEqualToString:@"iPhone12,5"] ||
        [model hasPrefix:@"iPhone13,"] ||
        [model isEqualToString:@"iPhone14,2"] ||
        [model isEqualToString:@"iPhone14,3"] ||
        [model isEqualToString:@"iPhone14,4"] ||
        [model isEqualToString:@"iPhone14,5"] ||
        [model isEqualToString:@"iPhone14,7"] ||
        [model isEqualToString:@"iPhone14,8"]) {
        return YES;
    }

    return NO;
}

static BOOL DNHasNativeDynamicIsland(NSString *model) {
    return [model hasPrefix:@"iPhone15,"] ||
           [model hasPrefix:@"iPhone16,"] ||
           [model hasPrefix:@"iPhone17,"] ||
           [model hasPrefix:@"iPhone18,"] ||
           [model hasPrefix:@"iPhone19,"];
}

static BOOL DNIsVirtualNotchEligible(NSString *model) {
    if ([model hasPrefix:@"iPhone5,"] ||
        [model hasPrefix:@"iPhone6,"] ||
        [model hasPrefix:@"iPhone7,"] ||
        [model hasPrefix:@"iPhone8,"] ||
        [model hasPrefix:@"iPhone9,"]) {
        return YES;
    }

    return [model isEqualToString:@"iPhone10,1"] ||
           [model isEqualToString:@"iPhone10,2"] ||
           [model isEqualToString:@"iPhone10,4"] ||
           [model isEqualToString:@"iPhone10,5"] ||
           [model isEqualToString:@"iPhone12,8"] ||
           [model isEqualToString:@"iPhone14,6"];
}

static BOOL DNModelUsesCompactNotch(NSString *model) {
    return [model isEqualToString:@"iPhone14,2"] ||
           [model isEqualToString:@"iPhone14,3"] ||
           [model isEqualToString:@"iPhone14,4"] ||
           [model isEqualToString:@"iPhone14,5"] ||
           [model isEqualToString:@"iPhone14,7"] ||
           [model isEqualToString:@"iPhone14,8"];
}

#pragma mark - Overlay window

@interface DNNotchWindow : UIWindow
@property(nonatomic, weak) UIView *hitView;
@end

@implementation DNNotchWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.hitView) {
        return nil;
    }

    CGPoint localPoint =
        [self.hitView convertPoint:point fromView:self];

    if (![self.hitView pointInside:localPoint withEvent:event]) {
        return nil;
    }

    return [super hitTest:point withEvent:event];
}

@end

#pragma mark - Notch view

@interface DNNotchView : UIView

@property(nonatomic, strong) CAShapeLayer *shapeLayer;
@property(nonatomic, strong) UIImageView *symbolView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIImageView *artworkView;
@property(nonatomic, strong) UIImageView *compactArtworkView;
@property(nonatomic, strong) NSMutableArray<UIView *> *visualizerBars;

@property(nonatomic, assign) DNDisplayMode displayMode;

@property(nonatomic, copy) NSString *displayTitle;
@property(nonatomic, copy) NSString *displayDetail;
@property(nonatomic, copy) NSString *displaySymbol;
@property(nonatomic, strong) UIImage *displayArtwork;

- (void)configureMode:(DNDisplayMode)mode
                title:(NSString *)title
               detail:(NSString *)detail
               symbol:(NSString *)symbol
              artwork:(UIImage *)artwork;

- (UIBezierPath *)topAttachedPath;
- (void)playGreetingWithColor:(UIColor *)color;
- (void)startVisualizer;
- (void)stopVisualizer;

@end

@implementation DNNotchView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (!self) {
        return nil;
    }

    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.userInteractionEnabled = YES;

    _shapeLayer = [CAShapeLayer layer];
    _shapeLayer.fillColor = UIColor.blackColor.CGColor;
    _shapeLayer.shadowColor = UIColor.blackColor.CGColor;
    _shapeLayer.shadowOpacity = 0.22;
    _shapeLayer.shadowRadius = 4.0;
    _shapeLayer.shadowOffset = CGSizeMake(0, 2);

    [self.layer insertSublayer:_shapeLayer atIndex:0];

    _symbolView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _symbolView.contentMode = UIViewContentModeScaleAspectFit;
    _symbolView.tintColor = UIColor.whiteColor;
    [self addSubview:_symbolView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font =
        [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.75;
    [self addSubview:_titleLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.textColor =
        [UIColor colorWithWhite:0.82 alpha:1.0];
    _detailLabel.font =
        [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    _detailLabel.numberOfLines = 1;
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _detailLabel.adjustsFontSizeToFitWidth = YES;
    _detailLabel.minimumScaleFactor = 0.75;
    [self addSubview:_detailLabel];

    _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkView.clipsToBounds = YES;
    _artworkView.layer.cornerRadius = 10;
    [self addSubview:_artworkView];

    _compactArtworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _compactArtworkView.contentMode = UIViewContentModeScaleAspectFill;
    _compactArtworkView.clipsToBounds = YES;
    _compactArtworkView.layer.cornerRadius = 6;
    [self addSubview:_compactArtworkView];

    _visualizerBars = [NSMutableArray array];

    for (NSInteger index = 0; index < 5; index++) {
        UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
        bar.backgroundColor = UIColor.whiteColor;
        bar.layer.cornerRadius = 1.5;
        bar.hidden = YES;
        [self addSubview:bar];
        [_visualizerBars addObject:bar];
    }

    self.displayMode = DNDisplayModeCollapsed;

    return self;
}

- (void)configureMode:(DNDisplayMode)mode
                title:(NSString *)title
               detail:(NSString *)detail
               symbol:(NSString *)symbol
              artwork:(UIImage *)artwork {
    self.displayMode = mode;
    self.displayTitle = title;
    self.displayDetail = detail;
    self.displaySymbol = symbol;
    self.displayArtwork = artwork;

    self.titleLabel.text = title;
    self.detailLabel.text = detail;
    self.symbolView.image =
        symbol.length ? [UIImage systemImageNamed:symbol] : nil;

    self.artworkView.image = artwork;
    self.compactArtworkView.image = artwork;

    self.symbolView.hidden = YES;
    self.titleLabel.hidden = YES;
    self.detailLabel.hidden = YES;
    self.artworkView.hidden = YES;
    self.compactArtworkView.hidden = YES;

    for (UIView *bar in self.visualizerBars) {
        bar.hidden = YES;
    }

    switch (mode) {
        case DNDisplayModeTransient:
            self.symbolView.hidden = NO;
            self.titleLabel.hidden = NO;
            self.detailLabel.hidden = NO;
            break;

        case DNDisplayModeMediaCompact:
            self.compactArtworkView.hidden = NO;

            for (UIView *bar in self.visualizerBars) {
                bar.hidden = NO;
            }
            break;

        case DNDisplayModeMediaExpanded:
            self.artworkView.hidden = NO;
            self.titleLabel.hidden = NO;
            self.detailLabel.hidden = NO;
            break;

        default:
            break;
    }

    [self setNeedsLayout];
}

- (UIBezierPath *)topAttachedPath {
    CGRect bounds = self.bounds;

    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat radius = MIN(18.0, height * 0.48);

    UIBezierPath *path = [UIBezierPath bezierPath];

    [path moveToPoint:CGPointMake(0, 0)];
    [path addLineToPoint:CGPointMake(width, 0)];
    [path addLineToPoint:CGPointMake(width, height - radius)];

    [path addQuadCurveToPoint:CGPointMake(width - radius, height)
                controlPoint:CGPointMake(width, height)];

    [path addLineToPoint:CGPointMake(radius, height)];

    [path addQuadCurveToPoint:CGPointMake(0, height - radius)
                controlPoint:CGPointMake(0, height)];

    [path closePath];

    return path;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    UIBezierPath *path = [self topAttachedPath];

    self.shapeLayer.frame = self.bounds;
    self.shapeLayer.path = path.CGPath;
    self.shapeLayer.shadowPath = path.CGPath;

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);

    if (self.displayMode == DNDisplayModeTransient) {
        self.symbolView.frame = CGRectMake(15, 13, 27, 27);

        self.titleLabel.frame =
            CGRectMake(53, 9, MAX(0, width - 68), 19);

        self.detailLabel.frame =
            CGRectMake(53, 29, MAX(0, width - 68), 15);
    } else if (self.displayMode == DNDisplayModeMediaCompact) {
        self.compactArtworkView.frame =
            CGRectMake(9, 6, 26, 26);

        CGFloat barStartX = MAX(48, width - 57);

        CGFloat barHeights[] = {9, 17, 23, 14, 10};

        for (NSInteger index = 0;
             index < self.visualizerBars.count;
             index++) {
            UIView *bar = self.visualizerBars[index];

            CGFloat barHeight = barHeights[index];

            bar.bounds = CGRectMake(0, 0, 3, barHeight);
            bar.center =
                CGPointMake(barStartX + index * 8, height * 0.5);
        }
    } else if (self.displayMode == DNDisplayModeMediaExpanded) {
        self.artworkView.frame = CGRectMake(13, 15, 70, 70);

        self.titleLabel.frame =
            CGRectMake(96, 27, MAX(0, width - 109), 23);

        self.detailLabel.frame =
            CGRectMake(96, 53, MAX(0, width - 109), 18);
    }
}

- (void)startVisualizer {
    for (NSInteger index = 0;
         index < self.visualizerBars.count;
         index++) {
        UIView *bar = self.visualizerBars[index];

        [bar.layer removeAnimationForKey:@"umn1.visualizer"];

        CABasicAnimation *animation =
            [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];

        animation.fromValue = @(0.35 + (index % 2) * 0.15);
        animation.toValue = @(0.8 + (index % 3) * 0.4);
        animation.duration = 0.25 + index * 0.065;
        animation.autoreverses = YES;
        animation.repeatCount = HUGE_VALF;

        animation.timingFunction =
            [CAMediaTimingFunction functionWithName:
                kCAMediaTimingFunctionEaseInEaseOut];

        [bar.layer addAnimation:animation
                        forKey:@"umn1.visualizer"];
    }
}

- (void)stopVisualizer {
    for (UIView *bar in self.visualizerBars) {
        [bar.layer removeAnimationForKey:@"umn1.visualizer"];
    }
}

- (void)playGreetingWithColor:(UIColor *)color {
    UIBezierPath *path = [self topAttachedPath];

    CAShapeLayer *outline = [CAShapeLayer layer];
    outline.frame = self.bounds;
    outline.path = path.CGPath;
    outline.fillColor = UIColor.clearColor.CGColor;
    outline.strokeColor = color.CGColor;
    outline.lineWidth = 2.0;
    outline.strokeEnd = 0;

    [self.layer addSublayer:outline];

    CABasicAnimation *animation =
        [CABasicAnimation animationWithKeyPath:@"strokeEnd"];

    animation.fromValue = @0;
    animation.toValue = @1;
    animation.duration = 0.85;
    animation.timingFunction =
        [CAMediaTimingFunction functionWithName:
            kCAMediaTimingFunctionEaseInEaseOut];

    [outline addAnimation:animation forKey:@"umn1.greeting"];
    outline.strokeEnd = 1;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(1.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [outline removeFromSuperlayer];
    });
}

@end

#pragma mark - Root controller

@interface DNRootViewController : UIViewController
@end

@implementation DNRootViewController

- (void)loadView {
    UIView *view =
        [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];

    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;

    self.view = view;
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

@end

#pragma mark - MediaRemote

typedef void (*DNMediaRemoteGetNowPlayingInfo)(
    dispatch_queue_t queue,
    void (^completion)(CFDictionaryRef information)
);

typedef void (*DNMediaRemoteGetPlayingState)(
    dispatch_queue_t queue,
    void (^completion)(BOOL playing)
);

typedef void (*DNMediaRemoteRegisterNotifications)(
    dispatch_queue_t queue
);

static void *gMediaRemoteHandle = NULL;
static DNMediaRemoteGetNowPlayingInfo gGetNowPlayingInfo = NULL;
static DNMediaRemoteGetPlayingState gGetPlayingState = NULL;
static DNMediaRemoteRegisterNotifications gRegisterNowPlaying = NULL;

static void DNLoadMediaRemote(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        gMediaRemoteHandle =
            dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                   RTLD_LAZY);

        if (!gMediaRemoteHandle) {
            return;
        }

        gGetNowPlayingInfo =
            (DNMediaRemoteGetNowPlayingInfo)dlsym(
                gMediaRemoteHandle,
                "MRMediaRemoteGetNowPlayingInfo"
            );

        gGetPlayingState =
            (DNMediaRemoteGetPlayingState)dlsym(
                gMediaRemoteHandle,
                "MRMediaRemoteGetNowPlayingApplicationIsPlaying"
            );

        gRegisterNowPlaying =
            (DNMediaRemoteRegisterNotifications)dlsym(
                gMediaRemoteHandle,
                "MRMediaRemoteRegisterForNowPlayingNotifications"
            );

        if (gRegisterNowPlaying) {
            gRegisterNowPlaying(dispatch_get_main_queue());
        }
    });
}

#pragma mark - Controller

@interface DNController : NSObject <UIGestureRecognizerDelegate>

@property(nonatomic, strong) DNNotchWindow *window;
@property(nonatomic, strong) DNNotchView *notch;
@property(nonatomic, strong) DNRootViewController *rootController;

@property(nonatomic, strong) CTCallCenter *callCenter;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) NSTimer *mediaTimer;
@property(nonatomic, strong) NSTimer *mediaIntroTimer;

@property(nonatomic, strong) AVAudioPlayer *impactPlayer;
@property(nonatomic, strong) CAEmitterLayer *dropletEmitter;

@property(nonatomic, weak) UIWindow *previousKeyWindow;

@property(nonatomic, copy) NSString *hardwareModel;
@property(nonatomic, copy) NSString *mediaTitle;
@property(nonatomic, copy) NSString *mediaArtist;
@property(nonatomic, copy) NSString *mediaTrackKey;
@property(nonatomic, strong) UIImage *mediaArtwork;

@property(nonatomic, assign) DNDisplayMode displayMode;
@property(nonatomic, assign) DNTrigger currentTrigger;

@property(nonatomic, assign) BOOL settingsEnabled;
@property(nonatomic, assign) BOOL mediaEnabled;
@property(nonatomic, assign) BOOL visualizerEnabled;
@property(nonatomic, assign) BOOL chargingEnabled;
@property(nonatomic, assign) BOOL accessoriesEnabled;
@property(nonatomic, assign) BOOL callsEnabled;
@property(nonatomic, assign) BOOL silentEnabled;
@property(nonatomic, assign) BOOL hideInCamera;
@property(nonatomic, assign) BOOL hideInLandscape;
@property(nonatomic, assign) BOOL autoCollapse;

@property(nonatomic, assign) BOOL easterEggsEnabled;
@property(nonatomic, assign) BOOL sosGestureEnabled;
@property(nonatomic, assign) BOOL moltenEffectEnabled;
@property(nonatomic, assign) BOOL explosionSoundEnabled;
@property(nonatomic, assign) BOOL greetingEnabled;

@property(nonatomic, assign) BOOL virtualNotch;
@property(nonatomic, assign) BOOL compactNotch;
@property(nonatomic, assign) BOOL mediaPlaying;
@property(nonatomic, assign) BOOL mediaIntroActive;
@property(nonatomic, assign) BOOL mediaExpandedByHold;
@property(nonatomic, assign) BOOL charging;
@property(nonatomic, assign) BOOL accessoryConnected;
@property(nonatomic, assign) BOOL callActive;
@property(nonatomic, assign) BOOL silentActive;
@property(nonatomic, assign) BOOL hasInitialSystemState;
@property(nonatomic, assign) BOOL preferencesObserverInstalled;
@property(nonatomic, assign) BOOL mediaRequestInFlight;
@property(nonatomic, assign) BOOL moltenHoldActive;
@property(nonatomic, assign) BOOL moltenBurstFinished;

@property(nonatomic, assign) NSInteger emergencyTapCount;
@property(nonatomic, assign) NSInteger tapCount;

@property(nonatomic, assign) NSTimeInterval lastTapTime;
@property(nonatomic, assign) NSTimeInterval heatDuration;
@property(nonatomic, assign) NSTimeInterval chargingUntil;
@property(nonatomic, assign) NSTimeInterval accessoryUntil;
@property(nonatomic, assign) NSTimeInterval callUntil;
@property(nonatomic, assign) NSTimeInterval silentUntil;

@property(nonatomic, assign) NSUInteger mediaRequestGeneration;
@property(nonatomic, assign) NSUInteger moltenGeneration;

+ (instancetype)shared;

- (void)start;
- (void)reloadPreferences;
- (void)pollSystemState;
- (void)refreshMediaInformation;
- (void)refreshEvents;
- (void)applyVisualizerIfEnabled;

@end

#pragma mark - Notifications

static void DNPreferencesChangedCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DNController shared] reloadPreferences];
    });
}

static void DNMediaRemoteChangedCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DNController shared] refreshMediaInformation];
    });
}

#pragma mark - Controller implementation

@implementation DNController

+ (instancetype)shared {
    static DNController *instance;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        instance = [[DNController alloc] init];
    });

    return instance;
}

- (instancetype)init {
    self = [super init];

    if (!self) {
        return nil;
    }

    _emergencyTapCount = 5;
    _heatDuration = 4.5;
    _autoCollapse = YES;

    return self;
}

- (void)start {
    if (![NSBundle.mainBundle.bundleIdentifier
          isEqualToString:@"com.apple.springboard"]) {
        return;
    }

    if (self.preferencesObserverInstalled) {
        return;
    }

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        DNPreferencesChangedCallback,
        DNPreferencesNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    self.preferencesObserverInstalled = YES;

    self.hardwareModel = DNHardwareModel();

    [self reloadPreferences];

    if (DNHasNativeDynamicIsland(self.hardwareModel)) {
        NSLog(@"[Umn1Notch] Native Dynamic Island detected; overlay disabled.");
        return;
    }

    BOOL physicalNotch = DNHasPhysicalNotch(self.hardwareModel);

    self.virtualNotch =
        !physicalNotch && DNIsVirtualNotchEligible(self.hardwareModel);

    if (!physicalNotch && !self.virtualNotch) {
        NSLog(@"[Umn1Notch] Unsupported device: %@", self.hardwareModel);
        return;
    }

    NSInteger profile =
        DNPreferenceInteger(@"IslandProfile", DNNotchProfileAuto);

    if (profile == DNNotchProfileWide) {
        self.compactNotch = NO;
    } else if (profile == DNNotchProfileCompact) {
        self.compactNotch = YES;
    } else {
        self.compactNotch = DNModelUsesCompactNotch(self.hardwareModel);
    }

    [self createOverlayWindow];
    [self installSystemObservers];
    [self installCallMonitoring];

    UIDevice.currentDevice.batteryMonitoringEnabled = YES;

    [self pollSystemState];
    [self refreshMediaInformation];

    self.pollTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.75
                                      target:self
                                    selector:@selector(pollSystemState)
                                    userInfo:nil
                                     repeats:YES];

    self.mediaTimer =
        [NSTimer scheduledTimerWithTimeInterval:2.0
                                      target:self
                                    selector:@selector(refreshMediaInformation)
                                    userInfo:nil
                                     repeats:YES];

    if (self.greetingEnabled) {
        [self.notch playGreetingWithColor:
            [UIColor colorWithRed:0.28 green:0.65 blue:1 alpha:1]];
    }

    [self refreshEvents];
}

- (void)createOverlayWindow {
    if (self.window) {
        return;
    }

    CGRect bounds = UIScreen.mainScreen.bounds;

    self.window = [[DNNotchWindow alloc] initWithFrame:bounds];
    self.window.backgroundColor = UIColor.clearColor;
    self.window.opaque = NO;
    self.window.windowLevel = UIWindowLevelStatusBar + 1.0;
    self.window.hidden = YES;

    self.rootController = [[DNRootViewController alloc] init];
    self.window.rootViewController = self.rootController;

    self.notch = [[DNNotchView alloc] initWithFrame:CGRectZero];

    [self.rootController.view addSubview:self.notch];

    self.window.hitView = self.notch;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(handleTap:)];

    tap.numberOfTapsRequired = 1;
    tap.numberOfTouchesRequired = 1;
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;

    [self.notch addGestureRecognizer:tap];

    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(handleLongPress:)];

    hold.minimumPressDuration = 0.45;
    hold.cancelsTouchesInView = NO;
    hold.delegate = self;

    [self.notch addGestureRecognizer:hold];
}

- (void)installSystemObservers {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    [center addObserver:self
               selector:@selector(systemStateNeedsRefresh:)
                   name:UIDeviceBatteryStateDidChangeNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(systemStateNeedsRefresh:)
                   name:AVAudioSessionRouteChangeNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(systemStateNeedsRefresh:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(systemStateNeedsRefresh:)
                   name:UIApplicationDidChangeStatusBarOrientationNotification
                 object:nil];

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        DNMediaRemoteChangedCallback,
        CFSTR("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

- (void)installCallMonitoring {
    self.callCenter = [[CTCallCenter alloc] init];

    __weak typeof(self) weakSelf = self;

    self.callCenter.callEventHandler = ^(CTCall *call) {
        __strong typeof(weakSelf) self = weakSelf;

        if (!self || !call) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *state = call.callState;

            BOOL active =
                [state isEqualToString:CTCallStateConnected] ||
                [state isEqualToString:CTCallStateDialing] ||
                [state isEqualToString:CTCallStateIncoming];

            if (active != self.callActive) {
                self.callActive = active;

                if (active) {
                    self.callUntil =
                        NSDate.date.timeIntervalSince1970 + 2.6;
                }

                [self refreshEvents];
            }
        });
    };
}

- (void)systemStateNeedsRefresh:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self pollSystemState];
        [self refreshEvents];
    });
}

#pragma mark - Preferences

- (void)reloadPreferences {
    self.settingsEnabled =
        DNPreferenceBool(@"Enabled", YES);

    self.mediaEnabled =
        DNPreferenceBool(@"EnableMediaPlayer", YES);

    self.visualizerEnabled =
        DNPreferenceBool(@"EnableVisualizer", YES);

    self.chargingEnabled =
        DNPreferenceBool(@"EnableCharging", YES);

    self.accessoriesEnabled =
        DNPreferenceBool(@"EnableAccessories", YES);

    self.callsEnabled =
        DNPreferenceBool(@"EnableCalls", YES);

    self.silentEnabled =
        DNPreferenceBool(@"EnableSilentMode", YES);

    self.hideInCamera =
        DNPreferenceBool(@"HideInCamera", YES);

    self.hideInLandscape =
        DNPreferenceBool(@"HideInLandscape", YES);

    self.autoCollapse =
        DNPreferenceBool(@"AutoCollapse", YES);

    self.easterEggsEnabled =
        DNPreferenceBool(@"EnableEasterEggs", YES);

    self.sosGestureEnabled =
        DNPreferenceBool(@"EnableSOSGesture", YES);

    self.moltenEffectEnabled =
        DNPreferenceBool(@"EnableMoltenEffect", YES);

    self.explosionSoundEnabled =
        DNPreferenceBool(@"EnableExplosionSound", YES);

    self.greetingEnabled =
        DNPreferenceBool(@"EnableGreeting", YES);

    self.emergencyTapCount =
        MIN(25, MAX(5, DNPreferenceInteger(@"EmergencyTapCount", 5)));

    self.heatDuration =
        MIN(8.0, MAX(2.5, DNPreferenceFloat(@"HeatDuration", 4.5)));

    if (!self.settingsEnabled) {
        [self.mediaIntroTimer invalidate];
        self.mediaIntroTimer = nil;

        self.mediaIntroActive = NO;
        self.mediaExpandedByHold = NO;
        self.moltenHoldActive = NO;

        [self.notch stopVisualizer];

        self.window.hidden = YES;
        self.tapCount = 0;

        return;
    }

    if (self.window) {
        self.window.hidden = NO;
    }

    [self refreshMediaInformation];
    [self refreshEvents];
}

#pragma mark - Application context

- (NSString *)frontmostBundleIdentifier {
    Class workspaceClass = NSClassFromString(@"SBMainWorkspace");

    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    SEL frontmostSelector = NSSelectorFromString(@"frontmostApplication");
    SEL bundleSelector = NSSelectorFromString(@"bundleIdentifier");

    if (!workspaceClass ||
        ![workspaceClass respondsToSelector:sharedSelector]) {
        return nil;
    }

    id workspace =
        ((id (*)(id, SEL))objc_msgSend)(workspaceClass, sharedSelector);

    if (!workspace ||
        ![workspace respondsToSelector:frontmostSelector]) {
        return nil;
    }

    id application =
        ((id (*)(id, SEL))objc_msgSend)(workspace, frontmostSelector);

    if (!application ||
        ![application respondsToSelector:bundleSelector]) {
        return nil;
    }

    id value =
        ((id (*)(id, SEL))objc_msgSend)(application, bundleSelector);

    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (BOOL)isHiddenByContext {
    CGRect bounds = UIScreen.mainScreen.bounds;

    BOOL landscape =
        CGRectGetWidth(bounds) > CGRectGetHeight(bounds);

    if (self.hideInLandscape && landscape) {
        return YES;
    }

    NSString *bundleID = [self frontmostBundleIdentifier];

    if (self.hideInCamera &&
        [bundleID isEqualToString:@"com.apple.camera"]) {
        return YES;
    }

    if ([bundleID isEqualToString:@"com.apple.mobilephone"] ||
        [bundleID isEqualToString:@"com.apple.facetime"]) {
        return YES;
    }

    return NO;
}

#pragma mark - System state

- (BOOL)currentAccessoryState {
    AVAudioSessionRouteDescription *route =
        AVAudioSession.sharedInstance.currentRoute;

    for (AVAudioSessionPortDescription *port in route.outputs) {
        NSString *type = port.portType;

        if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
            [type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
            return YES;
        }
    }

    return NO;
}

- (BOOL)currentSilentState {
    Class mediaControllerClass =
        NSClassFromString(@"SBMediaController");

    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    SEL mutedSelector = NSSelectorFromString(@"isRingerMuted");

    if (!mediaControllerClass ||
        ![mediaControllerClass respondsToSelector:sharedSelector]) {
        return self.silentActive;
    }

    id mediaController =
        ((id (*)(id, SEL))objc_msgSend)(mediaControllerClass, sharedSelector);

    if (!mediaController ||
        ![mediaController respondsToSelector:mutedSelector]) {
        return self.silentActive;
    }

    BOOL (*sendBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;

    return sendBool(mediaController, mutedSelector);
}

- (void)pollSystemState {
    if (!self.window || !self.settingsEnabled) {
        return;
    }

    UIDeviceBatteryState batteryState =
        UIDevice.currentDevice.batteryState;

    BOOL newCharging =
        batteryState == UIDeviceBatteryStateCharging ||
        batteryState == UIDeviceBatteryStateFull;

    BOOL newAccessory = [self currentAccessoryState];
    BOOL newSilent = [self currentSilentState];

    if (!self.hasInitialSystemState) {
        self.charging = newCharging;
        self.accessoryConnected = newAccessory;
        self.silentActive = newSilent;
        self.hasInitialSystemState = YES;

        [self refreshEvents];
        return;
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    if (newCharging != self.charging) {
        self.charging = newCharging;

        if (newCharging && self.chargingEnabled) {
            self.chargingUntil = now + 2.6;
        }
    }

    if (newAccessory != self.accessoryConnected) {
        self.accessoryConnected = newAccessory;

        if (newAccessory && self.accessoriesEnabled) {
            self.accessoryUntil = now + 2.6;
        }
    }

    if (newSilent != self.silentActive) {
        self.silentActive = newSilent;

        if (self.silentEnabled) {
            self.silentUntil = now + 2.6;
        }
    }

    [self refreshEvents];
}

#pragma mark - Media

- (void)refreshMediaInformation {
    if (!self.mediaEnabled || !self.settingsEnabled) {
        self.mediaPlaying = NO;
        self.mediaTitle = nil;
        self.mediaArtist = nil;
        self.mediaArtwork = nil;
        self.mediaTrackKey = nil;

        [self refreshEvents];
        return;
    }

    DNLoadMediaRemote();

    if (!gGetNowPlayingInfo) {
        NSDictionary *fallback =
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;

        BOOL playing =
            [fallback[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] > 0.0;

        [self applyMediaInformation:fallback playing:playing];
        return;
    }

    if (self.mediaRequestInFlight) {
        return;
    }

    self.mediaRequestInFlight = YES;

    NSUInteger generation = ++self.mediaRequestGeneration;

    __weak typeof(self) weakSelf = self;

    gGetNowPlayingInfo(dispatch_get_main_queue(),
                       ^(CFDictionaryRef information) {
        __strong typeof(weakSelf) self = weakSelf;

        if (!self || self.mediaRequestGeneration != generation) {
            return;
        }

        NSDictionary *dictionary =
            information ? (__bridge NSDictionary *)information : @{};

        if (![dictionary isKindOfClass:NSDictionary.class]) {
            dictionary = @{};
        }

        id playingValue =
            dictionary[@"kMRMediaRemoteNowPlayingInfoIsPlaying"];

        BOOL inferredPlaying = NO;

        if ([playingValue respondsToSelector:@selector(boolValue)]) {
            inferredPlaying = [playingValue boolValue];
        } else {
            id rate = dictionary[MPNowPlayingInfoPropertyPlaybackRate];

            inferredPlaying =
                [rate respondsToSelector:@selector(doubleValue)] &&
                [rate doubleValue] > 0.0;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.mediaRequestGeneration != generation) {
                return;
            }

            self.mediaRequestInFlight = NO;

            [self applyMediaInformation:dictionary
                              playing:inferredPlaying];

            if (gGetPlayingState) {
                gGetPlayingState(dispatch_get_main_queue(),
                                 ^(BOOL playing) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.mediaRequestGeneration != generation) {
                            return;
                        }

                        self.mediaPlaying =
                            playing && self.mediaTitle.length > 0;

                        [self refreshEvents];
                    });
                });
            }
        });
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.mediaRequestGeneration == generation &&
            self.mediaRequestInFlight) {
            self.mediaRequestInFlight = NO;
        }
    });
}

- (void)applyMediaInformation:(NSDictionary *)dictionary
                      playing:(BOOL)playing {
    NSString *title =
        dictionary[@"kMRMediaRemoteNowPlayingInfoTitle"] ?:
        dictionary[MPMediaItemPropertyTitle] ?:
        dictionary[@"title"];

    NSString *artist =
        dictionary[@"kMRMediaRemoteNowPlayingInfoArtist"] ?:
        dictionary[MPMediaItemPropertyArtist] ?:
        dictionary[@"artist"];

    UIImage *artwork = nil;

    id artworkValue =
        dictionary[@"kMRMediaRemoteNowPlayingInfoArtworkData"] ?:
        dictionary[MPMediaItemPropertyArtwork] ?:
        dictionary[@"artwork"];

    if ([artworkValue isKindOfClass:UIImage.class]) {
        artwork = artworkValue;
    } else if ([artworkValue isKindOfClass:NSData.class]) {
        artwork = [UIImage imageWithData:artworkValue];
    }

    NSDictionary *fallback =
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;

    if (!title.length &&
        [fallback[MPMediaItemPropertyTitle] isKindOfClass:NSString.class]) {
        title = fallback[MPMediaItemPropertyTitle];
    }

    if (!artist.length &&
        [fallback[MPMediaItemPropertyArtist] isKindOfClass:NSString.class]) {
        artist = fallback[MPMediaItemPropertyArtist];
    }

    if (!artwork &&
        [fallback[MPMediaItemPropertyArtwork]
            isKindOfClass:MPMediaItemArtwork.class]) {
        artwork =
            [(MPMediaItemArtwork *)fallback[MPMediaItemPropertyArtwork]
                imageWithSize:CGSizeMake(100, 100)];
    }

    NSString *newTrackKey =
        [NSString stringWithFormat:@"%@|%@", title ?: @"", artist ?: @""];

    BOOL trackChanged =
        ![newTrackKey isEqualToString:self.mediaTrackKey];

    self.mediaTitle = title;
    self.mediaArtist = artist;
    self.mediaArtwork = artwork;
    self.mediaPlaying = playing && title.length > 0;

    if (self.mediaPlaying && trackChanged) {
        self.mediaTrackKey = newTrackKey;
        self.mediaIntroActive = YES;
        self.mediaExpandedByHold = NO;

        [self.mediaIntroTimer invalidate];

        __weak typeof(self) weakSelf = self;

        self.mediaIntroTimer =
            [NSTimer scheduledTimerWithTimeInterval:0.82
                                          target:self
                                        selector:@selector(endMediaIntro)
                                        userInfo:nil
                                         repeats:NO];
    }

    if (!self.mediaPlaying) {
        self.mediaIntroActive = NO;
        self.mediaExpandedByHold = NO;

        [self.mediaIntroTimer invalidate];
        self.mediaIntroTimer = nil;
    }

    [self refreshEvents];
}

- (void)endMediaIntro {
    self.mediaIntroActive = NO;
    self.mediaIntroTimer = nil;
    [self refreshEvents];
}

#pragma mark - Trigger priority

- (DNTrigger)currentSystemTrigger {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    if (self.chargingEnabled && self.chargingUntil > now) {
        return DNTriggerCharging;
    }

    if (self.accessoriesEnabled && self.accessoryUntil > now) {
        return DNTriggerAccessory;
    }

    if (self.callsEnabled &&
        (self.callActive || self.callUntil > now)) {
        return DNTriggerCall;
    }

    if (self.silentEnabled && self.silentUntil > now) {
        return DNTriggerSilent;
    }

    if (self.mediaEnabled && self.mediaPlaying) {
        return DNTriggerMedia;
    }

    return DNTriggerNone;
}

- (void)refreshEvents {
    if (!self.window || !self.notch) {
        return;
    }

    if (!self.settingsEnabled || [self isHiddenByContext]) {
        self.window.hidden = YES;
        [self.notch stopVisualizer];
        return;
    }

    self.window.hidden = NO;

    DNTrigger trigger = [self currentSystemTrigger];
    self.currentTrigger = trigger;

    if (trigger == DNTriggerCharging) {
        [self showTransientTitle:@"Charging"
                         detail:@"Power connected"
                         symbol:@"bolt.fill"];
        return;
    }

    if (trigger == DNTriggerAccessory) {
        [self showTransientTitle:@"Accessory connected"
                         detail:@"Audio device"
                         symbol:@"headphones"];
        return;
    }

    if (trigger == DNTriggerCall) {
        [self showTransientTitle:@"Call"
                         detail:@"Phone activity"
                         symbol:@"phone.fill"];
        return;
    }

    if (trigger == DNTriggerSilent) {
        [self showTransientTitle:
            (self.silentActive ? @"Silent mode" : @"Sound enabled")
                         detail:@"Ringer setting changed"
                         symbol:(self.silentActive ?
                                 @"bell.slash.fill" : @"bell.fill")];
        return;
    }

    if (trigger == DNTriggerMedia) {
        if (self.mediaIntroActive || self.mediaExpandedByHold) {
            [self showMediaExpanded];
        } else {
            [self showMediaCompact];
        }

        return;
    }

    [self.notch stopVisualizer];

    [self.notch configureMode:DNDisplayModeCollapsed
                        title:nil
                       detail:nil
                       symbol:nil
                      artwork:nil];

    [self applyNotchFrameWidth:[self collapsedWidth]
                        height:[self collapsedHeight]
                      animated:YES];
}

- (void)showTransientTitle:(NSString *)title
                   detail:(NSString *)detail
                   symbol:(NSString *)symbol {
    [self.notch stopVisualizer];

    [self.notch configureMode:DNDisplayModeTransient
                        title:title
                       detail:detail
                       symbol:symbol
                      artwork:nil];

    CGFloat width =
        MIN(CGRectGetWidth(UIScreen.mainScreen.bounds) - 24.0, 238.0);

    [self applyNotchFrameWidth:width height:57.0 animated:YES];
}

- (void)showMediaCompact {
    [self.notch configureMode:DNDisplayModeMediaCompact
                        title:nil
                       detail:nil
                       symbol:nil
                      artwork:self.mediaArtwork];

    [self applyVisualizerIfEnabled];

    [self applyNotchFrameWidth:[self collapsedWidth]
                        height:[self collapsedHeight]
                      animated:YES];
}

- (void)applyVisualizerIfEnabled {
    if (self.visualizerEnabled) {
        [self.notch startVisualizer];
    } else {
        [self.notch stopVisualizer];
    }
}

- (void)showMediaExpanded {
    [self.notch stopVisualizer];

    NSString *title =
        self.mediaTitle.length ? self.mediaTitle : @"Now Playing";

    NSString *artist =
        self.mediaArtist.length ? self.mediaArtist : @"";

    [self.notch configureMode:DNDisplayModeMediaExpanded
                        title:title
                       detail:artist
                       symbol:nil
                      artwork:self.mediaArtwork];

    CGFloat width =
        MIN(CGRectGetWidth(UIScreen.mainScreen.bounds) - 20.0, 340.0);

    [self applyNotchFrameWidth:width height:104.0 animated:YES];
}

#pragma mark - Geometry

- (CGFloat)collapsedWidth {
    if (self.virtualNotch) {
        return self.compactNotch ? 118.0 : 138.0;
    }

    return self.compactNotch ? 126.0 : 145.0;
}

- (CGFloat)collapsedHeight {
    return self.virtualNotch ? 32.0 : 35.0;
}

- (void)applyNotchFrameWidth:(CGFloat)width
                      height:(CGFloat)height
                    animated:(BOOL)animated {
    if (!self.window || !self.notch) {
        return;
    }

    CGRect screenBounds = UIScreen.mainScreen.bounds;

    self.window.frame = screenBounds;
    self.rootController.view.frame = screenBounds;

    width = MIN(width, MAX(100.0, CGRectGetWidth(screenBounds) - 16.0));

    CGRect target = CGRectMake(
        (CGRectGetWidth(screenBounds) - width) * 0.5,
        0,
        width,
        height
    );

    if (animated) {
        [UIView animateWithDuration:0.24
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            self.notch.frame = target;
        } completion:nil];
    } else {
        self.notch.frame = target;
    }
}

#pragma mark - Gestures

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) {
        return;
    }

    if (!self.easterEggsEnabled ||
        !self.sosGestureEnabled ||
        self.currentTrigger != DNTriggerNone ||
        [self isHiddenByContext]) {
        self.tapCount = 0;
        return;
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    if (now - self.lastTapTime > 3.0) {
        self.tapCount = 0;
    }

    self.lastTapTime = now;
    self.tapCount++;

    if (self.tapCount >= self.emergencyTapCount) {
        self.tapCount = 0;
        [self presentEmergencyConfirmation];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (self.currentTrigger == DNTriggerMedia &&
            self.mediaPlaying) {
            self.mediaExpandedByHold = YES;
            [self refreshEvents];
            return;
        }

        if (self.currentTrigger == DNTriggerNone &&
            self.easterEggsEnabled &&
            self.moltenEffectEnabled &&
            ![self isHiddenByContext]) {
            [self beginMoltenHold];
        }

        return;
    }

    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        if (self.mediaExpandedByHold) {
            self.mediaExpandedByHold = NO;
            [self refreshEvents];
        }

        if (self.moltenHoldActive && !self.moltenBurstFinished) {
            [self resetMoltenEffect];
        }
    }
}

#pragma mark - SOS confirmation

- (void)presentEmergencyConfirmation {
    if (!self.rootController ||
        self.rootController.presentedViewController) {
        return;
    }

    self.previousKeyWindow = UIApplication.sharedApplication.keyWindow;

    [self.window makeKeyAndVisible];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Emergency call"
                                          message:@"Open the system emergency calling screen? No call will be placed automatically."
                                   preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Cancel"
                               style:UIAlertActionStyleCancel
                             handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        [self restorePreviousKeyWindow];
    }]];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Open emergency screen"
                               style:UIAlertActionStyleDestructive
                             handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;

        [self restorePreviousKeyWindow];

        NSURL *url = [NSURL URLWithString:@"tel://112"];

        if (url) {
            [UIApplication.sharedApplication openURL:url
                                          options:@{}
                                completionHandler:nil];
        }
    }]];

    [self.rootController presentViewController:alert
                                    animated:YES
                                  completion:nil];
}

- (void)restorePreviousKeyWindow {
    UIWindow *previous = self.previousKeyWindow;

    if (previous && !previous.hidden) {
        [previous makeKeyWindow];
    } else {
        [self.window resignKeyWindow];
    }
}

#pragma mark - Molten effect

- (void)beginMoltenHold {
    if (self.moltenHoldActive) {
        return;
    }

    self.moltenHoldActive = YES;
    self.moltenBurstFinished = NO;

    NSUInteger generation = ++self.moltenGeneration;

    NSArray<UIColor *> *colors = @[
        [UIColor colorWithWhite:0.015 alpha:1.0],
        [UIColor colorWithRed:0.30 green:0.005 blue:0.005 alpha:1.0],
        [UIColor colorWithRed:0.75 green:0.035 blue:0.005 alpha:1.0],
        [UIColor colorWithRed:1.0 green:0.20 blue:0.015 alpha:1.0],
        [UIColor colorWithRed:1.0 green:0.68 blue:0.12 alpha:1.0],
        [UIColor colorWithRed:1.0 green:0.96 blue:0.78 alpha:1.0],
        UIColor.whiteColor
    ];

    NSMutableArray *values = [NSMutableArray array];

    for (UIColor *color in colors) {
        [values addObject:(id)color.CGColor];
    }

    CAKeyframeAnimation *heat =
        [CAKeyframeAnimation animationWithKeyPath:@"fillColor"];

    heat.values = values;
    heat.duration = self.heatDuration;
    heat.calculationMode = kCAAnimationCubic;
    heat.fillMode = kCAFillModeForwards;
    heat.removedOnCompletion = NO;

    [self.notch.shapeLayer addAnimation:heat
                                forKey:@"umn1.molten.heat"];

    self.notch.shapeLayer.fillColor = UIColor.whiteColor.CGColor;
    self.notch.shapeLayer.shadowColor =
        [UIColor colorWithRed:1 green:0.25 blue:0.02 alpha:1].CGColor;
    self.notch.shapeLayer.shadowOpacity = 0.85;
    self.notch.shapeLayer.shadowRadius = 14.0;

    __weak typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(self.heatDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;

        if (!self ||
            self.moltenGeneration != generation ||
            !self.moltenHoldActive ||
            self.currentTrigger != DNTriggerNone) {
            return;
        }

        self.moltenBurstFinished = YES;
        self.moltenHoldActive = NO;

        [self showMoltenDroplets];
        [self playMoltenImpactSound];
    });
}

- (void)resetMoltenEffect {
    self.moltenHoldActive = NO;
    self.moltenBurstFinished = NO;
    self.moltenGeneration++;

    [self.notch.shapeLayer removeAnimationForKey:@"umn1.molten.heat"];

    CABasicAnimation *reset =
        [CABasicAnimation animationWithKeyPath:@"fillColor"];

    reset.fromValue =
        (id)self.notch.shapeLayer.presentationLayer.fillColor;

    reset.toValue = (id)UIColor.blackColor.CGColor;
    reset.duration = 0.28;

    [self.notch.shapeLayer addAnimation:reset
                                forKey:@"umn1.molten.reset"];

    self.notch.shapeLayer.fillColor = UIColor.blackColor.CGColor;
    self.notch.shapeLayer.shadowColor = UIColor.blackColor.CGColor;
    self.notch.shapeLayer.shadowOpacity = 0.22;
    self.notch.shapeLayer.shadowRadius = 4.0;
}

- (UIImage *)moltenDropletImage {
    CGSize size = CGSizeMake(24, 38);

    UIGraphicsBeginImageContextWithOptions(size, NO, 0);

    CGContextRef context = UIGraphicsGetCurrentContext();

    if (!context) {
        UIGraphicsEndImageContext();
        return nil;
    }

    CGRect rect = CGRectMake(5, 2, 14, 34);

    UIBezierPath *path = [UIBezierPath bezierPath];

    [path moveToPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect))];

    [path addCurveToPoint:CGPointMake(CGRectGetMaxX(rect), CGRectGetMidY(rect))
            controlPoint1:CGPointMake(CGRectGetMaxX(rect) - 1, 9)
            controlPoint2:CGPointMake(CGRectGetMaxX(rect), 15)];

    [path addCurveToPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect))
            controlPoint1:CGPointMake(CGRectGetMaxX(rect) - 1, 32)
            controlPoint2:CGPointMake(CGRectGetMidX(rect) + 4, 36)];

    [path addCurveToPoint:CGPointMake(CGRectGetMinX(rect), CGRectGetMidY(rect))
            controlPoint1:CGPointMake(CGRectGetMidX(rect) - 4, 36)
            controlPoint2:CGPointMake(CGRectGetMinX(rect) + 1, 15)];

    [path addCurveToPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect))
            controlPoint1:CGPointMake(CGRectGetMinX(rect), 9)
            controlPoint2:CGPointMake(CGRectGetMidX(rect), 2)];

    [path closePath];

    [[UIColor colorWithRed:1.0 green:0.28 blue:0.035 alpha:1.0] setFill];
    [path fill];

    UIImage *image =
        UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return image;
}

- (void)showMoltenDroplets {
    [self.dropletEmitter removeFromSuperlayer];

    CAEmitterLayer *emitter = [CAEmitterLayer layer];

    emitter.frame = self.rootController.view.bounds;
    emitter.emitterShape = kCAEmitterLayerLine;
    emitter.emitterMode = kCAEmitterLayerSurface;
    emitter.renderMode = kCAEmitterLayerOldestFirst;

    emitter.emitterPosition =
        CGPointMake(CGRectGetMidX(self.notch.frame),
                   CGRectGetMaxY(self.notch.frame) + 1.0);

    emitter.emitterSize =
        CGSizeMake(MIN(CGRectGetWidth(self.notch.bounds), 180.0), 2.0);

    CAEmitterCell *cell = [CAEmitterCell emitterCell];

    UIImage *dropletImage = [self moltenDropletImage];

    cell.contents = dropletImage ? (id)dropletImage.CGImage : nil;
    cell.birthRate = 18.0;
    cell.lifetime = 1.7;
    cell.velocity = 190.0;
    cell.velocityRange = 80.0;
    cell.yAcceleration = 520.0;
    cell.emissionLongitude = (CGFloat)M_PI_2;
    cell.emissionRange = 0.55;
    cell.scale = 0.17;
    cell.scaleRange = 0.09;
    cell.alphaSpeed = -0.5;

    emitter.emitterCells = @[cell];

    [self.rootController.view.layer addSublayer:emitter];

    self.dropletEmitter = emitter;

    __weak typeof(self) weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(2.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;

        [self.dropletEmitter removeFromSuperlayer];
        self.dropletEmitter = nil;

        [self resetMoltenEffect];
    });
}

#pragma mark - Original synthesized impact sound

static void DNWriteLE32(uint8_t *buffer, uint32_t value) {
    buffer[0] = (uint8_t)(value & 0xFF);
    buffer[1] = (uint8_t)((value >> 8) & 0xFF);
    buffer[2] = (uint8_t)((value >> 16) & 0xFF);
    buffer[3] = (uint8_t)((value >> 24) & 0xFF);
}

static void DNWriteLE16(uint8_t *buffer, uint16_t value) {
    buffer[0] = (uint8_t)(value & 0xFF);
    buffer[1] = (uint8_t)((value >> 8) & 0xFF);
}

static NSData *DNCreateImpactWAV(void) {
    const uint32_t sampleRate = 22050;
    const uint32_t sampleCount = (uint32_t)(sampleRate * 0.24);
    const uint32_t dataLength = sampleCount * 2;

    NSMutableData *data =
        [NSMutableData dataWithLength:44 + dataLength];

    uint8_t *bytes = data.mutableBytes;

    memcpy(bytes, "RIFF", 4);
    DNWriteLE32(bytes + 4, 36 + dataLength);
    memcpy(bytes + 8, "WAVE", 4);

    memcpy(bytes + 12, "fmt ", 4);
    DNWriteLE32(bytes + 16, 16);
    DNWriteLE16(bytes + 20, 1);
    DNWriteLE16(bytes + 22, 1);
    DNWriteLE32(bytes + 24, sampleRate);
    DNWriteLE32(bytes + 28, sampleRate * 2);
    DNWriteLE16(bytes + 32, 2);
    DNWriteLE16(bytes + 34, 16);

    memcpy(bytes + 36, "data", 4);
    DNWriteLE32(bytes + 40, dataLength);

    int16_t *samples = (int16_t *)(bytes + 44);

    for (uint32_t index = 0; index < sampleCount; index++) {
        double time = (double)index / sampleRate;
        double envelope = exp(-time * 20.0);

        double wave =
            sin(2.0 * M_PI * 440.0 * time) * 0.55 +
            sin(2.0 * M_PI * 1174.0 * time) * 0.28 +
            sin(2.0 * M_PI * 2310.0 * time) * 0.17;

        double sample = wave * envelope * 0.42;
        sample = MAX(-1.0, MIN(1.0, sample));

        samples[index] = (int16_t)(sample * 32767.0);
    }

    return data;
}

- (void)playMoltenImpactSound {
    if (!self.explosionSoundEnabled) {
        return;
    }

    NSError *error = nil;

    self.impactPlayer =
        [[AVAudioPlayer alloc] initWithData:DNCreateImpactWAV()
                                      error:&error];

    if (!self.impactPlayer) {
        NSLog(@"[Umn1Notch] Impact sound initialization failed: %@",
              error);
        return;
    }

    self.impactPlayer.volume = 0.55;
    [self.impactPlayer prepareToPlay];
    [self.impactPlayer play];
}

@end

#pragma mark - Constructor

__attribute__((constructor))
static void DNInitialize(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[DNController shared] start];
            });
        });
    }
}
