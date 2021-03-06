//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

@import UIKit;

NS_ASSUME_NONNULL_BEGIN

@interface NSLayoutConstraint (SRGLetterbox)

/**
 *  Replace a constraint with an equivalent one having the specified multiplier. Returns a new constraint
 *  if the multiplier changed, otherwise the receiver.
 */
- (NSLayoutConstraint *)srg_replacementConstraintWithMultiplier:(CGFloat)multiplier API_AVAILABLE(ios(10.0));

/**
 *  Replace a constraint with an equivalent one having the specified multiplier and constant. Returns a new
 *  constraint if the multiplier changed, otherwise the receiver with adjusted constant.
 */
- (NSLayoutConstraint *)srg_replacementConstraintWithMultiplier:(CGFloat)multiplier constant:(CGFloat)constant API_AVAILABLE(ios(10.0));

@end

NS_ASSUME_NONNULL_END
