// DownloadPipeline.xm — modern stream fetcher for YouTube 21.14.4+ (iOS 16–26).
// Design doc: Docs/DownloadPipeline.md
// Phase 1 scaffold: innertube player request + format selection.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "YTSigDecipher.h"
#import "UYTSABR.h"
#import "UYTDownloadsDB.h"

@interface DownloadsManager : NSObject
+ (instancetype)sharedInstance;
@end

@interface AFHTTPSessionManager : NSObject
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                             progress:(void (^)(NSProgress *progress))progressPtr
                                          destination:(NSURL *(^)(NSURL *targetPath, NSURLResponse *response))destination
                                    completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler;
@end

@interface DownloadItem : NSObject
@property (nonatomic, strong) NSString *videoID;
@property (nonatomic, strong) NSString *filePath;
- (void)setRemoteURL:(NSURL *)url;
@end

static NSString * const UYTInnertubeURL = @"https://www.youtube.com/youtubei/v1/player?key=AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc";
static NSString * const UYTClientVersion = @"19.45.1";

@interface UYTStreamFormat : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, assign) NSInteger itag;
@property (nonatomic, copy) NSString *mimeType;   // e.g. "video/mp4"
@property (nonatomic, assign) BOOL hasVideo;
@property (nonatomic, assign) BOOL hasAudio;
@property (nonatomic, assign) long long bitrate;
@property (nonatomic, copy) NSString *qualityLabel;
@end

@implementation UYTStreamFormat
@end

@interface UYTDownloadPipeline : NSObject
+ (void)fetchFormatsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<UYTStreamFormat *> *formats, NSError *error))completion;
+ (UYTStreamFormat *)streamFormatFromDict:(NSDictionary *)f url:(NSString *)url;
+ (UYTStreamFormat *)bestMuxedFormat:(NSArray<UYTStreamFormat *> *)formats;
+ (UYTStreamFormat *)bestAudioFormat:(NSArray<UYTStreamFormat *> *)formats;
@end

@implementation UYTDownloadPipeline

+ (NSDictionary *)clientContext {
    return @{@"context": @{@"client": @{
        @"clientName": @"IOS",
        @"clientVersion": UYTClientVersion,
        @"deviceMake": @"Apple",
        @"deviceModel": @"iPhone16,2",
        @"osName": @"iOS",
        @"osVersion": @"18.5.0.22F76",
        @"hl": @"en",
        @"timeZone": @"UTC",
        @"utcOffsetMinutes": @0
    }},
    @"contentCheckOk": @YES,
    @"racyCheckOk": @YES};
}

+ (void)fetchFormatsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<UYTStreamFormat *> *, NSError *))completion {
    NSMutableDictionary *body = [[self clientContext] mutableCopy];
    body[@"videoId"] = videoID;
    body[@"playbackContext"] = @{@"contentPlaybackContext": @{@"html5Preference": @"HTML5_PREF_WANTS"}};

    NSURL *url = [NSURL URLWithString:UYTInnertubeURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"com.google.ios.youtube/19.45.1 (iPhone16,2; U; CPU iOS 18_5_0 like Mac OS X;)" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err || !data) {
                completion(@[], err ?: [NSError errorWithDomain:@"UYTDownload" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"empty response"}]);
                return;
            }
            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (!json) {
                completion(@[], jsonErr);
                return;
            }
            NSArray *streams = json[@"streamingData"][@"adaptiveFormats"];
            NSArray *muxed = json[@"streamingData"][@"formats"];
            NSMutableArray<UYTStreamFormat *> *out = [NSMutableArray array];
            NSMutableArray<NSDictionary *> *ciphered = [NSMutableArray array];
            for (NSArray *list in @[streams ?: @[], muxed ?: @[]]) {
                for (NSDictionary *f in list) {
                    NSString *u = f[@"url"];
                    if (u) {
                        [out addObject:[self streamFormatFromDict:f url:u]];
                        continue;
                    }
                    // No plain url: YouTube gated this format behind a
                    // signatureCipher. Resolve those as a batch below instead
                    // of dropping them (was: `continue` - silently discarded
                    // every format whenever ALL of them were ciphered, which
                    // left `out` empty and produced NSURLErrorUnsupportedURL
                    // (-1002) downstream once uYou's own broken native
                    // extraction was the only thing left to fall back to).
                    NSString *cipher = f[@"signatureCipher"] ?: f[@"cipher"];
                    if (cipher) [ciphered addObject:f];
                }
            }

            if (ciphered.count == 0) {
                completion(out, nil);
                return;
            }

            [UYTSigDecipher playerContextForVideoID:videoID completion:^(UYTPlayerJSContext *player, NSError *sigErr) {
                if (!player) {
                    NSLog(@"[UYTPipeline] signature decipher unavailable for %@ (%@); %lu ciphered format(s) dropped",
                          videoID, sigErr.localizedDescription, (unsigned long)ciphered.count);
                    completion(out, nil);
                    return;
                }
                NSUInteger deciphered = 0;
                for (NSDictionary *f in ciphered) {
                    NSString *cipher = f[@"signatureCipher"] ?: f[@"cipher"];
                    NSString *resolved = [UYTSigDecipher resolveURLFromSignatureCipher:cipher usingPlayer:player];
                    if (resolved) {
                        [out addObject:[self streamFormatFromDict:f url:resolved]];
                        deciphered++;
                    }
                }
                NSLog(@"[UYTPipeline] deciphered %lu/%lu ciphered format(s) for %@",
                      (unsigned long)deciphered, (unsigned long)ciphered.count, videoID);
                completion(out, nil);
            }];
        }];
    [task resume];
}

