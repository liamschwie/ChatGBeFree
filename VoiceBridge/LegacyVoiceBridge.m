#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

#import "LegacyRealtimeVoice.h"
#import "LegacyNativeVoiceLifecycle.h"
#import "../CopyBridge/LegacyCopyBridge.h"
#import "../ImageBridge/LegacyImageBridge.h"
#import "../ModelSwitcher/LegacyModelSwitcher.h"
#import "../ModelSwitcher/LegacyModelSelectionPersistence.h"

static NSString *const LVBVersion = @"1.2026.202";
static NSString *const LVBBuild = @"30140022279";
static NSString *const LVBRevision = @"2026.09.04-chatgbefree-r9-production-refactor";
static NSString *const LVBHandledRequestKey = @"com.local.LegacyVoiceBridge.handled";
static NSString *const LVBAppAttestHeader = @"X-Sentinel-Payload";

static dispatch_queue_t LVBLogQueue;
static NSString *LVBChatreqToken;
static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *LVBModeCatalog;
static NSString *LVBStatusDefaultMode;
static BOOL LVBPreferStatusAttestUnavailableSentinel;
static NSBundle *LVBMainBundle;
static NSURL *LVBLastAPIOrigin;
static NSString *LVBLastAPIBasePath;
static NSDictionary<NSString *, NSString *> *LVBLastAPIAssetHeaders;
static const void *LVBFileServiceBridgeAssociationKey =
    &LVBFileServiceBridgeAssociationKey;
static void (*LVBOriginalFileServiceStartLoading)(id, SEL);
static void (*LVBOriginalFileServiceStopLoading)(id, SEL);
static BOOL LVBFileServiceInterpositionInstalled;

typedef NS_ENUM(NSUInteger, LVBEndpointKind) {
    LVBEndpointNone = 0,
    LVBEndpointVoiceStatus,
    LVBEndpointGetToken,
    LVBEndpointModels,
    LVBEndpointConversation,
    LVBEndpointConversationDetail,
    LVBEndpointImageAsset,
};

@interface LVBVoiceURLProtocol : NSURLProtocol <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSURLSession *forwardingSession;
@property(nonatomic, strong) NSURLSessionDataTask *forwardingTask;
@property(nonatomic) LVBEndpointKind endpointKind;
@property(nonatomic, strong) NSHTTPURLResponse *streamingHTTPResponse;
@property(nonatomic) NSUInteger streamedByteCount;
@property(nonatomic, strong) NSMutableData *conversationSSEBuffer;
@property(nonatomic, strong) NSMutableSet<NSString *> *loggedImageEventSummaries;
@property(nonatomic) BOOL conversationDetectedAsyncImage;
@property(nonatomic) BOOL conversationSawImageOutput;
@property(nonatomic) BOOL conversationHeldDone;
@property(nonatomic) BOOL conversationTransportCompleted;
@property(nonatomic, strong) NSError *conversationTransportError;
@property(nonatomic, copy) NSString *conversationIdentifier;
@property(nonatomic, copy) NSString *imageTurnExchangeIdentifier;
@property(nonatomic) NSTimeInterval conversationStartedAt;
@property(nonatomic) NSUInteger imagePollAttempt;
@property(nonatomic, strong) NSURLSession *imagePollingSession;
@property(nonatomic, strong) NSURLSessionDataTask *imagePollingTask;
@property(nonatomic, strong) NSMutableSet<NSString *> *deliveredImageMessageIdentifiers;
@property(nonatomic) BOOL completedClient;
@property(nonatomic) BOOL attemptedStatusAttestFallback;
@property(nonatomic) BOOL attemptedCurrentModeTokenFallback;
@property(nonatomic) BOOL attemptedStandardModeTokenFallback;
@property(nonatomic) BOOL stopped;
@property(nonatomic, strong) NSData *initialStatusData;
@property(nonatomic, strong) NSURLResponse *initialStatusResponse;
@property(nonatomic, strong) NSError *initialStatusError;
@property(nonatomic, strong) NSData *initialGetTokenData;
@property(nonatomic, strong) NSURLResponse *initialGetTokenResponse;
@property(nonatomic, strong) NSError *initialGetTokenError;
- (void)lvb_startForwardingRequest:(NSURLRequest *)forwarded attempt:(NSString *)attempt;
- (void)lvb_startImageAssetResolution;
- (void)lvb_fetchSignedImageURL:(NSURL *)URL;
- (void)lvb_beginImagePollingIfNeeded;
- (void)lvb_finishStreamingConversationWithError:(NSError *)error;
@end

static NSString *LVBLogFilePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"LegacyVoiceBridge.log"];
}

static void LVBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *LVBJSONString(id object);
static NSString *LVBNormalizedKey(NSString *key);

static void LVBLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    dispatch_queue_t queue = LVBLogQueue;
    if (!queue) {
        NSLog(@"[LegacyVoiceBridge] %@", message);
        return;
    }
    dispatch_async(queue, ^{
        // NSLog can synchronously contact the system logger and was visible in
        // the voice-button hot path on older devices. Keep logging ordered,
        // but never make UI work wait for it.
        NSLog(@"[LegacyVoiceBridge] %@", message);
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = LVBLogFilePath();
        NSFileManager *manager = NSFileManager.defaultManager;
        if (![manager fileExistsAtPath:path]) {
            [manager createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    });
}

void LVBRealtimeVoiceLog(NSString *message) {
    LVBLog(@"realtime %@", message ?: @"(no message)");
}

static BOOL LVBIsOpenAIHost(NSString *host) {
    NSString *lowercaseHost = host.lowercaseString ?: @"";
    return [lowercaseHost isEqualToString:@"openai.com"] ||
           [lowercaseHost hasSuffix:@".openai.com"] ||
           [lowercaseHost isEqualToString:@"chatgpt.com"] ||
           [lowercaseHost hasSuffix:@".chatgpt.com"];
}

static void LVBRememberAuthenticatedAPIContext(NSURLRequest *request) {
    NSURL *URL = request.URL;
    if (!LVBIsOpenAIHost(URL.host) || URL.scheme.length == 0 || URL.host.length == 0) {
        return;
    }
    NSURLComponents *originComponents = [[NSURLComponents alloc] init];
    originComponents.scheme = URL.scheme;
    originComponents.host = URL.host;
    originComponents.port = URL.port;
    NSURL *origin = originComponents.URL;
    if (!origin) {
        return;
    }

    NSString *path = URL.path ?: @"";
    NSString *basePath = [path containsString:@"/backend-api/"] ? @"/backend-api" : @"";
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[
        @"authorization", @"chatgpt-account-id", @"openai-sentinel-chat-requirements-token",
        @"oai-device-id", @"x-openai-assistant-app-id", @"user-agent", @"accept-language"
    ]];
    [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        if ([allowed containsObject:key.lowercaseString] && value.length > 0) {
            headers[key] = value;
        }
    }];
    @synchronized (LVBVoiceURLProtocol.class) {
        LVBLastAPIOrigin = origin;
        LVBLastAPIBasePath = basePath;
        if (headers.count > 0) {
            LVBLastAPIAssetHeaders = [headers copy];
        }
    }
}

static NSString *LVBImageFileIdentifier(NSURL *URL) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (URL.host.length > 0) {
        [candidates addObject:URL.host];
    }
    for (NSString *component in URL.path.pathComponents ?: @[]) {
        if (component.length > 1) {
            [candidates addObject:component];
        }
    }
    for (NSString *candidate in candidates) {
        NSString *lower = candidate.lowercaseString;
        if (![lower hasPrefix:@"file_"] && ![lower hasPrefix:@"file-"]) {
            continue;
        }
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
        if (candidate.length <= 256 &&
            [candidate rangeOfCharacterFromSet:invalid].location == NSNotFound) {
            return candidate;
        }
    }
    return nil;
}

static NSString *LVBFindDownloadURLString(id object, NSUInteger depth) {
    if (!object || depth > 8) {
        return nil;
    }
    if ([object isKindOfClass:NSString.class]) {
        NSString *value = object;
        NSURL *URL = [NSURL URLWithString:value];
        return ([URL.scheme.lowercaseString isEqualToString:@"https"] ||
                [URL.scheme.lowercaseString isEqualToString:@"http"]) ? value : nil;
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) {
            NSString *result = LVBFindDownloadURLString(value, depth + 1);
            if (result) {
                return result;
            }
        }
        return nil;
    }
    if (![object isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary *dictionary = object;
    // Sediment responses can contain both a stable/authenticated URL and the
    // actual signed CDN URL. Dictionary iteration order is undefined, so the
    // previous implementation could choose the wrong one and receive 403.
    static NSArray<NSString *> *preferredKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        preferredKeys = @[
            @"directdownloadurl", @"downloadurl", @"asseturl", @"url"
        ];
    });
    for (NSString *preferredKey in preferredKeys) {
        for (id rawKey in dictionary) {
            if (![rawKey isKindOfClass:NSString.class] ||
                ![LVBNormalizedKey(rawKey) isEqualToString:preferredKey]) {
                continue;
            }
            NSString *result =
                LVBFindDownloadURLString(dictionary[rawKey], depth + 1);
            if (result) {
                return result;
            }
        }
    }
    for (id value in dictionary.allValues) {
        NSString *result = LVBFindDownloadURLString(value, depth + 1);
        if (result) {
            return result;
        }
    }
    return nil;
}

static NSDictionary *LVBJSONDictionary(NSData *data) {
    if (data.length == 0) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSData *LVBRequestBodyData(NSURLRequest *request, BOOL *materializedStream) {
    *materializedStream = NO;
    if (request.HTTPBody.length > 0) {
        return request.HTTPBody;
    }

    NSInputStream *stream = request.HTTPBodyStream;
    if (!stream) {
        return nil;
    }

    *materializedStream = YES;
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    [stream open];
    while (YES) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count < 0) {
            NSError *streamError = stream.streamError;
            LVBLog(@"could not read intercepted request body stream domain=%@ code=%ld",
                   streamError.domain ?: @"unknown",
                   (long)streamError.code);
            [stream close];
            return nil;
        }
        if (count == 0) {
            break;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
        if (data.length > (2 * 1024 * 1024)) {
            LVBLog(@"refusing to buffer intercepted request body larger than 2 MiB");
            [stream close];
            return nil;
        }
    }
    [stream close];
    return data;
}

