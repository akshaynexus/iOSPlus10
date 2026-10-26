#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

// The root part of the app (userland/rebootapp/powermenu-helper.c): setuid root, root:mobile 4750,
// accepts the caller only when the parent process is /Applications/XNUtils.app/XNUtils.
// The reboot syscall, the reboot-mode sysctl, the switch files and the backboardd kill all need euid 0,
// so every action goes through it; the app itself never calls the reboot syscall or the usb reboot tool.
#define HELPER_PATH "/usr/local/libexec/powermenu-helper"

// Run the helper with VERB [ARG]; returns the exit status (or -errno when it could not start),
// stdout + stderr in *output.
static int run_helper(NSString *verb, NSString *arg, NSString **output) {
    int fds[2];
    if (pipe(fds) != 0) return -errno;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);
    char *const argv2[] = { HELPER_PATH, (char *)verb.UTF8String, NULL };
    char *const argv3[] = { HELPER_PATH, (char *)verb.UTF8String, (char *)arg.UTF8String, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, HELPER_PATH, &fa, NULL, arg ? argv3 : argv2, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    NSMutableData *data = [NSMutableData data];
    if (rc == 0) {
        char buf[1024];
        ssize_t n;
        while ((n = read(fds[0], buf, sizeof(buf))) > 0) [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fds[0]);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    if (output) *output = text;
    if (rc != 0) return -rc;
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// KEY=VALUE lines of `powermenu-helper status`.
static NSDictionary<NSString *, NSString *> *parse_status(NSString *text) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        d[[line substringToIndex:eq.location]] = [line substringFromIndex:eq.location + 1];
    }
    return d;
}

@interface ViewController : UIViewController
@property (strong, nonatomic) UILabel *gpuNameLabel;
@property (strong, nonatomic) UILabel *gpuStatusLabel;
@property (strong, nonatomic) UILabel *gpuDetailsLabel;
@property (strong, nonatomic) UISegmentedControl *metalControl;
@property (strong, nonatomic) UISwitch *glSwitch;
@property (strong, nonatomic) UISwitch *glAppsSwitch;
@property (strong, nonatomic) UISwitch *glFinishSwitch;
@property (strong, nonatomic) UILabel *switchStatusLabel;
@property (nonatomic) BOOL updatingControls;
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
    
    // Section Header: Switches (NegroniMetal / NegroniGL gate files, written by the helper)
    UILabel *switchHeader = [[UILabel alloc] init];
    switchHeader.text = @"GPU SWITCHES";
    switchHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    switchHeader.textColor = [UIColor secondaryLabelColor];
    switchHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:switchHeader];

    UIView *switchCard = [self createSwitchCard];
    switchCard.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:switchCard];

    UIStackView *applyStack = [[UIStackView alloc] init];
    applyStack.axis = UILayoutConstraintAxisVertical;
    applyStack.spacing = 14.0;
    applyStack.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:applyStack];

    [applyStack addArrangedSubview:[self createActionCardWithTitle:@"Restart backboardd (apply)"
                                                           detail:@"Kills backboardd; SpringBoard and this app restart with it"
                                                       symbolName:@"arrow.clockwise.circle.fill"
                                                        tintColor:[UIColor systemIndigoColor]
                                                           action:@selector(onRestartUITapped)]];

    [applyStack addArrangedSubview:[self createActionCardWithTitle:@"Clear Metal strikes"
                                                           detail:@"Re-arms the device for processes that crashed with it"
                                                       symbolName:@"xmark.circle.fill"
                                                        tintColor:[UIColor systemTealColor]
                                                           action:@selector(onClearStrikesTapped)]];

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
        
        [switchHeader.topAnchor constraintEqualToAnchor:gpuCard.bottomAnchor constant:28],
        [switchHeader.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:24],
        [switchHeader.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],

        [switchCard.topAnchor constraintEqualToAnchor:switchHeader.bottomAnchor constant:10],
        [switchCard.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [switchCard.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],

        [applyStack.topAnchor constraintEqualToAnchor:switchCard.bottomAnchor constant:14],
        [applyStack.leadingAnchor constraintEqualToAnchor:frameGuide.leadingAnchor constant:20],
        [applyStack.trailingAnchor constraintEqualToAnchor:frameGuide.trailingAnchor constant:-20],

        [powerHeader.topAnchor constraintEqualToAnchor:applyStack.bottomAnchor constant:28],
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
    [self refreshStatus];
}

#pragma mark - Switches

