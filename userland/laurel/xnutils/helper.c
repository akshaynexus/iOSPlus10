/*
 * powermenu-helper for the Mi A3 (laurel_sprout): the root part of XNUtils.app (docs/laurel_sprout/xnutils.md). Same place, same caller
 * check as the negroni helper (userland/rebootapp/powermenu-helper.c), with this port's paths:
 *
 *   powermenu-helper restart|shutdown|bootloader|check     power (kernel 2003 + 2018; kern.laurel_reboot_mode)
 *   powermenu-helper metal auto|all|probes|off             the Metal gate's files (below)
 *   powermenu-helper gl on|off                             /private/var/db/laurelgl/off (bbd_wrap.c reads it at backboardd's start)
 *   powermenu-helper strikes-clear                         delete the Metal dead-man strikes
 *   powermenu-helper restart-ui                            kill -9 backboardd (launchd starts it; SpringBoard and the apps follow)
 *   powermenu-helper stream                                a report for each byte on stdin; ends at EOF (the app hides or dies)
 *   powermenu-helper stats | report                        one report, 1 s long (tab lines | plain text), for SSH
 *
 * Install: /usr/local/libexec/powermenu-helper, root:mobile 4750. Caller: real uid 0, or uid 501 with the parent process
 * /Applications/XNUtils.app/XNUtils; others get exit 4. Strict verbs, no path or environment from the caller, starts no program.
 * The caller check says "mobile code to root, for these verbs only" (userland/rebootapp/README.md "Privileges").
 *
 * metal:  auto    list with the gate's mark + the probes, in both list files, off file removed: the gate decides at the next boot
 *         all     own list "* -backboardd -mediaserverd" (the gate's wide list, never changed by the gate)
 *         probes  own list, the probes only
 *         off     the off file: no process gets a device
 * Exit codes: 0 ok / 1 a call failed / 2 usage / 3 no reboot-mode sysctl / 4 caller refused / 5 not setuid root.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "collect.h"
#include "report.h"

#define RB_AUTOBOOT 0     /* <sys/reboot.h>, not in the iPhoneOS SDK */
#define RB_HALT     0x08
#define MOBILE_UID  501
#define APP_PATH    "/Applications/XNUtils.app/XNUtils"
#define PATH_BUF    4096
#define MODE_SYSCTL "kern.laurel_reboot_mode"
/* root-add-gpu.sh moves Apple's backboardd here; the wrapper execs it: same process name, this path */
#define BBD_REAL    "/usr/libexec/real/backboardd"
#define BBD_STOCK   "/usr/libexec/backboardd"

int proc_pidpath(int pid, void *buffer, uint32_t buffersize); /* libproc, not in the SDK */

static int
caller_allowed(void)
{
	uid_t uid = getuid();

	if (uid == 0) {
		return 1;
	}
	if (uid != MOBILE_UID) {
		fprintf(stderr, "powermenu-helper: uid %u not allowed\n", (unsigned)uid);
		return 0;
	}
	char path[PATH_BUF] = "";
	pid_t ppid = getppid();

	if (proc_pidpath(ppid, path, sizeof(path)) <= 0) {
		fprintf(stderr, "powermenu-helper: no path for parent pid %d (errno %d)\n", (int)ppid, errno);
		return 0;
	}
	if (strcmp(path, APP_PATH) != 0) {
		fprintf(stderr, "powermenu-helper: parent %s is not %s\n", path, APP_PATH);
		return 0;
	}
	return 1;
}

static int
do_reboot(int how)
{
	sync();
	sleep(1);
	sync();
	syscall(SYS_reboot, how, NULL);
	perror("powermenu-helper: reboot");
	return 1;
}

static int
do_bootloader(void)
{
	size_t len = 0;

	if (sysctlbyname(MODE_SYSCTL, NULL, &len, NULL, 0) != 0) {
		fprintf(stderr, "powermenu-helper: this kernel has no " MODE_SYSCTL ": not rebooting\n");
		return 3;
	}
	const char *mode = "bootloader";

	if (sysctlbyname(MODE_SYSCTL, NULL, NULL, (void *)mode, strlen(mode) + 1) != 0) {
		perror("powermenu-helper: set reboot mode");
		return 1;
	}
	char got[32] = "";

	len = sizeof(got);
	if (sysctlbyname(MODE_SYSCTL, got, &len, NULL, 0) != 0 || strcmp(got, mode) != 0) {
		fprintf(stderr, "powermenu-helper: " MODE_SYSCTL " reads back \"%s\": not rebooting\n", got);
		return 1;
	}
	return do_reboot(RB_AUTOBOOT);
}

