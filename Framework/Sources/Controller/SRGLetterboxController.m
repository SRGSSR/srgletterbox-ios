//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxController.h"

#import "NSBundle+SRGLetterbox.h"
#import "NSTimer+SRGLetterbox.h"
#import "SRGLetterbox.h"
#import "SRGLetterboxService+Private.h"
#import "SRGLetterboxError.h"
#import "SRGLetterboxLogger.h"
#import "SRGMediaComposition+SRGLetterbox.h"
#import "SRGProgram+SRGLetterbox.h"
#import "UIDevice+SRGLetterbox.h"

#import <FXReachability/FXReachability.h>
#import <libextobjc/libextobjc.h>
#import <MAKVONotificationCenter/MAKVONotificationCenter.h>
#import <SRGAnalytics_DataProvider/SRGAnalytics_DataProvider.h>
#import <SRGAnalytics_MediaPlayer/SRGAnalytics_MediaPlayer.h>
#import <SRGContentProtection/SRGContentProtection.h>
#import <SRGDiagnostics/SRGDiagnostics.h>
#import <SRGMediaPlayer/SRGMediaPlayer.h>
#import <SRGNetwork/SRGNetwork.h>

static BOOL s_prefersDRM = NO;

NSString * const SRGLetterboxPlaybackStateDidChangeNotification = @"SRGLetterboxPlaybackStateDidChangeNotification";
NSString * const SRGLetterboxSegmentDidStartNotification = @"SRGLetterboxSegmentDidStartNotification";
NSString * const SRGLetterboxSegmentDidEndNotification = @"SRGLetterboxSegmentDidEndNotification";
NSString * const SRGLetterboxMetadataDidChangeNotification = @"SRGLetterboxMetadataDidChangeNotification";

NSString * const SRGLetterboxURNKey = @"SRGLetterboxURN";
NSString * const SRGLetterboxMediaKey = @"SRGLetterboxMedia";
NSString * const SRGLetterboxMediaCompositionKey = @"SRGLetterboxMediaComposition";
NSString * const SRGLetterboxSubdivisionKey = @"SRGLetterboxSubdivision";
NSString * const SRGLetterboxChannelKey = @"SRGLetterboxChannel";
NSString * const SRGLetterboxProgramKey = @"SRGLetterboxProgram";

NSString * const SRGLetterboxPreviousURNKey = @"SRGLetterboxPreviousURN";
NSString * const SRGLetterboxPreviousMediaKey = @"SRGLetterboxPreviousMedia";
NSString * const SRGLetterboxPreviousMediaCompositionKey = @"SRGLetterboxPreviousMediaComposition";
NSString * const SRGLetterboxPreviousSubdivisionKey = @"SRGLetterboxPreviousSubdivision";
NSString * const SRGLetterboxPreviousChannelKey = @"SRGLetterboxPreviousChannel";
NSString * const SRGLetterboxPreviousProgramKey = @"SRGLetterboxPreviousProgram";

NSString * const SRGLetterboxPlaybackDidFailNotification = @"SRGLetterboxPlaybackDidFailNotification";

NSString * const SRGLetterboxPlaybackDidRetryNotification = @"SRGLetterboxPlaybackDidRetryNotification";

NSString * const SRGLetterboxPlaybackDidContinueAutomaticallyNotification = @"SRGLetterboxPlaybackDidContinueAutomaticallyNotification";

NSString * const SRGLetterboxLivestreamDidFinishNotification = @"SRGLetterboxLivestreamDidFinishNotification";

NSString * const SRGLetterboxSocialCountViewWillIncreaseNotification = @"SRGLetterboxSocialCountViewWillIncreaseNotification";

NSString * const SRGLetterboxErrorKey = @"SRGLetterboxError";

static NSString * const SRGLetterboxDiagnosticServiceName = @"SRGPlaybackMetrics";

static NSError *SRGBlockingReasonErrorForMedia(SRGMedia *media, NSDate *date)
{
    SRGBlockingReason blockingReason = [media blockingReasonAtDate:date];
    if (blockingReason == SRGBlockingReasonStartDate || blockingReason == SRGBlockingReasonEndDate) {
        return [NSError errorWithDomain:SRGLetterboxErrorDomain
                                   code:SRGLetterboxErrorCodeNotAvailable
                               userInfo:@{ NSLocalizedDescriptionKey : SRGMessageForBlockedMediaWithBlockingReason(blockingReason),
                                           SRGLetterboxBlockingReasonKey : @(blockingReason),
                                           SRGLetterboxTimeAvailabilityKey : @([media timeAvailabilityAtDate:date]) }];
    }
    else if (blockingReason != SRGBlockingReasonNone) {
        return [NSError errorWithDomain:SRGLetterboxErrorDomain
                                   code:SRGLetterboxErrorCodeBlocked
                               userInfo:@{ NSLocalizedDescriptionKey : SRGMessageForBlockedMediaWithBlockingReason(blockingReason),
                                           SRGLetterboxBlockingReasonKey : @(blockingReason) }];
    }
    else {
        return nil;
    }
}

static BOOL SRGLetterboxControllerIsLoading(SRGLetterboxDataAvailability dataAvailability, SRGMediaPlayerPlaybackState playbackState)
{
    BOOL isPlayerLoading = playbackState == SRGMediaPlayerPlaybackStatePreparing
        || playbackState == SRGMediaPlayerPlaybackStateSeeking
        || playbackState == SRGMediaPlayerPlaybackStateStalled;
    return isPlayerLoading || dataAvailability == SRGLetterboxDataAvailabilityLoading;
}

static NSString *SRGDeviceInformation(void)
{
    return [NSString stringWithFormat:@"%@ (%@)", UIDevice.currentDevice.hardware, UIDevice.currentDevice.systemVersion];
}

static NSString *SRGLetterboxNetworkType(void)
{
    static dispatch_once_t s_onceToken;
    static NSDictionary<NSNumber *, NSString *> *s_types;
    dispatch_once(&s_onceToken, ^{
        s_types = @{ @(FXReachabilityStatusReachableViaWiFi) : @"wifi",
                     @(FXReachabilityStatusReachableViaWWAN) : @"cellular" };
    });
    return s_types[@([FXReachability sharedInstance].status)];
}

static NSString *SRGLetterboxCodeForBlockingReason(SRGBlockingReason blockingReason)
{
    static dispatch_once_t s_onceToken;
    static NSDictionary<NSNumber *, NSString *> *s_codes;
    dispatch_once(&s_onceToken, ^{
        s_codes = @{ @(SRGBlockingReasonGeoblocking) : @"GEOBLOCK",
                     @(SRGBlockingReasonLegal) : @"LEGAL",
                     @(SRGBlockingReasonCommercial) : @"COMMERCIAL",
                     @(SRGBlockingReasonAgeRating18) : @"AGERATING18",
                     @(SRGBlockingReasonAgeRating12) : @"AGERATING12",
                     @(SRGBlockingReasonStartDate) : @"STARTDATE",
                     @(SRGBlockingReasonEndDate) : @"ENDDATE",
                     @(SRGBlockingReasonUnknown) : @"UNKNOWN" };
    });
    return s_codes[@(blockingReason)];
}

static SRGPlaybackSettings *SRGPlaybackSettingsFromLetterboxPlaybackSettings(SRGLetterboxPlaybackSettings *settings)
{
    SRGPlaybackSettings *playbackSettings = [[SRGPlaybackSettings alloc] init];
    playbackSettings.streamType = settings.streamType;
    playbackSettings.quality = settings.quality;
    // TODO: Replace s_prefersDRM at the `SRGAnalytics_DataProvider` level with YES when DRMs are the default choice
    playbackSettings.DRM = s_prefersDRM;
    playbackSettings.startBitRate = settings.startBitRate;
    playbackSettings.sourceUid = settings.sourceUid;
    return playbackSettings;
}

@interface SRGDiagnosticInformation (SRGLetterboxController)

- (void)srgletterbox_setDataInformationWithMediaCompostion:(SRGMediaComposition *)mediaComposition HTTPResponse:(NSHTTPURLResponse *)HTTPResponse error:(NSError *)error;
- (void)srgletterbox_setPlayerInformationWithContentURL:(NSURL *)contentURL error:(NSError *)error;

@end

@interface SRGLetterboxController ()

@property (nonatomic) SRGMediaPlayerController *mediaPlayerController;

@property (nonatomic) NSDictionary<NSString *, NSString *> *globalHeaders;
@property (nonatomic) NSDictionary<NSString *, NSString *> *globalParameters;

@property (nonatomic, copy) NSString *URN;
@property (nonatomic) SRGMedia *media;
@property (nonatomic) SRGMediaComposition *mediaComposition;
@property (nonatomic) SRGChannel *channel;
@property (nonatomic) SRGSubdivision *subdivision;
@property (nonatomic) SRGPosition *startPosition;
@property (nonatomic) SRGLetterboxPlaybackSettings *preferredSettings;
@property (nonatomic) NSError *error;
@property (nonatomic, getter=isStopped) BOOL stopped;

// Save the URN sent to the social count view service, to not send it twice
@property (nonatomic, copy) NSString *socialCountViewURN;

@property (nonatomic) SRGLetterboxDataAvailability dataAvailability;
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic) SRGMediaPlayerPlaybackState playbackState;

@property (nonatomic) SRGProgram *program;