static NSString *LVBNormalizedKey(NSString *key) {
    return [[key.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@""]
            stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

static BOOL LVBDictionaryLooksLikeGetToken(NSDictionary *dictionary) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (id key in dictionary) {
        if ([key isKindOfClass:NSString.class]) {
            [keys addObject:LVBNormalizedKey(key)];
        }
    }
    return ([keys containsObject:@"voicesessionid"] &&
            ([keys containsObject:@"modelslug"] || [keys containsObject:@"voicemode"]));
}

static LVBEndpointKind LVBEndpointForRequest(NSURLRequest *request) {
    if (CGBIsSedimentAssetURL(request.URL) ||
        [request.URL.scheme.lowercaseString isEqualToString:@"file-service"]) {
        return LVBEndpointImageAsset;
    }
    if (!LVBIsOpenAIHost(request.URL.host)) {
        return LVBEndpointNone;
    }

    NSString *path = request.URL.path.lowercaseString ?: @"";
    NSString *compactPath = [[path stringByReplacingOccurrencesOfString:@"_" withString:@""]
                             stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if ([path containsString:@"conversation/voice/status"]) {
        return LVBEndpointVoiceStatus;
    }
    if ([compactPath containsString:@"gettoken"]) {
        return LVBEndpointGetToken;
    }
    NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
    if ([method isEqualToString:@"GET"] && [path hasSuffix:@"/models"] &&
        ![path containsString:@"/voice/"] && ![path containsString:@"/gizmo"]) {
        return LVBEndpointModels;
    }
    if ([method isEqualToString:@"POST"] &&
        ([path isEqualToString:@"/conversation"] || [path hasSuffix:@"/conversation"])) {
        return LVBEndpointConversation;
    }
    if ([method isEqualToString:@"GET"] &&
        ([path containsString:@"/conversation/"] ||
         [path hasSuffix:@"/conversation"] ||
         [path containsString:@"/conversations"] ||
         [path hasSuffix:@"/conversation/init"]) &&
        ![path containsString:@"/conversation/voice/"]) {
        // Conversation data can arrive through the detail endpoint, the list
        // refresh endpoint, or the encrypted repository bootstrap used by the
        // legacy app. Recursively adapting JSON is a no-op for metadata-only
        // responses, so handling all history GET routes also repairs old chats
        // that never issue a canonical /conversation/{id} request.
        return LVBEndpointConversationDetail;
    }

    NSDictionary *body = LVBJSONDictionary(request.HTTPBody);
    return LVBDictionaryLooksLikeGetToken(body) ? LVBEndpointGetToken : LVBEndpointNone;
}

static NSArray<NSString *> *LVBSortedStringKeys(NSDictionary *dictionary) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (id key in dictionary) {
        if ([key isKindOfClass:NSString.class]) {
            [keys addObject:key];
        }
    }
    [keys sortUsingSelector:@selector(compare:)];
    return keys;
}

static id LVBValueForNormalizedKey(NSDictionary *dictionary, NSString *normalizedKey) {
    for (id key in dictionary) {
        if ([key isKindOfClass:NSString.class] &&
            [LVBNormalizedKey(key) isEqualToString:normalizedKey]) {
            return dictionary[key];
        }
    }
    return nil;
}

static NSString *LVBSafeIdentifier(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 128) {
        return nil;
    }
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *allowed = [NSCharacterSet
            characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"];
        invalidCharacters = allowed.invertedSet;
    });
    return [value rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound ? value : nil;
}

static id LVBStructuralSummary(id object, NSUInteger depth) {
    if (depth > 3) {
        return @"depth-limit";
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        NSMutableDictionary *children = [NSMutableDictionary dictionary];
        for (NSString *key in LVBSortedStringKeys(dictionary)) {
            if (keys.count >= 24) {
                break;
            }
            NSString *safeKey = LVBSafeIdentifier(key) ?: @"redacted-key";
            [keys addObject:safeKey];
            id value = dictionary[key];
            if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
                children[safeKey] = LVBStructuralSummary(value, depth + 1);
            }
        }
        NSMutableDictionary *summary = [@{
            @"type": @"object",
            @"key_count": @(dictionary.count),
            @"keys": keys
        } mutableCopy];
        if (children.count > 0) {
            summary[@"children"] = children;
        }
        return summary;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSArray *array = object;
        NSMutableDictionary *summary = [@{
            @"type": @"array",
            @"count": @(array.count)
        } mutableCopy];
        if (array.count > 0) {
            summary[@"first"] = LVBStructuralSummary(array.firstObject, depth + 1);
        }
        return summary;
    }
    if ([object isKindOfClass:NSString.class]) {
        return @"string";
    }
    if ([object isKindOfClass:NSNumber.class]) {
        return @"number";
    }
    if (object == NSNull.null) {
        return @"null";
    }
    return @"other";
}

static void LVBStoreVoiceStatusMetadata(NSDictionary *status) {
    if (![status isKindOfClass:NSDictionary.class]) {
        return;
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *catalog =
        [NSMutableDictionary dictionary];
    id rawModes = LVBValueForNormalizedKey(status, @"modes");
    if ([rawModes isKindOfClass:NSArray.class]) {
        for (id rawMode in rawModes) {
            if (![rawMode isKindOfClass:NSDictionary.class]) {
                continue;
            }
            NSDictionary *modeDictionary = rawMode;
            NSString *mode = LVBSafeIdentifier(LVBValueForNormalizedKey(modeDictionary, @"mode"));
            if (mode.length == 0) {
                continue;
            }
            NSString *model = LVBSafeIdentifier(
                LVBValueForNormalizedKey(modeDictionary, @"defaultmodelslug"));
            id disabledMetadata = LVBValueForNormalizedKey(modeDictionary, @"disabledmodemetadata");
            BOOL enabled = disabledMetadata == nil || disabledMetadata == NSNull.null;
            catalog[mode.lowercaseString] = @{
                @"mode": mode,
                @"default_model_slug": model ?: NSNull.null,
                @"enabled": @(enabled)
            };
        }
    }

    NSString *defaultMode = LVBSafeIdentifier(
        LVBValueForNormalizedKey(status, @"defaultvoicemode"));
    @synchronized (LVBVoiceURLProtocol.class) {
        LVBModeCatalog = [catalog copy];
        LVBStatusDefaultMode = [defaultMode copy];
    }

    NSArray *modeSummary = [[catalog.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
            return [first[@"mode"] compare:second[@"mode"]];
        }] copy];
    id chatreq = LVBValueForNormalizedKey(status, @"chatreq");
    LVBLog(@"voice status metadata default_mode=%@ modes=%@ chatreq_shape=%@",
           defaultMode ?: @"none",
           LVBJSONString(modeSummary),
           chatreq ? LVBJSONString(LVBStructuralSummary(chatreq, 0)) : @"none");
}

static NSDictionary<NSString *, id> *LVBModeConfiguration(NSString *mode) {
    NSString *safeMode = LVBSafeIdentifier(mode);
    if (safeMode.length == 0) {
        return nil;
    }
    @synchronized (LVBVoiceURLProtocol.class) {
        return [LVBModeCatalog[safeMode.lowercaseString] copy];
    }
}

static BOOL LVBContainsNormalizedKey(NSDictionary *dictionary, NSString *normalizedKey) {
    for (id key in dictionary) {
        if ([key isKindOfClass:NSString.class] &&
            [LVBNormalizedKey(key) isEqualToString:normalizedKey]) {
            return YES;
        }
    }
    return NO;
}

static NSString *LVBFindChatreqToken(id object) {
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        for (id key in dictionary) {
            if ([key isKindOfClass:NSString.class] &&
                [LVBNormalizedKey(key) isEqualToString:@"chatreqtoken"] &&
                [dictionary[key] isKindOfClass:NSString.class] &&
                [dictionary[key] length] > 0) {
                return dictionary[key];
            }
        }
        for (id value in dictionary.allValues) {
            NSString *token = LVBFindChatreqToken(value);
            if (token.length > 0) {
                return token;
            }
        }
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) {
            NSString *token = LVBFindChatreqToken(value);
            if (token.length > 0) {
                return token;
            }
        }
    }
    return nil;
}

static void LVBStoreChatreqToken(NSString *token) {
    if (token.length == 0) {
        return;
    }
    @synchronized (LVBVoiceURLProtocol.class) {
        LVBChatreqToken = [token copy];
    }
    LVBLog(@"voice status supplied chatreq token (value redacted)");
}

static NSString *LVBCurrentChatreqToken(void) {
    @synchronized (LVBVoiceURLProtocol.class) {
        return [LVBChatreqToken copy];
    }
}

static BOOL LVBIsSensitiveKey(NSString *key) {
    NSString *normalized = LVBNormalizedKey(key);
    NSArray<NSString *> *sensitiveFragments = @[
        @"token", @"authorization", @"cookie", @"secret", @"e2ee", @"apikey",
        @"conversationid", @"parentmessageid", @"voicesessionid"
    ];
    for (NSString *fragment in sensitiveFragments) {
        if ([normalized containsString:fragment]) {
            return YES;
        }
    }
    return NO;
}

static id LVBSafeErrorSummary(id object, NSUInteger depth) {
    if (depth > 5) {
        return @"<depth limit>";
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        NSDictionary *dictionary = object;
        for (id rawKey in dictionary) {
            if (![rawKey isKindOfClass:NSString.class]) {
                continue;
            }
            NSString *key = rawKey;
            NSString *normalized = LVBNormalizedKey(key);
            if (LVBIsSensitiveKey(key)) {
                summary[key] = @"<redacted>";
            } else if ([normalized isEqualToString:@"error"]) {
                id value = dictionary[key];
                summary[key] = ([value isKindOfClass:NSDictionary.class] ||
                                [value isKindOfClass:NSArray.class]) ?
                    (LVBSafeErrorSummary(value, depth + 1) ?: NSNull.null) :
                    @"<redacted error text>";
            } else if ([normalized isEqualToString:@"code"] ||
                       [normalized isEqualToString:@"type"] ||
                       [normalized isEqualToString:@"status"]) {
                id value = dictionary[key];
                if ([value isKindOfClass:NSNumber.class] || value == NSNull.null) {
                    summary[key] = value;
                } else if ([value isKindOfClass:NSString.class] && [value length] <= 128 &&
                           [value rangeOfCharacterFromSet:
                               [[NSCharacterSet characterSetWithCharactersInString:
                                   @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"]
                                invertedSet]].location == NSNotFound) {
                    summary[key] = value;
                } else {
                    summary[key] = @"<redacted non-code value>";
                }
            } else if ([normalized isEqualToString:@"message"] ||
                       [normalized isEqualToString:@"detail"]) {
                summary[key] = @"<redacted diagnostic text>";
            }
        }
        return summary;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSArray *array = object;
        NSMutableArray *summary = [NSMutableArray array];
        for (NSUInteger index = 0; index < MIN(array.count, 3); index++) {
            [summary addObject:LVBSafeErrorSummary(array[index], depth + 1) ?: NSNull.null];
        }
        return summary;
    }
    if ([object isKindOfClass:NSString.class]) {
        return @"<redacted string>";
    }
    if ([object isKindOfClass:NSNumber.class] || object == NSNull.null) {
        return object;
    }
    return @"<unsupported value>";
}

static void LVBCollectDiagnosticStrings(id object,
                                        NSMutableArray<NSString *> *strings,
                                        NSUInteger depth) {
    if (depth > 6 || strings.count >= 64) {
        return;
    }
    if ([object isKindOfClass:NSString.class]) {
        if ([object length] <= 2048) {
            [strings addObject:[object lowercaseString]];
        }
        return;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id value in [object allValues]) {
            LVBCollectDiagnosticStrings(value, strings, depth + 1);
        }
        return;
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) {
            LVBCollectDiagnosticStrings(value, strings, depth + 1);
        }
    }
}

