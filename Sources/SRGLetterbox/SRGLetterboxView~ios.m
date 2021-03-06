//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import <TargetConditionals.h>

#if TARGET_OS_IOS

#import "SRGLetterboxView.h"
#import "SRGLetterboxView+Private.h"

#import "NSBundle+SRGLetterbox.h"
#import "NSLayoutConstraint+SRGLetterboxPrivate.h"
#import "NSTimer+SRGLetterbox.h"
#import "SRGAccessibilityView.h"
#import "SRGAvailabilityView.h"
#import "SRGContinuousPlaybackView.h"
#import "SRGControlsBackgroundView.h"
#import "SRGControlsView.h"
#import "SRGErrorView.h"
#import "SRGLetterboxControllerView+Subclassing.h"
#import "SRGLetterboxController+Private.h"
#import "SRGLetterboxError.h"
#import "SRGLetterboxLogger.h"
#import "SRGLetterboxPlaybackButton.h"
#import "SRGLetterboxService+Private.h"
#import "SRGLetterboxTimelineView.h"
#import "SRGMediaComposition+SRGLetterbox.h"
#import "SRGNotificationView.h"
#import "SRGTapGestureRecognizer.h"
#import "UIImageView+SRGLetterbox.h"

@import SRGAnalyticsDataProvider;
@import libextobjc;
@import MAKVONotificationCenter;

static const CGFloat kBottomConstraintGreaterPriority = 950.f;
static const CGFloat kBottomConstraintLesserPriority = 850.f;

@interface SRGLetterboxView () <SRGAirPlayViewDelegate, SRGLetterboxTimelineViewDelegate, SRGContinuousPlaybackViewDelegate, SRGControlsViewDelegate>

@property (nonatomic, weak) UIImageView *imageView;
@property (nonatomic, weak) UIView *playbackView;
@property (nonatomic, weak) SRGControlsBackgroundView *controlsBackgroundView;
@property (nonatomic, weak) SRGControlsView *controlsView;
@property (nonatomic, weak) SRGNotificationView *notificationView;
@property (nonatomic, weak) SRGLetterboxTimelineView *timelineView;
@property (nonatomic, weak) SRGAvailabilityView *availabilityView;
@property (nonatomic, weak) SRGContinuousPlaybackView *continuousPlaybackView;
@property (nonatomic, weak) SRGErrorView *errorView;

@property (nonatomic, weak) NSLayoutConstraint *timelineHeightConstraint;
@property (nonatomic, weak) NSLayoutConstraint *timelineToSafeAreaBottomConstraint;
@property (nonatomic, weak) NSLayoutConstraint *timelineToSelfBottomConstraint;
@property (nonatomic, weak) NSLayoutConstraint *notificationHeightConstraint;

@property (nonatomic, weak) UITapGestureRecognizer *showUserInterfaceTapGestureRecognizer;
@property (nonatomic, weak) SRGTapGestureRecognizer *videoGravityTapChangeGestureRecognizer;

@property (nonatomic) NSTimer *inactivityTimer;

@property (nonatomic, copy) NSString *notificationMessage;

@property (nonatomic, getter=isUserInterfaceHidden) BOOL userInterfaceHidden;
@property (nonatomic, getter=isUserInterfaceTogglable) BOOL userInterfaceTogglable;

@property (nonatomic, getter=isFullScreen) BOOL fullScreen;
@property (nonatomic, getter=isFullScreenAnimationRunning) BOOL fullScreenAnimationRunning;

@property (nonatomic) CGFloat previousAspectRatio;

@property (nonatomic) CGFloat preferredTimelineHeight;

@property (nonatomic, copy) void (^animations)(BOOL hidden, BOOL minimal, CGFloat aspectRatio, CGFloat heightOffset);
@property (nonatomic, copy) void (^completion)(BOOL finished);

@end

@implementation SRGLetterboxView {
@private
    BOOL _inWillAnimateUserInterface;
}

@synthesize userInterfaceStyle = _userInterfaceStyle;

#pragma mark Class methods

+ (void)setMotionManager:(CMMotionManager *)motionManager
{
    [SRGMediaPlayerView setMotionManager:motionManager];
}

#pragma mark Layout

- (void)layoutContentView
{
    [super layoutContentView];
    
    self.userInterfaceHidden = NO;
    self.userInterfaceTogglable = YES;
    self.preferredTimelineHeight = SRGLetterboxTimelineViewDefaultHeight;
    self.previousAspectRatio = SRGAspectRatioUndefined;
    
    self.contentView.backgroundColor = UIColor.blackColor;
    self.contentView.accessibilityIgnoresInvertColors = YES;
    
    // Detect all touches on the player view. Other gesture recognizers can be added directly in the storyboard
    // to detect other interactions earlier
    SRGActivityGestureRecognizer *activityGestureRecognizer = [[SRGActivityGestureRecognizer alloc] initWithTarget:self
                                                                                                            action:@selector(resetInactivity:)];
    activityGestureRecognizer.delegate = self;
    [self.contentView addGestureRecognizer:activityGestureRecognizer];
    
    [self layoutTimelineViewInView:self.contentView];
    [self layoutPlayerViewInView:self.contentView];
    [self layoutControlsViewInView:self.contentView];
    [self layoutNotificationViewInView:self.contentView];
    [self layoutAvailabilityViewInView:self.contentView];
    [self layoutContinuousPlaybackViewInView:self.contentView];
    [self layoutErrorViewInView:self.contentView];
}

