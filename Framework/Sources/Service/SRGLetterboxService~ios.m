//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxService.h"

#import "MPRemoteCommand+SRGLetterbox.h"
#import "SRGLetterboxController+Private.h"
#import "SRGLetterboxLogger.h"
#import "SRGProgram+SRGLetterbox.h"
#import "UIDevice+SRGLetterbox.h"
#import "UIImage+SRGLetterbox.h"

#import <libextobjc/libextobjc.h>
#import <MAKVONotificationCenter/MAKVONotificationCenter.h>
#import <MediaPlayer/MediaPlayer.h>
#import <SRGAppearance/SRGAppearance.h>
#import <SRGMediaPlayer/SRGMediaPlayer.h>
#import <YYWebImage/YYWebImage.h>

SRGLetterboxCommands SRGLetterboxCommandsDefault = SRGLetterboxCommandSkipForward | SRGLetterboxCommandSkipBackward
    | SRGLetterboxCommandSeekForward | SRGLetterboxCommandSeekBackward | SRGLetterboxCommandChangePlaybackPosition
    | SRGLetterboxCommandLanguageSelection;

NSString * const SRGLetterboxServiceSettingsDidChangeNotification = @"SRGLetterboxServiceSettingsDidChangeNotification";

static MPNowPlayingInfoLanguageOptionGroup *SRGLetterboxServiceLanguageOptionGroup(NSArray<AVMediaSelectionOption *> *selectionOption, BOOL allowEmptySelection);

@interface SRGLetterboxService () <AVPictureInPictureControllerDelegate> {
@private
    BOOL _restoreUserInterface;
    BOOL _playbackStopped;
}

@property (nonatomic) SRGLetterboxController *controller;
@property (nonatomic) id<SRGLetterboxPictureInPictureDelegate> pictureInPictureDelegate;

@property (nonatomic, getter=areNowPlayingInfoAndCommandsEnabled) BOOL nowPlayingInfoAndCommandsEnabled;
@property (nonatomic) SRGLetterboxCommands allowedCommands;

@property (nonatomic, weak) id periodicTimeObserver;
@property (nonatomic) YYWebImageOperation *imageOperation;

@property (atomic) NSURL *cachedArtworkURL;
@property (atomic) UIImage *cachedArtworkImage;

@end

@implementation SRGLetterboxService

#pragma mark Class methods

+ (SRGLetterboxService *)sharedService
{
    static SRGLetterboxService *s_sharedService;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_sharedService = [SRGLetterboxService new];
    });
    return s_sharedService;
}

#pragma mark Object lifecycle

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

- (instancetype)init
{
    if (self = [super init]) {
        self.nowPlayingInfoAndCommandsEnabled = YES;
        self.allowedCommands = SRGLetterboxCommandsDefault;
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationDidEnterBackground:)
                                                   name:UIApplicationDidEnterBackgroundNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationDidBecomeActive:)
                                                   name:UIApplicationDidBecomeActiveNotification
                                                 object:nil];
        
        _restoreUserInterface = YES;
        _playbackStopped = YES;
    }
    return self;
}

#pragma clang diagnostic pop

- (void)dealloc
{
    self.controller = nil;
    self.nowPlayingInfoAndCommandsEnabled = NO;
}

#pragma mark Getters and setters

- (void)setNowPlayingInfoAndCommandsEnabled:(BOOL)nowPlayingInfoAndCommandsEnabled
{
    _nowPlayingInfoAndCommandsEnabled = nowPlayingInfoAndCommandsEnabled;
    
    if (nowPlayingInfoAndCommandsEnabled) {
        [self setupRemoteCommandCenter];
    }
    else {
        [self resetRemoteCommandCenter];
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    }
}

- (void)setAllowedCommands:(SRGLetterboxCommands)allowedCommands
{
    _allowedCommands = allowedCommands;
    
    [self updateRemoteCommandCenterWithController:self.controller];
}

