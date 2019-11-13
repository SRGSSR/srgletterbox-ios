//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxPlaybackSettings.h"

#import <SRGDataProvider/SRGDataProvider.h>
#import <SRGMediaPlayer/SRGMediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  Controller data availability.
 */
typedef NS_ENUM(NSInteger, SRGLetterboxDataAvailability) {
    /**
     *  No data is available.
     */
    SRGLetterboxDataAvailabilityNone,
    /**
     *  Data is being loaded.
     */
    SRGLetterboxDataAvailabilityLoading,
    /**
     *  Data has been loaded once.
     */
    SRGLetterboxDataAvailabilityLoaded
};

/**
 *  Types.
 */
typedef NSURL * _Nullable (^SRGLetterboxURLOverridingBlock)(NSString *URN);

/**
 *  Notification sent when the controller playback state changes. Use keys available for the equivalent notification defined
 *  in <SRGMediaPlayer/SRGMediaPlayerConstants.h> to retrieve information from the notification `userInfo` dictionary.
 */
OBJC_EXPORT NSString * const SRGLetterboxPlaybackStateDidChangeNotification;

/**
 *  Notifications sent when the current segment changes. Use keys available for the equivalent notifications defined
 *  in <SRGMediaPlayer/SRGMediaPlayerConstants.h> to retrieve information from the notification `userInfo` dictionary.
 */
OBJC_EXPORT NSString * const SRGLetterboxSegmentDidStartNotification;
OBJC_EXPORT NSString * const SRGLetterboxSegmentDidEndNotification;

/**
 *  Notification sent when playback metadata is updated (use the dictionary keys below to get previous and new values).
 *
 *  @discussion The data itself should in general change, but the notification might be posted even if no real change
 *              actually occurred. Nevertheless, your implementation should not be concerned about such details and
 *              still respond to change notifications accordingly (e.g. by updating user interface elements).
 */
OBJC_EXPORT NSString * const SRGLetterboxMetadataDidChangeNotification;

/**
 *  Current metadata.
 */
OBJC_EXPORT NSString * const SRGLetterboxURNKey;
OBJC_EXPORT NSString * const SRGLetterboxMediaKey;
OBJC_EXPORT NSString * const SRGLetterboxMediaCompositionKey;
OBJC_EXPORT NSString * const SRGLetterboxSubdivisionKey;
OBJC_EXPORT NSString * const SRGLetterboxChannelKey;
OBJC_EXPORT NSString * const SRGLetterboxProgramKey;

/**
 *  Previous metadata.
 */
OBJC_EXPORT NSString * const SRGLetterboxPreviousURNKey;
OBJC_EXPORT NSString * const SRGLetterboxPreviousMediaKey;
OBJC_EXPORT NSString * const SRGLetterboxPreviousMediaCompositionKey;
OBJC_EXPORT NSString * const SRGLetterboxPreviousSubdivisionKey;
OBJC_EXPORT NSString * const SRGLetterboxPreviousChannelKey;
OBJC_EXPORT NSString * const SRGLetterboxPreviousProgramKey;

/**
 *  Notification sent when an error has been encountered.
 */
OBJC_EXPORT NSString * const SRGLetterboxPlaybackDidFailNotification;

/**
 *  Error information.
 */
OBJC_EXPORT NSString * const SRGLetterboxErrorKey;

/**
 *  Notification sent when playback has been retried (might be automatic when network is reachable again).
 */
OBJC_EXPORT NSString * const SRGLetterboxPlaybackDidRetryNotification;

/**
 *  Notification sent when the controller plays the next media automatically. Use the `SRGLetterboxURNKey` and
 *  `SRGLetterboxMediaKey` keys to retrieve upcoming media information from the notification `userInfo` dictionary.
 */
OBJC_EXPORT NSString * const SRGLetterboxPlaybackDidContinueAutomaticallyNotification;

/**
 *  Standard time intervals for stream availability checks.
 */
static const NSTimeInterval SRGLetterboxDefaultUpdateInterval = 30.;
static const NSTimeInterval SRGLetterboxMinimumUpdateInterval = 10.;

/**
 *  Standard time intervals for checking channel metadata.
 */
static const NSTimeInterval SRGLetterboxChannelDefaultUpdateInterval = 30.;
static const NSTimeInterval SRGLetterboxChannelMinimumUpdateInterval = 10.;

/**
 *  Standard skip intervals.
 */
