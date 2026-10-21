#import <Foundation/Foundation.h>

#import "../ImageBridge/LegacyImageBridge.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSURL *sediment = [NSURL URLWithString:
            @"sediment://file_private123/preview?token=signed-secret&size=medium#page"];
        Require(CGBIsSedimentAssetURL(sediment), @"recognizes sediment assets");

        NSURL *legacy = CGBLegacyFileServiceURLForSedimentURL(sediment);
        Require([legacy.absoluteString isEqualToString:
            @"file-service://file_private123/preview?token=signed-secret&size=medium#page"],
            @"changes only the scheme and preserves the opaque asset locator");
        Require(CGBLegacyFileServiceURLForSedimentURL(
            [NSURL URLWithString:@"https://example.com/image.png"]) == nil,
            @"does not rewrite ordinary URLs");

        NSDictionary *URLSummary = CGBSafeAssetURLSummary(sediment);
        NSData *URLSummaryData = [NSJSONSerialization dataWithJSONObject:URLSummary
                                                                 options:0
                                                                   error:nil];
        NSString *URLSummaryJSON = [[NSString alloc] initWithData:URLSummaryData
                                                         encoding:NSUTF8StringEncoding];
        Require([URLSummary[@"scheme"] isEqualToString:@"sediment"],
                @"reports the asset scheme");
        Require([URLSummary[@"host_looks_like_file_id"] boolValue],
                @"reports the host shape without its value");
        Require([URLSummary[@"query_names"] isEqualToArray:@[@"size", @"token"]],
                @"reports query names without signed values");
        Require(![URLSummaryJSON containsString:@"private123"] &&
                ![URLSummaryJSON containsString:@"signed-secret"],
                @"redacted URL diagnostics do not leak IDs or signatures");

        NSDictionary *event = @{
            @"type": @"conversation.message.delta",
            @"message": @{
                @"content": @{
                    @"content_type": @"multimodal_text",
                    @"parts": @[
                        @"do not log this private prompt",
                        @{
                            @"content_type": @"image_asset_pointer",
                            @"asset_pointer":
                                @"sediment://file_private123?token=signed-secret",
                            @"metadata": @{
                                @"generation": @{ @"gen_id": @"generation-secret" },
                            },
                        },
                    ],
                },
            },
        };
        NSDictionary *eventSummary = CGBSafeImageEventSummary(event);
        Require(eventSummary != nil, @"recognizes an image event");
        Require([eventSummary[@"asset_schemes"] containsObject:@"sediment"],
                @"reports the modern asset scheme");
        Require([eventSummary[@"types"] containsObject:@"image_asset_pointer"],
                @"reports image content types");
        NSData *summaryData = [NSJSONSerialization dataWithJSONObject:eventSummary
                                                               options:0
                                                                 error:nil];
        NSString *summaryJSON = [[NSString alloc] initWithData:summaryData
                                                      encoding:NSUTF8StringEncoding];
        Require(![summaryJSON containsString:@"private prompt"] &&
                ![summaryJSON containsString:@"private123"] &&
                ![summaryJSON containsString:@"signed-secret"] &&
                ![summaryJSON containsString:@"generation-secret"],
                @"event diagnostics contain structure only");

        Require(CGBSafeImageEventSummary(@{
            @"type": @"conversation.message.delta",
            @"content": @"ordinary private chat text",
        }) == nil, @"ignores non-image conversation events");

        NSDictionary *asyncEvent = @{
            @"message": @{
                @"id": @"placeholder-message",
                @"author": @{ @"role": @"assistant" },
                @"recipient": @"t2uay3k.sj1i4kz",
                @"metadata": @{
                    @"image_gen_task_id": @"safe-task-token",
                    @"turn_exchange_id": @"turn-safe-123",
                },
            },
            @"conversation_id": @"conversation-safe-123",
        };
        Require(CGBImageEventIndicatesAsyncGeneration(asyncEvent),
                @"recognizes a modern asynchronous image turn");
        Require([CGBConversationIdentifierFromImageEvent(asyncEvent)
                    isEqualToString:@"conversation-safe-123"],
                @"extracts the conversation identifier for polling");
        Require([CGBImageTurnExchangeIdentifierFromEvent(asyncEvent)
                    isEqualToString:@"turn-safe-123"],
                @"extracts the current turn identifier for result filtering");
        Require(!CGBImageEventIndicatesAsyncGeneration(@{
            @"conversation_async_status": @3,
            @"message": @{ @"content": @{ @"parts": @[@"ordinary text"] } },
        }), @"does not mistake generic asynchronous thinking for image generation");

        NSDictionary *generatedToolMessage = @{
            @"id": @"generated-image-message",
            @"author": @{
                @"role": @"tool",
                @"name": @"t2uay3k.sj1i4kz",
            },
            @"create_time": @200.0,
            @"content": @{
                @"content_type": @"multimodal_text",
                @"parts": @[
                    @{
                        @"content_type": @"image_asset_pointer",
                        @"asset_pointer":
                            @"sediment://file_private123?token=signed-secret",
                        @"width": @1024,
                        @"height": @1024,
                    },
                ],
            },
            @"metadata": @{
                @"async_task_type": @"image_gen",
                @"turn_exchange_id": @"turn-safe-123",
            },
            @"recipient": @"all",
        };
        NSDictionary *conversation = @{
            @"conversation_id": @"conversation-safe-123",
            @"mapping": @{
                @"old": @{
                    @"message": @{
                        @"id": @"old-generated-image",
                        @"author": @{ @"role": @"tool" },
                        @"create_time": @10.0,
                        @"content": generatedToolMessage[@"content"],
                        @"metadata": @{
                            @"async_task_type": @"image_gen",
                            @"turn_exchange_id": @"different-turn",
                        },
                    },
                },
                @"current": @{ @"message": generatedToolMessage },
            },
        };
        NSArray<NSDictionary *> *legacyMessages = CGBLegacyGeneratedImageMessages(
            conversation, @"turn-safe-123", 100.0);
        Require(legacyMessages.count == 1,
                @"returns only generated images belonging to the current turn");
        NSDictionary *legacyMessage = legacyMessages.firstObject;
        Require([legacyMessage[@"author"][@"role"] isEqualToString:@"assistant"],
                @"converts the modern tool result into a legacy assistant message");
        Require(legacyMessage[@"author"][@"name"] == nil,
                @"removes the modern private image-tool name");
        NSString *legacyPointer = legacyMessage[@"content"][@"parts"][0][@"asset_pointer"];
        Require([legacyPointer isEqualToString:
                    @"file-service://file_private123?token=signed-secret"],
                @"rewrites the asset before the legacy markdown renderer sees it");

        NSUInteger rewrittenURLs = 0;
        NSUInteger rewrittenMessages = 0;
        NSDictionary *ordinaryTool = @{
            @"author": @{ @"role": @"tool", @"name": @"browser" },
            @"content": @{
                @"content_type": @"multimodal_text",
                @"parts": @[@{
                    @"content_type": @"image_asset_pointer",
                    @"asset_pointer": @"sediment://file_input",
                }],
            },
        };
        NSDictionary *rewrittenOrdinary = CGBLegacyImageCompatibleObject(
            ordinaryTool, &rewrittenURLs, &rewrittenMessages);
        Require(rewrittenMessages == 0 &&
                [rewrittenOrdinary[@"author"][@"role"] isEqualToString:@"tool"],
                @"does not relabel unrelated tool messages");
        Require(rewrittenURLs == 1,
                @"still makes a directly rendered sediment asset loadable");

        NSDictionary *historicalDalleMessage = @{
            @"id": @"historical-dalle-image",
            @"author": @{ @"role": @"tool", @"name": @"dalle.text2im" },
            @"content": @{
                @"content_type": @"multimodal_text",
                @"parts": @[
                    @{
                        @"content_type": @"image_asset_pointer",
                        @"asset_pointer": @"file-service://file_historical_rover",
                    },
                    @"Model caption: private internal model description",
                ],
            },
            @"metadata": @{
                @"dalle": @{ @"generation_id": @"generation-historical" },
                @"is_visually_hidden_from_conversation": @YES,
            },
        };
        rewrittenURLs = 0;
        rewrittenMessages = 0;
        NSDictionary *rewrittenHistorical = CGBLegacyImageCompatibleObject(
            historicalDalleMessage, &rewrittenURLs, &rewrittenMessages);
        Require(rewrittenMessages == 1,
                @"recognizes historical dalle.text2im tool messages");
        Require([rewrittenHistorical[@"author"][@"role"] isEqualToString:@"assistant"],
                @"publishes a historical DALL-E result through the legacy assistant renderer");
        Require(![rewrittenHistorical[@"metadata"]
                    [@"is_visually_hidden_from_conversation"] boolValue],
                @"unhides the result when the legacy client has no separate image card");
        Require([rewrittenHistorical[@"content"][@"parts"] count] == 1,
                @"removes the internal model caption from the visible image message");

        NSLog(@"PASS: ChatGBeFree image bridge tests");
    }
    return 0;
}
