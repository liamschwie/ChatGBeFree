#import <Foundation/Foundation.h>

// Method 1: Network Interception
// Intercepts the server response and rewrites "hard_deprecation" to "supported"
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    
    NSString *url = request.URL.absoluteString;
    
    if ([url containsString:@"openai.com"] || [url containsString:@"chatgpt.com"]) {
        void (^originalHandler)(NSData *, NSURLResponse *, NSError *) = [completionHandler copy];
        
        void (^modifiedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data) {
                NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                
                if (body && ([body containsString:@"hard_deprecation"] || [body containsString:@"soft_deprecation"])) {
                    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\"status\"\\s*:\\s*\"(hard|soft)_deprecation\"" 
                                                                                          options:0 
                                                                                            error:nil];
                    NSString *modified = [regex stringByReplacingMatchesInString:body 
                                                                         options:0 
                                                                           range:NSMakeRange(0, body.length) 
                                                                    withTemplate:@"\"status\":\"supported\""];
                    
                    NSData *modifiedData = [modified dataUsingEncoding:NSUTF8StringEncoding];
                    if (modifiedData) {
                        NSLog(@"[ChatGBeFree] Spoofed sunset response to 'supported'");
                        originalHandler(modifiedData, response, error);
                        return;
                    }
                }
            }
            originalHandler(data, response, error);
        };
        
        return %orig(request, modifiedHandler);
    }
    
    return %orig;
}
%end

// Method 2: Version Spoofing
// Tricks the app into reporting a future version to the server
%hook NSBundle
- (NSDictionary *)infoDictionary {
    NSDictionary *dict = %orig;
    if ([self.bundleIdentifier isEqualToString:@"com.openai.chat"]) {
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