@property (nonatomic) SRGDataProvider *dataProvider;
@property (nonatomic) SRGRequestQueue *requestQueue;

// Use timers (not time observers) so that updates are performed also when the controller is idle
@property (nonatomic) NSTimer *updateTimer;
@property (nonatomic) NSTimer *channelUpdateTimer;

// Timers for single metadata updates at start and end times
@property (nonatomic) NSTimer *startDateTimer;
@property (nonatomic) NSTimer *endDateTimer;
@property (nonatomic) NSTimer *livestreamEndDateTimer;
@property (nonatomic) NSTimer *socialCountViewTimer;

// Timer for continuous playback
@property (nonatomic) NSTimer *continuousPlaybackTransitionTimer;

// Time observers
@property (nonatomic) id programTimeObserver;

@property (nonatomic, copy) void (^playerConfigurationBlock)(AVPlayer *player);
@property (nonatomic, copy) SRGLetterboxURLOverridingBlock contentURLOverridingBlock;

@property (nonatomic, weak) id<SRGLetterboxControllerPlaylistDataSource> playlistDataSource;

// Remark: Not wrapped into a parent context class so that all properties are KVO-observable.
@property (nonatomic) NSDate *continuousPlaybackTransitionStartDate;
@property (nonatomic) NSDate *continuousPlaybackTransitionEndDate;
@property (nonatomic) SRGMedia *continuousPlaybackUpcomingMedia;

@property (nonatomic) NSTimeInterval updateInterval;
@property (nonatomic) NSTimeInterval channelUpdateInterval;

@property (nonatomic) NSDate *lastUpdateDate;

@property (nonatomic, getter=isTracked) BOOL tracked;

@property (nonatomic, readonly, getter=isUsingAirPlay) BOOL usingAirPlay;

@property (nonatomic) SRGDiagnosticReport *report;

@end

@implementation SRGLetterboxController

@synthesize serviceURL = _serviceURL;

#pragma mark Class methods

+ (void)setPrefersDRM:(BOOL)prefersDRM
{
    s_prefersDRM = prefersDRM;
}

+ (BOOL)prefersDRM
{
    return s_prefersDRM;
}

#pragma mark Object lifecycle

- (instancetype)init
{
    if (self = [super init]) {
        self.mediaPlayerController = [[SRGMediaPlayerController alloc] init];
        self.mediaPlayerController.analyticsPlayerName = @"SRGLetterbox";
        self.mediaPlayerController.analyticsPlayerVersion = SRGLetterboxMarketingVersion();
#if TARGET_OS_IOS
        self.mediaPlayerController.viewBackgroundBehavior = SRGMediaPlayerViewBackgroundBehaviorDetachedWhenDeviceLocked;
#endif
        
        // FIXME: See https://github.com/SRGSSR/SRGMediaPlayer-iOS/issues/50 and https://soadist.atlassian.net/browse/LSV-631
        //        for more information about this choice.
        self.mediaPlayerController.minimumDVRWindowLength = 45.;
        
        @weakify(self)
        self.mediaPlayerController.playerConfigurationBlock = ^(AVPlayer *player) {
            @strongify(self)
            
            // Do not allow AirPlay video playback by default
            player.allowsExternalPlayback = NO;
            
            // Call the configuration block afterwards (so that the above default behavior can be overridden)
            self.playerConfigurationBlock ? self.playerConfigurationBlock(player) : nil;
            player.muted = self.muted;
        };
        
        // Also register the associated periodic time observers
        self.updateInterval = SRGLetterboxDefaultUpdateInterval;
        self.channelUpdateInterval = SRGLetterboxChannelDefaultUpdateInterval;
        
        self.programTimeObserver = [self.mediaPlayerController addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1., NSEC_PER_SEC) queue:NULL usingBlock:^(CMTime time) {
            @strongify(self)
            [self updateProgram];
        }];
        
        self.playbackState = SRGMediaPlayerPlaybackStateIdle;
        
        self.resumesAfterRetry = YES;
        self.resumesAfterRouteBecomesUnavailable = NO;
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(reachabilityDidChange:)
                                                   name:FXReachabilityStatusDidChangeNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackStateDidChange:)
                                                   name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                 object:self.mediaPlayerController];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(segmentDidStart:)
                                                   name:SRGMediaPlayerSegmentDidStartNotification
                                                 object:self.mediaPlayerController];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(segmentDidEnd:)
                                                   name:SRGMediaPlayerSegmentDidEndNotification
                                                 object:self.mediaPlayerController];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackDidFail:)
                                                   name:SRGMediaPlayerPlaybackDidFailNotification
                                                 object:self.mediaPlayerController];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(routeDidChange:)
                                                   name:AVAudioSessionRouteChangeNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc
{
    // Invalidate timers
    self.updateTimer = nil;
    self.channelUpdateTimer = nil;
    self.startDateTimer = nil;
    self.endDateTimer = nil;
    self.livestreamEndDateTimer = nil;
    self.socialCountViewTimer = nil;
    self.continuousPlaybackTransitionTimer = nil;
}

#pragma mark Getters and setters

- (void)setDataAvailability:(SRGLetterboxDataAvailability)dataAvailability
{
    _dataAvailability = dataAvailability;
    
    self.loading = SRGLetterboxControllerIsLoading(dataAvailability, self.playbackState);
}

- (void)setPlaybackState:(SRGMediaPlayerPlaybackState)playbackState
{
    [self willChangeValueForKey:@keypath(self.playbackState)];
    _playbackState = playbackState;
    [self didChangeValueForKey:@keypath(self.playbackState)];
    
    self.loading = SRGLetterboxControllerIsLoading(self.dataAvailability, playbackState);
}

- (void (^)(AVPlayerItem * _Nonnull, AVAsset * _Nonnull))mediaConfigurationBlock
{
    return self.mediaPlayerController.mediaConfigurationBlock;
}

- (void)setMediaConfigurationBlock:(void (^)(AVPlayerItem * _Nonnull, AVAsset * _Nonnull))mediaConfigurationBlock
{
    self.mediaPlayerController.mediaConfigurationBlock = mediaConfigurationBlock;
}

- (BOOL)isLive
{
    return self.mediaPlayerController.live;
}

- (CMTime)currentTime
{
    return self.mediaPlayerController.currentTime;
}

- (NSDate *)date
{
    return self.mediaPlayerController.date;
}

- (CMTimeRange)timeRange
{
    return self.mediaPlayerController.timeRange;
}

- (void)setMuted:(BOOL)muted
{
    _muted = muted;
    [self.mediaPlayerController reloadPlayerConfiguration];
}

- (BOOL)isBackgroundVideoPlaybackEnabled
{
    return self.mediaPlayerController.viewBackgroundBehavior == SRGMediaPlayerViewBackgroundBehaviorDetached;
}

- (void)setBackgroundVideoPlaybackEnabled:(BOOL)backgroundVideoPlaybackEnabled
{
#if TARGET_OS_IOS
    self.mediaPlayerController.viewBackgroundBehavior = backgroundVideoPlaybackEnabled ? SRGMediaPlayerViewBackgroundBehaviorDetached : SRGMediaPlayerViewBackgroundBehaviorDetachedWhenDeviceLocked;
#else
    self.mediaPlayerController.viewBackgroundBehavior = backgroundVideoPlaybackEnabled ? SRGMediaPlayerViewBackgroundBehaviorDetached : SRGMediaPlayerViewBackgroundBehaviorAttached;
#endif
}

#if TARGET_OS_IOS

- (BOOL)areBackgroundServicesEnabled
{
    return self == SRGLetterboxService.sharedService.controller;
}

- (BOOL)isPictureInPictureEnabled
{
    return self.backgroundServicesEnabled && SRGLetterboxService.sharedService.pictureInPictureDelegate;
}

- (BOOL)isPictureInPictureActive
{
    return self.pictureInPictureEnabled && self.mediaPlayerController.pictureInPictureController.pictureInPictureActive;
}

#endif

- (void)setEndTolerance:(NSTimeInterval)endTolerance
{
    self.mediaPlayerController.endTolerance = endTolerance;
}

- (NSTimeInterval)endTolerance
{
    return self.mediaPlayerController.endTolerance;
}

- (void)setEndToleranceRatio:(float)endToleranceRatio
{
    self.mediaPlayerController.endToleranceRatio = endToleranceRatio;
}

- (float)endToleranceRatio
{
    return self.mediaPlayerController.endToleranceRatio;
}

- (void)setServiceURL:(NSURL *)serviceURL
{
    _serviceURL = serviceURL;
}

- (NSURL *)serviceURL
{
    return _serviceURL ?: SRGIntegrationLayerProductionServiceURL();
}

- (void)setTracked:(BOOL)tracked
{
    self.mediaPlayerController.tracked = tracked;
}

- (BOOL)isTracked
{
    return self.mediaPlayerController.tracked;
}

