//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "LetterboxBaseTestCase.h"

#import <libextobjc/libextobjc.h>
#import <OHHTTPStubs/NSURLRequest+HTTPBodyTesting.h>
#import <OHHTTPStubs/OHHTTPStubs.h>
#import <SRGContentProtection/SRGContentProtection.h>
#import <SRGDiagnostics/SRGDiagnostics.h>
#import <SRGLetterbox/SRGLetterbox.h>

NSString * const DiagnosticTestDidSendReportNotification = @"DiagnosticTestDidSendReportNotification";
NSString * const DiagnosticTestJSONDictionaryKey = @"DiagnosticTestJSONDictionary";

static NSString * const OnDemandVideoURN = @"urn:swi:video:42844052";
static NSString * const OnDemandVideoTokenURN = @"urn:rts:video:1967124";

@interface DiagnosticTestCase : LetterboxBaseTestCase

@property (nonatomic) SRGDataProvider *dataProvider;
@property (nonatomic) SRGLetterboxController *controller;

@property (nonatomic, weak) id<OHHTTPStubsDescriptor> reportRequestStub;

@end

@implementation DiagnosticTestCase

#pragma mark Setup and tear down

- (void)setUp
{
    self.dataProvider = [[SRGDataProvider alloc] initWithServiceURL:SRGIntegrationLayerProductionServiceURL()];
    self.controller = [[SRGLetterboxController alloc] init];
    
    [SRGDiagnosticsService serviceWithName:@"SRGPlaybackMetrics"].submissionInterval = SRGDiagnosticsMinimumSubmissionInterval;
    
    self.reportRequestStub = [OHHTTPStubs stubRequestsPassingTest:^BOOL(NSURLRequest *request) {
        return [request.URL isEqual:[NSURL URLWithString:@"https://srgsnitch.herokuapp.com/report"]];
    } withStubResponse:^OHHTTPStubsResponse *(NSURLRequest *request) {
        NSDictionary *JSONDictionary = [NSJSONSerialization JSONObjectWithData:[request OHHTTPStubs_HTTPBody] options:0 error:NULL] ?: @{};
        [[NSNotificationCenter defaultCenter] postNotificationName:DiagnosticTestDidSendReportNotification
                                                            object:nil
                                                          userInfo:@{ DiagnosticTestJSONDictionaryKey : JSONDictionary }];
        return [[OHHTTPStubsResponse responseWithData:[NSJSONSerialization dataWithJSONObject:@{ @"success" : @YES } options:0 error:NULL]
                                           statusCode:200
                                              headers:@{ @"Content-Type" : @"application/json" }] requestTime:0. responseTime:OHHTTPStubsDownloadSpeedWifi];
    }];
    self.reportRequestStub.name = @"Diagnostic report";
}

- (void)tearDown
{
    // Always ensure the player gets deallocated between tests
    [self.controller reset];
    self.controller = nil;
    
    [OHHTTPStubs removeStub:self.reportRequestStub];
}

#pragma mark Tests

