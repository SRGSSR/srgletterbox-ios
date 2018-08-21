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

#import <FXReachability/FXReachability.h>
#import <libextobjc/libextobjc.h>
#import <MAKVONotificationCenter/MAKVONotificationCenter.h>
#import <SRGAnalytics_DataProvider/SRGAnalytics_DataProvider.h>
#import <SRGAnalytics_MediaPlayer/SRGAnalytics_MediaPlayer.h>
#import <SRGMediaPlayer/SRGMediaPlayer.h>
#import <SRGNetwork/SRGNetwork.h>

static BOOL s_prefersDRM = NO;

NSString * const SRGLetterboxPlaybackStateDidChangeNotification = @"SRGLetterboxPlaybackStateDidChangeNotification";
NSString * const SRGLetterboxSegmentDidStartNotification = @"SRGLetterboxSegmentDidStartNotification";
NSString * const SRGLetterboxSegmentDidEndNotification = @"SRGLetterboxSegmentDidEndNotification";
NSString * const SRGLetterboxMetadataDidChangeNotification = @"SRGLetterboxMetadataDidChangeNotification";

NSString * const SRGLetterboxURNKey = @"SRGLetterboxURNKey";
NSString * const SRGLetterboxMediaKey = @"SRGLetterboxMediaKey";
NSString * const SRGLetterboxMediaCompositionKey = @"SRGLetterboxMediaCompositionKey";
NSString * const SRGLetterboxSubdivisionKey = @"SRGLetterboxSubdivisionKey";
NSString * const SRGLetterboxChannelKey = @"SRGLetterboxChannelKey";

NSString * const SRGLetterboxPreviousURNKey = @"SRGLetterboxPreviousURNKey";
NSString * const SRGLetterboxPreviousMediaKey = @"SRGLetterboxPreviousMediaKey";
NSString * const SRGLetterboxPreviousMediaCompositionKey = @"SRGLetterboxPreviousMediaCompositionKey";
NSString * const SRGLetterboxPreviousSubdivisionKey = @"SRGLetterboxPreviousSubdivisionKey";
NSString * const SRGLetterboxPreviousChannelKey = @"SRGLetterboxPreviousChannelKey";

NSString * const SRGLetterboxPlaybackDidFailNotification = @"SRGLetterboxPlaybackDidFailNotification";

NSString * const SRGLetterboxPlaybackDidRetryNotification = @"SRGLetterboxPlaybackDidRetryNotification";

NSString * const SRGLetterboxPlaybackDidContinueAutomaticallyNotification = @"SRGLetterboxPlaybackDidContinueAutomaticallyNotification";

NSString * const SRGLetterboxLivestreamDidFinishNotification = @"SRGLetterboxLivestreamDidFinishNotification";

NSString * const SRGLetterboxSocialCountViewWillIncreaseNotification = @"SRGLetterboxSocialCountViewWillIncreaseNotification";

NSString * const SRGLetterboxErrorKey = @"SRGLetterboxErrorKey";

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

@interface SRGLetterboxController ()

@property (nonatomic) SRGMediaPlayerController *mediaPlayerController;

@property (nonatomic) NSDictionary<NSString *, NSString *> *globalHeaders;

@property (nonatomic, copy) NSString *URN;
@property (nonatomic) SRGMedia *media;
@property (nonatomic) SRGMediaComposition *mediaComposition;
@property (nonatomic) SRGChannel *channel;
@property (nonatomic) SRGSubdivision *subdivision;
@property (nonatomic) CMTime startTime;
@property (nonatomic) SRGStreamType streamType;
@property (nonatomic) SRGQuality quality;
@property (nonatomic) NSInteger startBitRate;
@property (nonatomic, getter=isStandalone) BOOL standalone;
@property (nonatomic) NSError *error;

// Save the URN sent to the social count view service, to not send it twice
@property (nonatomic, copy) NSString *socialCountViewURN;

@property (nonatomic) SRGLetterboxDataAvailability dataAvailability;
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic) SRGMediaPlayerPlaybackState playbackState;

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

@end

@implementation SRGLetterboxController

@synthesize serviceURL = _serviceURL;
@synthesize globalHeaders = _globalHeaders;

#pragma mark Class methods

+ (void)setPrefersDRM:(BOOL)prefersDRM;
{
    s_prefersDRM = prefersDRM;
}

#pragma mark Object lifecycle

