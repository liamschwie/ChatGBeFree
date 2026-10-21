#import "LegacyModelSwitcher.h"

static NSString *const CGBSlugPrefix = @"cgbf.v1.";
static NSString *const CGBSelectionDefaultsKey =
    @"com.liam.chatgbefree.preferred-model-selection.v1";

// The legacy picker only gives the app one opaque slug. Keep the exact mapping
// generated from the latest server catalog so persistence can never turn an
// invented slug into an advertised/default choice. The API server remains the
// authority for model availability and account entitlements.
static NSMutableDictionary<NSString *, NSDictionary *> *CGBPublishedSelections;
static NSMutableDictionary<NSString *, NSDictionary *> *CGBPublishedDisplaySelections;

static NSObject *CGBSelectionLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
        CGBPublishedSelections = [NSMutableDictionary dictionary];
        CGBPublishedDisplaySelections = [NSMutableDictionary dictionary];
    });
    return lock;
}

static NSString *CGBNormalizedKey(NSString *key) {
    return [[key.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@""]
            stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

static id CGBValue(NSDictionary *dictionary, NSString *normalizedKey) {
    if (![dictionary isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    for (id rawKey in dictionary) {
        if ([rawKey isKindOfClass:NSString.class] &&
            [CGBNormalizedKey(rawKey) isEqualToString:normalizedKey]) {
            return dictionary[rawKey];
        }
    }
    return nil;
}

static NSString *CGBString(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *string = [value stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return string.length > 0 ? string : nil;
}

static NSArray *CGBArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *CGBExistingKey(NSDictionary *dictionary, NSString *normalizedKey) {
    for (id rawKey in dictionary) {
        if ([rawKey isKindOfClass:NSString.class] &&
            [CGBNormalizedKey(rawKey) isEqualToString:normalizedKey]) {
            return rawKey;
        }
    }
    return nil;
}

static void CGBSetValue(NSMutableDictionary *dictionary,
                        NSString *normalizedKey,
                        NSString *canonicalKey,
                        id _Nullable value) {
    NSString *key = CGBExistingKey(dictionary, normalizedKey) ?: canonicalKey;
    if (value) {
        dictionary[key] = value;
    } else {
        [dictionary removeObjectForKey:key];
    }
}

static BOOL CGBSafeIdentifier(NSString *identifier) {
    if (identifier.length == 0 || identifier.length > 256) {
        return NO;
    }
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        invalidCharacters = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"] invertedSet];
    });
    return [identifier rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

static NSDictionary *CGBSelection(NSString *model,
                                  NSString *_Nullable effort,
                                  NSString *_Nullable tier) {
    if (!CGBSafeIdentifier(model) || (effort && !CGBSafeIdentifier(effort)) ||
        (tier && !CGBSafeIdentifier(tier))) {
        return nil;
    }
    NSMutableDictionary *selection = [@{ @"model": model } mutableCopy];
    if (effort.length > 0) {
        selection[@"thinking_effort"] = effort;
    }
    if (tier.length > 0) {
        selection[@"service_tier"] = tier;
    }
    return selection;
}

static NSDictionary *CGBValidatedSelection(id rawSelection) {
    if (![rawSelection isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSString *model = CGBString(CGBValue(rawSelection, @"model"));
    NSString *effort = CGBString(CGBValue(rawSelection, @"thinkingeffort"));
    NSString *tier = CGBString(CGBValue(rawSelection, @"servicetier"));
    return CGBSelection(model, effort, tier);
}

static NSDictionary *CGBPersistedModelSelection(void) {
    id rawSelection = [[NSUserDefaults standardUserDefaults]
        objectForKey:CGBSelectionDefaultsKey];
    return CGBValidatedSelection(rawSelection);
}

static void CGBPersistModelSelection(NSDictionary *selection) {
    NSDictionary *validated = CGBValidatedSelection(selection);
    if (!validated || [validated isEqualToDictionary:CGBPersistedModelSelection()]) {
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:validated forKey:CGBSelectionDefaultsKey];
    // The host app is commonly killed from the app switcher immediately after
    // choosing a model, so explicitly flush this tiny preference update.
    [defaults synchronize];
}

static void CGBReplacePublishedSelections(
    NSDictionary<NSString *, NSDictionary *> *selections,
    NSDictionary<NSString *, NSDictionary *> *displaySelections) {
    @synchronized (CGBSelectionLock()) {
        [CGBPublishedSelections removeAllObjects];
        [CGBPublishedSelections addEntriesFromDictionary:selections ?: @{}];
        [CGBPublishedDisplaySelections removeAllObjects];
        [CGBPublishedDisplaySelections addEntriesFromDictionary:displaySelections ?: @{}];
    }
}

static NSString *CGBNormalizedVisibleText(NSString *text) {
    if (![text isKindOfClass:NSString.class]) {
        return nil;
    }
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *nonempty = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [nonempty addObject:part];
        }
    }
    return nonempty.count > 0 ? [nonempty componentsJoinedByString:@" "] : nil;
}

BOOL CGBPersistPublishedModelSelectionMatchingVisibleText(NSString *text,
                                                           NSString **displayOut) {
    NSString *visibleText = CGBNormalizedVisibleText(text);
    if (visibleText.length == 0) {
        return NO;
    }

    __block NSString *bestDisplay = nil;
    __block NSDictionary *bestSelection = nil;
    __block BOOL ambiguous = NO;
    @synchronized (CGBSelectionLock()) {
        [CGBPublishedDisplaySelections enumerateKeysAndObjectsUsingBlock:
            ^(NSString *display, NSDictionary *selection, BOOL *stop) {
            (void)stop;
            NSRange match = [visibleText rangeOfString:display
                                               options:NSCaseInsensitiveSearch];
            if (match.location == NSNotFound) {
                return;
            }
            if (!bestDisplay || display.length > bestDisplay.length) {
                bestDisplay = display;
                bestSelection = selection;
                ambiguous = NO;
            } else if (display.length == bestDisplay.length &&
                       ![selection isEqualToDictionary:bestSelection]) {
                ambiguous = YES;
            }
        }];
    }
    if (!bestSelection || ambiguous) {
        return NO;
    }
    CGBPersistModelSelection(bestSelection);
    if (displayOut) {
        *displayOut = bestDisplay;
    }
    return YES;
}

static NSDictionary *CGBPublishedSelection(NSString *legacySlug) {
    if (legacySlug.length == 0) {
        return nil;
    }
    @synchronized (CGBSelectionLock()) {
        return [CGBPublishedSelections[legacySlug] copy];
    }
}

static BOOL CGBOptionalIdentifierMatches(NSString *first, NSString *second) {
    if (first.length == 0 || second.length == 0) {
        return first.length == second.length;
    }
    return [first caseInsensitiveCompare:second] == NSOrderedSame;
}

static NSUInteger CGBPreferredCandidateIndex(NSArray<NSDictionary *> *candidates,
                                              NSDictionary *persistedSelection) {
    NSDictionary *persisted = CGBValidatedSelection(persistedSelection);
    if (!persisted) {
        return NSNotFound;
    }
    NSString *preferredModel = persisted[@"model"];
    NSString *preferredEffort = persisted[@"thinking_effort"];
    NSString *preferredTier = persisted[@"service_tier"];
    NSUInteger modelEffortFallback = NSNotFound;
    for (NSUInteger index = 0; index < candidates.count; index++) {
        NSDictionary *candidate = candidates[index];
        NSString *model = CGBString(candidate[@"model"]);
        NSString *effort = CGBString(candidate[@"effort"]);
        NSString *tier = CGBString(candidate[@"tier"]);
        if (!CGBOptionalIdentifierMatches(model, preferredModel) ||
            !CGBOptionalIdentifierMatches(effort, preferredEffort)) {
            continue;
        }
        if (CGBOptionalIdentifierMatches(tier, preferredTier)) {
            return index;
        }
        // Service tiers are delivery details and can change between catalog
        // revisions. Falling back to the current advertised row with the same
        // model+effort preserves the user's intelligence choice without
        // replaying an obsolete or unavailable tier.
        if (modelEffortFallback == NSNotFound) {
            modelEffortFallback = index;
        }
    }
    return modelEffortFallback;
}

static NSString *CGBBase64URLString(NSString *string) {
    if (string.length == 0) {
        return @"0";
    }
    NSString *encoded = [[string dataUsingEncoding:NSUTF8StringEncoding]
        base64EncodedStringWithOptions:0];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSString *CGBStringFromBase64URL(NSString *encoded) {
    if ([encoded isEqualToString:@"0"]) {
        return nil;
    }
    if (encoded.length == 0 ||
        [encoded rangeOfCharacterFromSet:[[NSCharacterSet
            characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"]
            invertedSet]].location != NSNotFound) {
        return nil;
    }
    NSString *base64 = [[encoded stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger padding = (4 - (base64.length % 4)) % 4;
    base64 = [base64 stringByPaddingToLength:base64.length + padding
                                  withString:@"="
                             startingAtIndex:0];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSString *CGBLegacySlug(NSString *model,
                               NSString *_Nullable thinkingEffort,
                               NSString *_Nullable serviceTier) {
    return [NSString stringWithFormat:@"%@%@.%@.%@",
            CGBSlugPrefix,
            CGBBase64URLString(model),
            CGBBase64URLString(thinkingEffort ?: @""),
            CGBBase64URLString(serviceTier ?: @"")];
}

static BOOL CGBDecodeLegacyModelSlug(NSString *slug,
                                     NSString **modelOut,
                                     NSString **thinkingEffortOut,
                                     NSString **serviceTierOut) {
    if (![slug hasPrefix:CGBSlugPrefix]) {
        return NO;
    }
    NSArray<NSString *> *components = [slug componentsSeparatedByString:@"."];
    if (components.count != 5 ||
        ![components[0] isEqualToString:@"cgbf"] ||
        ![components[1] isEqualToString:@"v1"]) {
        return NO;
    }
    NSString *model = CGBStringFromBase64URL(components[2]);
    NSString *effort = CGBStringFromBase64URL(components[3]);
    NSString *tier = CGBStringFromBase64URL(components[4]);
    if (!CGBSafeIdentifier(model) || (effort && !CGBSafeIdentifier(effort)) ||
        (tier && !CGBSafeIdentifier(tier))) {
        return NO;
    }
    if (modelOut) {
        *modelOut = model;
    }
    if (thinkingEffortOut) {
        *thinkingEffortOut = effort;
    }
    if (serviceTierOut) {
        *serviceTierOut = tier;
    }
    return YES;
}

static BOOL CGBModelIsVisible(NSDictionary *model) {
    for (id value in CGBArray(CGBValue(model, @"tags")) ?: @[]) {
        NSString *tag = CGBString(value).lowercaseString;
        if ([tag isEqualToString:@"hidden"] || [tag isEqualToString:@"confidential"]) {
            return NO;
        }
    }
    return YES;
}

static NSString *CGBFirstString(NSDictionary *dictionary,
                                NSArray<NSString *> *normalizedKeys) {
    for (NSString *key in normalizedKeys) {
        NSString *value = CGBString(CGBValue(dictionary, key));
        if (value.length > 0) {
            return value;
        }
    }
    return nil;
}

static BOOL CGBGenericModelTitle(NSString *title) {
    static NSSet<NSString *> *genericTitles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        genericTitles = [NSSet setWithArray:@[
            @"auto", @"default", @"instant", @"thinking", @"thinking mini", @"pro"
        ]];
    });
    return [genericTitles containsObject:title.lowercaseString];
}

static BOOL CGBTitleContains(NSString *title, NSString *component) {
    return title.length > 0 && component.length > 0 &&
           [title rangeOfString:component options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL CGBLooksLikeModelTitle(NSString *title) {
    NSString *lowercase = title.lowercaseString ?: @"";
    if ([lowercase hasPrefix:@"gpt-"] || [lowercase hasPrefix:@"chatgpt "]) {
        return YES;
    }
    return lowercase.length > 1 && [lowercase characterAtIndex:0] == 'o' &&
           [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:
               [lowercase characterAtIndex:1]];
}

static NSString *CGBFriendlyQualifier(NSString *qualifier) {
    if (qualifier.length == 0) {
        return nil;
    }
    static NSDictionary<NSString *, NSString *> *labels;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        labels = @{
            @"auto": @"Auto",
            @"none": @"Instant",
            @"minimal": @"Instant",
            @"instant": @"Instant",
            @"light": @"Low",
            @"low": @"Low",
            @"medium": @"Medium",
            @"high": @"High",
            @"xhigh": @"Extra High",
            @"standard": @"Medium",
            @"extended": @"High",
            @"heavy": @"Extra High",
            @"max": @"Max",
        };
    });
    return labels[qualifier.lowercaseString] ?: qualifier;
}

static NSString *CGBVersionDisplayName(NSString *version) {
    if (version.length == 0) {
        return nil;
    }
    NSString *lowercase = version.lowercaseString;
    if ([lowercase hasPrefix:@"gpt"] || [lowercase hasPrefix:@"o"]) {
        return version;
    }
    unichar first = [version characterAtIndex:0];
    return [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:first] ?
        [@"GPT-" stringByAppendingString:version] : version;
}

static NSString *CGBModelTitleFromSlug(NSString *modelSlug) {
    NSString *lowercase = modelSlug.lowercaseString ?: @"";
    if (![lowercase hasPrefix:@"gpt-"]) {
        return nil;
    }
    NSArray<NSString *> *parts = [modelSlug componentsSeparatedByString:@"-"];
    if (parts.count < 2 || [CGBString(parts[1]) length] == 0) {
        return nil;
    }

    NSMutableArray<NSString *> *titleParts = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"GPT-%@", parts[1]]];
    static NSDictionary<NSString *, NSString *> *knownComponents;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownComponents = @{
            @"sol": @"Sol", @"terra": @"Terra", @"luna": @"Luna",
            @"instant": @"Instant", @"thinking": @"Thinking",
            @"pro": @"Pro", @"mini": @"Mini", @"nano": @"Nano",
        };
    });
    for (NSUInteger index = 2; index < parts.count; index++) {
        NSString *part = CGBString(parts[index]);
        if (part.length == 0) {
            continue;
        }
        // Snapshot dates are implementation details, not useful picker text.
        if (part.length == 4 &&
            [part rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet]
                .location == NSNotFound) {
            break;
        }
        NSString *display = knownComponents[part.lowercaseString];
        if (!display) {
            break;
        }
        [titleParts addObject:display];
    }
    return [titleParts componentsJoinedByString:@" "];
}

static BOOL CGBQualifierConveysThinking(NSString *qualifier) {
    static NSSet<NSString *> *thinkingLabels;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        thinkingLabels = [NSSet setWithArray:@[
            @"low", @"medium", @"high", @"extra high", @"max"
        ]];
    });
    return [thinkingLabels containsObject:qualifier.lowercaseString];
}

static BOOL CGBTierIsDefault(NSString *tier) {
    NSString *lowercase = tier.lowercaseString;
    return tier.length == 0 || [lowercase isEqualToString:@"default"] ||
           [lowercase isEqualToString:@"auto"];
}

static double CGBGPTVersionNumber(NSString *modelSlug) {
    NSString *lowercase = modelSlug.lowercaseString ?: @"";
    if (![lowercase hasPrefix:@"gpt-"]) {
        return -1.0;
    }
    NSScanner *scanner = [NSScanner scannerWithString:[lowercase substringFromIndex:4]];
    double version = -1.0;
    return [scanner scanDouble:&version] ? version : -1.0;
}

static NSInteger CGBModelVariantRank(NSString *modelSlug) {
    NSString *lowercase = modelSlug.lowercaseString ?: @"";
    if ([lowercase containsString:@"-sol"]) {
        return 0;
    }
    if ([lowercase containsString:@"-terra"]) {
        return 1;
    }
    if ([lowercase containsString:@"-luna"]) {
        return 2;
    }
    return 3;
}

static NSInteger CGBEffortRank(NSDictionary *candidate) {
    NSString *raw = CGBString(candidate[@"effort"]);
    if (raw.length == 0) {
        NSString *preset = CGBString(candidate[@"preset"]);
        raw = CGBLooksLikeModelTitle(preset) ? nil : preset;
    }
    NSString *label = CGBFriendlyQualifier(raw).lowercaseString;
    static NSDictionary<NSString *, NSNumber *> *ranks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ranks = @{
            @"auto": @(-1), @"instant": @0, @"low": @1,
            @"medium": @2, @"high": @3, @"extra high": @4, @"max": @5,
        };
    });
    return ranks[label] ? ranks[label].integerValue : -2;
}