- (void)setController:(SRGLetterboxController *)controller
{
    if (_controller) {
        // Revert back to default behavior
        _controller.playerConfigurationBlock = nil;
        [_controller reloadPlayerConfiguration];
        
        // TODO: Not needed if program information is later delivered as highlights (segments).
        [_controller removeObserver:self keyPath:@keypath(_controller.program)];
        
        SRGMediaPlayerController *previousMediaPlayerController = _controller.mediaPlayerController;
        [previousMediaPlayerController removeObserver:self keyPath:@keypath(previousMediaPlayerController.timeRange)];
        
        AVPictureInPictureController *pictureInPictureController = previousMediaPlayerController.pictureInPictureController;
        [pictureInPictureController removeObserver:self keyPath:@keypath(pictureInPictureController.pictureInPictureActive)];
        
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:SRGLetterboxMetadataDidChangeNotification
                                                    object:_controller];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                    object:previousMediaPlayerController];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:SRGMediaPlayerSeekNotification
                                                    object:previousMediaPlayerController];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:SRGMediaPlayerAudioTrackDidChangeNotification
                                                    object:previousMediaPlayerController];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:SRGMediaPlayerSubtitleTrackDidChangeNotification
                                                    object:previousMediaPlayerController];
        
        [previousMediaPlayerController removePeriodicTimeObserver:self.periodicTimeObserver];
    }
    
    _controller = controller;
    
    [self updateRemoteCommandCenterWithController:controller];
    [self updateNowPlayingInformationWithController:controller];
    
    if (controller) {
        controller.playerConfigurationBlock = ^(AVPlayer *player) {
            // Do not switch to external playback when playing anything other than videos. External playback is namely only
            // intended for video playback. If you try to play audio with external playback, then:
            //   - The screen will be black instead of displaying a media notification.
            //   - The user won't be able to change the volume with the phone controls.
            // Remark: For video external playback, it is normal that the user cannot control the volume from her device.
            player.allowsExternalPlayback = (controller.media.mediaType == SRGMediaTypeVideo);
            player.usesExternalPlaybackWhileExternalScreenIsActive = ! self.mirroredOnExternalScreen;
        };
        [controller reloadPlayerConfiguration];
        
        // TODO: Not needed if program information is later delivered as highlights (segments).
        @weakify(controller)
        [controller addObserver:self keyPath:@keypath(controller.program) options:0 block:^(MAKVONotification *notification) {
            @strongify(controller)
            [self updateNowPlayingInformationWithController:controller];
        }];
        
        SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
        [mediaPlayerController addObserver:self keyPath:@keypath(mediaPlayerController.timeRange) options:0 block:^(MAKVONotification *notification) {
            [self updateNowPlayingInformationWithController:controller];
        }];
        
        AVPictureInPictureController *pictureInPictureController = mediaPlayerController.pictureInPictureController;
        if (pictureInPictureController) {
            @weakify(self) @weakify(pictureInPictureController)
            [pictureInPictureController addObserver:self keyPath:@keypath(pictureInPictureController.pictureInPictureActive) options:0 block:^(MAKVONotification *notification) {
                @strongify(self) @strongify(pictureInPictureController)
                
                // When enabling AirPlay from the control center while picture in picture is active, picture in picture will be
                // stopped without the usual restoration and stop delegate methods being called. KVO observe changes and call
                // those methods manually
                if (mediaPlayerController.player.externalPlaybackActive) {
                    [self pictureInPictureController:pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:^(BOOL restored) {}];
                    [self pictureInPictureControllerDidStopPictureInPicture:pictureInPictureController];
                }
            }];
            
            pictureInPictureController.delegate = self;
        }
        else {
            @weakify(self)
            mediaPlayerController.pictureInPictureControllerCreationBlock = ^(AVPictureInPictureController *pictureInPictureController) {
                @strongify(self)
                
                pictureInPictureController.delegate = self;
            };
        }
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(metadataDidChange:)
                                                   name:SRGLetterboxMetadataDidChangeNotification
                                                 object:controller];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackStateDidChange:)
                                                   name:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                 object:mediaPlayerController];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playerSeek:)
                                                   name:SRGMediaPlayerSeekNotification
                                                 object:mediaPlayerController];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(audioTrackDidChange:)
                                                   name:SRGMediaPlayerAudioTrackDidChangeNotification
                                                 object:mediaPlayerController];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(subtitleTrackDidChange:)
                                                   name:SRGMediaPlayerSubtitleTrackDidChangeNotification
                                                 object:mediaPlayerController];
        
        @weakify(self)
        self.periodicTimeObserver = [mediaPlayerController addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.2, NSEC_PER_SEC) queue:NULL usingBlock:^(CMTime time) {
            @strongify(self)
            [self updateRemoteCommandCenterWithController:controller];
        }];
    }
}

- (void)setMirroredOnExternalScreen:(BOOL)mirroredOnExternalScreen
{
    if (_mirroredOnExternalScreen == mirroredOnExternalScreen) {
        return;
    }
    
    _mirroredOnExternalScreen = mirroredOnExternalScreen;
    [self.controller.mediaPlayerController reloadPlayerConfiguration];
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxServiceSettingsDidChangeNotification object:self];
}

#pragma mark Enabling and disabling the service

- (void)enableWithController:(SRGLetterboxController *)controller pictureInPictureDelegate:(id<SRGLetterboxPictureInPictureDelegate>)pictureInPictureDelegate
{
    if (self.controller == controller && self.pictureInPictureDelegate == pictureInPictureDelegate) {
        return;
    }
    
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        NSArray<NSString *> *backgroundModes = NSBundle.mainBundle.infoDictionary[@"UIBackgroundModes"];
        if (! [backgroundModes containsObject:@"audio"]) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                           reason:@"You must enable the 'Audio, AirPlay, and Picture in Picture' flag of your target background modes (under the Capabilities tab) before attempting to use the Letterbox service"
                                         userInfo:nil];
        }
    });
    
    self.controller = controller;
    self.pictureInPictureDelegate = [AVPictureInPictureController isPictureInPictureSupported] ? pictureInPictureDelegate : nil;
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxServiceSettingsDidChangeNotification object:self];
}

- (void)disableForController:(SRGLetterboxController *)controller
{
    if (self.controller != controller) {
        return;
    }
    
    [self disable];
}

