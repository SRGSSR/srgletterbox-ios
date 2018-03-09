//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGLetterboxBaseView.h"

#import "NSBundle+SRGLetterbox.h"

#import <Masonry/Masonry.h>

static void commonInit(SRGLetterboxBaseView *self);

@implementation SRGLetterboxBaseView

#pragma mark Object lifecycle

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        commonInit(self);
        
        // The top-level view loaded from the xib file and initialized in `commonInit` is NOT an `SRGLetterboxBaseView`. Manually
        // calling `-awakeFromNib` forces the final view initialization (also see comments in `commonInit`).
        [self awakeFromNib];
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

#pragma mark Getters and setters

- (SRGLetterboxView *)contextView
{
    // Start with self. The context can namely be the receiver itself
    UIView *contextView = self;
    while (contextView) {
        if ([contextView isKindOfClass:[SRGLetterboxView class]]) {
            return (SRGLetterboxView *)contextView;
        }
        contextView = contextView.superview;
    }
    return nil;
}

#pragma mark Overrides

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];
    
    if (newWindow) {
        [self contentSizeCategoryDidChange];
        [self voiceOverStatusDidChange];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(contentSizeCategoryDidChange:)
                                                     name:UIContentSizeCategoryDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(accessibilityVoiceOverStatusChanged:)
                                                     name:UIAccessibilityVoiceOverStatusChanged
                                                   object:nil];
    }
    else {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:UIContentSizeCategoryDidChangeNotification
                                                      object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:UIAccessibilityVoiceOverStatusChanged
                                                      object:nil];
    }
}

#pragma mark Subclassing hooks

- (void)contentSizeCategoryDidChange
{}

- (void)voiceOverStatusDidChange
{}

#pragma mark Notifications

- (void)contentSizeCategoryDidChange:(NSNotification *)notification
{
    [self contentSizeCategoryDidChange];
}

- (void)accessibilityVoiceOverStatusChanged:(NSNotification *)notification
{
    [self voiceOverStatusDidChange];
}

@end

static void commonInit(SRGLetterboxBaseView *self)
{
    NSString *nibName = NSStringFromClass([self class]);
    if ([[NSBundle srg_letterboxBundle] pathForResource:nibName ofType:@"nib"]) {
        // This makes design in a xib and Interface Builder preview (IB_DESIGNABLE) work. The top-level view must NOT be
        // an `SRGLetterboxBaseView` to avoid infinite recursion
        UIView *view = [[[NSBundle srg_letterboxBundle] loadNibNamed:nibName owner:self options:nil] firstObject];
        view.backgroundColor = [UIColor clearColor];
        [self addSubview:view];
        [view mas_makeConstraints:^(MASConstraintMaker *make) {
            make.edges.equalTo(self);
        }];
    }
}