static NSString *CGBDisplayTitle(NSDictionary *candidate,
                                 NSDictionary *model,
                                 NSString *effortLabel,
                                 BOOL showDefaultQualifier) {
    NSString *modelSlug = CGBString(candidate[@"model"]);
    NSString *modelTitle = CGBString(CGBValue(model, @"title")) ?: modelSlug;
    NSString *version = CGBString(candidate[@"version"]);
    NSString *preset = CGBString(candidate[@"preset"]);
    NSString *base = modelTitle;
    NSString *slugTitle = CGBModelTitleFromSlug(modelSlug);
    if (CGBGenericModelTitle(base)) {
        base = slugTitle ?: CGBVersionDisplayName(version) ?: base;
    } else if (slugTitle.length > base.length && CGBTitleContains(slugTitle, base)) {
        base = slugTitle;
    }

    NSString *qualifier = CGBFriendlyQualifier(effortLabel);
    if (qualifier.length == 0 && preset.length > 0 && !CGBLooksLikeModelTitle(preset)) {
        qualifier = preset;
    }
    qualifier = CGBFriendlyQualifier(qualifier);
    if (CGBLooksLikeModelTitle(qualifier)) {
        qualifier = nil;
    }
    if (qualifier.length == 0 && showDefaultQualifier) {
        qualifier = @"Default";
    }
    if (qualifier.length > 0 && !CGBTitleContains(base, qualifier)) {
        if ([base hasSuffix:@" Thinking"] && CGBQualifierConveysThinking(qualifier)) {
            base = [base substringToIndex:base.length - @" Thinking".length];
        }
        return [NSString stringWithFormat:@"%@ (%@)", base, qualifier];
    }
    return base;
}

