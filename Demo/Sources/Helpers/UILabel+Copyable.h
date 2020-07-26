//
//  UILabel+Copyable.h
//
//  Created by Alexandre Santos on 16/07/14.
//  Copyright (c) 2014 iAOS Software. All rights reserved.
//

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

@import UIKit;

/**
 A category to enable long press copy feature on UILabel.
 */
@interface UILabel (Copyable)

/**
 Set this property to YES in order to enable the copy feature. Defaults to NO.
 */
@property (nonatomic) IBInspectable BOOL copyingEnabled API_UNAVAILABLE(tvos);

/**
 Used to enable/disable the internal long press gesture recognizer. Defaults to YES.
 */
@property (nonatomic) IBInspectable BOOL shouldUseLongPressGestureRecognizer API_UNAVAILABLE(tvos);

@end
