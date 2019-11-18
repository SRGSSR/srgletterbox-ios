//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "MediaListViewController.h"

#import "AdvancedPlayerViewController.h"
#import "DemoAccessibilityFormatter.h"
#import "NSBundle+LetterboxDemo.h"
#import "NSDateFormatter+LetterboxDemo.h"
#import "SettingsViewController.h"
#import "UIViewController+LetterboxDemo.h"

@interface MediaListViewController ()

@property (nonatomic) MediaList mediaList;
@property (nonatomic) SRGTopic *topic;
@property (nonatomic) NSURL *serviceURL;

@property (nonatomic) SRGDataProvider *dataProvider;
@property (nonatomic, weak) SRGBaseRequest *request;

@property (nonatomic) NSArray<SRGMedia *> *medias;

@end

@implementation MediaListViewController

#pragma mark Object lifecycle

- (instancetype)initWithMediaList:(MediaList)mediaList topic:(SRGTopic *)topic serviceURL:(NSURL *)serviceURL
{
    if (self = [super initWithStyle:UITableViewStyleGrouped]) {
        self.mediaList = mediaList;
        self.topic = topic;
        self.serviceURL = serviceURL;
    }
    return self;
}

- (instancetype)init
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

#pragma mark View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
#if TARGET_OS_TV
    if (@available(tvOS 13, *)) {
        self.navigationController.tabBarObservedScrollView = self.tableView;
    }
#endif
    
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    
    self.dataProvider = [[SRGDataProvider alloc] initWithServiceURL:self.serviceURL ?: ApplicationSettingServiceURL()];
    self.dataProvider.globalParameters = ApplicationSettingGlobalParameters();
    
#if TARGET_OS_IOS
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
    [self.tableView insertSubview:refreshControl atIndex:0];
    self.refreshControl = refreshControl;
#endif
    
    [self refresh];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    if (self.movingFromParentViewController || self.beingDismissed) {
        [self.request cancel];
    }
}

#pragma mark Getters and setters

