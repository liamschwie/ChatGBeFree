#import "LegacyNativeVoiceLifecycle.h"
#import "LegacyRealtimeVoice.h"
#import "../Runtime/ChatGPTRuntimeResolver.h"

#import <substrate.h>

#include <dlfcn.h>
#include <stdlib.h>

// The supported legacy app presents Voice through
// VoiceViewPresentationModifier<A>. Its first field is Binding<A?>. Capturing
// that binding before the modifier commits its overlay gives the replacement
// UI first-frame coverage; assigning nil later is the exact SwiftUI teardown.
static BOOL LVBVoicePresentationBindingBridgeInstalled;
__attribute__((used)) static void *LVBOriginalVoicePresentationModifierBody;

typedef struct {
    void *initializeBufferWithCopyOfBuffer;
    void (*destroy)(void *value, const void *metadata);
    void *(*initializeWithCopy)(void *destination,
                                const void *source,
                                const void *metadata);
    void *assignWithCopy;
    void *initializeWithTake;
    void *assignWithTake;
    unsigned (*getEnumTagSinglePayload)(const void *value,
                                        unsigned emptyCases,
                                        const void *metadata);
    void (*storeEnumTagSinglePayload)(void *value,
                                      unsigned whichCase,
                                      unsigned emptyCases,
                                      const void *metadata);
    uintptr_t size;
    uintptr_t stride;
    uint32_t flags;
    uint32_t extraInhabitantCount;
} LVBValueWitnessTable;

static void *LVBCapturedVoicePresentationBinding;
static const void *LVBCapturedVoicePresentationBindingMetadata;
static const void *LVBCapturedVoicePresentationItemMetadata;
static const void *LVBCapturedVoicePresentationOptionalMetadata;

static const LVBValueWitnessTable *LVBValueWitnesses(const void *metadata) {
    return metadata ? *((const LVBValueWitnessTable *const *)metadata - 1) : NULL;
}

#if defined(__arm64__)
// SwiftUI.Binding accessors carry the Binding value in x20. The getter also
// returns its generic value indirectly through x8.
__attribute__((naked)) static void LVBCallBindingGetter(void *result,
                                                        void *binding,
                                                        const void *bindingMetadata,
                                                        void *getter) {
    __asm__ volatile(
        "stp x20, x30, [sp, #-16]!\n"
        "mov x8, x0\n"
        "mov x20, x1\n"
        "mov x0, x2\n"
        "blr x3\n"
        "ldp x20, x30, [sp], #16\n"
        "ret\n"
    );
}

__attribute__((naked)) static void LVBCallBindingSetter(void *value,
                                                        void *binding,
                                                        const void *bindingMetadata,
                                                        void *setter) {
    __asm__ volatile(
        "stp x20, x30, [sp, #-16]!\n"
        "mov x20, x1\n"
        "mov x1, x2\n"
        "blr x3\n"
        "ldp x20, x30, [sp], #16\n"
        "ret\n"
    );
}
#endif

static void LVBDestroyCapturedVoicePresentationBinding(void) {
    if (!LVBCapturedVoicePresentationBinding ||
        !LVBCapturedVoicePresentationBindingMetadata) {
        return;
    }
    const LVBValueWitnessTable *witnesses =
        LVBValueWitnesses(LVBCapturedVoicePresentationBindingMetadata);
    if (witnesses && witnesses->destroy) {
        witnesses->destroy(LVBCapturedVoicePresentationBinding,
                           LVBCapturedVoicePresentationBindingMetadata);
    }
    free(LVBCapturedVoicePresentationBinding);
    LVBCapturedVoicePresentationBinding = NULL;
    LVBCapturedVoicePresentationBindingMetadata = NULL;
    LVBCapturedVoicePresentationItemMetadata = NULL;
    LVBCapturedVoicePresentationOptionalMetadata = NULL;
}

