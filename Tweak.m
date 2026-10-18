// Power-M: Super Ultra sleep battery saver (runs inside SpringBoard).
//
// When the screen turns off, Power-M switches on a set of deep power-saving measures
// (Low Power Mode, Airplane Mode, Wi-Fi / Bluetooth / Location off, close background apps).
// When you wake the phone it puts back exactly what it changed, nothing more.
// Every sleep is also logged (battery % before and after) so the real drain can be checked.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define PM_DOMAIN CFSTR("com.kwarnu.powerm")
#define PM_NOTIFY_PREFS "com.kwarnu.powerm/prefschanged"
#define PM_NOTIFY_ACTIVATE "com.kwarnu.powerm/activate"
#define PM_NOTIFY_RESTORE "com.kwarnu.powerm/restore"
#define PM_NOTIFY_RESPRING "com.kwarnu.powerm/respring"

#pragma mark - Settings

typedef struct {
    BOOL enabled;
    NSInteger delay;          // seconds after screen off before activating
    BOOL onlyUnplugged;       // skip while charging
    BOOL skipMusic;           // skip while audio is playing
    NSInteger schedule;       // 0 = always, 1 = night hours only
    NSInteger nightStart;
    NSInteger nightEnd;
    BOOL lpm;
    BOOL airplane;
    BOOL wifi;
    BOOL bluetooth;
    BOOL location;
    BOOL killApps;
    NSInteger restoreDelay;   // seconds the screen must stay on before restoring
} PMConfig;

static PMConfig cfg = {
    .enabled = YES, .delay = 5, .onlyUnplugged = YES, .skipMusic = YES,
    .schedule = 0, .nightStart = 22, .nightEnd = 8,
    .lpm = YES, .airplane = YES, .wifi = YES, .bluetooth = YES, .location = NO, .killApps = YES,
    .restoreDelay = 3,
};

static id PMPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, PM_DOMAIN));
}

static void PMSetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, PM_DOMAIN);
    CFPreferencesAppSynchronize(PM_DOMAIN);
}

static BOOL PMBool(NSString *key, BOOL fallback) {
    id v = PMPref(key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

static NSInteger PMInt(NSString *key, NSInteger fallback, NSInteger lo, NSInteger hi) {
    id v = PMPref(key);
    NSInteger n = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : fallback;
    return n < lo ? lo : (n > hi ? hi : n);
}

static void PMLoadConfig(void) {
    CFPreferencesAppSynchronize(PM_DOMAIN);
    PMConfig c = cfg;
    c.enabled = PMBool(@"enabled", YES);
    c.delay = PMInt(@"delay", 5, 0, 600);
    c.onlyUnplugged = PMBool(@"onlyUnplugged", YES);
    c.skipMusic = PMBool(@"skipMusic", YES);
    c.schedule = PMInt(@"schedule", 0, 0, 1);
    c.nightStart = PMInt(@"nightStart", 22, 0, 23);
    c.nightEnd = PMInt(@"nightEnd", 8, 0, 23);
    c.lpm = PMBool(@"lpm", YES);
    c.airplane = PMBool(@"airplane", YES);
    c.wifi = PMBool(@"wifi", YES);
    c.bluetooth = PMBool(@"bluetooth", YES);
    c.location = PMBool(@"location", NO);
    c.killApps = PMBool(@"killApps", YES);
    c.restoreDelay = PMInt(@"restoreDelay", 3, 0, 60);
    cfg = c;
}

#pragma mark - Private API helpers (all looked up at runtime and guarded)

static id PMShared(const char *className, NSString *selector) {
    Class cls = objc_getClass(className);
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static BOOL PMGetBool(id obj, NSString *selector, BOOL fallback) {
    SEL sel = NSSelectorFromString(selector);
    if (!obj || ![obj respondsToSelector:sel]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

static BOOL PMSetBool(id obj, NSString *selector, BOOL value) {
    SEL sel = NSSelectorFromString(selector);
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, value);
    return YES;
}

// Airplane Mode
static id PMRadios(void) {
    static id radios;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("RadiosPreferences");
        if (cls) radios = [[cls alloc] init];
    });
    return radios;
}

static BOOL PMGetAirplane(void) { return PMGetBool(PMRadios(), @"airplaneMode", NO); }

static void PMSetAirplane(BOOL on) {
    id radios = PMRadios();
    if (PMSetBool(radios, @"setAirplaneMode:", on)) {
        SEL sync = NSSelectorFromString(@"synchronize");
        if ([radios respondsToSelector:sync]) ((void (*)(id, SEL))objc_msgSend)(radios, sync);
    }
}

// Wi-Fi
static BOOL PMGetWiFi(void) { return PMGetBool(PMShared("SBWiFiManager", @"sharedInstance"), @"wiFiEnabled", NO); }
static void PMSetWiFi(BOOL on) { PMSetBool(PMShared("SBWiFiManager", @"sharedInstance"), @"setWiFiEnabled:", on); }

// Bluetooth
static id PMBluetooth(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
    });
    return PMShared("BluetoothManager", @"sharedInstance");
}

