#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <version.h>
#import <rootless.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#define SettingsPath @"/var/mobile/Library/Preferences/tw.hiraku.datalogoswitcher.plist"
#define DLSPreferencesID CFSTR("tw.hiraku.datalogoswitcher")

static NSDictionary *DLSSettings(void)
{
    // Status-bar setters can be called hundreds of times during Wi-Fi and
    // radio transitions. Settings take effect after respring, so loading once
    // per process is correct and avoids synchronous plist I/O on that path.
    static NSDictionary *settings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        settings = [[NSDictionary alloc] initWithContentsOfFile:SettingsPath] ?: @{};
    });
    return settings;
}

static NSString *DLSRewriteStatusText(NSString *text)
{
    if (![text isKindOfClass:NSString.class] || text.length == 0) return nil;
    static NSSet<NSString *> *fiveG = nil;
    static NSSet<NSString *> *fourG = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fiveG = [NSSet setWithObjects:@"5G", @"5G+", @"5G Plus", @"5G UC", @"5G UW", @"5G UWB", @"5GE", @"5GA", @"5G-A", @"5G A", nil];
        fourG = [NSSet setWithObjects:@"4G", @"LTE", @"LTE+", @"LTE-A", nil];
    });
    NSDictionary *settings = DLSSettings();

    if ([fiveG containsObject:text]) {
        NSInteger value = [settings[@"5G"] integerValue];
        NSString *custom = settings[@"custom5GString"];
        if (value == 5) return @"5Gᴀ";
        if (value == 99 && custom.length > 0 && ![custom isEqualToString:text]) return custom;
    }

    // 4.0.19: 4G+ remains entirely native through the LTE+ connection
    // host. Only 4Gᴀ and custom 4G enter the text replacement path.
    if ([fourG containsObject:text]) {
        NSInteger value = [settings[@"4G"] integerValue];
        if (value == 10) return @"4Gᴀ";
        if (value == 99 && [settings[@"custom4GString"] length] > 0) {
            return settings[@"custom4GString"];
        }
    }
    return nil;
}

static BOOL DLSUsesSystemStatusUI(void)
{
    return NSClassFromString(@"STUIStatusBarStringView") != nil;
}

static __thread BOOL DLSApplyingText;

