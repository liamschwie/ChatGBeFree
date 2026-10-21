#import "LegacyCopyBridge.h"

NSString *CGBNormalizedCopiedText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0) {
        return @"";
    }

    NSMutableString *result = [text mutableCopy];
    // OAIMarkdown represents inline renderer attachments with U+FFFC. The
    // legacy copy path can leak those placeholders (and adjacent zero-width
    // layout markers) into the pasteboard when modern message decorations are
    // present.
    [result replaceOccurrencesOfString:@"\uFFFC"
                            withString:@""
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\u200B"
                            withString:@""
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\u2060"
                            withString:@""
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\uFEFF"
                            withString:@""
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\u00A0"
                            withString:@" "
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\u2028"
                            withString:@"\n"
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\u2029"
                            withString:@"\n"
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\r\n"
                            withString:@"\n"
                               options:0
                                 range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"\r"
                            withString:@"\n"
                               options:0
                                 range:NSMakeRange(0, result.length)];
    return [result copy];
}

#if defined(CGB_COPY_BRIDGE_TESTING)

void CGBInstallLegacyCopyBridge(void) {}

#else

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP CGBOriginalMarkdownCopyImplementation;
static Class CGBHookedMarkdownTextViewClass;

static NSString *CGBTextForSelectedRange(UITextView *textView) {
    NSRange selectedRange = textView.selectedRange;
    NSAttributedString *attributedText = textView.attributedText;
    if (selectedRange.location == NSNotFound || selectedRange.length == 0 ||
        selectedRange.location > attributedText.length ||
        selectedRange.length > attributedText.length - selectedRange.location) {
        return nil;
    }

    NSMutableAttributedString *selection = [[attributedText
        attributedSubstringFromRange:selectedRange] mutableCopy];
    if (!selection) {
        return nil;
    }

    // Replace attachments from the end so earlier ranges remain stable. When
    // the renderer supplied a meaningful accessibility label, retain it;
    // otherwise remove only the object-replacement glyph.
    NSMutableArray<NSDictionary *> *attachmentRanges = [NSMutableArray array];
    [selection enumerateAttribute:NSAttachmentAttributeName
                          inRange:NSMakeRange(0, selection.length)
                          options:0
                       usingBlock:^(id value, NSRange range, BOOL *stop) {
        (void)stop;
        if (!value || range.length == 0) {
            return;
        }
        NSString *label = nil;
        if ([value respondsToSelector:@selector(accessibilityLabel)]) {
            label = [value accessibilityLabel];
        }
        if (label.length > 256) {
            label = nil;
        }
        [attachmentRanges addObject:@{
            @"range": [NSValue valueWithRange:range],
            @"label": label ?: @"",
        }];
    }];
    for (NSDictionary *item in attachmentRanges.reverseObjectEnumerator) {
        [selection replaceCharactersInRange:[item[@"range"] rangeValue]
                                  withString:item[@"label"]];
    }

    return CGBNormalizedCopiedText(selection.string ?: @"");
}

static void CGBMarkdownTextViewCopy(id self, SEL selector, id sender) {
    UITextView *textView = [self isKindOfClass:UITextView.class] ? self : nil;
    NSString *text = textView ? CGBTextForSelectedRange(textView) : nil;
    if (text.length > 0) {
        UIPasteboard.generalPasteboard.string = text;
        return;
    }

    if (CGBOriginalMarkdownCopyImplementation) {
        ((void (*)(id, SEL, id))CGBOriginalMarkdownCopyImplementation)(self, selector, sender);
    }
}

static Class CGBFindLegacyMarkdownCopyingTextView(void) {
    Class exactClass = NSClassFromString(
        @"_TtC11OAIMarkdownP33_19FBFA8096A97C812DB987D3789FA7CA21CustomCopyingTextView");
    if (exactClass) {
        return exactClass;
    }

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    Class result = Nil;
    for (unsigned int index = 0; index < classCount; index++) {
        Class candidate = classes[index];
        NSString *name = NSStringFromClass(candidate);
        if ([name containsString:@"OAIMarkdown"] &&
            [name hasSuffix:@"CustomCopyingTextView"] &&
            [candidate isSubclassOfClass:UITextView.class]) {
            result = candidate;
            break;
        }
    }
    free(classes);
    return result;
}

static void CGBTryInstallLegacyCopyBridge(void) {
    @synchronized (UITextView.class) {
        if (CGBHookedMarkdownTextViewClass) {
            return;
        }
        Class candidate = CGBFindLegacyMarkdownCopyingTextView();
        Method copyMethod = candidate ? class_getInstanceMethod(candidate, @selector(copy:)) : NULL;
        if (!copyMethod) {
            return;
        }
        IMP existing = method_getImplementation(copyMethod);
        if (existing == (IMP)CGBMarkdownTextViewCopy) {
            CGBHookedMarkdownTextViewClass = candidate;
            return;
        }
        CGBOriginalMarkdownCopyImplementation = existing;
        method_setImplementation(copyMethod, (IMP)CGBMarkdownTextViewCopy);
        CGBHookedMarkdownTextViewClass = candidate;
        NSLog(@"[ChatGBeFree] legacy markdown copy bridge installed class=%@",
              NSStringFromClass(candidate));
    }
}

void CGBInstallLegacyCopyBridge(void) {
    CGBTryInstallLegacyCopyBridge();
    // Some Swift metadata is registered after tweak constructors. Retry on
    // the first main-run-loop turn without delaying app startup.
    dispatch_async(dispatch_get_main_queue(), ^{
        CGBTryInstallLegacyCopyBridge();
    });
}

#endif
