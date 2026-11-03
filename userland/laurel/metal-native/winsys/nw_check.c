/* SPDX-License-Identifier: MIT */
/*
 * See nw.h: the stream check. A rule for every packet this stack writes; a packet with no rule is refused, so a new packet cannot reach the GPU before somebody has read what the CP does with it.
 * Why each rule, with its proof: docs/laurel_sprout/ios26-native-metal.md section 11. Opcodes and events: Mesa's adreno_pm4.xml (MIT). Packet shape: the CP reads what a header says, and takes the words after it as what the opcode needs, even when the header's count is smaller.
 */
#include "nw.h"
#include <inttypes.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "adreno_common.xml.h"
#include "adreno_pm4.xml.h"
#include "nw_check_regs.h"
#include "nw_addr_regs.h"

void nw_check_count(struct nw_device *, uint64_t dwords, uint64_t packets);

static uint8_t addr_bits[0x10000 / 8];
static pthread_once_t addr_once = PTHREAD_ONCE_INIT;

static void addr_init(void)
{
	for (size_t i = 0; i < sizeof(nw_addr_regs) / sizeof(nw_addr_regs[0]); i++)
		addr_bits[nw_addr_regs[i] >> 3] |= 1u << (nw_addr_regs[i] & 7);
}

static bool refuse(char *why, size_t why_size, uint64_t at, const char *format, ...)
{
	char text[192];
	va_list a;
	va_start(a, format);
	vsnprintf(text, sizeof(text), format, a);
	va_end(a);
	snprintf(why, why_size, "at %#" PRIx64 ": %s", at, text);
	return false;
}

/* an address the GPU will use: zero means "off", anything else lies in a live buffer of this device */
static bool address_ok(struct nw_device *d, uint64_t address, uint64_t bytes)
{
	return address == 0 || nw_bo_of_address(d, address, bytes) != NULL;
}

/* The events that write a time stamp to memory: Mesa fd_gpu_events<A6XX>, needs_seqno. */
static bool event_writes(uint32_t e)
{
	switch (e) {
	case CACHE_FLUSH_TS:
	case WT_DONE_TS:
	case RB_DONE_TS:
	case PC_CCU_RESOLVE_TS:
	case PC_CCU_FLUSH_DEPTH_TS:
	case PC_CCU_FLUSH_COLOR_TS:
		return true;
	default:
		return false;
	}
}

/*
 * A write's size, not only its base. FAR 0x1008000 and 0x1068000 (2026-11-03, the compositor's first frames): base + 0x8000, each a small surface, and a base that this check let pass: CA leaves renderTargetWidth at 0, so the clear's bottom right was (w - 1) & 0x3fff = 16383. The rectangle ran past the buffer's last page, and the fault hung the GPU.
 * So what a CP_BLIT or a draw writes must fit its buffer: rows x pitch from the registers this submission wrote. The registers span IBs: a stream that grows goes on in a new IB.
 */
