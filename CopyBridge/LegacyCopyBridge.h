#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Removes renderer-only characters that should never escape into the user's
/// clipboard while preserving ordinary Unicode, emoji, whitespace, and code.
FOUNDATION_EXPORT NSString *CGBNormalizedCopiedText(NSString *text);

/// Installs a narrowly scoped replacement for the legacy OAIMarkdown
/// UITextView's broken rich-text copy action.
FOUNDATION_EXPORT void CGBInstallLegacyCopyBridge(void);

NS_ASSUME_NONNULL_END