static const NSTimeInterval SRGLetterboxBackwardSkipInterval = 10.;
static const NSTimeInterval SRGLetterboxForwardSkipInterval = 30.;

/**
 *  Special interval used to disable continuous playback.
 */
static const NSTimeInterval SRGLetterboxContinuousPlaybackDisabled = DBL_MAX;

/**
 *  Forward declarations.
 */
@class SRGLetterboxController;

/**
 *  A playlist data source provides next and previous medias to be played by a controller.
 *
 *  @discussion Since a controller can play any content at any time, there is no way for a playlist implementation to
 *              guess where it must resume if the content appears more than once in the list. For this reason, playlist
 *              implementations should contain a given media at most once (otherwise the playlist behavior will likely be
 *              undefined).
 */
@protocol SRGLetterboxControllerPlaylistDataSource <NSObject>

/**
 *  The next media to be played for the specified controller.
 *
 *  @discussion This method can be called often. Implementations should be efficient enough so that no associated
 *              performance issues are experienced.
 */
- (nullable SRGMedia *)nextMediaForController:(SRGLetterboxController *)controller;

/**
 *  The previous media to be played for the specified controller.
 *
 *  @discussion Same as for `-nextMediaForController:`.
 */
- (nullable SRGMedia *)previousMediaForController:(SRGLetterboxController *)controller;

@optional

/**
 *  To enable continuous playback, implement this method and return a valid non-negative transition duration. Values
 *  lower than 0 will be fixed to 0. A duration of 0 enables immediate continuation.
 *
 *  You can return `SRGLetterboxContinuousPlaybackDisabled` to disable continuous playback, which is equivalent to not
 *  having this method implemented.
 */
- (NSTimeInterval)continuousPlaybackTransitionDurationForController:(SRGLetterboxController *)controller;

/**
 *  Called when the current media in the playlist changes, either automatically or as a result of explicitly moving
 *  to a next or previous item.
 */
- (void)controller:(SRGLetterboxController *)controller didTransitionToMedia:(SRGMedia *)media automatically:(BOOL)automatically;

/**
 *  An optional position at which playback must start for the specified media. If not implemented or if the method returns
 *  `nil`, playback starts at the default location. If a position near or past the end of the media to be played is
 *  provided (see `SRGLetterboxController` `endTolerance` and `endToleranceRatio` properties), the player will start at
 *  its default location as well.
 */
- (nullable SRGPosition *)controller:(SRGLetterboxController *)controller startPositionForMedia:(SRGMedia *)media;

/**
 *  Optional playback settings to be applied when playing the specified media. If not implemented or if the method returns
 *  `nil`, default settings are applied.
 */
- (nullable SRGLetterboxPlaybackSettings *)controller:(SRGLetterboxController *)controller preferredSettingsForMedia:(SRGMedia *)media;

@end

/**
 *  The Letterbox controller manages media playback, as well as retrieval and updates of the associated metadata. It
 *  also takes care of errors, in particular those related to network issues, and automatically resumes when a connection
 *  becomes available.
 *
 *  Applications can use a Letterbox controller to play some content in the background. If they need to display what
 *  is being played, a Letterbox controller needs to be bound to a Letterbox view (@see `SRGLetterboxView`). By integrating
 *  this view into their own hierarchy, and by listening to metadata and error controller notifications, applications can
 *  provide rich playback interfaces with contextual information about the content currently being played.
 *
 *  Letterbox controllers can also be integrated with application-wide features like AirPlay or picture in picture.
 *  Such features can only be enabled for at most one controller at a time by starting the Letterbox service singleton
 *  for this controller (@see `SRGLetterboxService`). Your application is free to use as many controllers as needed,
 *  though, and you can change at any time which controller is enabled for such services.
 *
 *  When the `SRGAnalytics` tracker singleton has been properly started, controllers are automatically tracked. This
 *  behavior can be disabled by setting the `tracked` property to `NO`. If the tracker singleton has not been started,
 *  analytics won't be collected.
 */
@interface SRGLetterboxController : NSObject

/**
 *  The URL of the service data must be returned from. By default or if reset to `nil`, the production server is
 *  used. Official URL values can be found in `SRGDataProvider.h`.
 *
 *  @discussion Changing the service URL while playing is possible, but the change is not guaranteed to be applied
 *              immediately, and playback might be interrupted if the new service is not available to provide data
 *              for the media being played. In general, and a different service URL is required, you should therefore
 *              set it before starting playback.
 */
