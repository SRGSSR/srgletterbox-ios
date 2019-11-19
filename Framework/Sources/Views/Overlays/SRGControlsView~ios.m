//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGControlsView.h"

#import "NSBundle+SRGLetterbox.h"
#import "NSDateComponentsFormatter+SRGLetterbox.h"
#import "NSTimer+SRGLetterbox.h"
#import "SRGControlWrapperView.h"
#import "SRGFullScreenButton.h"
#import "SRGLetterboxController+Private.h"
#import "SRGLetterboxControllerView+Subclassing.h"
#import "SRGLetterboxPlaybackButton.h"
#import "SRGLetterboxTimeSlider.h"
#import "SRGLetterboxView+Private.h"
#import "SRGLiveLabel.h"
#import "UIFont+SRGLetterbox.h"
#import "UIImage+SRGLetterbox.h"

#import <libextobjc/libextobjc.h>
#import <SRGAppearance/SRGAppearance.h>

@interface SRGControlsView ()

@property (nonatomic, weak) IBOutlet SRGLetterboxPlaybackButton *playbackButton;
@property (nonatomic, weak) IBOutlet UIButton *backwardSeekButton;
@property (nonatomic, weak) IBOutlet UIButton *forwardSeekButton;
@property (nonatomic, weak) IBOutlet UIButton *skipToLiveButton;

@property (nonatomic, weak) IBOutlet UIStackView *bottomStackView;
@property (nonatomic, weak) IBOutlet SRGViewModeButton *viewModeButton;
@property (nonatomic, weak) IBOutlet SRGAirPlayButton *airPlayButton;
@property (nonatomic, weak) IBOutlet SRGPictureInPictureButton *pictureInPictureButton;
@property (nonatomic, weak) IBOutlet SRGLetterboxTimeSlider *timeSlider;
@property (nonatomic, weak) IBOutlet SRGTracksButton *tracksButton;
@property (nonatomic, weak) IBOutlet SRGFullScreenButton *fullScreenPhantomButton;

@property (nonatomic, weak) IBOutlet UILabel *durationLabel;
@property (nonatomic, weak) IBOutlet SRGControlWrapperView *durationLabelWrapperView;
@property (nonatomic, weak) IBOutlet SRGLiveLabel *liveLabel;
@property (nonatomic, weak) IBOutlet SRGControlWrapperView *liveLabelWrapperView;

@property (nonatomic, weak) IBOutlet NSLayoutConstraint *horizontalSpacingPlaybackToBackwardConstraint;
@property (nonatomic, weak) IBOutlet NSLayoutConstraint *horizontalSpacingPlaybackToForwardConstraint;
@property (nonatomic, weak) IBOutlet NSLayoutConstraint *horizontalSpacingForwardToSkipToLiveConstraint;

@property (nonatomic, weak) SRGFullScreenButton *fullScreenButton;

@end

@implementation SRGControlsView

@synthesize userInterfaceStyle = _userInterfaceStyle;

#pragma mark Getters and setters

- (void)setUserInterfaceStyle:(SRGMediaPlayerUserInterfaceStyle)userInterfaceStyle
{
    _userInterfaceStyle = userInterfaceStyle;
    self.tracksButton.userInterfaceStyle = userInterfaceStyle;
}

- (SRGMediaPlayerUserInterfaceStyle)userInterfaceStyle
{
    return _userInterfaceStyle;
}

- (CMTime)time
{
    return self.timeSlider.time;
}

- (NSDate *)date
{
    return self.timeSlider.date;
}

- (BOOL)isLive
{
    return self.timeSlider.live;
}

#pragma mark Overrides