- (void)setUpdateInterval:(NSTimeInterval)updateInterval
{
    if (updateInterval < SRGLetterboxMinimumUpdateInterval) {
        updateInterval = SRGLetterboxMinimumUpdateInterval;
    }
    
    _updateInterval = updateInterval;
    
    @weakify(self)
    self.updateTimer = [NSTimer srgletterbox_timerWithTimeInterval:updateInterval repeats:YES block:^(NSTimer * _Nonnull timer) {
        @strongify(self)
        
        [self updateMetadataWithCompletionBlock:^(NSError *error, BOOL resourceChanged, NSError *previousError) {
            if (resourceChanged || error) {
                [self stop];
            }
            // Start the player if the blocking reason changed from an not available state to an available one
            else if ([previousError.domain isEqualToString:SRGLetterboxErrorDomain] && previousError.code == SRGLetterboxErrorCodeNotAvailable) {
                [self playMedia:self.media atPosition:self.startPosition withPreferredSettings:self.preferredSettings];
            }
        }];
    }];
}

- (void)setChannelUpdateInterval:(NSTimeInterval)channelUpdateInterval
{
    if (channelUpdateInterval < SRGLetterboxChannelMinimumUpdateInterval) {
        channelUpdateInterval = SRGLetterboxChannelMinimumUpdateInterval;
    }
    
    _channelUpdateInterval = channelUpdateInterval;
    
    @weakify(self)
    self.channelUpdateTimer = [NSTimer srgletterbox_timerWithTimeInterval:channelUpdateInterval repeats:YES block:^(NSTimer * _Nonnull timer) {
        @strongify(self)
        [self updateChannel];
    }];
}

- (SRGMedia *)subdivisionMedia
{
    return [self.mediaComposition mediaForSubdivision:self.subdivision];
}

- (SRGMedia *)fullLengthMedia
{
    return self.mediaComposition.fullLengthMedia;
}

- (SRGResource *)resource
{
    return self.mediaPlayerController.resource;
}

- (BOOL)isContentURLOverridden
{
    if (! self.URN) {
        return NO;
    }
    
    return self.contentURLOverridingBlock && self.contentURLOverridingBlock(self.URN);
}

- (void)setUpdateTimer:(NSTimer *)updateTimer
{
    [_updateTimer invalidate];
    _updateTimer = updateTimer;
}

- (void)setChannelUpdateTimer:(NSTimer *)channelUpdateTimer
{
    [_channelUpdateTimer invalidate];
    _channelUpdateTimer = channelUpdateTimer;
}

- (void)setStartDateTimer:(NSTimer *)startDateTimer
{
    [_startDateTimer invalidate];
    _startDateTimer = startDateTimer;
}

- (void)setEndDateTimer:(NSTimer *)endDateTimer
{
    [_endDateTimer invalidate];
    _endDateTimer = endDateTimer;
}

- (void)setLivestreamEndDateTimer:(NSTimer *)livestreamEndDateTimer
{
    [_livestreamEndDateTimer invalidate];
    _livestreamEndDateTimer = livestreamEndDateTimer;
}

- (void)setSocialCountViewTimer:(NSTimer *)socialCountViewTimer
{
    [_socialCountViewTimer invalidate];
    _socialCountViewTimer = socialCountViewTimer;
}

- (void)setContinuousPlaybackTransitionTimer:(NSTimer *)continuousPlaybackTransitionTimer
{
    [_continuousPlaybackTransitionTimer invalidate];
    _continuousPlaybackTransitionTimer = continuousPlaybackTransitionTimer;
}

- (BOOL)isUsingAirPlay
{
    return AVAudioSession.srg_isAirPlayActive && (self.media.mediaType == SRGMediaTypeAudio || self.mediaPlayerController.player.externalPlaybackActive);
}

#pragma mark Periodic time observers

- (id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime))block
{
    return [self.mediaPlayerController addPeriodicTimeObserverForInterval:interval queue:queue usingBlock:block];
}

- (void)removePeriodicTimeObserver:(id)observer
{
    [self.mediaPlayerController removePeriodicTimeObserver:observer];
}

#pragma mark Playlists

- (BOOL)canPlayPlaylistMedia:(SRGMedia *)media
{
#if TARGET_OS_IOS
    if (self.pictureInPictureActive) {
        return NO;
    }
#endif
    
    return media != nil;
}

- (BOOL)canPlayNextMedia
{
    return [self canPlayPlaylistMedia:self.nextMedia];
}

- (BOOL)canPlayPreviousMedia
{
    return [self canPlayPlaylistMedia:self.previousMedia];
}

- (BOOL)prepareToPlayPlaylistMedia:(SRGMedia *)media withCompletionHandler:(void (^)(void))completionHandler
{
    if (! [self canPlayPlaylistMedia:media]) {
        return NO;
    }
    
    SRGPosition *position = [self startPositionForMedia:media];
    SRGLetterboxPlaybackSettings *preferredSettings = [self preferredSettingsForMedia:media];
    
    [self prepareToPlayMedia:media atPosition:position withPreferredSettings:preferredSettings completionHandler:completionHandler];
    
    if ([self.playlistDataSource respondsToSelector:@selector(controller:didTransitionToMedia:automatically:)]) {
        [self.playlistDataSource controller:self didTransitionToMedia:media automatically:NO];
    }
    return YES;
}

- (BOOL)prepareToPlayNextMediaWithCompletionHandler:(void (^)(void))completionHandler
{
    return [self prepareToPlayPlaylistMedia:self.nextMedia withCompletionHandler:completionHandler];
}

- (BOOL)prepareToPlayPreviousMediaWithCompletionHandler:(void (^)(void))completionHandler
{
    return [self prepareToPlayPlaylistMedia:self.previousMedia withCompletionHandler:completionHandler];
}

- (BOOL)playNextMedia
{
    return [self prepareToPlayNextMediaWithCompletionHandler:^{
        [self play];
    }];
}

- (BOOL)playPreviousMedia
{
    return [self prepareToPlayPreviousMediaWithCompletionHandler:^{
        [self play];
    }];
}

- (BOOL)playUpcomingMedia
{
    return [self prepareToPlayPlaylistMedia:self.continuousPlaybackUpcomingMedia withCompletionHandler:^{
        [self play];
    }];
}

- (SRGMedia *)nextMedia
{
    if ([self.playlistDataSource respondsToSelector:@selector(nextMediaForController:)]) {
        return [self.playlistDataSource nextMediaForController:self];
    }
    else {
        return nil;
    }
}

- (SRGMedia *)previousMedia
{
    if ([self.playlistDataSource respondsToSelector:@selector(previousMediaForController:)]) {
        return [self.playlistDataSource previousMediaForController:self];
    }
    else {
        return nil;
    }
}

- (SRGPosition *)startPositionForMedia:(SRGMedia *)media
{
    if ([self.playlistDataSource respondsToSelector:@selector(controller:startPositionForMedia:)]) {
        return [self.playlistDataSource controller:self startPositionForMedia:media];
    }
    else {
        return nil;
    }
}

- (SRGLetterboxPlaybackSettings *)preferredSettingsForMedia:(SRGMedia *)media
{
    if ([self.playlistDataSource respondsToSelector:@selector(controller:preferredSettingsForMedia:)]) {
        return [self.playlistDataSource controller:self preferredSettingsForMedia:media];
    }
    else {
        return nil;
    }
}

- (void)cancelContinuousPlayback
{
    self.continuousPlaybackTransitionTimer = nil;
    self.continuousPlaybackTransitionStartDate = nil;
    self.continuousPlaybackTransitionEndDate = nil;
    self.continuousPlaybackUpcomingMedia = nil;
}

#pragma mark Data

