#import "LegacyRealtimeVoice.h"
#import "LegacyNativeVoiceLifecycle.h"
#import "LegacySDPTransform.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

// LiveKitWebRTC is already bundled in the iOS 16-compatible ChatGPT IPA. The
// shipped binary does not include public headers, so declare only the stable
// Objective-C surface used by this bridge (it mirrors Google's WebRTC API).
@class LKRTCAudioSource;
@class LKRTCAudioTrack;
@class LKRTCConfiguration;
@class LKRTCDataBuffer;
@class LKRTCDataChannel;
@class LKRTCDataChannelConfiguration;
@class LKRTCIceCandidate;
@class LKRTCMediaConstraints;
@class LKRTCMediaStream;
@class LKRTCMediaStreamTrack;
@class LKRTCPeerConnection;
@class LKRTCPeerConnectionFactory;
@class LKRTCRtpReceiver;
@class LKRTCRtpSender;
@class LKRTCRtpTransceiver;
@class LKRTCRtpTransceiverInit;
@class LKRTCSessionDescription;

@protocol LKRTCDataChannelDelegate <NSObject>
- (void)dataChannelDidChangeState:(LKRTCDataChannel *)dataChannel;
- (void)dataChannel:(LKRTCDataChannel *)dataChannel
    didReceiveMessageWithBuffer:(LKRTCDataBuffer *)buffer;
@end

@protocol LKRTCPeerConnectionDelegate <NSObject>
@optional
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeSignalingState:(NSInteger)state;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didAddStream:(LKRTCMediaStream *)stream;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didRemoveStream:(LKRTCMediaStream *)stream;
- (void)peerConnectionShouldNegotiate:(LKRTCPeerConnection *)peerConnection;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeIceConnectionState:(NSInteger)state;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeIceGatheringState:(NSInteger)state;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didGenerateIceCandidate:(LKRTCIceCandidate *)candidate;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didRemoveIceCandidates:(NSArray<LKRTCIceCandidate *> *)candidates;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didOpenDataChannel:(LKRTCDataChannel *)dataChannel;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeConnectionState:(NSInteger)state;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didAddReceiver:(LKRTCRtpReceiver *)receiver
    streams:(NSArray<LKRTCMediaStream *> *)streams;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didRemoveReceiver:(LKRTCRtpReceiver *)receiver;
- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didStartReceivingOnTransceiver:(LKRTCRtpTransceiver *)transceiver;
@end

@interface LKRTCMediaConstraints : NSObject
- (instancetype)initWithMandatoryConstraints:(nullable NSDictionary<NSString *, NSString *> *)mandatory
                          optionalConstraints:(nullable NSDictionary<NSString *, NSString *> *)optional;
@end

@interface LKRTCConfiguration : NSObject
- (void)setBundlePolicy:(NSInteger)bundlePolicy;
- (void)setSdpSemantics:(NSInteger)sdpSemantics;
@end

@interface LKRTCMediaStreamTrack : NSObject
- (void)setIsEnabled:(BOOL)enabled;
@end

@interface LKRTCAudioTrack : LKRTCMediaStreamTrack
@end

@interface LKRTCRtpSender : NSObject
- (void)setTrack:(nullable LKRTCMediaStreamTrack *)track;
@end

@interface LKRTCRtpTransceiver : NSObject
@property(nonatomic, readonly) LKRTCRtpSender *sender;
@end

@interface LKRTCRtpTransceiverInit : NSObject
- (void)setDirection:(NSInteger)direction;
- (void)setStreamIds:(NSArray<NSString *> *)streamIds;
@end

@interface LKRTCPeerConnectionFactory : NSObject
- (LKRTCAudioSource *)audioSourceWithConstraints:(nullable LKRTCMediaConstraints *)constraints;
- (LKRTCAudioTrack *)audioTrackWithSource:(LKRTCAudioSource *)source
                                  trackId:(NSString *)trackId;
- (LKRTCPeerConnection *)peerConnectionWithConfiguration:(LKRTCConfiguration *)configuration
                                              constraints:(LKRTCMediaConstraints *)constraints
                                                 delegate:(id<LKRTCPeerConnectionDelegate>)delegate;
@end

@interface LKRTCDataChannelConfiguration : NSObject
- (void)setIsOrdered:(BOOL)ordered;
- (void)setChannelId:(NSInteger)channelId;
- (void)setIsNegotiated:(BOOL)negotiated;
@end

@interface LKRTCDataBuffer : NSObject
@property(nonatomic, readonly) NSData *data;
@property(nonatomic, readonly) BOOL isBinary;
- (instancetype)initWithData:(NSData *)data isBinary:(BOOL)isBinary;
@end

@interface LKRTCDataChannel : NSObject
@property(nonatomic, weak, nullable) id<LKRTCDataChannelDelegate> delegate;
@property(nonatomic, readonly) NSInteger readyState;
- (void)close;
@end

@interface LKRTCSessionDescription : NSObject
@property(nonatomic, readonly) NSString *sdp;
- (instancetype)initWithType:(NSInteger)type sdp:(NSString *)sdp;
@end

@interface LKRTCPeerConnection : NSObject
@property(nonatomic, readonly, nullable) LKRTCSessionDescription *localDescription;
@property(nonatomic, readonly) NSInteger iceGatheringState;
- (nullable LKRTCRtpTransceiver *)addTransceiverOfType:(NSInteger)mediaType
                                                   init:(LKRTCRtpTransceiverInit *)transceiverInit;
- (nullable LKRTCDataChannel *)dataChannelForLabel:(NSString *)label
                                      configuration:(LKRTCDataChannelConfiguration *)configuration;
- (void)offerForConstraints:(LKRTCMediaConstraints *)constraints
           completionHandler:(void (^)(LKRTCSessionDescription *_Nullable sdp,
                                       NSError *_Nullable error))completionHandler;
- (void)setLocalDescription:(LKRTCSessionDescription *)sdp
          completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
- (void)setRemoteDescription:(LKRTCSessionDescription *)sdp
           completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
- (void)close;
@end

typedef NS_ENUM(NSInteger, LRVConnectionState) {
    LRVConnectionStateIdle = 0,
    LRVConnectionStateStarting,
    LRVConnectionStateConnected,
    LRVConnectionStateFailed,
    LRVConnectionStateEnded,
};

@class LVBRealtimeVoiceSession;

@interface LRVVoiceViewController : UIViewController
@property(nonatomic, weak) LVBRealtimeVoiceSession *session;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIView *orbView;
@property(nonatomic, strong) UIButton *muteButton;
@property(nonatomic, strong) UIButton *endButton;
@property(nonatomic) BOOL retryMode;
- (void)setVoiceStatus:(NSString *)status detail:(NSString *)detail;
- (void)setConnected:(BOOL)connected;
- (void)setFailed:(BOOL)failed detail:(NSString *)detail;
@end

