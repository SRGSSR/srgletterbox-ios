//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxView.h"

#import "NSBundle+SRGLetterbox.h"
#import "SRGLetterboxController+Private.h"
#import "SRGLetterboxError.h"
#import "SRGLetterboxLogger.h"
#import "SRGLetterboxService+Private.h"
#import "UIFont+SRGLetterbox.h"
#import "UIImageView+SRGLetterbox.h"

#import <Masonry/Masonry.h>
#import <libextobjc/libextobjc.h>
#import <ASValueTrackingSlider/ASValueTrackingSlider.h>

static void commonInit(SRGLetterboxView *self);

@interface SRGLetterboxView () <ASValueTrackingSliderDataSource>

@property (nonatomic, weak) IBOutlet UIView *playerView;
@property (nonatomic, weak) IBOutlet UIImageView *imageView;
@property (nonatomic, weak) IBOutlet UIView *controlsView;
@property (nonatomic, weak) IBOutlet SRGPlaybackButton *playbackButton;
@property (nonatomic, weak) IBOutlet ASValueTrackingSlider *timeSlider;
@property (nonatomic, weak) IBOutlet UIButton *forwardSeekButton;
@property (nonatomic, weak) IBOutlet UIButton *backwardSeekButton;
@property (nonatomic, weak) IBOutlet UIButton *seekToLiveButton;

@property (nonatomic, weak) UIImageView *loadingImageView;

@property (nonatomic, weak) IBOutlet UIView *errorView;
@property (nonatomic, weak) IBOutlet UILabel *errorLabel;

@property (nonatomic, weak) IBOutlet SRGPictureInPictureButton *pictureInPictureButton;

@property (nonatomic, weak) IBOutlet SRGAirplayView *airplayView;
@property (nonatomic, weak) IBOutlet UILabel *airplayLabel;
@property (nonatomic, weak) IBOutlet SRGAirplayButton *airplayButton;
@property (nonatomic, weak) IBOutlet SRGTracksButton *tracksButton;
@property (nonatomic, weak) IBOutlet UIButton *fullScreenButton;

@property (nonatomic) NSTimer *inactivityTimer;
@property (nonatomic, weak) id periodicTimeObserver;

@property (nonatomic, getter=isUserInterfaceHidden) BOOL userInterfaceHidden;
@property (nonatomic, getter=isUserInterfaceTogglable) BOOL userInterfaceTogglable;
@property (nonatomic, getter=isFullScreen) BOOL fullScreen;
@property (nonatomic, getter=isFullScreenAnimationRunning) BOOL fullScreenAnimationRunning;
@property (nonatomic, getter=isShowingPopup) BOOL showingPopup;

@property (nonatomic) NSNumber *airplayRestorationHidden;               // Backup value when the UI behavior is temporarily changed during Airplay playback
@property (nonatomic) NSNumber *airplayRestorationTogglable;            // Backup value when the UI behavior is temporarily changed during Airplay playback

@property (nonatomic) NSNumber *errorRestorationHidden;                 // Backup value when the UI behavior is temporarily changed because an error is displayed
@property (nonatomic) NSNumber *errorRestorationTogglable;              // Backup value when the UI behavior is temporarily changed because an error is displayed

@property (nonatomic, copy) void (^animations)(BOOL hidden);
@property (nonatomic, copy) void (^completion)(BOOL finished);

@end

@implementation SRGLetterboxView {
@private
    BOOL _inWillAnimateUserInterface;
}

#pragma mark Object lifecycle

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        commonInit(self);
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    if (self = [super initWithCoder:aDecoder]) {
        commonInit(self);
    }
    return self;
}

- (void)dealloc
{
    self.controller = nil;
}

#pragma mark View lifecycle

