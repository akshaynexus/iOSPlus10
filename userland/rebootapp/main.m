#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <unistd.h>
#import <spawn.h>

extern int reboot(int);
extern char **environ;
#define RB_AUTOBOOT     0
#define RB_HALT         0x08

static void run_cmd(const char *path, char *const argv[]) {
    pid_t pid;
    posix_spawn(&pid, path, NULL, NULL, argv, environ);
    int status;
    waitpid(pid, &status, 0);
}

@interface ViewController : UIViewController
@property (strong, nonatomic) UILabel *gpuNameLabel;
@property (strong, nonatomic) UILabel *gpuStatusLabel;
@property (strong, nonatomic) UILabel *gpuDetailsLabel;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];
    
    // Header section
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"XNUtils";
    titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:titleLabel];
    
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"OnePlus 10 Pro • XNU System & Diagnostics";
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:subtitleLabel];
    
    // Section 1: GPU / Metal Hardware Diagnostics Card
    UIView *gpuCard = [self createGPUInfoCard];
    gpuCard.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:gpuCard];
    
    // Section Header: Power Actions
    UILabel *powerHeader = [[UILabel alloc] init];
    powerHeader.text = @"POWER ACTIONS";
    powerHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    powerHeader.textColor = [UIColor secondaryLabelColor];
    powerHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:powerHeader];
    
    // Section 2: Stack View for Action Cards
    UIStackView *cardStack = [[UIStackView alloc] init];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 14.0;
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
    
    // Footer section
    UILabel *footerLabel = [[UILabel alloc] init];
    footerLabel.text = @"XNU 8796 • ARMv8.3 PAC • Adreno 730 • 120Hz Vsync";
    footerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    footerLabel.textColor = [UIColor tertiaryLabelColor];
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:footerLabel];
    
    UILayoutGuide *guide = scrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = scrollView.frameLayoutGuide;
    
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:guide.topAnchor constant:40],
        [titleLabel.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],
        
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        
        [gpuCard.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:24],
        [gpuCard.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [gpuCard.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],
        
        [powerHeader.topAnchor constraintEqualToAnchor:gpuCard.bottomAnchor constant:28],
        [powerHeader.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:24],
        [powerHeader.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],
        
        [cardStack.topAnchor constraintEqualToAnchor:powerHeader.bottomAnchor constant:10],
        [cardStack.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [cardStack.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],
        
        [footerLabel.topAnchor constraintEqualToAnchor:cardStack.bottomAnchor constant:32],
        [footerLabel.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [footerLabel.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],
        [footerLabel.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-30]
    ]];
    
    [self probeMetalDevice];
}

- (UIView *)createGPUInfoCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    
    UIImageView *iconView = [[UIImageView alloc] init];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
    iconView.image = [UIImage systemImageNamed:@"display" withConfiguration:config];
    iconView.tintColor = [UIColor systemIndigoColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconView];
    
    UILabel *sectionTitle = [[UILabel alloc] init];
    sectionTitle.text = @"GRAPHICS & METAL";
    sectionTitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    sectionTitle.textColor = [UIColor systemIndigoColor];
    sectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:sectionTitle];
    
    self.gpuNameLabel = [[UILabel alloc] init];
    self.gpuNameLabel.text = @"Probing GPU...";
    self.gpuNameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    self.gpuNameLabel.textColor = [UIColor labelColor];
    self.gpuNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.gpuNameLabel];
    
    self.gpuStatusLabel = [[UILabel alloc] init];
    self.gpuStatusLabel.text = @"Status: Checking Metal device availability...";
    self.gpuStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.gpuStatusLabel.textColor = [UIColor secondaryLabelColor];
    self.gpuStatusLabel.numberOfLines = 0;
    self.gpuStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.gpuStatusLabel];
    
    self.gpuDetailsLabel = [[UILabel alloc] init];
    self.gpuDetailsLabel.text = @"Renderer: Adreno 730 • Pipeline: Turnip Vulkan";
    self.gpuDetailsLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.gpuDetailsLabel.textColor = [UIColor tertiaryLabelColor];
    self.gpuDetailsLabel.numberOfLines = 0;
    self.gpuDetailsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.gpuDetailsLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [iconView.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [iconView.widthAnchor constraintEqualToConstant:32],
        [iconView.heightAnchor constraintEqualToConstant:32],
        
        [sectionTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [sectionTitle.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [sectionTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        
        [self.gpuNameLabel.topAnchor constraintEqualToAnchor:sectionTitle.bottomAnchor constant:4],
        [self.gpuNameLabel.leadingAnchor constraintEqualToAnchor:sectionTitle.leadingAnchor],
        [self.gpuNameLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        
        [self.gpuStatusLabel.topAnchor constraintEqualToAnchor:self.gpuNameLabel.bottomAnchor constant:6],
        [self.gpuStatusLabel.leadingAnchor constraintEqualToAnchor:sectionTitle.leadingAnchor],
        [self.gpuStatusLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        
        [self.gpuDetailsLabel.topAnchor constraintEqualToAnchor:self.gpuStatusLabel.bottomAnchor constant:6],
        [self.gpuDetailsLabel.leadingAnchor constraintEqualToAnchor:sectionTitle.leadingAnchor],
        [self.gpuDetailsLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.gpuDetailsLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16]
    ]];
    
    return card;
}

- (void)probeMetalDevice {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
        self.gpuNameLabel.text = device.name ?: @"Active Metal Device";
        self.gpuStatusLabel.text = [NSString stringWithFormat:@"Hardware Accelerated: YES\nLow Power: %@ • Removable: %@",
                                    device.isLowPower ? @"YES" : @"NO",
                                    device.isRemovable ? @"YES" : @"NO"];
        
        NSMutableString *details = [NSMutableString stringWithString:@"Features: "];
        if ([device supportsFamily:MTLGPUFamilyApple1]) [details appendString:@"Apple1 "];
        if ([device supportsFamily:MTLGPUFamilyApple2]) [details appendString:@"Apple2 "];
        if ([device supportsFamily:MTLGPUFamilyApple3]) [details appendString:@"Apple3 "];
        if ([device supportsFamily:MTLGPUFamilyCommon1]) [details appendString:@"Common1 "];
        if ([device supportsFamily:MTLGPUFamilyCommon2]) [details appendString:@"Common2 "];
        [details appendFormat:@"\nMax Buffer: %lu MB", (unsigned long)(device.maxBufferLength / (1024 * 1024))];
        self.gpuDetailsLabel.text = details;
    } else {
        self.gpuNameLabel.text = @"Software Renderer (Fallback)";
        self.gpuStatusLabel.text = @"Hardware Accelerated: NO\nCoreAnimation using CPU rasterization";
        self.gpuDetailsLabel.text = @"Note: Check /var/db/negronimetal/clients or metal.log";
    }
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
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:symbolName withConfiguration:config];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:symbol];
    iconView.tintColor = tintColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconView];
    
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

#pragma mark - Confirmation & Actions

- (void)onBootloaderTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reboot to Bootloader?"
                                                                   message:@"The phone will restart and enter fastboot mode."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reboot to Bootloader" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        char *const args[] = {"/usr/local/bin/usbreboot", "-f", "bootloader", NULL};
        run_cmd("/usr/local/bin/usbreboot", args);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onRebootTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Device?"
                                                                   message:@"All running processes will be terminated and the system will reboot."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        sync();
        reboot(RB_AUTOBOOT);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onPowerOffTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Shut Down?"
                                                                   message:@"The device will cleanly unmount volumes and power off."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Shut Down" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        sync();
        reboot(RB_HALT);
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