- (NSString *)title
{
    if (self.mediaList == MediaListLatestByTopic) {
        return self.topic.title ?: NSLocalizedString(@"Unknown", nil);
    }
    else {
        static dispatch_once_t s_onceToken;
        static NSDictionary<NSNumber *, NSString *> *s_titles;
        dispatch_once(&s_onceToken, ^{
            s_titles = @{ @(MediaListLiveCenterSRF) : NSLocalizedString(@"SRF Live center", nil),
                          @(MediaListLiveCenterRTS) : NSLocalizedString(@"RTS Live center", nil),
                          @(MediaListLiveCenterRSI) : NSLocalizedString(@"RSI Live center", nil),
                          @(MediaListLiveTVSRF) : NSLocalizedString(@"SRF Live TVs", nil),
                          @(MediaListLiveTVRTS) : NSLocalizedString(@"RTS Live TVs", nil),
                          @(MediaListLiveTVRSI) : NSLocalizedString(@"RSI Live TVs", nil),
                          @(MediaListLiveTVRTR) : NSLocalizedString(@"RTR Live TVs", nil),
                          @(MediaListLiveRadioSRF) : NSLocalizedString(@"SRF Live Radios", nil),
                          @(MediaListLiveRadioRTS) : NSLocalizedString(@"RTS Live Radios", nil),
                          @(MediaListLiveRadioRSI) : NSLocalizedString(@"RSI Live Radios", nil),
                          @(MediaListLiveRadioRTR) : NSLocalizedString(@"RTR Live Radios", nil),
                          @(MediaListLatestVideosSRF) : NSLocalizedString(@"SRF Latest videos", nil),
                          @(MediaListLatestVideosRTS) : NSLocalizedString(@"RTS Latest videos", nil),
                          @(MediaListLatestVideosRSI) : NSLocalizedString(@"RSI Latest videos", nil),
                          @(MediaListLatestVideosRTR) : NSLocalizedString(@"RTR Latest videos", nil),
                          @(MediaListLatestVideosSWI) : NSLocalizedString(@"SWI Latest videos", nil),
                          @(MediaListLatestAudiosSRF1) : NSLocalizedString(@"SRF 1 Latest audios", nil),
                          @(MediaListLatestAudiosSRF2) : NSLocalizedString(@"SRF 2 Kultur Latest audios", nil),
                          @(MediaListLatestAudiosSRF3) : NSLocalizedString(@"SRF 3 Latest audios", nil),
                          @(MediaListLatestAudiosSRF4) : NSLocalizedString(@"SRF 4 News Latest audios", nil),
                          @(MediaListLatestAudiosSRF5) : NSLocalizedString(@"SRF Musikwelle Latest audios", nil),
                          @(MediaListLatestAudiosSRF6) : NSLocalizedString(@"SRF Virus Latest audios", nil),
                          @(MediaListLatestAudiosRTS1) : NSLocalizedString(@"RTS La 1ère Latest audios", nil),
                          @(MediaListLatestAudiosRTS2) : NSLocalizedString(@"RTS Espace 2 Latest audios", nil),
                          @(MediaListLatestAudiosRTS3) : NSLocalizedString(@"RTS Couleur 3 Latest audios", nil),
                          @(MediaListLatestAudiosRTS4) : NSLocalizedString(@"RTS Option Musique Latest audios", nil),
                          @(MediaListLatestAudiosRTS5) : NSLocalizedString(@"RTS Podcasts originaux Latest audios", nil),
                          @(MediaListLatestAudiosRSI1) : NSLocalizedString(@"RSI Rete Uno Latest audios", nil),
                          @(MediaListLatestAudiosRSI2) : NSLocalizedString(@"RSI Rete Due Latest audios", nil),
                          @(MediaListLatestAudiosRSI3) : NSLocalizedString(@"RSI Rete Tre Latest audios", nil),
                          @(MediaListLatestAudiosRTR) : NSLocalizedString(@"RTR Latest audios", nil),
                          @(MediaListLiveWebSRF) : NSLocalizedString(@"SRF Live Web", nil),
                          @(MediaListLiveWebRTS) : NSLocalizedString(@"RTS Live Web", nil),
                          @(MediaListLiveWebRSI) : NSLocalizedString(@"RSI Live Web", nil),
                          @(MediaListLiveWebRTR) : NSLocalizedString(@"RTR Live Web", nil) };
        });
        return s_titles[@(self.mediaList)] ?: NSLocalizedString(@"Unknown", nil);
    }
}

#pragma mark Data

