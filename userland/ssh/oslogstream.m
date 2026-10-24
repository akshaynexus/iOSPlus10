/*
 * oslogstream: live unified log on the phone, like `log stream` on macOS (iOS ships no `log` tool).
 *
 *   oslogstream [-l] [-t SECONDS] [-g TEXT] [PROCESS...]
 *     PROCESS  only processes whose name contains one of these words
 *     -g TEXT  only entries whose message contains TEXT
 *     -l       also info and debug entries (default: default, error, fault)
 *     -t N     stop after N seconds (default: run until killed)
 * Output, one line per entry:  HH:MM:SS.mmm TYPE process[pid] (sender) message
 *
 * Uses the private LoggingSupport.framework live store (served by diagnosticd), loaded at run
 * time. Entitlements: userland/ssh/oslogstream.entitlements (logging stream/diagnostic keys).
 * Approach from ios-flame phone/tools/oslog.m (MIT, NWylynko/ios-flame); this file is our own code.
 * Used by scripts/net/phone-log.sh.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* The parts of the private classes we call (LoggingSupport, iOS 16). */
@interface OSLogEventLiveStore : NSObject
+ (id)liveLocalStore;
- (void)prepareWithCompletionHandler:(void (^)(id source, NSError *error))handler;
@end
@interface OSLogEventLiveStream : NSObject
- (id)initWithLiveSource:(id)source;
- (void)setEventHandler:(void (^)(id event))handler;
- (void)setInvalidationHandler:(void (^)(int reason, id position))handler;
- (void)setFlags:(unsigned long long)flags;
- (void)activate;
@end
@interface OSLogEventProxy : NSObject
- (NSString *)composedMessage;
- (NSString *)process;
- (NSString *)sender;
- (int)processIdentifier;
- (unsigned long long)logType;
- (struct timeval *)unixDate;
@end

static const char *
type_tag(unsigned long long t)
{
	switch (t) {
	case 0x00: return "Df";
	case 0x01: return "In";
	case 0x02: return "Db";
	case 0x10: return "Er";
	case 0x11: return "Ft";
	default: return "--";
	}
}

static void
usage(void)
{
	fprintf(stderr, "usage: oslogstream [-l] [-t SECONDS] [-g TEXT] [PROCESS...]\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		int seconds = 0, all_levels = 0, c;
		const char *grep = NULL;
		while ((c = getopt(argc, argv, "lt:g:h")) != -1) {
			switch (c) {
			case 'l': all_levels = 1; break;
			case 't': seconds = atoi(optarg); break;
			case 'g': grep = optarg; break;
			default: usage();
			}
		}
		NSMutableArray<NSString *> *names = [NSMutableArray array];
		for (int i = optind; i < argc; i++) {
			[names addObject:@(argv[i])];
		}
		NSString *needle = grep ? @(grep) : nil;
		setvbuf(stdout, NULL, _IOLBF, 0);

		if (dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW) == NULL) {
			fprintf(stderr, "oslogstream: LoggingSupport: %s\n", dlerror());
			return 1;
		}
		Class store_class = NSClassFromString(@"OSLogEventLiveStore");
		Class stream_class = NSClassFromString(@"OSLogEventLiveStream");
		if (store_class == nil || stream_class == nil) {
			fprintf(stderr, "oslogstream: OSLogEventLiveStore/OSLogEventLiveStream missing\n");
			return 1;
		}

		__block OSLogEventLiveStream *stream = nil;
		[[store_class liveLocalStore] prepareWithCompletionHandler:^(id source, NSError *error) {
			if (source == nil) {
				fprintf(stderr, "oslogstream: no live source: %s\n", error.description.UTF8String);
				exit(1);
			}
			stream = [[stream_class alloc] initWithLiveSource:source];
			[stream setFlags:all_levels ? 0x7 : 0];	/* 0x1 info, 0x2 debug, 0x4 */
			[stream setEventHandler:^(OSLogEventProxy *e) {
				NSString *proc = e.process ?: @"?";
				if (names.count) {
					BOOL match = NO;
					for (NSString *n in names) {
						if ([proc rangeOfString:n].location != NSNotFound) {
							match = YES;
							break;
						}
					}
					if (!match) {
						return;
					}
				}
				NSString *msg = e.composedMessage ?: @"";
				if (needle && [msg rangeOfString:needle].location == NSNotFound) {
					return;
				}
				struct timeval *tv = e.unixDate;
				time_t sec = tv ? tv->tv_sec : time(NULL);
				struct tm tm;
				localtime_r(&sec, &tm);
				printf("%02d:%02d:%02d.%03d %s %s[%d] (%s) %s\n", tm.tm_hour, tm.tm_min, tm.tm_sec,
				    tv ? (int)(tv->tv_usec / 1000) : 0, type_tag(e.logType), proc.UTF8String,
				    e.processIdentifier, (e.sender ?: @"").UTF8String, msg.UTF8String);
			}];
			[stream setInvalidationHandler:^(int reason, id position) {
				fprintf(stderr, "oslogstream: stream ended (reason %d)\n", reason);
				exit(0);
			}];
			[stream activate];
		}];
		if (seconds > 0) {
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
		} else {
			[[NSRunLoop currentRunLoop] run];
		}
	}
	return 0;
}