@interface LVBRealtimeVoiceSession : NSObject <LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate>
@property(nonatomic, copy) NSURLRequest *sourceRequest;
@property(nonatomic, copy) NSDictionary<NSString *, id> *sourceBody;
@property(nonatomic, strong) UIWindow *overlayWindow;
@property(nonatomic, strong) LRVVoiceViewController *overlayController;
@property(nonatomic, strong) LKRTCPeerConnectionFactory *factory;
@property(nonatomic, strong) LKRTCPeerConnection *peerConnection;
@property(nonatomic, strong) LKRTCAudioTrack *audioTrack;
@property(nonatomic, strong) LKRTCRtpTransceiver *audioTransceiver;
@property(nonatomic, strong) LKRTCRtpTransceiver *videoTransceiver;
@property(nonatomic, strong) LKRTCDataChannel *dataChannel;
@property(nonatomic, strong) LKRTCDataChannel *serverDataChannel;
@property(nonatomic, strong) NSURLSession *signalingSession;
@property(nonatomic, strong) NSURLSessionDataTask *signalingTask;
@property(nonatomic, strong) dispatch_queue_t transportQueue;
@property(nonatomic, copy) NSArray<NSURL *> *endpointCandidates;
@property(nonatomic) NSUInteger endpointIndex;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) LRVConnectionState state;
@property(nonatomic) BOOL muted;
@property(nonatomic, copy) NSString *pendingOfferSDP;
@property(nonatomic) NSUInteger pendingOfferGeneration;
@property(nonatomic) BOOL signalingOfferStarted;
@property(nonatomic, strong) NSDate *lastUserEndDate;
@property(nonatomic, copy) NSString *activeVoiceSessionID;
@property(nonatomic, copy) NSString *lastEndedVoiceSessionID;
@property(nonatomic) CFTimeInterval startRequestedAt;
@property(nonatomic) CFTimeInterval voiceButtonTappedAt;
@property(nonatomic) BOOL legacyVoicePresentationDismissed;
@property(nonatomic) BOOL awaitingLegacyVoiceRequest;
@property(nonatomic) NSUInteger preparationGeneration;
+ (instancetype)sharedSession;
- (void)prepareForLegacyStart;
- (void)startWithRequest:(NSURLRequest *)request body:(NSDictionary<NSString *, id> *)body;
- (void)toggleMuteOrRetry;
- (void)endByUser;
- (void)configureAudioSession;
- (void)markTransportConnected;
- (void)queueOfferForSignaling:(NSString *)offerSDP generation:(NSUInteger)generation;
- (void)signalPendingOfferForGeneration:(NSUInteger)generation allowIncompleteICE:(BOOL)allowIncompleteICE;
- (void)postSessionData:(NSData *)sessionData
               offerSDP:(NSString *)offerSDP
             generation:(NSUInteger)generation
               endpoint:(NSURL *)retryEndpoint
        rawSDPTransport:(BOOL)rawSDPTransport;
@end

static NSString *LRVSafeString(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (string.length == 0 || string.length > 128) {
        return nil;
    }
    return string;
}

static void LRVRunOnMain(dispatch_block_t block) {
    if (!block) {
        return;
    }
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static NSString *LRVVoiceSessionIdentifier(NSDictionary<NSString *, id> *body) {
    for (NSString *key in body) {
        if (![key isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *normalized = [[key.lowercaseString
            stringByReplacingOccurrencesOfString:@"_" withString:@""]
            stringByReplacingOccurrencesOfString:@"-" withString:@""];
        if ([normalized isEqualToString:@"voicesessionid"] ||
            [normalized isEqualToString:@"sessionid"]) {
            return LRVSafeString(body[key]);
        }
    }
    return nil;
}

static void LRVProvideTapFeedback(void) {
    UIImpactFeedbackGenerator *generator =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator prepare];
    [generator impactOccurred];
}

static long LRVElapsedMilliseconds(CFTimeInterval startTime) {
    if (startTime <= 0.0) {
        return 0;
    }
    return (long)llround((CACurrentMediaTime() - startTime) * 1000.0);
}

static void LRVLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void LRVLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    LVBRealtimeVoiceLog(message);
}

static NSString *LRVEventTypeFromData(NSData *data) {
    if (data.length == 0 || data.length > (1024 * 1024)) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary *dictionary = (NSDictionary *)object;
    NSString *type = LRVSafeString(dictionary[@"type"]);
    NSString *nestedString = LRVSafeString(dictionary[@"data"]);
    if (nestedString.length > 0) {
        NSData *nestedData = [nestedString dataUsingEncoding:NSUTF8StringEncoding];
        id nestedObject = nestedData ?
            [NSJSONSerialization JSONObjectWithData:nestedData options:0 error:nil] : nil;
        if ([nestedObject isKindOfClass:NSDictionary.class]) {
            NSString *nestedType = LRVSafeString(((NSDictionary *)nestedObject)[@"type"]);
            if (nestedType.length > 0) {
                return nestedType;
            }
        }
    }
    return type;
}

static NSString *LRVServerErrorCategory(id object) {
    if (!object) {
        return @"none";
    }
    NSString *description = [[object description] lowercaseString];
    if ([description containsString:@"attest"] || [description containsString:@"sentinel"]) {
        return @"attestation";
    }
    if ([description containsString:@"unauthor"] || [description containsString:@"forbidden"] ||
        [description containsString:@"authentication"] || [description containsString:@"credential"]) {
        return @"authorization";
    }
    if ([description containsString:@"rate"] && [description containsString:@"limit"]) {
        return @"rate-limit";
    }
    if ([description containsString:@"sdp"] || [description containsString:@"offer"]) {
        return @"sdp";
    }
    if ([description containsString:@"session"] || [description containsString:@"payload"] ||
        [description containsString:@"field"] || [description containsString:@"missing"]) {
        return @"session-payload";
    }
    if ([description containsString:@"voice"] || [description containsString:@"model"]) {
        return @"voice-or-model";
    }
    if ([description containsString:@"device"] || [description containsString:@"dcid"]) {
        return @"device-id";
    }
    if ([description containsString:@"route"] || [description containsString:@"not found"] ||
        [description containsString:@"endpoint"]) {
        return @"route";
    }
    return @"other";
}

static NSString *LRVSanitizeServerDiagnostic(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) {
        return nil;
    }
    NSString *bounded = value.length > 1200 ? [value substringToIndex:1200] : value;
    NSMutableString *result = [bounded mutableCopy];
    NSArray<NSString *> *patterns = @[
        @"(?i)bearer\\s+[A-Za-z0-9._~+/=-]+",
        @"(?i)a=(?:ice-pwd|ice-ufrag|fingerprint|candidate):[^\\r\\n\\\"']+",
        @"(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b",
        @"\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b",
        @"\\b[A-Za-z0-9_-]{48,}\\b",
    ];
    for (NSString *pattern in patterns) {
        NSRegularExpression *expression =
            [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        [expression replaceMatchesInString:result
                                   options:0
                                     range:NSMakeRange(0, result.length)
                              withTemplate:@"<redacted>"];
    }
    NSRegularExpression *whitespace =
        [NSRegularExpression regularExpressionWithPattern:@"[\\r\\n\\t]+" options:0 error:nil];
    [whitespace replaceMatchesInString:result
                               options:0
                                 range:NSMakeRange(0, result.length)
                          withTemplate:@" "];
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void LRVCollectServerDiagnosticFields(id object,
                                             NSString *path,
                                             NSUInteger depth,
                                             NSMutableArray<NSString *> *fields) {
    if (!object || depth > 4 || fields.count >= 16) {
        return;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSSet<NSString *> *allowedKeys = [NSSet setWithArray:@[
            @"code", @"detail", @"error", @"field", @"loc", @"message",
            @"msg", @"param", @"reason", @"type"
        ]];
        NSArray *keys = [[(NSDictionary *)object allKeys]
            sortedArrayUsingComparator:^NSComparisonResult(id first, id second) {
                return [[first description] compare:[second description]];
            }];
        for (id rawKey in keys) {
            NSString *key = [rawKey isKindOfClass:NSString.class] ? rawKey : [rawKey description];
            if (![allowedKeys containsObject:key.lowercaseString]) {
                continue;
            }
            NSString *nextPath = path.length > 0 ?
                [path stringByAppendingFormat:@".%@", key] : key;
            LRVCollectServerDiagnosticFields(((NSDictionary *)object)[rawKey],
                                             nextPath,
                                             depth + 1,
                                             fields);
        }
        return;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSUInteger index = 0;
        for (id value in (NSArray *)object) {
            if (index >= 8 || fields.count >= 16) {
                break;
            }
            LRVCollectServerDiagnosticFields(value,
                                             [path stringByAppendingFormat:@"[%lu]",
                                              (unsigned long)index],
                                             depth + 1,
                                             fields);
            index += 1;
        }
        return;
    }
    NSString *value = nil;
    if ([object isKindOfClass:NSString.class]) {
        value = object;
    } else if ([object isKindOfClass:NSNumber.class]) {
        value = [(NSNumber *)object stringValue];
    }
    NSString *safeValue = LRVSanitizeServerDiagnostic(value);
    if (safeValue.length > 0) {
        [fields addObject:[NSString stringWithFormat:@"%@=%@", path, safeValue]];
    }
}

static NSString *LRVSafeServerDiagnostic(id object) {
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    LRVCollectServerDiagnosticFields(object, @"", 0, fields);
    NSString *joined = [fields componentsJoinedByString:@" | "];
    if (joined.length > 1600) {
        return [[joined substringToIndex:1600] stringByAppendingString:@"…"];
    }
    return joined.length > 0 ? joined : @"unavailable";
}

static BOOL LRVResponseRequestsRawSDP(id object) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *dictionary = (NSDictionary *)object;
    id error = dictionary[@"error"];
    NSDictionary *errorDictionary = [error isKindOfClass:NSDictionary.class] ? error : dictionary;
    NSString *code = LRVSafeString(errorDictionary[@"code"]);
    return [code isEqualToString:@"unsupported_content_type"];
}

static void LRVAppendUTF8String(NSMutableData *data, NSString *string) {
    NSData *encoded = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (encoded.length > 0) {
        [data appendData:encoded];
    }
}

static NSData *LRVMultipartSignalingBody(NSString *offerSDP,
                                         NSData *sessionData,
                                         NSString **contentType) {
    // VoiceModeTransceiverSignalingAPI.exchange in the 2026 IPA constructs two
    // encoder emits only Content-Disposition for these parts.
    NSString *boundary = [NSUUID UUID].UUIDString;
    NSMutableData *body = [NSMutableData data];
    LRVAppendUTF8String(body, [NSString stringWithFormat:@"--%@\r\n", boundary]);
    LRVAppendUTF8String(body, @"Content-Disposition: form-data; name=\"sdp\"\r\n\r\n");
    LRVAppendUTF8String(body, offerSDP);
    LRVAppendUTF8String(body, [NSString stringWithFormat:@"\r\n--%@\r\n", boundary]);
    LRVAppendUTF8String(body, @"Content-Disposition: form-data; name=\"session\"\r\n\r\n");
    [body appendData:sessionData];
    LRVAppendUTF8String(body, [NSString stringWithFormat:@"\r\n--%@--\r\n", boundary]);
    if (contentType) {
        *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
    }
    return body;
}

static UIWindowScene *LRVForegroundWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void LRVRestoreApplicationKeyWindow(UIWindow *overlayWindow) {
    UIWindowScene *scene = overlayWindow.windowScene ?: LRVForegroundWindowScene();
    for (UIWindow *window in scene.windows.reverseObjectEnumerator) {
        if (window != overlayWindow && !window.hidden && window.alpha > 0.0 &&
            window.windowLevel == UIWindowLevelNormal) {
            [window makeKeyWindow];
            return;
        }
    }
}

@implementation LRVVoiceViewController

- (UIButton *)controlButtonWithTitle:(NSString *)title color:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = color;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 28.0;
    button.exclusiveTouch = YES;
    [button addTarget:self
               action:@selector(controlTouchDown:)
     forControlEvents:UIControlEventTouchDown];
    [button addTarget:self
               action:@selector(controlTouchReleased:)
     forControlEvents:(UIControlEventTouchUpInside |
                       UIControlEventTouchUpOutside |
                       UIControlEventTouchCancel |
                       UIControlEventTouchDragExit)];
    return button;
}