- (void)awakeFromNib
{
    [super awakeFromNib];
    
    // FIXME: Currently added in code, but we should provide a more customizable activity indicator
    //        in the SRG Media Player library soon. Replace when available
    UIImageView *loadingImageView = [UIImageView srg_loadingImageView35WithTintColor:[UIColor whiteColor]];
    loadingImageView.alpha = 0.f;
    [self.playerView insertSubview:loadingImageView aboveSubview:self.playbackButton];
    [loadingImageView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.bottom.equalTo(self.playbackButton.mas_top).with.offset(-20.f);
        make.centerX.equalTo(self.playbackButton.mas_centerX);
    }];
    self.loadingImageView = loadingImageView;
    
    self.backwardSeekButton.alpha = 0.f;
    self.forwardSeekButton.alpha = 0.f;
    self.seekToLiveButton.alpha = 0.f;
    
    self.airplayView.delegate = self;
    
    self.timeSlider.resumingAfterSeek = YES;
    self.timeSlider.font = [UIFont srg_regularFontWithSize:14.f];
    self.timeSlider.popUpViewColor = UIColor.whiteColor;
    self.timeSlider.textColor = UIColor.blackColor;
    self.timeSlider.popUpViewWidthPaddingFactor = 1.5f;
    self.timeSlider.popUpViewHeightPaddingFactor = 1.f;
    self.timeSlider.popUpViewCornerRadius = 3.f;
    self.timeSlider.popUpViewArrowLength = 4.f;
    self.timeSlider.dataSource = self;
    
    self.airplayLabel.font = [UIFont srg_regularFontWithTextStyle:UIFontTextStyleFootnote];
    self.errorLabel.font = [UIFont srg_regularFontWithTextStyle:UIFontTextStyleSubheadline];
    
    self.errorView.alpha = 0.f;
    
    // Detect all touches on the player view. Other gesture recognizers can be added directly in the storyboard
    // to detect other interactions earlier
    SRGActivityGestureRecognizer *activityGestureRecognizer = [[SRGActivityGestureRecognizer alloc] initWithTarget:self
                                                                                                            action:@selector(resetInactivityTimer:)];
    activityGestureRecognizer.delegate = self;
    [self.playerView addGestureRecognizer:activityGestureRecognizer];
    
    self.fullScreenButton.hidden = [self isFullScreenButtonHidden];
    
    [self reloadData];
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];
    
    if (newWindow) {
        [self updateVisibleSubviewsAnimated:NO];
        [self updateUserInterfaceForServicePlayback];
        [self updateUserInterfaceForAirplayAnimated:NO];
        [self updateUserInterfaceForErrorAnimated:NO];
        [self reloadData];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(wirelessRouteDidChange:)
                                                     name:SRGMediaPlayerWirelessRouteDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screenDidConnect:)
                                                     name:UIScreenDidConnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screenDidDisconnect:)
                                                     name:UIScreenDidDisconnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(serviceSettingsDidChange:)
                                                     name:SRGLetterboxServiceSettingsDidChangeNotification
                                                   object:[SRGLetterboxService sharedService]];
        
        // Automatically resumes in the view when displayed and if picture in picture was active
        if ([SRGLetterboxService sharedService].controller == self.controller) {
            [[SRGLetterboxService sharedService] stopPictureInPictureRestoreUserInterface:NO];
        }
    }
    else {
        self.inactivityTimer = nil;                 // Invalidate timer
        
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:UIApplicationDidBecomeActiveNotification
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:SRGMediaPlayerWirelessRouteDidChangeNotification
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:UIScreenDidConnectNotification
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:UIScreenDidDisconnectNotification
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:SRGLetterboxServiceSettingsDidChangeNotification
                                                      object:[SRGLetterboxService sharedService]];
    }
}

#pragma mark Getters and setters

- (void)setController:(SRGLetterboxController *)controller
{
    if (_controller == controller) {
        return;
    }
    
    if (_controller) {
        SRGMediaPlayerController *previousMediaPlayerController = _controller.mediaPlayerController;
        [previousMediaPlayerController removePeriodicTimeObserver:self.periodicTimeObserver];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:SRGLetterboxMetadataDidChangeNotification
                                                      object:_controller];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:SRGLetterboxPlaybackDidFailNotification
                                                      object:_controller];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                      object:previousMediaPlayerController];
        
        if (previousMediaPlayerController.view.superview == self.playerView) {
            [previousMediaPlayerController.view removeFromSuperview];
        }
    }
    
    _controller = controller;
    
    SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
    self.playbackButton.mediaPlayerController = mediaPlayerController;
    self.pictureInPictureButton.mediaPlayerController = mediaPlayerController;
    self.airplayView.mediaPlayerController = mediaPlayerController;
    self.airplayButton.mediaPlayerController = mediaPlayerController;
    self.tracksButton.mediaPlayerController = mediaPlayerController;
    self.timeSlider.mediaPlayerController = mediaPlayerController;
    
    // Synchronize the slider popup and the loading indicator with the new controller state
    if (mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateIdle
        || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePreparing
        || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateEnded) {
        [self.timeSlider hidePopUpViewAnimated:NO];
    }
    else {
        [self.timeSlider showPopUpViewAnimated:NO];
    }
    
    [self updateLoadingIndicatorForController:controller animated:NO];
    
    if (controller) {
        SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
        
        @weakify(self)
        @weakify(controller)
        self.periodicTimeObserver = [mediaPlayerController addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1., NSEC_PER_SEC) queue:NULL usingBlock:^(CMTime time) {
            @strongify(self)
            @strongify(controller)
            [self updateControlsForController:controller animated:YES];
        }];
        [self updateControlsForController:controller animated:NO];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(mediaMetadataDidChange:)
                                                     name:SRGLetterboxMetadataDidChangeNotification
                                                   object:controller];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(mediaPlaybackDidFail:)
                                                     name:SRGLetterboxPlaybackDidFailNotification
                                                   object:controller];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playbackStateDidChange:)
                                                     name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                   object:mediaPlayerController];
        
        [self.playerView insertSubview:mediaPlayerController.view aboveSubview:self.imageView];
        
        // Force autolayout to ensure the layout is immediately correct 
        [mediaPlayerController.view mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.equalTo(self.playerView);
        }];
        
        [self.playerView layoutIfNeeded];
    }
    
    [self reloadData];
}