- (instancetype)init
{
    if (self = [super init]) {
        self.mediaPlayerController = [[SRGMediaPlayerController alloc] init];
        self.mediaPlayerController.analyticsPlayerName = @"SRGLetterbox";
        self.mediaPlayerController.analyticsPlayerVersion = SRGLetterboxMarketingVersion();
        
        // FIXME: See https://github.com/SRGSSR/SRGMediaPlayer-iOS/issues/50. Workaround so that the test passes on iOS 11.3.
        self.mediaPlayerController.minimumDVRWindowLength = 40.;
        
        @weakify(self)
        self.mediaPlayerController.playerConfigurationBlock = ^(AVPlayer *player) {
            @strongify(self)
            
            // Do not allow Airplay video playback by default
            player.allowsExternalPlayback = NO;
            
            // Only update the audio session if needed to avoid audio hiccups
            NSString *mode = (self.media.mediaType == SRGMediaTypeVideo) ? AVAudioSessionModeMoviePlayback : AVAudioSessionModeDefault;
            if (! [[AVAudioSession sharedInstance].mode isEqualToString:mode]) {
                [[AVAudioSession sharedInstance] setMode:mode error:NULL];
            }
            
            // Call the configuration block afterwards (so that the above default behavior can be overridden)
            self.playerConfigurationBlock ? self.playerConfigurationBlock(player) : nil;
            player.muted = self.muted;
        };
        
        // Also register the associated periodic time observers
        self.updateInterval = SRGLetterboxUpdateIntervalDefault;
        self.channelUpdateInterval = SRGLetterboxChannelUpdateIntervalDefault;
        
        self.playbackState = SRGMediaPlayerPlaybackStateIdle;
        
        self.resumesAfterRetry = YES;
        self.resumesAfterRouteBecomesUnavailable = NO;
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(reachabilityDidChange:)
                                                     name:FXReachabilityStatusDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playbackStateDidChange:)
                                                     name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                   object:self.mediaPlayerController];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(segmentDidStart:)
                                                     name:SRGMediaPlayerSegmentDidStartNotification
                                                   object:self.mediaPlayerController];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(segmentDidEnd:)
                                                     name:SRGMediaPlayerSegmentDidEndNotification
                                                   object:self.mediaPlayerController];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playbackDidFail:)
                                                     name:SRGMediaPlayerPlaybackDidFailNotification
                                                   object:self.mediaPlayerController];
        [[NSNotificationCenter defaultCenter] addObserver:self
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

- (BOOL)areBackgroundServicesEnabled
{
    return self == [SRGLetterboxService sharedService].controller;
}

- (BOOL)isPictureInPictureEnabled
{
    return self.backgroundServicesEnabled && [SRGLetterboxService sharedService].pictureInPictureDelegate;
}

- (BOOL)isPictureInPictureActive
{
    return self.pictureInPictureEnabled && self.mediaPlayerController.pictureInPictureController.pictureInPictureActive;
}

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
    if (updateInterval < 10.) {
        SRGLetterboxLogWarning(@"controller", @"The mimimum update interval is 10 seconds. Fixed to 10 seconds.");
        updateInterval = 10.;
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
                [self playMedia:self.media atTime:self.startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate];
            }
        }];
    }];
}

