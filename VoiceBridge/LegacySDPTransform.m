#import "LegacySDPTransform.h"

static BOOL LVBIsDecimalPayloadType(NSString *value) {
    if (value.length == 0 || value.length > 3) {
        return NO;
    }
    return [value rangeOfCharacterFromSet:
        NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

static BOOL LVBLineBelongsToPayload(NSString *line,
                                    NSString *attribute,
                                    NSString *payloadType) {
    NSString *prefix = [NSString stringWithFormat:@"%@%@", attribute, payloadType];
    if (![line.lowercaseString hasPrefix:prefix.lowercaseString]) {
        return NO;
    }
    if (line.length == prefix.length) {
        return YES;
    }
    unichar separator = [line characterAtIndex:prefix.length];
    return separator == ' ' || separator == '\t';
}

NSString *LVBTransformRealtimeOfferSDP(NSString *offerSDP,
                                      NSString **opusPayloadType) {
    if (opusPayloadType) {
        *opusPayloadType = nil;
    }
    if (offerSDP.length == 0) {
        return offerSDP ?: @"";
    }

    // The current client preserves whichever separator the WebRTC engine
    // emitted. Splitting this way also preserves the final empty component and
    // therefore the SDP's trailing line ending.
    NSString *lineEnding = [offerSDP containsString:@"\r\n"] ? @"\r\n" : @"\n";
    NSMutableArray<NSString *> *lines =
        [[offerSDP componentsSeparatedByString:lineEnding] mutableCopy];

    NSInteger audioStart = NSNotFound;
    NSInteger audioEnd = (NSInteger)lines.count;
    for (NSInteger index = 0; index < (NSInteger)lines.count; index++) {
        NSString *lowercase = lines[(NSUInteger)index].lowercaseString;
        if ([lowercase hasPrefix:@"m=audio "] || [lowercase isEqualToString:@"m=audio"]) {
            audioStart = index;
            continue;
        }
        if (audioStart != NSNotFound && [lowercase hasPrefix:@"m="]) {
            audioEnd = index;
            break;
        }
    }
    if (audioStart == NSNotFound) {
        return offerSDP;
    }

    NSInteger opusRtpmapIndex = NSNotFound;
    NSString *payloadType = nil;
    for (NSInteger index = audioStart + 1; index < audioEnd; index++) {
        NSString *line = lines[(NSUInteger)index];
        if (![line.lowercaseString hasPrefix:@"a=rtpmap:"]) {
            continue;
        }
        NSString *mapping = [line substringFromIndex:@"a=rtpmap:".length];
        NSRange whitespace = [mapping rangeOfCharacterFromSet:
            NSCharacterSet.whitespaceCharacterSet];
        if (whitespace.location == NSNotFound) {
            continue;
        }
        NSString *candidatePayload = [mapping substringToIndex:whitespace.location];
        NSString *codec = [[mapping substringFromIndex:NSMaxRange(whitespace)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange slash = [codec rangeOfString:@"/"];
        NSString *codecName = slash.location == NSNotFound ? codec :
            [codec substringToIndex:slash.location];
        if (LVBIsDecimalPayloadType(candidatePayload) &&
            [codecName caseInsensitiveCompare:@"opus"] == NSOrderedSame) {
            payloadType = candidatePayload;
            opusRtpmapIndex = index;
            break;
        }
    }
    if (payloadType.length == 0 || opusRtpmapIndex == NSNotFound) {
        return offerSDP;
    }
    if (opusPayloadType) {
        *opusPayloadType = payloadType;
    }

    NSString *feedbackLine = [NSString stringWithFormat:@"a=rtcp-fb:%@ nack", payloadType];
    for (NSInteger index = audioStart + 1; index < audioEnd; index++) {
        NSString *line = [lines[(NSUInteger)index]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line caseInsensitiveCompare:feedbackLine] == NSOrderedSame) {
            return offerSDP;
        }
    }

    // Keep feedback beside the Opus codec attributes. The current client puts
    // it after any existing rtpmap/fmtp/rtcp-fb entries for that payload.
    NSInteger insertionIndex = opusRtpmapIndex + 1;
    for (NSInteger index = opusRtpmapIndex + 1; index < audioEnd; index++) {
        NSString *line = [lines[(NSUInteger)index]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (LVBLineBelongsToPayload(line, @"a=fmtp:", payloadType) ||
            LVBLineBelongsToPayload(line, @"a=rtcp-fb:", payloadType)) {
            insertionIndex = index + 1;
        }
    }
    [lines insertObject:feedbackLine atIndex:(NSUInteger)insertionIndex];
    return [lines componentsJoinedByString:lineEnding];
}

NSUInteger LVBSDPCandidateCount(NSString *offerSDP) {
    if (offerSDP.length == 0) {
        return 0;
    }
    NSUInteger count = 0;
    NSRange searchRange = NSMakeRange(0, offerSDP.length);
    while (searchRange.length > 0) {
        NSRange match = [offerSDP rangeOfString:@"a=candidate:"
                                        options:NSCaseInsensitiveSearch
                                          range:searchRange];
        if (match.location == NSNotFound) {
            break;
        }
        count += 1;
        NSUInteger nextLocation = NSMaxRange(match);
        searchRange = NSMakeRange(nextLocation, offerSDP.length - nextLocation);
    }
    return count;
}

NSString *LVBSDPMediaKindsSummary(NSString *offerSDP) {
    if (offerSDP.length == 0) {
        return @"none";
    }
    NSString *normalized = [offerSDP stringByReplacingOccurrencesOfString:@"\r\n"
                                                               withString:@"\n"];
    NSMutableArray<NSString *> *mediaKinds = [NSMutableArray array];
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        if (![line.lowercaseString hasPrefix:@"m="]) {
            continue;
        }
        NSString *remainder = [line substringFromIndex:2];
        NSRange whitespace = [remainder rangeOfCharacterFromSet:
            NSCharacterSet.whitespaceCharacterSet];
        NSString *kind = whitespace.location == NSNotFound ? remainder :
            [remainder substringToIndex:whitespace.location];
        if (kind.length > 0 && kind.length <= 32) {
            [mediaKinds addObject:kind.lowercaseString];
        }
    }
    return mediaKinds.count > 0 ? [mediaKinds componentsJoinedByString:@","] : @"none";
}

NSUInteger LVBSDPBundleMIDCount(NSString *offerSDP) {
    if (offerSDP.length == 0) {
        return 0;
    }
    NSString *normalized = [offerSDP stringByReplacingOccurrencesOfString:@"\r\n"
                                                               withString:@"\n"];
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        if (![line.lowercaseString hasPrefix:@"a=group:bundle "]) {
            continue;
        }
        NSString *mids = [line substringFromIndex:@"a=group:bundle ".length];
        NSArray<NSString *> *parts = [mids componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];
        NSUInteger count = 0;
        for (NSString *part in parts) {
            if (part.length > 0) {
                count += 1;
            }
        }
        return count;
    }
    return 0;
}