static BOOL LVBTextContainsAny(NSString *text, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([text containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSString *LVBErrorCategory(NSDictionary *responseJSON) {
    if (![responseJSON isKindOfClass:NSDictionary.class]) {
        return @"non-json";
    }
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    LVBCollectDiagnosticStrings(responseJSON, strings, 0);
    NSString *text = [strings componentsJoinedByString:@" "];
    BOOL missingOrInvalid = LVBTextContainsAny(text, @[
        @"not found", @"does not exist", @"unknown", @"invalid", @"unsupported"
    ]);

    if ([text containsString:@"chatreq"] || [text containsString:@"chat request"]) {
        return @"chatreq";
    }
    if ([text containsString:@"conversation"] && missingOrInvalid) {
        return @"conversation";
    }
    if ([text containsString:@"model"] && missingOrInvalid) {
        return @"model";
    }
    if (([text containsString:@"voice mode"] || [text containsString:@"voice_mode"]) &&
        missingOrInvalid) {
        return @"voice-mode";
    }
    if ((([text containsString:@"route"] || [text containsString:@"endpoint"] ||
          [text containsString:@"path"]) && [text containsString:@"not found"]) ||
        [text containsString:@"no route"] || [text containsString:@"no endpoint"]) {
        return @"route";
    }
    if (([text containsString:@"session"] || [text containsString:@"room"]) &&
        missingOrInvalid) {
        return @"session";
    }
    if ([text containsString:@"missing"] || [text containsString:@"required"]) {
        return @"missing-field";
    }
    if (LVBTextContainsAny(text, @[@"unauthorized", @"authentication", @"log in"])) {
        return @"authentication";
    }
    if (LVBTextContainsAny(text, @[@"forbidden", @"permission", @"not allowed"])) {
        return @"authorization";
    }
    if ([text containsString:@"rate limit"] || [text containsString:@"too many requests"]) {
        return @"rate-limit";
    }
    if ([text containsString:@"not found"]) {
        return @"generic-not-found";
    }
    if ([text containsString:@"unsupported"] && [text containsString:@"client"]) {
        return @"unsupported-client";
    }
    return @"unclassified";
}

static NSString *LVBJSONString(id object) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return [object description];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/*
 * The 2026 client sends a status request even when App Attest is unavailable.
 * Its X-Sentinel-Payload contains a bot_token failure object where raw reason
 * 1 is ConversationsCore.AssertionFailureReason.appAttestUnavailable.  This is
 * a truthful compatibility fallback for the 2024 voice path; it deliberately
 * does not invent a nonce, assertion object, device token, or attested token.
 */
static NSString *LVBAppAttestUnavailableSentinelValue(void) {
    static NSString *value;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *payload = @{
            @"bot_token": @{
                @"failure_reason": @1,
                @"detail": @"app_attest_service_not_supported"
            }
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    });
    return value;
}

static BOOL LVBHasAppAttestHeader(NSURLRequest *request) {
    return [request valueForHTTPHeaderField:LVBAppAttestHeader].length > 0;
}

static NSMutableURLRequest *LVBStatusAttestFallbackRequest(NSURLRequest *request) {
    NSMutableURLRequest *fallback = [request mutableCopy];
    [fallback setValue:LVBAppAttestUnavailableSentinelValue()
    forHTTPHeaderField:LVBAppAttestHeader];
    [NSURLProtocol setProperty:@YES forKey:LVBHandledRequestKey inRequest:fallback];
    return fallback;
}

static BOOL LVBShouldAttemptStatusAttestFallback(NSURLRequest *request,
                                                 NSData *data,
                                                 NSURLResponse *response,
                                                 NSError *error) {
    if (error || LVBHasAppAttestHeader(request)) {
        return NO;
    }
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ?
                                       (NSHTTPURLResponse *)response : nil;
    if (!httpResponse || LVBFindChatreqToken(LVBJSONDictionary(data)).length > 0) {
        return NO;
    }

    NSInteger status = httpResponse.statusCode;
    if (status >= 200 && status < 300) {
        return YES;
    }
    return status >= 400 && status < 500 && status != 429;
}

static BOOL LVBIsSuccessfulHTTPResponse(NSURLResponse *response) {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ?
                                       (NSHTTPURLResponse *)response : nil;
    return httpResponse.statusCode >= 200 && httpResponse.statusCode < 300;
}

static BOOL LVBBodyUsesSnakeCase(NSDictionary *body) {
    for (id key in body) {
        if ([key isKindOfClass:NSString.class] && [key containsString:@"_"]) {
            return YES;
        }
    }
    return NO;
}

static NSString *LVBExistingBodyKey(NSDictionary *body, NSString *normalizedKey) {
    for (id key in body) {
        if ([key isKindOfClass:NSString.class] &&
            [LVBNormalizedKey(key) isEqualToString:normalizedKey]) {
            return key;
        }
    }
    return nil;
}

static BOOL LVBSetBodyValue(NSMutableDictionary *body,
                            NSString *normalizedKey,
                            NSString *snakeKey,
                            NSString *camelKey,
                            id value,
                            BOOL usesSnakeCase) {
    NSString *key = LVBExistingBodyKey(body, normalizedKey) ?: (usesSnakeCase ? snakeKey : camelKey);
    if ([body[key] isEqual:value]) {
        return NO;
    }
    body[key] = value;
    return YES;
}

static NSMutableURLRequest *LVBCompatibilityGetTokenRequest(NSURLRequest *request,
                                                            BOOL useStandardMode,
                                                            NSArray<NSString *> **changesOut) {
    NSDictionary *body = LVBJSONDictionary(request.HTTPBody);
    if (![body isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    BOOL usesSnakeCase = LVBBodyUsesSnakeCase(body);
    NSString *requestedMode = LVBSafeIdentifier(LVBValueForNormalizedKey(body, @"voicemode"));
    NSDictionary<NSString *, id> *configuration = nil;
    if (useStandardMode) {
        if ([requestedMode.lowercaseString isEqualToString:@"standard"]) {
            return nil;
        }
        configuration = LVBModeConfiguration(@"standard");
        if (![configuration[@"enabled"] boolValue]) {
            return nil;
        }
    } else if (requestedMode.length > 0) {
        configuration = LVBModeConfiguration(requestedMode);
    }

    NSMutableDictionary *modifiedBody = [body mutableCopy];
    NSMutableArray<NSString *> *changes = [NSMutableArray array];
    NSString *timezoneName = NSTimeZone.localTimeZone.name ?: @"UTC";
    NSInteger timezoneOffsetMinutes =
        [NSTimeZone.localTimeZone secondsFromGMTForDate:NSDate.date] / 60;
    if (!LVBContainsNormalizedKey(modifiedBody, @"timezone") &&
        LVBSetBodyValue(modifiedBody, @"timezone", @"timezone", @"timezone",
                        timezoneName, usesSnakeCase)) {
        [changes addObject:@"timezone"];
    }
    if (!LVBContainsNormalizedKey(modifiedBody, @"timezoneoffsetmin") &&
        LVBSetBodyValue(modifiedBody, @"timezoneoffsetmin", @"timezone_offset_min",
                        @"timezoneOffsetMin", @(timezoneOffsetMinutes), usesSnakeCase)) {
        [changes addObject:@"timezone-offset"];
    }

    id legacyLanguage = LVBValueForNormalizedKey(modifiedBody, @"language");
    if (!LVBContainsNormalizedKey(modifiedBody, @"languagecode") &&
        [legacyLanguage isKindOfClass:NSString.class] && [legacyLanguage length] > 0 &&
        LVBSetBodyValue(modifiedBody, @"languagecode", @"language_code", @"languageCode",
                        legacyLanguage, usesSnakeCase)) {
        [changes addObject:@"language-code"];
    }

    NSString *serverMode = LVBSafeIdentifier(configuration[@"mode"]);
    if (useStandardMode && serverMode.length > 0 &&
        LVBSetBodyValue(modifiedBody, @"voicemode", @"voice_mode", @"voiceMode",
                        serverMode, usesSnakeCase)) {
        [changes addObject:@"server-standard-mode"];
    }

    NSString *serverModel = LVBSafeIdentifier(configuration[@"default_model_slug"]);
    if ([configuration[@"enabled"] boolValue] && serverModel.length > 0 &&
        LVBSetBodyValue(modifiedBody, @"modelslug", @"model_slug", @"modelSlug",
                        serverModel, usesSnakeCase)) {
        [changes addObject:@"server-default-model"];
    }

    if (changes.count == 0) {
        return nil;
    }
    NSData *encodedBody = [NSJSONSerialization dataWithJSONObject:modifiedBody options:0 error:nil];
    if (encodedBody.length == 0) {
        return nil;
    }

    NSMutableURLRequest *fallback = [request mutableCopy];
    fallback.HTTPBody = encodedBody;
    [fallback setValue:nil forHTTPHeaderField:@"Content-Length"];
    [fallback setValue:nil forHTTPHeaderField:@"Content-MD5"];
    [NSURLProtocol setProperty:@YES forKey:LVBHandledRequestKey inRequest:fallback];
    if (changesOut) {
        *changesOut = [changes copy];
    }
    return fallback;
}

static BOOL LVBGetTokenResponseLooksUsable(NSData *data,
                                           NSURLResponse *response,
                                           NSError *error) {
    if (error || !LVBIsSuccessfulHTTPResponse(response)) {
        return NO;
    }
    NSDictionary *body = LVBJSONDictionary(data);
    return [LVBValueForNormalizedKey(body, @"url") isKindOfClass:NSString.class] &&
           [LVBValueForNormalizedKey(body, @"token") isKindOfClass:NSString.class] &&
           [LVBValueForNormalizedKey(body, @"e2eekey") isKindOfClass:NSString.class];
}

static NSString *LVBEndpointName(LVBEndpointKind endpoint) {
    switch (endpoint) {
        case LVBEndpointVoiceStatus:
            return @"voice-status";
        case LVBEndpointGetToken:
            return @"get-token";
        case LVBEndpointModels:
            return @"models";
        case LVBEndpointConversation:
            return @"conversation";
        case LVBEndpointConversationDetail:
            return @"conversation-detail";
        case LVBEndpointImageAsset:
            return @"image-asset";
        case LVBEndpointNone:
            return @"none";
    }
    return @"unknown";
}

static NSMutableURLRequest *LVBPatchedRequest(NSURLRequest *request,
                                             LVBEndpointKind endpoint,
                                             BOOL *didInjectToken) {
    NSMutableURLRequest *patched = [request mutableCopy];
    *didInjectToken = NO;

    if (endpoint == LVBEndpointImageAsset) {
        NSURL *legacyURL = CGBLegacyFileServiceURLForSedimentURL(request.URL);
        if (legacyURL) {
            patched.URL = legacyURL;
            LVBLog(@"image asset scheme bridge sediment -> file-service source=%@ translated=%@",
                   LVBJSONString(CGBSafeAssetURLSummary(request.URL)),
                   LVBJSONString(CGBSafeAssetURLSummary(legacyURL)));
        } else if ([request.URL.scheme.lowercaseString isEqualToString:@"file-service"]) {
            LVBLog(@"image asset bridge routing existing file-service locator through native loader source=%@",
                   LVBJSONString(CGBSafeAssetURLSummary(request.URL)));
        } else {
            LVBLog(@"image asset scheme bridge could not translate source=%@",
                   LVBJSONString(CGBSafeAssetURLSummary(request.URL)));
        }
        return patched;
    }

    if (endpoint == LVBEndpointVoiceStatus && !LVBHasAppAttestHeader(patched)) {
        BOOL preferSentinel = NO;
        @synchronized (LVBVoiceURLProtocol.class) {
            preferSentinel = LVBPreferStatusAttestUnavailableSentinel;
        }
        if (preferSentinel) {
            [patched setValue:LVBAppAttestUnavailableSentinelValue()
           forHTTPHeaderField:LVBAppAttestHeader];
            LVBLog(@"voice-status using previously successful App-Attest-unavailable path on first attempt");
        }
    }

    BOOL materializedStream = NO;
    NSData *bodyData = LVBRequestBodyData(request, &materializedStream);
    if (materializedStream && bodyData) {
        patched.HTTPBody = bodyData;
        [patched setValue:nil forHTTPHeaderField:@"Content-Length"];
    }
    NSDictionary *bodyDictionary = LVBJSONDictionary(bodyData);
    if (endpoint == LVBEndpointGetToken && bodyDictionary) {
        NSString *token = LVBCurrentChatreqToken();
        BOOL alreadyHasToken = NO;
        BOOL usesSnakeCase = NO;
        for (id key in bodyDictionary) {
            if (![key isKindOfClass:NSString.class]) {
                continue;
            }
            if ([LVBNormalizedKey(key) isEqualToString:@"chatreqtoken"]) {
                alreadyHasToken = YES;
            }
            if ([key containsString:@"_"]) {
                usesSnakeCase = YES;
            }
        }

        NSMutableDictionary *modifiedBody = [bodyDictionary mutableCopy];
        BOOL didModifyBody = NO;
        NSDictionary *selection = nil;
        NSDictionary *resolvedVoiceBody = CGBVoiceBodyByResolvingModelSelection(
            modifiedBody, &selection);
        if (resolvedVoiceBody) {
            modifiedBody = [resolvedVoiceBody mutableCopy];
            didModifyBody = YES;
            LVBLog(@"voice model switcher resolved selection model=%@ thinking_effort=%@ service_tier=%@",
                   selection[@"model"] ?: @"none",
                   selection[@"thinking_effort"] ?: @"default",
                   selection[@"service_tier_ignored"] ?: @"not-applicable");
        }

        if (!alreadyHasToken && token.length > 0) {
            modifiedBody[usesSnakeCase ? @"chatreq_token" : @"chatreqToken"] = token;
            didModifyBody = YES;
            *didInjectToken = YES;
        }

        if (didModifyBody) {
            NSData *encodedBody = [NSJSONSerialization dataWithJSONObject:modifiedBody
                                                                    options:0
                                                                      error:nil];
            if (encodedBody.length > 0) {
                patched.HTTPBody = encodedBody;
                [patched setValue:nil forHTTPHeaderField:@"Content-Length"];
                [patched setValue:nil forHTTPHeaderField:@"Content-MD5"];
                bodyDictionary = modifiedBody;
            }
        }
    }

    if (endpoint == LVBEndpointConversation && bodyDictionary) {
        NSDictionary *selection = nil;
        NSDictionary *resolvedBody = CGBConversationBodyByResolvingModelSelection(
            bodyDictionary, &selection);
        if (resolvedBody) {
            NSData *encodedBody = [NSJSONSerialization dataWithJSONObject:resolvedBody
                                                                    options:0
                                                                      error:nil];
            if (encodedBody.length > 0) {
                patched.HTTPBody = encodedBody;
                [patched setValue:nil forHTTPHeaderField:@"Content-Length"];
                [patched setValue:nil forHTTPHeaderField:@"Content-MD5"];
                bodyDictionary = resolvedBody;
                *didInjectToken = YES;
                LVBLog(@"model switcher resolved selection model=%@ thinking_effort=%@ service_tier=%@",
                       selection[@"model"] ?: @"none",
                       selection[@"thinking_effort"] ?: @"default",
                       selection[@"service_tier"] ?: @"default");
            }
        }
    }

    if (endpoint == LVBEndpointModels) {
        LVBLog(@"intercept models %@ route=%@",
               request.HTTPMethod ?: @"GET", request.URL.path ?: @"unknown");
        return patched;
    }
    if (endpoint == LVBEndpointConversation) {
        NSString *requestModel = LVBSafeIdentifier(
            LVBValueForNormalizedKey(bodyDictionary, @"model"));
        NSString *thinkingEffort = LVBSafeIdentifier(
            LVBValueForNormalizedKey(bodyDictionary, @"thinkingeffort"));
        LVBLog(@"intercept conversation %@ route=%@ selection_resolved=%@ model=%@ thinking_effort=%@ body_stream=%@",
               request.HTTPMethod ?: @"POST",
               request.URL.path ?: @"unknown",
               *didInjectToken ? @"yes" : @"no",
               requestModel ?: @"none-or-redacted",
               thinkingEffort ?: @"default",
               materializedStream ? @"yes (materialized)" : @"no");
        return patched;
    }

    NSString *kind = LVBEndpointName(endpoint);
    NSArray *bodyKeys = bodyDictionary ? LVBSortedStringKeys(bodyDictionary) : @[];
    NSArray *headerKeys = [request.allHTTPHeaderFields.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSString *canonicalRoute = endpoint == LVBEndpointVoiceStatus ?
        @"conversation/voice/status" : @"voice/get_token";
    NSString *requestMode = LVBSafeIdentifier(LVBValueForNormalizedKey(bodyDictionary, @"voicemode"));
    NSString *requestModel = LVBSafeIdentifier(LVBValueForNormalizedKey(bodyDictionary, @"modelslug"));
    NSString *statusDefaultMode = nil;
    @synchronized (LVBVoiceURLProtocol.class) {
        statusDefaultMode = [LVBStatusDefaultMode copy];
    }
    LVBLog(@"intercept %@ %@ route=%@ body_keys=%@ header_keys=%@ token_injected=%@ body_stream=%@ app_attest_header=%@ nonce_present=%@ request_mode=%@ request_model=%@ status_default_mode=%@",
           kind,
           request.HTTPMethod ?: @"GET",
           canonicalRoute,
           bodyKeys,
           headerKeys,
           *didInjectToken ? @"yes" : @"no",
           materializedStream ? @"yes (materialized)" : @"no",
           LVBHasAppAttestHeader(patched) ? @"yes" : @"no",
           LVBContainsNormalizedKey(bodyDictionary, @"nonce") ? @"yes" : @"no",
           requestMode ?: @"none-or-redacted",
           requestModel ?: @"none-or-redacted",
           statusDefaultMode ?: @"none");
    return patched;
}

static NSHTTPURLResponse *LVBResponseForRewrittenBody(NSHTTPURLResponse *response,
                                                       NSUInteger bodyLength) {
    if (!response) {
        return nil;
    }
    NSMutableDictionary *headers = [response.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
    for (id key in [headers.allKeys copy]) {
        NSString *header = [[key description] lowercaseString];
        if ([header isEqualToString:@"content-length"] ||
            [header isEqualToString:@"content-encoding"]) {
            [headers removeObjectForKey:key];
        }
    }
    headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)bodyLength];
    return [[NSHTTPURLResponse alloc] initWithURL:response.URL
                                      statusCode:response.statusCode
                                     HTTPVersion:@"HTTP/1.1"
                                    headerFields:headers];
}

static Class LVBFileServiceProtocolClass(void) {
    static Class protocolClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class candidate = NSClassFromString(@"FileUploadService.FileServiceProtocol");
        if (!candidate) {
            candidate = objc_getClass("_TtC17FileUploadService19FileServiceProtocol");
        }
        if (candidate && [candidate isSubclassOfClass:NSURLProtocol.class]) {
            protocolClass = candidate;
        }
    });
    return protocolClass;
}

static NSArray<NSURL *> *LVBImageDownloadLinkCandidates(NSURL *assetURL) {
    NSString *fileID = LVBImageFileIdentifier(assetURL);
    if (fileID.length == 0) {
        return @[];
    }
    NSURL *origin = nil;
    NSString *rememberedBasePath = nil;
    @synchronized (LVBVoiceURLProtocol.class) {
        origin = LVBLastAPIOrigin;
        rememberedBasePath = LVBLastAPIBasePath;
    }
    if (!origin) {
        origin = [NSURL URLWithString:@"https://ios.chat.openai.com"];
    }

    NSMutableArray<NSString *> *basePaths = [NSMutableArray array];
    if (rememberedBasePath.length > 0) {
        [basePaths addObject:rememberedBasePath];
    }
    if (![basePaths containsObject:@"/backend-api"]) {
        [basePaths addObject:@"/backend-api"];
    }
    if (![basePaths containsObject:@""]) {
        [basePaths addObject:@""];
    }

    NSMutableArray<NSURL *> *result = [NSMutableArray array];
    for (NSString *basePath in basePaths) {
        NSString *path = [NSString stringWithFormat:@"%@/files/%@/download",
                                                    basePath, fileID];
        NSURL *candidate = [origin URLByAppendingPathComponent:path];
        if (candidate && ![result containsObject:candidate]) {
            [result addObject:candidate];
        }
    }
    return [result copy];
}

static NSRange LVBNextSSEEventBoundary(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    for (NSUInteger index = 0; index + 1 < length; index++) {
        if (index + 3 < length && bytes[index] == '\r' && bytes[index + 1] == '\n' &&
            bytes[index + 2] == '\r' && bytes[index + 3] == '\n') {
            return NSMakeRange(index, 4);
        }
        if (bytes[index] == '\n' && bytes[index + 1] == '\n') {
            return NSMakeRange(index, 2);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

static NSData *LVBDataByAppendingSSEBoundary(NSData *eventData) {
    NSMutableData *result = [eventData mutableCopy] ?: [NSMutableData data];
    [result appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    return result;
}

static NSData *LVBTransformConversationSSEEvent(LVBVoiceURLProtocol *protocol,
                                                NSData *eventData) {
    NSString *event = [[NSString alloc] initWithData:eventData
                                            encoding:NSUTF8StringEncoding];
    if (event.length == 0) {
        return LVBDataByAppendingSSEBoundary(eventData);
    }

    NSMutableArray<NSString *> *dataLines = [NSMutableArray array];
    [event enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        if (![line hasPrefix:@"data:"]) {
            return;
        }
        NSString *value = [line substringFromIndex:5];
        if ([value hasPrefix:@" "]) {
            value = [value substringFromIndex:1];
        }
        [dataLines addObject:value];
    }];
    if (dataLines.count == 0) {
        return LVBDataByAppendingSSEBoundary(eventData);
    }

    NSString *payload = [dataLines componentsJoinedByString:@"\n"];
    if ([payload isEqualToString:@"[DONE]"]) {
        if (protocol.conversationDetectedAsyncImage &&
            !protocol.conversationSawImageOutput) {
            protocol.conversationHeldDone = YES;
            LVBLog(@"conversation image bridge held stream completion while waiting for asynchronous result");
            [protocol lvb_beginImagePollingIfNeeded];
            return nil;
        }
        return LVBDataByAppendingSSEBoundary(eventData);
    }
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    id object = payloadData.length > 0 ?
        [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil] : nil;
    if (!object) {
        return LVBDataByAppendingSSEBoundary(eventData);
    }

    NSString *conversationIdentifier = CGBConversationIdentifierFromImageEvent(object);
    if (!protocol.conversationIdentifier.length && conversationIdentifier.length) {
        protocol.conversationIdentifier = conversationIdentifier;
    }
    NSString *turnIdentifier = CGBImageTurnExchangeIdentifierFromEvent(object);
    if (!protocol.imageTurnExchangeIdentifier.length && turnIdentifier.length) {
        protocol.imageTurnExchangeIdentifier = turnIdentifier;
    }
    if (CGBImageEventIndicatesAsyncGeneration(object)) {
        if (!protocol.conversationDetectedAsyncImage) {
            LVBLog(@"conversation image bridge detected current asynchronous image turn conversation_id=%@ turn_id=%@",
                   protocol.conversationIdentifier.length ? @"present" : @"pending",
                   protocol.imageTurnExchangeIdentifier.length ? @"present" : @"pending");
        }
        protocol.conversationDetectedAsyncImage = YES;
    }

    NSDictionary *summary = CGBSafeImageEventSummary(object);
    if (summary) {
        NSString *fingerprint = LVBJSONString(summary);
        if (!protocol.loggedImageEventSummaries) {
            protocol.loggedImageEventSummaries = [NSMutableSet set];
        }
        if (![protocol.loggedImageEventSummaries containsObject:fingerprint] &&
            protocol.loggedImageEventSummaries.count < 32) {
            [protocol.loggedImageEventSummaries addObject:fingerprint];
            LVBLog(@"conversation image event structure=%@", fingerprint);
        }
    }

    NSUInteger URLRewriteCount = 0;
    NSUInteger messageRewriteCount = 0;
    id legacyObject = CGBLegacyImageCompatibleObject(object, &URLRewriteCount,
                                                     &messageRewriteCount);
    if (messageRewriteCount > 0) {
        protocol.conversationSawImageOutput = YES;
    }
    if (URLRewriteCount == 0 && messageRewriteCount == 0) {
        return LVBDataByAppendingSSEBoundary(eventData);
    }

    NSData *legacyPayload = [NSJSONSerialization dataWithJSONObject:legacyObject
                                                             options:0
                                                               error:nil];
    if (legacyPayload.length == 0) {
        return LVBDataByAppendingSSEBoundary(eventData);
    }
    NSMutableData *rewrittenEvent = [NSMutableData data];
    [rewrittenEvent appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
    [rewrittenEvent appendData:legacyPayload];
    [rewrittenEvent appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    LVBLog(@"conversation image bridge rewrote stream asset_urls=%lu image_messages=%lu",
           (unsigned long)URLRewriteCount, (unsigned long)messageRewriteCount);
    return rewrittenEvent;
}

static NSData *LVBTransformConversationSSEData(LVBVoiceURLProtocol *protocol, NSData *data) {
    if (!protocol.conversationSSEBuffer) {
        protocol.conversationSSEBuffer = [NSMutableData data];
    }
    [protocol.conversationSSEBuffer appendData:data];
    NSMutableData *readyData = [NSMutableData data];

    while (YES) {
        NSRange boundary = LVBNextSSEEventBoundary(protocol.conversationSSEBuffer);
        if (boundary.location == NSNotFound) {
            break;
        }
        NSData *eventData = [protocol.conversationSSEBuffer
            subdataWithRange:NSMakeRange(0, boundary.location)];
        NSRange consumed = NSMakeRange(0, NSMaxRange(boundary));
        [protocol.conversationSSEBuffer replaceBytesInRange:consumed
                                                  withBytes:NULL
                                                     length:0];
        NSData *transformed = LVBTransformConversationSSEEvent(protocol, eventData);
        if (transformed.length > 0) {
            [readyData appendData:transformed];
        }
    }

    if (protocol.conversationSSEBuffer.length > (1024 * 1024)) {
        LVBLog(@"conversation image bridge passed through an unterminated SSE event larger than 1 MiB");
        [readyData appendData:protocol.conversationSSEBuffer];
        [protocol.conversationSSEBuffer setLength:0];
    }
    return readyData;
}

@implementation LVBVoiceURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:LVBHandledRequestKey inRequest:request]) {
        return NO;
    }
    LVBEndpointKind endpoint = LVBEndpointForRequest(request);
    // Every conversation stream must pass through the compatibility layer:
    // generated images can be selected implicitly by any current model, and
    // their final asset arrives after the ordinary stream completes.
    return endpoint != LVBEndpointNone;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    self.endpointKind = LVBEndpointForRequest(self.request);
    if (self.endpointKind != LVBEndpointImageAsset) {
        LVBRememberAuthenticatedAPIContext(self.request);
    }
    if (self.endpointKind == LVBEndpointConversation) {
        self.conversationStartedAt = NSDate.date.timeIntervalSince1970;
        self.deliveredImageMessageIdentifiers = [NSMutableSet set];
    }
    BOOL injectedToken = NO;
    NSMutableURLRequest *forwarded = LVBPatchedRequest(self.request, self.endpointKind, &injectedToken);
    [NSURLProtocol setProperty:@YES forKey:LVBHandledRequestKey inRequest:forwarded];

    if (self.endpointKind == LVBEndpointGetToken) {
        NSDictionary *voiceRequestBody = LVBJSONDictionary(forwarded.HTTPBody) ?: @{};
        LVBRealtimeVoiceStart(forwarded, voiceRequestBody);
    }

    if (self.endpointKind == LVBEndpointImageAsset) {
        [self lvb_startImageAssetResolution];
        return;
    }

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSMutableArray<Class> *protocolClasses = [configuration.protocolClasses mutableCopy] ?: [NSMutableArray array];
    [protocolClasses removeObject:LVBVoiceURLProtocol.class];
    configuration.protocolClasses = protocolClasses;
    configuration.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    configuration.URLCredentialStorage = NSURLCredentialStorage.sharedCredentialStorage;
    configuration.HTTPShouldSetCookies = YES;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    if (self.endpointKind == LVBEndpointConversation) {
        // Conversation responses and generated images can both be large or
        // incremental. Forward bytes as they arrive rather than buffering.
        self.streamedByteCount = 0;
        self.forwardingSession = [NSURLSession sessionWithConfiguration:configuration
                                                               delegate:self
                                                          delegateQueue:nil];
        self.forwardingTask = [self.forwardingSession dataTaskWithRequest:forwarded];
        [self.forwardingTask resume];
    } else {
        self.forwardingSession = [NSURLSession sessionWithConfiguration:configuration];
        [self lvb_startForwardingRequest:forwarded attempt:@"primary"];
    }
}

- (NSURLSession *)lvb_imageSession {
    NSURLSessionConfiguration *configuration =
        NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSMutableArray<Class> *classes =
        [configuration.protocolClasses mutableCopy] ?: [NSMutableArray array];
    [classes removeObject:LVBVoiceURLProtocol.class];
    Class oldFileService = LVBFileServiceProtocolClass();
    if (oldFileService) {
        [classes removeObject:oldFileService];
    }
    configuration.protocolClasses = classes;
    configuration.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    configuration.URLCredentialStorage = NSURLCredentialStorage.sharedCredentialStorage;
    configuration.HTTPShouldSetCookies = YES;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    return [NSURLSession sessionWithConfiguration:configuration];
}

- (void)lvb_finishImageAssetWithData:(NSData *)data
                            response:(NSURLResponse *)response
                               error:(NSError *)error {
    if (self.stopped) {
        return;
    }
    if (error || data.length == 0 || !response) {
        NSError *finalError = error ?: [NSError errorWithDomain:@"ChatGBeFree.ImageBridge"
                                                           code:4
                                                       userInfo:@{NSLocalizedDescriptionKey:
                                                           @"The generated image download returned no data."}];
        LVBLog(@"image asset Sediment bridge failed domain=%@ code=%ld",
               finalError.domain ?: @"unknown", (long)finalError.code);
        [self.client URLProtocol:self didFailWithError:finalError];
        return;
    }
    LVBLog(@"image asset Sediment bridge delivered mime=%@ bytes=%lu",
           response.MIMEType ?: @"unknown", (unsigned long)data.length);
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)lvb_fetchSignedImageURL:(NSURL *)URL {
    NSURL *resolvedURL = URL;
    NSURLComponents *assetComponents =
        [NSURLComponents componentsWithURL:self.request.URL
                   resolvingAgainstBaseURL:NO];
    if (assetComponents.percentEncodedQuery.length > 0) {
        NSURLComponents *downloadComponents =
            [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
        downloadComponents.percentEncodedQuery =
            assetComponents.percentEncodedQuery;
        resolvedURL = downloadComponents.URL ?: URL;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:resolvedURL];
    request.HTTPMethod = @"GET";
    NSDictionary<NSString *, NSString *> *contextHeaders = nil;
    @synchronized (LVBVoiceURLProtocol.class) {
        contextHeaders = LVBLastAPIAssetHeaders;
    }
    BOOL trustedAPIHost = LVBIsOpenAIHost(resolvedURL.host);
    [contextHeaders enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        NSString *lowerKey = key.lowercaseString;
        // The current Sediment request modifier retains normal client
        // identity headers. Only send account/bearer headers to OpenAI API
        // hosts; never leak them to a third-party signed CDN.
        if (trustedAPIHost || [lowerKey isEqualToString:@"user-agent"] ||
            [lowerKey isEqualToString:@"accept-language"]) {
            [request setValue:value forHTTPHeaderField:key];
        }
    }];
    [request setValue:@"image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
   forHTTPHeaderField:@"Accept"];
    NSURLSession *session = [self lvb_imageSession];
    self.forwardingSession = session;
    __weak typeof(self) weakSelf = self;
    self.forwardingTask = [session dataTaskWithRequest:request
                                    completionHandler:^(NSData *data,
                                                        NSURLResponse *response,
                                                        NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.stopped) {
            return;
        }
        NSHTTPURLResponse *HTTP = [response isKindOfClass:NSHTTPURLResponse.class] ?
            (NSHTTPURLResponse *)response : nil;
        LVBLog(@"image asset signed download status=%ld mime=%@ target=%@ response_header_keys=%@ transport_error=%@",
               (long)HTTP.statusCode,
               response.MIMEType.lowercaseString ?: @"unknown",
               LVBJSONString(CGBSafeAssetURLSummary(resolvedURL)),
               LVBSortedStringKeys(HTTP.allHeaderFields ?: @{}),
               error ? @"yes" : @"no");
        if (error || HTTP.statusCode < 200 || HTTP.statusCode >= 300) {
            NSError *HTTPError = error ?: [NSError errorWithDomain:@"ChatGBeFree.ImageBridge"
                                                               code:HTTP.statusCode
                                                           userInfo:@{NSLocalizedDescriptionKey:
                                                               @"The signed image URL was rejected."}];
            [self lvb_finishImageAssetWithData:nil response:nil error:HTTPError];
            return;
        }
        [self lvb_finishImageAssetWithData:data response:response error:nil];
    }];
    [self.forwardingTask resume];
}

- (void)lvb_tryImageDownloadLinkCandidates:(NSArray<NSURL *> *)candidates
                                      index:(NSUInteger)index {
    if (self.stopped) {
        return;
    }
    if (index >= candidates.count) {
        NSError *error = [NSError errorWithDomain:@"ChatGBeFree.ImageBridge"
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"The current file service did not return an image download link."}];
        [self lvb_finishImageAssetWithData:nil response:nil error:error];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:candidates[index]];
    request.HTTPMethod = @"GET";
    NSDictionary<NSString *, NSString *> *headers = nil;
    @synchronized (LVBVoiceURLProtocol.class) {
        headers = LVBLastAPIAssetHeaders;
    }
    [headers enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        [request setValue:value forHTTPHeaderField:key];
    }];
    [request setValue:@"application/json, image/*;q=0.9, */*;q=0.8"
   forHTTPHeaderField:@"Accept"];
    [NSURLProtocol setProperty:@YES forKey:LVBHandledRequestKey inRequest:request];

    NSURLSession *session = [self lvb_imageSession];
    self.forwardingSession = session;
    __weak typeof(self) weakSelf = self;
    self.forwardingTask = [session dataTaskWithRequest:request
                                    completionHandler:^(NSData *data,
                                                        NSURLResponse *response,
                                                        NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.stopped) {
            return;
        }
        NSHTTPURLResponse *HTTP = [response isKindOfClass:NSHTTPURLResponse.class] ?
            (NSHTTPURLResponse *)response : nil;
        NSString *mime = response.MIMEType.lowercaseString ?: @"";
        LVBLog(@"image asset download-link attempt=%lu status=%ld mime=%@ transport_error=%@",
               (unsigned long)(index + 1), (long)HTTP.statusCode,
               mime.length > 0 ? mime : @"unknown", error ? @"yes" : @"no");
        if (!error && HTTP.statusCode >= 200 && HTTP.statusCode < 300 && data.length > 0) {
            id JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *downloadURLString = LVBFindDownloadURLString(JSON, 0);
            NSURL *downloadURL = [NSURL URLWithString:downloadURLString ?: @""];
            if (downloadURL) {
                BOOL directKeyPresent =
                    LVBValueForNormalizedKey(JSON, @"directdownloadurl") != nil;
                LVBLog(@"image asset Sediment download link resolved attempt=%lu direct_key=%@ target=%@ response_shape=%@",
                       (unsigned long)(index + 1),
                       directKeyPresent ? @"yes" : @"no",
                       LVBJSONString(CGBSafeAssetURLSummary(downloadURL)),
                       LVBJSONString(LVBStructuralSummary(JSON, 0)));
                [self lvb_fetchSignedImageURL:downloadURL];
                return;
            }
            if ([mime hasPrefix:@"image/"] || !JSON) {
                [self lvb_finishImageAssetWithData:data response:response error:nil];
                return;
            }
        }
        [self lvb_tryImageDownloadLinkCandidates:candidates index:index + 1];
    }];
    [self.forwardingTask resume];
}

