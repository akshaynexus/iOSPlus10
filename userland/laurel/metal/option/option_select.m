/*
 * NegroniMetal.bundle's executable on the iOS 26 root: the Metal.framework plug-in class. It picks one stack, loads it, and hands over. The stacks are separate images (options/<name>/NegroniMetal) because
 * their Objective-C classes have the same names, so one process never loads two. Setting: /private/var/db/negronimetal/option, or BUNDLE/option.local for a sandboxed process; first word; read once, at the process's
 * device open. Changing it needs the process to restart: XNUtils offers Restart UI. Rule: option_rule.h, its files: option_store.h. Docs: docs/laurel_sprout/ios26-metal.md section 10.
 * Lines: LAUREL METAL: on: stack NAME ...  |  LAUREL METAL: off: <reason>: stack default. The native stack's own: LAUREL METAL NATIVE: off: <reason> (docs/laurel_sprout/ios26-native-metal.md).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "option_store.h"

#define DB       "/private/var/db/negronimetal"
#define SETTING  DB "/option"
#define STACK_D  DB "/stack"
#define ACTIVE   STACK_D "/active"
#define IMPL     "NegroniMTLDeviceImpl"

static char g_bundle[512];

static void line(const char *text)
{
	char buf[700];
	int n = snprintf(buf, sizeof(buf), "NMTL[%d %s]: %s\n", getpid(), getprogname() ?: "?", text);
	int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (fd >= 0) {
		(void)!write(fd, buf, (size_t)n);
		close(fd);
	}
	fd = open(DB "/metal.log", O_WRONLY | O_APPEND);
	if (fd >= 0) {
		(void)!write(fd, buf, (size_t)n);
		close(fd);
	}
}

static int known(const char *name)
{
	char p[640];
	for (const char *c = name; *c; c++) {
		if (!((*c >= 'a' && *c <= 'z') || (*c >= '0' && *c <= '9') || *c == '-'))
			return 0;
	}
	snprintf(p, sizeof(p), "%s/options/%s/NegroniMetal", g_bundle, name);
	return access(p, R_OK) == 0;
}

/* the tag of a failure line: an owner greps the stack's own word */
static const char *tag_of(const char *name)
{
	return strcmp(name, "native") == 0 ? "LAUREL METAL NATIVE" : "LAUREL METAL";
}

static bool read_word(const char *path, char *out, size_t size)
{
	FILE *f = fopen(path, "r");
	char fmt[16];
	if (f == NULL)
		return false;
	snprintf(fmt, sizeof(fmt), "%%%zus", size - 1);
	const bool got = fscanf(f, fmt, out) == 1;
	fclose(f);
	return got;
}

@interface _MTLDevice : NSObject
@end
@interface NegroniMTLDevice : _MTLDevice
- (id)initWithAcceleratorPort:(mach_port_t)port;
@end

@implementation NegroniMTLDevice
- (id)initWithAcceleratorPort:(mach_port_t)port
{
	/* this object is dropped for the stack's device; -[_MTLDevice dealloc] needs it initialised (as in NegroniMetal.mm) */
	if (!(self = [super init]))
		return nil;
	static id device;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		strlcpy(g_bundle, [[NSBundle bundleForClass:[NegroniMTLDevice class]] bundlePath].UTF8String ?: "/nonexistent", sizeof(g_bundle));
		const bool compositor = !strcmp(getprogname() ?: "", "backboardd");
		char wanted[32] = "", local[640], why[320], note[160];
		snprintf(local, sizeof(local), "%s/option.local", g_bundle);
		if (!read_word(SETTING, wanted, sizeof(wanted)))
			(void)read_word(local, wanted, sizeof(wanted));
		FILE *f;
		if (compositor) {
			/* the mode of helper_ios26.c stack_dir(): a root process can come here first; as mobile both calls only fail: the parent folder and this one are root's */
			mkdir(STACK_D, 01777);
			chmod(STACK_D, 01777);
		}
		char wanted_file[640];
		snprintf(wanted_file, sizeof(wanted_file), "%s/options/%s/NegroniMetal", g_bundle, wanted);
		const char *pick = nmtl_option_select(STACK_D, wanted, wanted_file, known, compositor, why, sizeof(why), note, sizeof(note));
		char say[440];
		if (note[0] != 0) {
			snprintf(say, sizeof(say), "%s: %s", tag_of(wanted), note);
			line(say);
		}
		/* one line a start, from the compositor; a client follows it */
		if (why[0] != 0 && compositor) {
			snprintf(say, sizeof(say), "%s: off: %s: stack default", tag_of(wanted), why);
			line(say);
		} else if (compositor) {
			snprintf(say, sizeof(say), "LAUREL METAL: on: stack %s (setting %s)", pick, wanted[0] ? wanted : "absent");
			line(say);
		}
		if (compositor && (f = fopen(ACTIVE, "w")) != NULL) {
			fprintf(f, "%s %s\n", pick, why);
			fclose(f);
		}
		setenv("NEGRONIMETAL_OPTION", pick, 1);
		char path[640];
		snprintf(path, sizeof(path), "%s/options/%s/NegroniMetal", g_bundle, pick);
		void *image = dlopen(path, RTLD_NOW | RTLD_LOCAL);
		if (image == NULL && strcmp(pick, NMTL_OPTION_DEFAULT) != 0) {
			/* nothing of the other stack came in: the default can still load in this process */
			snprintf(say, sizeof(say), "%s: off: option %s does not load: %.160s: stack default", tag_of(pick), pick, dlerror());
			line(say);
			pick = NMTL_OPTION_DEFAULT;
			setenv("NEGRONIMETAL_OPTION", pick, 1);
			if (compositor && (f = fopen(ACTIVE, "w")) != NULL) {
				fprintf(f, "%s it does not load\n", pick);
				fclose(f);
			}
			if (compositor)
				(void)nmtl_store_write(STACK_D, "failed", "it does not load\n");
			snprintf(path, sizeof(path), "%s/options/%s/NegroniMetal", g_bundle, pick);
			image = dlopen(path, RTLD_NOW | RTLD_LOCAL);
		}
		Class impl = image ? objc_getClass(IMPL) : Nil;
		if (impl == Nil) {
			snprintf(say, sizeof(say), "LAUREL METAL: off: stack %s has no class %s: %.160s: no device", pick, IMPL, image ? "" : dlerror());
			line(say);
			return;
		}
		id fresh = [impl alloc];
		device = [fresh initWithAcceleratorPort:port];
		if (device == nil && compositor && strcmp(pick, NMTL_OPTION_DEFAULT) != 0) {
			/* the classes are in this process now, so the default cannot come in beside them: the next start takes it. launchd restarts backboardd at once */
			/* on the disk before the exit: the next start, in this boot or after a reset, reads it */
			if (nmtl_store_write(STACK_D, "failed", "no device\n") != 0)
				line("LAUREL METAL: stack/failed cannot be written");
			snprintf(say, sizeof(say), "%s: off: stack %s gave no device: restart on stack default", tag_of(pick), pick);
			line(say);
			_exit(0);
		}
	});
	return device;
}
@end