static BOOL LVBCapturePresentedVoiceBinding(void *binding,
                                             const void *genericContext) {
#if defined(__arm64__)
    if (!binding || !genericContext || !NSThread.isMainThread) {
        return NO;
    }

    // The modifier body itself loads A's metadata from [genericContext+0x10].
    const void *itemMetadata = *((const void *const *)genericContext + 2);
    if (!itemMetadata) {
        return NO;
    }

    typedef void *(*MetadataAccessor)(uintptr_t request, const void *argument);
    MetadataAccessor optionalAccessor =
        (MetadataAccessor)dlsym(RTLD_DEFAULT, "$sSqMa");
    MetadataAccessor bindingAccessor =
        (MetadataAccessor)dlsym(RTLD_DEFAULT, "$s7SwiftUI7BindingVMa");
    void *getter = dlsym(RTLD_DEFAULT,
                         "$s7SwiftUI7BindingV12wrappedValuexvg");
    if (!optionalAccessor || !bindingAccessor || !getter) {
        return NO;
    }

    const void *optionalMetadata = optionalAccessor(0, itemMetadata);
    const void *bindingMetadata = optionalMetadata ?
        bindingAccessor(0, optionalMetadata) : NULL;
    const LVBValueWitnessTable *itemWitnesses = LVBValueWitnesses(itemMetadata);
    const LVBValueWitnessTable *optionalWitnesses =
        LVBValueWitnesses(optionalMetadata);
    const LVBValueWitnessTable *bindingWitnesses =
        LVBValueWitnesses(bindingMetadata);
    if (!itemWitnesses || !optionalWitnesses || !bindingWitnesses ||
        !itemWitnesses->getEnumTagSinglePayload ||
        !bindingWitnesses->initializeWithCopy ||
        optionalWitnesses->size == 0 || bindingWitnesses->size == 0) {
        return NO;
    }

    void *currentValue = calloc(1, MAX((uintptr_t)1, optionalWitnesses->size));
    if (!currentValue) {
        return NO;
    }
    LVBCallBindingGetter(currentValue, binding, bindingMetadata, getter);
    unsigned tag = itemWitnesses->getEnumTagSinglePayload(currentValue, 1,
                                                           itemMetadata);
    if (optionalWitnesses->destroy) {
        optionalWitnesses->destroy(currentValue, optionalMetadata);
    }
    free(currentValue);
    if (tag != 0) {
        return NO;
    }

    void *bindingCopy = calloc(1, MAX((uintptr_t)1, bindingWitnesses->size));
    if (!bindingCopy) {
        return NO;
    }
    bindingWitnesses->initializeWithCopy(bindingCopy, binding, bindingMetadata);
    LVBDestroyCapturedVoicePresentationBinding();
    LVBCapturedVoicePresentationBinding = bindingCopy;
    LVBCapturedVoicePresentationBindingMetadata = bindingMetadata;
    LVBCapturedVoicePresentationItemMetadata = itemMetadata;
    LVBCapturedVoicePresentationOptionalMetadata = optionalMetadata;
    return YES;
#else
    return NO;
#endif
}

static BOOL LVBSetCapturedVoicePresentationNil(void) {
#if defined(__arm64__)
    if (!NSThread.isMainThread || !LVBCapturedVoicePresentationBinding ||
        !LVBCapturedVoicePresentationBindingMetadata ||
        !LVBCapturedVoicePresentationItemMetadata ||
        !LVBCapturedVoicePresentationOptionalMetadata) {
        return NO;
    }

    void *setter = dlsym(RTLD_DEFAULT,
                         "$s7SwiftUI7BindingV12wrappedValuexvs");
    const LVBValueWitnessTable *itemWitnesses =
        LVBValueWitnesses(LVBCapturedVoicePresentationItemMetadata);
    const LVBValueWitnessTable *optionalWitnesses =
        LVBValueWitnesses(LVBCapturedVoicePresentationOptionalMetadata);
    if (!setter || !itemWitnesses || !optionalWitnesses ||
        !itemWitnesses->storeEnumTagSinglePayload ||
        optionalWitnesses->size == 0) {
        return NO;
    }

    void *noneValue = calloc(1, MAX((uintptr_t)1, optionalWitnesses->size));
    if (!noneValue) {
        return NO;
    }
    itemWitnesses->storeEnumTagSinglePayload(
        noneValue, 1, 1, LVBCapturedVoicePresentationItemMetadata);
    LVBCallBindingSetter(noneValue, LVBCapturedVoicePresentationBinding,
                         LVBCapturedVoicePresentationBindingMetadata, setter);
    free(noneValue);
    LVBRealtimeVoiceLog(@"legacy Voice presentation binding set to nil");
    return YES;
#else
    return NO;
#endif
}