- (void)lvb_startImageAssetResolution {
    NSArray<NSURL *> *candidates = LVBImageDownloadLinkCandidates(self.request.URL);
    LVBLog(@"image asset Sediment resolver started source=%@ candidates=%lu auth_context=%@",
           LVBJSONString(CGBSafeAssetURLSummary(self.request.URL)),
           (unsigned long)candidates.count,
           LVBLastAPIAssetHeaders.count > 0 ? @"available" : @"missing");
    if (candidates.count == 0) {
        NSError *error = [NSError errorWithDomain:@"ChatGBeFree.ImageBridge"
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"The generated image locator did not contain a file identifier."}];
        [self lvb_finishImageAssetWithData:nil response:nil error:error];
        return;
    }
    [self lvb_tryImageDownloadLinkCandidates:candidates index:0];
}

- (void)lvb_startForwardingRequest:(NSURLRequest *)forwarded attempt:(NSString *)attempt {
    __weak typeof(self) weakSelf = self;
    self.forwardingTask = [self.forwardingSession dataTaskWithRequest:forwarded
                                                   completionHandler:^(NSData *data,
                                                                       NSURLResponse *response,
                                                                       NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.stopped) {
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ?
                                           (NSHTTPURLResponse *)response : nil;
        NSDictionary *responseJSON = LVBJSONDictionary(data);
        if (self.endpointKind == LVBEndpointModels && !error &&
            LVBIsSuccessfulHTTPResponse(response) && responseJSON) {
            NSArray<NSDictionary *> *catalogSummary = nil;
            NSDictionary *legacyCatalog = CGBLegacyModelCatalog(responseJSON, &catalogSummary);
            NSData *legacyData = legacyCatalog ?
                [NSJSONSerialization dataWithJSONObject:legacyCatalog options:0 error:nil] : nil;
            if (legacyData.length > 0) {
                data = legacyData;
                responseJSON = legacyCatalog;
                response = LVBResponseForRewrittenBody(httpResponse, data.length) ?: response;
                httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ?
                    (NSHTTPURLResponse *)response : httpResponse;
                LVBLog(@"model switcher published %lu live choices: %@",
                       (unsigned long)catalogSummary.count,
                       LVBJSONString(catalogSummary));
            } else {
                LVBLog(@"model switcher left catalog unchanged because it contained no compatible choices");
            }
        }
        if (self.endpointKind == LVBEndpointConversationDetail && !error &&
            LVBIsSuccessfulHTTPResponse(response) && responseJSON) {
            NSUInteger URLRewriteCount = 0;
            NSUInteger messageRewriteCount = 0;
            NSDictionary *legacyConversation = CGBLegacyImageCompatibleObject(
                responseJSON, &URLRewriteCount, &messageRewriteCount);
            NSData *legacyData = (URLRewriteCount > 0 || messageRewriteCount > 0) ?
                [NSJSONSerialization dataWithJSONObject:legacyConversation options:0 error:nil] : nil;
            if (legacyData.length > 0) {
                data = legacyData;
                responseJSON = legacyConversation;
                response = LVBResponseForRewrittenBody(httpResponse, data.length) ?: response;
                httpResponse = [response isKindOfClass:NSHTTPURLResponse.class] ?
                    (NSHTTPURLResponse *)response : httpResponse;
                LVBLog(@"conversation detail image bridge rewrote asset_urls=%lu image_messages=%lu",
                       (unsigned long)URLRewriteCount,
                       (unsigned long)messageRewriteCount);
            }
        }
        if (self.endpointKind == LVBEndpointVoiceStatus) {
            if (LVBIsSuccessfulHTTPResponse(response) && responseJSON) {
                LVBStoreVoiceStatusMetadata(responseJSON);
            }
            NSString *token = LVBFindChatreqToken(responseJSON);
            if (token.length > 0) {
                LVBStoreChatreqToken(token);
            } else {
                LVBLog(@"voice status response did not contain chatreq token");
            }
        }

        NSString *kind = LVBEndpointName(self.endpointKind);
        NSArray *responseKeys = responseJSON ? LVBSortedStringKeys(responseJSON) : @[];
        NSArray *responseHeaderKeys = httpResponse ?
            [httpResponse.allHeaderFields.allKeys sortedArrayUsingComparator:^NSComparisonResult(id first, id second) {
                return [[first description] compare:[second description]];
            }] : @[];
        LVBLog(@"response %@ attempt=%@ status=%ld bytes=%lu keys=%@ response_header_keys=%@ transport_error=%@ transport_domain=%@ transport_code=%ld",
               kind,
               attempt,
               (long)httpResponse.statusCode,
               (unsigned long)data.length,
               responseKeys,
               responseHeaderKeys,
               error ? @"yes" : @"no",
               error.domain ?: @"none",
               (long)error.code);

        if (httpResponse.statusCode >= 400 && responseJSON) {
            LVBLog(@"response %@ error_category=%@ safe_error=%@",
                   kind,
                   LVBErrorCategory(responseJSON),
                   LVBJSONString(LVBSafeErrorSummary(responseJSON, 0)));
        }

        if (self.endpointKind == LVBEndpointVoiceStatus &&
            !self.attemptedStatusAttestFallback &&
            LVBShouldAttemptStatusAttestFallback(forwarded, data, response, error)) {
            self.attemptedStatusAttestFallback = YES;
            self.initialStatusData = data;
            self.initialStatusResponse = response;
            self.initialStatusError = error;
            NSMutableURLRequest *fallback = LVBStatusAttestFallbackRequest(forwarded);
            LVBLog(@"retry voice-status with truthful App-Attest-unavailable sentinel; no assertion or token fabricated");
            [self lvb_startForwardingRequest:fallback attempt:@"attest-unavailable-fallback"];
            return;
        }

        if (self.endpointKind == LVBEndpointVoiceStatus &&
            self.attemptedStatusAttestFallback &&
            self.initialStatusResponse) {
            BOOL fallbackHasToken = LVBFindChatreqToken(responseJSON).length > 0;
            BOOL fallbackImprovedHTTP = LVBIsSuccessfulHTTPResponse(response) &&
                                        !LVBIsSuccessfulHTTPResponse(self.initialStatusResponse);
            if (!fallbackHasToken && !fallbackImprovedHTTP) {
                LVBLog(@"App-Attest-unavailable retry did not improve status; delivering primary response");
                data = self.initialStatusData;
                response = self.initialStatusResponse;
                error = self.initialStatusError;
            } else {
                @synchronized (LVBVoiceURLProtocol.class) {
                    LVBPreferStatusAttestUnavailableSentinel = YES;
                }
                LVBLog(@"App-Attest-unavailable retry improved voice status; delivering fallback response");
            }
        }

        if (self.endpointKind == LVBEndpointGetToken &&
            !error && httpResponse.statusCode == 404 &&
            !LVBGetTokenResponseLooksUsable(data, response, error)) {
            NSArray<NSString *> *changes = nil;
            NSMutableURLRequest *fallback = nil;
            NSString *fallbackAttempt = nil;
            if (!self.attemptedCurrentModeTokenFallback) {
                self.attemptedCurrentModeTokenFallback = YES;
                fallback = LVBCompatibilityGetTokenRequest(forwarded, NO, &changes);
                fallbackAttempt = @"server-current-mode-fallback";
            }
            if (!fallback && !self.attemptedStandardModeTokenFallback) {
                self.attemptedStandardModeTokenFallback = YES;
                fallback = LVBCompatibilityGetTokenRequest(forwarded, YES, &changes);
                fallbackAttempt = @"server-standard-mode-fallback";
            }
            if (fallback) {
                if (!self.initialGetTokenResponse) {
                    self.initialGetTokenData = data;
                    self.initialGetTokenResponse = response;
                    self.initialGetTokenError = error;
                }
                NSDictionary *fallbackBody = LVBJSONDictionary(fallback.HTTPBody);
                NSString *fallbackMode = LVBSafeIdentifier(
                    LVBValueForNormalizedKey(fallbackBody, @"voicemode"));
                NSString *fallbackModel = LVBSafeIdentifier(
                    LVBValueForNormalizedKey(fallbackBody, @"modelslug"));
                LVBLog(@"retry get-token attempt=%@ changes=%@ mode=%@ model=%@",
                       fallbackAttempt,
                       changes ?: @[],
                       fallbackMode ?: @"none-or-redacted",
                       fallbackModel ?: @"none-or-redacted");
                [self lvb_startForwardingRequest:fallback attempt:fallbackAttempt];
                return;
            }
        }

        if (self.endpointKind == LVBEndpointGetToken && self.initialGetTokenResponse) {
            if (LVBGetTokenResponseLooksUsable(data, response, error)) {
                LVBLog(@"get-token compatibility fallback returned a usable LiveKit credential response");
            } else {
                LVBLog(@"get-token compatibility fallbacks did not return usable LiveKit credentials; delivering primary response");
                data = self.initialGetTokenData;
                response = self.initialGetTokenResponse;
                error = self.initialGetTokenError;
            }
        }

        if (error) {
            [self.client URLProtocol:self didFailWithError:error];
        } else {
            if (response) {
                [self.client URLProtocol:self
                      didReceiveResponse:response
                      cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            }
            if (data.length > 0) {
                [self.client URLProtocol:self didLoadData:data];
            }
            [self.client URLProtocolDidFinishLoading:self];
        }
        [self.forwardingSession finishTasksAndInvalidate];
        self.forwardingTask = nil;
        self.forwardingSession = nil;
    }];
    [self.forwardingTask resume];
}

static NSData *LVBConversationImageEventData(NSDictionary *message,
                                             NSString *conversationIdentifier) {
    if (![message isKindOfClass:NSDictionary.class] || conversationIdentifier.length == 0) {
        return nil;
    }
    NSDictionary *event = @{
        @"message": message,
        @"conversation_id": conversationIdentifier,
        @"error": NSNull.null,
    };
    NSData *JSON = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (JSON.length == 0) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    [data appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
    [data appendData:JSON];
    [data appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}

- (NSMutableURLRequest *)lvb_imagePollingRequest {
    if (self.conversationIdentifier.length == 0) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:self.request.URL
                                             resolvingAgainstBaseURL:NO];
    NSString *path = components.path ?: @"";
    NSRange conversationRange = [path rangeOfString:@"/conversation"
                                             options:NSBackwardsSearch];
    if (conversationRange.location == NSNotFound) {
        return nil;
    }
    NSString *basePath = [path substringToIndex:NSMaxRange(conversationRange)];
    components.path = [basePath stringByAppendingFormat:@"/%@", self.conversationIdentifier];
    components.query = nil;
    components.fragment = nil;
    NSURL *URL = components.URL;
    if (!URL) {
        return nil;
    }

    NSMutableURLRequest *request = [self.request mutableCopy];
    request.URL = URL;
    request.HTTPMethod = @"GET";
    request.HTTPBody = nil;
    request.HTTPBodyStream = nil;
    for (NSString *header in @[@"Content-Length", @"Content-Type", @"Content-MD5",
                                @"Transfer-Encoding"]) {
        [request setValue:nil forHTTPHeaderField:header];
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [NSURLProtocol setProperty:@YES forKey:LVBHandledRequestKey inRequest:request];
    return request;
}

- (void)lvb_scheduleNextImagePoll {
    if (self.stopped || self.completedClient) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.stopped || self.completedClient) {
            return;
        }
        [self lvb_beginImagePollingIfNeeded];
    });
}