- (void)awakeFromNib
{
    [super awakeFromNib];
    
    self.backgroundColor = UIColor.clearColor;
    
    self.backwardSeekButton.alpha = 0.f;
    self.forwardSeekButton.alpha = 0.f;
    self.skipToLiveButton.alpha = 0.f;
    
    self.timeSlider.alpha = 0.f;
    self.timeSlider.resumingAfterSeek = YES;
    self.timeSlider.delegate = self;
    
    self.tracksButton.delegate = self;
    
    // Always hidden from view. Only used to define the frame of the real full screen button, injected at the top of
    // the view hierarchy at runtime.
    self.fullScreenPhantomButton.alpha = 0.f;
    
    self.airPlayButton.audioImage = [UIImage imageNamed:@"airplay_audio" inBundle:NSBundle.srg_letterboxBundle compatibleWithTraitCollection:nil];
    self.airPlayButton.videoImage = [UIImage imageNamed:@"airplay_video" inBundle:NSBundle.srg_letterboxBundle compatibleWithTraitCollection:nil];
    self.pictureInPictureButton.startImage = [UIImage imageNamed:@"picture_in_picture_start" inBundle:NSBundle.srg_letterboxBundle compatibleWithTraitCollection:nil];
    self.pictureInPictureButton.stopImage = [UIImage imageNamed:@"picture_in_picture_stop" inBundle:NSBundle.srg_letterboxBundle compatibleWithTraitCollection:nil];
    self.tracksButton.image = [UIImage imageNamed:@"subtitles_off" inBundle:NSBundle.srg_letterboxBundle compatibleWithTraitCollection:nil];
    self.tracksButton.selectedImage = [UIImage imageNamed:@"subtitles_on" inBundle:NSBundle.srg_letterboxBundle compatibleWithTraitCollection:nil];
    
    static NSDateComponentsFormatter *s_dateComponentsFormatter;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_dateComponentsFormatter = [[NSDateComponentsFormatter alloc] init];
        s_dateComponentsFormatter.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
        s_dateComponentsFormatter.allowedUnits = NSCalendarUnitSecond;
    });
    
    self.backwardSeekButton.accessibilityLabel = [NSString stringWithFormat:SRGLetterboxAccessibilityLocalizedString(@"%@ backward", @"Seek backward button label with a custom time range"),
                                                  [s_dateComponentsFormatter stringFromTimeInterval:SRGLetterboxBackwardSkipInterval]];
    self.forwardSeekButton.accessibilityLabel = [NSString stringWithFormat:SRGLetterboxAccessibilityLocalizedString(@"%@ forward", @"Seek forward button label with a custom time range"),
                                                 [s_dateComponentsFormatter stringFromTimeInterval:SRGLetterboxForwardSkipInterval]];
    self.skipToLiveButton.accessibilityLabel = SRGLetterboxAccessibilityLocalizedString(@"Back to live", @"Back to live label");
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];
    
    if (newWindow) {
        // Inject the full screen button as first Letterbox view. This ensures the button remains accessible at all times,
        // while its position is determined by a phantom button inserted in the bottom stack view.
        SRGLetterboxView *parentLetterboxView = self.parentLetterboxView;
        if (parentLetterboxView) {
            SRGFullScreenButton *fullScreenButton = [[SRGFullScreenButton alloc] initWithFrame:CGRectZero];
            fullScreenButton.tintColor = UIColor.whiteColor;
            fullScreenButton.selected = parentLetterboxView.fullScreen;
            [fullScreenButton addTarget:self action:@selector(toggleFullScreen:) forControlEvents:UIControlEventTouchUpInside];
            [parentLetterboxView insertSubview:fullScreenButton atIndex:parentLetterboxView.subviews.count];
            self.fullScreenButton = fullScreenButton;
            
            fullScreenButton.translatesAutoresizingMaskIntoConstraints = NO;
            [NSLayoutConstraint activateConstraints:@[ [fullScreenButton.topAnchor constraintEqualToAnchor:self.fullScreenPhantomButton.topAnchor],
                                                       [fullScreenButton.bottomAnchor constraintEqualToAnchor:self.fullScreenPhantomButton.bottomAnchor],
                                                       [fullScreenButton.leftAnchor constraintEqualToAnchor:self.fullScreenPhantomButton.leftAnchor],
                                                       [fullScreenButton.rightAnchor constraintEqualToAnchor:self.fullScreenPhantomButton.rightAnchor] ]];
        }
    }
    else {
        [self.fullScreenButton removeFromSuperview];
    }
}

- (void)willDetachFromController
{
    [super willDetachFromController];
    
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:SRGLetterboxPlaybackStateDidChangeNotification
                                                object:self.controller];
}

- (void)didDetachFromController
{
    [super didDetachFromController];
    
    self.playbackButton.controller = nil;
    
    self.pictureInPictureButton.mediaPlayerController = nil;
    self.airPlayButton.mediaPlayerController = nil;
    self.tracksButton.mediaPlayerController = nil;
    self.timeSlider.mediaPlayerController = nil;
    
    self.viewModeButton.mediaPlayerView = nil;
}