- (void)setDelegate:(id<SRGLetterboxViewDelegate>)delegate
{
    _delegate = delegate;
    self.fullScreenButton.hidden = [self isFullScreenButtonHidden];
}

- (void)setFullScreen:(BOOL)fullScreen
{
    [self setFullScreen:fullScreen animated:NO];
}

- (void)setFullScreen:(BOOL)fullScreen animated:(BOOL)animated
{
    if (_fullScreen == fullScreen) {
        return;
    }
    
    if (self.fullScreenAnimationRunning) {
        SRGLetterboxLogInfo(@"view", @"A full screen animation is already running");
        return;
    }
    
    self.fullScreenAnimationRunning = YES;
    
    if ([self.delegate respondsToSelector:@selector(letterboxView:toggleFullScreen:animated:withCompletionHandler:)]) {
        [self.delegate letterboxView:self toggleFullScreen:fullScreen animated:animated withCompletionHandler:^(BOOL finished) {
            if (finished) {
                self.fullScreenButton.selected = fullScreen;
                _fullScreen = fullScreen;
            }
            self.fullScreenAnimationRunning = NO;
        }];
    }
}

- (void)setInactivityTimer:(NSTimer *)inactivityTimer
{
    [_inactivityTimer invalidate];
    _inactivityTimer = inactivityTimer;
}

- (NSError *)error
{
    if (self.controller.error) {
        return self.controller.error;
    }
    else if (! self.controller.media && ! self.controller.URN) {
        return [NSError errorWithDomain:SRGLetterboxErrorDomain
                                   code:SRGLetterboxErrorCodeNotFound
                               userInfo:@{ NSLocalizedDescriptionKey : SRGLetterboxLocalizedString(@"No media", @"Text displayed when no media is available for playback") }];
    }
    else {
        return nil;
    }
}

#pragma mark Data display

// Responsible of updating the data to be displayed. Must not alter visibility of UI elements or anything else
- (void)reloadData
{
    [self.imageView srg_requestImageForObject:self.controller.media withScale:SRGImageScaleLarge placeholderImageName:@"placeholder_media-180"];
    self.errorLabel.text = [self error].localizedDescription;
}

#pragma mark UI

// Public method for changing user interface behavior. Always update interface settings, except when using non-mirrored
// Airplay
- (void)setUserInterfaceHidden:(BOOL)hidden animated:(BOOL)animated togglable:(BOOL)togglable
{
    // If usual non-mirrored Airplay playback is active, do not let the user change the current state
    if (togglable && self.controller.mediaPlayerController.externalNonMirroredPlaybackActive) {
        SRGLetterboxLogWarning(@"view", @"Cannot set the UI to togglable while playing in non-mirrored Airplay");
        return;
    }
    
    self.userInterfaceTogglable = togglable;
    
    [self common_setUserInterfaceHidden:hidden animated:animated];
}

// Show or hide the user interface, doing nothing if the interface is not togglable
- (void)setUserInterfaceHidden:(BOOL)hidden animated:(BOOL)animated
{
    if (! self.userInterfaceTogglable || self.controller.mediaPlayerController.externalNonMirroredPlaybackActive) {
        return;
    }
    
    if (self.userInterfaceHidden == hidden) {
        return;
    }
    
    [self common_setUserInterfaceHidden:hidden animated:animated];
}