- (void)controlTouchDown:(UIButton *)button {
    [UIView animateWithDuration:0.08
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        button.transform = CGAffineTransformMakeScale(0.94, 0.94);
        button.alpha = 0.82;
    } completion:nil];
}

- (void)controlTouchReleased:(UIButton *)button {
    [UIView animateWithDuration:0.12
                          delay:0.0
         usingSpringWithDamping:0.72
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        button.transform = CGAffineTransformIdentity;
        button.alpha = 1.0;
    } completion:nil];
}

- (void)startConnectingOrbAnimation {
    if ([self.orbView.layer animationForKey:@"lvb.connecting.pulse"]) {
        return;
    }
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @0.96;
    pulse.toValue = @1.045;
    pulse.duration = 0.72;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.orbView.layer addAnimation:pulse forKey:@"lvb.connecting.pulse"];
}

- (void)stopConnectingOrbAnimation {
    [self.orbView.layer removeAnimationForKey:@"lvb.connecting.pulse"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.035
                                                green:0.047
                                                 blue:0.043
                                                alpha:1.0];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.tag = 9001;
    titleLabel.text = @"ChatGPT Voice";
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:titleLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.text = @"Connecting…";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.statusLabel];

    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.detailLabel.text = @"Starting secure voice session";
    self.detailLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    self.detailLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    self.detailLabel.textAlignment = NSTextAlignmentCenter;
    self.detailLabel.numberOfLines = 3;
    [self.view addSubview:self.detailLabel];

    self.orbView = [[UIView alloc] initWithFrame:CGRectZero];
    self.orbView.backgroundColor = [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1.0];
    self.orbView.layer.shadowColor = [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1.0].CGColor;
    self.orbView.layer.shadowOpacity = 0.34;
    self.orbView.layer.shadowRadius = 28.0;
    self.orbView.layer.shadowOffset = CGSizeZero;
    [self.view addSubview:self.orbView];

    self.muteButton = [self controlButtonWithTitle:@"Mute"
                                             color:[UIColor colorWithWhite:0.20 alpha:1.0]];
    self.muteButton.enabled = NO;
    [self.muteButton addTarget:self action:@selector(mutePressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.muteButton];

    self.endButton = [self controlButtonWithTitle:@"End"
                                            color:[UIColor colorWithRed:0.82 green:0.20 blue:0.23 alpha:1.0]];
    [self.endButton addTarget:self action:@selector(endPressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.endButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);

    UILabel *titleLabel = [self.view viewWithTag:9001];
    titleLabel.frame = CGRectMake(24.0, safe.top + 22.0, width - 48.0, 32.0);

    CGFloat orbSize = MIN(174.0, width * 0.46);
    CGFloat orbY = MAX(safe.top + 105.0, CGRectGetMidY(bounds) - 175.0);
    self.orbView.frame = CGRectMake((width - orbSize) / 2.0, orbY, orbSize, orbSize);
    self.orbView.layer.cornerRadius = orbSize / 2.0;

    CGFloat statusY = CGRectGetMaxY(self.orbView.frame) + 28.0;
    self.statusLabel.frame = CGRectMake(24.0, statusY, width - 48.0, 38.0);
    self.detailLabel.frame = CGRectMake(36.0, statusY + 42.0, width - 72.0, 60.0);

    CGFloat buttonWidth = MIN(142.0, (width - 48.0) / 2.0 - 6.0);
    CGFloat buttonY = height - safe.bottom - 80.0;
    CGFloat gap = 12.0;
    CGFloat groupWidth = buttonWidth * 2.0 + gap;
    CGFloat groupX = (width - groupWidth) / 2.0;
    self.muteButton.frame = CGRectMake(groupX, buttonY, buttonWidth, 56.0);
    self.endButton.frame = CGRectMake(groupX + buttonWidth + gap, buttonY, buttonWidth, 56.0);
}

- (void)setVoiceStatus:(NSString *)status detail:(NSString *)detail {
    self.statusLabel.text = status;
    self.detailLabel.text = detail;
}

- (void)setConnected:(BOOL)connected {
    self.retryMode = NO;
    self.muteButton.enabled = connected;
    [self.muteButton setTitle:@"Mute" forState:UIControlStateNormal];
    self.muteButton.alpha = connected ? 1.0 : 0.55;
    self.orbView.backgroundColor = connected ?
        [UIColor colorWithRed:0.22 green:0.78 blue:0.62 alpha:1.0] :
        [UIColor colorWithRed:0.16 green:0.48 blue:0.40 alpha:1.0];
    if (connected) {
        [self stopConnectingOrbAnimation];
    } else {
        [self startConnectingOrbAnimation];
    }
}

- (void)setFailed:(BOOL)failed detail:(NSString *)detail {
    self.retryMode = failed;
    self.muteButton.enabled = YES;
    self.muteButton.alpha = 1.0;
    if (failed) {
        [self stopConnectingOrbAnimation];
        [self setVoiceStatus:@"Couldn’t connect" detail:detail];
        [self.muteButton setTitle:@"Retry" forState:UIControlStateNormal];
        self.orbView.backgroundColor = [UIColor colorWithRed:0.74 green:0.30 blue:0.32 alpha:1.0];
    }
}

- (void)mutePressed:(UIButton *)sender {
    (void)sender;
    LRVProvideTapFeedback();
    [self.session toggleMuteOrRetry];
}

- (void)endPressed:(UIButton *)sender {
    (void)sender;
    LRVProvideTapFeedback();
    [self.session endByUser];
}

@end

@implementation LVBRealtimeVoiceSession

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _transportQueue = dispatch_queue_create(
            "com.local.LegacyVoiceBridge.realtime-transport", attributes);
    }
    return self;
}

