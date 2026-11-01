/*
 * Hot-loop shapes of the Mi A3 GPU user space, for scripts/laurel/cpu-tune-mca.sh (llvm-mca: static throughput on the
 * Cortex-A53 and Cortex-A73 models, per -mtune). Fixed trip counts: the compiler unrolls them into one straight block.
 * Not built into any product.
 */
#include <stdint.h>


/* Mesa util_format style: float RGBA -> BGRA8 unorm (texture uploads, CA colour packing), 16 pixels */
void k_pack_bgra8(uint32_t *restrict dst, const float *restrict src)
{
	for (int i = 0; i < 16; i++) {
		float r = src[4 * i], g = src[4 * i + 1], b = src[4 * i + 2], a = src[4 * i + 3];
		uint32_t R = (uint32_t)(r * 255.0f + 0.5f), G = (uint32_t)(g * 255.0f + 0.5f);
		uint32_t B = (uint32_t)(b * 255.0f + 0.5f), A = (uint32_t)(a * 255.0f + 0.5f);
		dst[i] = (A << 24) | (R << 16) | (G << 8) | B;
	}
}

/* fdl6 tiled copy style: 64-byte block moves with a swizzled destination offset, 8 blocks */
void k_tile_copy(uint8_t *restrict dst, const uint8_t *restrict src, uint32_t x)
{
	for (int i = 0; i < 8; i++) {
		uint32_t xi = x + (uint32_t)i;
		uint32_t off = ((xi & 1) << 6) | ((xi & 2) << 8) | ((xi & ~3u) << 9);
		__builtin_memcpy(dst + off, src + 64 * i, 64);
	}
}

/* pipeline-cache key / hash-table style: FNV-1a over 64 bytes + mix (metal2vulkan tracker, Mesa hash tables) */
uint64_t k_hash(const uint8_t *p)
{
	uint64_t h = 0xcbf29ce484222325ull;
	for (int i = 0; i < 64; i++) {
		h = (h ^ p[i]) * 0x100000001b3ull;
	}
	h ^= h >> 33;
	h *= 0xff51afd7ed558ccdull;
	h ^= h >> 33;
	return h;
}

/* command-stream emit style: PKT7 headers with parity + register writes into a buffer (Turnip tu_cs, eagl draw state) */
static inline uint32_t par(uint32_t v)
{
	return (0x9669 >> (0xF & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^ (v >> 20) ^ (v >> 24) ^ (v >> 28)))) & 1;
}
uint32_t *k_emit(uint32_t *cs, const uint32_t *regs, const uint32_t *vals)
{
	for (int i = 0; i < 8; i++) {
		uint32_t cnt = 2, op = regs[i] & 0x7f;
		*cs++ = 0x70000000u | cnt | (par(cnt) << 15) | (op << 16) | (par(op) << 23);
		*cs++ = regs[i];
		*cs++ = vals[i];
	}
	return cs;
}

/* blend / premultiply style, 16 pixels of BGRA8 (CPU fallbacks, eagl still-surface sums) */
void k_premul(uint32_t *restrict px)
{
	for (int i = 0; i < 16; i++) {
		uint32_t v = px[i], a = v >> 24;
		uint32_t rb = ((v & 0x00ff00ffu) * a + 0x00800080u) >> 8 & 0x00ff00ffu;
		uint32_t g = ((v & 0x0000ff00u) * a + 0x00008000u) >> 8 & 0x0000ff00u;
		px[i] = (v & 0xff000000u) | rb | g;
	}
}
