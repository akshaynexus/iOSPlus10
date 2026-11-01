/*
 * Host test of the laurel 2782 GSI channel allocation (bsd/dev/laurel_ipa_gsi.c, taken from the patches) with a simulated
 * GSI. Expected order and channels: ipa3_alloc_gsi_channel() over ipa3_ep_mapping[IPA_4_2] of the 4.14 driver; the command
 * words: gsi_alloc_channel_ee() and gsi_alloc_ap_channel(). Run by scripts/laurel/test-ipa.sh. Exit 0 = all pass.
 */
#include "kstub_ipa.h"
#include <stdlib.h>

static char last_line[400];
int kt_printf(const char *fmt, ...) { va_list ap; va_start(ap, fmt); int n = vsnprintf(last_line, sizeof(last_line), fmt, ap); va_end(ap); return n; }
uint64_t kt_now_ns;
int PE_parse_boot_argn(const char *n, void *v, int s) { (void)n; (void)v; (void)s; return 0; }

static uint32_t slept_ms;
void IOSleep(unsigned int ms) { slept_ms += ms; }

#include "laurel_ipa_regs.h"

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stdout, "FAIL line %d: %s (why: %s)\n", __LINE__, #c, why); bad++; } } while (0)
static char why[200];

/* ---- the simulated GSI: EE 0 registers, one state per AP channel, a log of commands as (ee, ch) */
static struct {
	uint32_t reg[0x4000 / 4];
	uint32_t ap_state[32];
	uint8_t log[40][2];
	int n;
	/* faults */
	int silent_at;          /* generic command n (1-based): no answer */
	int code_at;            /* generic command n: this return code */
	uint32_t code;
	int ap_stuck_ch;        /* this AP channel stays not allocated; -1 none */
	uint32_t error_log;     /* appears after the last command */
	/* what the test checks */
	int generic_n;
	bool en_ok, scratch_zeroed;
} G;

uint32_t
lipa_gsi_rd(uint32_t off)
{
	if (off < 0x1000) {
		return G.ap_state[off / 0x80] << 20;
	}
	return G.reg[off / 4];
}

void
lipa_gsi_wr(uint32_t off, uint32_t v)
{
	if (off == G_CH_CMD) {
		uint32_t ch = v & 0xFF;
		CHECK((v >> 24) == 0);          /* GSI_CH_ALLOCATE */
		G.log[G.n][0] = 0; G.log[G.n++][1] = (uint8_t)ch;
		if ((int)ch != G.ap_stuck_ch) {
			G.ap_state[ch] = 1;
		}
		return;
	}
	if (off == G_GENERIC_CMD) {
		uint32_t op = v & 0x1F, ch = (v >> 5) & 0x1F, ee = (v >> 10) & 0xF;
		CHECK(op == 2);                 /* GSI_GEN_EE_CMD_ALLOC_CHANNEL */
		G.log[G.n][0] = (uint8_t)ee; G.log[G.n++][1] = (uint8_t)ch;
		G.generic_n++;
		G.en_ok = G.en_ok && (G.reg[G_GLOB_IRQ_EN / 4] & 2) != 0;
		G.scratch_zeroed = G.scratch_zeroed && ((G.reg[G_SCRATCH_0 / 4] >> 5) & 7) == 0;
		if (G.generic_n != G.silent_at) {
			uint32_t code = G.generic_n == G.code_at ? G.code : 1;
			G.reg[G_SCRATCH_0 / 4] = (G.reg[G_SCRATCH_0 / 4] & ~(7u << 5)) | code << 5;
			G.reg[G_GLOB_IRQ_STTS / 4] |= 2;
		}
		return;
	}
	if (off == G_GLOB_IRQ_CLR) {
		G.reg[G_GLOB_IRQ_STTS / 4] &= ~v;
		return;
	}
	if (off == G_TYPE_IRQ_MSK && (v & 5) == 0 && G.error_log != 0) {
		G.reg[G_ERROR_LOG / 4] = G.error_log;   /* the mask goes back after the last command */
	}
	G.reg[off / 4] = v;
}

#include "laurel_ipa_gsi.c"

static void
reset(void)
{
	memset(&G, 0, sizeof(G));
	G.ap_stuck_ch = -1;
	G.en_ok = G.scratch_zeroed = true;
	G.reg[G_STATUS / 4] = 1;
	G.reg[G_HW_PARAM_2 / 4] = 23u << 3;
	G.reg[G_SCRATCH_0 / 4] = 0xA5u << 24 | 7u << 5;     /* an old code + other fields that must survive */
	G.reg[G_ERROR_LOG / 4] = 0xBAD;                     /* cleared as gsi_register_device does */
	G.reg[G_INTSET / 4] = 0;
	why[0] = 0;
	slept_ms = 0;
}

