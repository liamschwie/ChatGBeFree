#import <Foundation/Foundation.h>

#import "../ModelSwitcher/LegacyModelSwitcher.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSDictionary *Model(NSString *slug,
                           NSString *title,
                           NSString *defaultEffort,
                           NSArray<NSString *> *efforts,
                           NSArray<NSString *> *tags) {
    NSMutableArray *thinkingEfforts = [NSMutableArray array];
    for (NSString *effort in efforts) {
        NSString *label = [effort stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                            withString:[[effort substringToIndex:1] uppercaseString]];
        [thinkingEfforts addObject:@{
            @"thinking_effort": effort,
            @"short_label": label,
        }];
    }
    return @{
        @"slug": slug,
        @"title": title,
        @"description": [NSString stringWithFormat:@"%@ description", title],
        @"tags": tags,
        @"configurable_thinking_effort": @(efforts.count > 0),
        @"thinking_efforts": thinkingEfforts,
        @"default_thinking_effort": defaultEffort ?: NSNull.null,
    };
}

static NSDictionary *Category(NSString *name, NSString *model) {
    return @{
        @"human_category_name": name,
        @"human_category_short_name": name,
        @"short_explainer": @"Server category",
        @"icon": @"star",
        @"subscription_level": @"plus",
        @"default_model": model,
    };
}