- (void)layoutTimelineViewInView:(UIView *)view
{
    SRGLetterboxTimelineView *timelineView = [[SRGLetterboxTimelineView alloc] init];
    timelineView.translatesAutoresizingMaskIntoConstraints = NO;
    timelineView.delegate = self;
    [view addSubview:timelineView];
    self.timelineView = timelineView;
    
    [NSLayoutConstraint activateConstraints:@[
        [timelineView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [timelineView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        self.timelineHeightConstraint = [timelineView.heightAnchor constraintEqualToConstant:0.f],
        self.timelineToSafeAreaBottomConstraint = [[timelineView.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor] srgletterbox_withPriority:kBottomConstraintGreaterPriority],
        self.timelineToSelfBottomConstraint = [[timelineView.bottomAnchor constraintEqualToAnchor:view.bottomAnchor] srgletterbox_withPriority:kBottomConstraintLesserPriority]
    ]];
}

- (void)layoutPlayerViewInView:(UIView *)view
{
    UIImageView *imageView = [[UIImageView alloc] init];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    [view addSubview:imageView];
    self.imageView = imageView;
    
    UIView *playbackView = [[UIView alloc] init];
    playbackView.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:playbackView];
    self.playbackView = playbackView;
    
    [NSLayoutConstraint activateConstraints: @[
        [playbackView.topAnchor constraintEqualToAnchor:view.topAnchor],
        [playbackView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [playbackView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor]
    ]];
    
    [NSLayoutConstraint activateConstraints: @[
        [imageView.topAnchor constraintEqualToAnchor:playbackView.topAnchor],
        [imageView.bottomAnchor constraintEqualToAnchor:playbackView.bottomAnchor],
        [imageView.leadingAnchor constraintEqualToAnchor:playbackView.leadingAnchor],
        [imageView.trailingAnchor constraintEqualToAnchor:playbackView.trailingAnchor]
    ]];
    
    UITapGestureRecognizer *showUserInterfaceTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showUserInterface:)];
    showUserInterfaceTapGestureRecognizer.delegate = self;
    [playbackView addGestureRecognizer:showUserInterfaceTapGestureRecognizer];
    self.showUserInterfaceTapGestureRecognizer = showUserInterfaceTapGestureRecognizer;
    
    SRGTapGestureRecognizer *videoGravityTapChangeGestureRecognizer = [[SRGTapGestureRecognizer alloc] initWithTarget:self action:@selector(changeVideoGravity:)];
    videoGravityTapChangeGestureRecognizer.numberOfTapsRequired = 2;
    videoGravityTapChangeGestureRecognizer.tapDelay = 0.3;
    videoGravityTapChangeGestureRecognizer.delegate = self;
    videoGravityTapChangeGestureRecognizer.enabled = NO;
    [playbackView addGestureRecognizer:videoGravityTapChangeGestureRecognizer];
    self.videoGravityTapChangeGestureRecognizer = videoGravityTapChangeGestureRecognizer;
}

- (void)layoutControlsViewInView:(UIView *)view
{
    SRGControlsBackgroundView *controlsBackgroundView = [[SRGControlsBackgroundView alloc] init];
    controlsBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:controlsBackgroundView];
    self.controlsBackgroundView = controlsBackgroundView;
    
    [NSLayoutConstraint activateConstraints: @[
        [controlsBackgroundView.topAnchor constraintEqualToAnchor:view.topAnchor],
        [controlsBackgroundView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [controlsBackgroundView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor]
    ]];
    
    SRGControlsView *controlsView = [[SRGControlsView alloc] init];
    controlsView.translatesAutoresizingMaskIntoConstraints = NO;
    controlsView.delegate = self;
    [view addSubview:controlsView];
    self.controlsView = controlsView;
    
    [NSLayoutConstraint activateConstraints: @[
        [controlsView.topAnchor constraintEqualToAnchor:view.topAnchor],
        [controlsView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [controlsView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor]
    ]];
    
    SRGAccessibilityView *accessibilityView = [[SRGAccessibilityView alloc] init];
    accessibilityView.userInteractionEnabled = YES;
    accessibilityView.translatesAutoresizingMaskIntoConstraints = NO;
    accessibilityView.accessibilityFrameView = controlsView;
    [view addSubview:accessibilityView];
    
    [NSLayoutConstraint activateConstraints:@[
        [accessibilityView.centerXAnchor constraintEqualToAnchor:controlsView.centerXAnchor],
        [accessibilityView.centerYAnchor constraintEqualToAnchor:controlsView.centerYAnchor],
        [accessibilityView.widthAnchor constraintEqualToConstant:1.f],
        [accessibilityView.heightAnchor constraintEqualToConstant:1.f]
    ]];
}

- (void)layoutNotificationViewInView:(UIView *)view
{
    SRGNotificationView *notificationView = [[SRGNotificationView alloc] init];
    notificationView.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:notificationView];
    self.notificationView = notificationView;
    
    [NSLayoutConstraint activateConstraints:@[
        [notificationView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [notificationView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [notificationView.topAnchor constraintEqualToAnchor:self.playbackView.bottomAnchor],
        [notificationView.bottomAnchor constraintEqualToAnchor:self.timelineView.topAnchor],
        self.notificationHeightConstraint = [notificationView.heightAnchor constraintEqualToConstant:0.f],
        [notificationView.topAnchor constraintEqualToAnchor:self.controlsBackgroundView.bottomAnchor],
        [notificationView.topAnchor constraintEqualToAnchor:self.controlsView.bottomAnchor]
    ]];
}

- (void)layoutAvailabilityViewInView:(UIView *)view
{
    SRGAvailabilityView *availabilityView = [[SRGAvailabilityView alloc] init];
    availabilityView.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:availabilityView];
    self.availabilityView = availabilityView;
    
    [NSLayoutConstraint activateConstraints:@[
        [availabilityView.topAnchor constraintEqualToAnchor:self.playbackView.topAnchor],
        [availabilityView.bottomAnchor constraintEqualToAnchor:self.playbackView.bottomAnchor],
        [availabilityView.leadingAnchor constraintEqualToAnchor:self.playbackView.leadingAnchor],
        [availabilityView.trailingAnchor constraintEqualToAnchor:self.playbackView.trailingAnchor]
    ]];
}

- (void)layoutContinuousPlaybackViewInView:(UIView *)view
{
    SRGContinuousPlaybackView *continuousPlaybackView = [[SRGContinuousPlaybackView alloc] init];
    continuousPlaybackView.translatesAutoresizingMaskIntoConstraints = NO;
    continuousPlaybackView.delegate = self;
    [view addSubview:continuousPlaybackView];
    self.continuousPlaybackView = continuousPlaybackView;
    
    [NSLayoutConstraint activateConstraints:@[
        [continuousPlaybackView.topAnchor constraintEqualToAnchor:self.playbackView.topAnchor],
        [continuousPlaybackView.bottomAnchor constraintEqualToAnchor:self.playbackView.bottomAnchor],
        [continuousPlaybackView.leadingAnchor constraintEqualToAnchor:self.playbackView.leadingAnchor],
        [continuousPlaybackView.trailingAnchor constraintEqualToAnchor:self.playbackView.trailingAnchor]
    ]];
}

- (void)layoutErrorViewInView:(UIView *)view
{
    SRGErrorView *errorView = [[SRGErrorView alloc] init];
    errorView.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:errorView];
    self.errorView = errorView;
    
    [NSLayoutConstraint activateConstraints:@[
        [errorView.topAnchor constraintEqualToAnchor:self.playbackView.topAnchor],
        [errorView.bottomAnchor constraintEqualToAnchor:self.playbackView.bottomAnchor],
        [errorView.leadingAnchor constraintEqualToAnchor:self.playbackView.leadingAnchor],
        [errorView.trailingAnchor constraintEqualToAnchor:self.playbackView.trailingAnchor]
    ]];
}

