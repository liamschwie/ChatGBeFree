#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Mirrors the offer transform used by the current ChatGPT voice runtime. It
// adds the codec feedback line required by the consumer Realtime endpoint.
FOUNDATION_EXPORT NSString *LVBTransformRealtimeOfferSDP(
    NSString *offerSDP,
    NSString * _Nullable * _Nullable opusPayloadType);

// Diagnostic helper that reports only a count; candidate contents stay out of
// the bridge log.
FOUNDATION_EXPORT NSUInteger LVBSDPCandidateCount(NSString *offerSDP);

// Structural diagnostics that deliberately omit candidate addresses, ICE
// credentials, fingerprints, track ids, and raw SDP.
FOUNDATION_EXPORT NSString *LVBSDPMediaKindsSummary(NSString *offerSDP);
FOUNDATION_EXPORT NSUInteger LVBSDPBundleMIDCount(NSString *offerSDP);

NS_ASSUME_NONNULL_END