int main(void) {
    @autoreleasepool {
        CGBTestingClearPersistedModelSelection();
        NSDictionary *catalog = @{
            @"default_model_slug": @"gpt-5.6-sol",
            @"models": @[
                Model(@"gpt-5.6-sol", @"GPT-5.6 Sol", @"medium",
                      @[@"instant", @"medium", @"high"], @[]),
                Model(@"gpt-5.6-terra", @"Instant", @"medium",
                      @[@"instant", @"medium"], @[]),
                Model(@"gpt-5.6-luna", @"GPT-5.6 Luna", nil, @[], @[]),
                Model(@"gpt-5.5-thinking", @"GPT-5.5 Thinking", @"standard",
                      @[@"standard", @"extended"], @[]),
                Model(@"o3", @"o3", nil, @[], @[]),
                Model(@"secret-model", @"Secret", nil, @[], @[@"hidden"]),
            ],
            @"categories": @[
                Category(@"Instant", @"gpt-5.6-sol"),
                Category(@"Instant", @"gpt-5.6-terra"),
                Category(@"Instant", @"gpt-5.6-luna"),
                Category(@"Thinking", @"gpt-5.5-thinking"),
                Category(@"Thinking", @"o3"),
                Category(@"Internal", @"secret-model"),
            ],
            @"versions": @[
                @{
                    @"id": @"5.6",
                    @"display_text": @"5.6",
                    @"display_text_for_intelligence": @"GPT-5.6 Sol",
                    @"slugs": @[@"gpt-5.6-sol", @"gpt-5.6-terra", @"gpt-5.6-luna"],
                    @"intelligence_presets": @[
                        @{
                            @"selected_display_title": @"GPT-5.6 Sol",
                            @"model_slug": @"gpt-5.6-sol",
                        },
                        @{
                            @"title": @"Instant",
                            @"model_slug": @"gpt-5.6-sol",
                            @"thinking_effort": @"instant",
                        },
                        @{
                            @"title": @"Medium",
                            @"model_slug": @"gpt-5.6-sol",
                            @"thinking_effort": @"medium",
                        },
                        @{
                            @"title": @"High",
                            @"model_slug": @"gpt-5.6-sol",
                            @"thinking_effort": @"high",
                            @"default_service_tier": @"priority",
                        },
                        @{
                            @"title": @"Instant",
                            @"model_slug": @"gpt-5.6-terra",
                            @"thinking_effort": @"instant",
                        },
                        @{
                            @"title": @"GPT-5.6 Sol",
                            @"selected_display_title": @"GPT-5.6 Sol",
                            @"model_slug": @"gpt-5.6-luna",
                        },
                    ],
                },
            ],
        };

        NSArray<NSDictionary *> *summary = nil;
        NSDictionary *legacy = CGBLegacyModelCatalog(catalog, &summary);
        Require(legacy != nil, @"translates a modern catalog");
        Require([legacy[@"models"] count] == 9, @"publishes each supported model/effort once");
        Require([legacy[@"categories"] count] == 9, @"creates one legacy category per choice");
        Require(summary.count == 9, @"returns a safe row summary");

        NSMutableSet<NSString *> *titles = [NSMutableSet set];
        for (NSDictionary *category in legacy[@"categories"]) {
            NSString *title = category[@"human_category_name"];
            Require(title.length > 0, @"every row has a title");
            Require(![titles containsObject:title], @"dropdown titles are unique");
            Require(![title isEqualToString:@"Instant"] && ![title isEqualToString:@"Thinking"],
                    @"generic duplicate server labels are replaced");
            [titles addObject:title];
        }
        Require([titles containsObject:@"GPT-5.6 Sol (Instant)"], @"labels Sol instant explicitly");
        Require([titles containsObject:@"GPT-5.6 Sol (Medium)"], @"labels Sol medium explicitly");
        Require([titles containsObject:@"GPT-5.6 Sol (High)"], @"labels Sol high explicitly");
        Require([titles containsObject:@"GPT-5.6 Terra (Instant)"], @"labels Terra explicitly");
        Require([titles containsObject:@"GPT-5.6 Terra (Medium)"], @"adds advertised Terra effort");
        Require([titles containsObject:@"GPT-5.6 Luna"],
                @"uses the actual Luna model despite a conflicting Sol display field");
        Require([titles containsObject:@"GPT-5.5 (Medium)"],
                @"shortens Thinking Standard to Medium");
        Require([titles containsObject:@"GPT-5.5 (High)"],
                @"shortens Thinking Extended to High");
        Require(![titles containsObject:@"GPT-5.5 Thinking (Standard)"] &&
                ![titles containsObject:@"GPT-5.5 Thinking (Extended)"] &&
                ![titles containsObject:@"GPT-5.6 Sol"],
                @"does not leak outdated effort terminology");
        for (NSString *title in titles) {
            Require(!([title containsString:@"Luna"] && [title containsString:@"Sol"]),
                    @"never combines two competing model names in one row");
        }
        Require([titles containsObject:@"o3"], @"keeps an advertised legacy model");
        Require(![titles containsObject:@"Secret"], @"does not expose hidden models");
        Require([legacy[@"default_model_slug"] isEqualToString:@"gpt-5.6-sol"],
                @"uses the real slug for the server-default effort");

        NSArray<NSString *> *orderedTitles = [legacy[@"categories"]
            valueForKey:@"human_category_name"];
        Require([orderedTitles isEqualToArray:@[
            @"GPT-5.6 Sol (Instant)",
            @"GPT-5.6 Sol (Medium)",
            @"GPT-5.6 Sol (High)",
            @"GPT-5.6 Terra (Instant)",
            @"GPT-5.6 Terra (Medium)",
            @"GPT-5.6 Luna",
            @"GPT-5.5 (Medium)",
            @"GPT-5.5 (High)",
            @"o3",
        ]], @"orders current models and effort choices predictably");

        NSUInteger highIndex = NSNotFound;
        for (NSUInteger index = 0; index < summary.count; index++) {
            NSDictionary *row = summary[index];
            if ([row[@"model"] isEqualToString:@"gpt-5.6-sol"] &&
                [row[@"thinking_effort"] isEqualToString:@"high"]) {
                highIndex = index;
                break;
            }
        }
        Require(highIndex != NSNotFound, @"finds the high-effort choice");
        NSString *syntheticSlug = legacy[@"models"][highIndex][@"slug"];
        Require([syntheticSlug hasPrefix:@"cgbf.v1."], @"non-default choices use reversible slugs");

        // The runtime bridge reads the updated navigation title immediately
        // after ModelContext.select(...) so tapping a row is durable even if
        // no message is sent before the app is killed.
        CGBTestingClearPersistedModelSelection();
        NSString *matchedDisplay = nil;
        Require(CGBPersistPublishedModelSelectionMatchingVisibleText(
                    @"ChatGPT  GPT-5.6 Sol (High)", &matchedDisplay),
                @"matches the selected model in the legacy navigation title");
        Require([matchedDisplay isEqualToString:@"GPT-5.6 Sol (High)"],
                @"reports the exact advertised picker row that matched");
        Require([CGBTestingPersistedModelSelection() isEqualToDictionary:@{
            @"model": @"gpt-5.6-sol",
            @"thinking_effort": @"high",
            @"service_tier": @"priority",
        }], @"persists a picker tap before any conversation request");
        Require(!CGBPersistPublishedModelSelectionMatchingVisibleText(
                    @"ChatGPT Model", nil),
                @"does not infer a selection from unrelated navigation text");
        CGBTestingClearPersistedModelSelection();

        NSDictionary *selection = nil;
        NSDictionary *resolved = CGBConversationBodyByResolvingModelSelection(@{
            @"model": syntheticSlug,
            @"action": @"next",
            @"messages": @[],
        }, &selection);
        Require([resolved[@"model"] isEqualToString:@"gpt-5.6-sol"],
                @"restores the real model in conversation requests");
        Require([resolved[@"thinking_effort"] isEqualToString:@"high"],
                @"injects the selected thinking effort");
        Require([resolved[@"service_tier"] isEqualToString:@"priority"],
                @"preserves the preset's service tier");
        Require([selection isEqualToDictionary:@{
            @"model": @"gpt-5.6-sol",
            @"thinking_effort": @"high",
            @"service_tier": @"priority",
        }], @"reports only non-sensitive selection diagnostics");
        Require([CGBTestingPersistedModelSelection() isEqualToDictionary:selection],
                @"durably remembers the advertised model, effort, and tier actually used");

        selection = nil;
        NSDictionary *voiceResolved = CGBVoiceBodyByResolvingModelSelection(@{
            @"voice_session_id": @"test-session",
            @"voice_mode": @"advanced",
            @"model_slug": syntheticSlug,
        }, &selection);
        Require([voiceResolved[@"model_slug"] isEqualToString:@"gpt-5.6-sol"],
                @"restores the real model in voice token requests");
        Require([voiceResolved[@"thinking_effort"] isEqualToString:@"high"],
                @"passes the dropdown effort through voice's supported field");
        Require(voiceResolved[@"service_tier"] == nil,
                @"does not invent a service-tier field unsupported by voice");
        Require([selection isEqualToDictionary:@{
            @"model": @"gpt-5.6-sol",
            @"thinking_effort": @"high",
            @"service_tier_ignored": @"priority",
        }], @"reports when a chat-only service tier is omitted for voice");

        NSArray<NSDictionary *> *restoredSummary = nil;
        NSDictionary *restoredCatalog = CGBLegacyModelCatalog(catalog, &restoredSummary);
        Require([restoredCatalog[@"default_model_slug"] isEqualToString:syntheticSlug],
                @"restores the last used deep choice as the legacy app default after relaunch");
        Require([restoredSummary[highIndex][@"restored_default"] boolValue],
                @"marks the restored row for safe diagnostics");

        // A hand-crafted synthetic slug may still be forwarded to the server,
        // which remains authoritative, but it must never become a persisted
        // default unless the current account's catalog advertised it.
        NSDictionary *unadvertised = CGBConversationBodyByResolvingModelSelection(@{
            @"model": @"cgbf.v1.Z3B0LTk5.aGlnaA.0",
            @"messages": @[],
        }, nil);
        Require([unadvertised[@"model"] isEqualToString:@"gpt-99"],
                @"keeps synthetic-slug request translation backwards compatible");
        Require([CGBTestingPersistedModelSelection()[@"model"] isEqualToString:@"gpt-5.6-sol"],
                @"does not persist an unadvertised model or bypass the live catalog");

        Require(CGBConversationBodyByResolvingModelSelection(@{
            @"model": @"gpt-5.6-sol",
            @"messages": @[],
        }, nil) == nil, @"ordinary default selections still require no body rewrite");
        Require([CGBTestingPersistedModelSelection() isEqualToDictionary:@{
            @"model": @"gpt-5.6-sol",
            @"thinking_effort": @"medium",
        }], @"choosing a real/default slug replaces an older deep preference");
        NSDictionary *resetCatalog = CGBLegacyModelCatalog(catalog, nil);
        Require([resetCatalog[@"default_model_slug"] isEqualToString:@"gpt-5.6-sol"],
                @"restores a subsequently selected default-effort row too");

        Require(CGBConversationBodyByResolvingModelSelection(@{ @"model": @"gpt-5.6-sol" }, nil) == nil,
                @"leaves ordinary server model slugs untouched");
        Require(CGBVoiceBodyByResolvingModelSelection(@{ @"model_slug": @"gpt-5.6-sol" }, nil) == nil,
                @"leaves ordinary voice model slugs untouched");
        Require(!CGBTestingDecodeLegacyModelSlug(@"cgbf.v1.invalid", nil, nil, nil),
                @"rejects malformed synthetic slugs");
        Require(CGBLegacyModelCatalog(@{ @"models": @[] }, nil) == nil,
                @"leaves malformed or empty catalogs untouched");

        CGBTestingClearPersistedModelSelection();
        Require(CGBTestingPersistedModelSelection() == nil,
                @"can clear only ChatGBeFree's local model preference");

        NSLog(@"PASS: ChatGBeFree model switcher tests");
    }
    return 0;
}
