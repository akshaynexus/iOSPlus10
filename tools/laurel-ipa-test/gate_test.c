/*
 * Host test of the laurel 2782 gate (bsd/dev/laurel_ipa.c + laurel_ipa_link.c, taken from the patches): no QRTR message
 * that lets the modem touch the IPA (NEW_SERVER 0x31:101, INIT_MODEM_DRIVER) before every self-check passed, and one off
 * line per failure. The hardware steps are stubs here; each one fails in its own scenario. Each scenario is a new process
 * (the kernel files keep their state in statics). Run by scripts/laurel/test-ipa.sh. Exit 0 = all pass.
 */
#include "kstub_ipa.h"
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#include "laurel_ipa_regs.h"

static char log_text[8192];
static int off_lines;
int
kt_printf(const char *fmt, ...)
{
	char l[400];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(l, sizeof(l), fmt, ap);
	va_end(ap);
	strncat(log_text, l, sizeof(log_text) - strlen(log_text) - 1);
	if (strncmp(l, "LAUREL IPA: off:", 16) == 0) {
		off_lines++;
	}
	return n;
}
uint64_t kt_now_ns;
static uint32_t boot_ipa = 1;
int
PE_parse_boot_argn(const char *n, void *v, int s)
{
	(void)s;
	if (strcmp(n, "ipa") == 0 && boot_ipa != 1) {
		*(uint32_t *)v = boot_ipa;
		return 1;
	}
	return 0;
}
void IOSleep(unsigned int ms) { kt_now_ns += ms * 1000000ull; }

/* threads: the IPA thread runs to its end inside kernel_thread_start */
kern_return_t kernel_thread_start(thread_continue_t f, void *a, thread_t *t) { *t = 1; f(a, 0); return KERN_SUCCESS; }
void thread_deallocate(thread_t t) { (void)t; }
kern_return_t thread_terminate(thread_t t) { (void)t; return KERN_SUCCESS; }

/* QRTR: what reached the modem (ipa_cell_test.c adds its simulated UIM, DMS, NAS, WDS here) */
static bool (*gate_qrtr_more)(uint32_t src, const void *d, uint32_t len);
static int sent_server, sent_init, sent_other;
void
topaz_qrtr_data(uint32_t src, uint32_t node, uint32_t port, const void *d, uint32_t len)
{
	const uint8_t *b = d;
	(void)node; (void)port; (void)len;
	if (src == 0x4016 && b[3] == 0x21) {
		sent_init++;
	} else if (gate_qrtr_more == NULL || !gate_qrtr_more(src, d, len)) {
		sent_other++;
	}
}
void topaz_qrtr_new_server(uint32_t svc, uint32_t inst, uint32_t port) { (void)svc; (void)inst; (void)port; sent_server++; }

/* the hardware steps in order; fail_at names the one that fails ("" none) */
static const char *fail_at = "";
static char order[32];
static bool gsi_alive = true;
#define STEP(name, letter) \
	strncat(order, letter, sizeof(order) - strlen(order) - 1); \
	if (strcmp(fail_at, name) == 0) { snprintf(why, wl, "stub: %s failed", name); return false; } \
	return true
bool lipa_clock_on(char *why, size_t wl) { STEP("clock", "c"); }
bool lipa_smmu(char *why, size_t wl) { STEP("smmu", "s"); }
bool lipa_regs_map(struct lipa_mem *m, char *why, size_t wl) { static uint8_t r[0x100]; m->regs = r; m->restricted = 0; STEP("map", "m"); }
bool lipa_hw_init(struct lipa_mem *m, char *why, size_t wl) { (void)m; STEP("regs", "r"); }
bool lipa_fw_load(char *why, size_t wl) { STEP("fw", "f"); }
bool lipa_fw_recheck(struct lipa_mem *m, char *why, size_t wl) { m->pipes = 17; STEP("recheck", "R"); }
bool lipa_gsi_alloc(uint32_t pipes, char *why, size_t wl) { (void)pipes; STEP("alloc", "A"); }
bool lipa_sram_init(struct lipa_mem *m, char *why, size_t wl) { (void)m; STEP("sram", "S"); }
bool lipa_smem_item(char *why, size_t wl) { STEP("smem", "M"); }
bool
lipa_gsi_enabled(uint32_t *st)
{
	*st = gsi_alive && strcmp(fail_at, "gsi") != 0 ? 1 : 0;
	return *st != 0;
}

/* laurel 2931: the AP pipes: tools/laurel-ipa-test/data_test.c */
void lipa_data_kick(const struct lipa_mem *m) { (void)m; }
#include "laurel_ipa.c"
#include "laurel_ipa_link.c"
#include "laurel_ipa_qmi.c"