static NSDictionary *DLSCompactSuffixAttributes(NSDictionary *baseAttributes)
{
    NSMutableDictionary *attributes = [baseAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
    UIFont *font = attributes[NSFontAttributeName];
    if (font != nil) {
        // Exact 4.0.19 behavior: preserve the native family/weight and
        // reproduce the compact suffix metrics from the host font.
        attributes[NSFontAttributeName] = [UIFont fontWithDescriptor:font.fontDescriptor
                                                                  size:MAX(1.0, font.pointSize * 0.58)];
    }
    [attributes removeObjectForKey:NSBaselineOffsetAttributeName];
    return attributes;
}

static NSAttributedString *DLSAttributedReplacement(NSAttributedString *source, NSString *replacement)
{
    if (replacement.length == 0) return source;

    NSMutableAttributedString *updated = [[NSMutableAttributedString alloc] initWithString:replacement];
    if (source.length == 0) return updated;

    NSRange prefixRange = NSMakeRange(0, 0);
    NSDictionary *prefixAttributes = [source attributesAtIndex:0 effectiveRange:&prefixRange] ?: @{};

    // 4.0.19 uses the native 5G+ run as the authoritative style. The
    // original third-character attributes contain the real compact font,
    // kern and baseline behavior; do not substitute a named system font.
    BOOL compact5GSuffix = [replacement hasPrefix:@"5G"];
    // 5G path is intentionally unchanged and remains locked.
    if (compact5GSuffix) {
        NSUInteger prefixLength = MIN((NSUInteger)replacement.length, (NSUInteger)2);
        [updated setAttributes:prefixAttributes range:NSMakeRange(0, prefixLength)];

        NSDictionary *suffixAttributes = nil;
        if (source.length > 2) {
            suffixAttributes = [source attributesAtIndex:2 effectiveRange:NULL];
        }
        if (suffixAttributes == nil) {
            suffixAttributes = DLSCompactSuffixAttributes(prefixAttributes);
        }
        if (replacement.length > prefixLength) {
            [updated setAttributes:suffixAttributes
                             range:NSMakeRange(prefixLength, replacement.length - prefixLength)];
        }
        return updated;
    }

    // 4.0.19: non-5G text is passed through with its native attributes.
    // This preserves the working native 4G+ renderer and custom 4G body.
    if (!compact5GSuffix) {
        [updated setAttributes:prefixAttributes range:NSMakeRange(0, replacement.length)];
        return updated;
    }

    NSUInteger prefixLength = MIN((NSUInteger)replacement.length, (NSUInteger)2);
    [updated setAttributes:prefixAttributes range:NSMakeRange(0, prefixLength)];

    NSDictionary *suffixAttributes = nil;
    if (source.length > 2) {
        suffixAttributes = [source attributesAtIndex:2 effectiveRange:NULL];
    }
    if (suffixAttributes == nil) {
        suffixAttributes = DLSCompactSuffixAttributes(prefixAttributes);
    }
    if (replacement.length > prefixLength) {
        [updated setAttributes:suffixAttributes
                         range:NSMakeRange(prefixLength, replacement.length - prefixLength)];
    }
    return updated;
}

static NSAttributedString *DLSFallbackAttributedText(id object, NSString *replacement)
{
    UIFont *font = nil;
    if ([object respondsToSelector:@selector(font)]) {
        font = ((id (*)(id, SEL))objc_msgSend)(object, @selector(font));
    }
    UIColor *color = nil;
    if ([object respondsToSelector:@selector(textColor)]) {
        color = ((id (*)(id, SEL))objc_msgSend)(object, @selector(textColor));
    }

    NSMutableDictionary *prefix = [NSMutableDictionary dictionary];
    if (font != nil) prefix[NSFontAttributeName] = font;
    if (color != nil) prefix[NSForegroundColorAttributeName] = color;

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:replacement
                                                                                 attributes:prefix];

    // Fallback is only used when SystemStatusUI has no attributed run yet.
    // 4.0.19 only applies the compact fallback to 5Gᴀ; 4G custom text
    // inherits the native 4G body attributes unchanged.
    NSMutableDictionary *suffix = [prefix mutableCopy];
    BOOL compactSuffix = [replacement isEqualToString:@"5Gᴀ"];
    if (compactSuffix && font != nil) {
        suffix[NSFontAttributeName] = [UIFont fontWithDescriptor:font.fontDescriptor
                                                             size:MAX(1.0, font.pointSize * 0.58)];
        [result setAttributes:suffix range:NSMakeRange(2, replacement.length - 2)];
    }
    return result;
}

// iOS 17 may send the final cellular label through setText: without a later
// attributed update. Use the 4.0.19 path: preserve the current native
// attributed run, then replace only the visible string with a recursion guard.
%group GiOS17
%hook STUIStatusBarStringView
- (void)setText:(NSString *)text {
    NSString *replacement = DLSRewriteStatusText(text);
    if (replacement.length > 0 && !DLSApplyingText) {
        id currentAttributed = ((id (*)(id, SEL))objc_msgSend)(self, @selector(attributedText));
        if ([currentAttributed isKindOfClass:NSAttributedString.class] && [(NSAttributedString *)currentAttributed length] > 0) {
            DLSApplyingText = YES;
            ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setAttributedText:), DLSAttributedReplacement(currentAttributed, replacement));
            DLSApplyingText = NO;
            return;
        }
        if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(self, @selector(respondsToSelector:), @selector(setAttributedText:))) {
            DLSApplyingText = YES;
            ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setAttributedText:), DLSFallbackAttributedText(self, replacement));
            DLSApplyingText = NO;
            return;
        }
    }
    %orig(replacement.length > 0 ? replacement : text);
}
- (void)setAttributedText:(NSAttributedString *)text {
    if (DLSApplyingText) {
        %orig(text);
        return;
    }
    NSString *replacement = DLSRewriteStatusText(text.string);
    %orig(replacement.length > 0 ? DLSAttributedReplacement(text, replacement) : text);
}
%end
%end

//Before iOS 12.2