// Common implementation for -setUserInterfaceHidden:... methods. Use a distinct name to make aware this is an internal
// factorisation method which is not intended for direct use. This method always show or hide the user interface
- (void)common_setUserInterfaceHidden:(BOOL)hidden animated:(BOOL)animated
{
    if ([self.delegate respondsToSelector:@selector(letterboxViewWillAnimateUserInterface:)]) {
        _inWillAnimateUserInterface = YES;
        [self.delegate letterboxViewWillAnimateUserInterface:self];
        _inWillAnimateUserInterface = NO;
    }
    
    void (^animations)(void) = ^{
        self.controlsView.alpha = hidden ? 0.f : 1.f;
        self.animations ? self.animations(hidden) : nil;
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        if (finished) {
            self.userInterfaceHidden = hidden;
        }
        self.completion ? self.completion(finished) : nil;
        
        self.animations = nil;
        self.completion = nil;
    };
    
    if (animated) {
        [UIView animateWithDuration:0.2 animations:animations completion:completion];
    }
    else {
        animations();
        completion(YES);
    }
}

// Called to update the main player subviews (player view, background image, error overlay). Independent of the status
// of the controls
- (void)updateVisibleSubviewsAnimated:(BOOL)animated
{
    void (^animations)(void) = ^{
        SRGMediaPlayerController *mediaPlayerController = self.controller.mediaPlayerController;
        
        if (mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePlaying) {
            // Hide if playing a video in Airplay or if "true screen mirroring" (device screen copy with no full-screen
            // playbackl on the initiatedByCaller device) is used
            SRGMedia *media = self.controller.media;
            BOOL hidden = (media.mediaType == SRGMediaTypeVideo) && ! mediaPlayerController.externalNonMirroredPlaybackActive;
            self.imageView.alpha = hidden ? 0.f : 1.f;
            mediaPlayerController.view.alpha = hidden ? 1.f : 0.f;
            
            [self resetInactivityTimer];
            
            if (!self.showingPopup) {
                self.showingPopup = YES;
                [self.timeSlider showPopUpViewAnimated:NO /* already in animation block */];
            }
        }
        else if (mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateEnded || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateIdle) {
            self.imageView.alpha = 1.f;
            mediaPlayerController.view.alpha = 0.f;
            
            [self.timeSlider hidePopUpViewAnimated:NO /* already in animation block */];
            self.showingPopup = NO;
            
            [self setUserInterfaceHidden:NO animated:NO /* already in animation block */];
        }        
    };
    
    if (animated) {
        [UIView animateWithDuration:0.2 animations:animations];
    }
    else {
        animations();
    }
}

- (void)updateControlsForController:(SRGLetterboxController *)controller animated:(BOOL)animated
{
    void (^animations)(void) = ^{
        self.forwardSeekButton.alpha = [controller canSeekForward] ? 1.f : 0.f;
        self.backwardSeekButton.alpha = [controller canSeekBackward] ? 1.f : 0.f;
        self.seekToLiveButton.alpha = [controller canSeekToLive] ? 1.f : 0.f;
        
        if (controller.media.contentType == SRGContentTypeLivestream) {
            if (controller.mediaPlayerController.streamType == SRGMediaPlayerStreamTypeDVR || [controller canSeekBackward] || [controller canSeekForward]) {
                self.timeSlider.alpha = 1.f;
                self.timeSlider.timeLeftValueLabel.alpha = 0.f;
                self.playbackButton.pauseImage = [UIImage imageNamed:@"pause-50" inBundle:[NSBundle srg_letterboxBundle] compatibleWithTraitCollection:nil];
            }
            else {
                self.timeSlider.alpha = 0.f;
                self.timeSlider.timeLeftValueLabel.alpha = 1.f;
                self.playbackButton.pauseImage = [UIImage imageNamed:@"stop-50" inBundle:[NSBundle srg_letterboxBundle] compatibleWithTraitCollection:nil];
            }
        }
        else {
            self.timeSlider.alpha = 1.f;
            self.timeSlider.timeLeftValueLabel.alpha = 1.f;
            self.playbackButton.pauseImage = [UIImage imageNamed:@"pause-50" inBundle:[NSBundle srg_letterboxBundle] compatibleWithTraitCollection:nil];
        }
    };
    
    if (animated) {
        [UIView animateWithDuration:0.2 animations:animations];
    }
    else {
        animations();
    }
}