+ (UYTStreamFormat *)streamFormatFromDict:(NSDictionary *)f url:(NSString *)url {
    UYTStreamFormat *sf = [[UYTStreamFormat alloc] init];
    sf.url = url;
    sf.itag = [f[@"itag"] integerValue];
    sf.mimeType = f[@"mimeType"];
    sf.bitrate = [f[@"bitrate"] longLongValue];
    sf.qualityLabel = f[@"qualityLabel"];
    sf.hasVideo = [sf.mimeType hasPrefix:@"video"];
    sf.hasAudio = [sf.mimeType hasPrefix:@"audio"] || ([sf.mimeType hasPrefix:@"video"] && ![f objectForKey:@"qualityLabel"]);
    return sf;
}

+ (UYTStreamFormat *)bestMuxedFormat:(NSArray<UYTStreamFormat *> *)formats {
    UYTStreamFormat *best = nil;
    for (UYTStreamFormat *f in formats)
        if (f.hasVideo && f.hasAudio && (!best || f.bitrate > best.bitrate)) best = f;
    return best;
}

+ (UYTStreamFormat *)bestAudioFormat:(NSArray<UYTStreamFormat *> *)formats {
    UYTStreamFormat *best = nil;
    for (UYTStreamFormat *f in formats)
        if (f.hasAudio && !f.hasVideo && [f.mimeType containsString:@"mp4"]
            && (!best || f.bitrate > best.bitrate)) best = f;
    return best;
}

@end

// --- Wiring: fix uYou's stream URLs at the DownloadItem level ---------------

// Store resolved URLs keyed by videoID so the DownloadItem hook can swap them.
static NSMutableDictionary<NSString *, NSString *> *UYTResolvedURLs;

static void UYTStoreResolvedURL(NSString *vid, NSString *url) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UYTResolvedURLs = [NSMutableDictionary dictionary];
    });
    if (vid.length && url.length) UYTResolvedURLs[vid] = url;
}

static NSString *UYTGetResolvedURL(NSString *vid) {
    return UYTResolvedURLs[vid] ?: nil;
}

// --- DB integration (reserved for future use) --------------------------------
// With the URL-swap approach, uYou's native flow handles DB insertion when
// given valid stream URLs. This section is kept for reference but the
// standalone insert function was removed to fix -Wunused-function.
// Schema for future re-use:
//   CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY, videoID TEXT,
//   title TEXT, channel TEXT, channelURL TEXT, qualityLabel TEXT,
//   typeAndQuality TEXT, size TEXT, duration TEXT, type TEXT, path TEXT,
//   lyrics TEXT, timestamp DATETIME)
//   DB path: Documents/uyoudb.sqlite (or AppGroup/uyoudb.sqlite)