__attribute__((used, noinline)) static void
LVBVoicePresentationModifierBodyCaptured(void *binding,
                                          const void *genericContext) {
    if (!LVBCapturePresentedVoiceBinding(binding, genericContext)) {
        return;
    }
    LVBRealtimeVoicePrepareForLegacyStart();
    LVBRealtimeVoiceLog(
        @"legacy Voice presentation binding captured before SwiftUI overlay commit");
}

#if defined(__arm64__)
__attribute__((naked)) static void LVBVoicePresentationModifierBodyHook(void) {
    __asm__ volatile(
        "sub sp, sp, #96\n"
        "stp x0, x1, [sp, #0]\n"
        "stp x2, x3, [sp, #16]\n"
        "stp x4, x5, [sp, #32]\n"
        "stp x6, x7, [sp, #48]\n"
        "str x8, [sp, #64]\n"
        "str x30, [sp, #72]\n"
        "mov x0, x20\n"
        "ldr x1, [sp, #8]\n"
        "bl _LVBVoicePresentationModifierBodyCaptured\n"
        "ldp x0, x1, [sp, #0]\n"
        "ldp x2, x3, [sp, #16]\n"
        "ldp x4, x5, [sp, #32]\n"
        "ldp x6, x7, [sp, #48]\n"
        "ldr x8, [sp, #64]\n"
        "ldr x30, [sp, #72]\n"
        "add sp, sp, #96\n"
        "adrp x9, _LVBOriginalVoicePresentationModifierBody@PAGE\n"
        "ldr x9, [x9, _LVBOriginalVoicePresentationModifierBody@PAGEOFF]\n"
        "br x9\n"
    );
}
#endif

static void *LVBResolveVoicePresentationModifierBody(void) {
    // Full unique signature for VoiceViewPresentationModifier.body in the
    // supported legacy ChatGPT framework.
    static const uint32_t expected[] = {
        0xa9ba6ffcU, 0xa90167faU, 0xa9025ff8U, 0xa90357f6U,
        0xa9044ff4U, 0xa9057bfdU, 0x910143fdU, 0xd10303ffU,
        0xaa0103f3U, 0xf81083a0U, 0xf81583a8U, 0xf9400836U,
        0xd2800000U, 0xaa1603e1U,
    };
    return CGBResolveChatGPTTextAddress(0x007a3638U, expected,
                                        sizeof(expected) / sizeof(expected[0]));
}

void LVBInstallLegacyNativeVoiceLifecycleBridge(void) {
#if defined(__arm64__)
    if (LVBVoicePresentationBindingBridgeInstalled) {
        return;
    }
    void *body = LVBResolveVoicePresentationModifierBody();
    if (body) {
        MSHookFunction(body,
                       (void *)&LVBVoicePresentationModifierBodyHook,
                       &LVBOriginalVoicePresentationModifierBody);
        LVBVoicePresentationBindingBridgeInstalled =
            LVBOriginalVoicePresentationModifierBody != NULL;
    }
    LVBRealtimeVoiceLog(LVBVoicePresentationBindingBridgeInstalled ?
        @"legacy Voice SwiftUI presentation-binding bridge installed" :
        @"legacy Voice SwiftUI presentation-binding bridge unavailable");
#else
    LVBRealtimeVoiceLog(
        @"legacy Voice SwiftUI presentation-binding bridge unavailable: unsupported architecture");
#endif
}

BOOL LVBDismissUnderlyingLegacyVoiceMode(void) {
#if defined(__arm64__)
    if (!NSThread.isMainThread) {
        LVBRealtimeVoiceLog(@"legacy Voice binding dismissal skipped off main thread");
        return NO;
    }
    return LVBSetCapturedVoicePresentationNil();
#else
    return NO;
#endif
}
