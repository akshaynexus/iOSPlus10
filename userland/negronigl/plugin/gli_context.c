/*
 * NegroniGL.bundle GLI contexts on Mesa. EAGL's private block (-[EAGLContext commonInitWithAPI:] =
 * calloc 0x40e8) has +0x20 GLIContext, +0x28 and +0x2088 two dispatch tables of 1036 slots each.
 *
 * -[EAGLContext commonInitWithAPI:properties:] [V 0x1d3f513f0] calls, through _gli_plugin+0x30:
 *   gliCreateContextWithShared(priv+0x20, pixelformat, gfx_shared_state, priv+0x28, priv+0x2088, flags)
 * flags 0x10/0x20/0x40 = API 1/2/3. We make a Mesa GLES context (negronigl.c ngl_create), store a
 * struct ngl_gli as the GLIContext at *out, and fill both dispatch tables with ngl_dispatch (the
 * 1036-slot table built from gli-slots.txt / eagl.c). Then every glFoo() of OpenGLES does
 * rctx = [priv+0x20]; jump [priv+0x28 + 8*slot], i.e. ngl_dispatch[slot](the ngl_gli, args).
 *
 * gliSetInteger (+0x50) carries -texImageIOSurface: as pname 0x38e {surface ID, target, internal
 * format, w, h, format, type, plane, 0} then 0x399 {target, invert} [V 0x1d3f51efc]. gliGetInteger
 * (+0x58) backs -getParameter:.  Rule: never crash the caller; fail with a CGL error.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "negronigl.h"
#include "gli.h"

/* Mesa object sharing inside one EAGLSharegroup: the first context of a gfx shared state is the lead;
 * the rest share Mesa objects with it. (The gld shared-state pointer identifies the sharegroup.) */
#define NGL_MAX_SHARE 32
static pthread_mutex_t share_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
	void *shared;
	struct ngl_ctx *lead;
	int refs;
} shares[NGL_MAX_SHARE];

static struct ngl_ctx *
share_enter(void *shared)
{
	if (shared == NULL) {
		return NULL;
	}
	struct ngl_ctx *lead = NULL;
	pthread_mutex_lock(&share_lock);
	for (int i = 0; i < NGL_MAX_SHARE; i++) {
		if (shares[i].shared == shared) {
			shares[i].refs++;
			lead = shares[i].lead;
			pthread_mutex_unlock(&share_lock);
			return lead;
		}
	}
	pthread_mutex_unlock(&share_lock);
	return NULL;            /* first of this sharegroup: caller becomes the lead (share_set) */
}

static void
share_set_lead(void *shared, struct ngl_ctx *lead)
{
	if (shared == NULL) {
		return;
	}
	pthread_mutex_lock(&share_lock);
	for (int i = 0; i < NGL_MAX_SHARE; i++) {
		if (shares[i].shared == NULL) {
			shares[i].shared = shared;
			shares[i].lead = lead;
			shares[i].refs = 1;
			break;
		}
	}
	pthread_mutex_unlock(&share_lock);
}

static void
share_leave(void *shared)
{
	if (shared == NULL) {
		return;
	}
	pthread_mutex_lock(&share_lock);
	for (int i = 0; i < NGL_MAX_SHARE; i++) {
		if (shares[i].shared == shared && --shares[i].refs <= 0) {
			shares[i].shared = NULL;
			shares[i].lead = NULL;
			break;
		}
	}
	pthread_mutex_unlock(&share_lock);
}

int
gliCreateContextWithShared(void **out, void *pf, void *shared, void *disp1, void *disp2, uint32_t flags)
{
	(void)pf;
	if (out == NULL) {
		return NGL_ERR_BAD_CONTEXT;
	}
	*out = NULL;
	int api = (flags & 0x40) ? 3 : (flags & 0x20) ? 2 : 1;
	struct ngl_ctx *lead = share_enter(shared);
	struct ngl_gli *g = calloc(1, sizeof(*g));
	struct ngl_state *st = g ? calloc(1, sizeof(*st)) : NULL;
	struct ngl_ctx *ctx = st ? ngl_create(api, lead) : NULL;
	if (ctx == NULL) {
		if (shared != NULL) {
			share_leave(shared);
		}
		free(st);
		free(g);
		ngl_log("negronigl: gliCreateContextWithShared: no Mesa GLES %d context", api);
		return NGL_ERR_BAD_CONTEXT;
	}
	g->rctx = g;
	g->api = (unsigned)api;
	g->ctx = ctx;
	g->st = st;
	g->shared = shared;
	if (shared != NULL && lead == NULL) {
		share_set_lead(shared, ctx);    /* first context of this sharegroup */
	}
	if (disp1 != NULL) {
		memcpy(disp1, ngl_dispatch, sizeof(void *) * NGL_SLOTS);
	}
	if (disp2 != NULL) {
		memcpy(disp2, ngl_dispatch, sizeof(void *) * NGL_SLOTS);
	}
	*out = g;
	ngl_log("negronigl: EAGLContext GLI %p API %d on Mesa%s", (void *)g, api, shared ? " (shared)" : "");
	return 0;
}

int
gliDestroyContext(void *rctx)
{
	struct ngl_gli *g = rctx;
	if (g == NULL) {
		return 0;
	}
	if (ngl_cur == g) {
		ngl_bind(NULL);
	}
	ngl_gli_view_unbind(g);
	share_leave(g->shared);
	ngl_destroy(g->ctx);
	free(g->st);
	free(g);
	return 0;
}

/* params array for pname 0x38e: {surface ID, target, internal format, w, h, format, type, plane, 0} */
static int
set_iosurface(struct ngl_gli *g, const int32_t *p)
{
	IOSurfaceRef s = IOSurfaceLookup((IOSurfaceID)p[0]);
	if (s == NULL) {
		ngl_log("negronigl: gliSetInteger 0x38e: IOSurface %d not found", p[0]);
		return NGL_ERR_BAD_STATE;
	}
	NGL_CUR(g);
	bool ok = ngl_bind_surface(s, NGL_TGT((GLenum)p[1]), (GLenum)p[5], (GLenum)p[6], (uint32_t)p[7],
	    "gliSetInteger");
	CFRelease(s);
	return ok ? 0 : NGL_ERR_BAD_STATE;
}

int
gliSetInteger(void *rctx, uint32_t pname, const int32_t *params)
{
	struct ngl_gli *g = rctx;
	if (g == NULL) {
		return NGL_ERR_BAD_CONTEXT;
	}
	if (pname == 0x38e && params != NULL) {
		return set_iosurface(g, params);
	}
	if (pname == 0x399) {
		/* {target, invert}: the texture is already bound by 0x38e; CA's inverted render handled by
		 * its own geometry. Record nothing, succeed so -texImageIOSurface: does not report failure. */
		static int logged;
		if (params != NULL && params[1] && !__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: gliSetInteger 0x399: inverted IOSurface render (no flip applied)");
		}
		return 0;
	}
	return 0;               /* MTEngine/version/label/fence/profiler integers: accept and ignore */
}

int
gliGetInteger(void *rctx, uint32_t pname, int32_t *out)
{
	(void)pname;
	if ((struct ngl_gli *)rctx == NULL) {
		return NGL_ERR_BAD_CONTEXT;
	}
	if (out != NULL) {
		*out = 0;           /* e.g. profiler storage: no storage */
	}
	return 0;
}
