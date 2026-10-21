#import "LegacyImageBridge.h"

static NSString *CGBNormalizedImageKey(NSString *key) {
    NSString *normalized = key.lowercaseString ?: @"";
    normalized = [normalized stringByReplacingOccurrencesOfString:@"_" withString:@""];
    return [normalized stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

BOOL CGBIsSedimentAssetURL(NSURL *URL) {
    return [URL.scheme.lowercaseString isEqualToString:@"sediment"];
}

NSURL *CGBLegacyFileServiceURLForSedimentURL(NSURL *URL) {
    if (!CGBIsSedimentAssetURL(URL)) {
        return nil;
    }

    NSString *absoluteString = URL.absoluteString;
    NSRange separator = [absoluteString rangeOfString:@":"];
    if (separator.location == NSNotFound) {
        return nil;
    }

    NSString *suffix = [absoluteString substringFromIndex:NSMaxRange(separator)];
    return [NSURL URLWithString:[@"file-service:" stringByAppendingString:suffix]];
}

NSDictionary<NSString *, id> *CGBSafeAssetURLSummary(NSURL *URL) {
    if (!URL) {
        return @{ @"present": @NO };
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:URL
                                            resolvingAgainstBaseURL:NO];
    NSMutableSet<NSString *> *queryNames = [NSMutableSet set];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = CGBNormalizedImageKey(item.name);
        if (name.length > 0 && name.length <= 64) {
            [queryNames addObject:name];
        }
    }

    NSString *host = URL.host ?: @"";
    NSString *path = URL.path ?: @"";
    return @{
        @"present": @YES,
        @"scheme": URL.scheme.lowercaseString ?: @"none",
        @"host_present": @(host.length > 0),
        @"host_looks_like_file_id": @([host hasPrefix:@"file_"]),
        @"path_present": @(path.length > 0 && ![path isEqualToString:@"/"]),
        @"query_names": [[queryNames allObjects] sortedArrayUsingSelector:@selector(compare:)],
    };
}

static BOOL CGBStringLooksImageRelated(NSString *value) {
    NSString *normalized = CGBNormalizedImageKey(value);
    return [normalized containsString:@"image"] ||
           [normalized containsString:@"dalle"] ||
           [normalized containsString:@"paragen"] ||
           [normalized containsString:@"assetpointer"] ||
           [normalized containsString:@"generation"] ||
           [normalized containsString:@"sediment"];
}

static BOOL CGBSafeDiagnosticToken(NSString *value) {
    if (value.length == 0 || value.length > 96) {
        return NO;
    }
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *allowed = [NSCharacterSet
            characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/"];
        invalidCharacters = allowed.invertedSet;
    });
    return [value rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

static void CGBCollectImageEventStructure(id object,
                                          NSUInteger depth,
                                          NSUInteger *visited,
                                          BOOL *imageRelated,
                                          NSMutableSet<NSString *> *keys,
                                          NSMutableSet<NSString *> *types,
                                          NSMutableSet<NSString *> *schemes) {
    if (!object || depth > 8 || *visited >= 512) {
        return;
    }
    (*visited)++;

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        for (id rawKey in dictionary) {
            if (![rawKey isKindOfClass:NSString.class]) {
                continue;
            }
            NSString *key = rawKey;
            NSString *normalizedKey = CGBNormalizedImageKey(key);
            id value = dictionary[key];

            if (CGBStringLooksImageRelated(normalizedKey)) {
                *imageRelated = YES;
                if (normalizedKey.length <= 64) {
                    [keys addObject:normalizedKey];
                }
            }

            BOOL isTypeKey = [normalizedKey isEqualToString:@"type"] ||
                             [normalizedKey isEqualToString:@"contenttype"] ||
                             [normalizedKey isEqualToString:@"eventtype"] ||
                             [normalizedKey isEqualToString:@"status"];
            if (isTypeKey && [value isKindOfClass:NSString.class] &&
                CGBSafeDiagnosticToken(value)) {
                [types addObject:value];
                if (CGBStringLooksImageRelated(value)) {
                    *imageRelated = YES;
                }
            }

            CGBCollectImageEventStructure(value, depth + 1, visited, imageRelated,
                                          keys, types, schemes);
            if (*visited >= 512) {
                break;
            }
        }
        return;
    }

    if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            CGBCollectImageEventStructure(value, depth + 1, visited, imageRelated,
                                          keys, types, schemes);
            if (*visited >= 512) {
                break;
            }
        }
        return;
    }

    if (![object isKindOfClass:NSString.class]) {
        return;
    }

    NSString *string = object;
    NSRange schemeSeparator = [string rangeOfString:@"://"];
    if (schemeSeparator.location != NSNotFound && schemeSeparator.location <= 32) {
        NSString *scheme = [[string substringToIndex:schemeSeparator.location] lowercaseString];
        if (CGBSafeDiagnosticToken(scheme)) {
            [schemes addObject:scheme];
        }
        if ([scheme isEqualToString:@"sediment"] ||
            [scheme isEqualToString:@"file-service"]) {
            *imageRelated = YES;
        }
    }
}