#pragma mark Overrdes

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    [self setNeedsLayoutAnimated:NO];
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];
    
    if (newWindow) {
        [self restartInactivityTracker];
        
        @weakify(self)
        [self.controller addObserver:self keyPath:@keypath(SRGLetterboxController.new, mediaPlayerController.player.externalPlaybackActive) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            
            // Called e.g. when the route is changed from the control center
            [self showAirPlayNotificationMessageIfNeededAnimated:YES];
        }];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationDidBecomeActive:)
                                                   name:UIApplicationDidBecomeActiveNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(serviceSettingsDidChange:)
                                                   name:SRGLetterboxServiceSettingsDidChangeNotification
                                                 object:SRGLetterboxService.sharedService];
        
        // Automatically resumes in the view when displayed and if picture in picture was active
        if (SRGLetterboxService.sharedService.controller == self.controller) {
            [SRGLetterboxService.sharedService stopPictureInPictureRestoreUserInterface:NO];
        }
        
        [self showAirPlayNotificationMessageIfNeededAnimated:NO];
    }
    else {
        [self stopInactivityTracker];
        [self dismissNotificationViewAnimated:NO];
        
        [self.controller removeObserver:self keyPath:@keypath(SRGLetterboxController.new, mediaPlayerController.player.externalPlaybackActive)];
        
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:UIApplicationDidBecomeActiveNotification
                                                    object:nil];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:SRGLetterboxServiceSettingsDidChangeNotification
                                                    object:SRGLetterboxService.sharedService];
    }
}

- (void)voiceOverStatusDidChange
{
    [super voiceOverStatusDidChange];
    
    if (UIAccessibilityIsVoiceOverRunning()) {
        [self setTogglableUserInterfaceHidden:NO animated:YES];
    }
    
    [self restartInactivityTracker];
}

- (void)willDetachFromController
{
    [super willDetachFromController];
    
    SRGMediaPlayerController *mediaPlayerController = self.controller.mediaPlayerController;
    if (mediaPlayerController.view.superview == self.playbackView) {
        [mediaPlayerController.view removeFromSuperview];
    }
}

- (void)didDetachFromController
{
    [super didDetachFromController];
    
    self.controlsBackgroundView.controller = nil;
    self.controlsView.controller = nil;
    self.errorView.controller = nil;
    self.availabilityView.controller = nil;
    self.continuousPlaybackView.controller = nil;
    self.timelineView.controller = nil;
    
    // Notifications are transient and therefore do not need to be persisted at the controller level. They can be simply
    // cleaned up when the controller changes.
    self.notificationMessage = nil;
    
    [self unregisterObservers];
    [self setNeedsLayoutAnimated:NO];
}

