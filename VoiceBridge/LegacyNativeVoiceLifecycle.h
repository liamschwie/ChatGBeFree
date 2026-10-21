#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Captures the legacy app's SwiftUI Voice presentation binding before its
/// overlay commits, allowing the replacement window to cover the first frame.
void LVBInstallLegacyNativeVoiceLifecycleBridge(void);

/// Ends the underlying Voice presentation by assigning nil to that binding.
BOOL LVBDismissUnderlyingLegacyVoiceMode(void);

NS_ASSUME_NONNULL_END
