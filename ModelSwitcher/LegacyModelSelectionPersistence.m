#import "LegacyModelSelectionPersistence.h"
#import "LegacyModelSwitcher.h"
#import "../Runtime/ChatGPTRuntimeResolver.h"

#import <UIKit/UIKit.h>
#import <substrate.h>

// The supported legacy app funnels every picker choice through
// ChatGPTCore.ModelContext.select(ModelSelection). Hooking that single method
// lets us persist a tap even when the user closes the app before sending.
static BOOL CGBModelSelectionPersistenceInstalled;
__attribute__((used)) static void *CGBOriginalModelContextSelect;
static NSUInteger CGBModelSelectionCaptureGeneration;

static BOOL CGBTryPersistText(NSString *text) {
    NSString *display = nil;
    if (!CGBPersistPublishedModelSelectionMatchingVisibleText(text, &display)) {
        return NO;
    }
    NSLog(@"[ChatGBeFree] remembered selected model: %@", display);
    return YES;
}

static BOOL CGBRectIsInNavigationArea(CGRect rect, UIWindow *window) {
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect)) {
        return NO;
    }
    CGRect screenRect = [window convertRect:rect toWindow:nil];
    return CGRectGetMaxY(screenRect) >= 20.0 && CGRectGetMinY(screenRect) < 155.0;
}

static BOOL CGBScanAccessibleObject(id object, UIWindow *window, NSUInteger depth) {
    if (!object || depth > 5) {
        return NO;
    }
    NSString *label = nil;
    NSString *value = nil;
    CGRect frame = CGRectNull;
    @try {
        if ([object respondsToSelector:@selector(accessibilityLabel)]) {
            label = [object accessibilityLabel];
        }
        if ([object respondsToSelector:@selector(accessibilityValue)]) {
            value = [object accessibilityValue];
        }
        if ([object respondsToSelector:@selector(accessibilityFrame)]) {
            frame = [object accessibilityFrame];
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    CGRect windowFrame = CGRectIsNull(frame) ? CGRectNull : [window convertRect:frame fromWindow:nil];
    if (CGBRectIsInNavigationArea(windowFrame, window) &&
        (CGBTryPersistText(label) || CGBTryPersistText(value))) {
        return YES;
    }

    NSArray *elements = nil;
    @try {
        if ([object respondsToSelector:@selector(accessibilityElements)]) {
            elements = [object accessibilityElements];
        }
    } @catch (__unused NSException *exception) {
        elements = nil;
    }
    for (id element in elements ?: @[]) {
        if (element != object && CGBScanAccessibleObject(element, window, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static BOOL CGBScanViewForSelectedModel(UIView *view, UIWindow *window) {
    if (!view || view.hidden || view.alpha < 0.01) {
        return NO;
    }
    CGRect rect = [view convertRect:view.bounds toView:window];
    if (CGBRectIsInNavigationArea(rect, window)) {
        NSString *text = nil;
        if ([view isKindOfClass:UILabel.class]) {
            text = ((UILabel *)view).text;
        } else if ([view isKindOfClass:UIButton.class]) {
            text = [(UIButton *)view currentTitle];
        }
        if (CGBTryPersistText(text) ||
            CGBTryPersistText(view.accessibilityLabel) ||
            CGBTryPersistText(view.accessibilityValue)) {
            return YES;
        }
    }
    for (UIView *subview in view.subviews) {
        if (CGBScanViewForSelectedModel(subview, window)) {
            return YES;
        }
    }
    return CGBScanAccessibleObject(view, window, 0);
}

static BOOL CGBPersistSelectedModelFromNavigationArea(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSArray<UIWindow *> *windows = application.windows;
    for (UIWindow *window in [windows reverseObjectEnumerator]) {
        if (window.hidden || window.alpha < 0.01 || !window.rootViewController) {
            continue;
        }
        if (CGBScanViewForSelectedModel(window, window)) {
            return YES;
        }
    }
    return NO;
}

static void CGBScheduleModelSelectionCaptureAttempt(NSUInteger generation,
                                                     NSUInteger attempt) {
    static const NSTimeInterval delays[] = { 0.0, 0.06, 0.18, 0.45 };
    if (attempt >= sizeof(delays) / sizeof(delays[0])) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delays[attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != CGBModelSelectionCaptureGeneration) {
            return;
        }
        // SwiftUI can publish the new selection before it redraws the title.
        // Keep the bounded follow-up attempts even after an early match so an
        // old title observed during the transition cannot win persistence.
        CGBPersistSelectedModelFromNavigationArea();
        CGBScheduleModelSelectionCaptureAttempt(generation, attempt + 1);
    });
}

__attribute__((used, noinline)) static void CGBModelContextSelectionDidChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger generation = ++CGBModelSelectionCaptureGeneration;
        CGBScheduleModelSelectionCaptureAttempt(generation, 0);
    });
}

#if defined(__arm64__)
// ModelContext.select returns Void. Call the original first so SwiftUI's
// published selection and navigation title are current, then schedule a
// read-only capture while preserving the Swift caller's return registers.
__attribute__((naked)) static void CGBModelContextSelectHook(void) {
    __asm__ volatile(
        "sub sp, sp, #96\n"
        "str x30, [sp, #72]\n"
        "adrp x9, _CGBOriginalModelContextSelect@PAGE\n"
        "ldr x9, [x9, _CGBOriginalModelContextSelect@PAGEOFF]\n"
        "blr x9\n"
        "stp x0, x1, [sp, #0]\n"
        "stp x2, x3, [sp, #16]\n"
        "stp x4, x5, [sp, #32]\n"
        "stp x6, x7, [sp, #48]\n"
        "str x8, [sp, #64]\n"
        "bl _CGBModelContextSelectionDidChange\n"
        "ldp x0, x1, [sp, #0]\n"
        "ldp x2, x3, [sp, #16]\n"
        "ldp x4, x5, [sp, #32]\n"
        "ldp x6, x7, [sp, #48]\n"
        "ldr x8, [sp, #64]\n"
        "ldr x30, [sp, #72]\n"
        "add sp, sp, #96\n"
        "ret\n"
    );
}
#endif

static void *CGBResolveModelContextSelect(void) {
    static const uint32_t expected[] = {
        0xa9ba6ffcU, 0xa90167faU, 0xa9025ff8U, 0xa90357f6U,
        0xa9044ff4U, 0xa9057bfdU, 0x910143fdU, 0xd12b03ffU,
        0x910d43e1U, 0xf90137e0U,
    };
    return CGBResolveChatGPTTextAddress(0x002337fcU, expected,
                                        sizeof(expected) / sizeof(expected[0]));
}

void CGBInstallLegacyModelSelectionPersistenceBridge(void) {
#if defined(__arm64__)
    if (CGBModelSelectionPersistenceInstalled) {
        return;
    }
    void *target = CGBResolveModelContextSelect();
    if (target) {
        MSHookFunction(target,
                       (void *)&CGBModelContextSelectHook,
                       &CGBOriginalModelContextSelect);
        CGBModelSelectionPersistenceInstalled =
            CGBOriginalModelContextSelect != NULL;
    }
    NSLog(CGBModelSelectionPersistenceInstalled ?
        @"[ChatGBeFree] model picker persistence bridge installed" :
        @"[ChatGBeFree] model picker persistence bridge unavailable");
#endif
}