- (void)didAttachToController
{
    [super didAttachToController];
    
    SRGLetterboxController *controller = self.controller;
    self.controlsBackgroundView.controller = controller;
    self.controlsView.controller = controller;
    self.errorView.controller = controller;
    self.availabilityView.controller = controller;
    self.continuousPlaybackView.controller = controller;
    self.timelineView.controller = controller;
    
    [self registerObservers];
    
    UIView *mediaPlayerView = controller.mediaPlayerController.view;
    if (mediaPlayerView) {
        [self.playbackView addSubview:mediaPlayerView];
        
        // Force autolayout to ensure the layout is immediately correct
        mediaPlayerView.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[ [mediaPlayerView.topAnchor constraintEqualToAnchor:self.playbackView.topAnchor],
                                                   [mediaPlayerView.bottomAnchor constraintEqualToAnchor:self.playbackView.bottomAnchor],
                                                   [mediaPlayerView.leftAnchor constraintEqualToAnchor:self.playbackView.leftAnchor],
                                                   [mediaPlayerView.rightAnchor constraintEqualToAnchor:self.playbackView.rightAnchor] ]];
        
        [self.playbackView layoutIfNeeded];
    }
    
    [self setNeedsLayoutAnimated:NO];
}

- (void)metadataDidChange
{
    [super metadataDidChange];
    
    [self.imageView srg_requestImageForObject:self.controller.displayableMedia withScale:SRGImageScaleLarge type:SRGImageTypeDefault];
}

- (void)playbackDidFail
{
    [super playbackDidFail];
    
    [self setNeedsLayoutAnimated:YES];
}

- (void)immediatelyUpdateLayoutForUserInterfaceHidden:(BOOL)userInterfaceHidden
{
    [super immediatelyUpdateLayoutForUserInterfaceHidden:userInterfaceHidden];
    
    BOOL isFrameFullScreen = CGRectEqualToRect(self.window.bounds, self.frame);
    self.videoGravityTapChangeGestureRecognizer.enabled = self.fullScreen || isFrameFullScreen;
}

- (void)setNeedsLayoutAnimated:(BOOL)animated
{
    [self setNeedsLayoutAnimated:animated withAdditionalAnimations:nil];
}

#pragma mark Getters and setters

- (void)setFullScreen:(BOOL)fullScreen
{
    [self setFullScreen:fullScreen animated:NO];
}

- (void)setFullScreen:(BOOL)fullScreen animated:(BOOL)animated
{
    if (! [self.delegate respondsToSelector:@selector(letterboxView:toggleFullScreen:animated:withCompletionHandler:)]) {
        return;
    }
    
    if (_fullScreen == fullScreen) {
        return;
    }
    
    if (self.fullScreenAnimationRunning) {
        SRGLetterboxLogInfo(@"view", @"A full screen animation is already running");
        return;
    }
    
    self.fullScreenAnimationRunning = YES;
    
    [self.delegate letterboxView:self toggleFullScreen:fullScreen animated:animated withCompletionHandler:^(BOOL finished) {
        if (finished) {
            self->_fullScreen = fullScreen;
            
            BOOL isFrameFullScreen = self.window && CGRectEqualToRect(self.window.bounds, self.frame);
            self.videoGravityTapChangeGestureRecognizer.enabled = self.fullScreen || isFrameFullScreen;
            [self setNeedsLayoutAnimated:animated];
        }
        self.fullScreenAnimationRunning = NO;
    }];
}

- (CGFloat)aspectRatio
{
    SRGChapter *mainChapter = self.controller.mediaComposition.mainChapter;
    if (mainChapter && mainChapter.aspectRatio != SRGAspectRatioUndefined) {
        return mainChapter.aspectRatio;
    }
    else if (self.previousAspectRatio != SRGAspectRatioUndefined) {
        return self.previousAspectRatio;
    }
    else {
        return 16.f / 9.f;
    }
}

- (void)setInactivityTimer:(NSTimer *)inactivityTimer
{
    [_inactivityTimer invalidate];
    _inactivityTimer = inactivityTimer;
}

- (SRGLetterboxViewBehavior)userInterfaceBehavior
{    
    if (self.controller.error || ! self.controller.URN) {
        return SRGLetterboxViewBehaviorForcedHidden;
    }
    
    if (self.userInterfaceTogglable && self.controller.usingAirPlay) {
        return SRGLetterboxViewBehaviorForcedVisible;
    }
    
    return SRGLetterboxViewBehaviorNormal;
}

- (BOOL)isMinimal
{
    if (self.controller.error || ! self.controller.URN) {
        return self.userInterfaceTogglable || ! self.userInterfaceHidden;
    }
    else {
        return NO;
    }
}

- (BOOL)isUserInterfaceEnabled
{
    return self.parentLetterboxView.userInterfaceTogglable || ! self.parentLetterboxView.userInterfaceHidden;
}

- (void)setPreferredTimelineHeight:(CGFloat)preferredTimelineHeight animated:(BOOL)animated
{
    if (preferredTimelineHeight < 0.f) {
        SRGLetterboxLogWarning(@"view", @"The preferred timeline height must be >= 0. Fixed to 0");
        preferredTimelineHeight = 0.f;
    }
    
    if (self.preferredTimelineHeight == preferredTimelineHeight) {
        return;
    }
    
    self.preferredTimelineHeight = preferredTimelineHeight;
    [self setNeedsLayoutAnimated:animated];
}

- (BOOL)isTimelineAlwaysHidden
{
    return self.preferredTimelineHeight == 0;
}

- (void)setTimelineAlwaysHidden:(BOOL)timelineAlwaysHidden animated:(BOOL)animated
{
    [self setPreferredTimelineHeight:(timelineAlwaysHidden ? 0.f : SRGLetterboxTimelineViewDefaultHeight) animated:animated];
}

- (CGFloat)timelineHeight
{
    return self.timelineHeightConstraint.constant;
}

