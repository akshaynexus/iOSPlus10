/*
 * XNUtils on the iOS 26 root: the switches of the Metal path, and one fixed scene that measures the one in use (docs/laurel_sprout/ios26-metal.md section 10).
 * The app does not link Metal: it draws with UIKit, as any app, and the compositor does the work. Client numbers: intervals of CADisplayLink here. Present numbers: backboardd's frames over the same seconds (helper bench-begin, bench-end).
 * Each run is one line of Documents/xnutils-bench.tsv. A run with no compositor answer has no present numbers, never a made-up number.
 */
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "bench.h"
#import "bench_core.h"
#import "stream.h"

#define WARM_S    2
#define RUN_S     12
#define NUM_CARDS 60
#define MAX_TICKS 4096

static NSDictionary<NSString *, NSString *> *
parse_kv(NSString *text)
{
	NSMutableDictionary *d = [NSMutableDictionary dictionary];

	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		NSRange eq = [line rangeOfString:@"="];

		if (eq.location != NSNotFound) {
			d[[line substringToIndex:eq.location]] = [line substringFromIndex:eq.location + 1];
		}
	}
	return d;
}

static NSString *
bench_path(void)
{
	NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];

	[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
	return [dir stringByAppendingPathComponent:@"xnutils-bench.tsv"];
}

#pragma mark - The scene

@interface XTBenchScene : UIViewController
@property (copy, nonatomic) void (^done)(struct xt_client client, NSString *presents);
@end

@implementation XTBenchScene {
	CADisplayLink *_link;
	NSMutableArray<CALayer *> *_cards;
	double _ms[MAX_TICKS];
	size_t _ticks;
	CFTimeInterval _last, _t0;
	BOOL _running, _ended;
	UILabel *_label;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	CAGradientLayer *g = [CAGradientLayer layer];

	g.frame = self.view.bounds;
	g.colors = @[ (id)UIColor.systemIndigoColor.CGColor, (id)UIColor.systemTealColor.CGColor, (id)UIColor.systemOrangeColor.CGColor ];
	[self.view.layer addSublayer:g];
	_cards = [NSMutableArray arrayWithCapacity:NUM_CARDS];
	for (int i = 0; i < NUM_CARDS; i++) {
		CALayer *c = [CALayer layer];

		c.bounds = CGRectMake(0, 0, 64, 64);
		c.cornerRadius = 12;
		c.opacity = 0.75f;
		c.backgroundColor = [UIColor colorWithHue:(CGFloat)i / NUM_CARDS saturation:0.8 brightness:0.9 alpha:1].CGColor;
		[self.view.layer addSublayer:c];
		[_cards addObject:c];
	}
	UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];

	bar.frame = CGRectMake(0, self.view.bounds.size.height * 5 / 6, self.view.bounds.size.width, self.view.bounds.size.height / 6);
	bar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
	[self.view addSubview:bar];
	_label = [[UILabel alloc] initWithFrame:CGRectInset(bar.bounds, 16, 16)];
	_label.numberOfLines = 0;
	_label.text = @"Warming up. Do not touch the screen.";
	[bar.contentView addSubview:_label];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, WARM_S * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		[self begin];
	});
}

- (void)begin {
	_label.text = [NSString stringWithFormat:@"Measuring for %d s.", RUN_S];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *text = nil;

		xt_run_helper(@"bench-begin", nil, &text);
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_ticks = 0;
			self->_last = 0;
			self->_running = YES;
		});
		/* the plug-in looks each 500 ms: its start is at most this late; it reports its own seconds */
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RUN_S * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			[self end];
		});
	});
}

- (void)end {
	if (_ended) {
		return;
	}
	_ended = YES;
	_running = NO;
	[_link invalidate];
	_link = nil;
	struct xt_client client = xt_client_summary(_ms, _ticks);

	_label.text = @"Waiting for the compositor's numbers.";
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *text = nil;

		xt_run_helper(@"bench-end", nil, &text);
		dispatch_async(dispatch_get_main_queue(), ^{
			self.done(client, text ?: @"");
		});
	});
}