static void shadow_reg(struct nw_check_state *st, uint32_t r, uint32_t v)
{
	if (r >= NW_RB_MRT && r < NW_RB_MRT + 8 * 8) {
		const uint32_t i = (r - NW_RB_MRT) / 8, f = (r - NW_RB_MRT) % 8;
		if (f == 3)
			st->mrt_pitch[i] = v << 6;
		else if (f == 5)
			st->mrt_base[i] = (st->mrt_base[i] & ~0xffffffffull) | v;
		else if (f == 6)
			st->mrt_base[i] = (st->mrt_base[i] & 0xffffffffull) | ((uint64_t)v << 32);
		return;
	}
	switch (r) {
	case NW_RB_2D_BLIT_CNTL: st->blit_solid = (v & NW_RB_2D_BLIT_CNTL_SOLID) != 0; break;
	case NW_RB_2D_DST: st->dst = (st->dst & ~0xffffffffull) | v; break;
	case NW_RB_2D_DST + 1: st->dst = (st->dst & 0xffffffffull) | ((uint64_t)v << 32); break;
	case NW_RB_2D_DST_PITCH: st->dst_pitch = v << 6; break;
	case NW_GRAS_2D_DST_BR: st->dst_br = v; break;
	case NW_SP_PS_2D_SRC: st->src = (st->src & ~0xffffffffull) | v; break;
	case NW_SP_PS_2D_SRC + 1: st->src = (st->src & 0xffffffffull) | ((uint64_t)v << 32); break;
	case NW_SP_PS_2D_SRC_PITCH: st->src_pitch = ((v >> 9) & 0x7fffu) << 6; break;
	case NW_GRAS_2D_SRC_BR_X: st->src_br_x = v; break;
	case NW_GRAS_2D_SRC_BR_Y: st->src_br_y = v; break;
	case NW_GRAS_SC_WINDOW_SCISSOR_BR: st->window_rows = ((v >> 16) & 0x3fffu) + 1; break;
	case NW_RB_STENCIL_BUFFER_PITCH: st->stencil_pitch = v << 6; break;
	case NW_RB_STENCIL_BUFFER_BASE: st->stencil = (st->stencil & ~0xffffffffull) | v; break;
	case NW_RB_STENCIL_BUFFER_BASE + 1: st->stencil = (st->stencil & 0xffffffffull) | ((uint64_t)v << 32); break;
	case NW_RB_DEPTH_BUFFER_PITCH: st->depth_pitch = v << 6; break;
	case NW_RB_DEPTH_BUFFER_BASE: st->depth = (st->depth & ~0xffffffffull) | v; break;
	case NW_RB_DEPTH_BUFFER_BASE + 1: st->depth = (st->depth & 0xffffffffull) | ((uint64_t)v << 32); break;
	default: break;
	}
}

static bool range_fits(struct nw_device *d, uint64_t base, uint64_t bytes)
{
	return nw_bo_of_address(d, base, bytes) != NULL;
}

/* rows x pitch; pitch 0: one row of `columns` bytes (a copy of a buffer as a target of FMT6_8) */
static uint64_t rect_bytes(uint32_t rows, uint32_t pitch, uint32_t columns)
{
	return pitch != 0 ? (uint64_t)rows * pitch : columns;
}

static bool check_blit(struct nw_device *d, const struct nw_check_state *st, uint64_t at, char *why, size_t why_size)
{
	const uint32_t columns = (st->dst_br & 0x3fffu) + 1, rows = ((st->dst_br >> 16) & 0x3fffu) + 1;
	if (st->dst != 0 && !range_fits(d, st->dst, rect_bytes(rows, st->dst_pitch, columns)))
		return refuse(why, why_size, at, "a 2D write of %u x %u, pitch %u, at %#" PRIx64 " runs past its buffer", columns, rows, st->dst_pitch, st->dst);
	if (!st->blit_solid && st->src != 0) {
		/* these two hold a position with 8 bits of fraction (A6XX_GRAS_2D_SRC_BR_X: X, bits 8 to 24): Turnip's capture showed that */
		const uint32_t src_rows = ((st->src_br_y >> 8) & 0x1ffffu) + 1, src_columns = ((st->src_br_x >> 8) & 0x1ffffu) + 1;
		if (!range_fits(d, st->src, rect_bytes(src_rows, st->src_pitch, src_columns)))
			return refuse(why, why_size, at, "a 2D read of %u x %u, pitch %u, at %#" PRIx64 " runs past its buffer", src_columns, src_rows, st->src_pitch, st->src);
	}
	return true;
}

static bool check_targets(struct nw_device *d, const struct nw_check_state *st, uint64_t at, char *why, size_t why_size)
{
	for (uint32_t i = 0; i < 8; i++) {
		if (st->mrt_base[i] != 0 && !range_fits(d, st->mrt_base[i], rect_bytes(st->window_rows, st->mrt_pitch[i], 1)))
			return refuse(why, why_size, at, "target %u: %u rows, pitch %u, at %#" PRIx64 " runs past its buffer", i, st->window_rows, st->mrt_pitch[i], st->mrt_base[i]);
	}
	if (st->depth != 0 && !range_fits(d, st->depth, rect_bytes(st->window_rows, st->depth_pitch, 1)))
		return refuse(why, why_size, at, "depth: %u rows, pitch %u, at %#" PRIx64 " runs past its buffer", st->window_rows, st->depth_pitch, st->depth);
	if (st->stencil != 0 && !range_fits(d, st->stencil, rect_bytes(st->window_rows, st->stencil_pitch, 1)))
		return refuse(why, why_size, at, "stencil: %u rows, pitch %u, at %#" PRIx64 " runs past its buffer", st->window_rows, st->stencil_pitch, st->stencil);
	return true;
}