- (NSArray<SRGSubdivision *> *)subdivisions
{
    return self.timelineView.subdivisions;
}

- (void)setUserInterfaceStyle:(SRGMediaPlayerUserInterfaceStyle)userInterfaceStyle
{
    _userInterfaceStyle = userInterfaceStyle;
    self.controlsView.userInterfaceStyle = userInterfaceStyle;
}

- (SRGMediaPlayerUserInterfaceStyle)userInterfaceStyle
{
    return _userInterfaceStyle;
}

- (CMTime)time
{
    return self.controlsView.time;
}

- (NSDate *)date
{
    return self.controlsView.date;
}

- (BOOL)isLive
{
    return self.controlsView.live;
}

#pragma mark Observer management

- (void)registerObservers
{
    SRGLetterboxController *controller = self.controller;
    [controller addObserver:self keyPath:@keypath(controller.loading) options:0 block:^(MAKVONotification *notification) {
        [self setNeedsLayoutAnimated:YES];
    }];
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(livestreamDidFinish:)
                                               name:SRGLetterboxLivestreamDidFinishNotification
                                             object:controller];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(playbackDidContinueAutomatically:)
                                               name:SRGLetterboxPlaybackDidContinueAutomaticallyNotification
                                             object:controller];
    
    SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(playbackStateDidChange:)
                                               name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                             object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(segmentDidStart:)
                                               name:SRGMediaPlayerSegmentDidStartNotification
                                             object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(segmentDidEnd:)
                                               name:SRGMediaPlayerSegmentDidEndNotification
                                             object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(willSkipBlockedSegment:)
                                               name:SRGMediaPlayerWillSkipBlockedSegmentNotification
                                             object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(externalPlaybackStateDidChange:)
                                               name:SRGMediaPlayerExternalPlaybackStateDidChangeNotification
                                             object:mediaPlayerController];
    
    SRGMediaPlayerView *mediaPlayerView = mediaPlayerController.view;
    
    @weakify(self)
    [mediaPlayerView addObserver:self keyPath:@keypath(mediaPlayerView.readyForDisplay) options:0 block:^(MAKVONotification *notification) {
        @strongify(self)
        [self setNeedsLayoutAnimated:YES];
    }];
}

- (void)unregisterObservers
{
    SRGLetterboxController *controller = self.controller;
    [controller removeObserver:self keyPath:@keypath(controller.loading)];
    
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGLetterboxLivestreamDidFinishNotification
                                                object:controller];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGLetterboxPlaybackDidContinueAutomaticallyNotification
                                                object:controller];
    
    SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGMediaPlayerSegmentDidStartNotification
                                                object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGMediaPlayerSegmentDidEndNotification
                                                object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGMediaPlayerWillSkipBlockedSegmentNotification
                                                object:mediaPlayerController];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGMediaPlayerExternalPlaybackStateDidChangeNotification
                                                object:mediaPlayerController];
    
    SRGMediaPlayerView *mediaPlayerView = mediaPlayerController.view;
    [mediaPlayerView removeObserver:self keyPath:@keypath(mediaPlayerView.readyForDisplay)];
    
    if (mediaPlayerView.superview == self.playbackView) {
        [mediaPlayerView removeFromSuperview];
    }
}

#pragma mark UI behavior changes

- (void)setUserInterfaceHidden:(BOOL)hidden animated:(BOOL)animated togglable:(BOOL)togglable
{
    self.userInterfaceHidden = hidden;
    self.userInterfaceTogglable = togglable;
    
    if (! hidden && togglable) {
        [self restartInactivityTracker];
    }
    else {
        [self stopInactivityTracker];
    }
    
    [self setNeedsLayoutAnimated:animated];
}

- (void)setUserInterfaceHidden:(BOOL)hidden animated:(BOOL)animated
{
    [self setUserInterfaceHidden:hidden animated:animated togglable:self.userInterfaceTogglable];
}

- (void)setTogglableUserInterfaceHidden:(BOOL)hidden animated:(BOOL)animated
{
    if (! self.userInterfaceTogglable || [self userInterfaceBehavior] != SRGLetterboxViewBehaviorNormal) {
        return;
    }
    
    [self setUserInterfaceHidden:hidden animated:animated togglable:self.userInterfaceTogglable];
}

#pragma mark Layout updates

- (void)setNeedsLayoutAnimated:(BOOL)animated withAdditionalAnimations:(void (^)(void))additionalAnimations
{
    if ([self.delegate respondsToSelector:@selector(letterboxViewWillAnimateUserInterface:)]) {
        [self.delegate letterboxViewWillAnimateUserInterface:self];
    }
    
    __block BOOL userInterfaceHidden = NO;
    void (^animations)(void) = ^{
        additionalAnimations ? additionalAnimations() : nil;
        
        userInterfaceHidden = [self updateMainLayout];
        CGFloat timelineHeight = [self updateTimelineLayoutForUserInterfaceHidden:userInterfaceHidden];
        CGFloat notificationHeight = [self.notificationView updateLayoutWithMessage:self.notificationMessage width:CGRectGetWidth(self.frame)].height;
        self.notificationHeightConstraint.constant = notificationHeight;
        
        CGFloat aspectRatio = self.aspectRatio;
        self.animations ? self.animations(userInterfaceHidden, self.minimal, aspectRatio, timelineHeight + notificationHeight) : nil;
        self.previousAspectRatio = aspectRatio;
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        self.completion ? self.completion(finished) : nil;
        
        self.animations = nil;
        self.completion = nil;
    };
    
    if (animated) {
        [self layoutIfNeeded];
        [UIView animateWithDuration:0.2 animations:^{
            animations();
            [self layoutIfNeeded];
        } completion:completion];
    }
    else {
        animations();
        completion(YES);
    }
    
    [self recursivelyImmediatelyUpdateLayoutInView:self forUserInterfaceHidden:userInterfaceHidden];
}

