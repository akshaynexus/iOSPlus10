/* Host test of the table of kernel patch 2951 (bsd/dev/laurel_state_core.h): scripts/laurel/state-test.sh. The text the kernel sends and how it wraps. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "laurel_state_core.h"

static struct lst_table t;

int main(void)
{
	char out[32768];

	assert(lst_find("launchd") >= 0 && lst_find("init_data_protec") >= 0 && lst_find("nothing") < 0);
	/* p_name of exec is up to 32 characters, p_comm of exit 16: the same slot */
	assert(lst_find("init_data_protection") == lst_find("init_data_protec"));
	lst_exec(&t, "launchd", 1, 2100);
	lst_exec(&t, "mount", 5, 2500);
	lst_exit(&t, "mount", 5, 0x100, 2700);
	for (int i = 0; i < 7; i++) {
		lst_exec(&t, "backboardd", 100 + i, 30000u + i * 1000u);
		lst_exit(&t, "backboardd", 100 + i, 6, 30500u + i * 1000u);
	}
	lst_exec(&t, "backboardd", 200, 50000);
	unsigned n = lst_text(&t, 60000, "build X\nroot /dev/ufsroot0 rw\nlaunchd=up ssh=no\n", out, sizeof(out));
	out[n] = 0;
	assert(strstr(out, "state 1 up=60.0\n") == out);
	assert(strstr(out, "build X\nroot /dev/ufsroot0 rw\nlaunchd=up ssh=no\n"));
	assert(strstr(out, "count exec=10 exit=8 bad=8 sig=7\n"));
	assert(strstr(out, "run launchd pid=1 n=1 x=0 rv=0x0 t=2.1\n"));
	assert(strstr(out, "run mount pid=0 n=1 x=1 rv=0x100 t=2.5\n"));
	assert(strstr(out, "run backboardd pid=200 n=8 x=7 rv=0x6 t=30.0\n"));
	assert(strstr(out, "bad 2.7 mount[5] rv=0x100\n"));
	assert(strstr(out, "exec 50.0 backboardd[200]\n"));
	assert(!strcmp(out + n - 4, "end\n"));
	/* a name that is not watched: only in the rings. The rings keep the last ones */
	for (int i = 0; i < 40; i++) {
		lst_exec(&t, "somethingwithaverylongname", 1000 + i, 70000);
		lst_exit(&t, "somethingwithaverylongname", 1000 + i, 11, 70100);
	}
	n = lst_text(&t, 80000, "h\n", out, sizeof(out));
	out[n] = 0;
	assert(!strstr(out, "bad 2.7 mount"));
	assert(strstr(out, "somethingwithave[1039]"));
	/* a small buffer at every size: whole lines, ends with end, never over the buffer (ASan) */
	char head[512];
	memset(head, 'x', sizeof(head) - 2);
	head[sizeof(head) - 2] = '\n';
	head[sizeof(head) - 1] = 0;
	for (unsigned cap = 16; cap < 2000; cap++) {
		char *b = malloc(cap);
		unsigned m = lst_text(&t, 80000, cap > 900 ? head : "h\n", b, cap);
		assert(m <= cap && m >= 4 && !memcmp(b + m - 4, "end\n", 4));
		free(b);
	}
	puts("state-test: PASS");
	return 0;
}
