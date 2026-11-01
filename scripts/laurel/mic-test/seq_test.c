/*
 * Host test of the microphone's hardware sequence (patch 2920, LaurelMic{Regs,Hw,Codec,Ring}.inc, taken from the
 * patch by scripts/laurel/mic-host-test.sh). A register model of the macros, the SoundWire master and the WCD937x.
 * The expected values come from the stock driver and DT, written out here by hand. Proves the sequence, not the chip.
 */
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MIC_HOST_TEST
#define MIC_LOG(...) do { printf("  [kernel] "); printf(__VA_ARGS__); printf("\n"); } while (0)
static void IODelay(unsigned us) { (void)us; }
static void *ml_io_map(uint64_t pa, uint64_t size) { (void)size; return (void *)(uintptr_t)pa; }

/* the model */
#define MMIO_SLOTS 8192
static struct { uintptr_t a; uint32_t v; } mmio[MMIO_SLOTS];
static uint32_t mmio_n, codec[0x10000], rd_ans, slv_on, bank_status, log_i;
static struct { uint32_t dev, reg, val; } swlog[1024];
static uint32_t no_codec, stuck_reg, dead_bus;

static uint32_t *
slot(uintptr_t a)
{
	for (uint32_t i = 0; i < mmio_n; i++) {
		if (mmio[i].a == a) {
			return &mmio[i].v;
		}
	}
	mmio[mmio_n].a = a;
	return &mmio[mmio_n++].v;
}

#define SWR(off) ((uintptr_t)0x0A470000u + (off))

static uint32_t
mic_rd(volatile uint8_t *base, uint32_t off)
{
	uintptr_t a = (uintptr_t)base + off;

	if (a == SWR(0x0318)) {
		return rd_ans;
	}
	if (a == SWR(0x0530 + 8)) {
		return slv_on ? 0x01170223u : 0;
	}
	if (a == SWR(0x1090)) {
		return slv_on ? 1u << 2 : 0;
	}
	if (a == SWR(0x104C)) {
		return bank_status;
	}
	if (a == SWR(0x0000)) {
		return 0x01050000;
	}
	return *slot(a);
}

static void
mic_wr(volatile uint8_t *base, uint32_t off, uint32_t v)
{
	uintptr_t a = (uintptr_t)base + off;

	if (a == SWR(0x0300)) {                         /* a write command */
		uint32_t reg = v & 0xFFFF, id = (v >> 16) & 0xF, dev = (v >> 20) & 0xF, val = v >> 24;

		if (log_i < 1024) {
			swlog[log_i].dev = dev;
			swlog[log_i].reg = reg;
			swlog[log_i++].val = val;
		}
		if (dev == 0xF && id == 0xF && (reg == 0x60 || reg == 0x70)) {
			bank_status = reg == 0x70;      /* the frame broadcast switches the bank */
		}
		if (reg != stuck_reg || stuck_reg == 0) {
			codec[reg] = val;
		}
		return;
	}
	if (a == SWR(0x0304)) {                         /* a read command: the answer is in the FIFO */
		rd_ans = dead_bus ? 0 : (((v >> 16) & 0xF) << 8) | (codec[v & 0xFFFF] & 0xFF);
		return;
	}
	if (a == SWR(0x0008)) {
		slv_on = !no_codec;
		return;
	}
	*slot(a) = v;
}

static void mic_wait(unsigned milliseconds);
#include "LaurelMicRegs.inc"
#include "LaurelMicHw.inc"
#include "LaurelMicCodec.inc"
#include "LaurelMicRing.inc"
static void mic_wait(unsigned milliseconds) { (void)milliseconds; }

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)
#define RD(pa) (*slot((uintptr_t)(pa)))

/* the index of the n-th logged write of `val' (under `mask') to `reg', -1 = never */
static int
at(uint32_t reg, uint32_t mask, uint32_t val, int nth)
{
	for (uint32_t i = 0; i < log_i; i++) {
		if (swlog[i].reg == reg && (swlog[i].val & mask) == val && nth-- == 0) {
			return (int)i;
		}
	}
	return -1;
}

static void
reset_model(void)
{
	memset(mmio, 0, sizeof(mmio));
	memset(codec, 0, sizeof(codec));
	mmio_n = rd_ans = slv_on = bank_status = log_i = 0;
	no_codec = stuck_reg = 0;
	mtx = NULL;
	mic_why[0] = 0;
	mic_dev = 0;
}

static bool
bring_up(void)
{
	return mic_map_all() && (mic_reset_pulse(), mic_pins(true), mic_macro_clocks()) && (swrm_on(), (mic_dev = swr_find_codec(5)) != 0);
}

#include "seq_test_cases.c"