- (void)lvb_beginImagePollingIfNeeded {
    if (self.stopped || self.completedClient || !self.conversationHeldDone ||
        !self.conversationDetectedAsyncImage || self.conversationSawImageOutput ||
        !self.conversationTransportCompleted || self.imagePollingTask) {
        return;
    }
    NSMutableURLRequest *request = [self lvb_imagePollingRequest];
    if (!request) {
        if (self.conversationTransportCompleted) {
            LVBLog(@"conversation image bridge could not poll because the stream exposed no conversation identifier");
            [self lvb_finishStreamingConversationWithError:self.conversationTransportError];
        }
        return;
    }

    static const NSUInteger LVBMaximumImagePollAttempts = 90;
    if (self.imagePollAttempt >= LVBMaximumImagePollAttempts) {
        LVBLog(@"conversation image bridge timed out after %lu polls without a generated-image result",
               (unsigned long)self.imagePollAttempt);
        [self lvb_finishStreamingConversationWithError:self.conversationTransportError];
        return;
    }
    self.imagePollAttempt++;

    if (!self.imagePollingSession) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        NSMutableArray<Class> *protocolClasses = [configuration.protocolClasses mutableCopy] ?:
            [NSMutableArray array];
        [protocolClasses removeObject:LVBVoiceURLProtocol.class];
        configuration.protocolClasses = protocolClasses;
        configuration.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
        configuration.URLCredentialStorage = NSURLCredentialStorage.sharedCredentialStorage;
        configuration.HTTPShouldSetCookies = YES;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        self.imagePollingSession = [NSURLSession sessionWithConfiguration:configuration];
    }

    __weak typeof(self) weakSelf = self;
    self.imagePollingTask = [self.imagePollingSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.stopped || self.completedClient) {
            return;
        }
        self.imagePollingTask = nil;
        NSHTTPURLResponse *HTTPResponse = [response isKindOfClass:NSHTTPURLResponse.class] ?
            (NSHTTPURLResponse *)response : nil;
        NSDictionary *conversation = LVBJSONDictionary(data);
        NSArray<NSDictionary *> *messages = nil;
        if (!error && HTTPResponse.statusCode >= 200 && HTTPResponse.statusCode < 300 &&
            conversation) {
            messages = CGBLegacyGeneratedImageMessages(
                conversation, self.imageTurnExchangeIdentifier,
                MAX(0, self.conversationStartedAt - 10.0));
        }

        NSUInteger deliveredCount = 0;
        for (NSDictionary *message in messages ?: @[]) {
            NSString *messageIdentifier = LVBSafeIdentifier(
                LVBValueForNormalizedKey(message, @"id"));
            if (messageIdentifier.length > 0 &&
                [self.deliveredImageMessageIdentifiers containsObject:messageIdentifier]) {
                continue;
            }
            NSData *eventData = LVBConversationImageEventData(
                message, self.conversationIdentifier);
            if (eventData.length == 0) {
                continue;
            }
            if (messageIdentifier.length > 0) {
                [self.deliveredImageMessageIdentifiers addObject:messageIdentifier];
            }
            [self.client URLProtocol:self didLoadData:eventData];
            deliveredCount++;
        }

        if (deliveredCount > 0) {
            self.conversationSawImageOutput = YES;
            LVBLog(@"conversation image bridge delivered %lu asynchronous generated-image message(s) after %lu poll(s)",
                   (unsigned long)deliveredCount,
                   (unsigned long)self.imagePollAttempt);
            [self lvb_finishStreamingConversationWithError:nil];
            return;
        }

        BOOL authenticationFailure = HTTPResponse.statusCode == 401 ||
                                     HTTPResponse.statusCode == 403;
        if (authenticationFailure) {
            LVBLog(@"conversation image poll authentication failed status=%ld",
                   (long)HTTPResponse.statusCode);
            [self lvb_finishStreamingConversationWithError:self.conversationTransportError];
            return;
        }
        if (self.imagePollAttempt == 1 || self.imagePollAttempt % 10 == 0) {
            LVBLog(@"conversation image poll pending attempt=%lu status=%ld transport_error=%@",
                   (unsigned long)self.imagePollAttempt,
                   (long)HTTPResponse.statusCode,
                   error ? @"yes" : @"no");
        }
        [self lvb_scheduleNextImagePoll];
    }];
    [self.imagePollingTask resume];
}

