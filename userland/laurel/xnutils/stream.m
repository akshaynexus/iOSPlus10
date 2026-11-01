/* The helper process of the XNUtils screen: `powermenu-helper stream`, one report for each byte we send (report.h has the format). */
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import "stream.h"

extern char **environ;
#define HELPER_PATH "/usr/local/libexec/powermenu-helper"

@implementation XTRow
@end

@implementation XTSection
- (instancetype)init {
	if ((self = [super init])) {
		_rows = [NSMutableArray array];
	}
	return self;
}
- (NSString *)value:(NSString *)key {
	for (XTRow *r in self.rows) {
		if ([r.key isEqualToString:key]) {
			return r.value;
		}
	}
	return nil;
}
@end

/* a pipe from the helper's stdout + stderr, a pipe to its stdin if toChild is set */
static pid_t
spawn_helper(NSArray<NSString *> *args, int *fromChild, int *toChild, int *err)
{
	int out[2], in[2] = { -1, -1 };

	if (pipe(out) != 0 || (toChild != NULL && pipe(in) != 0)) {
		*err = errno;
		return -1;
	}
	posix_spawn_file_actions_t fa;

	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, out[1], STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&fa, out[1], STDERR_FILENO);
	if (toChild != NULL) {
		posix_spawn_file_actions_adddup2(&fa, in[0], STDIN_FILENO);
		posix_spawn_file_actions_addclose(&fa, in[1]);
	}
	posix_spawn_file_actions_addclose(&fa, out[0]);
	posix_spawn_file_actions_addclose(&fa, out[1]);
	char *argv[4] = { (char *)HELPER_PATH, NULL, NULL, NULL };

	for (NSUInteger i = 0; i < args.count && i < 2; i++) {
		argv[i + 1] = (char *)args[i].UTF8String;
	}
	pid_t pid = -1;
	int rc = posix_spawn(&pid, HELPER_PATH, &fa, NULL, argv, environ);

	posix_spawn_file_actions_destroy(&fa);
	close(out[1]);
	if (toChild != NULL) {
		close(in[0]);
		*toChild = in[1];
	}
	*fromChild = out[0];
	if (rc != 0) {
		*err = rc;
		close(out[0]);
		if (toChild != NULL) {
			close(in[1]);
		}
		return -1;
	}
	return pid;
}

int
xt_run_helper(NSString *verb, NSString *arg, NSString **text)
{
	int from = -1, err = 0;
	pid_t pid = spawn_helper(arg != nil ? @[ verb, arg ] : @[ verb ], &from, NULL, &err);

	if (pid < 0) {
		if (text != NULL) {
			*text = @"";
		}
		return -err;
	}
	NSMutableData *d = [NSMutableData data];
	char b[1024];

	for (ssize_t n; (n = read(from, b, sizeof(b))) > 0;) {
		[d appendBytes:b length:(NSUInteger)n];
	}
	close(from);
	if (text != NULL) {
		*text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
	}
	int status = 0;

	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

NSString *
xt_exit_text(int rc, NSString *text)
{
	switch (rc) {
	case 3: return @"This kernel has no kern.laurel_reboot_mode. Use Volume Down + Power, or op10tool ctl bootloader.";
	case 4: return @"The helper refused the caller (the app must be /Applications/XNUtils.app/XNUtils).";
	case 5: return @"The helper is not setuid root (install: root:mobile 4750).";
	default: break;
	}
	if (rc < 0) {
		return [NSString stringWithFormat:@"Could not start %s (errno %d).", HELPER_PATH, -rc];
	}
	return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *
xt_report_text(NSArray<XTSection *> *sections)
{
	NSMutableString *t = [NSMutableString stringWithFormat:@"XNUtils report, Mi A3, %@\n", NSDate.date];

	for (XTSection *s in sections) {
		[t appendFormat:@"\n== %@: %@%@%@\n", s.title, s.state, s.reason.length ? @": " : @"", s.reason];
		for (XTRow *r in s.rows) {
			[t appendFormat:@"  %@: %@%@\n", r.key, r.value, r.age >= 0 ? [NSString stringWithFormat:@" (%ld s ago)", (long)r.age] : @""];
		}
	}
	return t;
}

@interface XTStream ()
@property (weak, nonatomic) id<XTStreamDelegate> delegate;
@end

@implementation XTStream {
	int _to;
	BOOL _waiting, _stopped;
}

- (instancetype)initWithDelegate:(id<XTStreamDelegate>)delegate {
	if ((self = [super init])) {
		_delegate = delegate;
		_to = -1;
	}
	return self;
}

- (void)start {
	int from = -1, err = 0;
	pid_t pid = spawn_helper(@[ @"stream" ], &from, &_to, &err);

	if (pid < 0) {
		[self.delegate stream:self failed:xt_exit_text(-err, @"")];
		return;
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[self read:from pid:pid];
	});
}

- (void)ask {
	char c = 1;

	if (_to >= 0 && !_waiting && write(_to, &c, 1) == 1) {
		_waiting = YES;
	}
}

- (void)stop {
	_stopped = YES;
	if (_to >= 0) {
		close(_to);     /* the helper's read() returns 0: it ends, and the reader below ends with it */
		_to = -1;
	}
}

/* Reader thread until the helper ends. Sections are made here and handed over whole. */
- (void)read:(int)from pid:(pid_t)pid {
	NSMutableData *line = [NSMutableData data];
	NSMutableArray<XTSection *> *now = [NSMutableArray array];
	NSMutableString *other = [NSMutableString string];
	char b[8192];

	for (ssize_t n; (n = read(from, b, sizeof(b))) > 0;) {
		for (ssize_t i = 0; i < n; i++) {
			if (b[i] != '\n') {
				[line appendBytes:&b[i] length:1];
				continue;
			}
			NSString *l = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] ?: @"";

			line.length = 0;
			NSArray<NSString *> *f = [l componentsSeparatedByString:@"\t"];

			if ([l isEqualToString:@"%"]) {
				NSArray *done = now;

				now = [NSMutableArray array];
				dispatch_async(dispatch_get_main_queue(), ^{
					self->_waiting = NO;
					if (!self->_stopped) {
						[self.delegate stream:self gotSections:done];
					}
				});
			} else if (f.count == 4 && [f[0] isEqualToString:@"#"]) {
				XTSection *s = [[XTSection alloc] init];

				s.title = f[1];
				s.state = f[2];
				s.reason = f[3];
				[now addObject:s];
			} else if (f.count == 4 && [f[0] isEqualToString:@"="]) {
				XTRow *r = [[XTRow alloc] init];

				r.key = f[1];
				r.value = f[2];
				r.age = f[3].integerValue;
				[now.lastObject.rows addObject:r];
			} else {
				[other appendFormat:@"%@\n", l];
			}
		}
	}
	close(from);
	int status = 0;

	waitpid(pid, &status, 0);
	int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

	dispatch_async(dispatch_get_main_queue(), ^{
		if (!self->_stopped) {
			[self.delegate stream:self failed:[NSString stringWithFormat:@"the helper ended (exit %d). %@", rc, xt_exit_text(rc, other)]];
		}
	});
}

@end