@property (nonatomic, null_resettable) NSURL *serviceURL;

/**
 *  Prepare to play the specified URN (Uniform Resource Name) with the preferred (non-guaranteed) settings, and with
 *  the player paused (if playback is not started in the completion handler). If you want playback to start right after
 *  preparation, call `-play` from the completion handler.
 *
 *  @param URN               The URN to prepare.
 *  @param position          The position to start at. If `nil` or if the specified position lies outside the content
 *                           time range, playback starts at the default position.
 *  @param preferredSettings The settings which should ideally be applied. If `nil`, default settings are used.
 *  @param completionHandler The completion block to be called after the controller has finished preparing the media. This
 *                           block will only be called if the media could be successfully prepared.
 *
 *  @discussion Does nothing if the URN is the one currently being played. You might want to set the `resumesAfterRetry`
 *              property to `NO` when only preparing a player to play.
 */
- (void)prepareToPlayURN:(NSString *)URN
              atPosition:(nullable SRGPosition *)position
   withPreferredSettings:(nullable SRGLetterboxPlaybackSettings *)preferredSettings
       completionHandler:(nullable void (^)(void))completionHandler;

/**
 *  Same as `-prepareToPlayURN:atPosition:standalone:withPreferredSettings:completionHandler:`, but for a media.
 */
- (void)prepareToPlayMedia:(SRGMedia *)media
                atPosition:(nullable SRGPosition *)position
     withPreferredSettings:(nullable SRGLetterboxPlaybackSettings *)preferredSettings
         completionHandler:(nullable void (^)(void))completionHandler;

/**
 *  Ask the player to play.
 *
 *  @discussion Start playback if a media is available and the player is idle.
 */
- (void)play;

/**
 *  Ask the player to pause playback. Does nothing if the controller is not playing.
 *
 *  @discussion Livestreams cannot be paused and will be stopped instead.
 */
- (void)pause;

/**
 *  Ask the controller to change its status from pause to play or conversely, depending on the state it is in.
 *
 *  @discussion Start playback if a media is available and the player is idle. Livestreams cannot be paused and will be
 *              stopped instead.
 */
- (void)togglePlayPause;

/**
 *  Stop playback, keeping playback information.
 */
- (void)stop;

/**
 *  Restart playback completely for the same URN or media. Does nothing if no URN or media has currently been set.
 *
 *  @discussion Whether playback should automatically start when the player is restarted can be controlled using the
 *              `resumesAfterRetry` property.
 */
- (void)restart;

/**
 *  Reset playback and all playback information.
 */
- (void)reset;

/**
 *  Ask the controller to seek to a given location. A paused player remains paused, while a playing player remains
 *  playing. You can use the completion handler to change the player state if needed, e.g. to automatically
 *  resume playback after a seek has been performed on a paused player.
 *
 *  @param position          The position to start at. If `nil` or if the specified position lies outside the content
 *                           time range, playback starts at the default position.
 *  @param completionHandler The completion handler called when the seek ends. If the seek has been interrupted by
 *                           another seek, the completion handler will be called with `finished` set to `NO`, otherwise
 *                           with `finished` set to `YES`.
 *
 *  @discussion Upon completion handler entry, the playback state will be up-to-date if the seek finished, otherwise
 *              the player will still be in the seeking state. Note that if the media was not ready to play, seeking
 *              won't take place, and the completion handler won't be called.
 */
- (void)seekToPosition:(nullable SRGPosition *)position withCompletionHandler:(nullable void (^)(BOOL finished))completionHandler;

/**
 *  Switch to the specified URN, resuming playback if necessary. The URN must be related to the current playback context
 *  (i.e. it must be the URN of one of the related chapters or segments), otherwise no switching will occur. Switching
 *  to the currently playing URN restarts playback at its beginning.
 *
 *  @param completionHandler The completion handler called once switching finishes. The block will only be called when
 *                           switching is performed, and with `finished` set to `YES` iff playback could successfully
 *                           resume afterwards.
 *
 *  @return `YES` iff switching occurred successfully.
 */
- (BOOL)switchToURN:(NSString *)URN withCompletionHandler:(nullable void (^)(BOOL finished))completionHandler;