- (void)didAttachToController
{
    [super didAttachToController];
    
    SRGLetterboxController *controller = self.controller;
    self.playbackButton.controller = controller;
    
    SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
    self.pictureInPictureButton.mediaPlayerController = mediaPlayerController;
    self.airPlayButton.mediaPlayerController = mediaPlayerController;
    self.tracksButton.mediaPlayerController = mediaPlayerController;
    self.timeSlider.mediaPlayerController = mediaPlayerController;
    
    self.viewModeButton.mediaPlayerView = mediaPlayerController.view;
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(playbackStateDidChange:)
                                               name:SRGLetterboxPlaybackStateDidChangeNotification
                                             object:self.controller];
    
    [self refresh];
}

- (void)updateLayoutForUserInterfaceHidden:(BOOL)userInterfaceHidden
{
    [super updateLayoutForUserInterfaceHidden:userInterfaceHidden];
    
    SRGBlockingReason blockingReason = [self.controller.media blockingReasonAtDate:NSDate.date];
    self.alpha = (! userInterfaceHidden && blockingReason != SRGBlockingReasonStartDate && blockingReason != SRGBlockingReasonEndDate) ? 1.f : 0.f;
    
    // General playback controls
    SRGMediaPlayerPlaybackState playbackState = self.controller.playbackState;
    if (playbackState == SRGMediaPlayerPlaybackStateIdle
            || playbackState == SRGMediaPlayerPlaybackStatePreparing
            || playbackState == SRGMediaPlayerPlaybackStateEnded) {
        self.forwardSeekButton.alpha = 0.f;
        self.backwardSeekButton.alpha = 0.f;
        self.skipToLiveButton.alpha = [self.controller canSkipToLive] ? 1.f : 0.f;
        
        self.timeSlider.alpha = 0.f;
    }
    else {
        self.forwardSeekButton.alpha = [self.controller canSkipForward] ? 1.f : 0.f;
        self.backwardSeekButton.alpha = [self.controller canSkipBackward] ? 1.f : 0.f;
        self.skipToLiveButton.alpha = [self.controller canSkipToLive] ? 1.f : 0.f;
        
        SRGMediaPlayerStreamType streamType = self.controller.mediaPlayerController.streamType;
        self.timeSlider.alpha = (streamType == SRGMediaPlayerStreamTypeOnDemand || streamType == SRGMediaPlayerStreamTypeDVR) ? 1.f : 0.f;
    }
    
    self.playbackButton.alpha = self.controller.loading ? 0.f : 1.f;
    
    SRGLetterboxView *parentLetterboxView = self.parentLetterboxView;
    self.fullScreenButton.alpha = (parentLetterboxView.minimal || ! userInterfaceHidden) ? 1.f : 0.f;
    self.fullScreenButton.selected = parentLetterboxView.fullScreen;
}

