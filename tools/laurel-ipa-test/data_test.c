/*
 * Host test of the laurel 2941 AP data path (bsd/dev/laurel_ipa_data.c, taken from the patch) with a simulated GSI + IPA: register values against the sources named in
 * that file, RX ring + QMAP frames, TX ring, full ring, errors. No claim about the hardware's answer: only that this code does what the sources say.
 * Run by scripts/laurel/test-ipa.sh. Exit 0 = all pass.
 */
#include "kstub_ipa.h"
#include "laurel_ipa_regs.h"

static char logbuf[8192];
int
kt_printf(const char *fmt, ...)
{
	char b[400];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	strncat(logbuf, b, sizeof(logbuf) - strlen(logbuf) - 1);
	return 0;
}
uint64_t kt_now_ns;
static uint32_t boot_data = 1;
int
PE_parse_boot_argn(const char *n, void *v, int s)
{
	if (strcmp(n, "cell_data") == 0 && s == 4) {
		memcpy(v, &boot_data, 4);
		return 1;
	}
	return 0;
}
void IOSleep(unsigned int ms) { kt_now_ns += ms * 1000000ull; }

static int bad;
static char why[200];
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s (why: %s)\n", __LINE__, #c, why); bad++; } } while (0)
#undef printf
#define printf kt_printf

/* ---- simulated hardware. Pool: fake physical addresses below 4 GiB, as the modem pool */
#define POOL_PA 0xE1000000u
static uint8_t pool[4u << 20] __attribute__((aligned(4096)));
static uint32_t pool_used;
void *
topaz_pool_alloc(uint64_t size, uint64_t *pa)
{
	size = (size + 0xFFF) & ~0xFFFull;
	if (pool_used + size > sizeof(pool)) {
		return NULL;
	}
	*pa = POOL_PA + pool_used;
	pool_used += (uint32_t)size;
	return pool + *pa - POOL_PA;
}

static uint32_t gsi[0x4000 / 4], ipa[0x1000 / 4];
static int stuck_ch = -1;
static uint32_t cmds[8], ncmd;

uint32_t lipa_gsi_rd(uint32_t off) { return gsi[off / 4]; }
void
lipa_gsi_wr(uint32_t off, uint32_t v)
{
	if (off == G_CH_CMD || off == G_EV_CH_CMD) {
		uint32_t n = v & 0xFF, op = v >> 24, *ctx = off == G_CH_CMD ? &gsi[G_CH_CNTXT(n, 0) / 4] : &gsi[G_EV_CNTXT(n, 0) / 4];

		cmds[ncmd++ & 7] = v;
		if (off == G_EV_CH_CMD && op == 0) {
			*ctx = 1u << 20;
		}
		if (off == G_CH_CMD && op == 1 && (int)n != stuck_ch) {
			*ctx = (*ctx & ~(0xFu << 20)) | 2u << 20;
		}
		return;
	}
	/* a program write keeps the state field, as hardware: CHSTATE and EV_CHSTATE are read only */
	if ((off < 0x1000 && (off % 0x80) == 0) || (off >= 0x1000 && off < 0x2000 && (off % 0x80) == 0)) {
		gsi[off / 4] = (gsi[off / 4] & (0xFu << 20)) | (v & ~(0xFu << 20));
		return;
	}
	gsi[off / 4] = v;
}
struct thread_stub { int x; };
kern_return_t kernel_thread_start(thread_continue_t f, void *a, thread_t *t) { (void)f; (void)a; (void)t; return KERN_SUCCESS; }
void thread_deallocate(thread_t t) { (void)t; }
kern_return_t thread_terminate(thread_t t) { (void)t; return KERN_SUCCESS; }
bool lipa_link_active(void) { return false; }
static const char *ipa_why = "AP IPA side still starting";
bool laurel_ipa_state(const char **why) { *why = ipa_why; return false; }

/* the interface: laurel_pdp.c in the kernel */
static uint8_t rx_mux[8];
static uint32_t rx_len[8], rx_n;
static uint8_t rx_first[8];
void
laurel_pdp_input(uint8_t mux, const uint8_t *ip, uint32_t len)
{
	if (rx_n < 8) {
		rx_mux[rx_n] = mux;
		rx_len[rx_n] = len;
		rx_first[rx_n] = ip[0];
		rx_n++;
	}
}
bool laurel_pdp_session(void) { return true; }
void laurel_pdp_work(void) { }

#include "laurel_ipa_data.c"

static struct lipa_mem mem;

/* a finished transfer: an event for TRE slot in the channel's event ring, the event pointer moved */
static void
hw_event(struct lch *c, uint32_t *evn, uint32_t slot, uint32_t len)
{
	volatile uint32_t *e = (volatile uint32_t *)(c->evr + (*evn & (uint32_t)(c->slots - 1)) * RE_SIZE);
	uint64_t x = c->tre_pa + (uint64_t)slot * RE_SIZE;

	e[0] = (uint32_t)x;
	e[1] = (uint32_t)(x >> 32);
	e[2] = len;
	e[3] = 0;
	(*evn)++;
	gsi[G_EV_CNTXT(c->ev, 4) / 4] = (uint32_t)c->ev_pa + (*evn & (uint32_t)(c->slots - 1)) * RE_SIZE;
}

