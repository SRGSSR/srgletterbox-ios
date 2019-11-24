//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxViewController.h"

#import "NSBundle+SRGLetterbox.h"
#import "SRGAvailabilityView.h"
#import "SRGContinuousPlaybackViewController.h"
#import "SRGErrorView.h"
#import "SRGLetterboxController+Private.h"
#import "SRGLiveLabel.h"
#import "SRGNotificationView.h"
#import "UIImage+SRGLetterbox.h"
#import "UIImageView+SRGLetterbox.h"

#import <libextobjc/libextobjc.h>
#import <MAKVONotificationCenter/MAKVONotificationCenter.h>
#import <SRGAppearance/SRGAppearance.h>
#import <SRGLetterbox/SRGLetterbox.h>
#import <SRGMediaPlayer/SRGMediaPlayer.h>
#import <YYWebImage/YYWebImage.h>

static UIView *SRGLetterboxViewControllerLoadingIndicatorSubview(UIView *view)
{
    if ([NSStringFromClass(view.class) containsString:@"LoadingIndicator"]) {
        return view;
    }
    
    for (UIView *subview in view.subviews) {
        UIView *loadingView = SRGLetterboxViewControllerLoadingIndicatorSubview(subview);
        if (loadingView) {
            return loadingView;
        }
    }
    
    return nil;
}

@interface SRGLetterboxViewController () <SRGContinuousPlaybackViewControllerDelegate, SRGMediaPlayerViewControllerDelegate>

@property (nonatomic) SRGLetterboxController *controller;
@property (nonatomic) SRGMediaPlayerViewController *playerViewController;

@property (nonatomic) NSMutableDictionary<NSURL *, YYWebImageOperation *> *imageOperations;

@property (nonatomic, weak) UIImageView *imageView;
@property (nonatomic, weak) SRGAvailabilityView *availabilityView;
@property (nonatomic, weak) SRGErrorView *errorView;
@property (nonatomic, weak) UIImageView *loadingImageView;
@property (nonatomic, weak) SRGNotificationView *notificationView;

@property (nonatomic, weak) SRGLiveLabel *liveLabel;

@property (nonatomic, weak) id periodicTimeObserver;

@property (nonatomic, getter=isUserInterfaceHidden) BOOL userInterfaceHidden;

@end

@implementation SRGLetterboxViewController

#pragma mark Object lifecycle

- (instancetype)initWithController:(SRGLetterboxController *)controller
{
    if (self = [super init]) {
        if (! controller) {
            controller = [[SRGLetterboxController alloc] init];
        }
        
        self.controller = controller;
        self.playerViewController = [[SRGMediaPlayerViewController alloc] initWithController:controller.mediaPlayerController];
        self.playerViewController.delegate = self;
        self.userInterfaceHidden = YES;
        
        self.imageOperations = [NSMutableDictionary dictionary];
        
        @weakify(self) @weakify(controller)
        [controller addObserver:self keyPath:@keypath(controller.program) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            [self reloadImage];
        }];
        [controller addObserver:self keyPath:@keypath(controller.continuousPlaybackUpcomingMedia) options:0 block:^(MAKVONotification *notification) {
            @strongify(self) @strongify(controller)
            
            SRGMedia *upcomingMedia = controller.continuousPlaybackUpcomingMedia;
            if (upcomingMedia) {
                SRGContinuousPlaybackViewController *continuousPlaybackViewController = [[SRGContinuousPlaybackViewController alloc] initWithMedia:controller.media
                                                                                                                                     upcomingMedia:upcomingMedia
                                                                                                                                           endDate:controller.continuousPlaybackTransitionEndDate];
                continuousPlaybackViewController.delegate = self;
                [self presentViewController:continuousPlaybackViewController animated:YES completion:nil];
            }
        }];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(metadataDidChange:)
                                                   name:SRGLetterboxMetadataDidChangeNotification
                                                 object:controller];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackStateDidChange:)
                                                   name:SRGLetterboxPlaybackStateDidChangeNotification
                                                 object:controller];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackDidFail:)
                                                   name:SRGLetterboxPlaybackDidFailNotification
                                                 object:controller];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(livestreamDidFinish:)
                                                   name:SRGLetterboxLivestreamDidFinishNotification
                                                 object:controller];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackDidContinueAutomatically:)
                                                   name:SRGLetterboxPlaybackDidContinueAutomaticallyNotification
                                                 object:controller];
        
        SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
        [mediaPlayerController addObserver:self keyPath:@keypath(mediaPlayerController.mediaType) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            [self updateMainLayout];
        }];
        [mediaPlayerController addObserver:self keyPath:@keypath(mediaPlayerController.live) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            [self updateMainLayout];
        }];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(willSkipBlockedSegment:)
                                                   name:SRGMediaPlayerWillSkipBlockedSegmentNotification
                                                 object:mediaPlayerController];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithController:nil];
}

