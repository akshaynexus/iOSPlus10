/*
 * NegroniGL.bundle GLI layer (the 18 entry points OpenGLES's eagl_init binds, docs/notes.md 15):
 *   gli_table.c    the table, registration, pixel format, version, renderer-info/attribute stubs
 *   gli_context.c  context create/destroy on Mesa, SetInteger/GetInteger (0x38e/0x399 IOSurface)
 *   gli_view.c     BindViewES/PresentViewES (renderbuffer storage from a drawable's IOSurface)
 *
 * eagl_init (0x1d3f52444) stores GLEngine's dlopen handle at _gli_plugin[0] (0x1e25b0da0), calls
 * gliInitializeLibrary -> gfxInitializeLibrary -> our gldInitializeLibrary (so ngl_gli_register runs
 * here), then a loop dlsym()s the 18 names of _eagl_gli_names from _gli_plugin[0] into +0x08..+0x90.
 * ngl_gli_register overwrites _gli_plugin[0] with our bundle handle, so the loop binds our exports.
 */
#ifndef NGL_GLI_H
#define NGL_GLI_H

#include <stdint.h>
#include <IOSurface/IOSurfaceRef.h>

#include "gld.h"

struct ngl_gli;         /* negronigl.h */

/* gli_context.c, called by gli_table.c's gliCreateContext */
int gliCreateContextWithShared(void **out, void *pf, void *shared, void *disp1, void *disp2, uint32_t flags);

/* drawables: ngl_view_bind / ngl_view_unbind / ngl_view_present (../view.c, negronigl.h) */

#endif
