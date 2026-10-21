#import <Foundation/Foundation.h>

#import "../CopyBridge/LegacyCopyBridge.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSString *dirty = @"Hello\u00A0world\uFFFC\u200B\u2060\uFEFF\u2028next\r\nline\rfinal";
        Require([CGBNormalizedCopiedText(dirty) isEqualToString:
                    @"Hello world\nnext\nline\nfinal"],
                @"removes renderer placeholders and normalizes line endings");
        Require([CGBNormalizedCopiedText(@"👨‍👩‍👧‍👦 café Ελληνικά `code`  ")
                    isEqualToString:@"👨‍👩‍👧‍👦 café Ελληνικά `code`  "],
                @"preserves emoji joiners, Unicode, code, and intentional spaces");
        Require([CGBNormalizedCopiedText(@"") isEqualToString:@""],
                @"handles an empty selection safely");
        NSLog(@"PASS: ChatGBeFree copy bridge tests");
    }
    return 0;
}
