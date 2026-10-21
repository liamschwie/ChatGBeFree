#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Flattens the current server-driven model/version/intelligence catalog into
/// the models/categories shape understood by the 2024 ChatGPT client.
NSDictionary *_Nullable CGBLegacyModelCatalog(NSDictionary *catalog,
                                               NSArray<NSDictionary *> *_Nullable *_Nullable summaryOut);

/// Resolves a synthetic legacy-picker model slug back to the real model slug,
/// thinking effort, and service tier expected by the current conversation API.
NSDictionary *_Nullable CGBConversationBodyByResolvingModelSelection(
    NSDictionary *body,
    NSDictionary *_Nullable *_Nullable selectionOut);

/// Performs the equivalent translation for the voice get-token request. The
/// current voice API accepts the real model slug and thinking effort as
/// separate fields, while the legacy UI can only carry one selected slug.
NSDictionary *_Nullable CGBVoiceBodyByResolvingModelSelection(
    NSDictionary *body,
    NSDictionary *_Nullable *_Nullable selectionOut);

/// Persists the currently advertised picker row whose display title appears
/// in a visible navigation label. This is used by the legacy picker runtime
/// bridge immediately after ModelContext.select(...) changes the selection.
BOOL CGBPersistPublishedModelSelectionMatchingVisibleText(NSString *text,
                                                           NSString *_Nullable *_Nullable displayOut);

#if defined(CGB_MODEL_SWITCHER_TESTING)
NSDictionary *_Nullable CGBTestingPersistedModelSelection(void);
void CGBTestingClearPersistedModelSelection(void);
BOOL CGBTestingDecodeLegacyModelSlug(NSString *slug,
                                     NSString *_Nullable *_Nullable modelOut,
                                     NSString *_Nullable *_Nullable thinkingEffortOut,
                                     NSString *_Nullable *_Nullable serviceTierOut);
#endif

NS_ASSUME_NONNULL_END
