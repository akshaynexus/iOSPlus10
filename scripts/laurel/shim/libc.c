/*
 * Freestanding helpers for the clang build of the topaz shim (scripts/laurel/shim.sh).
 * GCC expands topaz's __builtin_strcmp calls inline; clang emits real calls (and may emit
 * memcpy/memset/memmove for struct copies), so the shim must define them. Position
 * independent, no data, byte loops only (the shim runs with -mstrict-align).
 */
#include <stddef.h>

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return (unsigned char)*a - (unsigned char)*b;
}

void *memcpy(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;
	while (n--)
		*d++ = *s++;
	return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;
	if (d < s) {
		while (n--)
			*d++ = *s++;
	} else {
		while (n--)
			d[n] = s[n];
	}
	return dst;
}

void *memset(void *dst, int c, size_t n)
{
	unsigned char *d = dst;
	while (n--)
		*d++ = (unsigned char)c;
	return dst;
}