%hook DownloadsManager
- (void)getLinksLocallyPlayerItem:(id)item videoID:(id)videoID sourceView:(id)sourceView isShorts:(BOOL)isShorts {
    NSString *vid = [NSString stringWithFormat:@"%@", videoID];

    // Pre-fetch working stream URLs via innertube BEFORE %orig runs.
    [UYTDownloadPipeline fetchFormatsForVideoID:vid completion:^(NSArray<UYTStreamFormat *> *formats, NSError *error) {
        if (error || formats.count == 0) {
            NSLog(@"[UYTPipeline] no formats for %@ (%@)", vid, error.localizedDescription);
            // Modern YouTube (21.29.3+) returns no stream URL at all - plain
            // or signatureCipher - for this client context; innertube alone
            // can't get us anything. The actual SABR fallback trigger and
            // completion handling lives in DownloadItem -setRemoteURL: below,
            // where we have a reference to the specific DownloadItem to drive
            // to completion - triggering it here was a dead end: %orig's own
            // broken native flow fails with NSURLErrorUnsupportedURL (-1002)
            // near-instantly (confirmed on-device: error shown before this
            // method's own 1.5s %orig delay even elapses), long before SABR
            // (confirmed ~48s for a real download) has anything to hand back,
            // and nothing here has a way to signal a DownloadItem that
            // doesn't exist yet.
            return;
        }
        UYTStreamFormat *best = [UYTDownloadPipeline bestMuxedFormat:formats];
        if (best.url.length) {
            UYTStoreResolvedURL(vid, best.url);
            NSLog(@"[UYTPipeline] cached working URL for %@ (itag=%ld)", vid, (long)best.itag);
        }
    }];

    // Give the async fetch a moment, then let %orig proceed — the DownloadItem
    // hook below will swap any broken URL with our cached working one.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        %orig;
    });
}
%end