//Before iOS 12.2
typedef NS_ENUM(NSInteger, connectionType) {
    ConnectionNone          = 0,
    Connection1x            = 1,
    ConnectionGprs          = 2,
    ConnectionEdge          = 3,
    ConnectionUmts          = 4,
    ConnectionHsdpa         = 5,
    Connection4GOverride    = 6,
    ConnectionLte           = 7,
    ConnectionBluetooth     = 8,
    ConnectionWifi          = 9,
    ConnectionOther         = 10
};

//After iOS 12.2
typedef NS_ENUM(NSInteger, newConnectionType) {
    NewConnectionNone       = 0,
    NewConnection1x         = 1,
    NewConnectionGprs       = 2,
    NewConnectionEdge       = 3,
    NewConnectionUmts       = 4,
    NewConnectionHsdpa      = 5,
    NewConnection4GOverride = 6,
    NewConnectionLte        = 7,
    NewConnectionLteA       = 8,
    NewConnectionLtePlus    = 9,
    NewConnection5GE        = 10,
    NewConnection5G         = 11,
    NewConnection5GPlus     = 12,
    NewConnection5GUWB      = 13,
    NewConnection5GUC       = 14,
    NewConnectionBluetooth  = 15,
    // NewConnectionBluetooth  = 11,
    // NewConnectionWifi       = 12,
    // NewConnectionOther      = 13
};

// //After iOS 14
// typedef NS_ENUM(NSInteger, newConnectionType) {
//     NewConnectionNone       = 0,
//     NewConnection1x         = 1,
//     NewConnectionGprs       = 2,
//     NewConnectionEdge       = 3,
//     NewConnectionUmts       = 4,
//     NewConnectionHsdpa      = 5,
//     NewConnection4GOverride = 6,
//     NewConnectionLte        = 7,
//     NewConnectionLteA       = 8,
//     NewConnectionLtePlus    = 9,
//     NewConnection5GE        = 10,
//     NewConnection5G         = 11,
//     NewConnection5GPlus     = 12,
//     NewConnection5GUWB      = 13,
//     NewConnectionBluetooth  = 14,
//     NewConnectionWifi       = 15,
//     NewConnectionOther      = 16
// };

%group GiOS13
%hook STTelephonySubscriptionContext
- (int)modemDataConnectionType
{
    int connectionType = %orig;

    NSDictionary *defaults = DLSSettings();
    if (connectionType == NewConnectionUmts ||
        connectionType == NewConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                return NewConnectionLtePlus;
            case 10:
                return NewConnectionLtePlus;
            case 5:
                return NewConnection5GE;
            case 6:
                return NewConnection5G;
            case 7:
                return NewConnection5GPlus;
            case 8:
                return NewConnection5GUWB;
            case 9:
                return NewConnection5GUC;
            default:
                break;
        }
    }

    if (connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                // Native LTE+ is the working 4G+ renderer.
                return NewConnectionLtePlus;
            case 10:
                // 4Gᴀ uses the same 4G host; only legacy text changes.
                return connectionType;
            case 99:
                // Custom 4G stays on the original 4G host.
                return connectionType;
            case 5:
                return NewConnection5GE;
            case 6:
                return NewConnection5G;
            case 7:
                return NewConnection5GPlus;
            case 8:
                return NewConnection5GUWB;
            case 9:
                return NewConnection5GUC;
            default:
                break;
        }
    }

    if (connectionType == NewConnection5G ||
        connectionType == NewConnection5GPlus ||
        connectionType == NewConnection5GUWB ||
        (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0 && connectionType == NewConnection5GUC))
    {
        switch([defaults[@"5G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection5G;
            case 2:
                return NewConnection5GPlus;
            case 3:
                return NewConnection5GUWB;
            case 4:
                return NewConnection5GUC;
            case 5:
                // 4.0.19: use native 5G+ as the host so SystemStatusUI
                // creates the compact suffix attributed run.
                return NewConnection5GPlus;
            case 99:
                // Custom 5G text uses the same native 5G+ host attributes.
                return NewConnection5GPlus;
        }
    }

    return connectionType;
}
%end

%hook STTelephonyCarrierBundleInfo
- (BOOL)LTEConnectionShows4G {
    // The user-facing default for LTE on this tweak is 4G, not LTE.
    return YES;
}
%end

%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSDictionary *defaults = DLSSettings();

    if ((connectionType == NewConnectionUmts || connectionType == NewConnectionHsdpa) &&
        [defaults[@"3G"] intValue] == 99) {
        return defaults[@"custom3GString"] ? defaults[@"custom3GString"] : @"3G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 99) {
        return defaults[@"custom4GString"] ? defaults[@"custom4GString"] : @"4G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 4) {
        if (!DLSUsesSystemStatusUI()) return @"4G+";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 10) {
        if (!DLSUsesSystemStatusUI()) return @"4Gᴀ";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 99) {
        if (!DLSUsesSystemStatusUI()) return defaults[@"custom4GString"] ?: @"4G";
    }

    if ((connectionType == NewConnection5G ||
        connectionType == NewConnection5GPlus ||
        connectionType == NewConnection5GUWB ||
        (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0 && connectionType == NewConnection5GUC)) &&
        [defaults[@"5G"] intValue] == 5) {
        if (!DLSUsesSystemStatusUI()) return @"5Gᴀ";
    }

    if ((connectionType == NewConnection5G ||
        connectionType == NewConnection5GPlus ||
        connectionType == NewConnection5GUWB ||
        (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0 && connectionType == NewConnection5GUC)) &&
        [defaults[@"5G"] intValue] == 99) {
        return defaults[@"custom5GString"] ? defaults[@"custom5GString"] : @"5G";
    }

    return %orig;
}
%end
%end