/* { EE, channel } per pipe, from ipa_utils.c IPA_4_2 + msm_ipa.h enum order */
static const uint8_t want[17][2] = {
	{ 0, 5 }, { 0, 0 }, { 0, 6 }, { 0, 7 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { 2, 0 }, { 0, 2 }, { 0, 3 }, { 1, 2 }, { 1, 3 },
	{ 0, 4 }, { 1, 4 }, { 0, 8 }, { 0, 9 }, { 2, 1 },
};

static void
test_ok(uint32_t pipes, int expect)
{
	reset();
	CHECK(lipa_gsi_alloc(pipes, why, sizeof(why)));
	CHECK(G.n == expect);
	CHECK(memcmp(G.log, want, (size_t)expect * 2) == 0);
	CHECK(G.en_ok && G.scratch_zeroed);
	CHECK((G.reg[G_GLOB_IRQ_EN / 4] & 2) == 0);         /* GP_INT1 off again */
	CHECK((G.reg[G_GLOB_IRQ_STTS / 4] & 2) == 0);       /* cleared */
	CHECK(G.reg[G_SCRATCH_0 / 4] >> 24 == 0xA5);        /* other fields kept */
	CHECK(G.reg[G_INTSET / 4] == 1 && G.reg[G_ERROR_LOG / 4] == 0);
	CHECK(G.reg[G_TYPE_IRQ_MSK / 4] == 0);              /* restored */
	CHECK(strstr(last_line, "GSI channels allocated") != NULL);
}

/* a failure stops at once: no later channel, false, a reason */
static void
test_fail(const char *text, int cmds)
{
	CHECK(!lipa_gsi_alloc(17, why, sizeof(why)));
	CHECK(G.n == cmds);
	CHECK(strstr(why, text) != NULL);
	CHECK((G.reg[G_GLOB_IRQ_EN / 4] & 2) == 0);
}

int
main(void)
{
	test_ok(17, 17);
	fprintf(stdout, "  17 pipes: order = stock (AP %s, modem 5, uC 2): %s\n", "10", last_line);
	test_ok(14, 14);                        /* the modem's pipes end at 13 */
	test_ok(31, 17);                        /* pipes beyond the table: ipa3_get_gsi_ep_info() = NULL, skipped */

	/* the modem channel of the 17:01 assert is command 2 of the generic ones */
	reset(); G.silent_at = 2;
	test_fail("no answer to ALLOCATE", 6);
	CHECK(strstr(why, "channel 1 of EE 1 (pipe 5)") != NULL);
	CHECK(slept_ms >= 5000);
	fprintf(stdout, "  no answer: %s\n", why);

	reset(); G.code_at = 1; G.code = 7;     /* GSI_GEN_EE_CMD_RETURN_CODE_OUT_OF_RESOURCES */
	test_fail("ALLOCATE refused, code 7", 5);
	fprintf(stdout, "  refused: %s\n", why);

	reset(); G.code_at = 2; G.code = 2;     /* the stock driver accepts this one; without proof we do not */
	test_fail("ALLOCATE refused, code 2", 6);

	reset(); G.ap_stuck_ch = 6;
	test_fail("after ALLOCATE the state is 0", 3);
	fprintf(stdout, "  AP channel: %s\n", why);

	reset(); G.ap_state[5] = 15;            /* GSI_CHAN_STATE_ERROR before the command */
	test_fail("before ALLOCATE the state is 15", 0);

	reset(); G.ap_state[5] = 1;             /* already allocated: no command, the state is the proof */
	CHECK(lipa_gsi_alloc(17, why, sizeof(why)));
	CHECK(G.n == 16);

	reset(); G.error_log = 0x1234;
	test_fail("ERROR_LOG 00001234", 17);

	reset(); G.reg[G_HW_PARAM_2 / 4] = 9u << 3;
	test_fail("9 channels per EE", 0);

	reset();
	CHECK(!lipa_gsi_alloc(13, why, sizeof(why)));
	CHECK(G.n == 0 && strstr(why, "IPA_ENABLED_PIPES is 13") != NULL);

	fprintf(stdout, bad == 0 ? "ok: GSI channels: stock order and command words, 9 failure paths stop before the handshake\n" : "gsi_test: %d failures\n", bad);
	return bad != 0;
}
