//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  A simple control resembling an image button, calling the action defined for the `UIControlEventPrimaryActionTriggered´
 *  event when pressed.
 */
@interface SRGImageButton : UIControl

/**
 *  The image view displaying the button image.
 */
@property (nonatomic, readonly) UIImageView *imageView;

@end

NS_ASSUME_NONNULL_END