%group GiOS12_2
%hook SBTelephonySubscriptionContext
- (int)modemDataConnectionType
{
    int connectionType = %orig;

    NSDictionary *defaults = DLSSettings();
    if (connectionType == NewConnectionUmts || connectionType == NewConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                return NewConnectionLtePlus;
            case 10:
                return NewConnectionLtePlus;
            case 5:
                return NewConnection5GE;
            default:
                break;
        }
    }

    if (connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return NewConnection4GOverride;
            case 2:
                return NewConnectionLte;
            case 3:
                return NewConnectionLteA;
            case 4:
                return NewConnectionLtePlus;
            case 5:
                return NewConnection5GE;
            default:
                break;
        }
    }

    return connectionType;
}
%end

%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSDictionary *defaults = DLSSettings();

    if ((connectionType == NewConnectionUmts || connectionType == NewConnectionHsdpa) &&
        [defaults[@"3G"] intValue] == 99) {
        return defaults[@"custom3GString"] ? defaults[@"custom3GString"] : @"3G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 99) {
        return defaults[@"custom4GString"] ? defaults[@"custom4GString"] : @"4G";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 4) {
        return @"4G+";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 10) {
        return @"4Gᴀ";
    }

    return %orig;
}
%end
%end


%group GiOS12_1
%hook SBTelephonySubscriptionContext
- (int)modemDataConnectionType
{
    int connectionType = %orig;

    NSDictionary *defaults = DLSSettings();
    if (connectionType == ConnectionUmts || connectionType == ConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    if (connectionType == Connection4GOverride || connectionType == ConnectionLte)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    return connectionType;
}
%end
%end

%group GiOS12
%hook SBMutableTelephonyCarrierBundleInfo
- (BOOL)LTEConnectionShows4G
{
    return NO;
}
%end
%end

%group GiOS11
%hook SBTelephonyManager
- (int)dataConnectionType
{
    int connectionType = %orig;
    NSDictionary *defaults = DLSSettings();

    if (connectionType == ConnectionUmts || connectionType == ConnectionHsdpa)
    {
        switch([defaults[@"3G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    if (connectionType == Connection4GOverride || connectionType == ConnectionLte)
    {
        switch([defaults[@"4G"] intValue])
        {
            case 0:
                return connectionType;
            case 1:
                return Connection4GOverride;
            case 2:
                return ConnectionLte;
            default:
                break;
        }
    }

    return connectionType;
}
%end
%end

%ctor
{
    %init;

    if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_12_0)
    {
         %init(GiOS11);
    }
    else if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_12_0 && kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_13_0)
    {
        %init(GiOS12);

        if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iOS_12_2)
        {
            %init(GiOS12_1);
        }
        else
        {
            %init(GiOS12_2);
        }
    }
    else
    {
        // iOS 13+ preserves the actual cellular host. iOS 17 replaces the
        // final text safely in setText:/setAttributedText: without cross-calls.
        %init(GiOS13);
        %init(GiOS17);
    }
}
