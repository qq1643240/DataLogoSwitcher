#import "DataLogoSwitcher.h"
#import <version.h>
#import <errno.h>
#import <sys/wait.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

static BOOL run_command(const char *path, char *const argv[])
{
    if (access(path, X_OK) != 0) {
        return NO;
    }

    pid_t pid = 0;
    int status = 0;
    int result = posix_spawn(&pid, path, NULL, NULL, argv, NULL);
    if (result != 0) {
        return NO;
    }

    if (waitpid(pid, &status, 0) < 0) {
        return NO;
    }

    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

//============================================================================================================

@interface DLSSettingController: PSListController
@property(nonatomic, strong) UIActivityIndicatorView *dlsSpinner;
@property(nonatomic, assign) BOOL dlsRespringing;
- (void)respring;
@end

@implementation DLSSettingController
- (NSArray *)specifiers
{
	if(_specifiers == nil) {

        NSMutableArray *specifiers = [NSMutableArray array];

        [specifiers addObject:[PSSpecifier emptyGroupSpecifier]];
        PSSpecifier *logo4G = [PSSpecifier preferenceSpecifierNamed:@"4G 标识" target:self set:@selector(setValue:forSpecifier:) get:@selector(getValueForSpecifier:) detail:NSClassFromString(@"PSListItemsController") cell:[PSTableCell cellTypeFromString:@"PSLinkListCell"] edit:nil];
		[logo4G setIdentifier:@"4G"];

        if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0) {
            logo4G.values = @[@0,@1,@2,@3,@4,@10,@5,@6,@7,@8,@9,@99];
            logo4G.titleDictionary = [NSDictionary dictionaryWithObjects:@[
                @"默认",
                @"4G",
                @"LTE",
                @"LTE-A",
                @"4G+",
                @"4Gᴀ",
                @"5GE",
                @"5G",
                @"5G+",
                @"5G UWB",
                @"5G UC",
                @"自定义"
            ] forKeys:logo4G.values];
        }
        else if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_14_0) {
            logo4G.values = @[@0,@1,@2,@3,@4,@10,@5,@6,@7,@8,@99];
            logo4G.titleDictionary = [NSDictionary dictionaryWithObjects:@[
                @"默认",
                @"4G",
                @"LTE",
                @"LTE-A",
                @"4G+",
                @"4Gᴀ",
                @"5GE",
                @"5G",
                @"5G+",
                @"5G UWB",
                @"自定义"
            ] forKeys:logo4G.values];
        }
        else if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_12_2) {
            logo4G.values = @[@0,@1,@2,@3,@4,@10,@5,@99];
            logo4G.titleDictionary = [NSDictionary dictionaryWithObjects:@[
                @"默认",
                @"4G",
                @"LTE",
                @"LTE-A",
                @"4G+",
                @"4Gᴀ",
                @"5GE",
                @"自定义"
            ] forKeys:logo4G.values];
        }
        else {
            logo4G.values = @[@0,@1,@2];
            logo4G.titleDictionary = [NSDictionary dictionaryWithObjects:@[
                @"默认",
                @"4G",
                @"LTE"
            ] forKeys:logo4G.values];
        }
		[logo4G setProperty:@"kListValue" forKey:@"key"];
		[specifiers addObject:logo4G];

        if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_15_0) {
            PSSpecifier *logo5G = [PSSpecifier preferenceSpecifierNamed:@"5G 标识" target:self set:@selector(setValue:forSpecifier:) get:@selector(getValueForSpecifier:) detail:NSClassFromString(@"PSListItemsController") cell:[PSTableCell cellTypeFromString:@"PSLinkListCell"] edit:nil];
            [logo5G setIdentifier:@"5G"];

            logo5G.values = @[@0,@1,@2,@3,@4,@5,@99];
            logo5G.titleDictionary = [NSDictionary dictionaryWithObjects:@[
                @"默认",
                @"5G",
                @"5G+",
                @"5G UWB",
                @"5G UC",
                @"5Gᴀ",
                @"自定义"
            ] forKeys:logo5G.values];
            [logo5G setProperty:@"kListValue" forKey:@"key"];
            [specifiers addObject:logo5G];
        }
        else if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_14_0) {
            [specifiers addObject:[PSSpecifier emptyGroupSpecifier]];
            PSSpecifier *logo5G = [PSSpecifier preferenceSpecifierNamed:@"5G 标识" target:self set:@selector(setValue:forSpecifier:) get:@selector(getValueForSpecifier:) detail:NSClassFromString(@"PSListItemsController") cell:[PSTableCell cellTypeFromString:@"PSLinkListCell"] edit:nil];
            [logo5G setIdentifier:@"5G"];

            logo5G.values = @[@0,@1,@2,@3,@99];
            logo5G.titleDictionary = [NSDictionary dictionaryWithObjects:@[
                @"默认",
                @"5G",
                @"5G+",
                @"5G UWB",
                @"自定义"
            ] forKeys:logo5G.values];
            [logo5G setProperty:@"kListValue" forKey:@"key"];
            [specifiers addObject:logo5G];
        }

        PSSpecifier *customStringGroup = [PSSpecifier groupSpecifierWithName:@"自定义标识"];
        [customStringGroup setProperty:@"先在上方为对应网络选择“自定义”，再填写显示文字。" forKey:@"footerText"];
        [specifiers addObject:customStringGroup];

        PSSpecifier *custom4GStringCell = [PSSpecifier preferenceSpecifierNamed:@"4G 自定义" target:self set:@selector(setValue:forSpecifier:) get:@selector(getValueForSpecifier:) detail:nil cell:[PSTableCell cellTypeFromString:@"PSEditTextCell"] edit:nil];
        [custom4GStringCell setIdentifier:@"custom4GString"];
        [specifiers addObject:custom4GStringCell];

        if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_14_0) {
            PSSpecifier *custom5GStringCell = [PSSpecifier preferenceSpecifierNamed:@"5G 自定义" target:self set:@selector(setValue:forSpecifier:) get:@selector(getValueForSpecifier:) detail:nil cell:[PSTableCell cellTypeFromString:@"PSEditTextCell"] edit:nil];
            [custom5GStringCell setIdentifier:@"custom5GString"];
            [specifiers addObject:custom5GStringCell];
        }

        PSSpecifier* footSpecifier = [PSSpecifier emptyGroupSpecifier];
        [footSpecifier setProperty:@"© 2011-2023 Hiraku (@hiraku_dev)\n© 2026 @6866dev 更新优化" forKey:@"footerText"];
        [specifiers addObject:footSpecifier];

        PSSpecifier *respringButton = [PSSpecifier preferenceSpecifierNamed:@"注销设备生效" target:self set:nil get:nil detail:nil cell:[PSTableCell cellTypeFromString:@"PSButtonCell"] edit:nil];
        respringButton->action = @selector(respring);
        [specifiers addObject:respringButton];

        _specifiers = [[NSMutableArray alloc] initWithArray:specifiers];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.title = @"5G Advanced";
}