- (void)immediatelyUpdateLayoutForUserInterfaceHidden:(BOOL)userInterfaceHidden
{
    [super immediatelyUpdateLayoutForUserInterfaceHidden:userInterfaceHidden];
    
    SRGBlockingReason blockingReason = [self.controller.media blockingReasonAtDate:NSDate.date];
    self.alpha = (! userInterfaceHidden && blockingReason != SRGBlockingReasonStartDate && blockingReason != SRGBlockingReasonEndDate) ? 1.f : 0.f;
    
    // General playback controls
    SRGMediaPlayerPlaybackState playbackState = self.controller.playbackState;
    SRGMediaPlayerStreamType streamType = self.controller.mediaPlayerController.streamType;
    self.durationLabel.hidden = (playbackState == SRGMediaPlayerPlaybackStateIdle || playbackState == SRGMediaPlayerPlaybackStateEnded || playbackState == SRGMediaPlayerPlaybackStatePreparing
                                    || streamType != SRGStreamTypeOnDemand);
    self.liveLabel.hidden = (streamType != SRGStreamTypeLive || playbackState == SRGMediaPlayerPlaybackStateIdle);
    
    // The reference frame for controls is given by the available width (as occupied by the bottom stack view) as
    // well as the whole parent Letterbox height. Critical size is aligned on iPhone Plus devices in landscape. 
    SRGImageSet imageSet = (CGRectGetWidth(self.bottomStackView.frame) < 668.f || CGRectGetHeight(self.parentLetterboxView.frame) < 376.f) ? SRGImageSetNormal : SRGImageSetLarge;
    CGFloat horizontalSpacing = (imageSet == SRGImageSetNormal) ? 0.f : 20.f;
    
    self.horizontalSpacingPlaybackToBackwardConstraint.constant = horizontalSpacing;
    self.horizontalSpacingPlaybackToForwardConstraint.constant = horizontalSpacing;
    self.horizontalSpacingForwardToSkipToLiveConstraint.constant = horizontalSpacing;
    
    self.playbackButton.imageSet = imageSet;
    
    [self.backwardSeekButton setImage:[UIImage srg_letterboxSeekBackwardImageInSet:imageSet] forState:UIControlStateNormal];
    [self.forwardSeekButton setImage:[UIImage srg_letterboxSeekForwardImageInSet:imageSet] forState:UIControlStateNormal];
    [self.skipToLiveButton setImage:[UIImage srg_letterboxSkipToLiveImageInSet:imageSet] forState:UIControlStateNormal];
    
    self.viewModeButton.viewModeMonoscopicImage = [UIImage srg_letterboxImageNamed:@"view_mode_monoscopic"];
    self.viewModeButton.viewModeStereoscopicImage = [UIImage srg_letterboxImageNamed:@"view_mode_stereoscopic"];
    
    // Show or hide the phantom button in the controls stack, as the real full-screen button will follow its frame
    self.fullScreenPhantomButton.hidden = [self.delegate controlsViewShouldHideFullScreenButton:self];
    
    // Responsiveness
    self.backwardSeekButton.hidden = NO;
    self.forwardSeekButton.hidden = NO;
    self.skipToLiveButton.hidden = NO;
    self.timeSlider.hidden = NO;
    self.durationLabelWrapperView.alwaysHidden = NO;
    self.viewModeButton.alwaysHidden = NO;
    self.pictureInPictureButton.alwaysHidden = NO;
    self.liveLabelWrapperView.alwaysHidden = NO;
    self.tracksButton.alwaysHidden = NO;
    
    CGFloat height = CGRectGetHeight(self.frame);
    if (height < 167.f) {
        self.timeSlider.hidden = YES;
        self.durationLabelWrapperView.alwaysHidden = YES;
    }
    if (height < 120.f) {
        self.backwardSeekButton.hidden = YES;
        self.forwardSeekButton.hidden = YES;
        self.skipToLiveButton.hidden = YES;
        self.viewModeButton.alwaysHidden = YES;
        self.pictureInPictureButton.alwaysHidden = YES;
        self.liveLabelWrapperView.alwaysHidden = YES;
        self.tracksButton.alwaysHidden = YES;
    }
    
    CGFloat width = CGRectGetWidth(self.frame);
    if (width < 296.f) {
        self.skipToLiveButton.hidden = YES;
        self.timeSlider.hidden = YES;
        self.durationLabelWrapperView.alwaysHidden = YES;
    }
    if (width < 214.f) {
        self.backwardSeekButton.hidden = YES;
        self.forwardSeekButton.hidden = YES;
        self.viewModeButton.alwaysHidden = YES;
        self.pictureInPictureButton.alwaysHidden = YES;
        self.liveLabelWrapperView.alwaysHidden = YES;
        self.tracksButton.alwaysHidden = YES;
    }
    
    // Fix incorrect empty space after hiding the full screen button on iOS 9.
    NSOperatingSystemVersion operatingSystemVersion = NSProcessInfo.processInfo.operatingSystemVersion;
    if (operatingSystemVersion.majorVersion == 9) {
        [self.bottomStackView setNeedsLayout];
        [self.bottomStackView layoutIfNeeded];
    }
}

#pragma mark UI

- (void)refresh
{
    CMTimeRange timeRange = self.controller.timeRange;
    if (SRG_CMTIMERANGE_IS_NOT_EMPTY(timeRange)) {
        NSTimeInterval durationInSeconds = CMTimeGetSeconds(timeRange.duration);
        if (durationInSeconds < 60. * 60.) {
            self.durationLabel.text = [NSDateComponentsFormatter.srg_shortDateComponentsFormatter stringFromTimeInterval:durationInSeconds];
        }
        else {
            self.durationLabel.text = [NSDateComponentsFormatter.srg_mediumDateComponentsFormatter stringFromTimeInterval:durationInSeconds];
        }
        
        self.durationLabel.accessibilityLabel = [NSDateComponentsFormatter.srg_accessibilityDateComponentsFormatter stringFromTimeInterval:durationInSeconds];
    }
    else {
        self.durationLabel.text = nil;
        self.durationLabel.accessibilityLabel = nil;
    }
}