- (void)dealloc
{
    [self.imageOperations enumerateKeysAndObjectsUsingBlock:^(NSURL * _Nonnull URL, YYWebImageOperation * _Nonnull operation, BOOL * _Nonnull stop) {
        [operation cancel];
    }];
    [self.controller removePeriodicTimeObserver:self.periodicTimeObserver];
    [self.playerViewController removeFromParentViewController];
}

#pragma mark View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    UIView *playerView = self.playerViewController.view;
    playerView.frame = self.view.bounds;
    playerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:playerView];
    [self addChildViewController:self.playerViewController];
    
    SRGErrorView *errorView = [[SRGErrorView alloc] initWithFrame:playerView.bounds];
    errorView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    errorView.controller = self.controller;
    [playerView insertSubview:errorView atIndex:0];
    self.errorView = errorView;
    
    SRGAvailabilityView *availabilityView = [[SRGAvailabilityView alloc] initWithFrame:playerView.bounds];
    availabilityView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    availabilityView.controller = self.controller;
    [playerView insertSubview:availabilityView atIndex:0];
    self.availabilityView = availabilityView;
    
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:playerView.bounds];
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    [playerView insertSubview:imageView atIndex:0];
    self.imageView = imageView;
    
    UIView *loadingIndicatorView = SRGLetterboxViewControllerLoadingIndicatorSubview(playerView);
    loadingIndicatorView.alpha = 0.f;
    
    UIImageView *loadingImageView = [UIImageView srg_loadingImageViewWithTintColor:UIColor.whiteColor];
    loadingImageView.alpha = 0.f;
    [playerView addSubview:loadingImageView];
    self.loadingImageView = loadingImageView;
    
    loadingImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[ [loadingImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
                                               [loadingImageView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor] ]];
    
    SRGNotificationView *notificationView = [[SRGNotificationView alloc] init];
    notificationView.alpha = 0.f;
    notificationView.layer.cornerRadius = 3.f;
    notificationView.layer.shadowOpacity = 0.5f;
    notificationView.layer.shadowOffset = CGSizeMake(0.f, 2.f);
    [playerView addSubview:notificationView];
    self.notificationView = notificationView;
    
    notificationView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[ [notificationView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
                                               [notificationView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:20.f],
                                               [notificationView.widthAnchor constraintLessThanOrEqualToConstant:1820.f],
                                               [notificationView.heightAnchor constraintLessThanOrEqualToConstant:980.f] ]];
    
    // Content overlay animations (to show or hide UI elements alongside player controls) are only available since tvOS 11.
    // On tvOS 10 and below, do not display any live label.
    if (@available(tvOS 11, *)) {
        UIView *contentOverlayView = self.playerViewController.contentOverlayView;
        SRGLiveLabel *liveLabel = [[SRGLiveLabel alloc] init];
        
        liveLabel.layer.shadowRadius = 5.f;
        liveLabel.layer.shadowOpacity = 0.5f;
        liveLabel.layer.shadowOffset = CGSizeMake(0.f, 2.f);
        [contentOverlayView addSubview:liveLabel];
        self.liveLabel = liveLabel;
        
        liveLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[ [liveLabel.trailingAnchor constraintEqualToAnchor:contentOverlayView.trailingAnchor constant:-100.f],
                                                   [liveLabel.topAnchor constraintEqualToAnchor:contentOverlayView.topAnchor constant:50.f],
                                                   [liveLabel.widthAnchor constraintEqualToConstant:75.f],
                                                   [liveLabel.heightAnchor constraintEqualToConstant:45.f] ]];
    }
    
    [self updateMainLayout];
    [self reloadData];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    if (self.movingFromParentViewController || self.beingDismissed) {
        [self dismissNotificationViewAnimated:NO];
    }
}