static NSString *CGBIconForEffort(NSString *effort) {
    NSString *lowercase = effort.lowercaseString ?: @"";
    if ([lowercase containsString:@"instant"] || [lowercase isEqualToString:@"none"] ||
        [lowercase isEqualToString:@"low"] || [lowercase isEqualToString:@"minimal"]) {
        return @"bolt";
    }
    if ([lowercase containsString:@"think"] || [lowercase isEqualToString:@"medium"] ||
        [lowercase isEqualToString:@"high"] || [lowercase isEqualToString:@"xhigh"] ||
        [lowercase isEqualToString:@"max"] || [lowercase isEqualToString:@"extended"]) {
        return @"stars";
    }
    return @"star";
}

NSDictionary *CGBLegacyModelCatalog(NSDictionary *catalog,
                                    NSArray<NSDictionary *> **summaryOut) {
    // Do not carry an entitlement-sensitive slug map across accounts or a
    // catalog response that we could not validate.
    CGBReplacePublishedSelections(@{}, @{});
    NSArray *rawModels = CGBArray(CGBValue(catalog, @"models"));
    if (rawModels.count == 0) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *modelsBySlug = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *modelOrder = [NSMutableArray array];
    for (id rawModel in rawModels) {
        if (![rawModel isKindOfClass:NSDictionary.class] || !CGBModelIsVisible(rawModel)) {
            continue;
        }
        NSString *slug = CGBString(CGBValue(rawModel, @"slug"));
        if (!CGBSafeIdentifier(slug) || modelsBySlug[slug]) {
            continue;
        }
        modelsBySlug[slug] = rawModel;
        [modelOrder addObject:slug];
    }
    if (modelsBySlug.count == 0) {
        return nil;
    }

    NSArray *rawCategories = CGBArray(CGBValue(catalog, @"categories")) ?: @[];
    NSArray *rawVersions = CGBArray(CGBValue(catalog, @"versions")) ?: @[];
    NSMutableDictionary<NSString *, NSDictionary *> *categoryByModel = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *eligibleModels = [NSMutableSet set];
    NSArray<NSString *> *categoryModelKeys = @[
        @"defaultmodel", @"browsingmodel", @"codeinterpretermodel", @"dallemodel"
    ];
    for (id rawCategory in rawCategories) {
        if (![rawCategory isKindOfClass:NSDictionary.class] ||
            [CGBValue(rawCategory, @"disabledbyadmin") boolValue]) {
            continue;
        }
        for (NSString *key in categoryModelKeys) {
            NSString *slug = CGBString(CGBValue(rawCategory, key));
            if (modelsBySlug[slug]) {
                [eligibleModels addObject:slug];
                if (!categoryByModel[slug]) {
                    categoryByModel[slug] = rawCategory;
                }
            }
        }
    }

    NSMutableArray<NSMutableDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *candidateKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *representedModelEfforts = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *versionByModel = [NSMutableDictionary dictionary];
    void (^addCandidate)(NSString *, NSString *, NSString *, NSString *, NSString *) =
        ^(NSString *modelSlug,
          NSString *effort,
          NSString *tier,
          NSString *version,
          NSString *preset) {
        if (!modelsBySlug[modelSlug]) {
            return;
        }
        NSString *key = [NSString stringWithFormat:@"%@\x1f%@\x1f%@",
                         modelSlug, effort ?: @"", tier ?: @""];
        if ([candidateKeys containsObject:key]) {
            return;
        }
        [candidateKeys addObject:key];
        [representedModelEfforts addObject:[NSString stringWithFormat:@"%@\x1f%@",
                                            modelSlug, effort ?: @""]];
        [eligibleModels addObject:modelSlug];
        NSMutableDictionary *candidate = [@{ @"model": modelSlug } mutableCopy];
        if (effort.length > 0) {
            candidate[@"effort"] = effort;
        }
        if (tier.length > 0) {
            candidate[@"tier"] = tier;
        }
        if (version.length > 0) {
            candidate[@"version"] = version;
        }
        if (preset.length > 0) {
            candidate[@"preset"] = preset;
        }
        candidate[@"source_order"] = @(candidates.count);
        [candidates addObject:candidate];
    };

    for (id rawVersion in rawVersions) {
        if (![rawVersion isKindOfClass:NSDictionary.class] ||
            [CGBValue(rawVersion, @"disabled") boolValue]) {
            continue;
        }
        NSString *versionLabel = CGBFirstString(rawVersion, @[
            @"displaytextforintelligence", @"displaytextfull", @"displaytext", @"id"
        ]);
        for (id rawSlug in CGBArray(CGBValue(rawVersion, @"slugs")) ?: @[]) {
            NSString *slug = CGBString(rawSlug);
            if (modelsBySlug[slug] && versionLabel.length > 0 && !versionByModel[slug]) {
                versionByModel[slug] = versionLabel;
            }
        }
        NSArray *presets = CGBArray(CGBValue(rawVersion, @"intelligencepresets")) ?: @[];
        for (id rawPreset in presets) {
            if (![rawPreset isKindOfClass:NSDictionary.class]) {
                continue;
            }
            NSString *modelSlug = CGBString(CGBValue(rawPreset, @"modelslug"));
            NSString *effort = CGBString(CGBValue(rawPreset, @"thinkingeffort"));
            NSString *tier = CGBString(CGBValue(rawPreset, @"defaultservicetier"));
            // `title` is the intelligence label shown as the option (for
            // example Instant). `selected_display_title` may be a separate
            // product-facing model name and must not be appended to the real
            // model title (which produced "Luna — Sol" in the legacy menu).
            NSString *presetLabel = CGBFirstString(rawPreset, @[
                @"title", @"selecteddisplaytitle"
            ]);
            if (modelsBySlug[modelSlug] && versionLabel.length > 0 && !versionByModel[modelSlug]) {
                versionByModel[modelSlug] = versionLabel;
            }
            addCandidate(modelSlug, effort, tier, versionLabel, presetLabel);
        }
    }

    if (eligibleModels.count == 0) {
        [eligibleModels addObjectsFromArray:modelOrder];
    }

    // The modern catalog explicitly lists every supported thinking effort per
    // model. Flatten those combinations so the legacy menu can represent the
    // intelligence control without pretending each effort is a new model.
    for (NSString *modelSlug in modelOrder) {
        if (![eligibleModels containsObject:modelSlug]) {
            continue;
        }
        NSDictionary *model = modelsBySlug[modelSlug];
        NSArray *efforts = CGBArray(CGBValue(model, @"thinkingefforts")) ?: @[];
        BOOL addedEffort = NO;
        if ([CGBValue(model, @"configurablethinkingeffort") boolValue]) {
            for (id rawEffort in efforts) {
                if (![rawEffort isKindOfClass:NSDictionary.class]) {
                    continue;
                }
                NSString *effort = CGBString(CGBValue(rawEffort, @"thinkingeffort"));
                if (effort.length > 0) {
                    NSString *representedKey = [NSString stringWithFormat:@"%@\x1f%@",
                                                modelSlug, effort];
                    if (![representedModelEfforts containsObject:representedKey]) {
                        addCandidate(modelSlug, effort, nil, versionByModel[modelSlug],
                                     CGBString(CGBValue(rawEffort, @"shortlabel")));
                    }
                    addedEffort = YES;
                }
            }
        }
        if (!addedEffort) {
            NSString *representedKey = [NSString stringWithFormat:@"%@\x1f", modelSlug];
            if (![representedModelEfforts containsObject:representedKey]) {
                addCandidate(modelSlug, nil, nil, versionByModel[modelSlug], nil);
            }
        }
    }

    // A modern catalog can contain both an unqualified model preset and an
    // explicit entry for that model's default effort. They produce the same
    // request, so keep the explicit, self-explanatory row and remove the
    // otherwise confusing plain duplicate.
    NSMutableSet<NSString *> *modelsWithExplicitDefaultEffort = [NSMutableSet set];
    for (NSDictionary *candidate in candidates) {
        NSString *modelSlug = CGBString(candidate[@"model"]);
        NSString *effort = CGBString(candidate[@"effort"]);
        NSString *defaultEffort = CGBString(CGBValue(modelsBySlug[modelSlug],
                                                     @"defaultthinkingeffort"));
        if (defaultEffort.length > 0 &&
            [effort.lowercaseString isEqualToString:defaultEffort.lowercaseString] &&
            CGBTierIsDefault(CGBString(candidate[@"tier"]))) {
            [modelsWithExplicitDefaultEffort addObject:modelSlug];
        }
    }

    NSMutableArray<NSMutableDictionary *> *filteredCandidates = [NSMutableArray array];
    for (NSMutableDictionary *candidate in candidates) {
        NSString *modelSlug = CGBString(candidate[@"model"]);
        NSString *effort = CGBString(candidate[@"effort"]);
        NSString *tier = CGBString(candidate[@"tier"]);
        NSString *preset = CGBString(candidate[@"preset"]);
        NSString *defaultEffort = CGBString(CGBValue(modelsBySlug[modelSlug],
                                                     @"defaultthinkingeffort"));
        NSString *friendlyPreset = CGBFriendlyQualifier(preset);
        NSString *friendlyDefault = CGBFriendlyQualifier(defaultEffort);
        BOOL presetDescribesDefault = preset.length == 0 || CGBLooksLikeModelTitle(preset) ||
            [preset caseInsensitiveCompare:@"default"] == NSOrderedSame ||
            (friendlyPreset.length > 0 && friendlyDefault.length > 0 &&
             [friendlyPreset caseInsensitiveCompare:friendlyDefault] == NSOrderedSame);
        BOOL redundantUnqualifiedDefault = effort.length == 0 && CGBTierIsDefault(tier) &&
            [modelsWithExplicitDefaultEffort containsObject:modelSlug] &&
            presetDescribesDefault;
        if (!redundantUnqualifiedDefault) {
            [filteredCandidates addObject:candidate];
        }
    }
    candidates = filteredCandidates;

    // Keep the flat legacy menu predictable: newest GPT family first, model
    // variants together, shallow-to-deep effort, then older o-series models.
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *first,
                                                         NSDictionary *second) {
        NSString *firstSlug = CGBString(first[@"model"]);
        NSString *secondSlug = CGBString(second[@"model"]);
        double firstVersion = CGBGPTVersionNumber(firstSlug);
        double secondVersion = CGBGPTVersionNumber(secondSlug);
        BOOL firstIsGPT = firstVersion >= 0.0;
        BOOL secondIsGPT = secondVersion >= 0.0;
        if (firstIsGPT != secondIsGPT) {
            return firstIsGPT ? NSOrderedAscending : NSOrderedDescending;
        }
        if (firstVersion != secondVersion) {
            return firstVersion > secondVersion ? NSOrderedAscending : NSOrderedDescending;
        }
        NSInteger firstVariant = CGBModelVariantRank(firstSlug);
        NSInteger secondVariant = CGBModelVariantRank(secondSlug);
        if (firstVariant != secondVariant) {
            return firstVariant < secondVariant ? NSOrderedAscending : NSOrderedDescending;
        }
        NSString *firstTitle = CGBString(CGBValue(modelsBySlug[firstSlug], @"title")) ?: firstSlug;
        NSString *secondTitle = CGBString(CGBValue(modelsBySlug[secondSlug], @"title")) ?: secondSlug;
        NSComparisonResult titleResult = [firstTitle localizedCaseInsensitiveCompare:secondTitle];
        if (titleResult != NSOrderedSame) {
            return titleResult;
        }
        NSInteger firstEffort = CGBEffortRank(first);
        NSInteger secondEffort = CGBEffortRank(second);
        if (firstEffort != secondEffort) {
            return firstEffort < secondEffort ? NSOrderedAscending : NSOrderedDescending;
        }
        return [first[@"source_order"] compare:second[@"source_order"]];
    }];

    if (candidates.count == 0) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSNumber *> *candidateCountsByModel =
        [NSMutableDictionary dictionary];
    for (NSDictionary *candidate in candidates) {
        NSString *modelSlug = CGBString(candidate[@"model"]);
        candidateCountsByModel[modelSlug] =
            @([candidateCountsByModel[modelSlug] unsignedIntegerValue] + 1);
    }

    NSMutableArray<NSDictionary *> *legacyModels = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *legacyCategories = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *summary = [NSMutableArray array];
    NSMutableSet<NSString *> *canonicalModelsUsed = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *displayNameCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *publishedSelections =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *publishedDisplaySelections =
        [NSMutableDictionary dictionary];
    NSDictionary *persistedSelection = CGBPersistedModelSelection();
    NSUInteger preferredCandidateIndex =
        CGBPreferredCandidateIndex(candidates, persistedSelection);
    NSString *preferredLegacyDefault = nil;
    NSString *originalDefault = CGBString(CGBValue(catalog, @"defaultmodelslug"));
    NSString *legacyDefault = nil;

    for (NSUInteger candidateIndex = 0; candidateIndex < candidates.count; candidateIndex++) {
        NSMutableDictionary *candidate = candidates[candidateIndex];
        NSString *modelSlug = candidate[@"model"];
        NSDictionary *model = modelsBySlug[modelSlug];
        NSString *effort = candidate[@"effort"];
        NSString *tier = candidate[@"tier"];
        NSString *defaultEffort = CGBString(CGBValue(model, @"defaultthinkingeffort"));

        NSString *effortLabel = nil;
        for (id rawEffort in CGBArray(CGBValue(model, @"thinkingefforts")) ?: @[]) {
            if (![rawEffort isKindOfClass:NSDictionary.class]) {
                continue;
            }
            NSString *candidateEffort = CGBString(CGBValue(rawEffort, @"thinkingeffort"));
            if ([candidateEffort isEqualToString:effort]) {
                effortLabel = CGBString(CGBValue(rawEffort, @"shortlabel"));
                break;
            }
        }
        effortLabel = effortLabel ?: effort;
        BOOL showDefaultQualifier = effort.length == 0 &&
            [candidateCountsByModel[modelSlug] unsignedIntegerValue] > 1;
        NSString *display = CGBDisplayTitle(candidate, model, effortLabel,
                                            showDefaultQualifier) ?: modelSlug;
        NSString *displayKey = display.lowercaseString;
        NSUInteger duplicateIndex = [displayNameCounts[displayKey] unsignedIntegerValue];
        displayNameCounts[displayKey] = @(duplicateIndex + 1);
        if (duplicateIndex > 0) {
            display = [NSString stringWithFormat:@"%@ · %@", display, modelSlug];
        }

        BOOL defaultTier = tier.length == 0 || [tier isEqualToString:@"default"] ||
                           [tier isEqualToString:@"auto"];
        BOOL defaultSelection = (effort.length == 0 ||
                                 (defaultEffort.length > 0 && [effort isEqualToString:defaultEffort])) &&
                                defaultTier;
        BOOL usesRealSlug = defaultSelection && ![canonicalModelsUsed containsObject:modelSlug];
        NSString *legacySlug = usesRealSlug ? modelSlug : CGBLegacySlug(modelSlug, effort, tier);
        if (usesRealSlug) {
            [canonicalModelsUsed addObject:modelSlug];
        }
        NSDictionary *selection = CGBSelection(modelSlug, effort, tier);
        if (selection) {
            publishedSelections[legacySlug] = selection;
            publishedDisplaySelections[display] = selection;
        }
        if (candidateIndex == preferredCandidateIndex) {
            preferredLegacyDefault = legacySlug;
        }

        NSMutableDictionary *legacyModel = [model mutableCopy];
        CGBSetValue(legacyModel, @"slug", @"slug", legacySlug);
        CGBSetValue(legacyModel, @"title", @"title", display);
        [legacyModels addObject:legacyModel];

        NSDictionary *sourceCategory = categoryByModel[modelSlug];
        NSString *subscriptionLevel = CGBString(CGBValue(sourceCategory, @"subscriptionlevel")) ?: @"plus";
        NSString *icon = CGBString(CGBValue(sourceCategory, @"icon"));
        static NSSet<NSString *> *legacyIcons;
        static dispatch_once_t iconOnceToken;
        dispatch_once(&iconOnceToken, ^{
            legacyIcons = [NSSet setWithArray:@[@"lab", @"bolt", @"star", @"stars", @"connected"]];
        });
        if (![legacyIcons containsObject:icon]) {
            icon = CGBIconForEffort(effortLabel);
        }
        NSString *explainer = CGBString(CGBValue(sourceCategory, @"shortexplainer"));
        if (effortLabel.length > 0) {
            explainer = [NSString stringWithFormat:@"%@ intelligence on %@",
                         effortLabel, CGBString(CGBValue(model, @"title")) ?: modelSlug];
        } else if (explainer.length == 0) {
            explainer = CGBString(CGBValue(model, @"description"));
        }

        NSMutableDictionary *legacyCategory = [@{
            @"human_category_name": display,
            @"human_category_short_name": display,
            @"icon": icon,
            @"subscription_level": subscriptionLevel,
            @"default_model": legacySlug,
        } mutableCopy];
        if (explainer.length > 0) {
            legacyCategory[@"short_explainer"] = explainer;
        }
        NSString *color = CGBString(CGBValue(sourceCategory, @"color"));
        if (color.length > 0) {
            legacyCategory[@"color"] = color;
        }
        for (NSString *specializedKey in @[
                 @"browsing_model", @"code_interpreter_model", @"dalle_model"
             ]) {
            if (CGBValue(sourceCategory, CGBNormalizedKey(specializedKey))) {
                legacyCategory[specializedKey] = legacySlug;
            }
        }
        [legacyCategories addObject:legacyCategory];

        NSMutableDictionary *summaryItem = [@{
            @"display": display,
            @"model": modelSlug,
            @"legacy_slug": usesRealSlug ? @"real" : @"synthetic",
        } mutableCopy];
        if (effort.length > 0) {
            summaryItem[@"thinking_effort"] = effort;
        }
        if (tier.length > 0) {
            summaryItem[@"service_tier"] = tier;
        }
        if (candidateIndex == preferredCandidateIndex) {
            summaryItem[@"restored_default"] = @YES;
        }
        [summary addObject:summaryItem];

        if (!legacyDefault && [modelSlug isEqualToString:originalDefault] && usesRealSlug) {
            legacyDefault = legacySlug;
        }
    }

    if (legacyModels.count == 0 || legacyCategories.count == 0) {
        return nil;
    }
    if (!legacyDefault) {
        for (NSUInteger index = 0; index < candidates.count; index++) {
            if ([candidates[index][@"model"] isEqualToString:originalDefault]) {
                legacyDefault = CGBString(CGBValue(legacyModels[index], @"slug"));
                break;
            }
        }
    }
    legacyDefault = legacyDefault ?: CGBString(CGBValue(legacyModels.firstObject, @"slug"));
    if (preferredLegacyDefault.length > 0) {
        legacyDefault = preferredLegacyDefault;
        // If only a service-tier detail changed, migrate to the exact current
        // server-advertised tuple while preserving the chosen model+effort.
        CGBPersistModelSelection(publishedSelections[preferredLegacyDefault]);
    }
    CGBReplacePublishedSelections(publishedSelections, publishedDisplaySelections);

    NSMutableDictionary *result = [catalog mutableCopy];
    CGBSetValue(result, @"models", @"models", legacyModels);
    CGBSetValue(result, @"categories", @"categories", legacyCategories);
    CGBSetValue(result, @"defaultmodelslug", @"default_model_slug", legacyDefault);
    if (summaryOut) {
        *summaryOut = [summary copy];
    }
    return result;
}