+ (instancetype)sharedSession {
    static LVBRealtimeVoiceSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        session = [[LVBRealtimeVoiceSession alloc] init];
    });
    return session;
}

- (void)prepareForLegacyStart {
    LRVRunOnMain(^{
        if (self.awaitingLegacyVoiceRequest ||
            self.state == LRVConnectionStateStarting ||
            self.state == LRVConnectionStateConnected ||
            (self.state == LRVConnectionStateFailed && self.overlayWindow)) {
            return;
        }

        self.awaitingLegacyVoiceRequest = YES;
        self.legacyVoicePresentationDismissed = NO;
        self.voiceButtonTappedAt = CACurrentMediaTime();
        self.preparationGeneration += 1;
        NSUInteger preparationGeneration = self.preparationGeneration;
        [self showOverlayAnimated:NO];
        LRVProvideTapFeedback();
        [self.overlayController setVoiceStatus:@"Connecting…"
                                        detail:@"Preparing secure voice session"];
        [self.overlayController setConnected:NO];
        LRVLog(@"legacy voice button captured; replacement cover shown before SwiftUI presentation");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.awaitingLegacyVoiceRequest ||
                preparationGeneration != self.preparationGeneration) {
                return;
            }
            self.awaitingLegacyVoiceRequest = NO;
            self.state = LRVConnectionStateFailed;
            self.legacyVoicePresentationDismissed = LVBDismissUnderlyingLegacyVoiceMode();
            self.overlayController.retryMode = NO;
            self.overlayController.muteButton.enabled = NO;
            self.overlayController.muteButton.alpha = 0.55;
            [self.overlayController.muteButton setTitle:@"Unavailable"
                                               forState:UIControlStateNormal];
            [self.overlayController setVoiceStatus:@"Couldn’t start"
                                            detail:@"The authenticated voice request did not arrive. Close and try again."];
            [self.overlayController stopConnectingOrbAnimation];
            LRVLog(@"legacy voice request preparation timed out dismissal=%@",
                   self.legacyVoicePresentationDismissed ? @"dispatched" : @"unavailable");
        });
    });
}

- (void)startWithRequest:(NSURLRequest *)request body:(NSDictionary<NSString *, id> *)body {
    CFTimeInterval requestTime = CACurrentMediaTime();
    NSString *incomingSessionID = LRVVoiceSessionIdentifier(body);
    LRVRunOnMain(^{
        BOOL preparedFromVoiceButton = self.awaitingLegacyVoiceRequest;
        if (self.state == LRVConnectionStateStarting ||
            self.state == LRVConnectionStateConnected) {
            LRVLog(@"start ignored because a native voice session is already active");
            return;
        }
        if (self.state == LRVConnectionStateFailed && self.overlayWindow) {
            LRVLog(@"automatic restart ignored after failure; waiting for manual Retry");
            return;
        }
        NSTimeInterval secondsSinceEnd = self.lastUserEndDate ?
            -self.lastUserEndDate.timeIntervalSinceNow : DBL_MAX;
        BOOL repeatsEndedSession = incomingSessionID.length > 0 &&
            [incomingSessionID isEqualToString:self.lastEndedVoiceSessionID];
        if ((repeatsEndedSession && secondsSinceEnd < 10.0) ||
            (incomingSessionID.length == 0 && secondsSinceEnd < 0.35)) {
            LRVLog(@"stale post-call start ignored same_session=%@ age_ms=%ld",
                   repeatsEndedSession ? @"yes" : @"unknown",
                   (long)llround(secondsSinceEnd * 1000.0));
            return;
        }

        self.awaitingLegacyVoiceRequest = NO;
        self.preparationGeneration += 1;
        self.sourceRequest = [request copy];
        self.sourceBody = [body copy] ?: @{};
        self.activeVoiceSessionID = incomingSessionID;
        self.startRequestedAt = requestTime;
        self.state = LRVConnectionStateStarting;
        self.generation += 1;
        [self showOverlayAnimated:!preparedFromVoiceButton];
        // Keep the covered SwiftUI presentation alive while its request
        // supplies the authenticated session context. Clearing it here races
        // the app's own start publication; the replacement End button writes
        // nil through the captured binding after the presentation settles.
        self.legacyVoicePresentationDismissed = NO;
        LRVLog(@"underlying legacy voice presentation retained behind opaque replacement until End");
        if (!preparedFromVoiceButton) {
            LRVProvideTapFeedback();
        }
        [self.overlayController setVoiceStatus:@"Connecting…"
                                        detail:@"Requesting microphone access"];
        [self.overlayController setConnected:NO];
        NSUInteger generation = self.generation;
        CFTimeInterval buttonTappedAt = self.voiceButtonTappedAt;
        dispatch_async(self.transportQueue, ^{
            long buttonToRequestMilliseconds = buttonTappedAt > 0.0 ?
                (long)llround((requestTime - buttonTappedAt) * 1000.0) : -1;
            LRVLog(@"native WebRTC session requested ui_ack_ms=%ld button_to_request_ms=%ld voice_present=%@ voice_mode_present=%@",
                   LRVElapsedMilliseconds(self.startRequestedAt),
                   buttonToRequestMilliseconds,
                   LRVSafeString(body[@"voice"]).length > 0 ? @"yes" : @"no",
                   LRVSafeString(body[@"voice_mode"]).length > 0 ? @"yes" : @"no");
        });
        [self requestMicrophoneAndBeginForGeneration:generation];
    });
}

- (void)showOverlayAnimated:(BOOL)animated {
    if (self.overlayWindow) {
        self.overlayWindow.hidden = NO;
        [self.overlayWindow makeKeyAndVisible];
        return;
    }
    UIWindowScene *scene = LRVForegroundWindowScene();
    if (!scene) {
        LRVLog(@"could not find a foreground UIWindowScene");
        return;
    }
    self.overlayController = [[LRVVoiceViewController alloc] init];
    self.overlayController.session = self;
    self.overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 2.0;
    // Keep the window itself opaque as well as its root view. That prevents a
    // transparent launch frame from exposing the legacy SwiftUI voice sheet.
    self.overlayWindow.backgroundColor = UIColor.blackColor;
    self.overlayWindow.rootViewController = self.overlayController;
    self.overlayController.view.alpha = animated ? 0.0 : 1.0;
    self.overlayController.view.transform = animated ?
        CGAffineTransformMakeScale(0.985, 0.985) : CGAffineTransformIdentity;
    self.overlayWindow.hidden = NO;
    [self.overlayWindow makeKeyAndVisible];
    if (!animated) {
        return;
    }
    [UIView animateWithDuration:0.16
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.overlayController.view.alpha = 1.0;
        self.overlayController.view.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)requestMicrophoneAndBeginForGeneration:(NSUInteger)generation {
    AVAuthorizationStatus permission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (permission == AVAuthorizationStatusDenied || permission == AVAuthorizationStatusRestricted) {
        [self failForGeneration:generation
                        reason:@"Microphone access is disabled for ChatGPT in Settings."
                           log:@"microphone permission denied or restricted"];
        return;
    }
    if (permission == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.generation || self.state == LRVConnectionStateEnded) {
                    return;
                }
                if (!granted) {
                    [self failForGeneration:generation
                                    reason:@"Microphone permission is required for voice."
                                       log:@"microphone permission request was declined"];
                    return;
                }
                [self beginPeerConnectionForGeneration:generation];
            });
        }];
        return;
    }
    [self beginPeerConnectionForGeneration:generation];
}

