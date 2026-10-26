/*
 * powermenu-helper: the root part of XNUtils.app (formerly PowerMenu.app; userland/rebootapp/README.md).
 *
 *   powermenu-helper restart|shutdown|bootloader|check          power
 *   powermenu-helper status                                     KEY=VALUE lines (file state of the switches)
 *   powermenu-helper metal all|probes|off                       NegroniMetal switch  (= scripts/metal/phone-metal.sh on "*"|probes|off)
 *   powermenu-helper gl on|off                                  NegroniGL for backboardd (= scripts/gpu/phone-gl.sh on|off)
 *   powermenu-helper glapps on|off                              NegroniGL for apps (= phone-gl.sh apps on "* -backboardd"|off)
 *   powermenu-helper glfinish on|off                            glFinish on every flush (= phone-gl.sh finish on|off)
 *   powermenu-helper strikes-clear                              delete the dead-man strikes (= phone-metal.sh strikes)
 *   powermenu-helper restart-ui                                 kill -9 backboardd; SpringBoard restarts with it
 *                                                               (= phone-metal.sh restart). The plugins read the switch
 *                                                               files once, at process start.
 *
 * Installed as /usr/local/libexec/powermenu-helper, owner root, group mobile (501), mode 4750:
 * setuid root, and only root and members of group mobile can run it. The app runs as mobile and
 * spawns it; reboot(2), the reboot-mode sysctl, the root-owned switch files and the kill of
 * backboardd need euid 0.
 *
 * Caller check: real uid 0 (an SSH root shell) is allowed. Real uid 501 is allowed only when the
 * parent process is /Applications/XNUtils.app/XNUtils. Every other caller gets exit code 4.
 * The tool accepts exactly the verbs above (strict compare, no other spelling). It reads no
 * environment variable, starts no other program and takes no path from the caller: every path
 * is a constant below. Switch files are written atomically (a temporary file in the same
 * directory, then rename) with the owner and mode the root hooks set (root:wheel 644; the
 * strikes and cache directories 1777, the config directories 755).
 *
 *   restart     sync, reboot(RB_AUTOBOOT)  (kernel 0211: reason of kern.negroni_reboot_mode,
 *               default normal = 0, PSCI SYSTEM_RESET)
 *   shutdown    sync, reboot(RB_HALT)      (kernel 0211: negroni_power_off, PSCI SYSTEM_OFF)
 *   bootloader  set kern.negroni_reboot_mode (or kern.sweet_reboot_mode) = "bootloader", read it
 *               back, sync, reboot(RB_AUTOBOOT): kernel patch 0213 writes reason 2 (ABL fastboot).
 *               If the kernel has no such sysctl (before 0213): exit 3, no reboot.
 *   check       caller check and kernel check only; prints the result, does not reboot.
 *
 * The switch files (docs/metal-management.md sections 1, 2, 6; docs/gpu-userland.md "The switch"):
 *   /private/var/db/negronimetal/clients   names, "*" = all, "-NAME" = never; "metalprobe m2vtest" = probes only
 *   /private/var/db/negronimetal/off       sentinel: no process gets a Metal device
 *   /private/var/db/negronimetal/strikes/  one file per process that crashed with a device
 *   /private/var/db/negronigl/clients      the backboardd EAGL gate (same syntax), + /off sentinel, + /finish
 *   /System/Library/Extensions/NegroniGL.bundle/apps.local   the apps gate, + off, + finish
 *
 * Exit codes: 0 ok (check: bootloader supported) / 1 reboot(2), sysctl, a file write or the kill failed /
 * 2 usage / 3 this kernel cannot select the bootloader / 4 caller not allowed /
 * 5 not setuid root (the install is wrong) / 6 NegroniGL.bundle is not installed (glapps). Our own code.
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
#include <time.h>
#include <unistd.h>

#define RB_AUTOBOOT 0     /* <sys/reboot.h>, not in the iPhoneOS SDK */
#define RB_HALT     0x08
#define MOBILE_UID  501
#define APP_PATH    "/Applications/XNUtils.app/XNUtils"
#define PATH_BUF    4096  /* PROC_PIDPATHINFO_MAXSIZE */