/**
 *  Switch to the specified subdivision, resuming playback if necessary. The subdivision must be related to the
 *  current playback context (i.e. it must be one of its related chapters or segments), otherwise no switching will occur.
 *  Switching to the currently playing subdivision restarts playback at its beginning.
 *
 *  @param completionHandler The completion handler called once switching finishes. The block will only be called when
 *                           switching is performed, and with `finished` set to `YES` iff playback could successfully
 *                           resume afterwards.
 *
 *  @return `YES` iff switching occurred successfully.
 */
- (BOOL)switchToSubdivision:(SRGSubdivision *)subdivision withCompletionHandler:(nullable void (^)(BOOL finished))completionHandler;

/**
 *  Return the current data availability. KVO-observable.
 *
 *  @discussion The availability is reset to `SRGLetterboxDataAvailabilityNone` when calling a prepare / play methods
 *              to play new content.
 */
@property (nonatomic, readonly) SRGLetterboxDataAvailability dataAvailability;

/**
 *  Return `YES` iff the controller is loading data (either retrieving metadata or buffering).
 *
 *  KVO-observable.
 */
@property (nonatomic, readonly, getter=isLoading) BOOL loading;

/**
 *  Set to `YES` to mute the player. Default is `NO`.
 */
@property (nonatomic, getter=isMuted) BOOL muted;

/**
 *  Set to `YES` to enable background video playback if possible (not supported for 360° or when AirPlay or Picture in
 *  picture are active). Default is `NO`.
 */
@property (nonatomic, getter=isBackgroundVideoPlaybackEnabled) BOOL backgroundVideoPlaybackEnabled;

/**
 *  Set to `YES` so that a retry automatically resumes playback (e.g. after a network loss, when the start time of
 *  a previously not available media has been reached, or when the content URL has changed). Default is `YES`. If
 *  set to `NO`, playback will only be prepared, but playback will not actually start.
 */
@property (nonatomic) BOOL resumesAfterRetry;

/**
 *  Set to `YES` to automatically resume playback after the current route becomes unavailalbe (e.g. a wired headset is
 *  unplugged or a Bluetooth headset is switched off abruptly). Default is `NO`.
 */
@property (nonatomic) BOOL resumesAfterRouteBecomesUnavailable;

@end

@interface SRGLetterboxController (Playback)

/**
 *  The current letterbox controller playback state.
 *
 *  @discussion This property is key-value observable.
 */
@property (nonatomic, readonly) SRGMediaPlayerPlaybackState playbackState;

/**
 *  For DVR and live streams, returns the date corresponding to the current playback time. If the date cannot be
 *  determined or for on-demand streams, the method returns `nil`.
 */
@property (nonatomic, readonly, nullable) NSDate *date;

/**
 *  Return `YES` iff the stream is currently played in live conditions (always `YES` for live streams, `YES` within the
 *  last 30 seconds of a DVR stream).
 */
@property (nonatomic, readonly, getter=isLive) BOOL live;

/**
 *  The current player time.
 */
@property (nonatomic, readonly) CMTime currentTime;

/**
 *  The current media time range (might be empty or indefinite).
 *
 *  @discussion Use `CMTimeRange` macros for checking time ranges.
 */
@property (nonatomic, readonly) CMTimeRange timeRange;

/**
 *  Register a block for periodic execution when the controller is not in the idle state.
 *
 *  @param interval Time interval between block executions.
 *  @param queue    The serial queue onto which block should be enqueued (main queue if `NULL`).
 *  @param block	The block to be periodically executed.
 *
 *  @return The time observer. The observer is retained by the controller, you can store a weak reference to it and
 *          remove it at a later time if needed.
 */