- (void)beginPeerConnectionForGeneration:(NSUInteger)generation {
    if (NSThread.isMainThread) {
        dispatch_async(self.transportQueue, ^{
            [self beginPeerConnectionForGeneration:generation];
        });
        return;
    }
    if (generation != self.generation || self.state != LRVConnectionStateStarting) {
        return;
    }

    [self configureAudioSession];

    Class factoryClass = NSClassFromString(@"LKRTCPeerConnectionFactory");
    Class configurationClass = NSClassFromString(@"LKRTCConfiguration");
    Class constraintsClass = NSClassFromString(@"LKRTCMediaConstraints");
    Class dataConfigurationClass = NSClassFromString(@"LKRTCDataChannelConfiguration");
    Class transceiverInitClass = NSClassFromString(@"LKRTCRtpTransceiverInit");
    Class sessionDescriptionClass = NSClassFromString(@"LKRTCSessionDescription");
    if (!factoryClass || !configurationClass || !constraintsClass ||
        !dataConfigurationClass || !transceiverInitClass || !sessionDescriptionClass) {
        [self failForGeneration:generation
                        reason:@"The bundled WebRTC engine could not be loaded."
                           log:@"required LiveKitWebRTC Objective-C classes were not found"];
        return;
    }

    self.factory = [[factoryClass alloc] init];
    LKRTCConfiguration *configuration = [[configurationClass alloc] init];
    // The current client uses Unified Plan and max-bundle. Explicitly setting
    // both avoids relying on defaults from the older WebRTC build.
    [configuration setSdpSemantics:1];
    [configuration setBundlePolicy:2];
    LKRTCMediaConstraints *peerConstraints =
        [[constraintsClass alloc] initWithMandatoryConstraints:@{
            @"bundlePolicy" : @"max-bundle",
            @"googCpuOveruseDetection" : @"false",
        } optionalConstraints:nil];
    self.peerConnection =
        [self.factory peerConnectionWithConfiguration:configuration
                                           constraints:peerConstraints
                                              delegate:self];
    if (!self.peerConnection) {
        [self failForGeneration:generation
                        reason:@"The WebRTC connection could not be created."
                           log:@"peerConnectionWithConfiguration returned nil"];
        return;
    }

    LKRTCMediaConstraints *audioConstraints =
        [[constraintsClass alloc] initWithMandatoryConstraints:nil
                                          optionalConstraints:@{
                                              @"googEchoCancellation" : @"true",
                                              @"googAutoGainControl" : @"true",
                                              @"googNoiseSuppression" : @"true",
                                          }];
    LKRTCAudioSource *audioSource = [self.factory audioSourceWithConstraints:audioConstraints];
    self.audioTrack = [self.factory audioTrackWithSource:audioSource trackId:@"lvb-audio-0"];
    [self.audioTrack setIsEnabled:YES];

    // VoiceRuntime's current Transceiver stack creates both m=audio and
    // m=video sections before its offer, with the same stream id, even when
    // the call starts audio-only. The consumer signaling validator expects
    // that offer shape.
    LKRTCRtpTransceiverInit *audioInit = [[transceiverInitClass alloc] init];
    [audioInit setDirection:0];
    [audioInit setStreamIds:@[@"stream"]];
    self.audioTransceiver = [self.peerConnection addTransceiverOfType:0 init:audioInit];
    if (!self.audioTransceiver) {
        [self failForGeneration:generation
                        reason:@"The microphone track could not be attached."
                           log:@"audio addTransceiverOfType returned nil"];
        return;
    }
    [self.audioTransceiver.sender setTrack:self.audioTrack];

    LKRTCRtpTransceiverInit *videoInit = [[transceiverInitClass alloc] init];
    [videoInit setDirection:0];
    [videoInit setStreamIds:@[@"stream"]];
    self.videoTransceiver = [self.peerConnection addTransceiverOfType:1 init:videoInit];
    if (!self.videoTransceiver) {
        [self failForGeneration:generation
                        reason:@"The compatible voice offer could not be prepared."
                           log:@"video addTransceiverOfType returned nil"];
        return;
    }

    LKRTCDataChannelConfiguration *dataConfiguration = [[dataConfigurationClass alloc] init];
    [dataConfiguration setIsOrdered:YES];
    // The consumer ChatGPT transport uses an in-band-free negotiated data
    // channel (stream id 0), unlike the public API example's "oai-events"
    // channel. Its empty label is intentional and matches the current app.
    [dataConfiguration setChannelId:0];
    [dataConfiguration setIsNegotiated:YES];
    self.dataChannel = [self.peerConnection dataChannelForLabel:@""
                                                  configuration:dataConfiguration];
    self.dataChannel.delegate = self;

    LRVRunOnMain(^{
        [self.overlayController setVoiceStatus:@"Connecting…"
                                        detail:@"Negotiating secure audio"];
    });
    LRVLog(@"WebRTC peer created; generating SDP offer startup_ms=%ld",
           LRVElapsedMilliseconds(self.startRequestedAt));

    LKRTCMediaConstraints *offerConstraints =
        [[constraintsClass alloc] initWithMandatoryConstraints:nil
                                          optionalConstraints:nil];
    __weak typeof(self) weakSelf = self;
    [self.peerConnection offerForConstraints:offerConstraints
                           completionHandler:^(LKRTCSessionDescription *offer, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.generation || self.state != LRVConnectionStateStarting) {
            return;
        }
        if (error || offer.sdp.length == 0) {
            [self failForGeneration:generation
                            reason:@"The device could not create a voice offer."
                               log:[NSString stringWithFormat:@"SDP offer failed domain=%@ code=%ld",
                                    error.domain ?: @"unknown", (long)error.code]];
            return;
        }
        NSString *opusPayloadType = nil;
        NSString *transformedSDP = LVBTransformRealtimeOfferSDP(offer.sdp,
                                                                &opusPayloadType);
        BOOL feedbackAdded = ![transformedSDP isEqualToString:offer.sdp];
        LRVLog(@"offer SDP transform opus_pt=%@ nack_added=%@",
               opusPayloadType ?: @"missing", feedbackAdded ? @"yes" : @"already-present-or-unavailable");
        LKRTCSessionDescription *transformedOffer =
            [[sessionDescriptionClass alloc] initWithType:0 sdp:transformedSDP];
        __weak typeof(self) innerWeakSelf = self;
        [self.peerConnection setLocalDescription:transformedOffer completionHandler:^(NSError *localError) {
            __strong typeof(innerWeakSelf) self = innerWeakSelf;
            if (!self || generation != self.generation || self.state != LRVConnectionStateStarting) {
                return;
            }
            if (localError) {
                [self failForGeneration:generation
                                reason:@"The device could not prepare secure audio."
                                   log:[NSString stringWithFormat:@"setLocalDescription failed domain=%@ code=%ld",
                                        localError.domain ?: @"unknown", (long)localError.code]];
                return;
            }
            NSString *sdp = self.peerConnection.localDescription.sdp ?: transformedSDP;
            [self queueOfferForSignaling:sdp generation:generation];
        }];
    }];
}