/* pkt4: a register that holds an address is written as a pair, and the pair's value lies in a live buffer. The bits below 64 bytes hold other things in some registers (a bindless base's size). */
static bool check_pkt4(struct nw_device *d, struct nw_check_state *st, const uint32_t *p, uint32_t reg, uint32_t n, uint64_t at, char *why, size_t why_size)
{
	if (reg + n > 0x10000)
		return refuse(why, why_size, at, "registers %#x + %u: past the register file", reg, n);
	for (uint32_t i = 0; i < n; i++)
		shadow_reg(st, reg + i, p[i]);
	for (uint32_t i = 0; i < n; i++) {
		uint32_t r = reg + i;
		if (!(addr_bits[r >> 3] & (1u << (r & 7))))
			continue;
		if (i + 1 >= n)
			return refuse(why, why_size, at, "register %#x holds an address, and the packet ends after its low word", r);
		uint64_t v = p[i] | ((uint64_t)p[i + 1] << 32);
		if (!address_ok(d, v & ~0x3full, 1))
			return refuse(why, why_size, at, "register %#x = %#" PRIx64 ": no live buffer holds it", r, v);
		i++;
	}
	return true;
}

static bool check_load_state(struct nw_device *d, const uint32_t *p, uint32_t n, uint64_t at, char *why, size_t why_size)
{
	if (n < 3)
		return refuse(why, why_size, at, "CP_LOAD_STATE6 of %u dwords", n);
	const uint32_t src = (p[0] & CP_LOAD_STATE6_0_STATE_SRC__MASK) >> CP_LOAD_STATE6_0_STATE_SRC__SHIFT;
	const uint32_t type = (p[0] & CP_LOAD_STATE6_0_STATE_TYPE__MASK) >> CP_LOAD_STATE6_0_STATE_TYPE__SHIFT;
	const uint32_t units = (p[0] & CP_LOAD_STATE6_0_NUM_UNIT__MASK) >> CP_LOAD_STATE6_0_NUM_UNIT__SHIFT;
	if (src == SS6_INDIRECT) {
		if (n != 3)
			return refuse(why, why_size, at, "an indirect CP_LOAD_STATE6 of %u dwords", n);
		uint64_t v = p[1] | ((uint64_t)p[2] << 32);
		if (v == 0 || !address_ok(d, v, 1))
			return refuse(why, why_size, at, "CP_LOAD_STATE6 from %#" PRIx64 ": no live buffer holds it", v);
		return true;
	}
	if (src != SS6_DIRECT)
		return refuse(why, why_size, at, "CP_LOAD_STATE6 source %u has no rule", src);
	if (type == ST6_CONSTANTS) {
		if (n != 3 + units * 4)
			return refuse(why, why_size, at, "CP_LOAD_STATE6 of %u constants in %u dwords", units, n);
		return true;
	}
	if (type == ST6_UBO) {
		if (n != 3 + units * 2)
			return refuse(why, why_size, at, "CP_LOAD_STATE6 of %u UBOs in %u dwords", units, n);
		for (uint32_t i = 0; i < units; i++) {
			uint64_t v = p[3 + i * 2] | ((uint64_t)(p[4 + i * 2] & 0x1ffffu) << 32);
			if (!address_ok(d, v, 1))
				return refuse(why, why_size, at, "UBO %u at %#" PRIx64 ": no live buffer holds it", i, v);
		}
		return true;
	}
	return refuse(why, why_size, at, "direct CP_LOAD_STATE6 of state type %u has no rule", type);
}