static int
ensure_dir(const char *dir, mode_t mode)
{
	struct stat st;

	if (stat(dir, &st) == 0) {
		return S_ISDIR(st.st_mode) ? 0 : -1;
	}
	if (mkdir(dir, mode) != 0 || chown(dir, 0, 0) != 0 || chmod(dir, mode) != 0) {
		fprintf(stderr, "powermenu-helper: %s: %s\n", dir, strerror(errno));
		return -1;
	}
	return 0;
}

/* TEXT into PATH at once: PATH.new in the same folder (root:wheel 644), then rename */
static int
write_file(const char *path, const char *text)
{
	char tmp[PATH_BUF];

	snprintf(tmp, sizeof(tmp), "%s.new", path);
	unlink(tmp);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);

	if (fd < 0) {
		fprintf(stderr, "powermenu-helper: create %s: %s\n", tmp, strerror(errno));
		return -1;
	}
	size_t n = strlen(text);
	ssize_t w = n ? write(fd, text, n) : 0;

	if (w < 0 || (size_t)w != n || fchown(fd, 0, 0) != 0 || fchmod(fd, 0644) != 0 || fsync(fd) != 0) {
		fprintf(stderr, "powermenu-helper: write %s: %s\n", tmp, strerror(errno));
		close(fd);
		unlink(tmp);
		return -1;
	}
	close(fd);
	if (rename(tmp, path) != 0) {
		fprintf(stderr, "powermenu-helper: rename %s: %s\n", path, strerror(errno));
		unlink(tmp);
		return -1;
	}
	return 0;
}

static int
remove_file(const char *path)
{
	if (unlink(path) != 0 && errno != ENOENT) {
		fprintf(stderr, "powermenu-helper: remove %s: %s\n", path, strerror(errno));
		return -1;
	}
	return 0;
}

/* the same text in both list files: the plug-in reads clients.local in sandboxed processes, which cannot read /var/db */
static int
write_lists(const char *text)
{
	if (write_file(XT_METAL_CLIENTS, text) != 0) {
		return -1;
	}
	struct stat st;

	return stat(XT_METAL_BUNDLE, &st) == 0 ? write_file(XT_METAL_LOCAL, text) : 0;
}

static int
do_metal(const char *what)
{
	char text[512];

	if (ensure_dir(XT_DB, 0755) != 0) {
		return 1;
	}
	if (strcmp(what, "off") == 0) {
		return write_file(XT_METAL_OFF, "powermenu-helper metal off\n") ? 1 : 0;
	}
	if (strcmp(what, "auto") == 0) {
		snprintf(text, sizeof(text), XT_GATE_MARK ": XNUtils asked for the gate at the next boot\n" XT_METAL_PROBES "\n");
		/* the record of an earlier verdict stays out of the way of a new test */
		if (remove_file(XT_METAL_GATE) != 0) {
			return 1;
		}
	} else {
		snprintf(text, sizeof(text), "# XNUtils, own list: the gate leaves it alone\n%s\n", strcmp(what, "all") == 0 ? XT_METAL_WIDE : XT_METAL_PROBES);
	}
	return (write_lists(text) != 0 || remove_file(XT_METAL_OFF) != 0) ? 1 : 0;
}

static int
do_gl(int on)
{
	if (on) {
		return remove_file(XT_GL_OFF) ? 1 : 0;
	}
	if (ensure_dir(XT_GL_DIR, 0755) != 0) {
		return 1;
	}
	return write_file(XT_GL_OFF, "powermenu-helper gl off\n") ? 1 : 0;
}

static int
do_strikes_clear(void)
{
	DIR *d = opendir(XT_METAL_STRIKES);
	int n = 0;

	if (d == NULL) {
		printf("STRIKES_CLEARED=0\n");
		return 0;
	}
	for (struct dirent *e; (e = readdir(d)) != NULL;) {
		char p[PATH_BUF];
		struct stat st;

		if (e->d_name[0] == '.') {
			continue;
		}
		snprintf(p, sizeof(p), XT_METAL_STRIKES "/%s", e->d_name);
		if (lstat(p, &st) == 0 && S_ISREG(st.st_mode) && unlink(p) == 0) {
			n++;
		}
	}
	closedir(d);
	printf("STRIKES_CLEARED=%d\n", n);
	return 0;
}

