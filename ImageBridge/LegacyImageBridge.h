#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES only for the generated-asset scheme introduced after the
/// legacy client was released.
FOUNDATION_EXPORT BOOL CGBIsSedimentAssetURL(NSURL * _Nullable URL);

/// Preserves the authority, path, query, and fragment while replacing the
/// modern `sediment` scheme with the legacy app's `file-service` scheme.
FOUNDATION_EXPORT NSURL * _Nullable CGBLegacyFileServiceURLForSedimentURL(
    NSURL * _Nullable URL);

/// A redacted description suitable for diagnostics. It intentionally omits
/// file IDs, signed query values, and the complete URL.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CGBSafeAssetURLSummary(
    NSURL * _Nullable URL);

/// Extracts only image-related structural information from a decoded SSE
/// object. User text, URLs, IDs, and metadata values are never returned.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
CGBSafeImageEventSummary(id _Nullable object);

/// Rewrites generated-image payloads into the shape understood by the 2024
/// client. Only verified image-tool messages are changed from `tool` to
/// `assistant`, and only `sediment:` asset URLs are changed to `file-service:`.
/// The returned object is immutable and the input is never mutated.
FOUNDATION_EXPORT id _Nullable CGBLegacyImageCompatibleObject(
    id _Nullable object,
    NSUInteger * _Nullable assetURLRewriteCount,
    NSUInteger * _Nullable imageMessageRewriteCount);

/// Returns YES for the modern asynchronous image-turn markers. A generic
/// async status alone is intentionally insufficient because ordinary thinking
/// turns can use the same transport.
FOUNDATION_EXPORT BOOL CGBImageEventIndicatesAsyncGeneration(id _Nullable object);

/// Extracts the non-sensitive identifiers needed to follow an asynchronous
/// image turn. Values are returned only when they are short safe identifiers.
FOUNDATION_EXPORT NSString * _Nullable CGBConversationIdentifierFromImageEvent(
    id _Nullable object);
FOUNDATION_EXPORT NSString * _Nullable CGBImageTurnExchangeIdentifierFromEvent(
    id _Nullable object);

/// Finds completed generated-image messages in a conversation-detail payload,
/// optionally restricted to the current turn and creation time. Each returned
/// message has already been converted for the legacy assistant renderer.
FOUNDATION_EXPORT NSArray<NSDictionary *> *CGBLegacyGeneratedImageMessages(
    NSDictionary * _Nullable conversation,
    NSString * _Nullable turnExchangeIdentifier,
    NSTimeInterval notBeforeCreateTime);

NS_ASSUME_NONNULL_END