#pragma mark Image retrieval

- (UIImage *)imageForMetadata:(id<SRGImageMetadata>)metadata withCompletion:(void (^)(void))completion
{
    NSParameterAssert(completion);
    
    YYWebImageManager *webImageManager = [YYWebImageManager sharedManager];
    
    CGSize size = SRGSizeForImageScale(SRGImageScaleMedium);
    NSURL *imageURL = [metadata imageURLForDimension:SRGImageDimensionWidth withValue:size.width type:SRGImageTypeDefault];
    NSString *key = [webImageManager cacheKeyForURL:imageURL];
    UIImage *image = [webImageManager.cache getImageForKey:key];
    if (image) {
        return image;
    }
    
    if (! self.imageOperations[imageURL]) {
        @weakify(self)
        YYWebImageOperation *imageOperation = [webImageManager requestImageWithURL:imageURL options:0 progress:nil transform:nil completion:^(UIImage * _Nullable image, NSURL * _Nonnull url, YYWebImageFromType from, YYWebImageStage stage, NSError * _Nullable error) {
            @strongify(self)
            dispatch_async(dispatch_get_main_queue(), ^{
                self.imageOperations[imageURL] = nil;
                completion();
            });
        }];
        self.imageOperations[imageURL] = imageOperation;
    }
    
    return [UIImage srg_vectorImageAtPath:SRGLetterboxFilePathForImagePlaceholder(SRGLetterboxImagePlaceholderMedia) withSize:size];
}

#pragma mark Data

- (void)reloadData
{
    [self.playerViewController reloadData];
    [self updateMainLayout];
    [self reloadImage];
}

- (NSString *)fullSummaryForMedia:(SRGMedia *)media
{
    NSParameterAssert(media);
    
    if (media.summary && media.imageCopyright) {
        NSString *imageCopyright = [NSString stringWithFormat:SRGLetterboxLocalizedString(@"Image credit: %@", @"Image copyright introductory label"), media.imageCopyright];
        return [NSString stringWithFormat:@"%@\n\n%@", media.summary, imageCopyright];
    }
    else if (media.imageCopyright) {
        return [NSString stringWithFormat:SRGLetterboxLocalizedString(@"Image credit: %@", @"Image copyright introductory label"), media.imageCopyright];
    }
    else {
        return media.summary;
    }
}

- (void)reloadImage
{
    [self.imageView srg_requestImageForController:self.controller withScale:SRGImageScaleLarge type:SRGImageTypeDefault placeholder:SRGLetterboxImagePlaceholderBackground atDate:self.controller.date];
}

#pragma mark Layout

- (void)updateMainLayout
{
    [self updateMainLayoutWithUserInterfaceHidden:self.userInterfaceHidden];
}

