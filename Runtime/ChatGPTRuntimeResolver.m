#import "ChatGPTRuntimeResolver.h"

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

#include <string.h>

static BOOL CGBIsChatGPTFrameworkImage(const char *imageName) {
    if (!imageName) {
        return NO;
    }
    static const char suffix[] = "/Frameworks/ChatGPT.framework/ChatGPT";
    size_t imageLength = strlen(imageName);
    size_t suffixLength = sizeof(suffix) - 1;
    return imageLength >= suffixLength &&
           strcmp(imageName + imageLength - suffixLength, suffix) == 0;
}

static const struct section_64 *CGBTextSection(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) {
        return NULL;
    }
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) {
            return NULL;
        }
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) {
                const struct section_64 *section =
                    (const struct section_64 *)(segment + 1);
                for (uint32_t sectionIndex = 0; sectionIndex < segment->nsects;
                     sectionIndex++, section++) {
                    if (strncmp(section->sectname, SECT_TEXT,
                                sizeof(section->sectname)) == 0) {
                        return section;
                    }
                }
            }
        }
        cursor += command->cmdsize;
    }
    return NULL;
}

void *CGBResolveChatGPTTextAddress(uintptr_t unslidAddress,
                                   const uint32_t *expectedWords,
                                   size_t expectedWordCount) {
    if (!expectedWords || expectedWordCount == 0 ||
        expectedWordCount > SIZE_MAX / sizeof(uint32_t)) {
        return NULL;
    }
    size_t expectedSize = expectedWordCount * sizeof(uint32_t);
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        if (!CGBIsChatGPTFrameworkImage(_dyld_get_image_name(index))) {
            continue;
        }
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(index);
        const struct section_64 *textSection = CGBTextSection(header);
        if (!textSection) {
            return NULL;
        }
        intptr_t slide = _dyld_get_image_vmaddr_slide(index);
        const uint8_t *textStart =
            (const uint8_t *)((uintptr_t)slide + (uintptr_t)textSection->addr);
        size_t textSize = (size_t)textSection->size;
        const uint8_t *target =
            (const uint8_t *)((uintptr_t)slide + unslidAddress);
        if (target < textStart) {
            return NULL;
        }
        size_t offset = (size_t)(target - textStart);
        if (offset > textSize || expectedSize > textSize - offset ||
            memcmp(target, expectedWords, expectedSize) != 0) {
            return NULL;
        }
        return (void *)target;
    }
    return NULL;
}
