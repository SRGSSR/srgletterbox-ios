//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "LetterboxBaseTestCase.h"

NSURL *MMFServiceURL(void)
{
    return [NSURL URLWithString:@"https://play-mmf.herokuapp.com/integrationlayer"];
}

NSString *MMFScheduledOnDemandVideoURN(NSDate *startDate, NSDate *endDate)
{
    return [NSString stringWithFormat:@"urn:rts:video:_bipbop_basic_delay_%@_%@", @((NSInteger)startDate.timeIntervalSince1970), @((NSInteger)endDate.timeIntervalSince1970)];
}

NSString *MMFCachedScheduledOnDemandVideoURN(NSDate *startDate, NSDate *endDate)
{
    return [NSString stringWithFormat:@"urn:rts:video:_bipbop_basic_cacheddelay_%@_%@", @((NSInteger)startDate.timeIntervalSince1970), @((NSInteger)endDate.timeIntervalSince1970)];
}

NSString *MMFURLChangeVideoURN(NSDate *startDate, NSDate *endDate)
{
    return [NSString stringWithFormat:@"urn:rts:video:_mediaplayer_dvr_killswitch_%@_%@", @((NSInteger)startDate.timeIntervalSince1970), @((NSInteger)endDate.timeIntervalSince1970)];
}

NSString *MMFBlockingReasonChangeVideoURN(NSDate *startDate, NSDate *endDate)
{
    return [NSString stringWithFormat:@"urn:rts:video:_mediaplayer_dvr_geoblocked_%@_%@", @((NSInteger)startDate.timeIntervalSince1970), @((NSInteger)endDate.timeIntervalSince1970)];
}

NSString *MMFSwissTXTFullDVRURN(NSDate *startDate, NSDate *endDate)
{
    return [NSString stringWithFormat:@"urn:rts:video:_tagesschau24_ard_fulldvr_%@_%@", @((NSInteger)startDate.timeIntervalSince1970), @((NSInteger)endDate.timeIntervalSince1970)];
}

NSString *MMFSwissTXTLimitedDVRURN(NSDate *startDate, NSDate *endDate)
{
    return [NSString stringWithFormat:@"urn:rts:video:_tagesschau24_ard_liveonly_limiteddvr_%@_%@", @((NSInteger)startDate.timeIntervalSince1970), @((NSInteger)endDate.timeIntervalSince1970)];
}

NSString *MMFSwissTXTLiveOnlyURN(NSDate *startDate, NSDate *endDate)
{
    return [NSString stringWithFormat:@"urn:rts:video:_tagesschau24_ard_liveonly_delay_%@_%@", @((NSInteger)startDate.timeIntervalSince1970), @((NSInteger)endDate.timeIntervalSince1970)];
}

@implementation LetterboxBaseTestCase

#pragma mark Helpers

- (XCTestExpectation *)expectationForSingleNotification:(NSNotificationName)notificationName object:(id)objectToObserve handler:(XCNotificationExpectationHandler)handler
{
    NSString *description = [NSString stringWithFormat:@"Expectation for notification '%@' from object %@", notificationName, objectToObserve];
    XCTestExpectation *expectation = [self expectationWithDescription:description];
    
    __block id observer = nil;
    observer = [NSNotificationCenter.defaultCenter addObserverForName:notificationName object:objectToObserve queue:nil usingBlock:^(NSNotification * _Nonnull notification) {
        void (^fulfill)(void) = ^{
            [expectation fulfill];
            [NSNotificationCenter.defaultCenter removeObserver:observer];
        };
        
        if (handler) {
            if (handler(notification)) {
                fulfill();
            }
        }
        else {
            fulfill();
        }
    }];
    return expectation;
}

- (XCTestExpectation *)expectationForElapsedTimeInterval:(NSTimeInterval)timeInterval withHandler:(void (^)(void))handler
{
    XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"Wait for %@ seconds", @(timeInterval)]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [expectation fulfill];
        handler ? handler() : nil;
    });
    return expectation;
}

@end