#define METAL_DIR     "/private/var/db/negronimetal"
#define METAL_CLIENTS METAL_DIR "/clients"
#define METAL_OFF     METAL_DIR "/off"
#define METAL_STRIKES METAL_DIR "/strikes"
#define METAL_CACHE   METAL_DIR "/cache"
#define GL_DIR        "/private/var/db/negronigl"
#define GL_CLIENTS    GL_DIR "/clients"
#define GL_OFF        GL_DIR "/off"
#define GL_FINISH     GL_DIR "/finish"
#define GL_BUNDLE     "/System/Library/Extensions/NegroniGL.bundle"
#define GLAPPS_LIST   GL_BUNDLE "/apps.local"
#define GLAPPS_OFF    GL_BUNDLE "/off"
#define GLAPPS_FINISH GL_BUNDLE "/finish"
#define BACKBOARDD    "/usr/libexec/backboardd"

#define PROBES_LIST   "metalprobe m2vtest"
#define APPS_DEFAULT  "* -backboardd"
#define LIST_BUF      4096

int proc_pidpath(int pid, void *buffer, uint32_t buffersize); /* libproc, not in the SDK */

static const char *mode_names[] = { "kern.negroni_reboot_mode", "kern.sweet_reboot_mode" };

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

/* ---- power ------------------------------------------------------------------------------- */

/* The name of the reboot-mode sysctl of this kernel, or NULL. */
static const char *
mode_sysctl(void)
{
	for (size_t i = 0; i < sizeof(mode_names) / sizeof(mode_names[0]); i++) {
		size_t len = 0;
		if (sysctlbyname(mode_names[i], NULL, &len, NULL, 0) == 0) {
			return mode_names[i];
		}
	}
	return NULL;
}

static int
do_reboot(int how)
{
	sync();
	sleep(1);
	sync();
	/* reboot(2) is not declared by the iOS SDK headers; the syscall is the same on iOS. */
	syscall(SYS_reboot, how, NULL);
	perror("powermenu-helper: reboot");
	return 1;
}

static int
do_bootloader(void)
{
	const char *name = mode_sysctl();
	if (name == NULL) {
		fprintf(stderr, "powermenu-helper: this kernel has no kern.negroni_reboot_mode: not rebooting\n");
		return 3;
	}
	const char *mode = "bootloader";
	if (sysctlbyname(name, NULL, NULL, (void *)mode, strlen(mode) + 1) != 0) {
		perror("powermenu-helper: set reboot mode");
		return 1;
	}
	char got[32] = "";
	size_t len = sizeof(got);
	if (sysctlbyname(name, got, &len, NULL, 0) != 0 || strcmp(got, mode) != 0) {
		fprintf(stderr, "powermenu-helper: %s reads back \"%s\", not \"%s\": not rebooting\n", name, got, mode);
		return 1;
	}
	return do_reboot(RB_AUTOBOOT);
}

/* ---- files ------------------------------------------------------------------------------- */

static int
exists(const char *path)
{
	struct stat st;
	return lstat(path, &st) == 0;
}

/* Create DIR (one level) with MODE if it is missing; an existing one keeps its owner and mode. */
static int
ensure_dir(const char *dir, mode_t mode)
{
	struct stat st;
	if (stat(dir, &st) == 0) {
		return S_ISDIR(st.st_mode) ? 0 : -1;
	}
	if (mkdir(dir, mode) != 0) {
		fprintf(stderr, "powermenu-helper: mkdir %s: %s\n", dir, strerror(errno));
		return -1;
	}
	if (chown(dir, 0, 0) != 0 || chmod(dir, mode) != 0) { /* chmod after chown: the umask and setgid bits */
		fprintf(stderr, "powermenu-helper: chown/chmod %s: %s\n", dir, strerror(errno));
		return -1;
	}
	return 0;
}

/* Write TEXT to PATH atomically: PATH.new in the same directory (root:wheel 0644), then rename. */
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

/* The list file as one line: the tokens of every non-comment line, space separated (the plugins'
 * syntax: names, "*", "-NAME"). Missing file: "" and 0 returned; 1 = present. */
static int
read_list(const char *path, char *out, size_t outlen)
{
	out[0] = '\0';
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		return 0;
	}
	char line[LIST_BUF];
	size_t used = 0;
	while (fgets(line, sizeof(line), f) != NULL) {
		if (line[0] == '#') {
			continue;
		}
		char *save = NULL;
		for (char *tok = strtok_r(line, " \t\r\n", &save); tok != NULL; tok = strtok_r(NULL, " \t\r\n", &save)) {
			size_t tl = strlen(tok);
			if (used + tl + 2 > outlen) {
				break;
			}
			if (used) {
				out[used++] = ' ';
			}
			memcpy(out + used, tok, tl + 1);
			used += tl;
		}
	}
	fclose(f);
	return 1;
}