// Pass in which data is available, the method will ensure that the data is consistent based on the most comprehensive
// information available (media composition first, then media, finally URN). Less comprehensive data will be ignored
- (void)updateWithURN:(NSString *)URN media:(SRGMedia *)media mediaComposition:(SRGMediaComposition *)mediaComposition subdivision:(SRGSubdivision *)subdivision channel:(SRGChannel *)channel program:(SRGProgram *)program
{
    if (mediaComposition) {
        SRGSubdivision *mainSubdivision = (subdivision && [mediaComposition mediaForSubdivision:subdivision]) ? subdivision : mediaComposition.mainChapter;
        media = [mediaComposition mediaForSubdivision:mainSubdivision];
        mediaComposition = [mediaComposition mediaCompositionForSubdivision:mainSubdivision];
    }
    
    if (media) {
        URN = media.URN;
    }
    
    // We do not check that the data actually changed. The reason is that object comparison is shallow and only checks
    // object identity (e.g. medias are compared by URN). Checking objects for equality here would not take into account
    // data changes, which might occur in rare cases. Sending a few additional notifications, even when no real change
    // occurred, is harmless, though.
    
    NSString *previousURN = self.URN;
    SRGMedia *previousMedia = self.media;
    SRGMediaComposition *previousMediaComposition = self.mediaComposition;
    SRGSubdivision *previousSubdivision = self.subdivision;
    SRGChannel *previousChannel = self.channel;
    SRGProgram *previousProgram = self.program;
    
    self.URN = URN;
    self.media = media;
    self.mediaComposition = mediaComposition;
    self.subdivision = subdivision ?: self.mediaComposition.mainChapter;
    self.channel = channel ?: media.channel;
    self.program = program;
    
    NSMutableDictionary<NSString *, id> *userInfo = [NSMutableDictionary dictionary];
    userInfo[SRGLetterboxURNKey] = URN;
    userInfo[SRGLetterboxMediaKey] = media;
    userInfo[SRGLetterboxMediaCompositionKey] = mediaComposition;
    userInfo[SRGLetterboxSubdivisionKey] = subdivision;
    userInfo[SRGLetterboxChannelKey] = channel;
    userInfo[SRGLetterboxProgramKey] = program;
    userInfo[SRGLetterboxPreviousURNKey] = previousURN;
    userInfo[SRGLetterboxPreviousMediaKey] = previousMedia;
    userInfo[SRGLetterboxPreviousMediaCompositionKey] = previousMediaComposition;
    userInfo[SRGLetterboxPreviousSubdivisionKey] = previousSubdivision;
    userInfo[SRGLetterboxPreviousChannelKey] = previousChannel;
    userInfo[SRGLetterboxPreviousProgramKey] = previousProgram;
    
    // Schedule an update when the media starts
    NSTimeInterval startTimeInterval = [media.startDate timeIntervalSinceNow];
    if (startTimeInterval > 0.) {
        @weakify(self)
        self.startDateTimer = [NSTimer srgletterbox_timerWithTimeInterval:startTimeInterval repeats:NO block:^(NSTimer * _Nonnull timer) {
            @strongify(self)
            [self updateMetadataWithCompletionBlock:^(NSError *error, BOOL resourceChanged, NSError *previousError) {
                if (error) {
                    [self stop];
                }
                else {
                    [self playMedia:self.media atPosition:self.startPosition withPreferredSettings:self.preferredSettings];
                }
            }];
        }];
    }
    else {
        self.startDateTimer = nil;
    }
    
    // Schedule an update when the media ends
    NSTimeInterval endTimeInterval = [media.endDate timeIntervalSinceNow];
    if (endTimeInterval > 0.) {
        @weakify(self)
        self.endDateTimer = [NSTimer srgletterbox_timerWithTimeInterval:endTimeInterval repeats:NO block:^(NSTimer * _Nonnull timer) {
            @strongify(self)
            
            [self updateWithError:SRGBlockingReasonErrorForMedia(self.media, NSDate.date)];
            [self notifyLivestreamEndWithMedia:self.mediaComposition.srgletterbox_liveMedia previousMedia:self.mediaComposition.srgletterbox_liveMedia];
            [self stop];
            
            [self updateMetadataWithCompletionBlock:nil];
        }];
    }
    else {
        self.endDateTimer = nil;
    }
    
    // Schedule an update when the associated livestream ends (if not the media itself)
    if (mediaComposition.srgletterbox_liveMedia && ! [mediaComposition.srgletterbox_liveMedia isEqual:media]) {
        NSTimeInterval endTimeInterval = [mediaComposition.srgletterbox_liveMedia.endDate timeIntervalSinceNow];
        if (endTimeInterval > 0.) {
            @weakify(self)
            self.livestreamEndDateTimer = [NSTimer srgletterbox_timerWithTimeInterval:endTimeInterval repeats:NO block:^(NSTimer * _Nonnull timer) {
                @strongify(self)
                
                [self notifyLivestreamEndWithMedia:self.mediaComposition.srgletterbox_liveMedia previousMedia:self.mediaComposition.srgletterbox_liveMedia];
                [self updateMetadataWithCompletionBlock:nil];
            }];
        }
        else {
            self.livestreamEndDateTimer = nil;
        }
    }
    else {
        self.livestreamEndDateTimer = nil;
    }
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxMetadataDidChangeNotification object:self userInfo:userInfo.copy];
}

- (void)notifyLivestreamEndWithMedia:(SRGMedia *)media previousMedia:(SRGMedia *)previousMedia
{
    if (! media || (previousMedia && ! [media isEqual:previousMedia])) {
        return;
    }
    
    if (previousMedia) {
        if (previousMedia.contentType != SRGContentTypeLivestream && previousMedia.contentType != SRGContentTypeScheduledLivestream) {
            return;
        }
        
        if ([previousMedia blockingReasonAtDate:self.lastUpdateDate] == SRGBlockingReasonEndDate) {
            return;
        }
        
        if ((media.contentType != SRGContentTypeLivestream && media.contentType != SRGContentTypeScheduledLivestream)
                || ((media.contentType == SRGContentTypeLivestream || media.contentType == SRGContentTypeScheduledLivestream)
                    && [media blockingReasonAtDate:NSDate.date] == SRGBlockingReasonEndDate)) {
                [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxLivestreamDidFinishNotification
                                                                  object:self
                                                                userInfo:@{ SRGLetterboxMediaKey : previousMedia }];
            }
    }
    else {
        if ((media.contentType == SRGContentTypeLivestream || media.contentType == SRGContentTypeScheduledLivestream)
                && [media blockingReasonAtDate:NSDate.date] == SRGBlockingReasonEndDate) {
            [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxLivestreamDidFinishNotification
                                                              object:self
                                                            userInfo:@{ SRGLetterboxMediaKey : media }];
        }
        
    }
}

- (void)updateMetadataWithCompletionBlock:(void (^)(NSError *error, BOOL resourceChanged, NSError *previousError))completionBlock
{
    void (^updateCompletionBlock)(SRGMedia * _Nullable, NSHTTPURLResponse * _Nullable, NSError * _Nullable, BOOL, SRGMedia * _Nullable, NSError * _Nullable) = ^(SRGMedia * _Nullable media, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error, BOOL resourceChanged, SRGMedia * _Nullable previousMedia, NSError * _Nullable previousError) {
        // Do not erase playback errors with successful metadata updates
        if (error || ! [self.error.domain isEqualToString:SRGLetterboxErrorDomain] || self.error.code != SRGLetterboxErrorCodeNotPlayable) {
            [self updateWithError:error];
        }
        
        [self notifyLivestreamEndWithMedia:media previousMedia:previousMedia];
        
        self.lastUpdateDate = NSDate.date;
        
        completionBlock ? completionBlock(error, resourceChanged, previousError) : nil;
    };
    
    if (self.contentURLOverridden) {
        SRGRequest *mediaRequest = [self.dataProvider mediaWithURN:self.URN completionBlock:^(SRGMedia * _Nullable media, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
            SRGMedia *previousMedia = self.media;
            
            if (media) {
                [self updateWithURN:nil media:media mediaComposition:nil subdivision:self.subdivision channel:self.channel program:self.program];
            }
            else {
                media = previousMedia;
            }
            
            updateCompletionBlock(media, HTTPResponse, SRGBlockingReasonErrorForMedia(media, NSDate.date), NO, previousMedia, SRGBlockingReasonErrorForMedia(previousMedia, self.lastUpdateDate));
        }];
        [self.requestQueue addRequest:mediaRequest resume:YES];
        return;
    }
    
    SRGRequest *mediaCompositionRequest = [self.dataProvider mediaCompositionForURN:self.URN standalone:self.preferredSettings.standalone withCompletionBlock:^(SRGMediaComposition * _Nullable mediaComposition, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
        SRGMediaCompositionCompletionBlock mediaCompositionCompletionBlock = ^(SRGMediaComposition * _Nullable mediaComposition, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
            SRGMediaComposition *previousMediaComposition = self.mediaComposition;
            
            SRGMedia *previousMedia = [previousMediaComposition mediaForSubdivision:previousMediaComposition.mainChapter];
            NSError *previousBlockingReasonError = SRGBlockingReasonErrorForMedia(previousMedia, self.lastUpdateDate);
            
            // Update metadata if retrieved, otherwise perform a check with the metadata we already have
            if (mediaComposition) {
                self.mediaPlayerController.mediaComposition = mediaComposition;
                [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:self.subdivision channel:self.channel program:self.program];
            }
            else {
                mediaComposition = previousMediaComposition;
            }
            
            if (mediaComposition) {
                // Check whether the media is now blocked (conditions might have changed, e.g. user location or time)
                SRGMedia *media = [mediaComposition mediaForSubdivision:mediaComposition.mainChapter];
                NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, NSDate.date);
                if (blockingReasonError) {
                    updateCompletionBlock(mediaComposition.srgletterbox_liveMedia, HTTPResponse, blockingReasonError, NO, previousMediaComposition.srgletterbox_liveMedia, previousBlockingReasonError);
                    return;
                }
                
                if (previousMediaComposition) {
                    // Update the URL if resources change (also cover DVR to live change or conversely, aka DVR "kill switch")
                    NSSet<SRGResource *> *previousResources = [NSSet setWithArray:previousMediaComposition.mainChapter.playableResources];
                    NSSet<SRGResource *> *resources = [NSSet setWithArray:mediaComposition.mainChapter.playableResources];
                    if (! [previousResources isEqualToSet:resources]) {
                        updateCompletionBlock(mediaComposition.srgletterbox_liveMedia, HTTPResponse, (self.error) ? error : nil, YES, previousMediaComposition.srgletterbox_liveMedia, previousBlockingReasonError);
                        return;
                    }
                }
            }
            
            updateCompletionBlock(mediaComposition.srgletterbox_liveMedia, HTTPResponse, self.error ? error : nil, NO, previousMediaComposition.srgletterbox_liveMedia, previousBlockingReasonError);
        };
        
        if ([error.domain isEqualToString:SRGNetworkErrorDomain] && error.code == SRGNetworkErrorHTTP && [error.userInfo[SRGNetworkHTTPStatusCodeKey] integerValue] == 404
                && self.mediaComposition && ! [self.mediaComposition.fullLengthMedia.URN isEqual:self.URN]) {
            SRGRequest *fullLengthMediaCompositionRequest = [self.dataProvider mediaCompositionForURN:self.mediaComposition.fullLengthMedia.URN
                                                                                           standalone:self.preferredSettings.standalone
                                                                                  withCompletionBlock:mediaCompositionCompletionBlock];
            [self.requestQueue addRequest:fullLengthMediaCompositionRequest resume:YES];
        }
        else {
            mediaCompositionCompletionBlock(mediaComposition, HTTPResponse, error);
        }
    }];
    [self.requestQueue addRequest:mediaCompositionRequest resume:YES];
}