- (void)tick:(CADisplayLink *)link {
	const CFTimeInterval now = link.timestamp;

	if (_t0 == 0) {
		_t0 = now;
	}
	if (_running) {
		if (_last != 0 && _ticks < MAX_TICKS) {
			_ms[_ticks++] = (now - _last) * 1000.0;
		}
		_last = now;
	}
	/* a fixed function of time: the same picture at the same second in each run */
	const CGSize size = self.view.bounds.size;
	const double t = now - _t0;

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for (NSUInteger i = 0; i < _cards.count; i++) {
		const double f = (double)i / NUM_CARDS * 2 * M_PI;

		_cards[i].position = CGPointMake(size.width * (0.5 + 0.45 * sin(t * 0.9 + f * 3)), size.height * (0.5 + 0.45 * cos(t * 0.7 + f * 2)));
	}
	[CATransaction commit];
}

@end

#pragma mark - The screen

@implementation XTBenchController {
	NSDictionary<NSString *, NSString *> *_state;
	NSArray<NSString *> *_runs;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Metal options and bench";
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
	[self reload];
}

- (void)close {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
	NSString *all = [NSString stringWithContentsOfFile:bench_path() encoding:NSUTF8StringEncoding error:NULL] ?: @"";
	NSMutableArray *rows = [NSMutableArray array];

	for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
		if (line.length && ![line hasPrefix:@"date\t"]) {
			[rows insertObject:line atIndex:0];     /* newest first */
		}
	}
	_runs = rows;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *text = nil;
		const int rc = xt_run_helper(@"metalstate", nil, &text);

		dispatch_async(dispatch_get_main_queue(), ^{
			self->_state = rc == 0 ? parse_kv(text ?: @"") : @{};
			[self.tableView reloadData];
		});
	});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
	return 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
	return section == 0 ? 3 : section == 1 ? 2 : (NSInteger)_runs.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
	return section == 0 ? @"Options" : section == 1 ? @"Actions" : @"Runs, newest first; tap to copy all";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
	return section == 0 ? @"Stack and Turnip mode apply after Restart UI. A stack that fails its check at start returns to Default by itself; choose it again to retry." : nil;
}

static NSString *
run_text(NSString *line)
{
	NSArray<NSString *> *c = [line componentsSeparatedByString:@"\t"];

	if (c.count < 15) {
		return line;
	}
	return [NSString stringWithFormat:@"app %@ fps, %@/%@/%@ ms; compositor %@ fps, %@/%@/%@ ms, %@ frames", c[6], c[7], c[8], c[9], c[10], c[11], c[12], c[13], c[14]];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

	c.textLabel.numberOfLines = 0;
	c.detailTextLabel.numberOfLines = 0;
	c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	if (ip.section == 0) {
		c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		if (ip.row == 0) {
			NSString *why = _state[@"WHY"];

			c.textLabel.text = [NSString stringWithFormat:@"Metal stack: %@", _state[@"OPTION"] ?: @"?"];
			c.detailTextLabel.text = why.length ? [NSString stringWithFormat:@"Running: %@. %@", _state[@"ACTIVE"], why] : [NSString stringWithFormat:@"Running: %@", _state[@"ACTIVE"] ?: @"?"];
		} else if (ip.row == 1) {
			c.textLabel.text = [NSString stringWithFormat:@"Turnip mode: %@", _state[@"TUMODE"] ?: @"?"];
			c.detailTextLabel.text = @"auto: Turnip decides. sysmem: no tiles. gmem: tiles.";
		} else {
			c.textLabel.text = [NSString stringWithFormat:@"Glass: %@", _state[@"GLASS"] ?: @"?"];
			c.detailTextLabel.text = @"bypass: no live capture behind blur. live: full capture. Within 5 s, no restart.";
		}
	} else if (ip.section == 1) {
		c.textLabel.textColor = UIColor.systemBlueColor;
		c.textLabel.text = ip.row == 0 ? [NSString stringWithFormat:@"Run the bench (%d s)", WARM_S + RUN_S] : @"Restart UI (backboardd)";
	} else {
		NSArray<NSString *> *f = [_runs[(NSUInteger)ip.row] componentsSeparatedByString:@"\t"];

		c.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
		c.textLabel.text = f.count >= 6 ? [NSString stringWithFormat:@"%@ %@, Turnip %@, glass %@", f[0], f[1], f[3], f[4]] : @"?";
		c.detailTextLabel.font = [UIFont systemFontOfSize:12];
		c.detailTextLabel.text = run_text(_runs[(NSUInteger)ip.row]);
	}
	return c;
}