- (void)updateMainLayoutWithUserInterfaceHidden:(BOOL)userInterfaceHidden
{
    SRGMediaPlayerPlaybackState playbackState = self.controller.playbackState;
    
    BOOL thumbnailHidden = (self.controller.media.mediaType == SRGMediaTypeVideo && playbackState != SRGMediaPlayerPlaybackStateIdle && playbackState != SRGMediaPlayerPlaybackStatePreparing && playbackState != SRGMediaPlayerPlaybackStateEnded);
    self.imageView.alpha = thumbnailHidden ? 0.f : 1.f;
    
    NSError *error = self.controller.error;
    if ([error.domain isEqualToString:SRGLetterboxErrorDomain] && error.code == SRGLetterboxErrorCodeNotAvailable) {
        self.errorView.alpha = 0.f;
        self.availabilityView.alpha = 1.f;
        self.view.userInteractionEnabled = NO;
    }
    else if (error) {
        self.errorView.alpha = 1.f;
        self.availabilityView.alpha = 0.f;
        self.view.userInteractionEnabled = NO;
    }
    else if (self.controller.URN) {
        self.errorView.alpha = 0.f;
        self.availabilityView.alpha = 0.f;
        self.view.userInteractionEnabled = YES;
    }
    else {
        self.errorView.alpha = 1.f;
        self.availabilityView.alpha = 0.f;
        self.view.userInteractionEnabled = NO;
    }
    
    if (self.controller.loading) {
        self.loadingImageView.alpha = 1.f;
        [self.loadingImageView startAnimating];
    }
    else {
        self.loadingImageView.alpha = 0.f;
        [self.loadingImageView stopAnimating];
    }
    
    self.liveLabel.alpha = (! userInterfaceHidden && self.controller.live) ? 1.f : 0.f;
}

#pragma mark Notification banners

- (void)showNotificationMessage:(NSString *)notificationMessage animated:(BOOL)animated
{
    if (notificationMessage.length == 0) {
        return;
    }
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissNotificationViewAutomatically) object:nil];
    
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, notificationMessage);
    [self.notificationView updateLayoutWithMessage:notificationMessage];
    
    [UIView animateWithDuration:0.2 animations:^{
        self.notificationView.alpha = 1.f;
    }];
    
    [self performSelector:@selector(dismissNotificationViewAutomatically) withObject:nil afterDelay:5.];
}

- (void)dismissNotificationViewAutomatically
{
    [self dismissNotificationViewAnimated:YES];
}

- (void)dismissNotificationViewAnimated:(BOOL)animated
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismissNotificationViewAutomatically) object:nil];
    
    [UIView animateWithDuration:0.2 animations:^{
        self.notificationView.alpha = 0.f;
    } completion:^(BOOL finished) {
        [self.notificationView updateLayoutWithMessage:nil];
    }];
}

#pragma mark AVPlayerViewControllerDelegate protocol

- (void)playerViewController:(AVPlayerViewController *)playerViewController willTransitionToVisibilityOfTransportBar:(BOOL)visible withAnimationCoordinator:(id<AVPlayerViewControllerAnimationCoordinator>)coordinator API_AVAILABLE(tvos(11.0))
{
    self.userInterfaceHidden = ! visible;
    
    [coordinator addCoordinatedAnimations:^{
        [self updateMainLayoutWithUserInterfaceHidden:! visible];
    } completion:nil];
}

#pragma mark SRGContinuousPlaybackViewControllerDelegate protocol

- (void)continuousPlaybackViewController:(SRGContinuousPlaybackViewController *)continuousPlaybackViewController didEngageInContinuousPlaybackWithUpcomingMedia:(SRGMedia *)upcomingMedia
{
    [self.controller playUpcomingMedia];
    
    if ([self.delegate respondsToSelector:@selector(letterboxViewController:didEngageInContinuousPlaybackWithUpcomingMedia:)]) {
        [self.delegate letterboxViewController:self didEngageInContinuousPlaybackWithUpcomingMedia:upcomingMedia];
    }
    
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)continuousPlaybackViewController:(SRGContinuousPlaybackViewController *)continuousPlaybackViewController didCancelContinuousPlaybackWithUpcomingMedia:(SRGMedia *)upcomingMedia
{
    [self.controller cancelContinuousPlayback];
    
    if ([self.delegate respondsToSelector:@selector(letterboxViewController:didCancelContinuousPlaybackWithUpcomingMedia:)]) {
        [self.delegate letterboxViewController:self didCancelContinuousPlaybackWithUpcomingMedia:upcomingMedia];
    }
    
    [self dismissViewControllerAnimated:NO completion:^{
        [self dismissViewControllerAnimated:YES completion:nil];
    }];
}

