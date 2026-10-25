#import <UIKit/UIKit.h>
#import <unistd.h>
#import <spawn.h>

#import <sys/wait.h>

extern char **environ;

// The app runs as mobile; reboot(2) needs root. The setuid-root helper does the three actions
// for this app only (README.md). On success the phone goes down and the helper never returns.
#define HELPER "/usr/local/libexec/powermenu-helper"

// Returns the helper's exit code, or -1 if it could not start / did not exit normally.
static int run_helper(const char *action) {
    pid_t pid;
    char *const argv[] = {HELPER, (char *)action, NULL};
    if (posix_spawn(&pid, HELPER, NULL, NULL, argv, environ) != 0) {
        return -1;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) {
        return -1;
    }
    return WEXITSTATUS(status);
}

static NSString *helper_error(int rc) {
    switch (rc) {
    case 3: return @"This kernel cannot select the bootloader (no kern.negroni_reboot_mode). Use Volume Up + Volume Down + Power, or op10tool ctl bootloader from the computer.";
    case 4: return @"The helper refused this caller.";
    case 5: return @"The helper is not setuid root. Install it again (root:mobile, mode 4750).";
    case -1: return @"Cannot start " HELPER ".";
    default: return [NSString stringWithFormat:@"The helper failed (exit code %d).", rc];
    }
}

@interface ViewController : UIViewController
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    // Scroll view for layout flexibility across screen sizes
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];
    
    // Header section
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Power Options";
    titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:titleLabel];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"OnePlus 10 Pro (NE2211) Native iOS";
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:subtitleLabel];
    
    // Stack View for Action Cards following Apple HIG Card / Inset-Grouped pattern
    UIStackView *cardStack = [[UIStackView alloc] init];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 16.0;
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:cardStack];
    
    [cardStack addArrangedSubview:[self createActionCardWithTitle:@"Reboot to Bootloader"
                                                          detail:@"Restarts device directly into Fastboot mode"
                                                      symbolName:@"arrow.triangle.2.circlepath.circle.fill"
                                                       tintColor:[UIColor systemBlueColor]
                                                          action:@selector(onBootloaderTapped)]];

    [cardStack addArrangedSubview:[self createActionCardWithTitle:@"Restart System"
                                                          detail:@"Performs a clean sync and system reboot"
                                                      symbolName:@"goforward"
                                                       tintColor:[UIColor systemOrangeColor]
                                                          action:@selector(onRebootTapped)]];

    [cardStack addArrangedSubview:[self createActionCardWithTitle:@"Shut Down"
                                                          detail:@"Safely flushes disk buffers and powers off"
                                                      symbolName:@"power.circle.fill"
                                                       tintColor:[UIColor systemRedColor]
                                                          action:@selector(onPowerOffTapped)]];
    
    // Status footnote
    UILabel *footerLabel = [[UILabel alloc] init];
    footerLabel.text = @"XNU 8796 • ARMv8.3 PAC • Adreno 730 Native";
    footerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    footerLabel.textColor = [UIColor tertiaryLabelColor];
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:footerLabel];
    
    UILayoutGuide *guide = scrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = scrollView.frameLayoutGuide;
    
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:guide.topAnchor constant:48],
        [titleLabel.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:24],
        [titleLabel.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-24],
        
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        
        [cardStack.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:36],
        [cardStack.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [cardStack.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],
        
        [footerLabel.topAnchor constraintEqualToAnchor:cardStack.bottomAnchor constant:40],
        [footerLabel.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [footerLabel.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],
        [footerLabel.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-40]
    ]];
}

- (UIView *)createActionCardWithTitle:(NSString *)title
                               detail:(NSString *)detail
                           symbolName:(NSString *)symbolName
                            tintColor:(UIColor *)tintColor
                               action:(SEL)actionSelector {
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card addTarget:self action:actionSelector forControlEvents:UIControlEventTouchUpInside];
    
    // Icon image
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:symbolName withConfiguration:config];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:symbol];
    iconView.tintColor = tintColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconView];
    
    // Label container
    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    titleLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleLbl.textColor = [UIColor labelColor];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLbl];
    
    UILabel *detailLbl = [[UILabel alloc] init];
    detailLbl.text = detail;
    detailLbl.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    detailLbl.textColor = [UIColor secondaryLabelColor];
    detailLbl.numberOfLines = 2;
    detailLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:detailLbl];
    
    // Chevron indicator (Apple HIG list navigation indicator)
    UIImageSymbolConfiguration *chevConfig = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImage *chevron = [UIImage systemImageNamed:@"chevron.right" withConfiguration:chevConfig];
    UIImageView *chevronView = [[UIImageView alloc] initWithImage:chevron];
    chevronView.tintColor = [UIColor tertiaryLabelColor];
    chevronView.contentMode = UIViewContentModeScaleAspectFit;
    chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chevronView];
    
    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:84],
        
        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [iconView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:36],
        [iconView.heightAnchor constraintEqualToConstant:36],
        
        [chevronView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [chevronView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chevronView.widthAnchor constraintEqualToConstant:14],
        
        [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [titleLbl.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:16],
        [titleLbl.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-12],
        
        [detailLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:4],
        [detailLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
        [detailLbl.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-12],
        [detailLbl.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18]
    ]];
    
    return card;
}

#pragma mark - Confirmation & Actions (Apple HIG standard alert controllers)

- (void)runAction:(const char *)action {
    int rc = run_helper(action);
    UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Not Done"
                                                                 message:helper_error(rc)
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:err animated:YES completion:nil];
}

- (void)onBootloaderTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reboot to Bootloader?"
                                                                   message:@"The phone will restart and enter fastboot mode."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reboot to Bootloader" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self runAction:"bootloader"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onRebootTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Device?"
                                                                   message:@"All running processes will be terminated and the system will reboot."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self runAction:"restart"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onPowerOffTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Shut Down?"
                                                                   message:@"The device will cleanly unmount volumes and power off."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Shut Down" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self runAction:"shutdown"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
