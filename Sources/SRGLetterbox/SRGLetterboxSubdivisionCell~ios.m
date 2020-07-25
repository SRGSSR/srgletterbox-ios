//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import <TargetConditionals.h>

#if TARGET_OS_IOS

#import "SRGLetterboxSubdivisionCell.h"

#import "NSBundle+SRGLetterbox.h"
#import "NSDateComponentsFormatter+SRGLetterbox.h"
#import "NSDateFormatter+SRGLetterbox.h"
#import "NSLayoutConstraint+SRGLetterboxPrivate.h"
#import "SRGPaddedLabel.h"
#import "UIColor+SRGLetterbox.h"
#import "UIFont+SRGLetterbox.h"
#import "UIImage+SRGLetterbox.h"
#import "UIImageView+SRGLetterbox.h"

@import SRGAppearance;

@interface SRGLetterboxSubdivisionCell ()

@property (nonatomic, weak) UIView *wrapperView;

@property (nonatomic, weak) UIImageView *imageView;
@property (nonatomic, weak) UIProgressView *progressView;
@property (nonatomic, weak) UILabel *titleLabel;
@property (nonatomic, weak) SRGPaddedLabel *durationLabel;
@property (nonatomic, weak) UIImageView *media360ImageView;

@property (nonatomic, weak) UIView *blockingOverlayView;
@property (nonatomic, weak) UIImageView *blockingReasonImageView;

@property (nonatomic, weak) UILongPressGestureRecognizer *longPressGestureRecognizer;

@end

@implementation SRGLetterboxSubdivisionCell

#pragma mark Object lifecycle

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        [self createView];
    }
    return self;
}

#pragma mark Layout

- (void)createView
{
    UILongPressGestureRecognizer *longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                                             action:@selector(longPress:)];
    longPressGestureRecognizer.minimumPressDuration = 1.;
    [self addGestureRecognizer:longPressGestureRecognizer];
    self.longPressGestureRecognizer = longPressGestureRecognizer;
    
    UIView *wrapperView = [[UIView alloc] init];
    wrapperView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:wrapperView];
    self.wrapperView = wrapperView;
    
    [NSLayoutConstraint activateConstraints:@[
        [wrapperView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [wrapperView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [wrapperView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [wrapperView.widthAnchor constraintEqualToAnchor:wrapperView.heightAnchor multiplier:16.f / 9.f]
    ]];
    
    UIImageView *imageView = [[UIImageView alloc] init];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapperView addSubview:imageView];
    self.imageView = imageView;
    
    [NSLayoutConstraint activateConstraints:@[
        [imageView.leadingAnchor constraintEqualToAnchor:wrapperView.leadingAnchor],
        [imageView.trailingAnchor constraintEqualToAnchor:wrapperView.trailingAnchor],
        [imageView.topAnchor constraintEqualToAnchor:wrapperView.topAnchor],
        [imageView.bottomAnchor constraintEqualToAnchor:wrapperView.bottomAnchor],
    ]];
    
    UIView *blockingOverlayView = [[UIView alloc] init];
    blockingOverlayView.backgroundColor = [UIColor colorWithWhite:0.f alpha:0.6f];
    blockingOverlayView.hidden = YES;
    blockingOverlayView.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapperView addSubview:blockingOverlayView];
    self.blockingOverlayView = blockingOverlayView;
    
    [NSLayoutConstraint activateConstraints:@[
        [blockingOverlayView.leadingAnchor constraintEqualToAnchor:wrapperView.leadingAnchor],
        [blockingOverlayView.trailingAnchor constraintEqualToAnchor:wrapperView.trailingAnchor],
        [blockingOverlayView.topAnchor constraintEqualToAnchor:wrapperView.topAnchor],
        [blockingOverlayView.bottomAnchor constraintEqualToAnchor:wrapperView.bottomAnchor],
    ]];
    
    UIImageView *blockingReasonImageView = [[UIImageView alloc] init];
    blockingReasonImageView.translatesAutoresizingMaskIntoConstraints = NO;
    blockingReasonImageView.tintColor = UIColor.whiteColor;
    [blockingOverlayView addSubview:blockingReasonImageView];
    self.blockingReasonImageView = blockingReasonImageView;
    
    [NSLayoutConstraint activateConstraints:@[
        [blockingReasonImageView.centerXAnchor constraintEqualToAnchor:blockingOverlayView.centerXAnchor],
        [blockingReasonImageView.centerYAnchor constraintEqualToAnchor:blockingOverlayView.centerYAnchor]
    ]];
    
    UIImage *media360Image = [UIImage srg_letterboxImageNamed:@"360_media"];
    UIImageView *media360ImageView = [[UIImageView alloc] initWithImage:media360Image];
    media360ImageView.translatesAutoresizingMaskIntoConstraints = NO;
    media360ImageView.tintColor = UIColor.whiteColor;
    media360ImageView.layer.shadowOpacity = 0.3f;
    media360ImageView.layer.shadowRadius = 2.f;
    media360ImageView.layer.shadowOffset = CGSizeMake(0.f, 1.f);
    [wrapperView addSubview:media360ImageView];
    self.media360ImageView = media360ImageView;
    
    [NSLayoutConstraint activateConstraints:@[
        [media360ImageView.leadingAnchor constraintEqualToAnchor:wrapperView.leadingAnchor constant:5.f],
        [media360ImageView.bottomAnchor constraintEqualToAnchor:wrapperView.bottomAnchor constant:5.f],
    ]];
    
    SRGPaddedLabel *durationLabel = [[SRGPaddedLabel alloc] init];
    durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    durationLabel.backgroundColor = [UIColor colorWithWhite:0.f alpha:0.85f];
    durationLabel.textColor = UIColor.whiteColor;
    durationLabel.textAlignment = NSTextAlignmentCenter;
    durationLabel.horizontalMargin = 5.f;
    durationLabel.layer.cornerRadius = 3.f;
    durationLabel.layer.masksToBounds = YES;
    [wrapperView addSubview:durationLabel];
    self.durationLabel = durationLabel;
    
    [NSLayoutConstraint activateConstraints:@[
        [durationLabel.trailingAnchor constraintEqualToAnchor:wrapperView.trailingAnchor constant:-5.f],
        [durationLabel.bottomAnchor constraintEqualToAnchor:wrapperView.bottomAnchor constant:-5.f],
        [durationLabel.heightAnchor constraintEqualToConstant:18.f]
    ]];
    
    UIProgressView *progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    progressView.translatesAutoresizingMaskIntoConstraints = NO;
    progressView.progressTintColor = UIColor.redColor;
    progressView.trackTintColor = [UIColor colorWithWhite:1.f alpha:0.6f];
    [wrapperView addSubview:progressView];
    self.progressView = progressView;
    
    [NSLayoutConstraint activateConstraints:@[
        [progressView.leadingAnchor constraintEqualToAnchor:wrapperView.leadingAnchor],
        [progressView.trailingAnchor constraintEqualToAnchor:wrapperView.trailingAnchor],
        [progressView.bottomAnchor constraintEqualToAnchor:wrapperView.bottomAnchor]
    ]];
    
    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.alignment = UIStackViewAlignmentFill;
    stackView.distribution = UIStackViewDistributionFill;
    [self.contentView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [[stackView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:6.f] srgletterbox_withPriority:999],
        [[stackView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6.f] srgletterbox_withPriority:999],
        [stackView.topAnchor constraintEqualToAnchor:wrapperView.bottomAnchor constant:2.f],
        [stackView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:3.f]
    ]];
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.numberOfLines = 2;
    [stackView addArrangedSubview:titleLabel];
    self.titleLabel = titleLabel;
    
    UIView *spacerView = [[UIView alloc] init];
    [stackView addArrangedSubview:spacerView];
}