/* The pid of the real backboardd: both paths, the wrapper execs and keeps the pid. */
static pid_t
find_backboardd(void)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;

	if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) {
		return 0;
	}
	len += len / 4;
	struct kinfo_proc *procs = malloc(len);

	if (procs == NULL || sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
		free(procs);
		return 0;
	}
	pid_t found = 0;

	for (size_t i = 0; i < len / sizeof(struct kinfo_proc) && found == 0; i++) {
		char path[PATH_BUF] = "";

		if (strcmp(procs[i].kp_proc.p_comm, "backboardd") == 0 && proc_pidpath(procs[i].kp_proc.p_pid, path, sizeof(path)) > 0 &&
		    (strcmp(path, BBD_REAL) == 0 || strcmp(path, BBD_STOCK) == 0)) {
			found = procs[i].kp_proc.p_pid;
		}
	}
	free(procs);
	return found;
}

static int
do_restart_ui(void)
{
	pid_t pid = find_backboardd();

	if (pid <= 0) {
		fprintf(stderr, "powermenu-helper: no backboardd process found\n");
		return 1;
	}
	sync();
	if (kill(pid, SIGKILL) != 0) {
		perror("powermenu-helper: kill backboardd");
		return 1;
	}
	printf("KILLED=%d\n", (int)pid);
	return 0;
}

static struct rp report;

static int
one_report(int plain)
{
	char *text = collect();

	if (text == NULL) {
		fprintf(stderr, "powermenu-helper: no memory\n");
		return 1;
	}
	report.out = stdout;
	report.plain = plain;
	rp_parse(&report, text);
	rp_all(&report);
	return 0;
}

/* The app writes one byte for each report and closes the pipe when it hides. No timer here: nothing runs between two reports. */
static int
do_stream(void)
{
	char c;

	while (read(STDIN_FILENO, &c, 1) == 1) {
		if (one_report(0) != 0) {
			return 1;
		}
	}
	return 0;
}

static int
do_once(int plain)
{
	(void)collect();        /* the first sample: rates and shares need two */
	sleep(1);
	return one_report(plain);
}

static int
usage(void)
{
	fprintf(stderr, "usage: powermenu-helper restart|shutdown|bootloader|check|strikes-clear|restart-ui|stream|stats|report\n"
	    "       powermenu-helper metal auto|all|probes|off | gl on|off\n");
	return 2;
}

int
main(int argc, char **argv)
{
	if (argc != 2 && argc != 3) {
		return usage();
	}
	const char *verb = argv[1], *arg = argc == 3 ? argv[2] : NULL;
	int metal = arg != NULL && !strcmp(verb, "metal") &&
	    (!strcmp(arg, "auto") || !strcmp(arg, "all") || !strcmp(arg, "probes") || !strcmp(arg, "off"));
	int gl = arg != NULL && !strcmp(verb, "gl") && (!strcmp(arg, "on") || !strcmp(arg, "off"));
	static const char *const plain[] = { "restart", "shutdown", "bootloader", "check", "strikes-clear", "restart-ui", "stream", "stats", "report" };
	int plain_ok = 0;

	for (size_t i = 0; arg == NULL && i < sizeof(plain) / sizeof(plain[0]); i++) {
		plain_ok |= !strcmp(verb, plain[i]);
	}
	if (!metal && !gl && !plain_ok) {
		return usage();
	}
	if (geteuid() != 0) {
		fprintf(stderr, "powermenu-helper: not setuid root (install: root:mobile 4750)\n");
		return 5;
	}
	if (!caller_allowed()) {
		return 4;
	}
	umask(022);
	if (metal) {
		return do_metal(arg);
	}
	if (gl) {
		return do_gl(!strcmp(arg, "on"));
	}
	if (!strcmp(verb, "restart")) return do_reboot(RB_AUTOBOOT);
	if (!strcmp(verb, "shutdown")) return do_reboot(RB_HALT);
	if (!strcmp(verb, "bootloader")) return do_bootloader();
	if (!strcmp(verb, "strikes-clear")) return do_strikes_clear();
	if (!strcmp(verb, "restart-ui")) return do_restart_ui();
	if (!strcmp(verb, "stream")) return do_stream();
	if (!strcmp(verb, "stats")) return do_once(0);
	if (!strcmp(verb, "report")) return do_once(1);
	size_t len = 0;
	int have = sysctlbyname(MODE_SYSCTL, NULL, &len, NULL, 0) == 0;

	printf("powermenu-helper: caller ok; bootloader: %s\n", have ? MODE_SYSCTL : "not supported (no " MODE_SYSCTL " in this kernel)");
	return have ? 0 : 3;
}
