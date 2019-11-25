//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "LetterboxBaseTestCase.h"

#import <SRGLetterbox/SRGLetterbox.h>

@interface SkipTestCase : LetterboxBaseTestCase

@property (nonatomic) SRGLetterboxController *controller;

@end

@implementation SkipTestCase

#pragma mark Setup and tear down

- (void)setUp
{
    self.controller = [[SRGLetterboxController alloc] init];
}

- (void)tearDown
{
    // Always ensure the player gets deallocated between tests
    [self.controller reset];
    self.controller = nil;
}

#pragma mark Tests

- (void)testOnDemandStreamSkips
{
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    // TTC
    [self.controller playURN:OnDemandVideoURN atPosition:nil withPreferredSettings:nil];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertTrue([self.controller canSkipWithInterval:15.]);
    
    // Seek to near the end
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    CMTime seekTime = CMTimeSubtract(CMTimeRangeGetEnd(self.controller.timeRange), CMTimeMakeWithSeconds(10., NSEC_PER_SEC));
    [self.controller seekToPosition:[SRGPosition positionAtTime:seekTime] withCompletionHandler:nil];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    
    // Seek far enough from the media end
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    CMTime seekTime1 = CMTimeSubtract(CMTimeRangeGetEnd(self.controller.timeRange), CMTimeMakeWithSeconds(60., NSEC_PER_SEC));
    [self.controller seekToPosition:[SRGPosition positionAtTime:seekTime1] withCompletionHandler:^(BOOL finished) {
        XCTAssertTrue(finished);
    }];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertTrue([self.controller canSkipWithInterval:15.]);
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    CMTime seekTime2 = CMTimeRangeGetEnd(self.controller.timeRange);
    [self.controller seekToPosition:[SRGPosition positionAtTime:seekTime2] withCompletionHandler:^(BOOL finished) {
        XCTAssertTrue(finished);
    }];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
}

- (void)testLivestreamSkips
{
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller playURN:LiveOnlyVideoURN atPosition:nil withPreferredSettings:nil];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    
    // Cannot skip
    BOOL skipped1 = [self.controller skipWithInterval:-15. completionHandler:^(BOOL finished) {
        XCTFail(@"Must not be called");
    }];
    XCTAssertFalse(skipped1);
    
    BOOL skipped2 = [self.controller skipWithInterval:15. completionHandler:^(BOOL finished) {
        XCTFail(@"Must not be called");
    }];
    XCTAssertFalse(skipped2);
}

- (void)testDVRStreamSkips
{
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    self.controller.serviceURL = MMFServiceURL();
    [self.controller playURN:MMFLiveDVRVideoURN atPosition:nil withPreferredSettings:nil];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue(self.controller.live);
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    
    // Seek far enough from live conditions
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    CMTime seekTime1 = CMTimeSubtract(CMTimeRangeGetEnd(self.controller.timeRange), CMTimeMakeWithSeconds(60., NSEC_PER_SEC));
    [self.controller seekToPosition:[SRGPosition positionAtTime:seekTime1] withCompletionHandler:^(BOOL finished) {
        XCTAssertTrue(finished);
    }];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertFalse(self.controller.live);
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertTrue([self.controller canSkipWithInterval:15.]);
    
    // Skip forward again
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    CMTime seekTime2 = CMTimeRangeGetEnd(self.controller.timeRange);
    [self.controller seekToPosition:[SRGPosition positionAroundTime:seekTime2] withCompletionHandler:^(BOOL finished) {
        XCTAssertTrue(finished);
    }];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue(self.controller.live);
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
}

- (void)testMultipleSkips
{
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller playURN:OnDemandLongVideoURN atPosition:nil withPreferredSettings:nil];
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    // Pile up skips forward
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller skipWithInterval:15. completionHandler:^(BOOL finished) {
        XCTAssertFalse(finished);
    }];
    [self.controller skipWithInterval:15. completionHandler:^(BOOL finished) {
        XCTAssertTrue(finished);
    }];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    
    // Pile up skips backward
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    BOOL skipped1 = [self.controller skipWithInterval:-15. completionHandler:^(BOOL finished) {
        XCTAssertFalse(finished);
    }];
    XCTAssertTrue(skipped1);
    
    BOOL skipped2 = [self.controller skipWithInterval:-15. completionHandler:^(BOOL finished) {
        XCTAssertTrue(finished);
    }];
    XCTAssertTrue(skipped2);
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
}

- (void)testSkipAbilitiesDuringOnDemandStreamPlaybackLifecycle
{
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
    
    __block BOOL preparingReceived = NO;
    __block BOOL playingReceived = NO;
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        if ([notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePreparing) {
            XCTAssertFalse([self.controller canSkipWithInterval:15.]);
            XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
            XCTAssertFalse([self.controller canSkipToLive]);
            
            preparingReceived = YES;
        }
        else if ([notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying) {
            XCTAssertTrue([self.controller canSkipWithInterval:15.]);
            XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
            XCTAssertFalse([self.controller canSkipToLive]);
            
            playingReceived = YES;
        }
        return preparingReceived && playingReceived;
    }];
    
    [self.controller playURN:OnDemandLongVideoURN atPosition:nil withPreferredSettings:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller seekToPosition:[SRGPosition positionAroundTimeInSeconds:80.] withCompletionHandler:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:15.]);
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStateIdle;
    }];
    
    [self.controller stop];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
}

