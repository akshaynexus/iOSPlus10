/*
 * XNUtils on the Mi A3 (docs/laurel_sprout/xnutils.md). UIKit only: no Metal, no blur, no symbol images, so that the screen draws
 * with Metal off and with CoreAnimation's software renderer. The layout has no fixed width: it follows the 360 x 780 pt screen and
 * the safe area (38 pt top, 29 pt bottom, docs/laurel_sprout/rtc-statusbar.md).
 *
 * Data: a helper process (stream.m) that lives only while this screen is visible. Hidden = no timer, no helper, nothing polled.
 */
#import <signal.h>
#import "vc.h"

#define REFRESH_S   2.0

@implementation ViewController

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		_open = [NSMutableSet set];
		_sections = @[];
		_note = @"Starting the helper...";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 44;
	self.tableView.alwaysBounceVertical = YES;
	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];

	title.text = @"  XNUtils";
	title.font = [UIFont boldSystemFontOfSize:28];
	self.tableView.tableHeaderView = title;
#ifdef XT_IOS26
	self.metal = [[UISegmentedControl alloc] initWithItems:@[ @"On", @"Off (CPU)" ]];
#else
	self.metal = [[UISegmentedControl alloc] initWithItems:@[ @"Auto", @"All", @"Probes", @"Off" ]];
#endif
	[self.metal addTarget:self action:@selector(metalChanged:) forControlEvents:UIControlEventValueChanged];
	self.metal.translatesAutoresizingMaskIntoConstraints = NO;
	self.metalCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	self.metalCell.selectionStyle = UITableViewCellSelectionStyleNone;
	[self.metalCell.contentView addSubview:self.metal];
	UIView *cv = self.metalCell.contentView;

	[NSLayoutConstraint activateConstraints:@[
		[self.metal.topAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.topAnchor],
		[self.metal.bottomAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.bottomAnchor],
		[self.metal.leadingAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.leadingAnchor],
		[self.metal.trailingAnchor constraintEqualToAnchor:cv.layoutMarginsGuide.trailingAnchor],
	]];
	self.gl = [[UISwitch alloc] init];
	[self.gl addTarget:self action:@selector(glChanged:) forControlEvents:UIControlEventValueChanged];
	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	[nc addObserver:self selector:@selector(startLive) name:UIApplicationDidBecomeActiveNotification object:nil];
	[nc addObserver:self selector:@selector(stopLive) name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self startLive];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	[self stopLive];
}

#pragma mark - Live data: only while visible

- (void)startLive {
	if (self.timer != nil) {
		return;
	}
	self.stream = [[XTStream alloc] initWithDelegate:self];
	[self.stream start];
	self.timer = [NSTimer scheduledTimerWithTimeInterval:REFRESH_S target:self selector:@selector(tick) userInfo:nil repeats:YES];
	[self tick];
}

- (void)stopLive {
	[self.timer invalidate];
	self.timer = nil;
	[self.stream stop];
	self.stream = nil;
}

- (void)tick {
	[self.stream ask];
}

- (void)stream:(XTStream *)stream gotSections:(NSArray<XTSection *> *)sections {
	if (stream != self.stream) {
		return;
	}
	self.sections = sections;
	self.note = [NSString stringWithFormat:@"Live, every %.0f s; nothing runs when this app is hidden.", REFRESH_S];
	[self syncControls];
	/* no reload under a finger: a change of row heights would move the list. The next tick catches up. */
	if (!self.tableView.isDragging && !self.tableView.isDecelerating) {
		[self.tableView reloadData];
	}
}

- (void)stream:(XTStream *)stream failed:(NSString *)why {
	if (stream != self.stream) {
		return;
	}
	self.note = [NSString stringWithFormat:@"No live data: %@", why];
	[self.tableView reloadData];
}

- (void)syncControls {
	for (XTSection *s in self.sections) {
		if ([s.title isEqualToString:@"Metal"]) {
			NSString *mode = [s value:@"Mode"] ?: @"";
#ifdef XT_IOS26
			NSArray *names = @[ @"all", @"off" ];
#else
			NSArray *names = @[ @"auto", @"all", @"probes", @"off" ];
#endif
			NSInteger at = UISegmentedControlNoSegment;

			for (NSUInteger i = 0; i < names.count; i++) {
				if ([mode hasPrefix:names[i]]) {
					at = (NSInteger)i;
				}
			}
			self.metal.selectedSegmentIndex = at;
		} else if ([s.title isEqualToString:@"GL"]) {
			self.gl.on = [[s value:@"Switch file"] hasPrefix:@"on"];
		}
	}
}

#pragma mark - Controls

- (void)runVerb:(NSString *)verb arg:(NSString *)arg {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *text = nil;
		int rc = xt_run_helper(verb, arg, &text);

		dispatch_async(dispatch_get_main_queue(), ^{
			if (rc != 0) {
				[self show:[NSString stringWithFormat:@"%@ %@ failed (exit %d)", verb, arg ?: @"", rc] text:xt_exit_text(rc, text)];
			}
		});
	});
}

- (void)show:(NSString *)title text:(NSString *)text {
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];

	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)metalChanged:(UISegmentedControl *)c {
#ifdef XT_IOS26
	NSArray *modes = @[ @"all", @"off" ];
#else
	NSArray *modes = @[ @"auto", @"all", @"probes", @"off" ];
#endif

	if (c.selectedSegmentIndex >= 0 && c.selectedSegmentIndex < (NSInteger)modes.count) {
		[self runVerb:@"metal" arg:modes[(NSUInteger)c.selectedSegmentIndex]];
	}
}

- (void)glChanged:(UISwitch *)s {
	[self runVerb:@"gl" arg:s.on ? @"on" : @"off"];
}

- (void)confirm:(NSString *)title text:(NSString *)text verb:(NSString *)verb {
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];

	[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
		[self runVerb:verb arg:nil];
	}]];
	[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)action:(NSInteger)n {
	switch (n) {
	case 0: [self runVerb:@"strikes-clear" arg:nil]; break;
	case 1: [self confirm:@"Restart UI" text:@"backboardd stops. SpringBoard and this app restart with it." verb:@"restart-ui"]; break;
	case 2:
		UIPasteboard.generalPasteboard.string = xt_report_text(self.sections);
		[self show:@"Report copied" text:[NSString stringWithFormat:@"%lu sections.", (unsigned long)self.sections.count]];
		break;
	case 3: {
		UIActivityViewController *v = [[UIActivityViewController alloc] initWithActivityItems:@[ xt_report_text(self.sections) ] applicationActivities:nil];

		[self presentViewController:v animated:YES completion:nil];
		break;
	}
	case 4: [self confirm:@"Restart" text:@"All processes stop and the phone restarts." verb:@"restart"]; break;
	case 5: [self confirm:@"Reboot to bootloader" text:@"The phone restarts into fastboot." verb:@"bootloader"]; break;
	default: [self confirm:@"Shut down" text:@"The phone powers off." verb:@"shutdown"]; break;
	}
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.rootViewController = [[ViewController alloc] init];
	[self.window makeKeyAndVisible];
	return YES;
}

@end

int
main(int argc, char *argv[])
{
	signal(SIGPIPE, SIG_IGN);       /* a helper that ended: write() fails, the app goes on */
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
	}
}