- (void)updateChannel
{
    if (! self.media || self.media.contentType != SRGContentTypeLivestream || ! self.media.channel.uid) {
        return;
    }
    
    SRGChannelCompletionBlock channelCompletionBlock = ^(SRGChannel * _Nullable channel, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
        SRGProgram *program = [self programForChannel:channel];
        [self updateWithURN:self.URN media:self.media mediaComposition:self.mediaComposition subdivision:self.subdivision channel:channel program:program];
    };
    
    if (self.media.mediaType == SRGMediaTypeVideo) {
        SRGRequest *request = [self.dataProvider tvChannelForVendor:self.media.vendor withUid:self.media.channel.uid completionBlock:channelCompletionBlock];
        [self.requestQueue addRequest:request resume:YES];
    }
    else if (self.media.mediaType == SRGMediaTypeAudio) {
        if (self.media.vendor == SRGVendorSRF && ! [self.media.uid isEqualToString:self.media.channel.uid]) {
            SRGRequest *request = [self.dataProvider radioChannelForVendor:self.media.vendor withUid:self.media.channel.uid livestreamUid:self.media.uid completionBlock:channelCompletionBlock];
            [self.requestQueue addRequest:request resume:YES];
        }
        else {
            SRGRequest *request = [self.dataProvider radioChannelForVendor:self.media.vendor withUid:self.media.channel.uid livestreamUid:nil completionBlock:channelCompletionBlock];
            [self.requestQueue addRequest:request resume:YES];
        }
    }
}

- (SRGProgram *)programForChannel:(SRGChannel *)channel
{
    if (self.media.contentType != SRGContentTypeLivestream || ! channel) {
        return nil;
    }
        
    NSDate *playbackDate = self.date;
    if (playbackDate && [channel.currentProgram srgletterbox_containsDate:playbackDate]) {
        return channel.currentProgram;
    }
    else {
        return nil;
    }
}

// TODO: Once program information is returned as segments, program updates can be entirely dropped, as program changes
//       will be reported via segment transitions.
- (void)updateProgram
{
    SRGProgram *program = [self programForChannel:self.channel];
    if (program != self.program && ! [program isEqual:self.program]) {
        [self updateWithURN:self.URN media:self.media mediaComposition:self.mediaComposition subdivision:self.subdivision channel:self.channel program:program];
    }
}

- (void)updateWithError:(NSError *)error
{
    if (! error) {
        self.error = nil;
        return;
    }
    
    // Forward Letterbox friendly errors
    if ([error.domain isEqualToString:SRGLetterboxErrorDomain]) {
        self.error = error;
    }
    // Use a friendly error message for network errors (might be a connection loss, incorrect proxy settings, etc.)
    else if ([error.domain isEqualToString:(NSString *)kCFErrorDomainCFNetwork] || [error.domain isEqualToString:NSURLErrorDomain]) {
        self.error = [NSError errorWithDomain:SRGLetterboxErrorDomain
                                         code:SRGLetterboxErrorCodeNetwork
                                     userInfo:@{ NSLocalizedDescriptionKey : SRGLetterboxLocalizedString(@"A network issue has been encountered. Please check your Internet connection and network settings", @"Message displayed when a network error has been encountered"),
                                                 NSUnderlyingErrorKey : error }];
    }
    // Use a friendly error message for all other reasons
    else {
        NSInteger code = (self.dataAvailability == SRGLetterboxDataAvailabilityNone) ? SRGLetterboxErrorCodeNotFound : SRGLetterboxErrorCodeNotPlayable;
        if ([error.domain isEqualToString:SRGNetworkErrorDomain] && error.code == SRGNetworkErrorHTTP && [error.userInfo[SRGNetworkHTTPStatusCodeKey] integerValue] == 404) {
            code = SRGLetterboxErrorCodeNotFound;
        }
        self.error = [NSError errorWithDomain:SRGLetterboxErrorDomain
                                         code:code
                                     userInfo:@{ NSLocalizedDescriptionKey : SRGLetterboxLocalizedString(@"The media cannot be played", @"Message displayed when a media cannot be played for some reason (the user should not know about)"),
                                                 NSUnderlyingErrorKey : error }];
    }
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxPlaybackDidFailNotification object:self userInfo:@{ SRGLetterboxErrorKey : self.error }];
}

#pragma mark Playback

- (void)prepareToPlayURN:(NSString *)URN atPosition:(SRGPosition *)position withPreferredSettings:(SRGLetterboxPlaybackSettings *)preferredSettings completionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURN:URN media:nil atPosition:position withPreferredSettings:preferredSettings completionHandler:completionHandler];
}

- (void)prepareToPlayMedia:(SRGMedia *)media atPosition:(SRGPosition *)position withPreferredSettings:(SRGLetterboxPlaybackSettings *)preferredSettings completionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURN:nil media:media atPosition:position withPreferredSettings:preferredSettings completionHandler:completionHandler];
}

- (void)prepareToPlayURN:(NSString *)URN media:(SRGMedia *)media atPosition:(SRGPosition *)position withPreferredSettings:(SRGLetterboxPlaybackSettings *)preferredSettings completionHandler:(void (^)(void))completionHandler
{
    if (media) {
        URN = media.URN;
    }
    
    if (! URN) {
        return;
    }
    
    // If already playing the media, does nothing
    if (self.mediaPlayerController.playbackState != SRGMediaPlayerPlaybackStateIdle && [self.URN isEqual:URN]) {
        return;
    }
    
    [self resetWithURN:URN media:media];
    
    // Save the settings for restarting after connection loss
    self.startPosition = position;
    
    // Deep copy settings to avoid further changes
    preferredSettings = preferredSettings.copy;
    self.preferredSettings = preferredSettings;
    
    @weakify(self)
    self.requestQueue = [[SRGRequestQueue alloc] init];
    
    if ([self prepareToPlayOverriddenURN:URN media:media atPosition:position withPreferredSettings:preferredSettings completionHandler:completionHandler]) {
        return;
    }
    
    self.dataAvailability = SRGLetterboxDataAvailabilityLoading;
    
    NSDictionary<SRGResourceLoaderOption, id> *options = nil;
    self.report = [self startPlaybackDiagnosticReportForService:SRGLetterboxDiagnosticServiceName withName:URN options:&options];
    
    [[self.report informationForKey:@"ilResult"] startTimeMeasurementForKey:@"duration"];
    
    SRGRequest *mediaCompositionRequest = [self.dataProvider mediaCompositionForURN:self.URN standalone:preferredSettings.standalone withCompletionBlock:^(SRGMediaComposition * _Nullable mediaComposition, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
        @strongify(self)
        
        [[self.report informationForKey:@"ilResult"] stopTimeMeasurementForKey:@"duration"];
        
        if (error) {
            self.dataAvailability = SRGLetterboxDataAvailabilityNone;
            [self updateWithError:error];

            [[self.report informationForKey:@"ilResult"] srgletterbox_setDataInformationWithMediaCompostion:mediaComposition HTTPResponse:HTTPResponse error:error];
            [self.report stopTimeMeasurementForKey:@"duration"];
            [self.report finish];
            return;
        }
        
        // Update screenType value after metadata update.
        [self.report setString:self.usingAirPlay ? @"airplay" : @"local" forKey:@"screenType"];
        
        [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:mediaComposition.mainSegment channel:nil program:nil];
        [self updateChannel];
        
        SRGMedia *media = [mediaComposition mediaForSubdivision:mediaComposition.mainChapter];
        [self notifyLivestreamEndWithMedia:media previousMedia:nil];
        
        // Do not go further if the content is blocked
        NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, NSDate.date);
        if (blockingReasonError) {
            self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
            [self updateWithError:blockingReasonError];
            
            [[self.report informationForKey:@"ilResult"] srgletterbox_setDataInformationWithMediaCompostion:mediaComposition HTTPResponse:HTTPResponse error:blockingReasonError];
            [self.report stopTimeMeasurementForKey:@"duration"];
            [self.report finish];
            return;
        }
        
        void (^prepareToPlayCompletionHandler)(void) = ^{
            [[self.report informationForKey:@"playerResult"] srgletterbox_setPlayerInformationWithContentURL:self.mediaPlayerController.contentURL error:nil];
            [[self.report informationForKey:@"playerResult"] stopTimeMeasurementForKey:@"duration"];
            [self.report stopTimeMeasurementForKey:@"duration"];
            [self.report finish];
            
            completionHandler ? completionHandler() : nil;
        };
        
        NSDictionary *userInfo = @{ SRGAnalyticsDataProviderUserInfoResourceLoaderOptionsKey : options };
        if ([self.mediaPlayerController prepareToPlayMediaComposition:mediaComposition atPosition:position withPreferredSettings:SRGPlaybackSettingsFromLetterboxPlaybackSettings(preferredSettings) userInfo:userInfo completionHandler:prepareToPlayCompletionHandler]) {
            [[self.report informationForKey:@"ilResult"] srgletterbox_setDataInformationWithMediaCompostion:mediaComposition HTTPResponse:HTTPResponse error:nil];
            [[self.report informationForKey:@"playerResult"] startTimeMeasurementForKey:@"duration"];
        }
        else {
            self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
            
            NSError *error = [NSError errorWithDomain:SRGLetterboxErrorDomain
                                                 code:SRGLetterboxErrorCodeNotPlayable
                                             userInfo:@{ NSLocalizedDescriptionKey : SRGLetterboxLocalizedString(@"The media cannot be played", @"Message displayed when a media cannot be played for some reason (the user should not know about)") }];
            [self updateWithError:error];
            
            [[self.report informationForKey:@"ilResult"] srgletterbox_setDataInformationWithMediaCompostion:mediaComposition HTTPResponse:HTTPResponse error:error];
            [[self.report informationForKey:@"ilResult"] setBool:YES forKey:@"noPlayableResourceFound"];
            [self.report stopTimeMeasurementForKey:@"duration"];
            [self.report finish];
        }
    }];
    [self.requestQueue addRequest:mediaCompositionRequest resume:YES];
}

