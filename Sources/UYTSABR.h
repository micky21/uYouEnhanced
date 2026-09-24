#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Modern YouTube (21.29.3+) stops returning any stream URL - plain or
// signatureCipher - for most/all adaptive formats. Confirmed on-device via
// [UYTPipeline] logs: DownloadPipeline.xm's innertube fetch and
// YTSigDecipher's signatureCipher resolution both come back with zero
// formats. Media instead flows through SABR (server-driven adaptive
// bitrate) over the UMP binary protocol.
//
// This does not try to independently re-derive a playback URL. Instead it
// captures the app's OWN live, already-signed `videoplayback` request (the
// one YouTube's real player issues when a video is actually played) and
// replays modified copies of it to pull the video/audio tracks directly,
// then hands the resulting raw track files to UYTMergeAudioVideo (see
// uYouPatches.h) for muxing - reusing the AVFoundation merge already built
// for the mp4+webm merge-hang fix instead of adding a new dependency
// (the reference implementation this was ported from uses FFmpegKitNext,
// which this repo does not vendor).
//
// Precondition: the user must have played the target video for at least a
// few seconds before requesting the download, so the capture hook below has
// something to work with. There is no per-video binding on the capture -
// it is always "whichever videoplayback request was captured most
// recently" - so downloading a different video than the one just played
// will use stale, likely-wrong data. This mirrors the reference
// implementation's own behavior, not a limitation introduced here.
//
// Ported from aricloverEXTRA/uYou-3.0.4-SOURCE (Classes/Core/Downloads/UYTSABR.xm),
// which the uYouEnhanced maintainer indicated is their intended fix for this
// exact problem. Not build-tested locally (no Theos toolchain) - needs a
// real device log to confirm the capture hook actually fires and the
// UMP/protobuf parsing matches what today's YouTube app sends.

// Where a finished SABR download lands before the caller moves it into
// uYou's own expected location (uYouItem -filePath).
NSString *UYTSABROutputPathForVideoID(NSString *videoID, BOOL audioOnly);

// True once a usable (non-expired) live videoplayback request has been
// captured by the HAMDataLoadRequest hook below.
BOOL UYTSABRHasValidCapture(void);

// Entry point: attempts a full SABR-based download for videoID, writing the
// final muxed file to Documents/Downloaded/<videoID>.mp4 - the same path
// UYTArmStallWatchdog and UYTFallbackToVideoOnly (uYouPatches.xm) already
// poll for, so no new "download finished" signaling path is needed; the
// watchdog already armed around uYou's own merge hooks picks this up.
// Pass audioOnly:YES to skip the video track entirely.
//
// progress (optional, may be nil) is called on the main queue as segments
// arrive, with fractionComplete in [0,1] - derived from UMP's own
// downloadedMs/endTimeMs per track (time-based; SABR has no upfront
// Content-Length to compute a byte-based percentage from) - and
// bytesDownloaded, the real running total across both tracks so far (used
// to derive a formatted size/speed estimate for uYou's own DownloadItem UI
// fields, since those need actual numbers, not just a fraction). If several
// DownloadItems are waiting on the same in-flight videoID (see
// gInFlightCompletions in UYTSABR.xm), every one of their progress blocks
// gets called, not just the first caller's.
void UYTSABRFallbackDownloadForVideoID(NSString *videoID,
                                       BOOL audioOnly,
                                       void (^_Nullable progress)(double fractionComplete, unsigned long long bytesDownloaded),
                                       void (^completion)(BOOL success, NSString * _Nullable error));

NS_ASSUME_NONNULL_END