#pragma mark Overrides

- (void)prepareForReuse
{
    [super prepareForReuse];
    
    self.blockingOverlayView.hidden = YES;
    self.blockingReasonImageView.image = nil;
    
    [self.imageView srg_resetImage];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    self.contentView.frame = self.bounds;
}

#pragma mark Getters and setters

- (void)setSubdivision:(SRGSubdivision *)subdivision
{
    _subdivision = subdivision;
    
    self.titleLabel.text = subdivision.title;
    self.titleLabel.font = [UIFont srg_mediumFontWithTextStyle:SRGAppearanceFontTextStyleCaption];
    
    [self.imageView srg_requestImageForObject:subdivision withScale:SRGImageScaleMedium type:SRGImageTypeDefault];
    
    self.durationLabel.font = [UIFont srg_mediumFontWithTextStyle:SRGAppearanceFontTextStyleCaption];
    self.durationLabel.backgroundColor = [UIColor colorWithWhite:0.f alpha:0.5f];
    
    NSString * (^formattedDuration)(NSTimeInterval) = ^(NSTimeInterval durationInSeconds) {
        if (durationInSeconds <= 60. * 60.) {
            return [NSDateComponentsFormatter.srg_shortDateComponentsFormatter stringFromTimeInterval:durationInSeconds];
        }
        else {
            return [NSDateComponentsFormatter.srg_mediumDateComponentsFormatter stringFromTimeInterval:durationInSeconds];
        }
    };
    
    NSDate *currentDate = NSDate.date;
    
    SRGTimeAvailability timeAvailability = [subdivision timeAvailabilityAtDate:currentDate];
    if (timeAvailability == SRGTimeAvailabilityNotYetAvailable) {
        self.durationLabel.text = SRGLetterboxLocalizedString(@"Soon", @"Short label identifying content which will be available soon.").uppercaseString;
        self.durationLabel.hidden = NO;
    }
    else if (timeAvailability == SRGTimeAvailabilityNotAvailableAnymore) {
        self.durationLabel.text = SRGLetterboxLocalizedString(@"Expired", @"Short label identifying content which has expired.").uppercaseString;
        self.durationLabel.hidden = NO;
    }
    else if ([subdivision isKindOfClass:SRGSegment.class]) {
        SRGSegment *segment = (SRGSegment *)subdivision;
        if (segment.markInDate && segment.markOutDate) {
            if ([segment.markInDate compare:currentDate] != NSOrderedDescending && [currentDate compare:segment.markOutDate] != NSOrderedDescending) {
                self.durationLabel.text = SRGLetterboxLocalizedString(@"Live", @"Short label identifying a livestream. Display in uppercase.").uppercaseString;
                self.durationLabel.backgroundColor = UIColor.srg_liveRedColor;
            }
            else {
                NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:SRGLetterboxNonLocalizedString(@" ") attributes:@{ NSFontAttributeName : [UIFont srg_awesomeFontWithTextStyle:SRGAppearanceFontTextStyleCaption] }];
                [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:[NSDateFormatter.srgletterbox_timeFormatter stringFromDate:segment.markInDate] attributes:@{ NSFontAttributeName : [UIFont srg_mediumFontWithTextStyle:SRGAppearanceFontTextStyleCaption] }]];
                self.durationLabel.attributedText = attributedString.copy;
            }
            self.durationLabel.hidden = NO;
        }
        else if (segment.duration != 0) {
            self.durationLabel.text = formattedDuration(segment.duration / 1000.);
            self.durationLabel.hidden = NO;
        }
        else {
            self.durationLabel.text = nil;
            self.durationLabel.hidden = YES;
        }
    }
    else if (subdivision.contentType == SRGContentTypeLivestream || subdivision.contentType == SRGContentTypeScheduledLivestream) {
        self.durationLabel.text = SRGLetterboxLocalizedString(@"Live", @"Short label identifying a livestream. Display in uppercase.").uppercaseString;
        self.durationLabel.hidden = NO;
        self.durationLabel.backgroundColor = UIColor.srg_liveRedColor;
    }
    else if (subdivision.duration != 0.) {
        self.durationLabel.text = formattedDuration(subdivision.duration / 1000.);
        self.durationLabel.hidden = NO;
    }
    else {
        self.durationLabel.text = nil;
        self.durationLabel.hidden = YES;
    }
    
    SRGBlockingReason blockingReason = [subdivision blockingReasonAtDate:currentDate];
    if (blockingReason == SRGBlockingReasonNone || blockingReason == SRGBlockingReasonStartDate) {
        self.blockingOverlayView.hidden = YES;
        self.blockingReasonImageView.image = nil;
        
        self.titleLabel.textColor = UIColor.whiteColor;
    }
    else {
        self.blockingOverlayView.hidden = NO;
        self.blockingReasonImageView.image = [UIImage srg_letterboxImageForBlockingReason:blockingReason];
        
        self.titleLabel.textColor = UIColor.lightGrayColor;
    }
    
    SRGPresentation presentation = SRGPresentationDefault;
    if ([subdivision isKindOfClass:SRGChapter.class]) {
        presentation = ((SRGChapter *)subdivision).presentation;
    }
    self.media360ImageView.hidden = (presentation != SRGPresentation360);
}

