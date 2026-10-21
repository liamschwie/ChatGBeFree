#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the iOS 16-compatible WebRTC voice transport using the authenticated
/// headers and voice selection from the retired LiveKit token request.
void LVBRealtimeVoiceStart(NSURLRequest *request,
                           NSDictionary<NSString *, id> *requestBody);

/// Covers the legacy SwiftUI voice presentation immediately when the app's
/// original voice action is invoked, before its authenticated request arrives.
void LVBRealtimeVoicePrepareForLegacyStart(void);

/// Routes realtime transport diagnostics through LegacyVoiceBridge's redacted
/// on-device log.
void LVBRealtimeVoiceLog(NSString *message);

NS_ASSUME_NONNULL_END
