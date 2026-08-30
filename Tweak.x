#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <version.h>
#import <rootless.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#define SettingsPath @"/var/mobile/Library/Preferences/tw.hiraku.datalogoswitcher.plist"
#define DLSPreferencesID CFSTR("tw.hiraku.datalogoswitcher")

static NSDictionary *DLSSettings(void)
{
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:SettingsPath];
    return settings ?: @{};
}

static NSString *DLSRewriteStatusText(NSString *text)
{
    if (![text isKindOfClass:NSString.class] || text.length == 0) return nil;
    NSDictionary *settings = DLSSettings();

    NSSet *fiveG = [NSSet setWithObjects:@"5G", @"5G+", @"5G Plus", @"5G UC", @"5G UW", @"5G UWB", @"5GE", @"5GA", @"5G-A", @"5G A", nil];
    if ([fiveG containsObject:text]) {
        NSInteger value = [settings[@"5G"] integerValue];
        NSString *custom = settings[@"custom5GString"];
        if (value == 5) return @"5Gᴀ";
        if (value == 99 && custom.length > 0 && ![custom isEqualToString:text]) return custom;
    }

    NSSet *fourG = [NSSet setWithObjects:@"4G", @"4G+", @"LTE", @"LTE+", @"LTE-A", @"5GE", nil];
    if ([fourG containsObject:text] && [settings[@"4G"] integerValue] == 10) {
        return @"4GA";
    }
    if ([fourG containsObject:text] && [settings[@"4G"] integerValue] == 99 && [settings[@"custom4GString"] length] > 0) {
        return settings[@"custom4GString"];
    }

    NSSet *threeG = [NSSet setWithObjects:@"3G", @"H", @"H+", nil];
    if ([threeG containsObject:text] && [settings[@"3G"] integerValue] == 99 && [settings[@"custom3GString"] length] > 0) {
        return settings[@"custom3GString"];
    }
    return nil;
}

static __thread BOOL DLSApplyingText;