- (void)setChannelUpdateInterval:(NSTimeInterval)channelUpdateInterval
{
    if (channelUpdateInterval < 10.) {
        SRGLetterboxLogWarning(@"controller", @"The mimimum now and next update interval is 10 seconds. Fixed to 10 seconds.");
        channelUpdateInterval = 10.;
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
    if (self.pictureInPictureActive) {
        return NO;
    }
    
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
    
    CMTime startTime = [self startTimeForMedia:media];
    [self prepareToPlayMedia:media atTime:startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate completionHandler:completionHandler];
    
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

- (CMTime)startTimeForMedia:(SRGMedia *)media
{
    if ([self.playlistDataSource respondsToSelector:@selector(controller:startTimeForMedia:)]) {
        return [self.playlistDataSource controller:self startTimeForMedia:media];
    }
    else {
        return kCMTimeZero;
    }
}

- (void)cancelContinuousPlayback
{
    [self resetContinuousPlayback];
}

- (void)resetContinuousPlayback
{
    self.continuousPlaybackTransitionTimer = nil;
    self.continuousPlaybackTransitionStartDate = nil;
    self.continuousPlaybackTransitionEndDate = nil;
    self.continuousPlaybackUpcomingMedia = nil;
}

#pragma mark Data

// Pass in which data is available, the method will ensure that the data is consistent based on the most comprehensive
// information available (media composition first, then media, finally URN). Less comprehensive data will be ignored
- (void)updateWithURN:(NSString *)URN media:(SRGMedia *)media mediaComposition:(SRGMediaComposition *)mediaComposition subdivision:(SRGSubdivision *)subdivision channel:(SRGChannel *)channel
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
    
    self.URN = URN;
    self.media = media;
    self.mediaComposition = mediaComposition;
    self.subdivision = subdivision ?: self.mediaComposition.mainChapter;
    self.channel = channel ?: media.channel;
    
    NSMutableDictionary<NSString *, id> *userInfo = [NSMutableDictionary dictionary];
    if (URN) {
        userInfo[SRGLetterboxURNKey] = URN;
    }
    if (media) {
        userInfo[SRGLetterboxMediaKey] = media;
    }
    if (mediaComposition) {
        userInfo[SRGLetterboxMediaCompositionKey] = mediaComposition;
    }
    if (subdivision) {
        userInfo[SRGLetterboxSubdivisionKey] = subdivision;
    }
    if (channel) {
        userInfo[SRGLetterboxChannelKey] = channel;
    }
    if (previousURN) {
        userInfo[SRGLetterboxPreviousURNKey] = previousURN;
    }
    if (previousMedia) {
        userInfo[SRGLetterboxPreviousMediaKey] = previousMedia;
    }
    if (previousMediaComposition) {
        userInfo[SRGLetterboxPreviousMediaCompositionKey] = previousMediaComposition;
    }
    if (previousSubdivision) {
        userInfo[SRGLetterboxPreviousSubdivisionKey] = previousSubdivision;
    }
    if (previousChannel) {
        userInfo[SRGLetterboxPreviousChannelKey] = previousChannel;
    }
    
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
                    [self playMedia:self.media atTime:self.startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate];
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
            
            [self updateWithError:SRGBlockingReasonErrorForMedia(self.media, [NSDate date])];
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
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxMetadataDidChangeNotification object:self userInfo:[userInfo copy]];
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
                    && [media blockingReasonAtDate:[NSDate date]] == SRGBlockingReasonEndDate)) {
                [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxLivestreamDidFinishNotification
                                                                    object:self
                                                                  userInfo:@{ SRGLetterboxMediaKey : previousMedia }];
        }
    }
    else {
        if ((media.contentType == SRGContentTypeLivestream || media.contentType == SRGContentTypeScheduledLivestream)
                && [media blockingReasonAtDate:[NSDate date]] == SRGBlockingReasonEndDate) {
            [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxLivestreamDidFinishNotification
                                                                object:self
                                                              userInfo:@{ SRGLetterboxMediaKey : media }];
        }
        
    }
}