- (void)refresh
{
    [self.request cancel];
    
    SRGBaseRequest *request = nil;
    
    SRGPaginatedMediaListCompletionBlock completionBlock = ^(NSArray<SRGMedia *> * _Nullable medias, SRGPage *page, SRGPage * _Nullable nextPage, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
#if TARGET_OS_IOS
        if (self.refreshControl.refreshing) {
            [self.refreshControl endRefreshing];
        }
#endif
        
        self.medias = medias;
        [self.tableView reloadData];
    };
    
    switch (self.mediaList) {
        case MediaListLatestByTopic: {
            request = [[self.dataProvider latestMediasForTopicWithURN:self.topic.URN completionBlock:completionBlock] requestWithPageSize:100];
            break;
        }
            
        case MediaListLiveCenterSRF:
        case MediaListLiveCenterRTS:
        case MediaListLiveCenterRSI: {
            static NSDictionary<NSNumber *, NSNumber *> *s_vendors;
            static dispatch_once_t s_onceToken;
            dispatch_once(&s_onceToken, ^{
                s_vendors = @{ @(MediaListLiveCenterSRF) : @(SRGVendorSRF),
                               @(MediaListLiveCenterRTS) : @(SRGVendorRTS),
                               @(MediaListLiveCenterRSI) : @(SRGVendorRSI) };
            });
            
            NSNumber *vendorNumber = s_vendors[@(self.mediaList)];
            NSAssert(vendorNumber != nil, @"The business unit must be supported");
            request = [[self.dataProvider liveCenterVideosForVendor:vendorNumber.integerValue withCompletionBlock:completionBlock] requestWithPageSize:100];
            break;
        }
            
        case MediaListLiveTVSRF:
        case MediaListLiveTVRTS:
        case MediaListLiveTVRSI:
        case MediaListLiveTVRTR: {
            static NSDictionary<NSNumber *, NSNumber *> *s_vendors;
            static dispatch_once_t s_onceToken;
            dispatch_once(&s_onceToken, ^{
                s_vendors = @{ @(MediaListLiveTVSRF) : @(SRGVendorSRF),
                               @(MediaListLiveTVRTS) : @(SRGVendorRTS),
                               @(MediaListLiveTVRSI) : @(SRGVendorRSI),
                               @(MediaListLiveTVRTR) : @(SRGVendorRTR) };
            });
            
            NSNumber *vendorNumber = s_vendors[@(self.mediaList)];
            NSAssert(vendorNumber != nil, @"The business unit must be supported");
            request = [self.dataProvider tvLivestreamsForVendor:vendorNumber.integerValue withCompletionBlock:^(NSArray<SRGMedia *> * _Nullable medias, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
                completionBlock(medias, [SRGPage new] /* The request does not support pagination, but we need to return a page */, nil, HTTPResponse, error);
            }];
            break;
        }
            
        case MediaListLiveRadioSRF:
        case MediaListLiveRadioRTS:
        case MediaListLiveRadioRSI:
        case MediaListLiveRadioRTR: {
            static NSDictionary<NSNumber *, NSNumber *> *s_vendors;
            static dispatch_once_t s_onceToken;
            dispatch_once(&s_onceToken, ^{
                s_vendors = @{ @(MediaListLiveRadioSRF) : @(SRGVendorSRF),
                               @(MediaListLiveRadioRTS) : @(SRGVendorRTS),
                               @(MediaListLiveRadioRSI) : @(SRGVendorRSI),
                               @(MediaListLiveRadioRTR) : @(SRGVendorRTR) };
            });
            
            NSNumber *vendorNumber = s_vendors[@(self.mediaList)];
            NSAssert(vendorNumber != nil, @"The business unit must be supported");
            request = [self.dataProvider radioLivestreamsForVendor:vendorNumber.integerValue contentProviders:SRGContentProvidersAll withCompletionBlock:^(NSArray<SRGMedia *> * _Nullable medias, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
                completionBlock(medias, [SRGPage new] /* The request does not support pagination, but we need to return a page */, nil, HTTPResponse, error);
            }];
            break;
        }
            
        case MediaListLatestVideosSRF:
        case MediaListLatestVideosRTS:
        case MediaListLatestVideosRSI:
        case MediaListLatestVideosRTR:
        case MediaListLatestVideosSWI: {
            static NSDictionary<NSNumber *, NSNumber *> *s_vendors;
            static dispatch_once_t s_onceToken;
            dispatch_once(&s_onceToken, ^{
                s_vendors = @{ @(MediaListLatestVideosSRF) : @(SRGVendorSRF),
                               @(MediaListLatestVideosRTS) : @(SRGVendorRTS),
                               @(MediaListLatestVideosRSI) : @(SRGVendorRSI),
                               @(MediaListLatestVideosRTR) : @(SRGVendorRTR),
                               @(MediaListLatestVideosSWI) : @(SRGVendorSWI) };
            });
            
            NSNumber *vendorNumber = s_vendors[@(self.mediaList)];
            NSAssert(vendorNumber != nil, @"The business unit must be supported");
            request = [[self.dataProvider tvLatestMediasForVendor:vendorNumber.integerValue withCompletionBlock:completionBlock] requestWithPageSize:100];
            break;
        }
            
        case MediaListLatestAudiosSRF1:
        case MediaListLatestAudiosSRF2:
        case MediaListLatestAudiosSRF3:
        case MediaListLatestAudiosSRF4:
        case MediaListLatestAudiosSRF5:
        case MediaListLatestAudiosSRF6:
        case MediaListLatestAudiosRTS1:
        case MediaListLatestAudiosRTS2:
        case MediaListLatestAudiosRTS3:
        case MediaListLatestAudiosRTS4:
        case MediaListLatestAudiosRTS5:
        case MediaListLatestAudiosRSI1:
        case MediaListLatestAudiosRSI2:
        case MediaListLatestAudiosRSI3:
        case MediaListLatestAudiosRTR: {
            static NSDictionary<NSNumber *, NSNumber *> *s_vendors;
            static NSDictionary<NSNumber *, NSString *> *s_channels;
            static dispatch_once_t s_onceToken;
            dispatch_once(&s_onceToken, ^{
                s_vendors = @{ @(MediaListLatestAudiosSRF1) : @(SRGVendorSRF),
                               @(MediaListLatestAudiosSRF2) : @(SRGVendorSRF),
                               @(MediaListLatestAudiosSRF3) : @(SRGVendorSRF),
                               @(MediaListLatestAudiosSRF4) : @(SRGVendorSRF),
                               @(MediaListLatestAudiosSRF5) : @(SRGVendorSRF),
                               @(MediaListLatestAudiosSRF6) : @(SRGVendorSRF),
                               @(MediaListLatestAudiosRTS1) : @(SRGVendorRTS),
                               @(MediaListLatestAudiosRTS2) : @(SRGVendorRTS),
                               @(MediaListLatestAudiosRTS3) : @(SRGVendorRTS),
                               @(MediaListLatestAudiosRTS4) : @(SRGVendorRTS),
                               @(MediaListLatestAudiosRTS5) : @(SRGVendorRTS),
                               @(MediaListLatestAudiosRSI1) : @(SRGVendorRSI),
                               @(MediaListLatestAudiosRSI2) : @(SRGVendorRSI),
                               @(MediaListLatestAudiosRSI3) : @(SRGVendorRSI),
                               @(MediaListLatestAudiosRTR) : @(SRGVendorRTR) };
                s_channels = @{ @(MediaListLatestAudiosSRF1) : @"69e8ac16-4327-4af4-b873-fd5cd6e895a7",
                                @(MediaListLatestAudiosSRF2) : @"c8537421-c9c5-4461-9c9c-c15816458b46",
                                @(MediaListLatestAudiosSRF3) : @"dd0fa1ba-4ff6-4e1a-ab74-d7e49057d96f",
                                @(MediaListLatestAudiosSRF4) : @"ee1fb348-2b6a-4958-9aac-ec6c87e190da",
                                @(MediaListLatestAudiosSRF5) : @"a9c5c070-8899-46c7-ac27-f04f1be902fd",
                                @(MediaListLatestAudiosSRF6) : @"66815fe2-9008-4853-80a5-f9caaffdf3a9",
                                @(MediaListLatestAudiosRTS1) : @"a9e7621504c6959e35c3ecbe7f6bed0446cdf8da",
                                @(MediaListLatestAudiosRTS2) : @"a83f29dee7a5d0d3f9fccdb9c92161b1afb512db",
                                @(MediaListLatestAudiosRTS3) : @"8ceb28d9b3f1dd876d1df1780f908578cbefc3d7",
                                @(MediaListLatestAudiosRTS4) : @"f8517e5319a515e013551eea15aa114fa5cfbc3a",
                                @(MediaListLatestAudiosRTS5) : @"123456789101112131415161718192021222324x",
                                @(MediaListLatestAudiosRSI1) : @"rete-uno",
                                @(MediaListLatestAudiosRSI2) : @"rete-due",
                                @(MediaListLatestAudiosRSI3) : @"rete-tre",
                                @(MediaListLatestAudiosRTR) : @"12fb886e-b7aa-4e55-beb2-45dbc619f3c4" };
            });
            
            NSNumber *vendorNumber = s_vendors[@(self.mediaList)];
            NSString *channelId = s_channels[@(self.mediaList)];
            NSAssert(vendorNumber != nil, @"The business unit must be supported");
            NSAssert(channelId != nil, @"The channel id must not be null");
            request = [[self.dataProvider radioLatestMediasForVendor:vendorNumber.intValue channelUid:channelId withCompletionBlock:completionBlock] requestWithPageSize:100];
            break;
        }
            
        case MediaListLiveWebSRF:
        case MediaListLiveWebRTS:
        case MediaListLiveWebRSI:
        case MediaListLiveWebRTR: {
            static NSDictionary<NSNumber *, NSNumber *> *s_vendors;
            static dispatch_once_t s_onceToken;
            dispatch_once(&s_onceToken, ^{
                s_vendors = @{ @(MediaListLiveWebSRF) : @(SRGVendorSRF),
                               @(MediaListLiveWebRTS) : @(SRGVendorRTS),
                               @(MediaListLiveWebRSI) : @(SRGVendorRSI),
                               @(MediaListLiveWebRTR) : @(SRGVendorRTR) };
            });
            
            NSNumber *vendorNumber = s_vendors[@(self.mediaList)];
            NSAssert(vendorNumber != nil, @"The business unit must be supported");
            request = [[self.dataProvider tvScheduledLivestreamsForVendor:vendorNumber.integerValue withCompletionBlock:completionBlock] requestWithPageSize:100];
            break;
        }
            
        default:
            break;
    }
    
    [request resume];
    self.request = request;
}