- (void)continuousPlaybackViewController:(SRGContinuousPlaybackViewController *)continuousPlaybackViewController didRestartPlaybackWithMedia:(SRGMedia *)media
{
    [self.controller restart];
    
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark SRGMediaPlayerViewControllerDelegate protocol

- (NSArray<AVMetadataItem *> *)playerViewControllerExternalMetadata:(SRGMediaPlayerViewController *)playerViewController
{
    SRGMedia *media = self.controller.fullLengthMedia;
    if (media) {
        AVMutableMetadataItem *titleItem = [[AVMutableMetadataItem alloc] init];
        titleItem.identifier = AVMetadataCommonIdentifierTitle;
        titleItem.value = media.title;
        titleItem.extendedLanguageTag = @"und";
        
        AVMutableMetadataItem *descriptionItem = [[AVMutableMetadataItem alloc] init];
        descriptionItem.identifier = AVMetadataCommonIdentifierDescription;
        descriptionItem.value = [self fullSummaryForMedia:media];
        descriptionItem.extendedLanguageTag = @"und";
        
        @weakify(self)
        UIImage *image = [self imageForMetadata:media withCompletion:^{
            @strongify(self)
            [self reloadData];
        }];
        
        AVMutableMetadataItem *artworkItem = [[AVMutableMetadataItem alloc] init];
        artworkItem.identifier = AVMetadataCommonIdentifierArtwork;
        artworkItem.value = UIImagePNGRepresentation(image);
        artworkItem.extendedLanguageTag = @"und";       // Also required for images in external metadata
        
        return @[ titleItem.copy, descriptionItem.copy, artworkItem.copy ];
    }
    else {
        return nil;
    }
}

- (NSArray<AVTimedMetadataGroup *> *)playerViewController:(SRGMediaPlayerViewController *)playerViewController navigationMarkersForSegments:(NSArray<id<SRGSegment>> *)segments
{
    NSMutableArray<AVTimedMetadataGroup *> *navigationMarkers = [NSMutableArray array];
    
    for (SRGSegment *segment in segments) {
        AVMutableMetadataItem *titleItem = [[AVMutableMetadataItem alloc] init];
        titleItem.identifier = AVMetadataCommonIdentifierTitle;
        titleItem.value = segment.title;
        titleItem.extendedLanguageTag = @"und";
        
        @weakify(self)
        UIImage *image = [self imageForMetadata:segment withCompletion:^{
            @strongify(self)
            [self reloadData];
        }];
        
        AVMutableMetadataItem *artworkItem = [[AVMutableMetadataItem alloc] init];
        artworkItem.identifier = AVMetadataCommonIdentifierArtwork;
        artworkItem.value = UIImagePNGRepresentation(image);
        artworkItem.extendedLanguageTag = @"und";       // Apparently not required, but added for safety / consistency
        
        AVTimedMetadataGroup *navigationMarker = [[AVTimedMetadataGroup alloc] initWithItems:@[ titleItem.copy, artworkItem.copy ] timeRange:segment.srg_timeRange];
        [navigationMarkers addObject:navigationMarker];
    }
    
    return navigationMarkers.copy;
}

#pragma mark Notifications

- (void)metadataDidChange:(NSNotification *)notification
{
    [self reloadData];
}

- (void)playbackStateDidChange:(NSNotification *)notification
{   
    [self updateMainLayout];
}

- (void)playbackDidFail:(NSNotification *)notification
{
    [self updateMainLayout];
}

- (void)livestreamDidFinish:(NSNotification *)notification
{
    [self showNotificationMessage:SRGLetterboxLocalizedString(@"Live broadcast ended", @"Notification message displayed when a live broadcast has finished.") animated:YES];
}

- (void)playbackDidContinueAutomatically:(NSNotification *)notification
{
    // Only dismiss continuous playback overlay when presented (i.e. when the transition duration is not 0)
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)willSkipBlockedSegment:(NSNotification *)notification
{
    SRGSubdivision *subdivision = notification.userInfo[SRGMediaPlayerSegmentKey];
    NSString *notificationMessage = SRGMessageForSkippedSegmentWithBlockingReason([subdivision blockingReasonAtDate:NSDate.date]);
    [self showNotificationMessage:notificationMessage animated:YES];
}

@end