- (void)testSkipAbilitiesDuringDVRLivestreamPlaybackLifecycle
{
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
    
    __block BOOL preparingReceived = NO;
    __block BOOL playingReceived = NO;
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        if ([notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePreparing) {
            XCTAssertFalse([self.controller canSkipWithInterval:15.]);
            XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
            XCTAssertFalse([self.controller canSkipToLive]);
            
            preparingReceived = YES;
        }
        else if ([notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying) {
            XCTAssertFalse([self.controller canSkipWithInterval:15.]);
            XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
            XCTAssertFalse([self.controller canSkipToLive]);
            
            playingReceived = YES;
        }
        return preparingReceived && playingReceived;
    }];
    
    self.controller.serviceURL = MMFServiceURL();
    [self.controller playURN:MMFLiveDVRVideoURN atPosition:nil withPreferredSettings:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller seekToPosition:[SRGPosition positionAroundTimeInSeconds:200.] withCompletionHandler:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    XCTAssertTrue([self.controller canSkipWithInterval:15.]);
    XCTAssertTrue([self.controller canSkipWithInterval:-15.]);
    XCTAssertTrue([self.controller canSkipToLive]);
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStateIdle;
    }];
    
    [self.controller stop];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
}

- (void)testSkipAbilitiesDuringLiveOnlyStreamPlaybackLifecycle
{
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
    
    __block BOOL preparingReceived = NO;
    __block BOOL playingReceived = NO;
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        if ([notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePreparing) {
            XCTAssertFalse([self.controller canSkipWithInterval:15.]);
            XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
            XCTAssertFalse([self.controller canSkipToLive]);
            
            preparingReceived = YES;
        }
        else if ([notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying) {
            XCTAssertFalse([self.controller canSkipWithInterval:15.]);
            XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
            XCTAssertFalse([self.controller canSkipToLive]);
            
            playingReceived = YES;
        }
        return preparingReceived && playingReceived;
    }];
    
    [self.controller playURN:LiveOnlyVideoURN atPosition:nil withPreferredSettings:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStateIdle;
    }];
    
    [self.controller stop];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    XCTAssertFalse([self.controller canSkipWithInterval:15.]);
    XCTAssertFalse([self.controller canSkipWithInterval:-15.]);
    XCTAssertFalse([self.controller canSkipToLive]);
}

- (void)testSkipToLiveForOnDemandStream
{
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller playURN:OnDemandVideoURN atPosition:nil withPreferredSettings:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    id eventObserver = [NSNotificationCenter.defaultCenter addObserverForName:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller queue:nil usingBlock:^(NSNotification * _Nonnull notification) {
        XCTFail(@"No playback state change must occur");
    }];
    
    [self expectationForElapsedTimeInterval:4. withHandler:nil];
    
    BOOL skipped = [self.controller skipToLiveWithCompletionHandler:^(BOOL finished) {
        XCTFail(@"Must not be called");
    }];
    XCTAssertFalse(skipped);
    
    [self waitForExpectationsWithTimeout:10. handler:^(NSError * _Nullable error) {
        [NSNotificationCenter.defaultCenter removeObserver:eventObserver];
    }];
}

- (void)testSkipToLiveForLivestream
{
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller playURN:LiveOnlyVideoURN atPosition:nil withPreferredSettings:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    id eventObserver = [NSNotificationCenter.defaultCenter addObserverForName:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller queue:nil usingBlock:^(NSNotification * _Nonnull notification) {
        XCTFail(@"No playback state change must occur");
    }];
    
    [self expectationForElapsedTimeInterval:4. withHandler:nil];
    
    BOOL skipped = [self.controller skipToLiveWithCompletionHandler:^(BOOL finished) {
        XCTFail(@"Must not be called");
    }];
    XCTAssertFalse(skipped);
    
    [self waitForExpectationsWithTimeout:10. handler:^(NSError * _Nullable error) {
        [NSNotificationCenter.defaultCenter removeObserver:eventObserver];
    }];
}

- (void)testSkipToLiveForDVRStream
{
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    self.controller.serviceURL = MMFServiceURL();
    [self.controller playURN:MMFLiveDVRVideoURN atPosition:nil withPreferredSettings:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    BOOL skipped1 = [self.controller skipToLiveWithCompletionHandler:^(BOOL finished) {
        XCTFail(@"Must not be called");
    }];
    XCTAssertFalse(skipped1);
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller seekToPosition:[SRGPosition positionAtTimeInSeconds:30.] withCompletionHandler:nil];
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
    
    [self expectationForSingleNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    BOOL skipped2 = [self.controller skipToLiveWithCompletionHandler:^(BOOL finished) {
        XCTAssertTrue(finished);
    }];
    XCTAssertTrue(skipped2);
    
    [self waitForExpectationsWithTimeout:10. handler:nil];
}

@end