- (void)disable
{
    if (! self.controller && ! self.pictureInPictureDelegate) {
        return;
    }
    
    self.controller = nil;
    self.pictureInPictureDelegate = nil;
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGLetterboxServiceSettingsDidChangeNotification object:self];
}

#pragma mark Control center and lock screen integration

- (void)setupRemoteCommandCenter
{
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    
    MPRemoteCommand *playCommand = commandCenter.playCommand;
    playCommand.enabled = NO;
    [playCommand srg_addUniqueTarget:self action:@selector(play:)];
    
    MPRemoteCommand *pauseCommand = commandCenter.pauseCommand;
    pauseCommand.enabled = NO;
    [pauseCommand srg_addUniqueTarget:self action:@selector(pause:)];
    
    MPRemoteCommand *togglePlayPauseCommand = commandCenter.togglePlayPauseCommand;
    togglePlayPauseCommand.enabled = NO;
    [togglePlayPauseCommand srg_addUniqueTarget:self action:@selector(togglePlayPause:)];
    
    MPSkipIntervalCommand *skipForwardIntervalCommand = commandCenter.skipForwardCommand;
    skipForwardIntervalCommand.enabled = NO;
    skipForwardIntervalCommand.preferredIntervals = @[@(SRGLetterboxForwardSkipInterval)];
    [skipForwardIntervalCommand srg_addUniqueTarget:self action:@selector(skipForward:)];
    
    MPSkipIntervalCommand *skipBackwardIntervalCommand = commandCenter.skipBackwardCommand;
    skipBackwardIntervalCommand.enabled = NO;
    skipBackwardIntervalCommand.preferredIntervals = @[@(SRGLetterboxBackwardSkipInterval)];
    [skipBackwardIntervalCommand srg_addUniqueTarget:self action:@selector(skipBackward:)];
    
    MPRemoteCommand *seekForwardCommand = commandCenter.seekForwardCommand;
    seekForwardCommand.enabled = NO;
    [seekForwardCommand srg_addUniqueTarget:self action:@selector(seekForward:)];
    
    MPRemoteCommand *seekBackwardCommand = commandCenter.seekBackwardCommand;
    seekBackwardCommand.enabled = NO;
    [seekBackwardCommand srg_addUniqueTarget:self action:@selector(seekBackward:)];
    
    MPRemoteCommand *previousTrackCommand = commandCenter.previousTrackCommand;
    previousTrackCommand.enabled = NO;
    [previousTrackCommand srg_addUniqueTarget:self action:@selector(previousTrack:)];
    
    MPRemoteCommand *nextTrackCommand = commandCenter.nextTrackCommand;
    nextTrackCommand.enabled = NO;
    [nextTrackCommand srg_addUniqueTarget:self action:@selector(nextTrack:)];
    
    if (@available(iOS 9.1, *)) {
        MPRemoteCommand *changePlaybackPositionCommand = commandCenter.changePlaybackPositionCommand;
        changePlaybackPositionCommand.enabled = NO;
        [changePlaybackPositionCommand srg_addUniqueTarget:self action:@selector(changePlaybackPosition:)];
    }

    MPRemoteCommand *enableLanguageOptionCommand = commandCenter.enableLanguageOptionCommand;
    enableLanguageOptionCommand.enabled = NO;
    [enableLanguageOptionCommand srg_addUniqueTarget:self action:@selector(enableLanguageOption:)];
    
    MPRemoteCommand *disableLanguageOptionCommand = commandCenter.disableLanguageOptionCommand;
    disableLanguageOptionCommand.enabled = NO;
    [disableLanguageOptionCommand srg_addUniqueTarget:self action:@selector(disableLanguageOption:)];
}