// Checks whether an override has been defined for the specified content to be played. Returns `YES` and plays it iff this is the case.
- (BOOL)prepareToPlayOverriddenURN:(NSString *)URN media:(SRGMedia *)media atPosition:(SRGPosition *)position withPreferredSettings:(SRGLetterboxPlaybackSettings *)preferredSettings completionHandler:(void (^)(void))completionHandler
{
    NSURL *contentURL = self.contentURLOverridden ? self.contentURLOverridingBlock(URN) : nil;
    if (! contentURL) {
        return NO;
    }
    
    void (^prepareToPlay)(NSURL *) = ^(NSURL *contentURL) {
        if (media.presentation == SRGPresentation360) {
            if (self.mediaPlayerController.view.viewMode == SRGMediaPlayerViewModeFlat) {
                self.mediaPlayerController.view.viewMode = SRGMediaPlayerViewModeMonoscopic;
            }
        }
        else {
            self.mediaPlayerController.view.viewMode = SRGMediaPlayerViewModeFlat;
        }
        [self.mediaPlayerController prepareToPlayURL:contentURL atPosition:position withSegments:nil userInfo:nil completionHandler:completionHandler];
    };
    
    self.dataAvailability = SRGLetterboxDataAvailabilityLoading;
    
    // Media readily available. Done
    if (media) {
        self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
        NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, NSDate.date);
        [self updateWithError:blockingReasonError];
        [self notifyLivestreamEndWithMedia:media previousMedia:nil];
        
        if (! blockingReasonError) {
            prepareToPlay(contentURL);
        }
    }
    // Retrieve the media
    else {
        SRGMediaCompletionBlock mediaCompletionBlock = ^(SRGMedia * _Nullable media, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
            if (error) {
                self.dataAvailability = SRGLetterboxDataAvailabilityNone;
                [self updateWithError:error];
                return;
            }
            
            self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
            
            [self updateWithURN:nil media:media mediaComposition:nil subdivision:nil channel:nil program:nil];
            [self notifyLivestreamEndWithMedia:media previousMedia:nil];
            
            NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, NSDate.date);
            if (blockingReasonError) {
                [self updateWithError:blockingReasonError];
            }
            else {
                prepareToPlay(contentURL);
            }
        };
        
        SRGRequest *mediaRequest = [self.dataProvider mediaWithURN:URN completionBlock:mediaCompletionBlock];
        [self.requestQueue addRequest:mediaRequest resume:YES];
    }
    
    return YES;
}

- (void)play
{
    if (self.mediaPlayerController.contentURL) {
        [self.mediaPlayerController play];
    }
    else if (self.media) {
        [self playMedia:self.media atPosition:self.startPosition withPreferredSettings:self.preferredSettings];
    }
    else if (self.URN) {
        [self playURN:self.URN atPosition:self.startPosition withPreferredSettings:self.preferredSettings];
    }
}

- (void)pause
{
    // Do not let pause live streams, stop playback
    if (self.mediaPlayerController.streamType == SRGMediaPlayerStreamTypeLive) {
        [self stop];
    }
    else {
        [self.mediaPlayerController pause];
    }
}

- (void)togglePlayPause
{
    if (self.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePlaying || self.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateSeeking) {
        [self pause];
    }
    else {
        [self play];
    }
}

- (void)stop
{
    // Reset the player, including the attached URL. We keep the Letterbox controller context so that playback can
    // be restarted.
    [self.mediaPlayerController reset];
    
    self.stopped = YES;
}

- (void)retry
{
    void (^prepareToPlayCompletionHandler)(void) = ^{
        if (self.resumesAfterRetry) {
            [self play];
        }
    };
    
    // Reuse the media if available (so that the information already available to clients is not reduced)
    if (self.media) {
        [self prepareToPlayMedia:self.media atPosition:self.startPosition withPreferredSettings:self.preferredSettings completionHandler:prepareToPlayCompletionHandler];
    }
    else if (self.URN) {
        [self prepareToPlayURN:self.URN atPosition:self.startPosition withPreferredSettings:self.preferredSettings completionHandler:prepareToPlayCompletionHandler];
    }
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxPlaybackDidRetryNotification object:self];
}

- (void)restart
{
    [self stop];
    [self retry];
}

- (void)reset
{
    [self resetWithURN:nil media:nil];
}

- (void)resetWithURN:(NSString *)URN media:(SRGMedia *)media
{
    if (URN) {
        self.dataProvider = [[SRGDataProvider alloc] initWithServiceURL:self.serviceURL];
        self.dataProvider.globalHeaders = self.globalHeaders;
        self.dataProvider.globalParameters = self.globalParameters;
    }
    else {
        self.dataProvider = nil;
    }
    
    self.error = nil;
    self.stopped = NO;
    
    self.lastUpdateDate = nil;
    self.dataAvailability = SRGLetterboxDataAvailabilityNone;
    self.program = nil;
    
    self.startPosition = nil;
    self.preferredSettings = nil;
    
    self.socialCountViewURN = nil;
    self.socialCountViewTimer = nil;
    
    self.report = nil;
    
    [self cancelContinuousPlayback];
    
    [self updateWithURN:URN media:media mediaComposition:nil subdivision:nil channel:nil program:nil];
    
    [self.mediaPlayerController reset];
    [self.requestQueue cancel];
}

- (void)seekToPosition:(SRGPosition *)position withCompletionHandler:(void (^)(BOOL))completionHandler
{
    [self.mediaPlayerController seekToPosition:position withCompletionHandler:completionHandler];
}

- (BOOL)switchToURN:(NSString *)URN withCompletionHandler:(void (^)(BOOL))completionHandler
{
    for (SRGChapter *chapter in self.mediaComposition.chapters) {
        if ([chapter.URN isEqual:URN]) {
            return [self switchToSubdivision:chapter withCompletionHandler:completionHandler];
        }
        
        for (SRGSegment *segment in chapter.segments) {
            if ([segment.URN isEqual:URN]) {
                return [self switchToSubdivision:segment withCompletionHandler:completionHandler];
            }
        }
    }
    
    SRGLetterboxLogInfo(@"controller", @"The specified URN is not related to the current context. No switch will occur.");
    return NO;
}

- (BOOL)switchToSubdivision:(SRGSubdivision *)subdivision withCompletionHandler:(void (^)(BOOL))completionHandler
{
    if (! self.mediaComposition) {
        SRGLetterboxLogInfo(@"controller", @"No context is available. No switch will occur.");
        return NO;
    }
    
    // Build the media composition for the provided subdivision. Return `NO` if the subdivision is not related to the
    // media composition.
    SRGMediaComposition *mediaComposition = [self.mediaComposition mediaCompositionForSubdivision:subdivision];
    if (! mediaComposition) {
        SRGLetterboxLogInfo(@"controller", @"The subdivision is not related to the current context. No switch will occur.");
        return NO;
    }
    
    // If playing another media or if the player is not playing, restart
    if ([subdivision isKindOfClass:SRGChapter.class]
            || self.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateIdle
            || self.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePreparing) {
        NSError *blockingReasonError = SRGBlockingReasonErrorForMedia([mediaComposition mediaForSubdivision:mediaComposition.mainChapter], NSDate.date);
        [self updateWithError:blockingReasonError];
        
        if (blockingReasonError) {
            self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
        }
        
        [self stop];
        self.socialCountViewURN = nil;
        self.socialCountViewTimer = nil;
        [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:subdivision channel:nil program:nil];
        
        NSDictionary<SRGResourceLoaderOption, id> *options = nil;
        self.report = [self startPlaybackDiagnosticReportForService:SRGLetterboxDiagnosticServiceName withName:subdivision.URN options:&options];
        
        if (! blockingReasonError) {
            [[self.report informationForKey:@"playerResult"] startTimeMeasurementForKey:@"duration"];
            NSDictionary *userInfo = @{ SRGAnalyticsDataProviderUserInfoResourceLoaderOptionsKey : options };
            [self.mediaPlayerController prepareToPlayMediaComposition:mediaComposition atPosition:nil withPreferredSettings:SRGPlaybackSettingsFromLetterboxPlaybackSettings(self.preferredSettings) userInfo:userInfo completionHandler:^{
                [[self.report informationForKey:@"playerResult"] stopTimeMeasurementForKey:@"duration"];
                [self.report stopTimeMeasurementForKey:@"duration"];
                [self.report finish];
                
                [self.mediaPlayerController play];
                completionHandler ? completionHandler(YES) : nil;
            }];
        }
        else {
            [[self.report informationForKey:@"ilResult"] srgletterbox_setDataInformationWithMediaCompostion:mediaComposition HTTPResponse:nil error:blockingReasonError];
            [self.report stopTimeMeasurementForKey:@"duration"];
            [self.report finish];
        }
    }
    // Playing another segment from the same media. Seek
    else if ([subdivision isKindOfClass:SRGSegment.class]) {
        [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:subdivision channel:nil program:nil];
        [self.mediaPlayerController seekToPosition:nil inSegment:(SRGSegment *)subdivision withCompletionHandler:^(BOOL finished) {
            [self.mediaPlayerController play];
            completionHandler ? completionHandler(finished) : nil;
        }];
    }
    else {
        return NO;
    }
    
    return YES;
}

