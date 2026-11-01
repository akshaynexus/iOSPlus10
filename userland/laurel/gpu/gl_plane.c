/*
 * laurel 0005: one plane of an IOSurface as the bound GL_TEXTURE_2D, its own memory (eagl.c: plane_shared, rb4_setup). topaz's gl_osmesa.c has
 * redwood_gl_surface_texture for whole surfaces; this one gives Mesa bits 32-39 = plane + 1 (mesa-tree-patches/0002, kernel 2913: request 0x7c).
 * 1: done. 0: Mesa or the kernel cannot (eagl.c stays with the CPU).
 */
#include <stdint.h>

#define GL_TEXTURE_2D 0x0de1

extern void (*OSMesaGetProcAddress(const char *name))(void);
extern unsigned glGetError(void);

int laurel_gl_plane_texture(uint32_t surface, unsigned plane);

int
laurel_gl_plane_texture(uint32_t surface, unsigned plane)
{
	static void (*image_target)(unsigned target, void *image);

	if (image_target == 0) {
		image_target = (void (*)(unsigned, void *))OSMesaGetProcAddress("glEGLImageTargetTexture2DOES");
	}
	if (image_target == 0) {
		return 0;
	}
	while (glGetError() != 0) {
	}
	image_target(GL_TEXTURE_2D, (void *)(uintptr_t)((uint64_t)surface | (uint64_t)(plane + 1) << 32));
	return glGetError() == 0;
}