- (void)lvb_finishStreamingConversationWithError:(NSError *)error {
    @synchronized (self) {
        if (self.completedClient || self.stopped) {
            return;
        }
        self.completedClient = YES;
    }

    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        if (self.conversationHeldDone) {
            NSData *doneData = [@"data: [DONE]\n\n" dataUsingEncoding:NSUTF8StringEncoding];
            [self.client URLProtocol:self didLoadData:doneData];
        }
        [self.client URLProtocolDidFinishLoading:self];
    }
    [self.imagePollingTask cancel];
    [self.imagePollingSession invalidateAndCancel];
    self.imagePollingTask = nil;
    self.imagePollingSession = nil;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    (void)dataTask;
    if (self.stopped) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    self.streamingHTTPResponse = [response isKindOfClass:NSHTTPURLResponse.class] ?
        (NSHTTPURLResponse *)response : nil;
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    (void)dataTask;
    if (!self.stopped && data.length > 0) {
        self.streamedByteCount += data.length;
        NSData *readyData = LVBTransformConversationSSEData(self, data);
        if (readyData.length > 0) {
            [self.client URLProtocol:self didLoadData:readyData];
        }
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)task;
    if (self.stopped) {
        return;
    }
    NSString *kind = LVBEndpointName(self.endpointKind);
    LVBLog(@"response %@ status=%ld bytes=%lu transport_error=%@ transport_domain=%@ transport_code=%ld",
           kind,
           (long)self.streamingHTTPResponse.statusCode,
           (unsigned long)self.streamedByteCount,
           error ? @"yes" : @"no",
           error.domain ?: @"none",
           (long)error.code);
    if (self.conversationSSEBuffer.length > 0) {
        NSData *finalEvent = [self.conversationSSEBuffer copy];
        [self.conversationSSEBuffer setLength:0];
        NSData *transformed = LVBTransformConversationSSEEvent(self, finalEvent);
        if (transformed.length > 0) {
            [self.client URLProtocol:self didLoadData:transformed];
        }
    }
    self.conversationTransportCompleted = YES;
    self.conversationTransportError = error;
    [session finishTasksAndInvalidate];
    self.forwardingTask = nil;
    self.forwardingSession = nil;
    self.streamingHTTPResponse = nil;
    self.conversationSSEBuffer = nil;
    self.loggedImageEventSummaries = nil;

    if (self.conversationHeldDone && self.conversationDetectedAsyncImage &&
        !self.conversationSawImageOutput) {
        [self lvb_beginImagePollingIfNeeded];
        return;
    }
    [self lvb_finishStreamingConversationWithError:error];
}