/* 1 when the space-separated LIST has the token WORD. */
static int
has_token(const char *list, const char *word)
{
	size_t wl = strlen(word);
	const char *p = list;
	while ((p = strstr(p, word)) != NULL) {
		int start_ok = (p == list || p[-1] == ' ');
		int end_ok = (p[wl] == '\0' || p[wl] == ' ');
		if (start_ok && end_ok) {
			return 1;
		}
		p += wl;
	}
	return 0;
}

/* LIST without the token WORD (in place). */
static void
drop_token(char *list, const char *word)
{
	char out[LIST_BUF] = "";
	size_t used = 0;
	char *save = NULL;
	for (char *tok = strtok_r(list, " ", &save); tok != NULL; tok = strtok_r(NULL, " ", &save)) {
		if (strcmp(tok, word) == 0) {
			continue;
		}
		size_t tl = strlen(tok);
		if (used + tl + 2 > sizeof(out)) {
			break;
		}
		if (used) {
			out[used++] = ' ';
		}
		memcpy(out + used, tok, tl + 1);
		used += tl;
	}
	strcpy(list, out);
}

static void
add_token(char *list, const char *word)
{
	if (strlen(list) + strlen(word) + 2 > LIST_BUF) {
		return;
	}
	if (list[0]) {
		strcat(list, " ");
	}
	strcat(list, word);
}

/* Write a list file as the host scripts do: a comment line with the writer and the time, then the list. */
static int
write_list(const char *path, const char *list)
{
	char text[LIST_BUF + 128];
	char when[32] = "";
	time_t now = time(NULL);
	struct tm tm;
	if (localtime_r(&now, &tm) != NULL) {
		strftime(when, sizeof(when), "%Y-%m-%dT%H:%M:%S", &tm);
	}
	/* One token per line (review 2026-10-27): scripts/gpu/phone-gl.sh and phone-metal.sh edit the file with
	 * grep -x line by line; both plugins read tokens across lines. */
	char lines[LIST_BUF + 8];
	size_t n = 0;
	for (const char *w = list; *w && n + 2 < sizeof(lines); ) {
		if (*w == ' ') { w++; continue; }
		while (*w && *w != ' ' && n + 2 < sizeof(lines)) lines[n++] = *w++;
		lines[n++] = '\n';
	}
	lines[n] = 0;
	snprintf(text, sizeof(text), "# powermenu-helper (XNUtils), %s\n%s", when, lines);
	return write_file(path, text);
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

/* Delete every regular file in DIR (the strikes). Returns the count, or -1. */
static int
clear_dir(const char *dir)
{
	DIR *d = opendir(dir);
	if (d == NULL) {
		return errno == ENOENT ? 0 : -1;
	}
	int n = 0;
	struct dirent *e;
	while ((e = readdir(d)) != NULL) {
		if (e->d_name[0] == '.') {
			continue;
		}
		char p[PATH_BUF];
		snprintf(p, sizeof(p), "%s/%s", dir, e->d_name);
		struct stat st;
		if (lstat(p, &st) == 0 && S_ISREG(st.st_mode) && unlink(p) == 0) {
			n++;
		}
	}
	closedir(d);
	return n;
}

static int
count_dir(const char *dir)
{
	DIR *d = opendir(dir);
	if (d == NULL) {
		return 0;
	}
	int n = 0;
	struct dirent *e;
	while ((e = readdir(d)) != NULL) {
		if (e->d_name[0] != '.') {
			n++;
		}
	}
	closedir(d);
	return n;
}

/* ---- the switches ------------------------------------------------------------------------ */

static int
metal_dirs(void)
{
	return ensure_dir(METAL_DIR, 0755) || ensure_dir(METAL_STRIKES, 01777) || ensure_dir(METAL_CACHE, 01777) ? 1 : 0;
}

/* metal all|probes|off: as scripts/metal/phone-metal.sh on "*" | probes | off */
static int
do_metal(const char *what)
{
	if (metal_dirs()) {
		return 1;
	}
	if (strcmp(what, "off") == 0) {
		return write_file(METAL_OFF, "powermenu-helper metal off\n") ? 1 : 0;
	}
	const char *list = strcmp(what, "all") == 0 ? "*" : PROBES_LIST;
	if (write_list(METAL_CLIENTS, list) || remove_file(METAL_OFF)) {
		return 1;
	}
	if (strcmp(what, "all") == 0 && clear_dir(METAL_STRIKES) < 0) {
		return 1;
	}
	return 0;
}

/* gl on|off: backboardd into / out of the negronigl gate. "*" in the gate: off adds "-backboardd"
 * (the never form), on removes it. Both remove the off sentinel, as scripts/gpu/phone-gl.sh. */
static int
do_gl(int on)
{
	if (ensure_dir(GL_DIR, 0755)) {
		return 1;
	}
	char list[LIST_BUF];
	read_list(GL_CLIENTS, list, sizeof(list));
	if (on) {
		drop_token(list, "-backboardd");
		if (!has_token(list, "*") && !has_token(list, "backboardd")) {
			add_token(list, "backboardd");
		}
	} else {
		drop_token(list, "backboardd");
		if (has_token(list, "*") && !has_token(list, "-backboardd")) {
			add_token(list, "-backboardd");
		}
	}
	return (write_list(GL_CLIENTS, list) || remove_file(GL_OFF)) ? 1 : 0;
}

/* glapps on|off: the apps gate in NegroniGL.bundle (phone-gl.sh apps on "* -backboardd" | off). */
static int
do_glapps(int on)
{
	struct stat st;
	if (stat(GL_BUNDLE, &st) != 0 || !S_ISDIR(st.st_mode)) {
		fprintf(stderr, "powermenu-helper: no %s (NegroniGL not installed)\n", GL_BUNDLE);
		return 6;
	}
	if (on) {
		return (write_list(GLAPPS_LIST, APPS_DEFAULT) || remove_file(GLAPPS_OFF)) ? 1 : 0;
	}
	return (write_file(GLAPPS_OFF, "powermenu-helper glapps off\n") || write_file(GLAPPS_LIST, "")) ? 1 : 0;
}

/* glfinish on|off: /var/db/negronigl/finish and the bundle copy (phone-gl.sh finish). */
static int
do_glfinish(int on)
{
	if (on) {
		if (ensure_dir(GL_DIR, 0755) || write_file(GL_FINISH, "powermenu-helper glfinish on\n")) {
			return 1;
		}
		if (exists(GL_BUNDLE) && write_file(GLAPPS_FINISH, "powermenu-helper glfinish on\n")) {
			return 1;
		}
		return 0;
	}
	return (remove_file(GL_FINISH) || remove_file(GLAPPS_FINISH)) ? 1 : 0;
}

static int
do_strikes_clear(void)
{
	int n = clear_dir(METAL_STRIKES);
	if (n < 0) {
		fprintf(stderr, "powermenu-helper: %s: %s\n", METAL_STRIKES, strerror(errno));
		return 1;
	}
	printf("STRIKES_CLEARED=%d\n", n);
	return 0;
}

/* The pid of /usr/libexec/backboardd, or 0. */
static pid_t
find_backboardd(void)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) {
		return 0;
	}
	len += len / 4; /* room for processes that start meanwhile */
	struct kinfo_proc *procs = malloc(len);
	if (procs == NULL || sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
		free(procs);
		return 0;
	}
	pid_t found = 0;
	size_t n = len / sizeof(struct kinfo_proc);
	for (size_t i = 0; i < n && found == 0; i++) {
		if (strcmp(procs[i].kp_proc.p_comm, "backboardd") != 0) {
			continue;
		}
		char path[PATH_BUF] = "";
		if (proc_pidpath(procs[i].kp_proc.p_pid, path, sizeof(path)) > 0 && strcmp(path, BACKBOARDD) == 0) {
			found = procs[i].kp_proc.p_pid;
		}
	}
	free(procs);
	return found;
}

