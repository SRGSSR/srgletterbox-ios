//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "FeedsViewController.h"

#import "FeedTableViewCell.h"
#import "NSBundle+LetterboxDemo.h"
#import "SettingsViewController.h"

#import <SRGDataProvider/SRGDataProvider.h>
#import <SRGLetterbox/SRGLetterbox.h>

@interface FeedsViewController ()

@property (nonatomic) NSArray<SRGMedia *> *medias;

@property (nonatomic) SRGDataProvider *dataProvider;
@property (nonatomic, weak) SRGRequest *request;

@end

@implementation FeedsViewController

#pragma mark Object lifecycle

- (instancetype)init
{
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:LetterboxDemoResourceNameForUIClass(self.class) bundle:nil];
    return [storyboard instantiateInitialViewController];
}

#pragma mark View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applicationDidBecomeActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
    
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self updateAudioSession];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    if (self.movingFromParentViewController || self.beingDismissed) {
        [self.request cancel];
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:0 error:NULL];
    }
}

#pragma mark Setters

- (void)setFeed:(Feed)feed
{
    _feed = feed;
    
    switch (feed) {
        case FeedSRFTrendingMedias: {
            self.title = NSLocalizedString(@"SRF trending videos", nil);
            break;
        }
            
        case FeedRTSTrendingMedias: {
            self.title = NSLocalizedString(@"RTS trending videos", nil);
            break;
        }
            
        case FeedRSITrendingMedias: {
            self.title = NSLocalizedString(@"RSI trending videos", nil);
            break;
        }
            
        default: {
            self.title = nil;
            break;
        }
    }
    
    if (self.viewLoaded) {
        [self refresh];
    }
}

#pragma mark Data

- (void)refresh
{
    [self.request cancel];
    self.request = nil;
    
    self.medias = nil;
    [self.tableView reloadData];
    
    self.dataProvider = [[SRGDataProvider alloc] initWithServiceURL:ApplicationSettingServiceURL()];
    self.dataProvider.globalParameters = ApplicationSettingGlobalParameters();
    
    SRGMediaListCompletionBlock completionBlock = ^(NSArray<SRGMedia *> * _Nullable medias, NSHTTPURLResponse * _Nullable HTTPResponse, NSError * _Nullable error) {
        self.medias = medias;
        [self.tableView reloadData];
    };
    
    static dispatch_once_t s_onceToken;
    static NSDictionary<NSNumber *, NSNumber *> *s_vendors;
    dispatch_once(&s_onceToken, ^{
        s_vendors = @{ @(FeedRSITrendingMedias) : @(SRGVendorRSI),
                       @(FeedRTSTrendingMedias) : @(SRGVendorRTS),
                       @(FeedSRFTrendingMedias) : @(SRGVendorSRF) };
    });
    
    SRGVendor vendor = [s_vendors[@(self.feed)] integerValue];
    SRGRequest *request = [self.dataProvider tvTrendingMediasForVendor:vendor withLimit:@50 completionBlock:completionBlock];
    [request resume];
    self.request = request;
}

#pragma mark Audio session

- (void)updateAudioSession
{
    __block BOOL silent = YES;
    [self.tableView.visibleCells enumerateObjectsUsingBlock:^(__kindof FeedTableViewCell * _Nonnull cell, NSUInteger idx, BOOL * _Nonnull stop) {
        if (! cell.muted) {
            silent = NO;
        }
    }];
    
    if (silent) {
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:NULL];
    }
    else {
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback withOptions:0 error:NULL];
    }
}

#pragma mark UITableViewDataSource protocol

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.medias.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return [tableView dequeueReusableCellWithIdentifier:NSStringFromClass(FeedTableViewCell.class)];
}

#pragma mark UITableViewDelegate protocol

- (void)tableView:(UITableView *)tableView willDisplayCell:(FeedTableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    static dispatch_once_t s_onceToken;
    static NSDictionary<NSNumber *, NSString *> *s_localizations;
    dispatch_once(&s_onceToken, ^{
        s_localizations = @{ @(FeedRSITrendingMedias) : @"it",
                             @(FeedRTSTrendingMedias) : @"fr",
                             @(FeedSRFTrendingMedias) : @"de" };
    });
    
    [cell setMedia:self.medias[indexPath.row] withPreferredSubtitleLocalization:s_localizations[@(self.feed)]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    FeedTableViewCell *selectedCell = [tableView cellForRowAtIndexPath:indexPath];
    selectedCell.muted = ! selectedCell.muted;
    
    [tableView.visibleCells enumerateObjectsUsingBlock:^(__kindof FeedTableViewCell * _Nonnull cell, NSUInteger idx, BOOL * _Nonnull stop) {
        if (! [cell isEqual:selectedCell]) {
            cell.muted = YES;
        }
    }];
    
    [self updateAudioSession];
    
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(FeedTableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [cell setMedia:nil withPreferredSubtitleLocalization:nil];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return CGRectGetWidth(tableView.frame) * 9.f / 16.f;
}

#pragma mark Notifications

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self updateAudioSession];
    [self.tableView reloadData];
}

@end