- (UIView *)switchRowWithTitle:(NSString *)title detail:(NSString *)detail control:(UIView *)control {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLbl.textColor = [UIColor labelColor];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:titleLbl];

    UILabel *detailLbl = [[UILabel alloc] init];
    detailLbl.text = detail;
    detailLbl.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    detailLbl.textColor = [UIColor secondaryLabelColor];
    detailLbl.numberOfLines = 0;
    detailLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:detailLbl];

    control.translatesAutoresizingMaskIntoConstraints = NO;
    [control setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:control];

    [NSLayoutConstraint activateConstraints:@[
        [titleLbl.topAnchor constraintEqualToAnchor:row.topAnchor],
        [titleLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:control.leadingAnchor constant:-12],
        [detailLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:2],
        [detailLbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [detailLbl.trailingAnchor constraintLessThanOrEqualToAnchor:control.leadingAnchor constant:-12],
        [detailLbl.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [control.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [control.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

- (UIView *)createSwitchCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    // Metal: all | probes | off  (helper: metal all|probes|off = phone-metal.sh on "*"|probes|off)
    UILabel *metalTitle = [[UILabel alloc] init];
    metalTitle.text = @"Metal (NegroniMetal)";
    metalTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    metalTitle.textColor = [UIColor labelColor];
    [stack addArrangedSubview:metalTitle];

    self.metalControl = [[UISegmentedControl alloc] initWithItems:@[@"All processes", @"Probes only", @"Off"]];
    [self.metalControl addTarget:self action:@selector(onMetalChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.metalControl];

    UILabel *metalDetail = [[UILabel alloc] init];
    metalDetail.text = @"All: every new process gets the Metal device (strikes cleared). Probes: metalprobe and m2vtest only. Off: the off sentinel, CPU rasterization.";
    metalDetail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    metalDetail.textColor = [UIColor secondaryLabelColor];
    metalDetail.numberOfLines = 0;
    [stack addArrangedSubview:metalDetail];

    self.glSwitch = [[UISwitch alloc] init];
    [self.glSwitch addTarget:self action:@selector(onGLChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self switchRowWithTitle:@"GL for backboardd"
                                                detail:@"NegroniGL EAGL gate (/var/db/negronigl/clients)"
                                               control:self.glSwitch]];

    self.glAppsSwitch = [[UISwitch alloc] init];
    [self.glAppsSwitch addTarget:self action:@selector(onGLAppsChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self switchRowWithTitle:@"GL for apps"
                                                detail:@"NegroniGL.bundle apps gate (apps.local = * -backboardd)"
                                               control:self.glAppsSwitch]];

    self.glFinishSwitch = [[UISwitch alloc] init];
    [self.glFinishSwitch addTarget:self action:@selector(onGLFinishChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self switchRowWithTitle:@"glFinish on every flush"
                                                detail:@"Default off: glFlush + the kernel swap fence"
                                               control:self.glFinishSwitch]];

    self.switchStatusLabel = [[UILabel alloc] init];
    self.switchStatusLabel.text = @"Reading switch files...";
    self.switchStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.switchStatusLabel.textColor = [UIColor tertiaryLabelColor];
    self.switchStatusLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.switchStatusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

// Read the switch files through the helper and show them. This is the file state only: the
// plugins read the files once at process start, so a running backboardd may differ until
// "Restart backboardd (apply)".
- (void)refreshStatus {
    NSString *out = nil;
    int rc = run_helper(@"status", nil, &out);
    if (rc != 0) {
        self.switchStatusLabel.text = [NSString stringWithFormat:@"Helper status failed (exit %d): %@", rc,
                                       [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        self.metalControl.enabled = NO;
        self.glSwitch.enabled = self.glAppsSwitch.enabled = self.glFinishSwitch.enabled = NO;
        return;
    }
    NSDictionary<NSString *, NSString *> *st = parse_status(out);
    self.updatingControls = YES;
    NSString *metal = st[@"METAL"] ?: @"";
    if ([metal isEqualToString:@"all"]) self.metalControl.selectedSegmentIndex = 0;
    else if ([metal isEqualToString:@"probes"]) self.metalControl.selectedSegmentIndex = 1;
    else if ([metal isEqualToString:@"off"]) self.metalControl.selectedSegmentIndex = 2;
    else self.metalControl.selectedSegmentIndex = UISegmentedControlNoSegment;   // custom list or no file
    self.metalControl.enabled = YES;
    self.glSwitch.on = [st[@"GL"] isEqualToString:@"on"];
    self.glSwitch.enabled = YES;
    BOOL bundle = [st[@"GLAPPS_BUNDLE"] isEqualToString:@"1"];
    self.glAppsSwitch.on = [st[@"GLAPPS"] isEqualToString:@"on"];
    self.glAppsSwitch.enabled = bundle;
    self.glFinishSwitch.on = [st[@"GLFINISH"] isEqualToString:@"on"];
    self.glFinishSwitch.enabled = YES;
    self.updatingControls = NO;

    NSString *clients = [st[@"METAL_CLIENTS"] length] ? st[@"METAL_CLIENTS"] : @"(none)";
    self.switchStatusLabel.text = [NSString stringWithFormat:
        @"Files: metal clients \"%@\"%@, strikes %@ • gl clients \"%@\"%@ • apps %@%@ • backboardd pid %@\n"
        @"File state only: whether the running backboardd has a Metal device is not known here. Changes apply to processes started after them (Restart backboardd).",
        clients, [st[@"METAL_OFF"] isEqualToString:@"1"] ? @" + off sentinel" : @"",
        st[@"METAL_STRIKES"] ?: @"?",
        st[@"GL_CLIENTS"] ?: @"", [st[@"GL_OFF"] isEqualToString:@"1"] ? @" + off sentinel" : @"",
        bundle ? ([st[@"GLAPPS_LIST"] length] ? st[@"GLAPPS_LIST"] : @"(empty list)") : @"(no NegroniGL.bundle)",
        [st[@"GLFINISH"] isEqualToString:@"on"] ? @", glFinish on" : @"",
        st[@"BACKBOARDD_PID"] ?: @"?"];
}

// Run VERB ARG through the helper; on a non-zero exit show the helper's message. Then re-read the files.
- (void)applyVerb:(NSString *)verb arg:(NSString *)arg {
    NSString *out = nil;
    int rc = run_helper(verb, arg, &out);
    if (rc != 0) {
        NSString *msg = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (rc == 3) msg = @"This kernel has no kern.negroni_reboot_mode (patch 0213). Use Volume Up + Volume Down + Power, or op10tool ctl bootloader.";
        else if (rc == 4) msg = @"The helper refused the caller (the app must be /Applications/XNUtils.app/XNUtils).";
        else if (rc == 5) msg = @"The helper is not setuid root (install: root:mobile 4750).";
        else if (rc == 6) msg = @"NegroniGL.bundle is not installed in /System/Library/Extensions.";
        else if (rc < 0) msg = [NSString stringWithFormat:@"Could not start %s (errno %d).", HELPER_PATH, -rc];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ %@ failed (exit %d)", verb, arg ?: @"", rc]
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    [self refreshStatus];
}

- (void)onMetalChanged:(UISegmentedControl *)c {
    if (self.updatingControls) return;
    NSArray *modes = @[@"all", @"probes", @"off"];
    if (c.selectedSegmentIndex < 0 || c.selectedSegmentIndex >= (NSInteger)modes.count) return;
    [self applyVerb:@"metal" arg:modes[c.selectedSegmentIndex]];
}

- (void)onGLChanged:(UISwitch *)sw {
    if (self.updatingControls) return;
    [self applyVerb:@"gl" arg:sw.on ? @"on" : @"off"];
}

- (void)onGLAppsChanged:(UISwitch *)sw {
    if (self.updatingControls) return;
    [self applyVerb:@"glapps" arg:sw.on ? @"on" : @"off"];
}

- (void)onGLFinishChanged:(UISwitch *)sw {
    if (self.updatingControls) return;
    [self applyVerb:@"glfinish" arg:sw.on ? @"on" : @"off"];
}

- (void)onClearStrikesTapped {
    [self applyVerb:@"strikes-clear" arg:nil];
}

- (void)onRestartUITapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart backboardd?"
                                                                   message:@"backboardd is killed; SpringBoard and this app restart with it. The new processes read the switch files."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart backboardd" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self applyVerb:@"restart-ui" arg:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
        [self applyVerb:@"bootloader" arg:nil];   // helper: kern.negroni_reboot_mode=bootloader, sync, reboot
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onRebootTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart Device?"
                                                                   message:@"All running processes will be terminated and the system will reboot."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self applyVerb:@"restart" arg:nil];      // helper: sync, then RB_AUTOBOOT
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)onPowerOffTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Shut Down?"
                                                                   message:@"The device will cleanly unmount volumes and power off."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Shut Down" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self applyVerb:@"shutdown" arg:nil];     // helper: sync, then RB_HALT
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