- (void)choose:(NSString *)title verb:(NSString *)verb names:(NSArray<NSString *> *)names restart:(BOOL)restart {
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];

	for (NSString *name in names) {
		[a addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
			[self set:verb arg:name restart:restart];
		}]];
	}
	[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)say:(NSString *)title text:(NSString *)text {
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];

	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)set:(NSString *)verb arg:(NSString *)arg restart:(BOOL)restart {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *text = nil;
		const int rc = xt_run_helper(verb, arg, &text);

		dispatch_async(dispatch_get_main_queue(), ^{
			[self reload];
			if (rc != 0) {
				[self say:[NSString stringWithFormat:@"%@ %@ failed (exit %d)", verb, arg, rc] text:xt_exit_text(rc, text)];
			} else if (restart) {
				[self askRestart];
			}
		});
	});
}

- (void)askRestart {
	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart UI" message:@"This applies after backboardd restarts. SpringBoard and this app restart with it." preferredStyle:UIAlertControllerStyleAlert];

	[a addAction:[UIAlertAction actionWithTitle:@"Restart UI" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSString *text = nil;

			xt_run_helper(@"restart-ui", nil, &text);
		});
	}]];
	[a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)runBench {
	NSDictionary *state = _state;
	XTBenchScene *scene = [[XTBenchScene alloc] init];

	scene.modalPresentationStyle = UIModalPresentationFullScreen;
	__weak XTBenchController *weak = self;
	scene.done = ^(struct xt_client client, NSString *presents) {
		[weak dismissViewControllerAnimated:YES completion:^{
			[weak record:client presents:parse_kv(presents) state:state];
		}];
	};
	[self presentViewController:scene animated:YES completion:nil];
}

- (void)record:(struct xt_client)client presents:(NSDictionary<NSString *, NSString *> *)p state:(NSDictionary<NSString *, NSString *> *)state {
	NSDateFormatter *df = [[NSDateFormatter alloc] init];

	df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
	df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
	NSString *none = @"-", *frames = p[@"PRESENTS"];
	const BOOL have = frames != nil && ![frames isEqualToString:@"none"];
	NSString *line = [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\tcards%d+blur\t%.1f\t%.1f\t%.1f\t%.1f\t%@\t%@\t%@\t%@\t%@\n", [df stringFromDate:NSDate.date], have ? p[@"STACK"] : (state[@"ACTIVE"] ?: @"?"), state[@"OPTION"] ?: @"?",
	    state[@"TUMODE"] ?: @"?", state[@"GLASS"] ?: @"?", NUM_CARDS, client.fps, client.p50, client.p95, client.max, have ? p[@"PRESENT_FPS"] : none, have ? p[@"PRESENT_P50"] : none, have ? p[@"PRESENT_P95"] : none,
	    have ? p[@"PRESENT_MAX"] : none, have ? frames : none];
	NSString *path = bench_path();
	NSFileHandle *h = nil;

	if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
		[@XT_BENCH_HEADER writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	}
	h = [NSFileHandle fileHandleForWritingAtPath:path];
	[h seekToEndOfFile];
	[h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
	[h closeFile];
	[self reload];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:NO];
	if (ip.section == 0) {
		if (ip.row == 0) {
			[self choose:@"Metal stack" verb:@"metaloption" names:@[ @"default", @"hot" ] restart:YES];
		} else if (ip.row == 1) {
			[self choose:@"Turnip mode" verb:@"tumode" names:@[ @"auto", @"sysmem", @"gmem" ] restart:YES];
		} else {
			[self choose:@"Live glass" verb:@"liveglass" names:@[ @"on", @"off" ] restart:YES];
		}
	} else if (ip.section == 1) {
		if (ip.row == 0) {
			[self runBench];
		} else {
			[self askRestart];
		}
	} else {
		NSString *all = [NSString stringWithContentsOfFile:bench_path() encoding:NSUTF8StringEncoding error:NULL] ?: @"";

		UIPasteboard.generalPasteboard.string = all;
		[self say:@"Runs copied" text:[NSString stringWithFormat:@"%lu runs as tab-separated text.", (unsigned long)_runs.count]];
	}
}

@end