int
main(void)
{
	mem.regs = (volatile uint8_t *)ipa;
	for (uint32_t i = 0; i < 10; i++) {
		gsi[G_CH_CNTXT(i, 0) / 4] = 1u << 20;   /* laurel_ipa_gsi.c allocated the AP channels */
	}
	/* --- a channel that does not start: the reason, no ready state */
	stuck_ch = 3;
	CHECK(!lipa_data_setup(&mem, why, sizeof(why)));
	CHECK(strstr(why, "channel START 3: state 1, wanted 2") != NULL);
	stuck_ch = -1;
	pool_used = 0;
	bzero(gsi, sizeof(gsi));
	for (uint32_t i = 0; i < 10; i++) {
		gsi[G_CH_CNTXT(i, 0) / 4] = 1u << 20;
	}
	for (uint32_t i = 0; i < LIPA_DATA_CH; i++) {
		chs[i].next = chs[i].done = chs[i].ev_next = 0;
	}
	why[0] = 0;
	/* --- the setup */
	CHECK(lipa_data_setup(&mem, why, sizeof(why)));
	/* stock ipa3_ep_mapping[IPA_4_2]: pipe 1 ch 0, pipe 9 ch 3, pipe 8 ch 2; mainline gsi_channel_program */
	CHECK(gsi[G_CH_CNTXT(0, 0) / 4] == (2u | 1u << 3 | 0u << 14 | 16u << 24 | 2u << 20));
	CHECK(gsi[G_CH_CNTXT(3, 0) / 4] == (2u | 1u << 14 | 16u << 24 | 2u << 20));
	CHECK(gsi[G_CH_CNTXT(2, 0) / 4] == (2u | 2u << 14 | 16u << 24 | 2u << 20));
	CHECK(gsi[G_CH_CNTXT(0, 1) / 4] == 128 * 16 && gsi[G_CH_CNTXT(3, 1) / 4] == 64 * 16 && gsi[G_CH_CNTXT(2, 1) / 4] == 8 * 16);
	CHECK(gsi[G_CH_QOS(0) / 4] == 1u << 10 && gsi[G_CH_SCRATCH(0, 0) / 4] == 0 && gsi[G_CH_SCRATCH(3, 2) / 4] == 0);
	CHECK(gsi[G_EV_CNTXT(1, 0) / 4] == (2u | 1u << 16 | 16u << 24 | 1u << 20));
	CHECK(gsi[G_EV_CNTXT(1, 8) / 4] == (32u | 1u << 16));
	/* the event doorbell: the ring's last entry */
	CHECK(gsi[G_EV_DOORBELL(1) / 4] == (uint32_t)chs[1].ev_pa + 63 * 16);
	/* rmnet_ipa.c handle3_egress_format: hdr len 4, metadata offset 0; ipa3_assign_policy: status to Q6_WAN_CONS 10; seq 0x806 */
	CHECK(ipa[R_ENDP_HDR(1) / 4] == 0x44 && ipa[R_ENDP_HDR_EXT(1) / 4] == 1 && ipa[R_ENDP_SEQ(1) / 4] == 0x806 && ipa[R_ENDP_STATUS(1) / 4] == 0x15);
	/* handle3_ingress_format: len 4, metadata 1, pkt size 2; pad valid, inc padding, big endian; mask ff000000; IPA_GENERIC_AGGR 6 KB, 500 us */
	CHECK(ipa[R_ENDP_HDR(9) / 4] == 0x2800C4 && ipa[R_ENDP_HDR_EXT(9) / 4] == 0xB && ipa[R_ENDP_METADATA_MASK(9) / 4] == 0xFF000000u);
	CHECK(ipa[R_ENDP_AGGR(9) / 4] == 0x2004D1 && ipa[R_ENDP_STATUS(9) / 4] == 0 && ipa[R_ENDP_HOL_EN(9) / 4] == 0);
	CHECK(ipa[R_ENDP_AGGR(8) / 4] == 0x4D1 && ipa[R_ENDP_HDR(8) / 4] == 0);
	/* RX: all slots but one posted, doorbell behind the last */
	CHECK(chs[1].next == 63 && gsi[G_CH_DOORBELL(3) / 4] == (uint32_t)chs[1].tre_pa + 63 * 16);
	{
		volatile uint32_t *t = (volatile uint32_t *)chs[1].tre + 5 * 4;
		CHECK(t[0] == (uint32_t)chs[1].buf_pa + 5 * 8192 && t[1] == 0 && t[2] == 8192 && t[3] == (TRE_TYPE_XFER | TRE_IEOT));
	}
	data_state = 1;
	/* --- RX: two IP packets + one QMAP command in one aggregated buffer */
	static const uint8_t frames[] = {
		0x00, 0x01, 0x00, 0x05, 0x45, 1, 2, 3, 4,                       /* mux 1, 5 bytes */
		0x02, 0x01, 0x00, 0x06, 0x60, 1, 2, 3, 0xEE, 0xEE,              /* pad 2, 6 with pad: 4 bytes of IPv6 */
		0x80, 0x01, 0x00, 0x02, 0xAA, 0xBB,                             /* command: not data */
	};
	memcpy(chs[1].buf, frames, sizeof(frames));
	uint32_t ev1 = 0;
	hw_event(&chs[1], &ev1, 0, sizeof(frames));
	CHECK(lipa_data_poll() == 1);
	CHECK(rx_n == 2 && rx_mux[0] == 1 && rx_len[0] == 5 && rx_first[0] == 0x45 && rx_len[1] == 4 && rx_first[1] == 0x60);
	CHECK(chs[1].pkts == 2 && chs[1].drops == 1 && chs[1].done == 1);
	/* the buffer is free again: the slot unposted so far (63) goes to the ring; doorbell wraps to 0; the event doorbell = the event read */
	CHECK(chs[1].next == 64 && gsi[G_CH_DOORBELL(3) / 4] == (uint32_t)chs[1].tre_pa);
	CHECK(gsi[G_EV_DOORBELL(1) / 4] == (uint32_t)chs[1].ev_pa);
	CHECK(lipa_data_poll() == 0);
	/* --- a cut frame stops the walk of this buffer, not the ring */
	static const uint8_t cut[] = { 0x00, 0x01, 0x00, 0x40, 0x45, 1, 2, 3 };
	memcpy(chs[1].buf + 8192, cut, sizeof(cut));
	hw_event(&chs[1], &ev1, 1, sizeof(cut));
	rx_n = 0;
	CHECK(lipa_data_poll() == 1 && rx_n == 0 && chs[1].drops == 2 && chs[1].next == 65);
	/* --- an event outside the ring: counted, one line, no crash */
	hw_event(&chs[1], &ev1, 2, 16);
	{
		volatile uint32_t *e = (volatile uint32_t *)(chs[1].evr + 2 * RE_SIZE);
		e[0] = 0x1000;
	}
	(void)lipa_data_poll();
	CHECK(chs[1].errs == 1 && strstr(logbuf, "outside the ring") != NULL);
	/* --- TX: header + TRE + doorbell */
	uint8_t *p = lipa_tx_begin(100);
	CHECK(p != NULL);
	memset(p, 0x45, 100);
	lipa_tx_end(1, 100);
	CHECK(chs[0].next == 1 && gsi[G_CH_DOORBELL(0) / 4] == (uint32_t)chs[0].tre_pa + 16);
	CHECK(chs[0].buf[0] == 0 && chs[0].buf[1] == 1 && chs[0].buf[2] == 0 && chs[0].buf[3] == 100 && chs[0].buf[4] == 0x45);
	{
		volatile uint32_t *t = (volatile uint32_t *)chs[0].tre;
		CHECK(t[0] == (uint32_t)chs[0].buf_pa && t[2] == 104 && t[3] == (TRE_TYPE_XFER | TRE_IEOT | TRE_BEI));
	}
	CHECK(lipa_tx_begin(5000) == NULL);             /* larger than a slot */
	/* --- a full ring: NULL, then one TX event frees room */
	for (uint32_t i = 1; i < 127; i++) {
		CHECK(lipa_tx_begin(10) != NULL);
		lipa_tx_end(1, 10);
	}
	CHECK(lipa_tx_begin(10) == NULL && chs[0].drops == 1);
	uint32_t ev0 = 0;
	hw_event(&chs[0], &ev0, 0, 14);
	hw_event(&chs[0], &ev0, 1, 14);
	CHECK(lipa_tx_begin(10) != NULL);
	lipa_tx_end(1, 10);
	CHECK(chs[0].done == 2);
	/* --- stats text and the kill switch */
	char st[160];
	lipa_data_stats(st, sizeof(st));
	CHECK(strstr(st, "rx 2 pkts") != NULL);
	/* the IPA off for good: the state says so once, with the reason */
	data_state = 0;
	ipa_why = "AP IPA side off: boot-arg ipa=0";
	{
		const char *w0 = NULL;
		CHECK(laurel_ipa_data_state(&w0) == -1 && strstr(w0, "boot-arg ipa=0") != NULL);
		CHECK(strstr(logbuf, "data: off: AP IPA side off: boot-arg ipa=0") != NULL);
	}
	ipa_why = "";
	data_state = 0;
	started = false;
	boot_data = 0;
	lipa_data_kick(&mem);
	const char *w = NULL;
	CHECK(laurel_ipa_data_state(&w) == -1 && strstr(w, "boot-arg cell_data=0") != NULL);
	if (bad == 0) {
		fprintf(stdout, "ok: AP data path: registers = sources, RX frames + repost, cut frame, TX + full ring, kill switch\n");
	} else {
		fprintf(stdout, "%s", logbuf);
	}
	return bad != 0;
}