- (void)updateMetadataWithCompletionBlock:(void (^)(NSError *error, BOOL resourceChanged, NSError *previousError))completionBlock
{
    void (^updateCompletionBlock)(SRGMedia * _Nullable, NSError * _Nullable, BOOL, SRGMedia * _Nullable, NSError * _Nullable) = ^(SRGMedia * _Nullable media, NSError * _Nullable error, BOOL resourceChanged, SRGMedia * _Nullable previousMedia, NSError * _Nullable previousError) {
        // Do not erase playback errors with successful metadata updates
        if (error || ! [self.error.domain isEqualToString:SRGLetterboxErrorDomain] || self.error.code != SRGLetterboxErrorCodeNotPlayable) {
            [self updateWithError:error];
        }
        
        [self notifyLivestreamEndWithMedia:media previousMedia:previousMedia];
        
        self.lastUpdateDate = [NSDate date];
        
        completionBlock ? completionBlock(error, resourceChanged, previousError) : nil;
    };
    
    if (self.contentURLOverridden) {
        SRGRequest *mediaRequest = [self.dataProvider mediaWithURN:self.URN completionBlock:^(SRGMedia * _Nullable media, NSError * _Nullable error) {
            SRGMedia *previousMedia = self.media;
            
            if (media) {
                [self updateWithURN:nil media:media mediaComposition:nil subdivision:self.subdivision channel:self.channel];
            }
            else {
                media = previousMedia;
            }
            
            updateCompletionBlock(media, SRGBlockingReasonErrorForMedia(media, [NSDate date]), NO, previousMedia, SRGBlockingReasonErrorForMedia(previousMedia, self.lastUpdateDate));
        }];
        [self.requestQueue addRequest:mediaRequest resume:YES];
        return;
    }
    
    SRGRequest *mediaCompositionRequest = [self.dataProvider mediaCompositionForURN:self.URN standalone:self.standalone withCompletionBlock:^(SRGMediaComposition * _Nullable mediaComposition, NSError * _Nullable error) {
        SRGMediaCompositionCompletionBlock mediaCompositionCompletionBlock = ^(SRGMediaComposition * _Nullable mediaComposition, NSError * _Nullable error) {
            SRGMediaComposition *previousMediaComposition = self.mediaComposition;
            
            SRGMedia *previousMedia = [previousMediaComposition mediaForSubdivision:previousMediaComposition.mainChapter];
            NSError *previousBlockingReasonError = SRGBlockingReasonErrorForMedia(previousMedia, self.lastUpdateDate);
            
            // Update metadata if retrieved, otherwise perform a check with the metadata we already have
            if (mediaComposition) {
                self.mediaPlayerController.mediaComposition = mediaComposition;
                [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:self.subdivision channel:self.channel];
            }
            else {
                mediaComposition = previousMediaComposition;
            }
            
            if (mediaComposition) {
                // Check whether the media is now blocked (conditions might have changed, e.g. user location or time)
                SRGMedia *media = [mediaComposition mediaForSubdivision:mediaComposition.mainChapter];
                NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, [NSDate date]);
                if (blockingReasonError) {
                    updateCompletionBlock(mediaComposition.srgletterbox_liveMedia, blockingReasonError, NO, previousMediaComposition.srgletterbox_liveMedia, previousBlockingReasonError);
                    return;
                }
                
                if (previousMediaComposition) {
                    // Update the URL if resources change (also cover DVR to live change or conversely, aka DVR "kill switch")
                    NSSet<SRGResource *> *previousResources = [NSSet setWithArray:previousMediaComposition.mainChapter.playableResources];
                    NSSet<SRGResource *> *resources = [NSSet setWithArray:mediaComposition.mainChapter.playableResources];
                    if (! [previousResources isEqualToSet:resources]) {
                        updateCompletionBlock(mediaComposition.srgletterbox_liveMedia, (self.error) ? error : nil, YES, previousMediaComposition.srgletterbox_liveMedia, previousBlockingReasonError);
                        return;
                    }
                }
            }
            
            updateCompletionBlock(mediaComposition.srgletterbox_liveMedia, self.error ? error : nil, NO, previousMediaComposition.srgletterbox_liveMedia, previousBlockingReasonError);
        };
        
        if ([error.domain isEqualToString:SRGNetworkErrorDomain] && error.code == SRGNetworkErrorHTTP && [error.userInfo[SRGNetworkHTTPStatusCodeKey] integerValue] == 404
                && self.mediaComposition && ! [self.mediaComposition.fullLengthMedia.URN isEqual:self.URN]) {
            SRGRequest *fullLengthMediaCompositionRequest = [self.dataProvider mediaCompositionForURN:self.mediaComposition.fullLengthMedia.URN
                                                                                           standalone:self.standalone
                                                                                  withCompletionBlock:mediaCompositionCompletionBlock];
            [self.requestQueue addRequest:fullLengthMediaCompositionRequest resume:YES];
        }
        else {
            mediaCompositionCompletionBlock(mediaComposition, error);
        }
    }];
    [self.requestQueue addRequest:mediaCompositionRequest resume:YES];
}

- (void)updateChannel
{
    if (! self.media || self.media.contentType != SRGContentTypeLivestream || ! self.media.channel.uid) {
        return;
    }
    
    void (^completionBlock)(SRGChannel * _Nullable, NSError * _Nullable) = ^(SRGChannel * _Nullable channel, NSError * _Nullable error) {
        [self updateWithURN:self.URN media:self.media mediaComposition:self.mediaComposition subdivision:self.subdivision channel:channel];
    };
    
    if (self.media.mediaType == SRGMediaTypeVideo) {
        SRGRequest *request = [self.dataProvider tvChannelForVendor:self.media.vendor withUid:self.media.channel.uid completionBlock:completionBlock];
        [self.requestQueue addRequest:request resume:YES];
    }
    else if (self.media.mediaType == SRGMediaTypeAudio) {
        if (self.media.vendor == SRGVendorSRF && ! [self.media.uid isEqualToString:self.media.channel.uid]) {
            SRGRequest *request = [self.dataProvider radioChannelForVendor:self.media.vendor withUid:self.media.channel.uid livestreamUid:self.media.uid completionBlock:completionBlock];
            [self.requestQueue addRequest:request resume:YES];
        }
        else {
            SRGRequest *request = [self.dataProvider radioChannelForVendor:self.media.vendor withUid:self.media.channel.uid livestreamUid:nil completionBlock:completionBlock];
            [self.requestQueue addRequest:request resume:YES];
        }
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
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxPlaybackDidFailNotification object:self userInfo:@{ SRGLetterboxErrorKey : self.error }];
}

#pragma mark Playback

- (void)prepareToPlayURN:(NSString *)URN atTime:(CMTime)time standalone:(BOOL)standalone withPreferredStreamType:(SRGStreamType)streamType quality:(SRGQuality)quality startBitRate:(NSInteger)startBitRate completionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURN:URN atTime:time standalone:standalone media:nil withPreferredStreamType:streamType quality:quality startBitRate:startBitRate completionHandler:completionHandler];
}