// FIXME: Improve fragile state-based implementation
- (void)updateUserInterfaceForAirplayAnimated:(BOOL)animated
{
    if (self.controller.mediaPlayerController.externalNonMirroredPlaybackActive) {
        if (! self.airplayRestorationTogglable) {
            self.airplayRestorationHidden = @(self.userInterfaceHidden);
            self.airplayRestorationTogglable = @(self.userInterfaceTogglable);
            
            [self setUserInterfaceHidden:NO animated:animated togglable:NO];
        }
    }
    else if (self.airplayRestorationTogglable) {
        if (self.airplayRestorationTogglable.boolValue) {
            [self setUserInterfaceHidden:YES animated:animated togglable:YES];
        }
        else {
            [self setUserInterfaceHidden:self.airplayRestorationHidden.boolValue animated:animated togglable:NO];
        }
        
        self.airplayRestorationHidden = nil;
        self.airplayRestorationTogglable = nil;
    }
}

// FIXME: Improve fragile state-based implementation
- (void)updateUserInterfaceForErrorAnimated:(BOOL)animated
{
    if ([self error]) {
        self.errorView.alpha = 1.f;
        
        if (! self.errorRestorationTogglable) {
            self.errorRestorationHidden = @(self.userInterfaceHidden);
            self.errorRestorationTogglable = @(self.userInterfaceTogglable);
            
            [self setUserInterfaceHidden:YES animated:animated togglable:NO];        
        }
    }
    else {
        self.errorView.alpha = 0.f;
        
        if (self.errorRestorationTogglable) {
            if (self.errorRestorationTogglable.boolValue) {
                [self setUserInterfaceHidden:YES animated:animated togglable:YES];
            }
            else {
                [self setUserInterfaceHidden:self.errorRestorationHidden.boolValue animated:animated togglable:NO];
            }
            
            self.errorRestorationHidden = nil;
            self.errorRestorationTogglable = nil;
        }
    }
}

- (void)updateLoadingIndicatorForController:(SRGLetterboxController *)controller animated:(BOOL)animated
{
    void (^animations)(void) = ^{
        SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
        self.loadingImageView.alpha = (! mediaPlayerController
                                       || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePlaying
                                       || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePaused
                                       || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateEnded
                                       || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateIdle) ? 0.f : 1.f;
    };
    
    if (animated) {
        [UIView animateWithDuration:0.2 animations:animations];
    }
    else {
        animations();
    }
}

- (void)updateUserInterfaceForServicePlayback
{
    self.airplayButton.alwaysHidden = ! self.controller.backgroundServicesEnabled;
    self.pictureInPictureButton.alwaysHidden = ! self.controller.pictureInPictureEnabled;
}

- (void)resetInactivityTimer
{
    self.inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:4. target:self selector:@selector(hideInterface:) userInfo:nil repeats:NO];
}

- (void)animateAlongsideUserInterfaceWithAnimations:(void (^)(BOOL))animations completion:(void (^)(BOOL finished))completion
{
    if (! _inWillAnimateUserInterface) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                       reason:@"-animateAlongsideUserInterfaceWithAnimations:completion: can omnly be called from within the -animateAlongsideUserInterfaceWithAnimations: method of the Letterbox view delegate"
                                     userInfo:nil];
    }
    
    self.animations = animations;
    self.completion = completion;
}

- (BOOL)isFullScreenButtonHidden
{
    return ! self.delegate || ! [self.delegate respondsToSelector:@selector(letterboxView:toggleFullScreen:animated:withCompletionHandler:)];
}

#pragma mark Gesture recognizers

- (void)resetInactivityTimer:(UIGestureRecognizer *)gestureRecognizer
{
    [self resetInactivityTimer];
    [self setUserInterfaceHidden:NO animated:YES];
}

- (IBAction)hideUserInterface:(UIGestureRecognizer *)gestureRecognizer
{
    [self setUserInterfaceHidden:YES animated:YES];
}

#pragma mark Timers

- (void)hideInterface:(NSTimer *)timer
{
    // Only auto-hide the UI when it makes sense (e.g. not when the player is paused or loading). When the state
    // of the player returns to playing, the inactivity timer will be reset (see -playbackStateDidChange:)
    SRGMediaPlayerController *mediaPlayerController = self.controller.mediaPlayerController;
    if (mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePlaying
            || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateSeeking
            || mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateStalled) {
        [self setUserInterfaceHidden:YES animated:YES];
    }
}