- (void)testPlaybackReportForNonProtectedMedia
{
    // Report submission is disabled in public builds (tested once). Nothing to test here.
    if (SRGContentProtectionIsPublic()) {
        return;
    }
    
    NSString *URN = OnDemandVideoURN;
    
    [self expectationForNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    [self expectationForNotification:DiagnosticTestDidSendReportNotification object:nil handler:^BOOL(NSNotification * _Nonnull notification) {
        NSDictionary *JSONDictionary = notification.userInfo[DiagnosticTestJSONDictionaryKey];
        
        XCTAssertEqualObjects(JSONDictionary[@"version"], @1);
        XCTAssertEqualObjects(JSONDictionary[@"urn"], URN);
        XCTAssertEqualObjects(JSONDictionary[@"screenType"], @"local");
        XCTAssertEqualObjects(JSONDictionary[@"networkType"], @"wifi");
        XCTAssertEqualObjects(JSONDictionary[@"browser"], [[NSBundle mainBundle] bundleIdentifier]);
        NSString *playerName = [NSString stringWithFormat:@"Letterbox/iOS/%@", SRGLetterboxMarketingVersion()];
        XCTAssertEqualObjects(JSONDictionary[@"player"], playerName);
        XCTAssertEqualObjects(JSONDictionary[@"environment"], @"preprod");
        XCTAssertEqualObjects(JSONDictionary[@"standalone"], @NO);
        
        XCTAssertNotNil(JSONDictionary[@"clientTime"]);
        XCTAssertNotNil(JSONDictionary[@"device"]);
        
        XCTAssertNotNil(JSONDictionary[@"playerResult"]);
        XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"playerResult"][@"url"]]);
        XCTAssertNotNil(JSONDictionary[@"playerResult"][@"duration"]);
        XCTAssertNil(JSONDictionary[@"playerResult"][@"errorMessage"]);
        
        XCTAssertNotNil(JSONDictionary[@"duration"]);
        
        XCTAssertNotNil(JSONDictionary[@"ilResult"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"duration"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"varnish"]);
        XCTAssertEqualObjects(JSONDictionary[@"ilResult"][@"httpStatusCode"], @200);
        XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"ilResult"][@"url"]]);
        XCTAssertNil(JSONDictionary[@"playerResult"][@"errorMessage"]);
        
        if (! SRGContentProtectionIsPublic()) {
            XCTAssertNotNil(JSONDictionary[@"tokenResult"]);
            XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"tokenResult"][@"url"]]);
            XCTAssertNotNil(JSONDictionary[@"tokenResult"][@"httpStatusCode"]);
            XCTAssertNotNil(JSONDictionary[@"tokenResult"][@"duration"]);
            XCTAssertNil(JSONDictionary[@"tokenResult"][@"errorMessage"]);
        }
        else {
            XCTAssertNil(JSONDictionary[@"tokenResult"]);
        }
        
        XCTAssertNil(JSONDictionary[@"drmResult"]);
        
        return YES;
    }];
    
    [self.controller playURN:URN standalone:NO];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
}

- (void)testSinglePlaybackReportSubmission
{
    // Report submission is disabled in public builds (tested once). Nothing to test here.
    if (SRGContentProtectionIsPublic()) {
        return;
    }
    
    [self expectationForNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    [self expectationForNotification:DiagnosticTestDidSendReportNotification object:nil handler:^BOOL(NSNotification * _Nonnull notification) {
        return YES;
    }];
    
    [self.controller playURN:OnDemandVideoURN standalone:NO];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    // Play for a while. No other diagnostic report notification must be received.
    id diagnosticSentObserver = [[NSNotificationCenter defaultCenter] addObserverForName:DiagnosticTestDidSendReportNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull notification) {
        XCTFail(@"Controller must not send twice the diagnostic report.");
    }];
    
    [self expectationForElapsedTimeInterval:15. withHandler:nil];
    
    [self waitForExpectationsWithTimeout:20. handler:^(NSError * _Nullable error) {
        [[NSNotificationCenter defaultCenter] removeObserver:diagnosticSentObserver];
    }];
}

- (void)testPlaybackReportForUnknownMedia
{
    // Report submission is disabled in public builds (tested once). Nothing to test here.
    if (SRGContentProtectionIsPublic()) {
        return;
    }
    
    NSString *URN = @"urn:swi:video:_UNKNOWN_ID_";
    
    [self expectationForNotification:SRGLetterboxPlaybackDidFailNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return YES;
    }];
    
    [self expectationForNotification:DiagnosticTestDidSendReportNotification object:nil handler:^BOOL(NSNotification * _Nonnull notification) {
        NSDictionary *JSONDictionary = notification.userInfo[DiagnosticTestJSONDictionaryKey];
        
        XCTAssertEqualObjects(JSONDictionary[@"urn"], URN);
        XCTAssertEqualObjects(JSONDictionary[@"screenType"], @"local");
        XCTAssertEqualObjects(JSONDictionary[@"networkType"], @"wifi");
        XCTAssertEqualObjects(JSONDictionary[@"browser"], [[NSBundle mainBundle] bundleIdentifier]);
        NSString *playerName = [NSString stringWithFormat:@"Letterbox/iOS/%@", SRGLetterboxMarketingVersion()];
        XCTAssertEqualObjects(JSONDictionary[@"player"], playerName);
        XCTAssertEqualObjects(JSONDictionary[@"environment"], @"preprod");
        XCTAssertEqualObjects(JSONDictionary[@"standalone"], @NO);
        
        XCTAssertNotNil(JSONDictionary[@"clientTime"]);
        XCTAssertNotNil(JSONDictionary[@"device"]);
        
        XCTAssertNil(JSONDictionary[@"playerResult"]);
        
        XCTAssertNotNil(JSONDictionary[@"duration"]);
        
        XCTAssertNotNil(JSONDictionary[@"ilResult"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"duration"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"varnish"]);
        XCTAssertEqualObjects(JSONDictionary[@"ilResult"][@"httpStatusCode"], @404);
        XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"ilResult"][@"url"]]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"errorMessage"]);
        
        XCTAssertNil(JSONDictionary[@"tokenResult"]);
        
        XCTAssertNil(JSONDictionary[@"drmResult"]);
        
        return YES;
    }];
    
    [self.controller playURN:URN standalone:NO];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
}