#pragma mark SRGTimeSliderDelegate protocol

- (void)timeSlider:(SRGTimeSlider *)slider isMovingToPlaybackTime:(CMTime)time withValue:(float)value interactive:(BOOL)interactive
{
    [self.delegate controlsView:self isMovingSliderToPlaybackTime:time withValue:value interactive:interactive];
}

- (NSAttributedString *)timeSlider:(SRGTimeSlider *)slider labelForValue:(float)value time:(CMTime)time
{
    SRGMediaPlayerStreamType streamType = slider.mediaPlayerController.streamType;
    if (slider.live) {
        return [[NSAttributedString alloc] initWithString:SRGLetterboxLocalizedString(@"Live", @"Very short text in the slider bubble, or in the bottom right corner of the Letterbox view when playing a live only stream or a DVR stream in live").uppercaseString attributes:@{ NSFontAttributeName : [UIFont srg_boldFontWithSize:14.f] }];
    }
    else if (streamType == SRGMediaPlayerStreamTypeDVR) {
        NSDate *date = slider.date;
        if (date) {
            static dispatch_once_t s_onceToken;
            static NSDateFormatter *s_dateFormatter;
            dispatch_once(&s_onceToken, ^{
                s_dateFormatter = [[NSDateFormatter alloc] init];
                s_dateFormatter.dateStyle = NSDateFormatterNoStyle;
                s_dateFormatter.timeStyle = NSDateFormatterShortStyle;
            });
            
            NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:SRGLetterboxNonLocalizedString(@" ") attributes:@{ NSFontAttributeName : [UIFont srg_awesomeFontWithSize:14.f] }];
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:[s_dateFormatter stringFromDate:date] attributes:@{ NSFontAttributeName : [UIFont srg_mediumFontWithSize:14.f] }]];
            return attributedString.copy;
        }
        else {
            return [[NSAttributedString alloc] initWithString:@"--:--" attributes:@{ NSFontAttributeName : [UIFont srg_mediumFontWithSize:14.f] }];
        }
    }
    else if (streamType == SRGMediaPlayerStreamTypeLive) {
        return nil;
    }
    else {
        NSDateComponentsFormatter *dateComponentsFormatter = (fabsf(value) < 60.f * 60.f) ? NSDateComponentsFormatter.srg_shortDateComponentsFormatter : NSDateComponentsFormatter.srg_mediumDateComponentsFormatter;
        NSString *string = [dateComponentsFormatter stringFromTimeInterval:value];
        return [[NSAttributedString alloc] initWithString:string attributes:@{ NSFontAttributeName : [UIFont srg_mediumFontWithSize:14.f] }];
    }
}

#pragma mark SRGTracksButtonDelegate protocol

- (void)tracksButtonWillShowTrackSelection:(SRGTracksButton *)tracksButton
{
    [self.delegate controlsViewWillShowTrackSelectionPopover:self];
}

- (void)tracksButtonDidHideTrackSelection:(SRGTracksButton *)tracksButton
{
    [self.delegate controlsViewDidHideTrackSelectionPopover:self];
}

#pragma mark Actions

- (IBAction)skipBackward:(id)sender
{
    [self.controller skipBackwardWithCompletionHandler:^(BOOL finished) {
        [self timeSlider:self.timeSlider isMovingToPlaybackTime:self.timeSlider.time withValue:self.timeSlider.value interactive:YES];
    }];
}

- (IBAction)skipForward:(id)sender
{
    [self.controller skipForwardWithCompletionHandler:^(BOOL finished) {
        [self timeSlider:self.timeSlider isMovingToPlaybackTime:self.timeSlider.time withValue:self.timeSlider.value interactive:YES];
    }];
}

- (IBAction)skipToLive:(id)sender
{
    [self.controller skipToLiveWithCompletionHandler:nil];
}

- (IBAction)hideUserInterface:(id)sender
{
    [self.delegate controlsViewDidTap:self];
}

- (IBAction)toggleFullScreen:(id)sender
{
    [self.delegate controlsViewDidToggleFullScreen:self];
}

#pragma mark Notifications

- (void)playbackStateDidChange:(NSNotification *)notification
{
    [self refresh];
}

@end