NSDictionary<NSString *, id> *CGBSafeImageEventSummary(id object) {
    if (!object) {
        return nil;
    }

    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    NSMutableSet<NSString *> *types = [NSMutableSet set];
    NSMutableSet<NSString *> *schemes = [NSMutableSet set];
    NSUInteger visited = 0;
    BOOL imageRelated = NO;
    CGBCollectImageEventStructure(object, 0, &visited, &imageRelated,
                                  keys, types, schemes);
    if (!imageRelated) {
        return nil;
    }

    return @{
        @"image_keys": [[keys allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"types": [[types allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"asset_schemes": [[schemes allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"scan_limited": @(visited >= 512),
    };
}

static NSString *CGBImageString(id value) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *string = [value stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return string.length > 0 ? string : nil;
}

static NSString *CGBImageKey(NSDictionary *dictionary, NSString *normalizedKey) {
    if (![dictionary isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    for (id rawKey in dictionary) {
        if ([rawKey isKindOfClass:NSString.class] &&
            [CGBNormalizedImageKey(rawKey) isEqualToString:normalizedKey]) {
            return rawKey;
        }
    }
    return nil;
}

static id CGBImageValue(NSDictionary *dictionary, NSString *normalizedKey) {
    NSString *key = CGBImageKey(dictionary, normalizedKey);
    return key ? dictionary[key] : nil;
}

static BOOL CGBSafeImageIdentifier(NSString *value) {
    if (value.length == 0 || value.length > 256) {
        return NO;
    }
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        invalidCharacters = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"] invertedSet];
    });
    return [value rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound;
}

static BOOL CGBContentContainsImageAssetPointer(id object,
                                                 NSUInteger depth,
                                                 NSUInteger *visited) {
    if (!object || depth > 10 || *visited >= 2048) {
        return NO;
    }
    (*visited)++;
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        NSString *contentType = CGBImageString(CGBImageValue(dictionary, @"contenttype"));
        NSString *assetPointer = CGBImageString(CGBImageValue(dictionary, @"assetpointer"));
        if ([contentType.lowercaseString isEqualToString:@"image_asset_pointer"] &&
            assetPointer.length > 0) {
            return YES;
        }
        for (id value in dictionary.allValues) {
            if (CGBContentContainsImageAssetPointer(value, depth + 1, visited)) {
                return YES;
            }
        }
        return NO;
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            if (CGBContentContainsImageAssetPointer(value, depth + 1, visited)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL CGBObjectContainsGeneratedImageMarker(id object,
                                                   NSUInteger depth,
                                                   NSUInteger *visited) {
    if (!object || depth > 8 || *visited >= 4096) {
        return NO;
    }
    (*visited)++;
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        for (id rawKey in dictionary) {
            NSString *key = [rawKey isKindOfClass:NSString.class] ?
                CGBNormalizedImageKey(rawKey) : @"";
            id value = dictionary[rawKey];
            if ([key containsString:@"imagegen"] ||
                [key containsString:@"dalle"] ||
                [key isEqualToString:@"generationid"] ||
                [key isEqualToString:@"generation"] ||
                [key isEqualToString:@"generatedimage"]) {
                return YES;
            }
            if (CGBObjectContainsGeneratedImageMarker(value, depth + 1, visited)) {
                return YES;
            }
        }
        return NO;
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            if (CGBObjectContainsGeneratedImageMarker(value, depth + 1, visited)) {
                return YES;
            }
        }
        return NO;
    }
    if (![object isKindOfClass:NSString.class]) {
        return NO;
    }
    NSString *normalized = CGBNormalizedImageKey(object);
    return [normalized containsString:@"dalle"] ||
           [normalized containsString:@"imagegen"] ||
           [normalized hasPrefix:@"t2uay3k"] ||
           [normalized hasPrefix:@"n7jupd"];
}

static BOOL CGBMessageIsGeneratedImageToolOutput(NSDictionary *dictionary) {
    NSDictionary *author = [CGBImageValue(dictionary, @"author")
        isKindOfClass:NSDictionary.class] ? CGBImageValue(dictionary, @"author") : nil;
    NSString *role = CGBImageString(CGBImageValue(author, @"role"));
    if (![role.lowercaseString isEqualToString:@"tool"]) {
        return NO;
    }

    NSDictionary *metadata = [CGBImageValue(dictionary, @"metadata")
        isKindOfClass:NSDictionary.class] ? CGBImageValue(dictionary, @"metadata") : nil;
    NSString *asyncTaskType = CGBImageString(CGBImageValue(metadata, @"asynctasktype"));
    NSString *recipient = CGBImageString(CGBImageValue(dictionary, @"recipient"));
    NSString *authorName = CGBImageString(CGBImageValue(author, @"name"));
    NSUInteger markerVisited = 0;
    BOOL verifiedImageTool = [asyncTaskType.lowercaseString isEqualToString:@"image_gen"] ||
        [recipient.lowercaseString hasPrefix:@"t2uay3k"] ||
        [authorName.lowercaseString hasPrefix:@"t2uay3k"] ||
        [authorName.lowercaseString hasPrefix:@"n7jupd"] ||
        [recipient.lowercaseString containsString:@"dalle"] ||
        [authorName.lowercaseString containsString:@"dalle"] ||
        CGBObjectContainsGeneratedImageMarker(metadata, 0, &markerVisited);
    if (!verifiedImageTool) {
        return NO;
    }

    NSUInteger visited = 0;
    return CGBContentContainsImageAssetPointer(CGBImageValue(dictionary, @"content"),
                                               0, &visited);
}

static BOOL CGBIsModelCaptionPart(id value) {
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class]) {
        text = value;
    } else if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        NSString *contentType = CGBImageString(CGBImageValue(dictionary, @"contenttype"));
        if ([contentType.lowercaseString isEqualToString:@"text"] ||
            [contentType.lowercaseString isEqualToString:@"output_text"]) {
            text = CGBImageString(CGBImageValue(dictionary, @"text"));
        }
    }
    NSString *normalized = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    return [normalized hasPrefix:@"model caption:"];
}

static NSDictionary *CGBImageContentWithoutModelCaption(NSDictionary *content) {
    if (![content isKindOfClass:NSDictionary.class]) {
        return content;
    }
    NSMutableDictionary *result = [content mutableCopy];
    for (id rawKey in [result.allKeys copy]) {
        if (![rawKey isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *normalizedKey = CGBNormalizedImageKey(rawKey);
        if ([normalizedKey isEqualToString:@"modelcaption"]) {
            [result removeObjectForKey:rawKey];
            continue;
        }
        if ([normalizedKey isEqualToString:@"parts"] &&
            [result[rawKey] isKindOfClass:NSArray.class]) {
            NSMutableArray *visibleParts = [NSMutableArray array];
            for (id part in result[rawKey]) {
                if (!CGBIsModelCaptionPart(part)) {
                    [visibleParts addObject:part];
                }
            }
            result[rawKey] = [visibleParts copy];
        }
    }
    return [result copy];
}

static id CGBRewriteImageObject(id object,
                                NSUInteger depth,
                                NSUInteger *visited,
                                NSUInteger *assetURLRewriteCount,
                                NSUInteger *imageMessageRewriteCount) {
    if (!object || depth > 16 || *visited >= 262144) {
        return object;
    }
    (*visited)++;

    if ([object isKindOfClass:NSString.class]) {
        NSString *string = object;
        if (![string.lowercaseString hasPrefix:@"sediment:"]) {
            return string;
        }
        NSURL *URL = [NSURL URLWithString:string];
        NSURL *legacyURL = CGBLegacyFileServiceURLForSedimentURL(URL);
        if (!legacyURL.absoluteString.length) {
            return string;
        }
        (*assetURLRewriteCount)++;
        return legacyURL.absoluteString;
    }

    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[object count]];
        for (id value in (NSArray *)object) {
            [result addObject:CGBRewriteImageObject(value, depth + 1, visited,
                                                    assetURLRewriteCount,
                                                    imageMessageRewriteCount) ?: NSNull.null];
        }
        return [result copy];
    }

    if (![object isKindOfClass:NSDictionary.class]) {
        return object;
    }

    NSDictionary *dictionary = object;
    BOOL generatedImageToolOutput = CGBMessageIsGeneratedImageToolOutput(dictionary);
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
    for (id rawKey in dictionary) {
        id value = dictionary[rawKey];
        result[rawKey] = CGBRewriteImageObject(value, depth + 1, visited,
                                               assetURLRewriteCount,
                                               imageMessageRewriteCount) ?: NSNull.null;
    }

    if (generatedImageToolOutput) {
        NSString *authorKey = CGBImageKey(result, @"author") ?: @"author";
        NSDictionary *existingAuthor = [result[authorKey] isKindOfClass:NSDictionary.class] ?
            result[authorKey] : @{};
        NSMutableDictionary *legacyAuthor = [existingAuthor mutableCopy];
        NSString *roleKey = CGBImageKey(legacyAuthor, @"role") ?: @"role";
        legacyAuthor[roleKey] = @"assistant";
        for (id rawKey in [legacyAuthor.allKeys copy]) {
            if ([rawKey isKindOfClass:NSString.class] &&
                [CGBNormalizedImageKey(rawKey) isEqualToString:@"name"]) {
                [legacyAuthor removeObjectForKey:rawKey];
            }
        }
        result[authorKey] = [legacyAuthor copy];
        result[@"recipient"] = @"all";
        result[@"channel"] = @"final";
        result[@"status"] = @"finished_successfully";
        result[@"end_turn"] = @YES;

        NSString *contentKey = CGBImageKey(result, @"content") ?: @"content";
        if ([result[contentKey] isKindOfClass:NSDictionary.class]) {
            result[contentKey] = CGBImageContentWithoutModelCaption(result[contentKey]);
        }

        // Modern tool results are deliberately hidden because the new client
        // synthesizes a separate image card. The legacy client has no such
        // card pipeline, so leaving this flag set makes a correctly converted
        // assistant image disappear from both live and cached conversations.
        NSString *metadataKey = CGBImageKey(result, @"metadata") ?: @"metadata";
        if ([result[metadataKey] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *visibleMetadata =
                [result[metadataKey] mutableCopy];
            for (id rawKey in [visibleMetadata.allKeys copy]) {
                NSString *normalizedKey = [rawKey isKindOfClass:NSString.class] ?
                    CGBNormalizedImageKey(rawKey) : @"";
                if ([normalizedKey isEqualToString:@"isvisuallyhiddenfromconversation"] ||
                    [normalizedKey isEqualToString:@"ishiddenfromconversation"] ||
                    [normalizedKey isEqualToString:@"isconversationturnhidden"]) {
                    visibleMetadata[rawKey] = @NO;
                }
            }
            result[metadataKey] = [visibleMetadata copy];
        }
        (*imageMessageRewriteCount)++;
    }
    return [result copy];
}

id CGBLegacyImageCompatibleObject(id object,
                                  NSUInteger *assetURLRewriteCount,
                                  NSUInteger *imageMessageRewriteCount) {
    if (!object) {
        return nil;
    }
    NSUInteger URLCount = 0;
    NSUInteger messageCount = 0;
    NSUInteger visited = 0;
    id result = CGBRewriteImageObject(object, 0, &visited, &URLCount, &messageCount);
    if (assetURLRewriteCount) {
        *assetURLRewriteCount = URLCount;
    }
    if (imageMessageRewriteCount) {
        *imageMessageRewriteCount = messageCount;
    }
    return result;
}

static BOOL CGBObjectContainsAsyncImageMarker(id object,
                                              NSUInteger depth,
                                              NSUInteger *visited) {
    if (!object || depth > 10 || *visited >= 2048) {
        return NO;
    }
    (*visited)++;
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        NSString *asyncTaskType = CGBImageString(CGBImageValue(dictionary, @"asynctasktype"));
        NSString *taskID = CGBImageString(CGBImageValue(dictionary, @"imagegentaskid"));
        NSString *recipient = CGBImageString(CGBImageValue(dictionary, @"recipient"));
        NSString *name = CGBImageString(CGBImageValue(dictionary, @"name"));
        if ([asyncTaskType.lowercaseString isEqualToString:@"image_gen"] ||
            taskID.length > 0 || [recipient.lowercaseString hasPrefix:@"t2uay3k"] ||
            [name.lowercaseString hasPrefix:@"t2uay3k"]) {
            return YES;
        }
        for (id value in dictionary.allValues) {
            if (CGBObjectContainsAsyncImageMarker(value, depth + 1, visited)) {
                return YES;
            }
        }
        return NO;
    }
    if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            if (CGBObjectContainsAsyncImageMarker(value, depth + 1, visited)) {
                return YES;
            }
        }
    }
    return NO;
}

BOOL CGBImageEventIndicatesAsyncGeneration(id object) {
    NSUInteger visited = 0;
    return CGBObjectContainsAsyncImageMarker(object, 0, &visited);
}

static NSString *CGBFindSafeIdentifierForKey(id object,
                                              NSString *normalizedKey,
                                              NSUInteger depth,
                                              NSUInteger *visited) {
    if (!object || depth > 10 || *visited >= 2048) {
        return nil;
    }
    (*visited)++;
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        NSString *candidate = CGBImageString(CGBImageValue(dictionary, normalizedKey));
        if (CGBSafeImageIdentifier(candidate)) {
            return candidate;
        }
        for (id value in dictionary.allValues) {
            NSString *nested = CGBFindSafeIdentifierForKey(value, normalizedKey,
                                                            depth + 1, visited);
            if (nested) {
                return nested;
            }
        }
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            NSString *nested = CGBFindSafeIdentifierForKey(value, normalizedKey,
                                                            depth + 1, visited);
            if (nested) {
                return nested;
            }
        }
    }
    return nil;
}

