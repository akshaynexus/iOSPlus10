/* negronigl: the log (negroni_drm.h ngl_log). */
#include <fcntl.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "negroni_drm.h"

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int log_fd = -1;
static os_log_t oslog;

static void
log_open(void)
{
	const char *w = getenv("NEGRONIGL_LOG");
	oslog = os_log_create("dev.iosplus10.negronigl", "gl");
	if (w == NULL || strcmp(w, "console") == 0) {
		log_fd = open("/dev/console", O_WRONLY | O_CLOEXEC | O_NOCTTY);
	} else if (strcmp(w, "stderr") == 0) {
		log_fd = dup(STDERR_FILENO);
	} else if (w[0] == '/') {
		log_fd = open(w, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
	}
	/* "oslog", "none": os_log only */
}

void
ngl_log(const char *fmt, ...)
{
	char line[512];
	va_list ap;
	pthread_once(&once, log_open);
	va_start(ap, fmt);
	int n = vsnprintf(line, sizeof(line) - 1, fmt, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if (n > (int)sizeof(line) - 2) {
		n = (int)sizeof(line) - 2;
	}
	os_log(oslog, "%{public}s", line);
	if (log_fd >= 0) {
		line[n++] = '\n';
		(void)write(log_fd, line, (size_t)n);
	}
}
