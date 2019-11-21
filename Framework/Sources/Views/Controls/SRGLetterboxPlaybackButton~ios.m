//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxPlaybackButton.h"

#import "NSBundle+SRGLetterbox.h"
#import "SRGLetterboxController+Private.h"
#import "UIImage+SRGLetterbox.h"

#import <libextobjc/libextobjc.h>

static void commonInit(SRGLetterboxPlaybackButton *self);

@implementation SRGLetterboxPlaybackButton

@synthesize imageSet = _imageSet;

#pragma mark Object lifecycle

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        commonInit(self);
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    if (self = [super initWithCoder:aDecoder]) {
        commonInit(self);
    }
    return self;
}

#pragma mark Getters and setters

- (void)setController:(SRGLetterboxController *)controller
{
    if (_controller) {
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:SRGLetterboxPlaybackStateDidChangeNotification
                                                    object:_controller];
    }
    
    _controller = controller;
    [self refresh];
    
    if (controller) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(playbackStateDidChange:)
                                                   name:SRGLetterboxPlaybackStateDidChangeNotification
                                                 object:controller];
    }
}

- (void)setImageSet:(SRGImageSet)imageSet
{
    _imageSet = imageSet;
    [self refresh];
}

#pragma mark Overrides

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];
    
    if (newWindow) {
        [self refresh];
    }
}

#pragma mark UI

- (void)refresh
{
    // Keep the most recent state when seeking
    if (self.controller.playbackState != SRGMediaPlayerPlaybackStateSeeking) {
        UIImage *buttonImage = nil;
        NSString *accessibilityLabel = nil;
        
        if (self.controller.playbackState == SRGMediaPlayerPlaybackStatePlaying || self.controller.playbackState == SRGMediaPlayerPlaybackStateStalled) {
            BOOL isLiveOnly = (self.controller.mediaPlayerController.streamType == SRGMediaPlayerStreamTypeLive);
            buttonImage = isLiveOnly ? [UIImage srg_letterboxStopImageInSet:self.imageSet] : [UIImage srg_letterboxPauseImageInSet:self.imageSet];
            accessibilityLabel = isLiveOnly ? SRGLetterboxAccessibilityLocalizedString(@"Stop", @"Stop button label") : SRGLetterboxAccessibilityLocalizedString(@"Pause", @"Pause button label");
        }
        else {
            buttonImage = [UIImage srg_letterboxPlayImageInSet:self.imageSet];
            accessibilityLabel = SRGLetterboxAccessibilityLocalizedString(@"Play", @"Play button label");
        }
        
        [self setImage:buttonImage forState:UIControlStateNormal];
        self.accessibilityLabel = accessibilityLabel;
    }
}

#pragma mark Actions

- (void)togglePlayPause:(id)sender
{
    [self.controller togglePlayPause];
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement
{
    return (self.alpha != 0);
}

#pragma mark Notifications

- (void)playbackStateDidChange:(NSNotification *)notification
{
    [self refresh];
}

@end

#pragma mark Functions

static void commonInit(SRGLetterboxPlaybackButton *self)
{
    self.imageSet = SRGImageSetNormal;
    
    [self addTarget:self action:@selector(togglePlayPause:) forControlEvents:UIControlEventTouchUpInside];
}