- (void)testPlaybackReportForUnplayableMedia
{
    // Report submission is disabled in public builds (tested once). Nothing to test here.
    if (SRGContentProtectionIsPublic()) {
        return;
    }
    
    self.controller.serviceURL = MMFServiceURL();
    
    NSString *URN = @"urn:rts:video:playlist500";
    
    [self expectationForNotification:SRGLetterboxPlaybackDidFailNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return YES;
    }];
    
    [self expectationForNotification:DiagnosticTestDidSendReportNotification object:nil handler:^BOOL(NSNotification * _Nonnull notification) {
        NSDictionary *JSONDictionary = notification.userInfo[DiagnosticTestJSONDictionaryKey];
        
        XCTAssertEqualObjects(JSONDictionary[@"urn"], URN);
        XCTAssertEqualObjects(JSONDictionary[@"screenType"], @"local");
        XCTAssertEqualObjects(JSONDictionary[@"networkType"], @"wifi");
        XCTAssertEqualObjects(JSONDictionary[@"browser"], [[NSBundle mainBundle] bundleIdentifier]);
        NSString *playerName = [NSString stringWithFormat:@"Letterbox/iOS/%@", SRGLetterboxMarketingVersion()];
        XCTAssertEqualObjects(JSONDictionary[@"player"], playerName);
        XCTAssertEqualObjects(JSONDictionary[@"environment"], @"preprod");
        XCTAssertEqualObjects(JSONDictionary[@"standalone"], @NO);
        
        XCTAssertNotNil(JSONDictionary[@"clientTime"]);
        XCTAssertNotNil(JSONDictionary[@"device"]);
        
        XCTAssertNotNil(JSONDictionary[@"playerResult"]);
        XCTAssertNotNil(JSONDictionary[@"playerResult"][@"url"]);
        XCTAssertNotNil(JSONDictionary[@"playerResult"][@"duration"]);
        XCTAssertNotNil(JSONDictionary[@"playerResult"][@"errorMessage"]);
        
        XCTAssertNotNil(JSONDictionary[@"duration"]);
        
        XCTAssertNotNil(JSONDictionary[@"ilResult"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"duration"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"varnish"]);
        XCTAssertEqualObjects(JSONDictionary[@"ilResult"][@"httpStatusCode"], @200);
        XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"ilResult"][@"url"]]);
        XCTAssertNil(JSONDictionary[@"ilResult"][@"errorMessage"]);
        
        XCTAssertNil(JSONDictionary[@"tokenResult"]);
        
        XCTAssertNil(JSONDictionary[@"drmResult"]);
        
        return YES;
    }];
    
    [self.controller playURN:URN standalone:NO];
    
    [self waitForExpectationsWithTimeout:60. handler:nil];
}

- (void)testPlaybackReportForOverriddenMedia
{
    // Report submission is disabled in public builds (tested once). Nothing to test here.
    if (SRGContentProtectionIsPublic()) {
        return;
    }
    
    NSURL *overridingURL = [NSURL URLWithString:@"http://devimages.apple.com.edgekey.net/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"];
    
    self.controller.contentURLOverridingBlock = ^NSURL * _Nullable(NSString * _Nonnull URN) {
        return overridingURL;
    };
    
    [self expectationForNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller playURN:OnDemandVideoURN standalone:NO];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    // Play for a while. No diagnostic report notifications must be received for content URL overriding.
    id diagnosticSentObserver = [[NSNotificationCenter defaultCenter] addObserverForName:DiagnosticTestDidSendReportNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull notification) {
        XCTFail(@"Controller must not send diagnostic reports for content URL overriding.");
    }];
    
    [self expectationForElapsedTimeInterval:15. withHandler:nil];
    
    [self waitForExpectationsWithTimeout:20. handler:^(NSError * _Nullable error) {
        [[NSNotificationCenter defaultCenter] removeObserver:diagnosticSentObserver];
    }];
}