#define CHECK(c) do { if (!(c)) { fprintf(stdout, "FAIL %s line %d: %s\n%s\n", scen, __LINE__, #c, log_text); exit(1); } } while (0)
static const char *scen;

static void
ready_and_service(void)
{
	laurel_ipa_server(LIPA_QMI_SVC, LIPA_QMI_INST_MODEM, 0, 0x19, true);    /* the modem announces early */
	for (int i = 0; i < 3; i++) {
		laurel_ipa_poll(true, true);
		kt_now_ns += 100000000ull;
	}
}

static void
scenario_step_fails(const char *step)
{
	fail_at = step;
	ready_and_service();
	CHECK(off_lines == 1);
	CHECK(strstr(log_text, "stub:") != NULL || strcmp(step, "gsi") == 0);
	CHECK(sent_server == 0 && sent_init == 0 && sent_other == 0);
	const char *w = NULL;
	CHECK(!laurel_ipa_state(&w) && strstr(w, "AP IPA side off") != NULL);
	CHECK(laurel_ipa_smp2p_answer() == 1);
	laurel_ipa_off("later reason");
	CHECK(off_lines == 1);
}

/* a QMI response with result 0: TLV 0x02 */
static uint32_t
resp(uint8_t *b, uint8_t type, uint16_t msg)
{
	const uint8_t h[14] = { type, 1, 0, (uint8_t)msg, (uint8_t)(msg >> 8), 7, 0, 0x02, 4, 0, 0, 0, 0, 0 };
	memcpy(b, h, sizeof(h));
	return sizeof(h);
}

static void
scenario_all_pass(void)
{
	uint8_t b[32];
	laurel_ipa_poll(true, true);
	CHECK(strcmp(order, "csmrfRASM") == 0);
	CHECK(sent_server == 0 && sent_init == 0);      /* no service yet: nothing sent */
	CHECK(strstr(log_text, "self-check passed") != NULL);
	laurel_ipa_server(LIPA_QMI_SVC, LIPA_QMI_INST_MODEM, 0, 0x19, true);
	laurel_ipa_poll(true, true);
	CHECK(sent_server == 1 && sent_init == 1);
	CHECK(!laurel_ipa_state(NULL));
	(void)laurel_ipa_rx(0, 0x19, LIPA_PORT_CLIENT, b, resp(b, 2, 0x21));
	(void)laurel_ipa_rx(0, 0x30, LIPA_PORT_SERVER, b, resp(b, 0, 0x35));
	laurel_ipa_poll(true, true);
	CHECK(laurel_ipa_state(NULL));
	CHECK(strstr(log_text, "LAUREL IPA: on: v4.2") != NULL);
	CHECK(off_lines == 0);
	laurel_ipa_off("modem crashed: x");
	CHECK(off_lines == 1 && !laurel_ipa_state(NULL));
}

/* all checks passed, the GSI went away before the service came: no message */
static void
scenario_gsi_lost(void)
{
	laurel_ipa_poll(true, true);
	gsi_alive = false;
	laurel_ipa_server(LIPA_QMI_SVC, LIPA_QMI_INST_MODEM, 0, 0x19, true);
	laurel_ipa_poll(true, true);
	CHECK(sent_server == 0 && sent_init == 0 && off_lines == 1);
	CHECK(strstr(log_text, "GSI not enabled before INIT_MODEM_DRIVER") != NULL);
}

static void
scenario_kill_switch(void)
{
	boot_ipa = 0;
	ready_and_service();
	CHECK(order[0] == 0 && sent_server == 0 && sent_init == 0 && off_lines == 1);
	CHECK(strstr(log_text, "off: boot-arg ipa=0") != NULL);
}

#ifndef GATE_NO_MAIN
int
main(void)
{
	static const char *const steps[] = { "clock", "smmu", "map", "regs", "fw", "gsi", "recheck", "alloc", "sram", "smem" };
	int bad = 0, n = 0;

	for (int i = -3; i < (int)(sizeof(steps) / sizeof(steps[0])); i++) {
		pid_t p = fork();
		if (p == 0) {
			scen = i == -3 ? "all pass" : i == -2 ? "GSI lost" : i == -1 ? "ipa=0" : steps[i];
			if (i == -3) { scenario_all_pass(); } else if (i == -2) { scenario_gsi_lost(); }
			else if (i == -1) { scenario_kill_switch(); } else { scenario_step_fails(steps[i]); }
			exit(0);
		}
		int st = 0;
		waitpid(p, &st, 0);
		n++;
		bad += !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
	}
	fprintf(stdout, bad == 0 ? "ok: gate: %d scenarios: no NEW_SERVER or INIT_MODEM_DRIVER before all self-checks passed\n" : "gate_test: %d scenarios, failures\n", n);
	return bad != 0;
}
#endif
