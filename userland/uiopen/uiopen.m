/*
 * uiopen: open a URL on the running phone from SSH (the stock iOS has no `uiopen`; toybox has none).
 * Safari (or the app that owns the scheme) opens it in the foreground, which lets the Mac drive
 * WebGL / WebGPU test pages without a tap (docs/metal-management.md "Safari test steps").
 *
 *   uiopen https://get.webgl.org
 *
 * Run as root over SSH. Uses the private LSApplicationWorkspace API (MobileCoreServices, looked up
 * at run time), as userland/rebootapp/pmregister.m. Signed with uiopen.entitlements. Built and
 * pushed by scripts/net/phone-open-url.sh. Our own code.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options;
- (BOOL)openURL:(NSURL *)url;
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc != 2) {
			fprintf(stderr, "usage: uiopen URL\n");
			return 2;
		}
		dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
		Class ws = NSClassFromString(@"LSApplicationWorkspace");
		if (ws == nil) {
			fprintf(stderr, "uiopen: LSApplicationWorkspace not found\n");
			return 1;
		}
		NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
		if (url == nil) {
			fprintf(stderr, "uiopen: bad URL\n");
			return 2;
		}
		LSApplicationWorkspace *w = [ws defaultWorkspace];
		BOOL ok = NO;
		if ([w respondsToSelector:@selector(openSensitiveURL:withOptions:)])
			ok = [w openSensitiveURL:url withOptions:@{}];
		if (!ok && [w respondsToSelector:@selector(openURL:)])
			ok = [w openURL:url];
		printf("uiopen: %s -> %s\n", argv[1], ok ? "ok" : "FAILED");
		return ok ? 0 : 1;
	}
}