- (void)prepareToPlayMedia:(SRGMedia *)media atTime:(CMTime)time standalone:(BOOL)standalone withPreferredStreamType:(SRGStreamType)streamType quality:(SRGQuality)quality startBitRate:(NSInteger)startBitRate completionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURN:nil atTime:time standalone:standalone media:media withPreferredStreamType:streamType quality:quality startBitRate:startBitRate completionHandler:completionHandler];
}

- (void)prepareToPlayURN:(NSString *)URN atTime:(CMTime)time standalone:(BOOL)standalone media:(SRGMedia *)media withPreferredStreamType:(SRGStreamType)streamType quality:(SRGQuality)quality startBitRate:(NSInteger)startBitRate completionHandler:(void (^)(void))completionHandler
{
    if (media) {
        URN = media.URN;
    }
    
    if (! URN) {
        return;
    }
    
    if (startBitRate < 0) {
        startBitRate = 0;
    }
    
    // If already playing the media, does nothing
    if (self.mediaPlayerController.playbackState != SRGMediaPlayerPlaybackStateIdle && [self.URN isEqual:URN]) {
        return;
    }
    
    [self resetWithURN:URN media:media];
    
    // Save the settings for restarting after connection loss
    self.startTime = time;
    self.streamType = streamType;
    self.quality = quality;
    self.startBitRate = startBitRate;
    self.standalone = standalone;
    
    @weakify(self)
    self.requestQueue = [[SRGRequestQueue alloc] init];
    
    self.dataAvailability = SRGLetterboxDataAvailabilityLoading;
    
    // Apply overriding if available. Overriding requires a media to be available. No media composition is retrieved
    if (self.contentURLOverridingBlock) {
        NSURL *contentURL = self.contentURLOverridingBlock(URN);
        if (contentURL) {
            void (^prepareToPlay)(NSURL *) = ^(NSURL *contentURL) {
                if (media.presentation == SRGPresentation360) {
                    if (self.mediaPlayerController.view.viewMode != SRGMediaPlayerViewModeMonoscopic && self.mediaPlayerController.view.viewMode != SRGMediaPlayerViewModeStereoscopic) {
                        self.mediaPlayerController.view.viewMode = SRGMediaPlayerViewModeMonoscopic;
                    }
                }
                else {
                    self.mediaPlayerController.view.viewMode = SRGMediaPlayerViewModeFlat;
                }
                [self.mediaPlayerController prepareToPlayURL:contentURL atTime:time withSegments:nil userInfo:nil completionHandler:completionHandler];
            };
            
            // Media readily available. Done
            if (media) {
                self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
                NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, [NSDate date]);
                [self updateWithError:blockingReasonError];
                [self notifyLivestreamEndWithMedia:media previousMedia:nil];
                
                if (! blockingReasonError) {
                    prepareToPlay(contentURL);
                }
            }
            // Retrieve the media
            else {
                void (^mediaCompletionBlock)(SRGMedia * _Nullable, NSError * _Nullable) = ^(SRGMedia * _Nullable media, NSError * _Nullable error) {
                    if (error) {
                        self.dataAvailability = SRGLetterboxDataAvailabilityNone;
                        [self updateWithError:error];
                        return;
                    }
                    
                    self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
                    
                    [self updateWithURN:nil media:media mediaComposition:nil subdivision:nil channel:nil];
                    [self notifyLivestreamEndWithMedia:media previousMedia:nil];
                    
                    NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, [NSDate date]);
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
            return;
        }
    }
    
    SRGRequest *mediaCompositionRequest = [self.dataProvider mediaCompositionForURN:self.URN standalone:standalone withCompletionBlock:^(SRGMediaComposition * _Nullable mediaComposition, NSError * _Nullable error) {
        @strongify(self)
        
        if (error) {
            self.dataAvailability = SRGLetterboxDataAvailabilityNone;
            [self updateWithError:error];
            return;
        }
        
        [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:mediaComposition.mainSegment channel:nil];
        [self updateChannel];
        
        SRGMedia *media = [mediaComposition mediaForSubdivision:mediaComposition.mainChapter];
        [self notifyLivestreamEndWithMedia:media previousMedia:nil];
        
        // Do not go further if the content is blocked
        NSError *blockingReasonError = SRGBlockingReasonErrorForMedia(media, [NSDate date]);
        if (blockingReasonError) {
            self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
            [self updateWithError:blockingReasonError];
            return;
        }
        
        // TODO: Replace s_prefersDRM with YES when removed
        if (! [self.mediaPlayerController prepareToPlayMediaComposition:mediaComposition atTime:time withPreferredStreamingMethod:SRGStreamingMethodNone streamType:streamType quality:quality DRM:s_prefersDRM startBitRate:startBitRate userInfo:nil completionHandler:completionHandler]) {
            self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
            
            NSError *error = [NSError errorWithDomain:SRGDataProviderErrorDomain
                                                 code:SRGDataProviderErrorCodeInvalidData
                                             userInfo:@{ NSLocalizedDescriptionKey : SRGLetterboxNonLocalizedString(@"No recommended streaming resources found") }];
            [self updateWithError:error];
        }
    }];
    [self.requestQueue addRequest:mediaCompositionRequest resume:YES];
}