NSDictionary *CGBConversationBodyByResolvingModelSelection(
    NSDictionary *body,
    NSDictionary **selectionOut) {
    NSString *legacySlug = CGBString(CGBValue(body, @"model"));
    NSDictionary *publishedSelection = CGBPublishedSelection(legacySlug);
    if (publishedSelection) {
        // Real slugs represent the default effort for their model and require
        // no request rewrite, but choosing one must still replace an older
        // persisted synthetic/deep preference.
        CGBPersistModelSelection(publishedSelection);
    }
    NSString *model = nil;
    NSString *effort = nil;
    NSString *tier = nil;
    if (!CGBDecodeLegacyModelSlug(legacySlug, &model, &effort, &tier)) {
        return nil;
    }

    NSMutableDictionary *result = [body mutableCopy];
    CGBSetValue(result, @"model", @"model", model);
    CGBSetValue(result, @"thinkingeffort", @"thinking_effort", effort);
    CGBSetValue(result, @"servicetier", @"service_tier", tier);
    if (selectionOut) {
        NSMutableDictionary *selection = [@{ @"model": model } mutableCopy];
        if (effort.length > 0) {
            selection[@"thinking_effort"] = effort;
        }
        if (tier.length > 0) {
            selection[@"service_tier"] = tier;
        }
        *selectionOut = selection;
    }
    return result;
}

