/*
 * Copyright 2011-2014 Jason Rush and John Flanagan. All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#import <AudioToolbox/AudioToolbox.h>
#import "LockScreenManager.h"
#import "LockViewController.h"
#import "PinViewController.h"
#import "MiniKeePassAppDelegate.h"
#import "AppSettings.h"
#import "KeychainUtils.h"

@interface LockScreenManager () <PinViewControllerDelegate>
@property (nonatomic, strong) LockViewController *lockViewController;
@property (nonatomic, strong) PinViewController *pinViewController;
@end

@implementation LockScreenManager

static LockScreenManager *sharedInstance = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[[self class] alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter addObserver:self
                               selector:@selector(applicationDidFinishLaunching:)
                                   name:UIApplicationDidFinishLaunchingNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(applicationWillResignActive:)
                                   name:UIApplicationWillResignActiveNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(applicationDidBecomeActive:)
                                   name:UIApplicationDidBecomeActiveNotification
                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter removeObserver:self];
}

#pragma mark - Lock/Unlock

- (BOOL)shouldCheckPin {
    AppSettings *appSettings = [AppSettings sharedInstance];

    // Check if the PIN is enabled
    if (![appSettings pinEnabled]) {
        return NO;
    }

    // Get the last time the app exited
    NSDate *exitTime = [appSettings exitTime];
    if (exitTime == nil) {
        return YES;
    }

    // Check if enough time has ellapsed
    NSTimeInterval timeInterval = ABS([exitTime timeIntervalSinceNow]);
    return timeInterval > [appSettings pinLockTimeout];
}

+ (UIViewController *)topMostController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;

    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }

    return topController;
}

- (void)showLockScreen {
    if (self.lockViewController != nil) {
        return;
    }

    self.lockViewController = [[LockViewController alloc] init];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:self.lockViewController];

    // Hack for iOS 8 to ensure the view is displayed before anything else on launch
    MiniKeePassAppDelegate *appDelegate = [MiniKeePassAppDelegate appDelegate];
    [appDelegate.window addSubview:navigationController.view];

    UIViewController *rootViewController = [LockScreenManager topMostController];
    [rootViewController presentViewController:navigationController animated:NO completion:nil];
}

- (void)hideLockScreen {
    [self.lockViewController dismissModalViewControllerAnimated:NO];
    self.lockViewController = nil;
}

- (void)showPinScreenAnimated:(BOOL)animated {
    if (self.pinViewController != nil) {
        [self.pinViewController clearPinEntry];
        return;
    }

    if (self.lockViewController == nil) {
        [self showLockScreen];
    }

    self.pinViewController = [[PinViewController alloc] init];
    self.pinViewController.delegate = self;

    [self.lockViewController presentViewController:self.pinViewController animated:animated completion:nil];
}

- (void)hidePinScreen {
    [self.lockViewController.presentingViewController dismissViewControllerAnimated:YES completion:^{
        self.lockViewController = nil;
        self.pinViewController = nil;
    }];
}

#pragma mark - PinViewController delegate methods

- (void)pinViewController:(PinViewController *)pinViewController pinEntered:(NSString *)pin {
    NSString *validPin = [KeychainUtils stringForKey:@"PIN" andServiceName:@"com.jflan.MiniKeePass.pin"];
    if (validPin == nil) {
        // Delete keychain data
        MiniKeePassAppDelegate *appDelegate = [MiniKeePassAppDelegate appDelegate];
        [appDelegate deleteKeychainData];

        // Dismiss the PIN screen
        [self hidePinScreen];
    } else {
        AppSettings *appSettings = [AppSettings sharedInstance];

        // Check if the PIN is valid
        if ([pin isEqualToString:validPin]) {
            // Reset the number of pin failed attempts
            [appSettings setPinFailedAttempts:0];

            // Dismiss the PIN screen
            [self hidePinScreen];
        } else {
            // Vibrate to signify they are a bad user
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
            [pinViewController clearPinEntry];

            if (![appSettings deleteOnFailureEnabled]) {
                // Update the status message on the PIN view
                pinViewController.titleLabel.text = NSLocalizedString(@"Incorrect PIN", nil);
            } else {
                // Get the number of failed attempts
                NSInteger pinFailedAttempts = [appSettings pinFailedAttempts];
                [appSettings setPinFailedAttempts:++pinFailedAttempts];

                // Get the number of failed attempts before deleting
                NSInteger deleteOnFailureAttempts = [appSettings deleteOnFailureAttempts];

                // Update the status message on the PIN view
                NSInteger remainingAttempts = (deleteOnFailureAttempts - pinFailedAttempts);

                // Update the incorrect pin message
                if (remainingAttempts > 0) {
                    pinViewController.titleLabel.text = [NSString stringWithFormat:@"%@\n%@: %ld", NSLocalizedString(@"Incorrect PIN", nil), NSLocalizedString(@"Attempts Remaining", nil), (long)remainingAttempts];
                } else {
                    pinViewController.titleLabel.text = NSLocalizedString(@"Incorrect PIN", nil);
                }

                // Check if they have failed too many times
                if (pinFailedAttempts >= deleteOnFailureAttempts) {
                    // Delete all data
                    MiniKeePassAppDelegate *appDelegate = [MiniKeePassAppDelegate appDelegate];
                    [appDelegate deleteAllData];

                    // Dismiss the PIN screen
                    [self hidePinScreen];
                }
            }
        }
    }
}

#pragma mark - Application Notification Handlers

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if ([self shouldCheckPin]) {
        [self showPinScreenAnimated:NO];
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    AppSettings *appSettings = [AppSettings sharedInstance];
    if ([appSettings pinEnabled]) {
        [appSettings setExitTime:[NSDate date]];

        [self showLockScreen];
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if ([self shouldCheckPin]) {
        [self showPinScreenAnimated:YES];
    } else {
        [self hideLockScreen];
    }
}

@end