- (void)play
{
    if (self.mediaPlayerController.contentURL) {
        [self cancelContinuousPlayback];
        [self.mediaPlayerController play];
    }
    else if (self.media) {
        [self playMedia:self.media atTime:self.startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate];
    }
    else if (self.URN) {
        [self playURN:self.URN atTime:self.startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate];
    };
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
        [self prepareToPlayMedia:self.media atTime:self.startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate completionHandler:prepareToPlayCompletionHandler];
    }
    else if (self.URN) {
        [self prepareToPlayURN:self.URN atTime:self.startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate completionHandler:prepareToPlayCompletionHandler];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxPlaybackDidRetryNotification object:self];
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
    }
    else {
        self.dataProvider = nil;
    }
    
    self.error = nil;
    
    self.lastUpdateDate = nil;
    
    self.dataAvailability = SRGLetterboxDataAvailabilityNone;
    
    self.streamType = SRGStreamTypeNone;
    self.quality = SRGQualityNone;
    self.startBitRate = 0;
    
    self.socialCountViewURN = nil;
    self.socialCountViewTimer = nil;
    
    [self resetContinuousPlayback];
    
    [self updateWithURN:URN media:media mediaComposition:nil subdivision:nil channel:nil];
    
    [self.mediaPlayerController reset];
    [self.requestQueue cancel];
}

- (void)seekToTime:(CMTime)time withToleranceBefore:(CMTime)toleranceBefore toleranceAfter:(CMTime)toleranceAfter completionHandler:(void (^)(BOOL))completionHandler
{
    [self.mediaPlayerController seekToTime:time withToleranceBefore:toleranceBefore toleranceAfter:toleranceAfter completionHandler:completionHandler];
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
    if ([subdivision isKindOfClass:[SRGChapter class]]
            || self.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateIdle
            || self.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStatePreparing) {
        NSError *blockingReasonError = SRGBlockingReasonErrorForMedia([mediaComposition mediaForSubdivision:mediaComposition.mainChapter], [NSDate date]);
        [self updateWithError:blockingReasonError];
        
        if (blockingReasonError) {
            self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
        }
        
        [self stop];
        self.socialCountViewURN = nil;
        self.socialCountViewTimer = nil;
        [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:subdivision channel:nil];
        
        if (! blockingReasonError) {
            // TODO: Replace s_prefersDRM with YES when removed
            [self.mediaPlayerController prepareToPlayMediaComposition:mediaComposition atTime:kCMTimeZero withPreferredStreamingMethod:SRGStreamingMethodNone streamType:self.streamType quality:self.quality DRM:s_prefersDRM startBitRate:self.startBitRate userInfo:nil completionHandler:^{
                [self.mediaPlayerController play];
                completionHandler ? completionHandler(YES) : nil;
            }];
        }
    }
    // Playing another segment from the same media. Seek
    else if ([subdivision isKindOfClass:[SRGSegment class]]) {
        [self updateWithURN:nil media:nil mediaComposition:mediaComposition subdivision:subdivision channel:nil];
        [self.mediaPlayerController seekToTime:kCMTimeZero inSegment:(SRGSegment *)subdivision withCompletionHandler:^(BOOL finished) {
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

- (void)prepareToPlayURN:(NSString *)URN standalone:(BOOL)standalone withCompletionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURN:URN atTime:kCMTimeZero standalone:standalone withPreferredStreamType:SRGStreamTypeNone quality:SRGQualityNone startBitRate:SRGLetterboxDefaultStartBitRate completionHandler:completionHandler];
}

- (void)prepareToPlayMedia:(SRGMedia *)media standalone:(BOOL)standalone withCompletionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayMedia:media atTime:kCMTimeZero standalone:standalone withPreferredStreamType:SRGStreamTypeNone quality:SRGQualityNone startBitRate:SRGLetterboxDefaultStartBitRate completionHandler:completionHandler];
}

- (void)playURN:(NSString *)URN atTime:(CMTime)time standalone:(BOOL)standalone withPreferredStreamType:(SRGStreamType)streamType quality:(SRGQuality)quality startBitRate:(NSInteger)startBitRate
{
    @weakify(self)
    [self prepareToPlayURN:URN atTime:time standalone:standalone withPreferredStreamType:streamType quality:quality startBitRate:startBitRate completionHandler:^{
        @strongify(self)
        [self play];
    }];
}