static NSDictionary *DLSCompactSuffixAttributes(NSDictionary *baseAttributes)
{
    NSMutableDictionary *attributes = [baseAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
    UIFont *font = attributes[NSFontAttributeName];
    if (font != nil) {
        // The native 5G+ suffix is materially smaller than the 5G body.
        // Use the same family/weight, with compact metrics for A/custom suffixes.
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

    // 4G+ must remain vertically centered. Do not apply the compact 5G suffix style.
    BOOL compact5GSuffix = [replacement hasPrefix:@"5G"] || [replacement hasPrefix:@"4GA"];
    if (!compact5GSuffix) {
        [updated setAttributes:prefixAttributes range:NSMakeRange(0, replacement.length)];
        return updated;
    }

    NSUInteger prefixLength = MIN((NSUInteger)replacement.length, (NSUInteger)2);
    [updated setAttributes:prefixAttributes range:NSMakeRange(0, prefixLength)];

    // 5G A/custom text is deliberately mapped to NewConnection5GPlus.
    // Its third glyph (+) is the authoritative native compact suffix style.
    NSDictionary *suffixAttributes = nil;
    if (compact5GSuffix && source.length > 2) {
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

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:replacement attributes:prefix];
    NSMutableDictionary *suffix = [prefix mutableCopy];
    if (replacement.length > 2 && ([replacement hasPrefix:@"5G"] || [replacement hasPrefix:@"4GA"]) && font != nil) {
        UIFont *suffixFont = [UIFont fontWithDescriptor:font.fontDescriptor
                                                    size:MAX(1.0, font.pointSize * 0.58)];
        suffix[NSFontAttributeName] = suffixFont;
        [result setAttributes:suffix range:NSMakeRange(2, replacement.length - 2)];
    }
    return result;
}

static BOOL DLSIsStatusBarObject(id object)
{
    id current = object;
    for (NSUInteger depth = 0; current != nil && depth < 10; depth++) {
        NSString *name = NSStringFromClass(object_getClass(current));
        if ([name rangeOfString:@"StatusBar" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"STUI" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"Cellular" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
        current = [current respondsToSelector:@selector(superview)] ? [current superview] : nil;
    }
    return NO;
}

// iOS 17 moved the visible carrier text into SystemStatusUI.
%group GiOS17
%hook STUIStatusBarStringView
- (void)setText:(NSString *)text {
    NSString *replacement = DLSRewriteStatusText(text);
    id currentAttributed = nil;
    if (!DLSApplyingText) {
        currentAttributed = ((id (*)(id, SEL))objc_msgSend)(self, @selector(attributedText));
    }
    if (replacement.length > 0 && [currentAttributed isKindOfClass:NSAttributedString.class] && [(NSAttributedString *)currentAttributed length] > 0 && !DLSApplyingText) {
        DLSApplyingText = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setAttributedText:), DLSAttributedReplacement(currentAttributed, replacement));
        DLSApplyingText = NO;
        return;
    }
    if (replacement.length > 0 && !DLSApplyingText && ((BOOL (*)(id, SEL, SEL))objc_msgSend)(self, @selector(respondsToSelector:), @selector(setAttributedText:))) {
        DLSApplyingText = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setAttributedText:), DLSFallbackAttributedText(self, replacement));
        DLSApplyingText = NO;
        return;
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

// Some iOS 17 builds use a UILabel subclass for the final rendered text.
%hook UILabel
- (void)setText:(NSString *)text {
    if (DLSIsStatusBarObject(self)) {
        NSString *replacement = DLSRewriteStatusText(text);
        if (replacement.length > 0 && !DLSApplyingText && self.attributedText.length > 0) {
            DLSApplyingText = YES;
            [self setAttributedText:DLSAttributedReplacement(self.attributedText, replacement)];
            DLSApplyingText = NO;
            return;
        }
        if (replacement.length > 0 && !DLSApplyingText && [self respondsToSelector:@selector(setAttributedText:)]) {
            DLSApplyingText = YES;
            [self setAttributedText:DLSFallbackAttributedText(self, replacement)];
            DLSApplyingText = NO;
            return;
        }
    }
    %orig(text);
}
- (void)setAttributedText:(NSAttributedString *)text {
    if (DLSIsStatusBarObject(self)) {
        if (DLSApplyingText) {
            %orig(text);
            return;
        }
        NSString *replacement = DLSRewriteStatusText(text.string);
        if (replacement.length > 0) {
            %orig(DLSAttributedReplacement(text, replacement));
            return;
        }
    }
    %orig(text);
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
            case 10:
                return NewConnectionLtePlus;
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
                // Use the native 5G+ renderer as the host for the compact suffix.
                return NewConnection5GPlus;
            case 99:
                // Custom 5G text also needs the native compact-suffix style.
                return NewConnection5GPlus;
        }
    }

    return connectionType;
}
%end

%hook STTelephonyCarrierBundleInfo
- (BOOL)LTEConnectionShows4G {
    return NO;
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
        [defaults[@"4G"] intValue] == 10) {
        return @"4GA";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 99) {
        return defaults[@"custom4GString"] ? defaults[@"custom4GString"] : @"4G";
    }

    if ((connectionType == NewConnection5G ||
        connectionType == NewConnection5GPlus ||
        connectionType == NewConnection5GUWB ||
        (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0 && connectionType == NewConnection5GUC)) &&
        [defaults[@"5G"] intValue] == 5) {
        return @"5Gᴀ";
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
        [defaults[@"4G"] intValue] == 10) {
        return @"4GA";
    }

    if ((connectionType == NewConnection4GOverride ||
        connectionType == NewConnectionLte ||
        connectionType == NewConnectionLteA ||
        connectionType == NewConnectionLtePlus ||
        connectionType == NewConnection5GE) &&
        [defaults[@"4G"] intValue] == 99) {
        return defaults[@"custom4GString"] ? defaults[@"custom4GString"] : @"4G";
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
        %init(GiOS13);
        // Safe when absent on older systems; Logos skips an unavailable class.
        %init(GiOS17);
    }
}