bool nw_stream_check_with(struct nw_device *d, struct nw_check_state *st, const uint32_t *words, uint32_t dwords, uint64_t iova, int level, char *why, size_t why_size)
{
	pthread_once(&addr_once, addr_init);
	uint64_t packets = 0;
	if (words == NULL)
		return refuse(why, why_size, iova, "a stream with no CPU address");
	for (uint32_t i = 0; i < dwords; packets++) {
		const uint32_t h = words[i];
		const uint64_t at = iova + (uint64_t)i * 4;
		uint32_t n;
		if ((h >> 28) == 4) {
			n = h & 0x7f;
			uint32_t reg = (h >> 8) & 0x3ffff;
			if (((h >> 7) & 1) != nw_odd_parity(n) || ((h >> 27) & 1) != nw_odd_parity(reg))
				return refuse(why, why_size, at, "header %08x: parity", h);
			if (n == 0 || i + 1 + n > dwords)
				return refuse(why, why_size, at, "header %08x: %u dwords, %u left in the IB", h, n, dwords - i - 1);
			if (!check_pkt4(d, st, &words[i + 1], reg, n, at, why, why_size))
				return false;
		} else if ((h >> 28) == 7) {
			n = h & 0x3fff;
			uint32_t op = (h >> 16) & 0x7f;
			if (((h >> 15) & 1) != nw_odd_parity(n) || ((h >> 23) & 1) != nw_odd_parity(op))
				return refuse(why, why_size, at, "header %08x: parity", h);
			if (i + 1 + n > dwords)
				return refuse(why, why_size, at, "header %08x: %u dwords, %u left in the IB", h, n, dwords - i - 1);
			const uint32_t *p = &words[i + 1];
			switch (op) {
			case CP_NOP:
				break;
			case CP_WAIT_FOR_IDLE:
			case CP_WAIT_MEM_WRITES:
			case CP_WAIT_FOR_ME:
				if (n != 0)
					return refuse(why, why_size, at, "opcode %#x with %u dwords, it takes none", op, n);
				break;
			case CP_SET_MARKER:
			case CP_SET_MODE:
			case CP_SET_VISIBILITY_OVERRIDE:
			case CP_SKIP_IB2_ENABLE_GLOBAL:
			case CP_BLIT:
				if (n != 1)
					return refuse(why, why_size, at, "opcode %#x with %u dwords, it takes 1", op, n);
				if (op == CP_BLIT && !check_blit(d, st, at, why, why_size))
					return false;
				/* a new pass writes its own targets: a slot of the last pass is not this pass's */
				if (op == CP_SET_MARKER && (p[0] & 0xfu) == NW_MARKER_DIRECT_RENDER) {
					memset(st->mrt_base, 0, sizeof(st->mrt_base));
					st->depth = 0;
					st->stencil = 0;
				}
				break;
			case CP_REG_WRITE:
				if (n != 3)
					return refuse(why, why_size, at, "CP_REG_WRITE with %u dwords", n);
				break;
			case CP_EVENT_WRITE: {
				uint32_t e = n ? (p[0] & CP_EVENT_WRITE_0_EVENT__MASK) : 0;
				if (n == 1) {
					if (event_writes(e)) {
						uint64_t would = i + 3 < dwords ? (words[i + 2] | ((uint64_t)words[i + 3] << 32)) : 0;
						return refuse(why, why_size, at, "event %u writes a time stamp and has no address: the CP would write to %#" PRIx64, e, would);
					}
				} else if (n == 4) {
					uint64_t v = p[1] | ((uint64_t)p[2] << 32);
					if (!event_writes(e))
						return refuse(why, why_size, at, "event %u with an address has no rule", e);
					if (v == 0 || !address_ok(d, v, 4))
						return refuse(why, why_size, at, "event %u writes to %#" PRIx64 ": no live buffer holds it", e, v);
				} else {
					return refuse(why, why_size, at, "CP_EVENT_WRITE with %u dwords", n);
				}
				break;
			}
			case CP_SET_DRAW_STATE:
				/* this stack only clears the groups, as tu6_init_hw */
				if (n != 3 || !(p[0] & CP_SET_DRAW_STATE__0_DISABLE_ALL_GROUPS) || p[1] != 0 || p[2] != 0)
					return refuse(why, why_size, at, "CP_SET_DRAW_STATE with a group has no rule");
				break;
			case CP_LOAD_STATE6_GEOM:
			case CP_LOAD_STATE6_FRAG:
				if (!check_load_state(d, p, n, at, why, why_size))
					return false;
				break;
			case CP_DRAW_INDX_OFFSET:
				if (!check_targets(d, st, at, why, why_size))
					return false;
				if (n == 7) {
					uint64_t v = p[4] | ((uint64_t)p[5] << 32);
					if (v == 0 || !address_ok(d, v, 2))
						return refuse(why, why_size, at, "index buffer at %#" PRIx64 ": no live buffer holds it", v);
				} else if (n != 3) {
					return refuse(why, why_size, at, "CP_DRAW_INDX_OFFSET with %u dwords", n);
				}
				break;
			case CP_DRAW_INDIRECT_MULTI: {
				if (!check_targets(d, st, at, why, why_size))
					return false;
				if (n != 6 && n != 9)
					return refuse(why, why_size, at, "CP_DRAW_INDIRECT_MULTI with %u dwords has no rule", n);
				const uint64_t args = n == 6 ? (p[3] | ((uint64_t)p[4] << 32)) : (p[6] | ((uint64_t)p[7] << 32));
				const uint32_t stride = n == 6 ? p[5] : p[8];
				if (args == 0 || !range_fits(d, args, stride))
					return refuse(why, why_size, at, "draw arguments at %#" PRIx64 ": no live buffer holds %u bytes", args, stride);
				if (n == 9) {
					const uint64_t index = p[3] | ((uint64_t)p[4] << 32);
					if (index == 0 || !address_ok(d, index, 2))
						return refuse(why, why_size, at, "index buffer at %#" PRIx64 ": no live buffer holds it", index);
				}
				break;
			}
			case CP_EXEC_CS:
				if (n != 4)
					return refuse(why, why_size, at, "CP_EXEC_CS with %u dwords", n);
				break;
			case CP_INDIRECT_BUFFER: {
				if (n != 3)
					return refuse(why, why_size, at, "CP_INDIRECT_BUFFER with %u dwords", n);
				/* an a6xx has CP_IB1 and CP_IB2 and no third level (a6xx.xml); Turnip never goes deeper (3 captures, 217 calls, all IB1 -> IB2) */
				if (level >= 2)
					return refuse(why, why_size, at, "a call from an IB2: the a6xx has no third level");
				uint64_t v = p[0] | ((uint64_t)p[1] << 32);
				uint32_t size = p[2];
				if (size == 0 || (v & 3))
					return refuse(why, why_size, at, "a call to %#" PRIx64 " of %u dwords", v, size);
				struct nw_bo *b = nw_bo_of_address(d, v, (uint64_t)size * 4);
				if (b == NULL)
					return refuse(why, why_size, at, "a call to %#" PRIx64 " of %u dwords: no live buffer holds it", v, size);
				if (!nw_ib2_known(d, v, size) && !nw_stream_check_with(d, st, (const uint32_t *)((const char *)b->map + (v - b->iova)), size, v, level + 1, why, why_size))
					return false;
				break;
			}
			default:
				return refuse(why, why_size, at, "opcode %#x has no rule", op);
			}
		} else {
			return refuse(why, why_size, at, "word %08x is no packet header", h);
		}
		i += 1 + n;
	}
	nw_check_count(d, dwords, packets);
	return true;
}

bool nw_stream_check(struct nw_device *d, const uint32_t *words, uint32_t dwords, uint64_t iova, int level, char *why, size_t why_size)
{
	struct nw_check_state st;
	memset(&st, 0, sizeof(st));
	return nw_stream_check_with(d, &st, words, dwords, iova, level, why, why_size);
}