- (void)testPlaybackReportForTokenProtectedMedia
{
    // Report submission is disabled in public builds (tested once). Nothing to test here.
    if (SRGContentProtectionIsPublic()) {
        return;
    }
    
    NSString *URN = OnDemandVideoTokenURN;
    
    [self expectationForNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    [self expectationForNotification:DiagnosticTestDidSendReportNotification object:nil handler:^BOOL(NSNotification * _Nonnull notification) {
        NSDictionary *JSONDictionary = notification.userInfo[DiagnosticTestJSONDictionaryKey];
        
        XCTAssertEqualObjects(JSONDictionary[@"version"], @1);
        XCTAssertEqualObjects(JSONDictionary[@"urn"], URN);
        XCTAssertEqualObjects(JSONDictionary[@"screenType"], @"local");
        XCTAssertEqualObjects(JSONDictionary[@"networkType"], @"wifi");
        XCTAssertEqualObjects(JSONDictionary[@"browser"], [[NSBundle mainBundle] bundleIdentifier]);
        NSString *playerName = [NSString stringWithFormat:@"Letterbox/iOS/%@", SRGLetterboxMarketingVersion()];
        XCTAssertEqualObjects(JSONDictionary[@"player"], playerName);
        XCTAssertEqualObjects(JSONDictionary[@"environment"], @"preprod");
        XCTAssertEqualObjects(JSONDictionary[@"standalone"], @NO);
        
        XCTAssertNotNil(JSONDictionary[@"clientTime"]);
        XCTAssertNotNil(JSONDictionary[@"device"]);
        
        XCTAssertNotNil(JSONDictionary[@"playerResult"]);
        XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"playerResult"][@"url"]]);
        XCTAssertNotNil(JSONDictionary[@"playerResult"][@"duration"]);
        XCTAssertNil(JSONDictionary[@"playerResult"][@"errorMessage"]);
        
        XCTAssertNotNil(JSONDictionary[@"duration"]);
        
        XCTAssertNotNil(JSONDictionary[@"ilResult"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"duration"]);
        XCTAssertNotNil(JSONDictionary[@"ilResult"][@"varnish"]);
        XCTAssertEqualObjects(JSONDictionary[@"ilResult"][@"httpStatusCode"], @200);
        XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"ilResult"][@"url"]]);
        XCTAssertNil(JSONDictionary[@"playerResult"][@"errorMessage"]);
        
        XCTAssertNotNil(JSONDictionary[@"tokenResult"]);
        XCTAssertNotNil([NSURL URLWithString:JSONDictionary[@"tokenResult"][@"url"]]);
        XCTAssertNotNil(JSONDictionary[@"tokenResult"][@"httpStatusCode"]);
        XCTAssertNotNil(JSONDictionary[@"tokenResult"][@"duration"]);
        XCTAssertNil(JSONDictionary[@"tokenResult"][@"errorMessage"]);
        
        XCTAssertNil(JSONDictionary[@"drmResult"]);
        
        return YES;
    }];
    
    [self.controller playURN:URN standalone:NO];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
}

- (void)testDisabledPlaybackReportsInPublicBuilds
{
    if (! SRGContentProtectionIsPublic()) {
        return;
    }
    
    [self expectationForNotification:SRGLetterboxPlaybackStateDidChangeNotification object:self.controller handler:^BOOL(NSNotification * _Nonnull notification) {
        return [notification.userInfo[SRGMediaPlayerPlaybackStateKey] integerValue] == SRGMediaPlayerPlaybackStatePlaying;
    }];
    
    [self.controller playURN:OnDemandVideoURN standalone:NO];
    
    [self waitForExpectationsWithTimeout:30. handler:nil];
    
    // Play for a while. No diagnostic report notifications must be received in public builds
    id diagnosticSentObserver = [[NSNotificationCenter defaultCenter] addObserverForName:DiagnosticTestDidSendReportNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull notification) {
        XCTFail(@"Controller must not send diagnostic reports for public builds.");
    }];
    
    [self expectationForElapsedTimeInterval:15. withHandler:nil];
    
    [self waitForExpectationsWithTimeout:20. handler:^(NSError * _Nullable error) {
        [[NSNotificationCenter defaultCenter] removeObserver:diagnosticSentObserver];
    }];
}

@end