- (void)setProgress:(float)progress
{
    self.progressView.progress = progress;
}

- (void)setCurrent:(BOOL)current
{
    _current = current;
    
    if (current) {
        self.contentView.layer.cornerRadius = 4.f;
        self.contentView.layer.masksToBounds = YES;
        self.contentView.backgroundColor = [UIColor colorWithRed:128.f / 255.f green:0.f / 255.f blue:0.f / 255.f alpha:1.f];
        
        self.wrapperView.layer.cornerRadius = 0.f;
        self.wrapperView.layer.masksToBounds = NO;
    }
    else {
        self.contentView.layer.cornerRadius = 0.f;
        self.contentView.layer.masksToBounds = NO;
        self.contentView.backgroundColor = UIColor.clearColor;
        
        self.wrapperView.layer.cornerRadius = 4.f;
        self.wrapperView.layer.masksToBounds = YES;
    }
}

#pragma mark Gesture recognizers

- (void)longPress:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        if (self.delegate) {
            [self.delegate letterboxSubdivisionCellDidLongPress:self];
        }
    }
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement
{
    return YES;
}

- (NSString *)accessibilityLabel
{
    return self.subdivision.title;
}

- (NSString *)accessibilityHint
{
    return SRGLetterboxAccessibilityLocalizedString(@"Plays the content.", @"Segment or chapter cell hint");
}

@end

#endif
