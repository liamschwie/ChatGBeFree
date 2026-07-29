#import <Foundation/Foundation.h>

// Spoof the app version dynamically to match the working TrollStore IPA
%hook NSBundle
- (NSDictionary *)infoDictionary {
    NSDictionary *dict = %orig;
    
    // Read the bundle ID directly from the dictionary to prevent infinite recursion
    NSString *bundleID = [dict objectForKey:@"CFBundleIdentifier"];
    if ([bundleID isEqualToString:@"com.openai.chat"]) {
        NSMutableDictionary *modDict = [dict mutableCopy];
        modDict[@"CFBundleShortVersionString"] = @"1.2099.999";
        modDict[@"CFBundleVersion"] = @"99999999999";
        return modDict;
    }
    return dict;
}
%end

%ctor {
    NSLog(@"[ChatGBeFree] Loaded successfully");
}
