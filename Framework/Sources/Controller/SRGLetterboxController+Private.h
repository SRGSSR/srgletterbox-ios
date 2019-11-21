//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxController.h"

#import <SRGMediaPlayer/SRGMediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  Notification sent when the livestream associated with the current playback context just finished. The corresponding
 *  media can be retrieved under the `SRGLetterboxMediaKey` user information key.
 */
OBJC_EXPORT NSString * const SRGLetterboxLivestreamDidFinishNotification;

/**
 *  Notification sent when a request to the social count view service will be fired. The corresponding media subdivision
 *  can be retrieved under the `SRGLetterboxSubdivisionKey` user information key.
 */
OBJC_EXPORT NSString * const SRGLetterboxSocialCountViewWillIncreaseNotification;

/**
 *  Interface for internal use.
 */
@interface SRGLetterboxController (Private)

/**
 *  The media player controller managing playback.
 *
 *  @discussion Do not alter properties of this player controller, this could lead to undefined behavior. Only use
 *              in a readonly way or to register observers.
 */
@property (nonatomic, readonly) SRGMediaPlayerController *mediaPlayerController;

/**
 *  Optional block which gets called right after player creation, when the player changes, or when the configuration is
 *  reloaded by calling `-reloadPlayerConfiguration`. Does not get called when the player is set to `nil`.
 *
 *  @discussion The player starts with external playback disabled and default audio session settings for the media
 *              being played. The configuration block might be used to override these default values.
 */
@property (nonatomic, copy, nullable) void (^playerConfigurationBlock)(AVPlayer *player);

/**
 *  Returns `YES` iff the controller is currently used for external AirPlay playback.
 */
@property (nonatomic, readonly, getter=isUsingAirPlay) BOOL usingAirPlay;

/**
 *  The program corresponding to the current playback position, if any.
 */
@property (nonatomic, readonly, nullable) SRGProgram *program;

/**
 *  Play the upcoming media currently available.
 *
 *  @return `YES` iff successful.
 */
- (BOOL)playUpcomingMedia;

/**
 *  Ask the player to reload its configuration by calling the associated configuration block, if any. Does nothing if
 *  the player has not been created yet.
 */
- (void)reloadPlayerConfiguration;

/**
 *  If set to `YES`, DRM streams must be favored over non-DRM ones when both are available, otherwise the original
 *  resource order is used when looking for the best match.
 */
// FIXME: This hook is temporary until 2019 and must only be used by Play SRG applications. It will be removed
//        afterwards.
@property (class, nonatomic) BOOL prefersDRM;

@end

NS_ASSUME_NONNULL_END