- (void)playMedia:(SRGMedia *)media atTime:(CMTime)time standalone:(BOOL)standalone withPreferredStreamType:(SRGStreamType)streamType quality:(SRGQuality)quality startBitRate:(NSInteger)startBitRate
{
    @weakify(self)
    [self prepareToPlayMedia:media atTime:time standalone:standalone withPreferredStreamType:streamType quality:quality startBitRate:startBitRate completionHandler:^{
        @strongify(self)
        [self play];
    }];
}

- (void)playURN:(NSString *)URN standalone:(BOOL)standalone
{
    [self playURN:URN atTime:self.startTime standalone:standalone withPreferredStreamType:SRGStreamTypeNone quality:SRGQualityNone startBitRate:SRGLetterboxDefaultStartBitRate];
}

- (void)playMedia:(SRGMedia *)media standalone:(BOOL)standalone
{
    [self playMedia:media atTime:self.startTime standalone:standalone withPreferredStreamType:SRGStreamTypeNone quality:SRGQualityNone startBitRate:SRGLetterboxDefaultStartBitRate];
}

- (void)seekEfficientlyToTime:(CMTime)time withCompletionHandler:(void (^)(BOOL))completionHandler
{
    [self seekToTime:time withToleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:completionHandler];
}

- (void)seekPreciselyToTime:(CMTime)time withCompletionHandler:(void (^)(BOOL))completionHandler
{
    [self seekToTime:time withToleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:completionHandler];
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
        return [self.mediaComposition.srgletterbox_liveMedia blockingReasonAtDate:[NSDate date]] != SRGBlockingReasonEndDate;
    }
    else {
        return NO;
    }
}

- (BOOL)skipBackwardWithCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    return [self seekBackwardFromTime:[self seekStartTime] withCompletionHandler:completionHandler];
}

- (BOOL)skipForwardWithCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    return [self seekForwardFromTime:[self seekStartTime] withCompletionHandler:completionHandler];
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
    
    SRGMediaPlayerPlaybackState playbackState = self.mediaPlayerController.playbackState;
    if (playbackState == SRGMediaPlayerPlaybackStateIdle || playbackState == SRGMediaPlayerPlaybackStatePreparing) {
        return NO;
    }
    
    SRGMediaPlayerStreamType streamType = self.mediaPlayerController.streamType;
    return (streamType == SRGMediaPlayerStreamTypeOnDemand || streamType == SRGMediaPlayerStreamTypeDVR);
}

- (BOOL)canSkipForwardFromTime:(CMTime)time
{
    if (CMTIME_IS_INDEFINITE(time)) {
        return NO;
    }
    
    SRGMediaPlayerPlaybackState playbackState = self.mediaPlayerController.playbackState;
    if (playbackState == SRGMediaPlayerPlaybackStateIdle || playbackState == SRGMediaPlayerPlaybackStatePreparing) {
        return NO;
    }
    
    SRGMediaPlayerController *mediaPlayerController = self.mediaPlayerController;
    return (mediaPlayerController.streamType == SRGMediaPlayerStreamTypeOnDemand && CMTimeGetSeconds(time) + SRGLetterboxForwardSkipInterval < CMTimeGetSeconds(mediaPlayerController.player.currentItem.duration))
        || (mediaPlayerController.streamType == SRGMediaPlayerStreamTypeDVR && ! mediaPlayerController.live);
}

- (BOOL)seekBackwardFromTime:(CMTime)time withCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    if (! [self canSkipBackwardFromTime:time]) {
        return NO;
    }
    
    CMTime targetTime = CMTimeSubtract(time, CMTimeMakeWithSeconds(SRGLetterboxBackwardSkipInterval, NSEC_PER_SEC));
    [self seekToTime:targetTime withToleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:^(BOOL finished) {
        if (finished) {
            [self.mediaPlayerController play];
        }
        completionHandler ? completionHandler(finished) : nil;
    }];
    return YES;
}