- (BOOL)updateMainLayout
{
    BOOL userInterfaceHidden = NO;
    switch ([self userInterfaceBehavior]) {
        case SRGLetterboxViewBehaviorForcedHidden: {
            userInterfaceHidden = YES;
            break;
        }
            
        case SRGLetterboxViewBehaviorForcedVisible: {
            userInterfaceHidden = NO;
            break;
        }
            
        default: {
            userInterfaceHidden = self.userInterfaceHidden;
            break;
        }
    }
    
    SRGMediaPlayerController *mediaPlayerController = self.controller.mediaPlayerController;
    SRGMediaPlayerPlaybackState playbackState = mediaPlayerController.playbackState;
    
    // Hide video view if a video is played with AirPlay or if "true screen mirroring" is used (device screen copy with no full-screen
    // playback on the external device)
    BOOL playerViewVisible = (self.controller.media.mediaType == SRGMediaTypeVideo && mediaPlayerController.view.readyForDisplay && ! mediaPlayerController.externalNonMirroredPlaybackActive
                              && playbackState != SRGMediaPlayerPlaybackStateIdle && playbackState != SRGMediaPlayerPlaybackStatePreparing && playbackState != SRGMediaPlayerPlaybackStateEnded);
    
    // Prevent capture in production builds
    if (NSBundle.srg_letterbox_isProductionVersion && UIScreen.mainScreen.captured && ! AVAudioSession.srg_isAirPlayActive) {
        playerViewVisible = NO;
    }
    
    // Force aspect fit ratio when not full screen
    BOOL isFrameFullScreen = self.window && CGRectEqualToRect(self.window.bounds, self.frame);
    if (! self.fullScreen && ! isFrameFullScreen) {
        AVPlayerLayer *playerLayer = self.controller.mediaPlayerController.playerLayer;
        playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    }
    
    [self recursivelyUpdateLayoutInView:self forUserInterfaceHidden:userInterfaceHidden];
    
    self.imageView.alpha = playerViewVisible ? 0.f : 1.f;
    mediaPlayerController.view.alpha = playerViewVisible ? 1.f : 0.f;
    
    return userInterfaceHidden;
}

- (void)recursivelyUpdateLayoutInView:(UIView *)view forUserInterfaceHidden:(BOOL)userInterfaceHidden
{
    if ([view isKindOfClass:SRGLetterboxBaseView.class]) {
        SRGLetterboxBaseView *baseView = (SRGLetterboxBaseView *)view;
        [baseView updateLayoutForUserInterfaceHidden:userInterfaceHidden];
    }
    
    for (UIView *subview in view.subviews) {
        [self recursivelyUpdateLayoutInView:subview forUserInterfaceHidden:userInterfaceHidden];
    }
}

- (void)recursivelyImmediatelyUpdateLayoutInView:(UIView *)view forUserInterfaceHidden:(BOOL)userInterfaceHidden
{
    if ([view isKindOfClass:SRGLetterboxBaseView.class]) {
        SRGLetterboxBaseView *baseView = (SRGLetterboxBaseView *)view;
        [baseView immediatelyUpdateLayoutForUserInterfaceHidden:userInterfaceHidden];
    }
    
    for (UIView *subview in view.subviews) {
        [self recursivelyImmediatelyUpdateLayoutInView:subview forUserInterfaceHidden:userInterfaceHidden];
    }
}

- (CGFloat)updateTimelineLayoutForUserInterfaceHidden:(BOOL)userInterfaceHidden
{
    NSArray<SRGSubdivision *> *subdivisions = [self.controller.mediaComposition srgletterbox_subdivisionsForMediaPlayerController:self.controller.mediaPlayerController];
    
    // The timeline (if other content is available) is displayed when an error has been encountered, so that the user has
    // a chance to pick another media
    CGFloat timelineHeight = (subdivisions.count != 0 && ! self.timelineAlwaysHidden && ! self.controller.continuousPlaybackUpcomingMedia && (! userInterfaceHidden || self.controller.error)) ? self.preferredTimelineHeight : 0.f;
    BOOL isTimelineVisible = (timelineHeight != 0.f);
    
    // Scroll to selected index when opening the timeline. `shouldFocus` needs to be calculated before the constant is updated
    // for the following to work.
    BOOL shouldFocus = (self.timelineHeightConstraint.constant == 0.f && isTimelineVisible);
    self.timelineHeightConstraint.constant = timelineHeight;
    
    if (shouldFocus) {
        [self.timelineView scrollToCurrentSelectionAnimated:NO];
    }
    
    if (isTimelineVisible) {
        self.timelineToSafeAreaBottomConstraint.priority = kBottomConstraintGreaterPriority;
        self.timelineToSelfBottomConstraint.priority = kBottomConstraintLesserPriority;
    }
    else {
        self.timelineToSafeAreaBottomConstraint.priority = kBottomConstraintLesserPriority;
        self.timelineToSelfBottomConstraint.priority = kBottomConstraintGreaterPriority;
    }
    
    return timelineHeight;
}

