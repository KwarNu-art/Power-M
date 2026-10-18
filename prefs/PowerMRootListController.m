#import <UIKit/UIKit.h>
#import <notify.h>

// Minimal declarations of the private Preferences.framework classes we subclass.
@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController {
@protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

#define PM_DOMAIN CFSTR("com.kwarnu.powerm")
#define PM_NOTIFY_PREFS "com.kwarnu.powerm/prefschanged"
#define PM_NOTIFY_ACTIVATE "com.kwarnu.powerm/activate"
#define PM_NOTIFY_RESTORE "com.kwarnu.powerm/restore"
#define PM_NOTIFY_RESPRING "com.kwarnu.powerm/respring"

@interface PowerMRootListController : PSListController
@end

@implementation PowerMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];   // refresh the sleep report every time the pane opens
}

#pragma mark - Helpers

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyValues:(NSDictionary *)values title:(NSString *)title {
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, PM_DOMAIN);
    }];
    CFPreferencesAppSynchronize(PM_DOMAIN);
    notify_post(PM_NOTIFY_PREFS);
    [self reloadSpecifiers];
    [self showAlert:title message:@"Preset applied. It takes effect the next time the screen turns off."];
}

#pragma mark - Presets

- (void)presetSuperUltra {
    [self applyValues:@{
        @"enabled": @YES, @"lpm": @YES, @"airplane": @YES, @"wifi": @YES, @"bluetooth": @YES,
        @"location": @YES, @"killApps": @YES, @"delay": @3,
    } title:@"Super Ultra"];
}

- (void)presetDeepSleep {
    [self applyValues:@{
        @"enabled": @YES, @"lpm": @YES, @"airplane": @NO, @"wifi": @YES, @"bluetooth": @YES,
        @"location": @NO, @"killApps": @YES, @"delay": @5,
    } title:@"Deep Sleep"];
}

- (void)presetLight {
    [self applyValues:@{
        @"enabled": @YES, @"lpm": @YES, @"airplane": @NO, @"wifi": @NO, @"bluetooth": @NO,
        @"location": @NO, @"killApps": @NO, @"delay": @10,
    } title:@"Light"];
}

#pragma mark - Test buttons

- (void)activateNow {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Test Sleep Mode"
                         message:@"This turns on your selected measures right now, for example Airplane Mode. Tap Restore Now (or lock and unlock the phone) to undo it."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Turn On" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        notify_post(PM_NOTIFY_ACTIVATE);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreNow {
    notify_post(PM_NOTIFY_RESTORE);
    [self showAlert:@"Restored" message:@"Everything Power-M changed has been put back."];
}

- (void)clearHistory {
    CFPreferencesSetAppValue(CFSTR("history"), NULL, PM_DOMAIN);
    CFPreferencesAppSynchronize(PM_DOMAIN);
    [self reloadSpecifiers];
}

- (void)respring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Respring"
                         message:@"Respring now?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        notify_post(PM_NOTIFY_RESPRING);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Sleep report

- (NSArray *)history {
    CFPreferencesAppSynchronize(PM_DOMAIN);
    id stored = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("history"), PM_DOMAIN));
    return [stored isKindOfClass:NSArray.class] ? stored : @[];
}

static NSString *PMDurationText(NSTimeInterval seconds) {
    NSInteger minutes = (NSInteger)(seconds / 60.0);
    if (minutes < 60) return [NSString stringWithFormat:@"%ldm", (long)minutes];
    return [NSString stringWithFormat:@"%ldh %02ldm", (long)(minutes / 60), (long)(minutes % 60)];
}

// Average drain in % per hour over the saved sleeps with Power-M on (active = YES) or off.
- (NSString *)rateForActive:(BOOL)active {
    double drained = 0.0, hours = 0.0;
    NSInteger count = 0;
    for (NSDictionary *entry in [self history]) {
        if ([entry[@"active"] boolValue] != active) continue;
        drained += MAX(0, [entry[@"from"] integerValue] - [entry[@"to"] integerValue]);
        hours += [entry[@"dur"] doubleValue] / 3600.0;
        count++;
    }
    if (count == 0 || hours <= 0.0) return @"no data yet";
    return [NSString stringWithFormat:@"%.1f%%/h (%ld)", drained / hours, (long)count];
}

- (id)lastDuration:(id)specifier {
    NSDictionary *last = [[self history] lastObject];
    return last ? PMDurationText([last[@"dur"] doubleValue]) : @"no data yet";
}

- (id)lastChange:(id)specifier {
    NSDictionary *last = [[self history] lastObject];
    if (!last) return @"no data yet";
    return [NSString stringWithFormat:@"%@%% → %@%%", last[@"from"], last[@"to"]];
}

- (id)lastMode:(id)specifier {
    NSDictionary *last = [[self history] lastObject];
    if (!last) return @"no data yet";
    return [last[@"active"] boolValue] ? @"Power-M ON" : @"Power-M off";
}

- (id)rateOn:(id)specifier { return [self rateForActive:YES]; }
- (id)rateOff:(id)specifier { return [self rateForActive:NO]; }

@end