- (id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(nullable dispatch_queue_t)queue usingBlock:(void (^)(CMTime time))block;

/**
 *  Remove a time observer (does nothing if the observer is not registered).
 */
- (void)removePeriodicTimeObserver:(nullable id)observer;

@end

/**
 *  Media configuration.
 */
@interface SRGLetterboxController (MediaConfiguration)

/**
 *  Optional block which gets called once media information has been loaded, and which can be used to customize
 *  audio or subtitle selection, as well as subtitle appearance.
 */
@property (nonatomic, copy, nullable) void (^mediaConfigurationBlock)(AVPlayerItem *playerItem, AVAsset *asset);

/**
 *  Reload media configuration by calling the associated block, if any. Does nothing if the media has not been loaded
 *  yet. If there is no configuration block defined, calling this method applies the default selection options for
 *  audio and subtitles, and removes any subtitle styling which might have been applied.
 */
- (void)reloadMediaConfiguration;

/**
 *  Reload the player configuration with a new configuration block. Any previously existing configuration block is
 *  replaced.
 *
 *  @discussion If the media has not been loaded yet, the block is set but not called.
 */
- (void)reloadMediaConfigurationWithBlock:(nullable void (^)(AVPlayerItem *playerItem, AVAsset *asset))block;

@end

/**
 *  Playlist support. To use playlists, assign a data source which will supply previous and next medias to be played.
 *
 *  @discussion Playlist navigation is not available when picture in picture is active.
 */
@interface SRGLetterboxController (Playlists)

/**
 *  Return `YES` iff the next media can be played (or prepared to be played).
 */
- (BOOL)canPlayNextMedia;

/**
 *  Return `YES` iff the next media can be played (or prepared to be played).
 */
- (BOOL)canPlayPreviousMedia;

/**
 *  The playlist data source.
 */
@property (nonatomic, weak, nullable) id<SRGLetterboxControllerPlaylistDataSource> playlistDataSource;

/**
 *  Prepare to play the next media in the playlist. If you want playback to start right after preparation, call `-play`
 *  from the completion handler.
 *
 *  @param completionHandler The completion block to be called after the controller has finished preparing the media. This
 *                           block will only be called if the media could successfully be prepared.
 *
 *  @return `YES` iff successful. Note that the method returns `NO` when picture in picture is active.
 */
- (BOOL)prepareToPlayNextMediaWithCompletionHandler:(nullable void (^)(void))completionHandler;

/**
 *  Same as `-prepareToPlayNextMediaWithCompletionHandler:`, but with the previous madia in the playlist.
 */
- (BOOL)prepareToPlayPreviousMediaWithCompletionHandler:(nullable void (^)(void))completionHandler;

/**
 *  Play the next media currently available from the playlist.
 *
 *  @return `YES` iff successful. Note that the method returns `NO` when picture in picture is active.
 */
- (BOOL)playNextMedia;

/**
 *  Same as `-playNextMedia`, but with the previous media in the playlist.
 */
- (BOOL)playPreviousMedia;

/**
 *  The next media currently available from the playlist.
 */
@property (nonatomic, readonly, nullable) SRGMedia *nextMedia;

/**
 *  The previous media currently available from the playlist.
 */
@property (nonatomic, readonly, nullable) SRGMedia *previousMedia;

@end

/**
 *  Continuous playback support, i.e. automatically playing the next media in a playlist when a media playback ends.
 *  Requires a playlist data source supplying next item information.
 *
 *  Remark: Continuous playback is not active when picture in picture is active.
 */
@interface SRGLetterboxController (ContinuousPlayback)

/**
 *  The date at which the continuous playback transition to the next media started. KVO-observable.
 *
 *  @discussion Returns `nil` if there is no active transition.
 */
@property (nonatomic, readonly, nullable) NSDate *continuousPlaybackTransitionStartDate;

/**
 *  The date at which continuous playback will automatically resume with the next media. KVO-observable.
 *
 *  @discussion Returns `nil` if there no active transition. Stays constant during the transition, even if
 *              continuous playback settings change.
 */
@property (nonatomic, readonly, nullable) NSDate *continuousPlaybackTransitionEndDate;

/**
 *  The upcoming media while undergoing a continuous playback transition. KVO-observable.
 *
 *  @discussion Returns `nil` if there no active transition. Stays constant during the transition, even if
 *              the playlist changes.
 */
@property (nonatomic, readonly, nullable) SRGMedia *continuousPlaybackUpcomingMedia;

/**
 *  Within a continuous playback transition, call this method to cancel automatic playback of the next item.
 *
 *  @dicussion This method has no effect outside a transition.
 */
- (void)cancelContinuousPlayback;

@end

/**
 *  Convenience methods.
 */
@interface SRGLetterboxController (Convenience)

/**
 *  Play the specified URN (Uniform Resource Name).
 *
 *  For more information, @see `-prepareToPlayURN:atPosition:withPreferredSettings:completionHandler:`.
 *
 *  @discussion Does nothing if the media is the one currently being played.
 */
- (void)playURN:(NSString *)URN atPosition:(nullable SRGPosition *)position withPreferredSettings:(nullable SRGLetterboxPlaybackSettings *)preferredSettings;

/**
 *  Play the specified media.
 *
 *  For more information, @see `-prepareToPlayMedia:atPosition:withPreferredSettings:completionHandler:`.
 *
 *  @discussion Does nothing if the media is the one currently being played.
 */
- (void)playMedia:(SRGMedia *)media atPosition:(nullable SRGPosition *)position withPreferredSettings:(nullable SRGLetterboxPlaybackSettings *)preferredSettings;

@end

/**
 *  Standard skips.
 */
@interface SRGLetterboxController (Skips)

/**
 *  Return `YES` iff the player can skip backward from `SRGLetterboxBackwardSkipInterval` seconds.
 */
- (BOOL)canSkipBackward;

/**
 *  Return `YES` iff the player can skip forward from `SRGLetterboxForwardSkipInterval` seconds.
 */
- (BOOL)canSkipForward;

/**
 *  Return `YES` iff the player can skip to live conditions.
 *
 *  @discussion Always returns `NO` for on-demand streams.
 */
- (BOOL)canSkipToLive;

/**
 *  Skip backward from a `SRGLetterboxBackwardSkipInterval` seconds.
 *
 *  @param completionHandler The completion handler called once skipping finishes. The block will only be called when
 *                           skipping is possible, and with `finished` set to `YES` iff skipping was not interrupted.
 *
 *  @return `YES` iff skipping is possible.
 */
- (BOOL)skipBackwardWithCompletionHandler:(nullable void (^)(BOOL finished))completionHandler;

/**
 *  Skip forward from a `SRGLetterboxForwardSkipInterval` seconds.
 *
 *  @param completionHandler The completion handler called once skipping finishes. The block will only be called when
 *                           skipping is possible, and with `finished` set to `YES` iff skipping was not interrupted.
 *
 *  @return `YES` iff skipping is possible.
 */
- (BOOL)skipForwardWithCompletionHandler:(nullable void (^)(BOOL finished))completionHandler;

/**
 *  Skip forward to live conditions.
 *
 *  @param completionHandler The completion handler called once skipping finishes. The block will only be called when
 *                           skipping is possible, and with `finished` set to `YES` iff skipping was not interrupted.
 *
 *  @return `YES` iff skipping is possible. Always returns `NO` for on-demand streams.
 */
- (BOOL)skipToLiveWithCompletionHandler:(nullable void (^)(BOOL finished))completionHandler;

@end

/**
 *  Playback information. Changes are notified through `SRGLetterboxMetadataDidChangeNotification` and
 *  `SRGLetterboxPlaybackDidFailNotification`.
 */
@interface SRGLetterboxController (Metadata)

/**
 *  Unified Resource Name of the media being played.
 */
@property (nonatomic, readonly, nullable, copy) NSString *URN;

/**
 *  Media information.
 */
@property (nonatomic, readonly, nullable) SRGMedia *media;

/**
 *  Media composition (playback context).
 */
@property (nonatomic, readonly, nullable) SRGMediaComposition *mediaComposition;

/**
 *  Channel information (contains information about current and next programs).
 */
@property (nonatomic, readonly, nullable) SRGChannel *channel;

/**
 *  The program corresponding to the current playback position, if any.
 */
@property (nonatomic, readonly, nullable) SRGProgram *program;

/**
 *  The current subdivision being played.
 */
@property (nonatomic, readonly, nullable) SRGSubdivision *subdivision;

/**
 *  The current subdivision (segment or chapter) being played, as an `SRGMedia` object.
 */
@property (nonatomic, readonly, nullable) SRGMedia *subdivisionMedia;

/**
 *  The current full-length information.
 */
@property (nonatomic, readonly, nullable) SRGMedia *fullLengthMedia;

/**
 *  The resource which is being played.
 */
@property (nonatomic, readonly, nullable) SRGResource *resource;

/**
 *  Error (if any has been encountered).
 */
@property (nonatomic, readonly, nullable) NSError *error;

@end

/**
 *  Tolerance settings applied at playback start.
 *
 *  @discussion If needed, the effective tolerance resulting from these settings can be calculated with the help of the
 *              `SRGMediaPlayerEffectiveEndTolerance` function.
 */
@interface SRGLetterboxController (EndToleranceSettings)

/**
 *  The absolute tolerance (in seconds) applied when attempting to start playback near the end of a media. Default is 0
 *  seconds.
 *
 *  @discussion If the distance between the desired playback position and the end is smaller than the maximum tolerated
 *              value according to `endTolerance` and / or `endToleranceRatio` (the smallest value wins), playback will
 *              start at the default position.
 */
@property (nonatomic) NSTimeInterval endTolerance;

/**
 *  The tolerance ratio applied when attempting to start playback near the end of a media. The ratio is multiplied with
 *  the media duration to calculate the tolerance in seconds. Default is 0.
 *
 *  @discussion If the distance between the desired playback position and the end is smaller than the maximum tolerated
 *              value according to `endTolerance` and / or `endToleranceRatio` (the smallest value wins), playback will
 *              start at the default position.
 */
@property (nonatomic) float endToleranceRatio;

@end

/**
 *  Settings for the server from which metadata is retrieved.
 */
@interface SRGLetterboxController (ServerSettings)

/**
 *  The URL of the service data must be returned from. By default or if reset to `nil`, the production server is
 *  used. Official URL values can be found in `SRGDataProvider.h`.
 */
@property (nonatomic, null_resettable) NSURL *serviceURL;

/**
 *  Optional global headers which will be added to all requests performed by the controller. Use with caution, as some
 *  headers might not be supported and could lead to request failure.
 */
@property (nonatomic, nullable) NSDictionary<NSString *, NSString *> *globalHeaders;

/**
 *  Optional global parameters which will be added to all requests performed by the controller. Use with caution, as
 *  some parameters might not be supported and could lead to request failure.
 */
@property (nonatomic, nullable) NSDictionary<NSString *, NSString *> *globalParameters;

@end

/**
 *  Services information. Use `SRGLetterboxService` to start application-wide services for a Letterbox controller.
 */
@interface SRGLetterboxController (Services)

/**
 *  Return `YES` iff the receiver is enabled for background services.
 */
@property (nonatomic, readonly, getter=areBackgroundServicesEnabled) BOOL backgroundServicesEnabled API_UNAVAILABLE(tvos);

/**
 *  Return `YES` iff the receiver is enabled for picture in picture.
 */
@property (nonatomic, readonly, getter=isPictureInPictureEnabled) BOOL pictureInPictureEnabled API_UNAVAILABLE(tvos);

/**
 *  Return `YES` iff picture in picture is currently active for the receiver.
 */
@property (nonatomic, readonly, getter=isPictureInPictureActive) BOOL pictureInPictureActive API_UNAVAILABLE(tvos);

@end

/**
 *  Settings for SRGAnalytics integration.
 */
@interface SRGLetterboxController (Analytics)

/**
 *  Streaming analytics are automatically gathered when this property is set to `YES` (default).
 */
@property (nonatomic, getter=isTracked) BOOL tracked;

@end

/**
 *  Settings for periodic updates.
 */
@interface SRGLetterboxController (PeriodicUpdates)

/**
 *  Time interval for controller automatic updates.
 *
 *  Default is `SRGLetterboxDefaultUpdateInterval`, and minimum is `SRGLetterboxMinimumUpdateInterval`.
 */
@property (nonatomic) NSTimeInterval updateInterval;

/**
 *  Time interval between channel information updates, notified by a `SRGLetterboxMetadataDidChangeNotification`
 *  notification.
 *
 *  Default is `SRGLetterboxChannelDefaultUpdateInterval`, and minimum is `SRGLetterboxChannelMinimumUpdateInterval`.
 */
@property (nonatomic) NSTimeInterval channelUpdateInterval;

@end

/**
 *  Overriding abilities. Player functionalities might be limited when overriding has been made.
 */
@interface SRGLetterboxController (Overriding)

/**
 *  Provides a way to override the content URL which has been retrieved for a media. This is for example useful
 *  to replace the original URL with a local file URL. Content overriding takes place when a play request is
 *  initiated, content overriding must be setup before such requests are made, otherwise it won't take place.
 *
 *  @discussion When a URL has been overridden, the player will only work with the media, not the full playback
 *              context (since the context is tightly related to the original content URL, this would open the
 *              door to several inconsistencies, most notably with segments).
 *
 *              The overridden URL should be of the same type as the original one (e.g. a livestream URL should
 *              only be overridden with another livestream URL), otherwise the behhavior is undefined.
 */
@property (nonatomic, copy, nullable) SRGLetterboxURLOverridingBlock contentURLOverridingBlock;

/**
 *  Return `YES` iff the URL played by the controller is overridden.
 *
 *  @discussion If no media URN is attached to the controller, the property returns `NO`.
 */
@property (nonatomic, readonly, getter=isContentURLOverridden) BOOL contentURLOverridden;

@end

NS_ASSUME_NONNULL_END