- (void)animateAlongsideUserInterfaceWithAnimations:(void (^)(BOOL, BOOL, CGFloat, CGFloat))animations completion:(void (^)(BOOL))completion
{
    self.animations = animations;
    self.completion = completion;
}

#pragma mark Timer management

// For optimal results, this method must be called when any form of user interaction is detected.
- (void)restartInactivityTracker
{
    if (! UIAccessibilityIsVoiceOverRunning()) {
        @weakify(self)
        self.inactivityTimer = [NSTimer srgletterbox_timerWithTimeInterval:4. repeats:YES /* important */ block:^(NSTimer * _Nonnull timer) {
            @strongify(self)
            
            SRGMediaPlayerPlaybackState playbackState = self.controller.mediaPlayerController.playbackState;
            if (playbackState == SRGMediaPlayerPlaybackStatePlaying || playbackState == SRGMediaPlayerPlaybackStateSeeking
                    || playbackState == SRGMediaPlayerPlaybackStateStalled) {
                [self setTogglableUserInterfaceHidden:YES animated:YES];
            }
        }];
    }
    else {
        self.inactivityTimer = nil;
    }
}

- (void)stopInactivityTracker
{
    self.inactivityTimer = nil;
}

#pragma mark Notification banners

- (void)showNotificationMessage:(NSString *)notificationMessage animated:(BOOL)animated
{
    if (notificationMessage.length == 0) {
        return;
    }
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissNotificationViewAutomatically) object:nil];
    
    self.notificationMessage = notificationMessage;
    
    [self setNeedsLayoutAnimated:animated];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, notificationMessage);
    
    [self performSelector:@selector(dismissNotificationViewAutomatically) withObject:nil afterDelay:5.];
}

- (void)dismissNotificationViewAutomatically
{
    [self dismissNotificationViewAnimated:YES];
}

- (void)dismissNotificationViewAnimated:(BOOL)animated
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissNotificationViewAutomatically) object:nil];
    
    self.notificationMessage = nil;
    [self setNeedsLayoutAnimated:animated];
}

- (void)showAirPlayNotificationMessageIfNeededAnimated:(BOOL)animated
{
    if (self.controller.mediaPlayerController.externalNonMirroredPlaybackActive) {
        [self showNotificationMessage:SRGLetterboxLocalizedString(@"Playback on AirPlay", @"Message displayed when broadcasting on an AirPlay device") animated:animated];
    }
}

#pragma mark Gesture recognizers

- (void)resetInactivity:(UIGestureRecognizer *)gestureRecognizer
{
    [self restartInactivityTracker];
}

- (void)showUserInterface:(UIGestureRecognizer *)gestureRecognizer
{
    [self setTogglableUserInterfaceHidden:NO animated:YES];
}

- (void)changeVideoGravity:(UIGestureRecognizer *)gestureRecognizer
{
    @weakify(self)
    [self setNeedsLayoutAnimated:YES withAdditionalAnimations:^{
        @strongify(self)
        AVPlayerLayer *playerLayer = self.controller.mediaPlayerController.playerLayer;
        if ([playerLayer.videoGravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
            playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        }
        else {
            playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        }
    }];
}

#pragma mark Actions

- (void)toggleFullScreen:(id)sender
{
    [self setFullScreen:!self.isFullScreen animated:YES];
}

#pragma mark SRGContinuousPlaybackViewDelegate protocol

- (void)continuousPlaybackView:(SRGContinuousPlaybackView *)continuousPlaybackView didEngageWithUpcomingMedia:(SRGMedia *)upcomingMedia
{
    [self setTogglableUserInterfaceHidden:YES animated:NO];
    
    if ([self.delegate respondsToSelector:@selector(letterboxView:didEngageInContinuousPlaybackWithUpcomingMedia:)]) {
        [self.delegate letterboxView:self didEngageInContinuousPlaybackWithUpcomingMedia:upcomingMedia];
    }
}

- (void)continuousPlaybackView:(SRGContinuousPlaybackView *)continuousPlaybackView didCancelWithUpcomingMedia:(SRGMedia *)upcomingMedia
{
    if ([self.delegate respondsToSelector:@selector(letterboxView:didCancelContinuousPlaybackWithUpcomingMedia:)]) {
        [self.delegate letterboxView:self didCancelContinuousPlaybackWithUpcomingMedia:upcomingMedia];
    }
}

#pragma mark SRGControlsViewDelegate protocol

- (void)controlsViewDidTap:(SRGControlsView *)controlsView
{
    // Defer execution to avoid conflicts with the activity gesture
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setTogglableUserInterfaceHidden:YES animated:YES];
    });
}

- (BOOL)controlsViewShouldHideFullScreenButton:(SRGControlsView *)controlsView
{
    if (! [self.delegate respondsToSelector:@selector(letterboxView:toggleFullScreen:animated:withCompletionHandler:)]) {
        return YES;
    }
    
    if (! [self.delegate respondsToSelector:@selector(letterboxViewShouldDisplayFullScreenToggleButton:)]) {
        return NO;
    }
    
    return ! [self.delegate letterboxViewShouldDisplayFullScreenToggleButton:self];
}

- (void)controlsViewDidToggleFullScreen:(SRGControlsView *)controlsView
{
    [self setFullScreen:!self.isFullScreen animated:YES];
}