// Intercept DownloadItem URL assignment — swap broken extraction URLs with
// our working innertube-fetched ones so uYou's native download flow functions.
%hook DownloadItem
- (void)setRemoteURL:(NSURL *)url {
    NSString *vid = self.videoID ?: @"";
    NSString *working = UYTGetResolvedURL(vid);
    if (working.length) {
        NSURL *fixed = [NSURL URLWithString:working];
        if (fixed) {
            NSLog(@"[UYTPipeline] swapped broken URL -> working innertube URL for %@", vid);
            %orig(fixed);
            return;
        }
    }

    // No working innertube URL for this video (modern YouTube returns none
    // at all for our client context - see getLinksLocallyPlayerItem: above).
    // Calling %orig(url) here hands uYou's native flow whatever broken URL
    // it extracted itself, which fails almost instantly with
    // NSURLErrorUnsupportedURL (-1002) - confirmed on-device, the error
    // shows before SABR (which takes ~48s for a real download) could ever
    // hand anything back. Skip %orig entirely in that case and drive THIS
    // SAME DownloadItem to completion ourselves once SABR finishes, instead
    // of relying on the merge-hook watchdog (uYouPatches.xm) that never gets
    // armed because the flow never reaches the merge stage without a
    // successful initial download.
    if (UYTSABRHasValidCapture()) {
        NSLog(@"[UYTPipeline] no working URL for %@, driving via SABR instead of uYou's native flow", vid);
        __weak DownloadItem *weakSelf = self;
        // uyouItem was already created by uYou's own earlier flow (before we
        // intercept here) with real metadata from the YouTube page - grab it
        // via KVC since this file's own minimal DownloadItem interface
        // doesn't declare a typed uYouItem property.
        id uyouItem = nil;
        @try { uyouItem = [self valueForKey:@"uYouItem"]; } @catch (NSException *e) {}
        NSString *title = nil, *channel = nil, *qualityLabel = nil, *typeAndQuality = nil;
        @try {
            title = [uyouItem valueForKey:@"title"];
            channel = [uyouItem valueForKey:@"channel"];
            qualityLabel = [uyouItem valueForKey:@"qualityLabel"];
            typeAndQuality = [uyouItem valueForKey:@"typeAndQuality"];
        } @catch (NSException *e) {}

        // Reuse uYou's OWN progress plumbing instead of building custom UI.
        // An earlier attempt here set a `downloadProgress` NSProgress
        // property that doesn't actually exist on this class - it silently
        // no-op'd through the @try/@catch around setValue:forKey:, which is
        // why the UI never moved. Confirmed via otool -ov class-dump of the
        // real uYou.dylib in this build what DownloadItem actually has:
        //   float     progress          (0.0-1.0)
        //   NSString *totalSize         (pre-formatted, e.g. "45.2 MB")
        //   NSString *downloadedSize    (pre-formatted)
        //   NSString *speed             (pre-formatted, e.g. "1.2 MB/s")
        //   int       remainingTime     (seconds)
        // DownloadingCell/DownloadingInfoButton read these directly and
        // refresh off a "downloadProgressChangedNotification" post - same
        // notification name confirmed via strings, reused as-is.
        NSDate *sabrStartDate = [NSDate date];
        NSByteCountFormatter *sabrByteFmt = [NSByteCountFormatter new];
        sabrByteFmt.countStyle = NSByteCountFormatterCountStyleFile;

        UYTSABRFallbackDownloadForVideoID(vid, NO, ^(double frac, unsigned long long bytesDownloaded) {
            DownloadItem *progressSelf = weakSelf;
            if (!progressSelf) return;
            NSTimeInterval elapsed = -[sabrStartDate timeIntervalSinceNow];
            // SABR gives no upfront Content-Length - estimate a moving total
            // from bytes-so-far/fraction-so-far, same technique most download
            // UIs use when the real total isn't known ahead of time.
            NSString *downloadedStr = [sabrByteFmt stringFromByteCount:(long long)bytesDownloaded];
            NSString *totalStr = (frac > 0.02) ? [sabrByteFmt stringFromByteCount:(long long)(bytesDownloaded / frac)] : nil;
            double bytesPerSec = (elapsed > 0.5) ? (double)bytesDownloaded / elapsed : 0;
            NSString *speedStr = (bytesPerSec > 0) ? [NSString stringWithFormat:@"%@/s", [sabrByteFmt stringFromByteCount:(long long)bytesPerSec]] : nil;
            int remaining = (frac > 0.02 && elapsed > 0.5) ? (int)(elapsed / frac * (1.0 - frac)) : 0;
            @try {
                [progressSelf setValue:@(frac) forKey:@"progress"];
                if (downloadedStr) [progressSelf setValue:downloadedStr forKey:@"downloadedSize"];
                if (totalStr) [progressSelf setValue:totalStr forKey:@"totalSize"];
                if (speedStr) [progressSelf setValue:speedStr forKey:@"speed"];
                [progressSelf setValue:@(remaining) forKey:@"remainingTime"];
            } @catch (NSException *e) {}
            [[NSNotificationCenter defaultCenter] postNotificationName:@"downloadProgressChangedNotification" object:progressSelf];
        }, ^(BOOL success, NSString *sabrErr) {
            NSLog(@"[UYTPipeline] SABR fallback for %@: %@", vid, success ? @"succeeded" : sabrErr);
            if (!success) return;
            DownloadItem *strongSelf = weakSelf;
            if (!strongSelf) {
                NSLog(@"[UYTPipeline] DownloadItem for %@ deallocated before SABR finished", vid);
                return;
            }
            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *sabrPath = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"Downloaded/%@.mp4", vid]];

            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:sabrPath error:nil];
            unsigned long long fileSize = [attrs[NSFileSize] unsignedLongLongValue];
            NSTimeInterval duration = 0;
            @try {
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sabrPath] options:nil];
                duration = CMTimeGetSeconds(asset.duration);
                if (isnan(duration) || isinf(duration)) duration = 0;
            } @catch (NSException *e) {}

            // uYou's own "Downloaded" tab reads from uyoudb.sqlite, not the
            // filesystem - without this row the file exists but the app has
            // no idea it's there. Schema/INSERT confirmed via strings on the
            // real uYou.dylib binary (see UYTDownloadsDB.h).
            UYTDownloadsDBInsertCompleted(vid, title, channel, nil, qualityLabel, typeAndQuality,
                                           fileSize, duration, @"video", sabrPath);

            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.filePath = sabrPath;
                @try {
                    [strongSelf setValue:@1.0f forKey:@"progress"];
                    [strongSelf setValue:[sabrByteFmt stringFromByteCount:(long long)fileSize] forKey:@"totalSize"];
                    [strongSelf setValue:[sabrByteFmt stringFromByteCount:(long long)fileSize] forKey:@"downloadedSize"];
                    [strongSelf setValue:@0 forKey:@"remainingTime"];
                } @catch (NSException *e) {}
                [[NSNotificationCenter defaultCenter] postNotificationName:@"downloadProgressChangedNotification" object:strongSelf];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"downloadDidCompleteNotification" object:strongSelf];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"conversionDidCompleteNotification" object:strongSelf];
            });
        });
        return; // do NOT call %orig - that's what produces the instant -1002
    }

    NSLog(@"[UYTPipeline] no working URL and no SABR capture for %@ - falling through to uYou's native flow (will likely fail)", vid);
    %orig;
}
%end

%ctor {
    %init;
}