- (void)stopLoading {
    self.stopped = YES;
    [self.forwardingTask cancel];
    [self.forwardingSession invalidateAndCancel];
    [self.imagePollingTask cancel];
    [self.imagePollingSession invalidateAndCancel];
    self.forwardingTask = nil;
    self.forwardingSession = nil;
    self.imagePollingTask = nil;
    self.imagePollingSession = nil;
}

@end

static void LVBFileServiceStartLoadingHook(id instance, SEL selector) {
    NSURLProtocol *nativeProtocol = (NSURLProtocol *)instance;
    NSURLRequest *request = nativeProtocol.request;
    if ([request.URL.scheme.lowercaseString isEqualToString:@"file-service"]) {
        LVBVoiceURLProtocol *bridge =
            [[LVBVoiceURLProtocol alloc] initWithRequest:request
                                         cachedResponse:nativeProtocol.cachedResponse
                                                 client:nativeProtocol.client];
        if (bridge) {
            objc_setAssociatedObject(nativeProtocol,
                                     LVBFileServiceBridgeAssociationKey,
                                     bridge,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LVBLog(@"image asset request intercepted at legacy FileServiceProtocol.startLoading");
            [bridge startLoading];
            return;
        }
    }
    if (LVBOriginalFileServiceStartLoading) {
        LVBOriginalFileServiceStartLoading(instance, selector);
    }
}

static void LVBFileServiceStopLoadingHook(id instance, SEL selector) {
    NSURLProtocol *nativeProtocol = (NSURLProtocol *)instance;
    LVBVoiceURLProtocol *bridge =
        objc_getAssociatedObject(nativeProtocol,
                                 LVBFileServiceBridgeAssociationKey);
    if (bridge) {
        [bridge stopLoading];
        objc_setAssociatedObject(nativeProtocol,
                                 LVBFileServiceBridgeAssociationKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (LVBOriginalFileServiceStopLoading) {
        LVBOriginalFileServiceStopLoading(instance, selector);
    }
}

static void LVBInstallFileServiceInterposition(void) {
    if (LVBFileServiceInterpositionInstalled) {
        return;
    }
    Class protocolClass = LVBFileServiceProtocolClass();
    if (!protocolClass) {
        return;
    }
    MSHookMessageEx(protocolClass,
                    @selector(startLoading),
                    (IMP)&LVBFileServiceStartLoadingHook,
                    (IMP *)&LVBOriginalFileServiceStartLoading);
    MSHookMessageEx(protocolClass,
                    @selector(stopLoading),
                    (IMP)&LVBFileServiceStopLoadingHook,
                    (IMP *)&LVBOriginalFileServiceStopLoading);
    LVBFileServiceInterpositionInstalled =
        LVBOriginalFileServiceStartLoading != NULL &&
        LVBOriginalFileServiceStopLoading != NULL;
    LVBLog(LVBFileServiceInterpositionInstalled ?
        @"legacy FileServiceProtocol image interposition installed" :
        @"legacy FileServiceProtocol image interposition unavailable");
}

@interface NSBundle (LegacyVoiceBridge)
- (NSDictionary *)lvb_infoDictionary;
- (NSDictionary *)lvb_localizedInfoDictionary;
- (id)lvb_objectForInfoDictionaryKey:(NSString *)key;
@end

@implementation NSBundle (LegacyVoiceBridge)

- (BOOL)lvb_isChatGPTMainBundle {
    return self == LVBMainBundle;
}

- (NSDictionary *)lvb_infoDictionary {
    NSDictionary *original = [self lvb_infoDictionary];
    if (![self lvb_isChatGPTMainBundle]) {
        return original;
    }
    NSMutableDictionary *modified = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    modified[@"CFBundleShortVersionString"] = LVBVersion;
    modified[@"CFBundleVersion"] = LVBBuild;
    return modified;
}

- (NSDictionary *)lvb_localizedInfoDictionary {
    NSDictionary *original = [self lvb_localizedInfoDictionary];
    if (![self lvb_isChatGPTMainBundle]) {
        return original;
    }
    NSMutableDictionary *modified = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    modified[@"CFBundleShortVersionString"] = LVBVersion;
    modified[@"CFBundleVersion"] = LVBBuild;
    return modified;
}

- (id)lvb_objectForInfoDictionaryKey:(NSString *)key {
    if ([self lvb_isChatGPTMainBundle]) {
        if ([key isEqualToString:@"CFBundleShortVersionString"]) {
            return LVBVersion;
        }
        if ([key isEqualToString:@"CFBundleVersion"]) {
            return LVBBuild;
        }
    }
    return [self lvb_objectForInfoDictionaryKey:key];
}

@end

@interface NSURLSessionConfiguration (LegacyVoiceBridge)
+ (NSURLSessionConfiguration *)lvb_defaultSessionConfiguration;
+ (NSURLSessionConfiguration *)lvb_ephemeralSessionConfiguration;
+ (NSURLSessionConfiguration *)lvb_backgroundSessionConfigurationWithIdentifier:(NSString *)identifier;
@end

static void LVBPrependProtocolClass(NSURLSessionConfiguration *configuration) {
    NSArray<Class> *currentClasses = configuration.protocolClasses ?: @[];
    if ([currentClasses containsObject:LVBVoiceURLProtocol.class]) {
        return;
    }
    configuration.protocolClasses = [@[LVBVoiceURLProtocol.class] arrayByAddingObjectsFromArray:currentClasses];
}

@implementation NSURLSessionConfiguration (LegacyVoiceBridge)

+ (NSURLSessionConfiguration *)lvb_defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = [self lvb_defaultSessionConfiguration];
    LVBPrependProtocolClass(configuration);
    return configuration;
}

+ (NSURLSessionConfiguration *)lvb_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = [self lvb_ephemeralSessionConfiguration];
    LVBPrependProtocolClass(configuration);
    return configuration;
}

+ (NSURLSessionConfiguration *)lvb_backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *configuration = [self lvb_backgroundSessionConfigurationWithIdentifier:identifier];
    LVBPrependProtocolClass(configuration);
    return configuration;
}