NSString *CGBConversationIdentifierFromImageEvent(id object) {
    NSUInteger visited = 0;
    return CGBFindSafeIdentifierForKey(object, @"conversationid", 0, &visited);
}

NSString *CGBImageTurnExchangeIdentifierFromEvent(id object) {
    NSUInteger visited = 0;
    return CGBFindSafeIdentifierForKey(object, @"turnexchangeid", 0, &visited);
}

static void CGBCollectGeneratedImageMessages(id object,
                                             NSString *turnExchangeIdentifier,
                                             NSTimeInterval notBeforeCreateTime,
                                             NSUInteger depth,
                                             NSUInteger *visited,
                                             NSMutableArray<NSDictionary *> *messages,
                                             NSMutableSet<NSString *> *messageIDs) {
    if (!object || depth > 12 || *visited >= 65536) {
        return;
    }
    (*visited)++;
    if ([object isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)object) {
            CGBCollectGeneratedImageMessages(value, turnExchangeIdentifier,
                                             notBeforeCreateTime, depth + 1,
                                             visited, messages, messageIDs);
        }
        return;
    }
    if (![object isKindOfClass:NSDictionary.class]) {
        return;
    }

    NSDictionary *dictionary = object;
    if (CGBMessageIsGeneratedImageToolOutput(dictionary)) {
        NSDictionary *metadata = [CGBImageValue(dictionary, @"metadata")
            isKindOfClass:NSDictionary.class] ? CGBImageValue(dictionary, @"metadata") : nil;
        NSString *messageTurn = CGBImageString(CGBImageValue(metadata, @"turnexchangeid"));
        NSNumber *createTime = [CGBImageValue(dictionary, @"createtime")
            isKindOfClass:NSNumber.class] ? CGBImageValue(dictionary, @"createtime") : nil;
        BOOL recentEnough = notBeforeCreateTime <= 0 || createTime == nil ||
            createTime.doubleValue >= notBeforeCreateTime;
        BOOL matchesTurn = turnExchangeIdentifier.length == 0 ||
            [messageTurn isEqualToString:turnExchangeIdentifier] ||
            (messageTurn.length == 0 && createTime != nil && recentEnough);
        NSString *messageID = CGBImageString(CGBImageValue(dictionary, @"id"));
        if (matchesTurn && recentEnough &&
            (messageID.length == 0 || ![messageIDs containsObject:messageID])) {
            NSUInteger URLCount = 0;
            NSUInteger messageCount = 0;
            id rewritten = CGBLegacyImageCompatibleObject(dictionary, &URLCount, &messageCount);
            if ([rewritten isKindOfClass:NSDictionary.class] && messageCount > 0) {
                [messages addObject:rewritten];
                if (messageID.length > 0) {
                    [messageIDs addObject:messageID];
                }
            }
        }
    }

    for (id value in dictionary.allValues) {
        CGBCollectGeneratedImageMessages(value, turnExchangeIdentifier,
                                         notBeforeCreateTime, depth + 1,
                                         visited, messages, messageIDs);
    }
}

NSArray<NSDictionary *> *CGBLegacyGeneratedImageMessages(
    NSDictionary *conversation,
    NSString *turnExchangeIdentifier,
    NSTimeInterval notBeforeCreateTime) {
    if (![conversation isKindOfClass:NSDictionary.class]) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *messages = [NSMutableArray array];
    NSMutableSet<NSString *> *messageIDs = [NSMutableSet set];
    NSUInteger visited = 0;
    CGBCollectGeneratedImageMessages(conversation, turnExchangeIdentifier,
                                     notBeforeCreateTime, 0, &visited,
                                     messages, messageIDs);
    [messages sortUsingComparator:^NSComparisonResult(NSDictionary *first,
                                                       NSDictionary *second) {
        NSNumber *firstTime = CGBImageValue(first, @"createtime");
        NSNumber *secondTime = CGBImageValue(second, @"createtime");
        return [firstTime ?: @0 compare:secondTime ?: @0];
    }];
    return [messages copy];
}
