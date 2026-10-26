/*
 * pmregister: register (or unregister) an app in /Applications with LaunchServices on a running
 * phone, so SpringBoard shows it without a new root (scripts/net/phone-add-powermenu.sh).
 * A new root does not need it: the first boot builds the app database from /Applications.
 *
 *   pmregister /Applications/XNUtils.app          register as a system app
 *   pmregister -u /Applications/XNUtils.app       unregister (also used for the old PowerMenu.app)
 *
 * Run as root. Uses the private LSApplicationWorkspace API (MobileCoreServices, looked up at run
 * time), as bergamota tools/sweetnet/sweetuicache.m (sideloaded apps in /Applications).
 * Signed with pmregister.entitlements. Installed as /usr/local/bin/pmregister (root-add-powermenu.sh
 * and phone-add-powermenu.sh). Our own code.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)registerApplication:(NSURL *)url;
- (BOOL)unregisterApplication:(NSURL *)url;
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		int unregister = argc == 3 && strcmp(argv[1], "-u") == 0;
		if (argc != 2 && !unregister) {
			fprintf(stderr, "usage: pmregister [-u] /Applications/App.app\n");
			return 2;
		}
		NSString *path = [NSString stringWithUTF8String:argv[argc - 1]];
		dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
		Class ws = NSClassFromString(@"LSApplicationWorkspace");
		if (ws == nil) {
			fprintf(stderr, "pmregister: LSApplicationWorkspace not found\n");
			return 1;
		}
		LSApplicationWorkspace *w = [ws defaultWorkspace];
		NSURL *url = [NSURL fileURLWithPath:path];
		if (unregister) {
			BOOL ok = [w unregisterApplication:url];
			printf("pmregister: unregister %s -> %s\n", path.UTF8String, ok ? "ok" : "FAILED");
			return ok ? 0 : 1;
		}
		NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
		NSString *bid = info[@"CFBundleIdentifier"];
		if (bid == nil) {
			fprintf(stderr, "pmregister: %s/Info.plist has no CFBundleIdentifier\n", path.UTF8String);
			return 1;
		}
		NSDictionary *dict = @{
			@"ApplicationType": @"System",
			@"CFBundleIdentifier": bid,
			@"CodeInfoIdentifier": bid,
			@"CompatibilityState": @0,
			@"IsDeletable": @NO,
			@"Path": path,
			@"SignerOrganization": @"Apple Inc.",
			@"SignerIdentity": @"Apple iPhone OS Application Signing",
		};
		BOOL ok = [w registerApplicationDictionary:dict];
		const char *how = "registerApplicationDictionary";
		if (!ok) {
			ok = [w registerApplication:url];
			how = "registerApplication";
		}
		printf("pmregister: register %s (%s) with %s -> %s\n", path.UTF8String, bid.UTF8String, how,
		    ok ? "ok" : "FAILED");
		return ok ? 0 : 1;
	}
}
