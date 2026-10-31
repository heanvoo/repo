// StretchClock — растягивает часы на экране блокировки.
// Режим 1 (по умолчанию): ищет UILabel с текстом вида "9:41" и растягивает его.
// Режим 2: если в настройках указан класс часов, хукается он напрямую.
// Режим отладки пишет найденные классы в /var/mobile/StretchClock.log

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDomain = @"com.stretchclock.tweak";

static BOOL gEnabled = YES;
static BOOL gDebug = NO;
static CGFloat gScaleX = 1.0;
static CGFloat gScaleY = 1.3;
static NSString *gClassName = nil;

static void loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id v;
    v = [d objectForKey:@"enabled"]; gEnabled = v ? [v boolValue] : YES;
    v = [d objectForKey:@"debug"];   gDebug   = v ? [v boolValue] : NO;
    v = [d objectForKey:@"scaleX"];  gScaleX  = v ? [v doubleValue] : 1.0;
    v = [d objectForKey:@"scaleY"];  gScaleY  = v ? [v doubleValue] : 1.3;
    v = [d objectForKey:@"className"];
    gClassName = ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

static void prefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    loadPrefs();
}

static BOOL looksLikeTime(NSString *s) {
    NSUInteger n = s.length;
    if (n < 3 || n > 8) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    BOOL sep = NO;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ':' || c == '.' || c == 0xFF1A) sep = YES;
        else if (![digits characterIsMember:c] && c != ' ') return NO;
    }
    return sep;
}

static void debugLog(UIView *v, NSString *why) {
    if (!gDebug) return;
    NSString *line = [NSString stringWithFormat:@"[%@] %@ <%@> superview chain: %@\n",
        NSProcessInfo.processInfo.processName, why, NSStringFromClass(v.class),
        ({ NSMutableArray *a = [NSMutableArray array]; UIView *p = v.superview;
           for (int i = 0; p && i < 6; i++, p = p.superview) [a addObject:NSStringFromClass(p.class)];
           [a componentsJoinedByString:@" > "]; })];
    NSLog(@"StretchClock: %@", line);
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/StretchClock.log"];
    if (!h) { [@"" writeToFile:@"/var/mobile/StretchClock.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
              h = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/StretchClock.log"]; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

static void applyStretch(UIView *v) {
    CGAffineTransform t = gEnabled ? CGAffineTransformMakeScale(gScaleX, gScaleY) : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(v.transform, t)) v.transform = t;
}

%hook UILabel
- (void)layoutSubviews {
    %orig;
    if (gClassName) return; // режим 2 активен
    NSString *t = self.text;
    if (t && looksLikeTime(t)) {
        debugLog(self, @"time label");
        applyStretch(self);
    }
}
%end

%group ClockHook
%hook ClockView
- (void)layoutSubviews {
    %orig;
    debugLog((UIView *)self, @"custom class");
    applyStretch((UIView *)self);
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.apple.springboard"] && ![bid isEqualToString:@"com.apple.PosterBoard"]) return;
        loadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            prefsChanged, CFSTR("com.stretchclock.tweak/reload"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        if (gClassName) {
            Class cls = objc_getClass(gClassName.UTF8String);
            if (cls && [cls isSubclassOfClass:[UIView class]]) { %init(ClockHook, ClockView = cls); }
        }
        %init;
    }
}