static BOOL PMGetBluetooth(void) { return PMGetBool(PMBluetooth(), @"enabled", NO); }

static void PMSetBluetooth(BOOL on) {
    id bt = PMBluetooth();
    PMSetBool(bt, @"setEnabled:", on);
    PMSetBool(bt, @"setPowered:", on);
}

// Location Services
static BOOL PMGetLocation(void) {
    Class cls = objc_getClass("CLLocationManager");
    SEL sel = NSSelectorFromString(@"locationServicesEnabled");
    if (!cls || ![cls respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(cls, sel);
}

static void PMSetLocation(BOOL on) {
    Class cls = objc_getClass("CLLocationManager");
    SEL sel = NSSelectorFromString(@"setLocationServicesEnabled:");
    if (cls && [cls respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(cls, sel, on);
}

// Low Power Mode
static BOOL PMGetLPM(void) { return NSProcessInfo.processInfo.isLowPowerModeEnabled; }

static void PMSetLPM(BOOL on) {
    id saver = PMShared("_CDBatterySaver", @"batterySaver");
    if (!saver) return;
    SEL a = NSSelectorFromString(@"setPowerMode:error:");
    SEL b = NSSelectorFromString(@"setMode:");
    if ([saver respondsToSelector:a]) {
        ((BOOL (*)(id, SEL, long long, id *))objc_msgSend)(saver, a, on ? 1 : 0, NULL);
    } else if ([saver respondsToSelector:b]) {
        ((void (*)(id, SEL, long long))objc_msgSend)(saver, b, on ? 1 : 0);
    }
}

// Close background apps
static void PMKillBackgroundApps(void) {
    id controller = PMShared("SBApplicationController", @"sharedInstance");
    SEL running = NSSelectorFromString(@"runningApplications");
    if (!controller || ![controller respondsToSelector:running]) return;

    dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
    typedef void (*KillFn)(NSString *, int, BOOL, NSString *);
    KillFn kill = (KillFn)dlsym(RTLD_DEFAULT, "BKSTerminateApplicationForReasonAndReportWithDescription");
    if (!kill) return;

    NSSet *keep = [NSSet setWithArray:@[
        @"com.apple.mobilephone", @"com.apple.facetime", @"com.apple.InCallService",
        @"com.apple.Preferences", @"com.apple.springboard",
    ]];
    NSArray *apps = ((NSArray * (*)(id, SEL))objc_msgSend)(controller, running);
    SEL bundleSel = NSSelectorFromString(@"bundleIdentifier");
    for (id app in apps) {
        if (![app respondsToSelector:bundleSel]) continue;
        NSString *bundleID = ((NSString * (*)(id, SEL))objc_msgSend)(app, bundleSel);
        if (!bundleID.length || [keep containsObject:bundleID]) continue;
        kill(bundleID, 5, NO, @"Power-M sleep saver");
    }
}

// Is audio / video playing right now?
static void PMCheckMusic(void (^done)(BOOL playing)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    typedef void (*PlayingFn)(dispatch_queue_t, void (^)(Boolean));
    PlayingFn fn = (PlayingFn)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!fn) { done(NO); return; }
    fn(dispatch_get_main_queue(), ^(Boolean playing) { done(playing ? YES : NO); });
}

// Safety net: ask SpringBoard itself whether the screen is on.
static BOOL PMScreenReallyOn(void) {
    id backlight = PMShared("SBBacklightController", @"sharedInstance");
    return PMGetBool(backlight, @"screenIsOn", NO);
}

static void PMRespring(void) {
    id service = PMShared("FBSystemService", @"sharedInstance");
    SEL sel = NSSelectorFromString(@"exitAndRelaunch:");
    if (service && [service respondsToSelector:sel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(service, sel, YES);
        return;
    }
    exit(0);
}

#pragma mark - State

static BOOL gScreenOn = YES;
static NSUInteger gGeneration;       // bumps on every screen on/off change; cancels stale timers
static BOOL gActive;                 // Power-M measures are currently applied
static NSDictionary *gSaved;         // previous values of whatever Power-M changed
static NSDate *gSleepStart;
static int gSleepStartLevel = -1;
static BOOL gActivatedThisSleep;

static int PMBatteryPercent(void) {
    float level = UIDevice.currentDevice.batteryLevel;
    return level < 0 ? -1 : (int)lroundf(level * 100.0f);
}

static BOOL PMInSchedule(void) {
    if (cfg.schedule == 0) return YES;
    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:NSDate.date];
    if (cfg.nightStart == cfg.nightEnd) return YES;
    if (cfg.nightStart < cfg.nightEnd) return hour >= cfg.nightStart && hour < cfg.nightEnd;
    return hour >= cfg.nightStart || hour < cfg.nightEnd;
}

#pragma mark - Activate / restore

static void PMActivate(void) {
    if (gActive) return;
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];

    // Radios first, while they are still on, then Airplane Mode last.
    if (cfg.wifi && PMGetWiFi()) { saved[@"wifi"] = @YES; PMSetWiFi(NO); }
    if (cfg.bluetooth && PMGetBluetooth()) { saved[@"bluetooth"] = @YES; PMSetBluetooth(NO); }
    if (cfg.location && PMGetLocation()) { saved[@"location"] = @YES; PMSetLocation(NO); }
    if (cfg.lpm && !PMGetLPM()) { saved[@"lpm"] = @NO; PMSetLPM(YES); }
    if (cfg.airplane && !PMGetAirplane()) { saved[@"airplane"] = @NO; PMSetAirplane(YES); }
    if (cfg.killApps) PMKillBackgroundApps();

    gSaved = saved;
    gActive = YES;
    gActivatedThisSleep = YES;
    PMSetPref(@"activeState", saved);   // survives a respring or crash
}

static void PMRestore(void) {
    NSDictionary *saved = gSaved;
    if (!saved) {
        id stored = PMPref(@"activeState");
        if ([stored isKindOfClass:NSDictionary.class]) saved = stored;
    }
    if (saved) {
        // Airplane Mode off first so the radios can come back, then the individual switches.
        if (saved[@"airplane"]) PMSetAirplane([saved[@"airplane"] boolValue]);
        if (saved[@"lpm"]) PMSetLPM([saved[@"lpm"] boolValue]);
        if (saved[@"wifi"]) PMSetWiFi([saved[@"wifi"] boolValue]);
        if (saved[@"bluetooth"]) PMSetBluetooth([saved[@"bluetooth"] boolValue]);
        if (saved[@"location"]) PMSetLocation([saved[@"location"] boolValue]);
    }
    gSaved = nil;
    gActive = NO;
    PMSetPref(@"activeState", nil);
}

// YES while measures are applied, including after a SpringBoard restart (state is saved on disk).
static BOOL PMHasAppliedState(void) {
    return gActive || [PMPref(@"activeState") isKindOfClass:NSDictionary.class];
}

static void PMTryActivate(NSUInteger generation);

static void PMRetryLater(NSUInteger generation, int64_t seconds) {
    dispatch_after(dispatch_walltime(NULL, seconds * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        PMTryActivate(generation);
    });
}

// Runs only while the screen is off; every check is re-done at the moment of activation.
static void PMTryActivate(NSUInteger generation) {
    if (gActive || !cfg.enabled) return;
    if (generation != gGeneration || gScreenOn) return;
    if (PMScreenReallyOn()) return;

    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    if (cfg.onlyUnplugged && (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull)) return;
    if (!PMInSchedule()) return;

    if (cfg.skipMusic) {
        PMCheckMusic(^(BOOL playing) {
            if (gActive || generation != gGeneration || gScreenOn) return;
            if (playing) { PMRetryLater(generation, 60); return; }
            PMActivate();
        });
        return;
    }
    PMActivate();
}

#pragma mark - Sleep report

static void PMRecordSleep(NSDate *start, NSTimeInterval duration, int from, int to, BOOL active) {
    if (duration < 600 || from < 0 || to < 0) return;   // ignore short wake-ups
    id stored = PMPref(@"history");
    NSMutableArray *history = [stored isKindOfClass:NSArray.class] ? [stored mutableCopy] : [NSMutableArray array];
    [history addObject:@{ @"start": start, @"dur": @(duration), @"from": @(from), @"to": @(to), @"active": @(active) }];
    while (history.count > 20) [history removeObjectAtIndex:0];
    PMSetPref(@"history", history);
}

#pragma mark - Screen events

static void PMScreenWentOff(void) {
    gSleepStart = NSDate.date;
    gSleepStartLevel = PMBatteryPercent();
    gActivatedThisSleep = NO;
    if (!cfg.enabled) return;

    NSUInteger generation = gGeneration;
    if (cfg.delay <= 0) {
        PMTryActivate(generation);
    } else {
        dispatch_after(dispatch_walltime(NULL, cfg.delay * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            PMTryActivate(generation);
        });
    }
}

static void PMScreenWentOn(void) {
    if (gSleepStart) {
        NSTimeInterval duration = -[gSleepStart timeIntervalSinceNow];
        PMRecordSleep(gSleepStart, duration, gSleepStartLevel, PMBatteryPercent(), gActivatedThisSleep);
        gSleepStart = nil;
    }
    if (!gActive) return;

    NSUInteger generation = gGeneration;
    if (cfg.restoreDelay <= 0) {
        PMRestore();
    } else {
        dispatch_after(dispatch_walltime(NULL, cfg.restoreDelay * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (generation == gGeneration && gScreenOn) PMRestore();
        });
    }
}

static void PMScreenChanged(BOOL on) {
    if (on == gScreenOn) return;
    gScreenOn = on;
    gGeneration++;
    if (on) PMScreenWentOn(); else PMScreenWentOff();
}

#pragma mark - Notifications

static void PMOnPrefsChanged(void) {
    PMLoadConfig();
    if (!cfg.enabled && gActive) { PMRestore(); return; }
    if (cfg.enabled && !gScreenOn && !gActive) PMTryActivate(gGeneration);
}

static void PMDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([n isEqualToString:@PM_NOTIFY_PREFS]) {
            PMOnPrefsChanged();
        } else if ([n isEqualToString:@PM_NOTIFY_ACTIVATE]) {
            PMLoadConfig();
            PMActivate();                       // manual test: ignores screen / charging / schedule
        } else if ([n isEqualToString:@PM_NOTIFY_RESTORE]) {
            PMRestore();
        } else if ([n isEqualToString:@PM_NOTIFY_RESPRING]) {
            PMRespring();
        }
    });
}