- (BOOL)seekForwardFromTime:(CMTime)time withCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    if (! [self canSkipForwardFromTime:time]) {
        return NO;
    }
    
    CMTime targetTime = CMTimeAdd(time, CMTimeMakeWithSeconds(SRGLetterboxForwardSkipInterval, NSEC_PER_SEC));
    [self seekToTime:targetTime withToleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:^(BOOL finished) {
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
        [self seekToTime:CMTimeRangeGetEnd(self.mediaPlayerController.timeRange) withToleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:^(BOOL finished) {
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

- (void)reloadPlayerConfiguration
{
    [self.mediaPlayerController reloadPlayerConfiguration];
}

#pragma mark Notifications

- (void)reachabilityDidChange:(NSNotification *)notification
{
    if ([FXReachability sharedInstance].reachable) {
        [self retry];
    }
}

- (void)playbackStateDidChange:(NSNotification *)notification
{
    SRGMediaPlayerPlaybackState playbackState = [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue];
    if (playbackState != self.playbackState) {
        self.playbackState = playbackState;
        [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxPlaybackStateDidChangeNotification
                                                            object:self
                                                          userInfo:notification.userInfo];
    }
    
    // Do not let pause live streams, also when the state is changed from picture in picture controls. Stop playback instead
    if (self.pictureInPictureActive && self.mediaPlayerController.streamType == SRGMediaPlayerStreamTypeLive && playbackState == SRGMediaPlayerPlaybackStatePaused) {
        [self stop];
    }
    
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
            
            [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxSocialCountViewWillIncreaseNotification
                                                                object:self
                                                              userInfo:@{ SRGLetterboxSubdivisionKey : subdivision }];
            
            SRGRequest *request = [self.dataProvider increaseSocialCountForType:SRGSocialCountTypeSRGView subdivision:subdivision withCompletionBlock:^(SRGSocialCountOverview * _Nullable socialCountOverview, NSError * _Nullable error) {
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
        
        NSTimeInterval continuousPlaybackTransitionDuration = SRGLetterboxContinuousPlaybackTransitionDurationDisabled;
        if ([self.playlistDataSource respondsToSelector:@selector(continuousPlaybackTransitionDurationForController:)]) {
            continuousPlaybackTransitionDuration = [self.playlistDataSource continuousPlaybackTransitionDurationForController:self];
            if (continuousPlaybackTransitionDuration < 0.) {
                continuousPlaybackTransitionDuration = 0.;
            }
        }
        
        void (^notify)(void) = ^{
            if ([self.playlistDataSource respondsToSelector:@selector(controller:didTransitionToMedia:automatically:)]) {
                [self.playlistDataSource controller:self didTransitionToMedia:nextMedia automatically:YES];
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxPlaybackDidContinueAutomaticallyNotification
                                                                object:self
                                                              userInfo:@{ SRGLetterboxURNKey : nextMedia.URN,
                                                                          SRGLetterboxMediaKey : nextMedia }];
        };
        
        if (nextMedia && continuousPlaybackTransitionDuration != SRGLetterboxContinuousPlaybackTransitionDurationDisabled && ! self.pictureInPictureActive) {
            CMTime startTime = [self startTimeForMedia:nextMedia];
            
            if (continuousPlaybackTransitionDuration != 0.) {
                self.continuousPlaybackTransitionStartDate = NSDate.date;
                self.continuousPlaybackTransitionEndDate = [NSDate dateWithTimeIntervalSinceNow:continuousPlaybackTransitionDuration];
                self.continuousPlaybackUpcomingMedia = nextMedia;
                
                @weakify(self)
                self.continuousPlaybackTransitionTimer = [NSTimer srgletterbox_timerWithTimeInterval:continuousPlaybackTransitionDuration repeats:NO block:^(NSTimer * _Nonnull timer) {
                    @strongify(self)
                    
                    [self playMedia:nextMedia atTime:startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate];
                    [self resetContinuousPlayback];
                    notify();
                }];
            }
            else {
                [self playMedia:nextMedia atTime:startTime standalone:self.standalone withPreferredStreamType:self.streamType quality:self.quality startBitRate:self.startBitRate];
                
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
    [self updateWithURN:self.URN media:self.media mediaComposition:self.mediaComposition subdivision:subdivision channel:self.channel];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxSegmentDidStartNotification
                                                        object:self
                                                      userInfo:notification.userInfo];
}

- (void)segmentDidEnd:(NSNotification *)notification
{
    [self updateWithURN:self.URN media:self.media mediaComposition:self.mediaComposition subdivision:nil channel:self.channel];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGLetterboxSegmentDidEndNotification
                                                        object:self
                                                      userInfo:notification.userInfo];
}

- (void)playbackDidFail:(NSNotification *)notification
{
    if (self.dataAvailability == SRGLetterboxDataAvailabilityLoading) {
        self.dataAvailability = SRGLetterboxDataAvailabilityLoaded;
    }
    [self updateWithError:notification.userInfo[SRGMediaPlayerErrorKey]];
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
    return [NSString stringWithFormat:@"<%@: %p; URN: %@; media: %@; mediaComposition: %@; channel: %@; error: %@; mediaPlayerController: %@>",
            [self class],
            self,
            self.URN,
            self.media,
            self.mediaComposition,
            self.channel,
            self.error,
            self.mediaPlayerController];
}

@end