#pragma mark Playback (convenience)

- (void)playURN:(NSString *)URN atPosition:(SRGPosition *)position withPreferredSettings:(SRGLetterboxPlaybackSettings *)preferredSettings
{
    @weakify(self)
    [self prepareToPlayURN:URN atPosition:position withPreferredSettings:preferredSettings completionHandler:^{
        @strongify(self)
        [self play];
    }];
}

- (void)playMedia:(SRGMedia *)media atPosition:(SRGPosition *)position withPreferredSettings:(SRGLetterboxPlaybackSettings *)preferredSettings
{
    @weakify(self)
    [self prepareToPlayMedia:media atPosition:position withPreferredSettings:preferredSettings completionHandler:^{
        @strongify(self)
        [self play];
    }];
}

#pragma mark Standard seeks

- (BOOL)canSkipBackward
{
    return [self canSkipBackwardFromTime:[self seekStartTime]];
}

- (BOOL)canSkipForward
{
    return [self canSkipForwardFromTime:[self seekStartTime]];
}

- (BOOL)canSkipToLive
{
    if (self.mediaPlayerController.streamType == SRGMediaPlayerStreamTypeDVR) {
        return [self canSkipForward];
    }
    
    if (self.mediaComposition.srgletterbox_liveMedia && ! [self.mediaComposition.srgletterbox_liveMedia isEqual:self.media]) {
        return [self.mediaComposition.srgletterbox_liveMedia blockingReasonAtDate:NSDate.date] != SRGBlockingReasonEndDate;
    }
    else {
        return NO;
    }
}

- (BOOL)skipBackwardWithCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    return [self skipBackwardFromTime:[self seekStartTime] withCompletionHandler:completionHandler];
}

- (BOOL)skipForwardWithCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    return [self skipForwardFromTime:[self seekStartTime] withCompletionHandler:completionHandler];
}

#pragma mark Diagnostics

- (SRGDiagnosticReport *)startPlaybackDiagnosticReportForService:(NSString *)service withName:(NSString *)name options:(NSDictionary<SRGResourceLoaderOption, id> **)pOptions
{
    static dispatch_once_t s_onceToken;
    static NSDateFormatter *s_dateFormatter;
    dispatch_once(&s_onceToken, ^{
        s_dateFormatter = [[NSDateFormatter alloc] init];
        [s_dateFormatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
        [s_dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
    });
    
    SRGDiagnosticReport *report = [[SRGDiagnosticsService serviceWithName:service] reportWithName:name];
    [report setInteger:1 forKey:@"version"];
#if TARGET_OS_TV
    [report setString:[NSString stringWithFormat:@"Letterbox/tvOS/%@", SRGLetterboxMarketingVersion()] forKey:@"player"];
#else
    [report setString:[NSString stringWithFormat:@"Letterbox/iOS/%@", SRGLetterboxMarketingVersion()] forKey:@"player"];
#endif
    [report setString:NSBundle.srg_letterbox_isProductionVersion ? @"prod" : @"preprod" forKey:@"environment"];
    [report setString:SRGDeviceInformation() forKey:@"device"];
    [report setString:NSBundle.mainBundle.bundleIdentifier forKey:@"browser"];
    [report setString:self.usingAirPlay ? @"airplay" : @"local" forKey:@"screenType"];
    [report setString:self.URN forKey:@"urn"];
    [report setString:[s_dateFormatter stringFromDate:NSDate.date] forKey:@"clientTime"];
    [report setString:SRGLetterboxNetworkType() forKey:@"networkType"];
    [report startTimeMeasurementForKey:@"duration"];
    
    if (pOptions) {
        *pOptions = @{ SRGResourceLoaderOptionDiagnosticServiceNameKey : service,
                       SRGResourceLoaderOptionDiagnosticReportNameKey : name };
    }
    
    return report;
}

#pragma mark Helpers

- (CMTime)seekStartTime
{
    return CMTIME_IS_INDEFINITE(self.mediaPlayerController.seekTargetTime) ? self.mediaPlayerController.currentTime : self.mediaPlayerController.seekTargetTime;
}

- (BOOL)canSkipBackwardFromTime:(CMTime)time
{
    if (CMTIME_IS_INDEFINITE(time)) {
        return NO;
    }
    
    SRGMediaPlayerController *mediaPlayerController = self.mediaPlayerController;
    SRGMediaPlayerPlaybackState playbackState = mediaPlayerController.playbackState;
    
    if (playbackState == SRGMediaPlayerPlaybackStateIdle || playbackState == SRGMediaPlayerPlaybackStatePreparing) {
        return NO;
    }
    
    SRGMediaPlayerStreamType streamType = mediaPlayerController.streamType;
    return (streamType == SRGMediaPlayerStreamTypeOnDemand || streamType == SRGMediaPlayerStreamTypeDVR);
}

- (BOOL)canSkipForwardFromTime:(CMTime)time
{
    if (CMTIME_IS_INDEFINITE(time)) {
        return NO;
    }
    
    SRGMediaPlayerController *mediaPlayerController = self.mediaPlayerController;
    SRGMediaPlayerPlaybackState playbackState = mediaPlayerController.playbackState;
    
    if (playbackState == SRGMediaPlayerPlaybackStateIdle || playbackState == SRGMediaPlayerPlaybackStatePreparing) {
        return NO;
    }
    
    SRGMediaPlayerStreamType streamType = mediaPlayerController.streamType;
    return (streamType == SRGMediaPlayerStreamTypeOnDemand && CMTimeGetSeconds(time) + SRGLetterboxForwardSkipInterval < CMTimeGetSeconds(mediaPlayerController.player.currentItem.duration))
        || (streamType == SRGMediaPlayerStreamTypeDVR && ! mediaPlayerController.live);
}

- (BOOL)skipBackwardFromTime:(CMTime)time withCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    if (! [self canSkipBackwardFromTime:time]) {
        return NO;
    }
    
    CMTime targetTime = CMTimeSubtract(time, CMTimeMakeWithSeconds(SRGLetterboxBackwardSkipInterval, NSEC_PER_SEC));
    [self seekToPosition:[SRGPosition positionAroundTime:targetTime] withCompletionHandler:^(BOOL finished) {
        if (finished) {
            [self.mediaPlayerController play];
        }
        completionHandler ? completionHandler(finished) : nil;
    }];
    return YES;
}

- (BOOL)skipForwardFromTime:(CMTime)time withCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    if (! [self canSkipForwardFromTime:time]) {
        return NO;
    }
    
    CMTime targetTime = CMTimeAdd(time, CMTimeMakeWithSeconds(SRGLetterboxForwardSkipInterval, NSEC_PER_SEC));
    [self seekToPosition:[SRGPosition positionAroundTime:targetTime] withCompletionHandler:^(BOOL finished) {
        if (finished) {
            [self.mediaPlayerController play];
        }
        completionHandler ? completionHandler(finished) : nil;
    }];
    return YES;
}

- (BOOL)skipToLiveWithCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    if (! [self canSkipToLive]) {
        return NO;
    }
    
    if (self.mediaPlayerController.streamType == SRGMediaPlayerStreamTypeDVR) {
        CMTime targetTime = CMTimeRangeGetEnd(self.mediaPlayerController.timeRange);
        [self seekToPosition:[SRGPosition positionAroundTime:targetTime] withCompletionHandler:^(BOOL finished) {
            if (finished) {
                [self.mediaPlayerController play];
            }
            completionHandler ? completionHandler(finished) : nil;
        }];
        return YES;
    }
    else if (self.mediaComposition.srgletterbox_liveMedia) {
        return [self switchToURN:self.mediaComposition.srgletterbox_liveMedia.URN withCompletionHandler:completionHandler];
    }
    else {
        return NO;
    }
}

#pragma mark Configuration

- (void)reloadPlayerConfiguration
{
    [self.mediaPlayerController reloadPlayerConfiguration];
}

- (void)reloadMediaConfiguration
{
    [self.mediaPlayerController reloadMediaConfiguration];
}

- (void)reloadMediaConfigurationWithBlock:(void (^)(AVPlayerItem * _Nonnull, AVAsset * _Nonnull))block
{
    [self.mediaPlayerController reloadMediaConfigurationWithBlock:block];
}

#pragma mark Notifications

