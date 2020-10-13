//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "NSError+SRGLetterbox.h"

@implementation NSError (SRGLetterbox)

#pragma mark Class methods

- (NSError *)srg_letterboxNetworkError
{
    NSError *error = self;
    while (error) {
        if ([error.domain isEqualToString:NSURLErrorDomain] || [error.domain isEqualToString:(NSString *)kCFErrorDomainCFNetwork]) {
            return error;
        }
        
        error = error.userInfo[NSUnderlyingErrorKey];
    }
    return nil;
}

@end