#pragma mark Actions

- (IBAction)seekBackward:(id)sender
{
    [self.controller seekBackwardWithCompletionHandler:nil];
}

- (IBAction)seekForward:(id)sender
{
    [self.controller seekForwardWithCompletionHandler:nil];
}

- (IBAction)toggleFullScreen:(id)sender
{
    [self setFullScreen:!self.isFullScreen animated:YES];
}

- (IBAction)seekToLive:(id)sender
{
    [self.controller seekToLiveWithCompletionHandler:nil];
}

#pragma mark ASValueTrackingSliderDataSource protocol

- (NSAttributedString *)slider:(ASValueTrackingSlider *)slider attributedStringForValue:(float)value;
{
    if (self.controller.media.contentType == SRGContentTypeLivestream) {
        
        slider.popUpViewColor = (self.timeSlider.isLive) ? UIColor.redColor : UIColor.whiteColor;
        slider.textColor = (self.timeSlider.isLive) ? UIColor.whiteColor : UIColor.blackColor;
        
        static dispatch_once_t onceToken;
        static NSDateFormatter *dateFormatter;
        dispatch_once(&onceToken, ^{
            dateFormatter = [[NSDateFormatter alloc] init];
            dateFormatter.dateStyle = kCFDateFormatterNoStyle;
            dateFormatter.timeStyle = kCFDateFormatterShortStyle;
        });
        
        NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:@"  " attributes:@{ NSFontAttributeName : [UIFont srg_awesomeFontWithSize:13.f] }];
        
        NSString *string = (self.timeSlider.isLive) ? NSLocalizedString(@"Live", nil) : [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:self.timeSlider.value - self.timeSlider.maximumValue]];
        [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:string attributes:@{ NSFontAttributeName : [UIFont srg_regularFontWithSize:13.f] }]];
        
        return [attributedString copy];
    }
    else {
        slider.popUpViewColor = UIColor.whiteColor;
        slider.textColor = UIColor.blackColor;
        
        return [[NSAttributedString alloc] initWithString:self.timeSlider.valueString ?: @"--:--"];
    }
}

#pragma mark SRGAirplayViewDelegate protocol

- (void)airplayView:(SRGAirplayView *)airplayView didShowWithAirplayRouteName:(NSString *)routeName
{
    self.airplayLabel.text = SRGAirplayRouteDescription();
}

#pragma mark UIGestureRecognizerDelegate protocol

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

#pragma mark Notifications

- (void)mediaMetadataDidChange:(NSNotification *)notification
{
    [self updateVisibleSubviewsAnimated:YES];
    [self reloadData];
}

- (void)mediaPlaybackDidFail:(NSNotification *)notification
{
    [self updateVisibleSubviewsAnimated:YES];
    [self updateUserInterfaceForErrorAnimated:YES];
    [self reloadData];
}

- (void)playbackStateDidChange:(NSNotification *)notification
{
    [self updateVisibleSubviewsAnimated:YES];
    [self updateUserInterfaceForErrorAnimated:YES];
    [self updateUserInterfaceForAirplayAnimated:YES];
    [self updateLoadingIndicatorForController:self.controller animated:YES];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self updateVisibleSubviewsAnimated:YES];
}

- (void)wirelessRouteDidChange:(NSNotification *)notification
{
    [self updateVisibleSubviewsAnimated:YES];
    [self updateUserInterfaceForAirplayAnimated:YES];
}

- (void)screenDidConnect:(NSNotification *)notification
{
    [self updateVisibleSubviewsAnimated:YES];
}

- (void)screenDidDisconnect:(NSNotification *)notification
{
    [self updateVisibleSubviewsAnimated:YES];
}

- (void)serviceSettingsDidChange:(NSNotification *)notification
{
    [self reloadData];
    [self updateVisibleSubviewsAnimated:YES];
    [self updateUserInterfaceForAirplayAnimated:YES];
    [self updateUserInterfaceForServicePlayback];
}

@end

static void commonInit(SRGLetterboxView *self)
{
    UIView *view = [[[NSBundle srg_letterboxBundle] loadNibNamed:NSStringFromClass([self class]) owner:self options:nil] firstObject];
    [self addSubview:view];
    [view mas_makeConstraints:^(MASConstraintMaker *make) {
        make.edges.equalTo(self);
    }];
    
    self.userInterfaceHidden = NO;
    self.userInterfaceTogglable = YES;
}