- (void)queueOfferForSignaling:(NSString *)offerSDP generation:(NSUInteger)generation {
    dispatch_async(self.transportQueue, ^{
        if (generation != self.generation || self.state != LRVConnectionStateStarting ||
            offerSDP.length == 0) {
            return;
        }
        self.pendingOfferSDP = offerSDP;
        self.pendingOfferGeneration = generation;
        self.signalingOfferStarted = NO;
        LRVRunOnMain(^{
            [self.overlayController setVoiceStatus:@"Connecting…"
                                            detail:@"Gathering secure network route"];
        });
        [self signalPendingOfferForGeneration:generation allowIncompleteICE:NO];

        // Most devices have multiple usable candidates well before ICE reports
        // its final state. Send once that useful route set is present instead
        // of always paying the old four-second fallback delay.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)),
                       self.transportQueue, ^{
            NSString *currentSDP = self.peerConnection.localDescription.sdp ?: self.pendingOfferSDP;
            if (generation == self.generation && self.state == LRVConnectionStateStarting &&
                !self.signalingOfferStarted && self.pendingOfferSDP.length > 0 &&
                LVBSDPCandidateCount(currentSDP) >= 2) {
                LRVLog(@"ICE fast path has multiple candidates; starting signaling");
                [self signalPendingOfferForGeneration:generation allowIncompleteICE:YES];
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       self.transportQueue, ^{
            if (generation == self.generation && self.state == LRVConnectionStateStarting &&
                !self.signalingOfferStarted && self.pendingOfferSDP.length > 0) {
                LRVLog(@"ICE gathering timeout; signaling the complete local description available so far");
                [self signalPendingOfferForGeneration:generation allowIncompleteICE:YES];
            }
        });
    });
}

- (void)signalPendingOfferForGeneration:(NSUInteger)generation
                     allowIncompleteICE:(BOOL)allowIncompleteICE {
    if (generation != self.generation || self.state != LRVConnectionStateStarting ||
        generation != self.pendingOfferGeneration || self.signalingOfferStarted ||
        self.pendingOfferSDP.length == 0) {
        return;
    }
    NSInteger gatheringState = self.peerConnection.iceGatheringState;
    if (!allowIncompleteICE && gatheringState != 2) {
        return;
    }
    NSString *offerSDP = self.peerConnection.localDescription.sdp ?: self.pendingOfferSDP;
    self.signalingOfferStarted = YES;
    self.pendingOfferSDP = nil;
    LRVLog(@"offer ready for signaling startup_ms=%ld ICE_complete=%@ candidates=%lu opus_nack=%@ media=%@ bundle_mids=%lu",
           LRVElapsedMilliseconds(self.startRequestedAt),
           gatheringState == 2 ? @"yes" : @"no",
           (unsigned long)LVBSDPCandidateCount(offerSDP),
           [offerSDP rangeOfString:@" nack" options:NSCaseInsensitiveSearch].location != NSNotFound ?
               @"yes" : @"no",
           LVBSDPMediaKindsSummary(offerSDP),
           (unsigned long)LVBSDPBundleMIDCount(offerSDP));
    [self signalOffer:offerSDP generation:generation];
}

- (void)configureAudioSession {
    NSError *audioError = nil;
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    BOOL categorySet = [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                                            mode:AVAudioSessionModeVoiceChat
                                         options:(AVAudioSessionCategoryOptionDefaultToSpeaker |
                                                  AVAudioSessionCategoryOptionAllowBluetoothHFP)
                                           error:&audioError];
    if (!categorySet) {
        LRVLog(@"audio category setup failed domain=%@ code=%ld",
               audioError.domain ?: @"unknown", (long)audioError.code);
    }
    audioError = nil;
    if (![audioSession setActive:YES error:&audioError]) {
        LRVLog(@"audio activation failed domain=%@ code=%ld",
               audioError.domain ?: @"unknown", (long)audioError.code);
    }
}

- (void)markTransportConnected {
    if (self.state == LRVConnectionStateEnded) {
        return;
    }
    BOOL firstConnection = self.state != LRVConnectionStateConnected;
    self.state = LRVConnectionStateConnected;
    NSUInteger generation = self.generation;
    LRVRunOnMain(^{
        [self.overlayController setConnected:YES];
        [self.overlayController setVoiceStatus:@"Listening" detail:@"Speak naturally"];
        if (firstConnection) {
            LRVLog(@"native realtime voice transport connected startup_ms=%ld",
                   LRVElapsedMilliseconds(self.startRequestedAt));
        }
    });
    dispatch_async(self.transportQueue, ^{
        if (generation == self.generation && self.state == LRVConnectionStateConnected) {
            [self configureAudioSession];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   self.transportQueue, ^{
        if (generation == self.generation && self.state == LRVConnectionStateConnected) {
            [self configureAudioSession];
        }
    });
}

- (NSArray<NSURL *> *)candidateURLs {
    NSURL *sourceURL = self.sourceRequest.URL;
    NSURLComponents *sourceComponents = sourceURL ?
        [NSURLComponents componentsWithURL:sourceURL resolvingAgainstBaseURL:NO] : nil;
    NSMutableArray<NSURL *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^appendURL)(NSURLComponents *, NSString *) = ^(NSURLComponents *base, NSString *path) {
        if (!base || path.length == 0) {
            return;
        }
        NSURLComponents *components = [base copy];
        components.path = path;
        components.query = nil;
        // The 2026 route builder stringifies the negotiated data-channel ID,
        // which its peer constructor fixes at 0. This is not a device UUID.
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"dcid" value:@"0"]];
        NSURL *url = components.URL;
        if (url.absoluteString.length > 0 && ![seen containsObject:url.absoluteString]) {
            [seen addObject:url.absoluteString];
            [results addObject:url];
        }
    };

    if (sourceComponents.host.length > 0) {
        NSString *path = sourceComponents.path ?: @"";
        NSRange voiceRange = [path rangeOfString:@"voice/get_token"
                                         options:NSCaseInsensitiveSearch | NSBackwardsSearch];
        NSString *prefix = voiceRange.location == NSNotFound ? @"/backend-api/" :
            [path substringToIndex:voiceRange.location];
        if (![prefix hasSuffix:@"/"]) {
            prefix = [prefix stringByAppendingString:@"/"];
        }
        appendURL(sourceComponents, [prefix stringByAppendingString:@"realtime/vp"]);
        appendURL(sourceComponents, [prefix stringByAppendingString:@"realtime/wm"]);
    }

    NSURLComponents *knownBase = [NSURLComponents componentsWithString:@"https://ios.chat.openai.com"];
    appendURL(knownBase, @"/realtime/vp");
    appendURL(knownBase, @"/realtime/wm");
    return results;
}

- (void)signalOffer:(NSString *)offerSDP generation:(NSUInteger)generation {
    // The current app sends the JSON-encoded GetTokenRequest as the `session`
    // multipart field. The intercepted legacy request is a compatible subset
    // and already contains the authenticated chatreq token, conversation
    // context, selected mode/model, and voice. Add the two modern non-optional
    // timezone fields when this older client did not supply them.
    NSMutableDictionary<NSString *, id> *sessionObject = [self.sourceBody mutableCopy];
    if (![sessionObject[@"timezone"] isKindOfClass:NSString.class]) {
        sessionObject[@"timezone"] = NSTimeZone.localTimeZone.name ?: @"UTC";
    }
    if (![sessionObject[@"timezone_offset_min"] isKindOfClass:NSNumber.class]) {
        NSInteger offsetMinutes = [NSTimeZone.localTimeZone secondsFromGMTForDate:NSDate.date] / 60;
        sessionObject[@"timezone_offset_min"] = @(offsetMinutes);
    }
    NSData *sessionData = [NSJSONSerialization dataWithJSONObject:sessionObject
                                                          options:0
                                                            error:nil];
    if (sessionData.length == 0) {
        [self failForGeneration:generation
                        reason:@"The voice request could not be encoded."
                           log:@"failed to encode realtime signaling payload"];
        return;
    }

    self.endpointCandidates = [self candidateURLs];
    self.endpointIndex = 0;
    if (self.endpointCandidates.count == 0) {
        [self failForGeneration:generation
                        reason:@"No ChatGPT voice endpoint was available."
                           log:@"no realtime signaling endpoint candidates"];
        return;
    }

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    configuration.URLCredentialStorage = NSURLCredentialStorage.sharedCredentialStorage;
    configuration.HTTPShouldSetCookies = YES;
    configuration.timeoutIntervalForRequest = 20.0;
    configuration.timeoutIntervalForResource = 30.0;
    self.signalingSession = [NSURLSession sessionWithConfiguration:configuration];
    [self postSessionData:sessionData
                 offerSDP:offerSDP
               generation:generation
                 endpoint:nil
          rawSDPTransport:NO];
}