#pragma mark UITableViewDataSource protocol

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.medias.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString * const kCellIdentifier = @"MediaListCell";
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (! cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kCellIdentifier];
    }
    
    return cell;
}

#pragma mark UITableViewDelegate protocol

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    SRGMedia *media = self.medias[indexPath.row];
    NSString *text = media.title;
    NSString *accessibilityLabelPrefix = @"";
    
    SRGTimeAvailability timeAvailability = [media timeAvailabilityAtDate:NSDate.date];
    if (timeAvailability == SRGTimeAvailabilityNotYetAvailable) {
        text = [@"🔜 " stringByAppendingString:text];
        accessibilityLabelPrefix = [LetterboxDemoAccessibilityLocalizedString(@"Soon", nil) stringByAppendingString:@" ,"];
    }
    else if (timeAvailability == SRGTimeAvailabilityNotAvailableAnymore) {
        text = [@"🔚 " stringByAppendingString:text];
        accessibilityLabelPrefix = [LetterboxDemoAccessibilityLocalizedString(@"Expired", nil) stringByAppendingString:@" ,"];
    }
    else if (media.contentType == SRGContentTypeLivestream || media.contentType == SRGContentTypeScheduledLivestream) {
        text = [@"⏺ " stringByAppendingString:text];
        accessibilityLabelPrefix = [LetterboxDemoAccessibilityLocalizedString(@"Live", nil) stringByAppendingString:@" ,"];
    }
    else {
        text = [@"▶️ " stringByAppendingString:text];
    }
    
    cell.textLabel.text = text;
    
#if TARGET_OS_TV
    if (media.contentType != SRGContentTypeLivestream) {
        NSString *dateString = [NSDateFormatter.letterbox_demo_relativeDateAndTimeFormatter stringFromDate:media.date];
        cell.detailTextLabel.text = dateString;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@%@, %@", accessibilityLabelPrefix, text, LetterboxDemoAccessibilityRelativeDateAndTimeFromDate(media.date)];
    }
    else {
        cell.detailTextLabel.text = nil;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@%@", accessibilityLabelPrefix, text];
    }
#endif
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *URN = self.medias[indexPath.row].URN;
    [self openPlayerWithURN:URN serviceURL:self.serviceURL];
}

#pragma mark Actions

- (void)refresh:(id)sender
{
    [self refresh];
}

@end
