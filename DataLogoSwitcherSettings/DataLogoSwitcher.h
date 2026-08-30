#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSListController.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <CoreFoundation/CoreFoundation.h>
#import <rootless.h>

#define UserDefaultsChangedNotification "tw.hiraku.datalogoswitcher"
#define SettingsPath @"/var/mobile/Library/Preferences/tw.hiraku.datalogoswitcher.plist"
#define DLSPreferencesID CFSTR("tw.hiraku.datalogoswitcher")

@interface PSSpecifier (DataLogoSwitcher)
@property (nonatomic, retain) NSArray *values;
- (void)setIdentifier:(NSString *)identifier;
@end

@interface PSListController (DataLogoSwitcher)
- (void)loadView;
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath;
@end


@interface PSTableCell (DataLogoSwitcher)
@property(readonly, assign, nonatomic) UILabel* textLabel;
@end

//====================================================================================================================

id getUserDefaultForKey(NSString *key) {
    NSDictionary *defaults = [NSDictionary dictionaryWithContentsOfFile:SettingsPath];
    return defaults[key];
}

void setUserDefaultForKey(NSString *key, id value) {
    NSMutableDictionary *defaults = [NSMutableDictionary dictionaryWithContentsOfFile:SettingsPath];
    if (defaults == nil) defaults = [NSMutableDictionary dictionary];

    if (value != nil) {
        defaults[key] = value;
    } else {
        [defaults removeObjectForKey:key];
    }

    // The plist is authoritative; synchronize CFPreferences only as a notification/cache bridge.
    [defaults writeToFile:SettingsPath atomically:YES];
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             value == nil ? NULL : (__bridge CFPropertyListRef)value,
                             DLSPreferencesID);
    CFPreferencesAppSynchronize(DLSPreferencesID);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFSTR(UserDefaultsChangedNotification),
                                          NULL, NULL, TRUE);
}