/* restart-ui: kill -9 backboardd; launchd starts it again and SpringBoard (and the app) restart with it. */
static int
do_restart_ui(void)
{
	pid_t pid = find_backboardd();
	if (pid <= 0) {
		fprintf(stderr, "powermenu-helper: no %s process found\n", BACKBOARDD);
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

/* status: the file state only. Whether a running process has a device is not known here. */
static int
do_status(void)
{
	char list[LIST_BUF];
	int metal_off = exists(METAL_OFF);
	int have = read_list(METAL_CLIENTS, list, sizeof(list));
	const char *metal = "custom";
	if (metal_off) {
		metal = "off";
	} else if (!have || list[0] == '\0') {
		metal = "none";
	} else if (strcmp(list, "*") == 0) {
		metal = "all";
	} else if (strcmp(list, PROBES_LIST) == 0) {
		metal = "probes";
	}
	printf("METAL=%s\n", metal);
	printf("METAL_CLIENTS=%s\n", list);
	printf("METAL_OFF=%d\n", metal_off);
	printf("METAL_STRIKES=%d\n", count_dir(METAL_STRIKES));

	int gl_off = exists(GL_OFF);
	read_list(GL_CLIENTS, list, sizeof(list));
	int gl_on = !gl_off && !has_token(list, "-backboardd") && (has_token(list, "*") || has_token(list, "backboardd"));
	printf("GL=%s\n", gl_on ? "on" : "off");
	printf("GL_CLIENTS=%s\n", list);
	printf("GL_OFF=%d\n", gl_off);
	printf("GL_DYLIB=%d\n", exists("/usr/lib/negronigl.dylib"));

	int bundle = exists(GL_BUNDLE);
	read_list(GLAPPS_LIST, list, sizeof(list));
	int apps_on = bundle && !exists(GLAPPS_OFF) && list[0] != '\0';
	printf("GLAPPS=%s\n", apps_on ? "on" : "off");
	printf("GLAPPS_LIST=%s\n", list);
	printf("GLAPPS_BUNDLE=%d\n", bundle);
	printf("GLFINISH=%s\n", (exists(GL_FINISH) || exists(GLAPPS_FINISH)) ? "on" : "off");
	printf("BACKBOARDD_PID=%d\n", (int)find_backboardd());
	printf("BOOTLOADER_SYSCTL=%s\n", mode_sysctl() ? mode_sysctl() : "");
	return 0;
}

/* ---- main -------------------------------------------------------------------------------- */

static int
usage(void)
{
	fprintf(stderr, "usage: powermenu-helper restart|shutdown|bootloader|check|status|strikes-clear|restart-ui\n"
	    "       powermenu-helper metal all|probes|off | gl on|off | glapps on|off | glfinish on|off\n");
	return 2;
}

static int
onoff(const char *a)
{
	if (strcmp(a, "on") == 0) {
		return 1;
	}
	if (strcmp(a, "off") == 0) {
		return 0;
	}
	return -1;
}

int
main(int argc, char **argv)
{
	if (argc != 2 && argc != 3) {
		return usage();
	}
	const char *verb = argv[1];
	const char *arg = argc == 3 ? argv[2] : NULL;
	enum { V_RESTART, V_SHUTDOWN, V_BOOTLOADER, V_CHECK, V_STATUS, V_STRIKES, V_RESTART_UI,
	       V_METAL, V_GL, V_GLAPPS, V_GLFINISH } v;
	int on = -1;

	if (arg == NULL && !strcmp(verb, "restart")) v = V_RESTART;
	else if (arg == NULL && !strcmp(verb, "shutdown")) v = V_SHUTDOWN;
	else if (arg == NULL && !strcmp(verb, "bootloader")) v = V_BOOTLOADER;
	else if (arg == NULL && !strcmp(verb, "check")) v = V_CHECK;
	else if (arg == NULL && !strcmp(verb, "status")) v = V_STATUS;
	else if (arg == NULL && !strcmp(verb, "strikes-clear")) v = V_STRIKES;
	else if (arg == NULL && !strcmp(verb, "restart-ui")) v = V_RESTART_UI;
	else if (arg != NULL && !strcmp(verb, "metal") &&
	    (!strcmp(arg, "all") || !strcmp(arg, "probes") || !strcmp(arg, "off"))) v = V_METAL;
	else if (arg != NULL && !strcmp(verb, "gl") && (on = onoff(arg)) >= 0) v = V_GL;
	else if (arg != NULL && !strcmp(verb, "glapps") && (on = onoff(arg)) >= 0) v = V_GLAPPS;
	else if (arg != NULL && !strcmp(verb, "glfinish") && (on = onoff(arg)) >= 0) v = V_GLFINISH;
	else return usage();

	if (geteuid() != 0) {
		fprintf(stderr, "powermenu-helper: not setuid root (install: root:mobile 4750)\n");
		return 5;
	}
	if (!caller_allowed()) {
		return 4;
	}
	umask(022);

	switch (v) {
	case V_RESTART:    return do_reboot(RB_AUTOBOOT);
	case V_SHUTDOWN:   return do_reboot(RB_HALT);
	case V_BOOTLOADER: return do_bootloader();
	case V_CHECK: {
		const char *name = mode_sysctl();
		printf("powermenu-helper: caller ok; bootloader: %s\n",
		    name ? name : "not supported (no kern.negroni_reboot_mode in this kernel)");
		return name ? 0 : 3;
	}
	case V_STATUS:     return do_status();
	case V_STRIKES:    return do_strikes_clear();
	case V_RESTART_UI: return do_restart_ui();
	case V_METAL:      return do_metal(arg);
	case V_GL:         return do_gl(on);
	case V_GLAPPS:     return do_glapps(on);
	case V_GLFINISH:   return do_glfinish(on);
	}
	return usage();
}