@end

static void LVBSwizzleInstanceMethod(Class cls, SEL originalSelector, SEL replacementSelector) {
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (original && replacement) {
        method_exchangeImplementations(original, replacement);
    }
}

static void LVBSwizzleClassMethod(Class cls, SEL originalSelector, SEL replacementSelector) {
    Method original = class_getClassMethod(cls, originalSelector);
    Method replacement = class_getClassMethod(cls, replacementSelector);
    if (original && replacement) {
        method_exchangeImplementations(original, replacement);
    }
}

__attribute__((constructor)) static void LegacyVoiceBridgeInitialize(void) {
    @autoreleasepool {
        LVBLogQueue = dispatch_queue_create("com.local.LegacyVoiceBridge.log", DISPATCH_QUEUE_SERIAL);
        LVBMainBundle = NSBundle.mainBundle;

        LVBSwizzleInstanceMethod(NSBundle.class,
                                 @selector(infoDictionary),
                                 @selector(lvb_infoDictionary));
        LVBSwizzleInstanceMethod(NSBundle.class,
                                 @selector(localizedInfoDictionary),
                                 @selector(lvb_localizedInfoDictionary));
        LVBSwizzleInstanceMethod(NSBundle.class,
                                 @selector(objectForInfoDictionaryKey:),
                                 @selector(lvb_objectForInfoDictionaryKey:));

        LVBSwizzleClassMethod(NSURLSessionConfiguration.class,
                              @selector(defaultSessionConfiguration),
                              @selector(lvb_defaultSessionConfiguration));
        LVBSwizzleClassMethod(NSURLSessionConfiguration.class,
                              @selector(ephemeralSessionConfiguration),
                              @selector(lvb_ephemeralSessionConfiguration));
        LVBSwizzleClassMethod(NSURLSessionConfiguration.class,
                              @selector(backgroundSessionConfigurationWithIdentifier:),
                              @selector(lvb_backgroundSessionConfigurationWithIdentifier:));

        [NSURLProtocol registerClass:LVBVoiceURLProtocol.class];
        LVBInstallFileServiceInterposition();
        dispatch_async(dispatch_get_main_queue(), ^{
            LVBInstallFileServiceInterposition();
        });
        CGBInstallLegacyCopyBridge();
        CGBInstallLegacyModelSelectionPersistenceBridge();
        LVBInstallLegacyNativeVoiceLifecycleBridge();
        LVBLog(@"loaded; revision=%@ reported_version=%@ reported_build=%@ log=%@",
               LVBRevision, LVBVersion, LVBBuild, LVBLogFilePath());
    }
}