__attribute__((constructor)) static void PMInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

        PMLoadConfig();

        dispatch_async(dispatch_get_main_queue(), ^{
            UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        });

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        const char *names[] = { PM_NOTIFY_PREFS, PM_NOTIFY_ACTIVATE, PM_NOTIFY_RESTORE, PM_NOTIFY_RESPRING };
        for (int i = 0; i < 4; i++) {
            CFNotificationCenterAddObserver(darwin, NULL, PMDarwinCallback,
                                            (__bridge CFStringRef)@(names[i]), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // Display on / off (state 0 = off).
        static int displayToken, lockToken;
        notify_register_dispatch("com.apple.iokit.hid.displayStatus", &displayToken,
                                 dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 1;
            notify_get_state(token, &state);
            PMScreenChanged(state != 0);
        });

        // Unlock (state 0 = unlocked): restore immediately, no waiting.
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken,
                                 dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 1;
            notify_get_state(token, &state);
            if (state == 0 && PMHasAppliedState()) PMRestore();
        });

        // Plugging in or unplugging while asleep re-evaluates the "only when unplugged" rule.
        [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceBatteryStateDidChangeNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            if (!gScreenOn && !gActive) PMTryActivate(gGeneration);
        }];

        // If SpringBoard restarted while measures were applied, put everything back.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (PMHasAppliedState() && PMScreenReallyOn()) PMRestore();
        });
    }
}