NSDictionary *CGBVoiceBodyByResolvingModelSelection(
    NSDictionary *body,
    NSDictionary **selectionOut) {
    NSString *legacySlug = CGBString(CGBValue(body, @"modelslug"));
    NSDictionary *publishedSelection = CGBPublishedSelection(legacySlug);
    if (publishedSelection) {
        CGBPersistModelSelection(publishedSelection);
    }
    NSString *model = nil;
    NSString *effort = nil;
    NSString *tier = nil;
    if (!CGBDecodeLegacyModelSlug(legacySlug, &model, &effort, &tier)) {
        return nil;
    }

    NSMutableDictionary *result = [body mutableCopy];
    CGBSetValue(result, @"modelslug", @"model_slug", model);
    CGBSetValue(result, @"thinkingeffort", @"thinking_effort", effort);
    if (selectionOut) {
        NSMutableDictionary *selection = [@{ @"model": model } mutableCopy];
        if (effort.length > 0) {
            selection[@"thinking_effort"] = effort;
        }
        if (tier.length > 0) {
            // The voice token schema has no service-tier field. Retain this in
            // diagnostics so it is obvious when voice intentionally omits it.
            selection[@"service_tier_ignored"] = tier;
        }
        *selectionOut = selection;
    }
    return result;
}

#if defined(CGB_MODEL_SWITCHER_TESTING)
NSDictionary *CGBTestingPersistedModelSelection(void) {
    return CGBPersistedModelSelection();
}

void CGBTestingClearPersistedModelSelection(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:CGBSelectionDefaultsKey];
    [defaults synchronize];
}

BOOL CGBTestingDecodeLegacyModelSlug(NSString *slug,
                                     NSString **modelOut,
                                     NSString **thinkingEffortOut,
                                     NSString **serviceTierOut) {
    return CGBDecodeLegacyModelSlug(slug, modelOut, thinkingEffortOut,
                                    serviceTierOut);
}
#endif
