#pragma once

#include <stddef.h>
#include <stdint.h>

/// Returns an exact, signature-verified address inside the bundled ChatGPT
/// framework. No scanning or best-effort fallback is performed.
void *CGBResolveChatGPTTextAddress(uintptr_t unslidAddress,
                                   const uint32_t *expectedWords,
                                   size_t expectedWordCount);