- (void)resetRemoteCommandCenter
{
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    
    // For some unknown reason, at least an action (even dummy) must be bound to a command for `enabled` to have an effect,
    // see https://stackoverflow.com/questions/38993801/how-to-disable-all-the-mpremotecommand-objects-from-mpremotecommandcenter
    
    MPRemoteCommand *playCommand = commandCenter.playCommand;
    playCommand.enabled = NO;
    [playCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPRemoteCommand *pauseCommand = commandCenter.pauseCommand;
    pauseCommand.enabled = NO;
    [pauseCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPRemoteCommand *togglePlayPauseCommand = commandCenter.togglePlayPauseCommand;
    togglePlayPauseCommand.enabled = NO;
    [togglePlayPauseCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPSkipIntervalCommand *skipForwardIntervalCommand = commandCenter.skipForwardCommand;
    skipForwardIntervalCommand.enabled = NO;
    skipForwardIntervalCommand.preferredIntervals = @[];
    [skipForwardIntervalCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPSkipIntervalCommand *skipBackwardIntervalCommand = commandCenter.skipBackwardCommand;
    skipBackwardIntervalCommand.enabled = NO;
    skipBackwardIntervalCommand.preferredIntervals = @[];
    [skipBackwardIntervalCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPRemoteCommand *seekForwardCommand = commandCenter.seekForwardCommand;
    seekForwardCommand.enabled = NO;
    [seekForwardCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPRemoteCommand *seekBackwardCommand = commandCenter.seekBackwardCommand;
    seekBackwardCommand.enabled = NO;
    [seekBackwardCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPRemoteCommand *previousTrackCommand = commandCenter.previousTrackCommand;
    previousTrackCommand.enabled = NO;
    [previousTrackCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPRemoteCommand *nextTrackCommand = commandCenter.nextTrackCommand;
    nextTrackCommand.enabled = NO;
    [nextTrackCommand srg_addUniqueTarget:self action:@selector(doNothing:)];

    if (@available(iOS 9.1, *)) {
        MPRemoteCommand *changePlaybackPositionCommand = commandCenter.changePlaybackPositionCommand;
        changePlaybackPositionCommand.enabled = NO;
        [changePlaybackPositionCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    }

    MPRemoteCommand *enableLanguageOptionCommand = commandCenter.enableLanguageOptionCommand;
    enableLanguageOptionCommand.enabled = NO;
    [enableLanguageOptionCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
    
    MPRemoteCommand *disableLanguageOptionCommand = commandCenter.disableLanguageOptionCommand;
    disableLanguageOptionCommand.enabled = NO;
    [disableLanguageOptionCommand srg_addUniqueTarget:self action:@selector(doNothing:)];
}

- (void)updateRemoteCommandCenterWithController:(SRGLetterboxController *)controller
{
    if (! self.nowPlayingInfoAndCommandsEnabled) {
        return;
    }
    
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
    
    if (mediaPlayerController && mediaPlayerController.playbackState != SRGMediaPlayerPlaybackStateIdle && (mediaPlayerController.mediaType == SRGMediaTypeAudio
                                                                                                            || controller.backgroundVideoPlaybackEnabled
                                                                                                            || [UIApplication sharedApplication].applicationState != UIApplicationStateBackground
                                                                                                            || AVAudioSession.srg_isAirPlayActive
                                                                                                            || UIDevice.srg_letterbox_isLocked)) {
        commandCenter.playCommand.enabled = YES;
        commandCenter.pauseCommand.enabled = YES;
        commandCenter.togglePlayPauseCommand.enabled = YES;
        commandCenter.skipForwardCommand.enabled = (self.allowedCommands & SRGLetterboxCommandSkipForward) && [controller canSkipForward];
        commandCenter.skipBackwardCommand.enabled = (self.allowedCommands & SRGLetterboxCommandSkipBackward) && [controller canSkipBackward];
        commandCenter.seekForwardCommand.enabled = (self.allowedCommands & SRGLetterboxCommandSeekForward);
        commandCenter.seekBackwardCommand.enabled = (self.allowedCommands & SRGLetterboxCommandSeekBackward);
        commandCenter.nextTrackCommand.enabled = (self.allowedCommands & SRGLetterboxCommandNextTrack) && [controller canPlayNextMedia];
        commandCenter.previousTrackCommand.enabled = (self.allowedCommands & SRGLetterboxCommandPreviousTrack) && [controller canPlayPreviousMedia];
        
        if (@available(iOS 9.1, *)) {
            commandCenter.changePlaybackPositionCommand.enabled = (self.allowedCommands & SRGLetterboxCommandChangePlaybackPosition) && SRG_CMTIMERANGE_IS_NOT_EMPTY(controller.timeRange);
        }

        commandCenter.enableLanguageOptionCommand.enabled = (self.allowedCommands & SRGLetterboxCommandLanguageSelection);
        commandCenter.disableLanguageOptionCommand.enabled = (self.allowedCommands & SRGLetterboxCommandLanguageSelection);
    }
    else {
        commandCenter.playCommand.enabled = NO;
        commandCenter.pauseCommand.enabled = NO;
        commandCenter.togglePlayPauseCommand.enabled = NO;
        commandCenter.skipForwardCommand.enabled = NO;
        commandCenter.skipBackwardCommand.enabled = NO;
        commandCenter.seekForwardCommand.enabled = NO;
        commandCenter.seekBackwardCommand.enabled = NO;
        commandCenter.nextTrackCommand.enabled = NO;
        commandCenter.previousTrackCommand.enabled = NO;

        if (@available(iOS 9.1, *)) {
            commandCenter.changePlaybackPositionCommand.enabled = NO;
        }

        commandCenter.enableLanguageOptionCommand.enabled = NO;
        commandCenter.disableLanguageOptionCommand.enabled = NO;
    }
}

- (SRGMedia *)nowPlayingMediaForController:(SRGLetterboxController *)controller
{
    if (controller.media.mediaType == SRGMediaTypeVideo) {
        return controller.subdivisionMedia ?: controller.fullLengthMedia ?: controller.media;
    }
    else {
        return controller.media;
    }
}

- (void)updateNowPlayingInformationWithController:(SRGLetterboxController *)controller time:(NSValue *)time
{
    if (! self.nowPlayingInfoAndCommandsEnabled) {
        return;
    }
    
    SRGLetterboxLogDebug(@"service", @"Now playing info metadata update started");
    
    SRGMedia *media = [self nowPlayingMediaForController:controller];
    if (! media) {
        [self clearArtworkImageCache];
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
        return;
    }
    
    NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];
    
    switch (media.mediaType) {
        case SRGMediaTypeAudio: {
            nowPlayingInfo[MPMediaItemPropertyMediaType] = @(MPMediaTypeAnyAudio);
            break;
        }
            
        case SRGMediaTypeVideo: {
            nowPlayingInfo[MPMediaItemPropertyMediaType] = @(MPMediaTypeAnyVideo);
            break;
        }
            
        default: {
            nowPlayingInfo[MPMediaItemPropertyMediaType] = @(MPMediaTypeAny);
            break;
        }
    }
    
    // Display channel information when available for a livestream (testing channel information alone does not work since
    // such information can also be available for on-demand medias).
    SRGChannel *channel = controller.channel;
    if (media.contentType == SRGContentTypeLivestream && channel) {
        SRGProgram *program = controller.program;
        if (program) {
            NSString *title = program.title;
            nowPlayingInfo[MPMediaItemPropertyTitle] = title;
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = ! [channel.title isEqualToString:title] ? channel.title : @"";
        }
        else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = channel.title;
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = @"";
        }
    }
    else {
        nowPlayingInfo[MPMediaItemPropertyTitle] = media.title;
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = media.show.title;
    }
    
    nowPlayingInfo[MPMediaItemPropertyArtist] = @"";
    
    CGFloat artworkDimension = 256.f * UIScreen.mainScreen.scale;
    CGSize maximumSize = CGSizeMake(artworkDimension, artworkDimension);
    
    // TODO: Remove when iOS 10 is the minimum supported version
    if (@available(iOS 10, *)) {
        // Home artwork retrieval works (because poorly documented):
        // Images are retrieved when needed by the now playing info center by calling -[MPMediaItemArtwork imageWithSize:]`. Sizes
        // larger than the bounds size specified at creation will be fixed to the maximum compatible value. The request block itself
        // must be implemented to return an image of the size it receives as parameter, and is called on a background thread.
        //
        // Moreover, a subtle issue might arise if the controller is strongly captured by the block (successive now playing information
        // center updates might deadlock).
        nowPlayingInfo[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:maximumSize requestHandler:^UIImage * _Nonnull(CGSize size) {
            @weakify(self) @weakify(controller)
            return [self cachedArtworkImageForController:controller withSize:size completion:^{
                @strongify(self) @strongify(controller)
                [self updateNowPlayingInformationWithController:controller];
            }];
        }];
    }
    else {
        @weakify(self) @weakify(controller)
        UIImage *artworkImage = [self cachedArtworkImageForController:controller withSize:maximumSize completion:^{
            @strongify(self) @strongify(controller)
            [self updateNowPlayingInformationWithController:controller];
        }];
        nowPlayingInfo[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithImage:artworkImage];
    }
    
    SRGMediaPlayerController *mediaPlayerController = controller.mediaPlayerController;
    
    CMTimeRange timeRange = mediaPlayerController.timeRange;
    CMTime currentTime = time ? time.CMTimeValue : mediaPlayerController.currentTime;
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(CMTimeGetSeconds(CMTimeSubtract(currentTime, timeRange.start)));
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = @(CMTimeGetSeconds(timeRange.duration));
    
    // Provide rate information so that the information can be interpolated whithout the need for continuous updates
    SRGMediaPlayerPlaybackState playbackState = mediaPlayerController.playbackState;
    if (playbackState == SRGMediaPlayerPlaybackStatePlaying || playbackState == SRGMediaPlayerPlaybackStateSeeking) {
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = @(mediaPlayerController.player.rate);
    }
    else {
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = @0.;
    }
    
    // Available starting with iOS 10. When this property is set to YES the playback button is a play / stop button
    // on iOS 10, a play / pause button on iOS 11 and above, and LIVE is displayed instead of time progress.
    // TODO: Remove when the minimum required version is iOS 10
    if (@available(iOS 10, *)) {
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = @(mediaPlayerController.live);
    }
    
    // Audio tracks and subtitles
    NSMutableArray<MPNowPlayingInfoLanguageOptionGroup *> *languageOptionGroups = [NSMutableArray array];
    NSMutableArray<MPNowPlayingInfoLanguageOption *> *currentLanguageOptions = [NSMutableArray array];
    
    AVPlayerItem *playerItem = mediaPlayerController.player.currentItem;
    AVAsset *asset = playerItem.asset;
    if ([asset statusOfValueForKey:@keypath(asset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] == AVKeyValueStatusLoaded) {
        AVMediaSelectionGroup *audioGroup = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
        NSArray<AVMediaSelectionOption *> *audioOptions = audioGroup.options;
        if (audioOptions.count > 1) {
            [languageOptionGroups addObject:SRGLetterboxServiceLanguageOptionGroup(audioOptions, NO)];
            
            AVMediaSelectionOption *selectedAudibleOption = [playerItem selectedMediaOptionInMediaSelectionGroup:audioGroup];
            if (selectedAudibleOption) {
                [currentLanguageOptions addObject:[selectedAudibleOption makeNowPlayingInfoLanguageOption]];
            }
        }
        
        AVMediaSelectionGroup *subtitleGroup = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
        NSArray<AVMediaSelectionOption *> *subtitleOptions = [AVMediaSelectionGroup mediaSelectionOptionsFromArray:subtitleGroup.options withoutMediaCharacteristics:@[AVMediaCharacteristicContainsOnlyForcedSubtitles]];
        if (subtitleOptions.count > 0) {
            [languageOptionGroups addObject:SRGLetterboxServiceLanguageOptionGroup(subtitleOptions, YES)];
        }
        
        AVMediaSelectionOption *selectedLegibleOption = [playerItem selectedMediaOptionInMediaSelectionGroup:subtitleGroup];
        if (selectedLegibleOption) {
            [currentLanguageOptions addObject:[selectedLegibleOption makeNowPlayingInfoLanguageOption]];
        }
    }
    
    nowPlayingInfo[MPNowPlayingInfoPropertyAvailableLanguageOptions] = languageOptionGroups.copy;
    nowPlayingInfo[MPNowPlayingInfoPropertyCurrentLanguageOptions] = currentLanguageOptions.copy;
    
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nowPlayingInfo.copy;
}

- (void)updateNowPlayingInformationWithController:(SRGLetterboxController *)controller
{
    [self updateNowPlayingInformationWithController:controller time:nil];
}

- (NSURL *)artworkURLForController:(SRGLetterboxController *)controller withSize:(CGSize)size
{
    CGFloat smallestDimension = fmin(size.width, size.height);
    NSURL *artworkURL = nil;
    
    // Display channel information when available for a livestream (testing channel information alone does not work since
    // such information can also be available for on-demand medias).
    SRGChannel *channel = controller.channel;
    SRGMedia *media = [self nowPlayingMediaForController:controller];
    if (media.contentType == SRGContentTypeLivestream && channel) {
        SRGProgram *program = controller.program;
        if (program) {
            artworkURL = SRGLetterboxArtworkImageURL(program, smallestDimension);
            if (! artworkURL) {
                artworkURL = SRGLetterboxArtworkImageURL(channel, smallestDimension);
            }
        }
        else {
            artworkURL = SRGLetterboxArtworkImageURL(channel, smallestDimension);
        }
    }
    else {
        artworkURL = SRGLetterboxArtworkImageURL(media, smallestDimension);
    }
    
    if (! artworkURL) {
        artworkURL = [UIImage srg_URLForVectorImageAtPath:SRGLetterboxFilePathForImagePlaceholder(SRGLetterboxImagePlaceholderArtwork) withSize:size];
    }
    
    NSAssert(artworkURL != nil, @"An artwork URL must always be returned");
    return artworkURL;
}

// Return the best available image to display in the control center, performing an asynchronous update only when an image is not
// readily available from the cache
- (UIImage *)cachedArtworkImageForController:(SRGLetterboxController *)controller withSize:(CGSize)size completion:(void (^)(void))completion
{
    NSURL *artworkURL = [self artworkURLForController:controller withSize:size];
    if (! [artworkURL isEqual:self.cachedArtworkURL] || ! self.cachedArtworkImage) {
        // SRGLetterboxImageURL might return file URLs for overridden images
        if (artworkURL.fileURL) {
            UIImage *image = [UIImage imageWithContentsOfFile:artworkURL.path];
            self.cachedArtworkURL = artworkURL;
            self.cachedArtworkImage = image;
            return image;
        }
        else {
            NSURL *placeholderImageURL = [UIImage srg_URLForVectorImageAtPath:SRGLetterboxFilePathForImagePlaceholder(SRGLetterboxImagePlaceholderArtwork) withSize:size];
            UIImage *placeholderImage = [UIImage imageWithContentsOfFile:placeholderImageURL.path];
            
            SRGLetterboxLogDebug(@"service", @"Artwork image update triggered");
            
            // Request the image when not available. Calling -cachedArtworkImageForController:withSize: once the completion handler is called
            // will then return the image immediately
            self.imageOperation = [[YYWebImageManager sharedManager] requestImageWithURL:artworkURL options:0 progress:nil transform:nil completion:^(UIImage * _Nullable image, NSURL * _Nonnull url, YYWebImageFromType from, YYWebImageStage stage, NSError * _Nullable error) {
                if (image) {
                    self.cachedArtworkURL = artworkURL;
                    self.cachedArtworkImage = image;
                }
                else {
                    self.cachedArtworkURL = placeholderImageURL;
                    self.cachedArtworkImage = placeholderImage;
                }
                
                completion ? completion() : nil;
            }];
            
            // Keep the current artwork during retrieval (even if it does not match) for smoother transitions, or use
            // the placeholder when none
            return self.cachedArtworkImage ?: placeholderImage;
        }
    }
    else {
        return self.cachedArtworkImage;
    }
}

- (void)clearArtworkImageCache
{
    self.cachedArtworkURL = nil;
    self.cachedArtworkImage = nil;
}

#pragma mark Remote commands

- (MPRemoteCommandHandlerStatus)play:(MPRemoteCommandEvent *)event
{
    [self.controller.mediaPlayerController play];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)pause:(MPRemoteCommandEvent *)event
{
    [self.controller.mediaPlayerController pause];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)togglePlayPause:(MPRemoteCommandEvent *)event
{
    [self.controller.mediaPlayerController togglePlayPause];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)skipForward:(MPRemoteCommandEvent *)event
{
    return [self.controller skipForwardWithCompletionHandler:nil] ? MPRemoteCommandHandlerStatusSuccess : MPRemoteCommandHandlerStatusCommandFailed;
}

- (MPRemoteCommandHandlerStatus)skipBackward:(MPRemoteCommandEvent *)event
{
    return [self.controller skipBackwardWithCompletionHandler:nil] ? MPRemoteCommandHandlerStatusSuccess : MPRemoteCommandHandlerStatusCommandFailed;
}

- (MPRemoteCommandHandlerStatus)seekForward:(MPSeekCommandEvent *)event
{
    if (event.type == MPSeekCommandEventTypeBeginSeeking) {
        return [self.controller skipForwardWithCompletionHandler:nil] ? MPRemoteCommandHandlerStatusSuccess : MPRemoteCommandHandlerStatusCommandFailed;
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)seekBackward:(MPSeekCommandEvent *)event
{
    if (event.type == MPSeekCommandEventTypeBeginSeeking) {
        return [self.controller skipBackwardWithCompletionHandler:nil] ? MPRemoteCommandHandlerStatusSuccess : MPRemoteCommandHandlerStatusCommandFailed;
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)previousTrack:(MPRemoteCommandEvent *)event
{
    if ([self.controller playPreviousMedia]) {
        return MPRemoteCommandHandlerStatusSuccess;
    }
    else {
        if (@available(iOS 9.1, *)) {
            return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
        }
        else {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
    }
}

- (MPRemoteCommandHandlerStatus)nextTrack:(MPRemoteCommandEvent *)event
{
    if ([self.controller playNextMedia]) {
        return MPRemoteCommandHandlerStatusSuccess;
    }
    else {
        if (@available(iOS 9.1, *)) {
            return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
        }
        else {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
    }
}

- (MPRemoteCommandHandlerStatus)changePlaybackPosition:(MPChangePlaybackPositionCommandEvent *)event
{
    SRGPosition *position = [SRGPosition positionAroundTime:CMTimeMakeWithSeconds(event.positionTime, NSEC_PER_SEC)];
    [self.controller seekToPosition:position withCompletionHandler:^(BOOL finished) {
        // Resume playback when seeking from the control center. It namely does not make sense to seek blindly
        // without playback actually resuming if paused.
        if (finished) {
            [self.controller play];
        }
    }];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)enableLanguageOption:(MPChangeLanguageOptionCommandEvent *)event
{
    AVPlayerItem *playerItem = self.controller.mediaPlayerController.player.currentItem;
    AVAsset *asset = playerItem.asset;
    if ([asset statusOfValueForKey:@keypath(asset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] != AVKeyValueStatusLoaded) {
        if (@available(iOS 9.1, *)) {
            return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
        }
        else {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
    }
    
    BOOL (^selectLanguageOptionInGroup)(MPNowPlayingInfoLanguageOption *, AVMediaSelectionGroup *) = ^(MPNowPlayingInfoLanguageOption *languageOption, AVMediaSelectionGroup *group) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(AVMediaSelectionOption * _Nullable option, NSDictionary<NSString *,id> * _Nullable bindings) {
            return [option.extendedLanguageTag isEqualToString:languageOption.languageTag];
        }];
        AVMediaSelectionOption *option = [[AVMediaSelectionGroup mediaSelectionOptionsFromArray:group.options withMediaCharacteristics:languageOption.languageOptionCharacteristics] filteredArrayUsingPredicate:predicate].firstObject;
        if (! option) {
            return NO;
        }
        
        [playerItem selectMediaOption:option inMediaSelectionGroup:group];
        return YES;
    };
    
    MPNowPlayingInfoLanguageOption *languageOption = event.languageOption;
    if (languageOption.languageOptionType == MPNowPlayingInfoLanguageOptionTypeLegible) {
        AVMediaSelectionGroup *group = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
        if ([languageOption isAutomaticLegibleLanguageOption]) {
            [playerItem selectMediaOptionAutomaticallyInMediaSelectionGroup:group];
        }
        else if (! selectLanguageOptionInGroup(languageOption, group)) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
    }
    else {
        AVMediaSelectionGroup *group = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
        if ([languageOption isAutomaticAudibleLanguageOption]) {
            [playerItem selectMediaOptionAutomaticallyInMediaSelectionGroup:group];
        }
        else if (! selectLanguageOptionInGroup(languageOption, group)) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
    }
    
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)disableLanguageOption:(MPChangeLanguageOptionCommandEvent *)event
{
    AVPlayerItem *playerItem = self.controller.mediaPlayerController.player.currentItem;
    AVAsset *asset = playerItem.asset;
    if ([asset statusOfValueForKey:@keypath(asset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] != AVKeyValueStatusLoaded) {
        if (@available(iOS 9.1, *)) {
            return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
        }
        else {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
    }
    
    MPNowPlayingInfoLanguageOption *languageOption = event.languageOption;
    if (languageOption.languageOptionType == MPNowPlayingInfoLanguageOptionTypeLegible) {
        AVMediaSelectionGroup *subtitleGroup = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
        [playerItem selectMediaOption:nil inMediaSelectionGroup:subtitleGroup];
    }
    else {
        AVMediaSelectionGroup *audioGroup = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
        [playerItem selectMediaOption:nil inMediaSelectionGroup:audioGroup];
    }
    
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)doNothing:(MPRemoteCommandEvent *)event
{
    return MPRemoteCommandHandlerStatusSuccess;
}

#pragma mark Picture in picture

- (void)stopPictureInPictureRestoreUserInterface:(BOOL)restoreUserInterface
{
    AVPictureInPictureController *pictureInPictureController = self.controller.mediaPlayerController.pictureInPictureController;
    if (! pictureInPictureController.pictureInPictureActive) {
        return;
    }
    
    _restoreUserInterface = restoreUserInterface;
    [pictureInPictureController stopPictureInPicture];
}

#pragma mark AVPictureInPictureControllerDelegate protocol

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController
{
    BOOL dismissed = [self.pictureInPictureDelegate letterboxDismissUserInterfaceForPictureInPicture];
    _restoreUserInterface = _restoreUserInterface && dismissed;
    
    if ([self.pictureInPictureDelegate respondsToSelector:@selector(letterboxDidStartPictureInPicture)]) {
        [self.pictureInPictureDelegate letterboxDidStartPictureInPicture];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler
{
    // If the restoration method gets called, this means playback was not stopped from the picture in picture stop button
    _playbackStopped = NO;
    
    if (! _restoreUserInterface) {
        completionHandler(YES);
        return;
    }
    
    // It is very important that the completion handler is called at the very end of the process, otherwise silly
    // things might happen during the restoration (most notably player rate set to 0)
    
    // If stopping picture in picture because of a reset, don't restore anything
    if (self.controller.mediaPlayerController.playbackState == SRGMediaPlayerPlaybackStateIdle) {
        completionHandler(YES);
        return;
    }
    
    if ([self.pictureInPictureDelegate letterboxShouldRestoreUserInterfaceForPictureInPicture]) {
        [self.pictureInPictureDelegate letterboxRestoreUserInterfaceForPictureInPictureWithCompletionHandler:^(BOOL restored) {
            completionHandler(restored);
        }];
    }
    else {
        completionHandler(YES);
    }
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController
{
    if ([self.pictureInPictureDelegate respondsToSelector:@selector(letterboxDidEndPictureInPicture)]) {
        [self.pictureInPictureDelegate letterboxDidEndPictureInPicture];
    }
    
    if (_playbackStopped) {
        if ([self.pictureInPictureDelegate respondsToSelector:@selector(letterboxDidStopPlaybackFromPictureInPicture)]) {
            [self.pictureInPictureDelegate letterboxDidStopPlaybackFromPictureInPicture];
        }
    }
    
    // Reset to default values
    _playbackStopped = YES;
    _restoreUserInterface = YES;
}

#pragma mark Notifications

- (void)metadataDidChange:(NSNotification *)notification
{
    [self updateNowPlayingInformationWithController:self.controller];
}

- (void)playbackStateDidChange:(NSNotification *)notification
{
    [self updateNowPlayingInformationWithController:self.controller];
}

- (void)playerSeek:(NSNotification *)notification
{
    [self updateNowPlayingInformationWithController:self.controller time:notification.userInfo[SRGMediaPlayerSeekTimeKey]];
}

- (void)audioTrackDidChange:(NSNotification *)notification
{
    [self updateNowPlayingInformationWithController:self.controller];
}

- (void)subtitleTrackDidChange:(NSNotification *)notification
{
    [self updateNowPlayingInformationWithController:self.controller];
}

// Update commands while transitioning from / to the background (since control availability might be affected)
- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    [self updateRemoteCommandCenterWithController:self.controller];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self updateRemoteCommandCenterWithController:self.controller];
}

#pragma mark Description

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p; controller = %@; pictureInPictureDelegate = %@>",
            self.class,
            self,
            self.controller,
            self.pictureInPictureDelegate];
}

@end

#pragma mark Functions

// Cannot use `-makeNowPlayingInfoLanguageOptionGroup` for groups for which Off is not an option.
static MPNowPlayingInfoLanguageOptionGroup *SRGLetterboxServiceLanguageOptionGroup(NSArray<AVMediaSelectionOption *> *selectionOptions, BOOL allowEmptySelection)
{
    NSMutableArray<MPNowPlayingInfoLanguageOption *> *languageOptions = [NSMutableArray array];
    
    [selectionOptions enumerateObjectsUsingBlock:^(AVMediaSelectionOption * _Nonnull selectionOption, NSUInteger idx, BOOL * _Nonnull stop) {
        [languageOptions addObject:[selectionOption makeNowPlayingInfoLanguageOption]];
    }];
    
    return [[MPNowPlayingInfoLanguageOptionGroup alloc] initWithLanguageOptions:languageOptions.copy
                                                          defaultLanguageOption:nil
                                                            allowEmptySelection:allowEmptySelection];
}