- (void)controlsView:(SRGControlsView *)controlsView isMovingSliderToTime:(CMTime)time date:(NSDate *)date withValue:(float)value interactive:(BOOL)interactive
{
    SRGSubdivision *subdivision = [self.controller displayableSubdivisionAtTime:time];
    
    if (interactive) {
        NSInteger selectedIndex = [self.timelineView.subdivisions indexOfObject:subdivision];
        self.timelineView.selectedIndex = selectedIndex;
        [self.timelineView scrollToCurrentSelectionAnimated:YES];
    }
    self.timelineView.time = time;
    
    if ([self.delegate respondsToSelector:@selector(letterboxView:didScrollWithSubdivision:time:date:interactive:)]) {
        [self.delegate letterboxView:self didScrollWithSubdivision:subdivision time:time date:date interactive:interactive];
    }
    
    // Provide immediate updates during seeks only, otherwise rely on usual image updates (`-metadataDidChange:`)
    if (self.controller.playbackState == SRGMediaPlayerPlaybackStateSeeking) {
        [self.imageView srg_requestImageForObject:subdivision ?: self.controller.displayableMedia withScale:SRGImageScaleLarge type:SRGImageTypeDefault];
    }
}

- (void)controlsViewWillShowTrackSelectionPopover:(SRGControlsView *)controlsView
{
    [self stopInactivityTracker];
}

- (void)controlsViewDidHideTrackSelectionPopover:(SRGControlsView *)controlsView
{
    [self restartInactivityTracker];
}

#pragma mark SRGLetterboxTimelineViewDelegate protocol

- (void)letterboxTimelineView:(SRGLetterboxTimelineView *)timelineView didSelectSubdivision:(SRGSubdivision *)subdivision
{
    if ([self.delegate respondsToSelector:@selector(letterboxView:didSelectSubdivision:)]) {
        [self.delegate letterboxView:self didSelectSubdivision:subdivision];
    }
}

- (void)letterboxTimelineView:(SRGLetterboxTimelineView *)timelineView didLongPressSubdivision:(SRGSubdivision *)subdivision
{
    if ([self.delegate respondsToSelector:@selector(letterboxView:didLongPressSubdivision:)]) {
        [self.delegate letterboxView:self didLongPressSubdivision:subdivision];
    }
}

#pragma mark UIGestureRecognizerDelegate protocol

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    if (gestureRecognizer == self.videoGravityTapChangeGestureRecognizer) {
        return [otherGestureRecognizer isKindOfClass:SRGActivityGestureRecognizer.class] || otherGestureRecognizer == self.showUserInterfaceTapGestureRecognizer;
    }
    else {
        return NO;
    }
}

#pragma mark Notifications

- (void)livestreamDidFinish:(NSNotification *)notification
{
    [self showNotificationMessage:SRGLetterboxLocalizedString(@"Live broadcast ended", @"Notification message displayed when a live broadcast has finished.") animated:YES];
}

- (void)playbackDidContinueAutomatically:(NSNotification *)notification
{
    [self setTogglableUserInterfaceHidden:YES animated:NO];
}

- (void)playbackStateDidChange:(NSNotification *)notification
{
    SRGMediaPlayerPlaybackState previousPlaybackState = [notification.userInfo[SRGMediaPlayerPreviousPlaybackStateKey] integerValue];
    SRGMediaPlayerPlaybackState playbackState = [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue];
    
    if (previousPlaybackState == SRGMediaPlayerPlaybackStatePreparing && playbackState != SRGMediaPlayerPlaybackStateIdle) {
        [self.timelineView scrollToCurrentSelectionAnimated:YES];
        [self showAirPlayNotificationMessageIfNeededAnimated:YES];
    }
    
    if (playbackState == SRGMediaPlayerPlaybackStatePaused || playbackState == SRGMediaPlayerPlaybackStateEnded) {
        [self setTogglableUserInterfaceHidden:NO animated:YES];
    }
    else if (playbackState == SRGMediaPlayerPlaybackStateSeeking) {
        NSValue *seekTimeValue = notification.userInfo[SRGMediaPlayerSeekTimeKey];
        if (seekTimeValue) {
            CMTime seekTime = seekTimeValue.CMTimeValue;
            SRGSubdivision *subdivision = [self.controller displayableSubdivisionAtTime:seekTime];
            self.timelineView.selectedIndex = [self.timelineView.subdivisions indexOfObject:subdivision];
            self.timelineView.time = seekTime;
        }
    }
    
    [self setNeedsLayoutAnimated:YES];
}

- (void)segmentDidStart:(NSNotification *)notification
{
    SRGSubdivision *subdivision = notification.userInfo[SRGMediaPlayerSegmentKey];
    self.timelineView.selectedIndex = [self.timelineView.subdivisions indexOfObject:subdivision];
    [self.timelineView scrollToCurrentSelectionAnimated:YES];
}

- (void)segmentDidEnd:(NSNotification *)notification
{
    self.timelineView.selectedIndex = NSNotFound;
}

- (void)willSkipBlockedSegment:(NSNotification *)notification
{
    SRGSubdivision *subdivision = notification.userInfo[SRGMediaPlayerSegmentKey];
    NSString *notificationMessage = SRGMessageForSkippedSegmentWithBlockingReason([subdivision blockingReasonAtDate:NSDate.date]);
    [self showNotificationMessage:notificationMessage animated:YES];
}

- (void)externalPlaybackStateDidChange:(NSNotification *)notification
{
    [self showAirPlayNotificationMessageIfNeededAnimated:YES];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self setNeedsLayoutAnimated:YES];
}

- (void)serviceSettingsDidChange:(NSNotification *)notification
{
    [self setNeedsLayoutAnimated:YES];
}

@end

#endif