- (void)postSessionData:(NSData *)sessionData
               offerSDP:(NSString *)offerSDP
             generation:(NSUInteger)generation
               endpoint:(NSURL *)retryEndpoint
        rawSDPTransport:(BOOL)rawSDPTransport {
    if (generation != self.generation || self.state != LRVConnectionStateStarting) {
        return;
    }
    if (!retryEndpoint && self.endpointIndex >= self.endpointCandidates.count) {
        [self failForGeneration:generation
                        reason:@"ChatGPT rejected every compatible voice endpoint. Tap Retry once; if it still fails, export LegacyVoiceBridge.log."
                           log:@"all realtime signaling endpoint candidates failed"];
        return;
    }

    NSURL *endpoint = retryEndpoint;
    if (!endpoint) {
        endpoint = self.endpointCandidates[self.endpointIndex++];
    }
    NSString *contentType = nil;
    NSData *payloadData = nil;
    NSString *transportName = nil;
    if (rawSDPTransport) {
        payloadData = [offerSDP dataUsingEncoding:NSUTF8StringEncoding];
        contentType = @"application/sdp";
        transportName = @"server-directed-sdp";
    } else {
        payloadData = LRVMultipartSignalingBody(offerSDP, sessionData, &contentType);
        transportName = @"new-client-multipart";
    }
    if (payloadData.length == 0 || contentType.length == 0) {
        [self failForGeneration:generation
                        reason:@"The voice request could not be encoded."
                           log:@"failed to encode realtime signaling body"];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    request.HTTPBody = payloadData;
    request.timeoutInterval = 20.0;
    for (NSString *header in self.sourceRequest.allHTTPHeaderFields) {
        NSString *lowercase = header.lowercaseString;
        if ([lowercase isEqualToString:@"content-length"] ||
            [lowercase isEqualToString:@"content-md5"] ||
            [lowercase isEqualToString:@"host"]) {
            continue;
        }
        [request setValue:self.sourceRequest.allHTTPHeaderFields[header]
       forHTTPHeaderField:header];
    }
    [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/sdp, text/plain, */*" forHTTPHeaderField:@"Accept"];

    LRVLog(@"signaling POST route=%@ startup_ms=%ld candidate=%lu transport=%@ dcid=0",
           endpoint.path ?: @"unknown",
           LRVElapsedMilliseconds(self.startRequestedAt),
           (unsigned long)self.endpointIndex,
           transportName);
    __weak typeof(self) weakSelf = self;
    self.signalingTask = [self.signalingSession dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data,
                                                                     NSURLResponse *response,
                                                                     NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.generation || self.state != LRVConnectionStateStarting) {
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ?
            (NSHTTPURLResponse *)response : nil;
        NSString *answerSDP = data.length > 0 ?
            [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        BOOL isSDP = [answerSDP hasPrefix:@"v=0"] ||
                     [answerSDP containsString:@"\r\nm=audio "] ||
                     [answerSDP containsString:@"\nm=audio "];
        LRVLog(@"signaling response route=%@ startup_ms=%ld status=%ld bytes=%lu sdp=%@ transport_domain=%@ transport_code=%ld",
               endpoint.path ?: @"unknown",
               LRVElapsedMilliseconds(self.startRequestedAt),
               (long)http.statusCode,
               (unsigned long)data.length,
               isSDP ? @"yes" : @"no",
               error.domain ?: @"none",
               (long)error.code);

        id errorObject = nil;
        if (error || http.statusCode < 200 || http.statusCode >= 300 || !isSDP) {
            if (data.length > 0 && data.length < (64 * 1024)) {
                errorObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([errorObject isKindOfClass:NSDictionary.class]) {
                    NSArray *keys = [[(NSDictionary *)errorObject allKeys]
                        sortedArrayUsingComparator:^NSComparisonResult(id first, id second) {
                            return [[first description] compare:[second description]];
                        }];
                    LRVLog(@"signaling non-SDP response JSON keys=%@ category=%@",
                           keys, LRVServerErrorCategory(errorObject));
                    LRVLog(@"signaling safe validation detail: %@",
                           LRVSafeServerDiagnostic(errorObject));
                }
            }
            if (!rawSDPTransport && LRVResponseRequestsRawSDP(errorObject)) {
                LRVLog(@"signaling endpoint explicitly requested application/sdp; retrying the same route with raw SDP");
                [self postSessionData:sessionData
                             offerSDP:offerSDP
                           generation:generation
                             endpoint:endpoint
                      rawSDPTransport:YES];
            } else {
                [self postSessionData:sessionData
                             offerSDP:offerSDP
                           generation:generation
                             endpoint:nil
                      rawSDPTransport:NO];
            }
            return;
        }

        // Google's WebRTC enum is Offer=0, PrAnswer=1, Answer=2, Rollback=3.
        Class sessionDescriptionClass = NSClassFromString(@"LKRTCSessionDescription");
        if (!sessionDescriptionClass) {
            [self failForGeneration:generation
                            reason:@"The bundled WebRTC engine could not be loaded."
                               log:@"LKRTCSessionDescription disappeared before applying the answer"];
            return;
        }
        LKRTCSessionDescription *answer = [[sessionDescriptionClass alloc] initWithType:2
                                                                                     sdp:answerSDP];
        __weak typeof(self) innerWeakSelf = self;
        [self.peerConnection setRemoteDescription:answer completionHandler:^(NSError *remoteError) {
            __strong typeof(innerWeakSelf) self = innerWeakSelf;
            if (!self || generation != self.generation || self.state != LRVConnectionStateStarting) {
                return;
            }
            if (remoteError) {
                [self failForGeneration:generation
                                reason:@"ChatGPT returned an incompatible audio answer."
                                   log:[NSString stringWithFormat:@"setRemoteDescription failed domain=%@ code=%ld",
                                        remoteError.domain ?: @"unknown", (long)remoteError.code]];
                return;
            }
            LRVLog(@"remote SDP accepted; waiting for WebRTC connection");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.overlayController setVoiceStatus:@"Connecting…"
                                                detail:@"Opening encrypted audio channel"];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation == self.generation && self.state == LRVConnectionStateStarting) {
                    [self failForGeneration:generation
                                    reason:@"The encrypted audio connection timed out. Tap Retry."
                                       log:@"WebRTC connection timed out after remote SDP was accepted"];
                }
            });
        }];
    }];
    [self.signalingTask resume];
}

- (void)toggleMuteOrRetry {
    LRVRunOnMain(^{
        if (self.state == LRVConnectionStateFailed || self.overlayController.retryMode) {
            self.state = LRVConnectionStateStarting;
            self.generation += 1;
            NSUInteger generation = self.generation;
            [self.overlayController setVoiceStatus:@"Connecting…" detail:@"Retrying secure voice session"];
            [self.overlayController setConnected:NO];
            dispatch_async(self.transportQueue, ^{
                LRVLog(@"manual native voice retry requested");
                [self teardownTransportDeactivateAudio:NO];
                LRVRunOnMain(^{
                    if (generation == self.generation &&
                        self.state == LRVConnectionStateStarting) {
                        [self requestMicrophoneAndBeginForGeneration:generation];
                    }
                });
            });
            return;
        }
        if (self.state != LRVConnectionStateConnected && self.state != LRVConnectionStateStarting) {
            return;
        }
        self.muted = !self.muted;
        [self.audioTrack setIsEnabled:!self.muted];
        [self.overlayController.muteButton setTitle:self.muted ? @"Unmute" : @"Mute"
                                            forState:UIControlStateNormal];
        [self.overlayController setVoiceStatus:self.muted ? @"Muted" : @"Listening"
                                        detail:self.muted ? @"Your microphone is off" : @"Speak naturally"];
        LRVLog(@"microphone %@", self.muted ? @"muted" : @"unmuted");
    });
}

- (void)endByUser {
    LRVRunOnMain(^{
        if ((self.state == LRVConnectionStateEnded || self.state == LRVConnectionStateIdle) &&
            !self.awaitingLegacyVoiceRequest) {
            return;
        }
        self.awaitingLegacyVoiceRequest = NO;
        self.preparationGeneration += 1;
        self.generation += 1;
        self.state = LRVConnectionStateEnded;
        self.lastUserEndDate = NSDate.date;
        self.lastEndedVoiceSessionID = self.activeVoiceSessionID;
        self.activeVoiceSessionID = nil;
        BOOL dispatchedNow = LVBDismissUnderlyingLegacyVoiceMode();
        self.legacyVoicePresentationDismissed =
            self.legacyVoicePresentationDismissed || dispatchedNow;
        UIWindow *overlayWindow = self.overlayWindow;
        NSUInteger endingGeneration = self.generation;
        NSUInteger endingPreparationGeneration = self.preparationGeneration;
        self.overlayController.view.userInteractionEnabled = NO;
        [self.overlayController setVoiceStatus:@"Ending…" detail:@""];
        self.voiceButtonTappedAt = 0.0;
        dispatch_async(self.transportQueue, ^{
            LRVLog(@"native voice session ended by user");
            [self teardownTransportDeactivateAudio:YES];
        });

        // endSession(.userRequest) publishes through SwiftUI asynchronously.
        // Keep our already-visible opaque cover for that short transition so
        // the removed legacy screen can never flash between windows.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.generation != endingGeneration ||
                self.preparationGeneration != endingPreparationGeneration ||
                self.state != LRVConnectionStateEnded ||
                self.overlayWindow != overlayWindow) {
                return;
            }
            LRVRestoreApplicationKeyWindow(overlayWindow);
            overlayWindow.hidden = YES;
            overlayWindow.rootViewController = nil;
            self.overlayWindow = nil;
            self.overlayController = nil;
            self.legacyVoicePresentationDismissed = NO;
        });
    });
}

- (void)teardownTransportDeactivateAudio:(BOOL)deactivateAudio {
    [self.signalingTask cancel];
    [self.signalingSession invalidateAndCancel];
    self.signalingTask = nil;
    self.signalingSession = nil;
    self.dataChannel.delegate = nil;
    self.serverDataChannel.delegate = nil;
    [self.dataChannel close];
    [self.serverDataChannel close];
    [self.peerConnection close];
    self.dataChannel = nil;
    self.serverDataChannel = nil;
    self.audioTrack = nil;
    self.audioTransceiver = nil;
    self.videoTransceiver = nil;
    self.peerConnection = nil;
    self.factory = nil;
    self.endpointCandidates = nil;
    self.endpointIndex = 0;
    self.pendingOfferSDP = nil;
    self.pendingOfferGeneration = 0;
    self.signalingOfferStarted = NO;
    self.muted = NO;
    if (deactivateAudio) {
        NSError *error = nil;
        [AVAudioSession.sharedInstance setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:&error];
        if (error) {
            LRVLog(@"audio deactivation failed domain=%@ code=%ld",
                   error.domain ?: @"unknown", (long)error.code);
        }
    }
}

- (void)failForGeneration:(NSUInteger)generation
                    reason:(NSString *)reason
                       log:(NSString *)logMessage {
    if (generation != self.generation || self.state == LRVConnectionStateEnded) {
        return;
    }
    self.state = LRVConnectionStateFailed;
    LRVLog(@"native voice failed: %@", logMessage);
    LRVRunOnMain(^{
        [self.overlayController setFailed:YES detail:reason];
    });
}

#pragma mark - Peer connection delegate

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeConnectionState:(NSInteger)state {
    (void)peerConnection;
    LRVLog(@"WebRTC connection state=%ld", (long)state);
    if (state == 2) {
        [self markTransportConnected];
    } else if (state == 4 && self.state != LRVConnectionStateEnded) {
        [self failForGeneration:self.generation
                        reason:@"The encrypted audio connection failed. Tap Retry."
                           log:@"WebRTC peer connection entered failed state"];
    }
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeIceConnectionState:(NSInteger)state {
    (void)peerConnection;
    LRVLog(@"WebRTC ICE state=%ld", (long)state);
    if ((state == 2 || state == 3) && self.state == LRVConnectionStateStarting) {
        [self markTransportConnected];
    } else if (state == 4 && self.state != LRVConnectionStateEnded) {
        [self failForGeneration:self.generation
                        reason:@"ChatGPT could not establish an audio route. Tap Retry."
                           log:@"WebRTC ICE entered failed state"];
    }
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeIceGatheringState:(NSInteger)state {
    (void)peerConnection;
    LRVLog(@"WebRTC ICE gathering state=%ld", (long)state);
    if (state == 2) {
        dispatch_async(self.transportQueue, ^{
            [self signalPendingOfferForGeneration:self.generation allowIncompleteICE:NO];
        });
    }
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didOpenDataChannel:(LKRTCDataChannel *)dataChannel {
    (void)peerConnection;
    self.serverDataChannel = dataChannel;
    self.serverDataChannel.delegate = self;
    LRVLog(@"server opened realtime data channel");
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didChangeSignalingState:(NSInteger)state {
    (void)peerConnection;
    LRVLog(@"WebRTC signaling state=%ld", (long)state);
}

- (void)peerConnectionShouldNegotiate:(LKRTCPeerConnection *)peerConnection {
    (void)peerConnection;
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didAddStream:(LKRTCMediaStream *)stream {
    (void)peerConnection;
    (void)stream;
    LRVLog(@"remote media stream added");
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didRemoveStream:(LKRTCMediaStream *)stream {
    (void)peerConnection;
    (void)stream;
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didGenerateIceCandidate:(LKRTCIceCandidate *)candidate {
    (void)peerConnection;
    (void)candidate;
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didRemoveIceCandidates:(NSArray<LKRTCIceCandidate *> *)candidates {
    (void)peerConnection;
    (void)candidates;
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didAddReceiver:(LKRTCRtpReceiver *)receiver
    streams:(NSArray<LKRTCMediaStream *> *)streams {
    (void)peerConnection;
    (void)receiver;
    (void)streams;
    LRVLog(@"remote audio receiver added");
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didRemoveReceiver:(LKRTCRtpReceiver *)receiver {
    (void)peerConnection;
    (void)receiver;
}

- (void)peerConnection:(LKRTCPeerConnection *)peerConnection
    didStartReceivingOnTransceiver:(LKRTCRtpTransceiver *)transceiver {
    (void)peerConnection;
    (void)transceiver;
    LRVLog(@"remote transceiver started receiving");
}

#pragma mark - Data channel delegate

- (void)dataChannelDidChangeState:(LKRTCDataChannel *)dataChannel {
    LRVLog(@"realtime data channel state=%ld", (long)dataChannel.readyState);
}

- (void)dataChannel:(LKRTCDataChannel *)dataChannel
    didReceiveMessageWithBuffer:(LKRTCDataBuffer *)buffer {
    (void)dataChannel;
    NSString *eventType = buffer.isBinary ? nil : LRVEventTypeFromData(buffer.data);
    LRVLog(@"realtime event received type=%@ bytes=%lu binary=%@",
           eventType ?: @"unknown",
           (unsigned long)buffer.data.length,
           buffer.isBinary ? @"yes" : @"no");
    if ([eventType containsString:@"speech_started"] ||
        [eventType containsString:@"input_audio_buffer.speech_started"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.overlayController setVoiceStatus:@"Listening" detail:@"I hear you"];
        });
    } else if ([eventType containsString:@"audio.delta"] ||
               [eventType containsString:@"response.audio"] ||
               [eventType containsString:@"output_audio"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.overlayController setVoiceStatus:@"Speaking" detail:@"ChatGPT is responding"];
        });
    } else if ([eventType containsString:@"response.done"] ||
               [eventType containsString:@"speech_stopped"] ||
               [eventType containsString:@"input_audio_buffer.speech_stopped"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.overlayController setVoiceStatus:@"Listening" detail:@"Speak naturally"];
        });
    }
}

@end

void LVBRealtimeVoiceStart(NSURLRequest *request,
                           NSDictionary<NSString *, id> *requestBody) {
    if (!request) {
        return;
    }
    [[LVBRealtimeVoiceSession sharedSession] startWithRequest:request
                                                        body:requestBody ?: @{}];
}

void LVBRealtimeVoicePrepareForLegacyStart(void) {
    [[LVBRealtimeVoiceSession sharedSession] prepareForLegacyStart];
}