- (void)reachabilityDidChange:(NSNotification *)notification
{
    if (! self.stopped && [FXReachability sharedInstance].reachable) {
        [self retry];
    }
}

- (void)playbackStateDidChange:(NSNotification *)notification
{
    SRGMediaPlayerPlaybackState playbackState = [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue];
    if (playbackState != self.playbackState) {
        self.playbackState = playbackState;
        [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxPlaybackStateDidChangeNotification
                                                          object:self
                                                        userInfo:notification.userInfo];
    }
    
    // Continuous playback only makes sense while in the ended state
    if (playbackState != SRGMediaPlayerPlaybackStateEnded) {
        [self cancelContinuousPlayback];
    }
    
#if TARGET_OS_IOS
    // Never let pause live streams, including when the state is changed from picture in picture controls. Stop playback instead
    if (self.pictureInPictureActive && self.mediaPlayerController.streamType == SRGMediaPlayerStreamTypeLive && playbackState == SRGMediaPlayerPlaybackStatePaused) {
        [self stop];
    }
#endif
    
    if (playbackState == SRGMediaPlayerPlaybackStatePreparing) {
        self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
    }
    else if (playbackState == SRGMediaPlayerPlaybackStatePlaying && self.mediaComposition && ! [self.socialCountViewURN isEqual:self.mediaComposition.mainChapter.URN] && ! self.socialCountViewTimer) {
        __block SRGSubdivision *subdivision = self.mediaComposition.mainChapter;
        
        static const NSTimeInterval kDefaultTimerInterval = 10.;
        NSTimeInterval timerInterval = kDefaultTimerInterval;
        if (subdivision.contentType != SRGContentTypeLivestream && subdivision.contentType != SRGContentTypeScheduledLivestream && subdivision.duration < kDefaultTimerInterval) {
            timerInterval = subdivision.duration * .8;
        }
        @weakify(self)
        self.socialCountViewTimer = [NSTimer srgletterbox_timerWithTimeInterval:timerInterval repeats:NO block:^(NSTimer * _Nonnull timer) {
            @strongify(self)
            
            [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxSocialCountViewWillIncreaseNotification
                                                              object:self
                                                            userInfo:@{ SRGLetterboxSubdivisionKey : subdivision }];
            
            SRGRequest *request = [self.dataProvider increaseSocialCountForType:SRGSocialCountTypeSRGView subdivision:subdivision withCompletionBlock:^(SRGSocialCountOverview * _Nullable socialCountOverview, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
                self.socialCountViewURN = socialCountOverview.URN;
                self.socialCountViewTimer = nil;
            }];
            [self.requestQueue addRequest:request resume:YES];
        }];
    }
    else if (playbackState == SRGMediaPlayerPlaybackStateIdle) {
        self.socialCountViewTimer = nil;
    }
    else if (playbackState == SRGMediaPlayerPlaybackStateEnded) {
        SRGMedia *nextMedia = self.nextMedia;
        
        NSTimeInterval continuousPlaybackTransitionDuration = SRGLetterboxContinuousPlaybackDisabled;
        if ([self.playlistDataSource respondsToSelector:@selector(continuousPlaybackTransitionDurationForController:)]) {
            continuousPlaybackTransitionDuration = [self.playlistDataSource continuousPlaybackTransitionDurationForController:self];
            if (continuousPlaybackTransitionDuration < 0.) {
                continuousPlaybackTransitionDuration = 0.;
            }
        }
        
        if (nextMedia && continuousPlaybackTransitionDuration != SRGLetterboxContinuousPlaybackDisabled
#if TARGET_OS_IOS
            && ! self.pictureInPictureActive
#endif
        ) {
            void (^notify)(void) = ^{
                if ([self.playlistDataSource respondsToSelector:@selector(controller:didTransitionToMedia:automatically:)]) {
                    [self.playlistDataSource controller:self didTransitionToMedia:nextMedia automatically:YES];
                }
                [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxPlaybackDidContinueAutomaticallyNotification
                                                                  object:self
                                                                userInfo:@{ SRGLetterboxURNKey : nextMedia.URN,
                                                                            SRGLetterboxMediaKey : nextMedia }];
            };
            
            SRGPosition *startPosition = [self startPositionForMedia:nextMedia];
            SRGLetterboxPlaybackSettings *preferredSettings = [self preferredSettingsForMedia:nextMedia];
            
            if (continuousPlaybackTransitionDuration != 0.) {
                self.continuousPlaybackTransitionStartDate = NSDate.date;
                self.continuousPlaybackTransitionEndDate = [NSDate dateWithTimeIntervalSinceNow:continuousPlaybackTransitionDuration];
                self.continuousPlaybackUpcomingMedia = nextMedia;
                
                @weakify(self)
                self.continuousPlaybackTransitionTimer = [NSTimer srgletterbox_timerWithTimeInterval:continuousPlaybackTransitionDuration repeats:NO block:^(NSTimer * _Nonnull timer) {
                    @strongify(self)
                    
                    [self playMedia:nextMedia atPosition:startPosition withPreferredSettings:preferredSettings];
                    notify();
                }];
            }
            else {
                [self playMedia:nextMedia atPosition:startPosition withPreferredSettings:preferredSettings];
                
                // Send notification on next run loop, so that other observers of the playback end notification all receive
                // the notification before the continuous playback notification is emitted.
                dispatch_async(dispatch_get_main_queue(), ^{
                    notify();
                });
            }
        }
    }
}

- (void)segmentDidStart:(NSNotification *)notification
{
    SRGSubdivision *subdivision = notification.userInfo[SRGMediaPlayerSegmentKey];
    [self updateWithURN:self.URN media:self.media mediaComposition:self.mediaComposition subdivision:subdivision channel:self.channel program:self.program];
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxSegmentDidStartNotification
                                                      object:self
                                                    userInfo:notification.userInfo];
}

- (void)segmentDidEnd:(NSNotification *)notification
{
    [self updateWithURN:self.URN media:self.media mediaComposition:self.mediaComposition subdivision:nil channel:self.channel program:self.program];
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxSegmentDidEndNotification
                                                      object:self
                                                    userInfo:notification.userInfo];
}

- (void)playbackDidFail:(NSNotification *)notification
{
    if (self.dataAvailability == SRGLetterboxDataAvailabilityLoading) {
        self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
    }
    
    NSError *error = notification.userInfo[SRGMediaPlayerErrorKey];
    [self updateWithError:error];
    
    [[self.report informationForKey:@"playerResult"] srgletterbox_setPlayerInformationWithContentURL:self.mediaPlayerController.contentURL error:error];
    [[self.report informationForKey:@"playerResult"] stopTimeMeasurementForKey:@"duration"];
    [self.report stopTimeMeasurementForKey:@"duration"];
    [self.report finish];
}

- (void)routeDidChange:(NSNotification *)notification
{
    NSInteger routeChangeReason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
    if (routeChangeReason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable
            && self.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePlaying) {
        // Playback is automatically paused by the system. Force resume if desired. Wait a little bit (0.1 is an
        // empirical value), the system induced state change occurs slightly after this notification is received.
        // We could probably do something more robust (e.g. wait until the real state change), but this would lead
        // to additional complexity or states which do not seem required for correct behavior. Improve later if needed.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.resumesAfterRouteBecomesUnavailable) {
                [self play];
            }
        });
    }
}

#pragma mark KVO

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    if ([key isEqualToString:@keypath(SRGLetterboxController.new, playbackState)]) {
        return NO;
    }
    else {
        return [super automaticallyNotifiesObserversForKey:key];
    }
}

#pragma mark Description

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p; URN = %@; media = %@; mediaComposition = %@; channel = %@; error = %@; "
            "mediaPlayerController = %@>",
            self.class,
            self,
            self.URN,
            self.media,
            self.mediaComposition,
            self.channel,
            self.error,
            self.mediaPlayerController];
}

@end

@implementation SRGDiagnosticInformation (SRGLetterboxController)

- (void)srgletterbox_setDataInformationWithMediaCompostion:(SRGMediaComposition *)mediaComposition HTTPResponse:(NSHTTPURLResponse *)HTTPResponse error:(NSError *)error
{
    if (HTTPResponse) {
        [self setURL:HTTPResponse.URL forKey:@"url"];
        [self setInteger:HTTPResponse.statusCode forKey:@"httpStatusCode"];
        [self setString:HTTPResponse.allHeaderFields[@"X-Varnish"] forKey:@"varnish"];
    }
    // If the HTTP response is missing (network error typically), extract URL from error information
    else {
        [self setURL:error.userInfo[NSURLErrorFailingURLErrorKey] forKey:@"url"];
    }
    
    [self setString:error.localizedDescription forKey:@"errorMessage"];
    [self setString:SRGLetterboxCodeForBlockingReason([error.userInfo[SRGLetterboxBlockingReasonKey] integerValue]) forKey:@"blockReason"];
    if (mediaComposition) {
        SRGSubdivision *subdivision = mediaComposition.mainSegment ?: mediaComposition.mainChapter;
        [self setBool:subdivision.playableAbroad forKey:@"playableAbroad"];
    }
}

- (void)srgletterbox_setPlayerInformationWithContentURL:(NSURL *)contentURL error:(NSError *)error
{
    [self setURL:contentURL forKey:@"url"];
    [self setString:error.localizedDescription forKey:@"errorMessage"];
}

@end