- (void)loadView {
  	[super loadView];
    self.title = @"5G Advanced";

    NSMutableDictionary *settings = [[NSMutableDictionary alloc] initWithContentsOfFile:SettingsPath];
    if (settings == nil) {
        settings = [[NSMutableDictionary alloc] initWithObjectsAndKeys: @0, @"3G",
                                                                        @0, @"4G",
                                                                        @0, @"5G",
                                                                        nil];
        [settings writeToFile:SettingsPath atomically:YES];
    }
}

//=============================================================================
- (id)getValueForSpecifier:(PSSpecifier *)specifier {
    return getUserDefaultForKey(specifier.identifier);
}

- (void)setValue:(id)value forSpecifier:(PSSpecifier *)specifier {
    setUserDefaultForKey(specifier.identifier, value);
}

-(void)respring {
    if (self.dlsRespringing) return;
    self.dlsRespringing = YES;
    [self.view endEditing:YES];

    if (self.dlsSpinner == nil) {
        self.dlsSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.dlsSpinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.dlsSpinner];
        [NSLayoutConstraint activateConstraints:@[
            [self.dlsSpinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [self.dlsSpinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
        ]];
    }
    [self.dlsSpinner startAnimating];
    self.navigationItem.hidesBackButton = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Keep the spinner visible long enough to acknowledge the tap.
        usleep(550000);

        char *const sbreloadArgs[] = {(char *)ROOT_PATH("/usr/bin/sbreload"), NULL};
        if (run_command(ROOT_PATH("/usr/bin/sbreload"), sbreloadArgs)) {
            return;
        }

        const char *killallPath = ROOT_PATH("/usr/bin/killall");
        char *const springBoardArgs[] = {(char *)killallPath, "-9", "SpringBoard", NULL};
        char *const backboardArgs[] = {(char *)killallPath, "-9", "backboardd", NULL};
        char *const lsdArgs[] = {(char *)killallPath, "-9", "lsd", NULL};

        run_command(killallPath, springBoardArgs);
        run_command(killallPath, backboardArgs);
        run_command(killallPath, lsdArgs);
    });
}
//=============================================================================
@end
