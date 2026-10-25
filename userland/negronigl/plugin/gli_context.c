/*
 * NegroniGL.bundle GLI contexts on Mesa. EAGL's private block (-[EAGLContext commonInitWithAPI:] =
 * calloc 0x40e8) has +0x20 GLIContext, +0x28 and +0x2088 two dispatch tables of 1036 slots each.
 *
 * -[EAGLContext commonInitWithAPI:properties:] [V 0x1d3f513f0] calls, through _gli_plugin+0x30:
 *   gliCreateContextWithShared(priv+0x20, pixelformat, gfx_shared_state, priv+0x28, priv+0x2088, flags)
 * flags 0x10/0x20/0x40 = API 1/2/3. Every EAGLSharegroup has its own gfx shared state
 * (-loadGLIPlugin: gfxCreateSharedState [V 0x1d3f5213c]), so the shared-state pointer names the
 * sharegroup. We make a Mesa GLES context (negronigl.c ngl_create), store a struct ngl_gli as the
 * GLIContext at *out, and fill both dispatch tables with ngl_dispatch (the 1036-slot table built from
 * gli-slots.txt / eagl.c). Then every glFoo() of OpenGLES does rctx = [priv+0x20]; jump
 * [priv+0x28 + 8*slot], i.e. ngl_dispatch[slot](the ngl_gli, args). +0x2088 is the "back" table of
 * GLCSelectDispatch and GLCRestoreDispatch [V 0x1d3f52a2c..0x1d3f52b10]; a copy of the originals there
 * restores to the same functions.
 *
 * gliSetInteger (+0x50) carries -texImageIOSurface: as pname 0x38e {surface ID, target, internal
 * format, w, h, format, type, plane, 0} then 0x399 {target, invert} [V 0x1d3f51efc]. gliGetInteger
 * (+0x58) backs -getParameter:. Rule: never crash or block the caller; fail with a CGL error.
 *
 * Threads: EAGL may destroy a context on a thread other than the one where it is current (ARC
 * releases on any thread). Mesa still points at it there, and the next make-current on that thread
 * reads the old context. So a context that is ngl_cur on another thread is only marked (zombie) and
 * freed by ngl_gli_bound() when that thread switches away (eagl.c ngl_bind).
 */
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "negronigl.h"
#include "gli.h"

/*
 * Mesa object sharing inside one EAGLSharegroup: a new context shares with any live context of the
 * same gfx shared state. share_lock covers the list and is held across ngl_create, so the context we
 * share with cannot be freed while Mesa takes its shared state (destroy unlinks under the lock first).
 */
static pthread_mutex_t share_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ngl_gli *contexts;        /* live plugin contexts, linked by share_next */

/* binds / zombie of every plugin context */
static pthread_mutex_t bind_lock = PTHREAD_MUTEX_INITIALIZER;

static void
share_unlink(struct ngl_gli *g)
{
	pthread_mutex_lock(&share_lock);
	for (struct ngl_gli **p = &contexts; *p != NULL; p = &(*p)->share_next) {
		if (*p == g) {
			*p = g->share_next;
			break;
		}
	}
	g->share_next = NULL;
	pthread_mutex_unlock(&share_lock);
}

static void
reap(struct ngl_gli *g)
{
	ngl_destroy(g->ctx);    /* binds == 0: Mesa has it current on no thread */
	free(g->st);
	free(g);
}

/* eagl.c ngl_bind: this thread switched from old to g (either may be NULL) */
void
ngl_gli_bound(struct ngl_gli *old, struct ngl_gli *g)
{
	struct ngl_gli *dead = NULL;
	pthread_mutex_lock(&bind_lock);
	if (g != NULL) {
		g->binds++;
	}
	if (old != NULL && --old->binds <= 0 && old->zombie) {
		dead = old;
	}
	pthread_mutex_unlock(&bind_lock);
	if (dead != NULL) {
		reap(dead);
		ngl_log("negronigl: GLI %p freed now that its last thread switched away", (void *)dead);
	}
}

NGL_GLD int
gliCreateContextWithShared(void **out, void *pf, void *shared, void *disp1, void *disp2, uint32_t flags)
{
	(void)pf;
	if (out == NULL) {
		return NGL_ERR_BAD_CONTEXT;
	}
	*out = NULL;
	int api = (flags & 0x40) ? 3 : (flags & 0x20) ? 2 : 1;
	struct ngl_gli *g = calloc(1, sizeof(*g));
	struct ngl_state *st = g ? calloc(1, sizeof(*st)) : NULL;
	if (st == NULL) {
		free(g);
		return NGL_ERR_BAD_ALLOC;
	}
	pthread_mutex_lock(&share_lock);
	struct ngl_gli *lead = NULL;
	for (struct ngl_gli *c = contexts; c != NULL && shared != NULL; c = c->share_next) {
		if (c->shared == shared) {
			lead = c;
			break;
		}
	}
	struct ngl_ctx *ctx = ngl_create(api, lead ? lead->ctx : NULL);
	if (ctx != NULL) {
		g->rctx = g;
		g->api = (unsigned)api;
		g->ctx = ctx;
		g->st = st;
		g->shared = shared;
		g->share_next = contexts;
		contexts = g;
	}
	pthread_mutex_unlock(&share_lock);
	if (ctx == NULL) {
		free(st);
		free(g);
		ngl_log("negronigl: gliCreateContextWithShared: no Mesa GLES %d context", api);
		return NGL_ERR_BAD_CONTEXT;
	}
	if (disp1 != NULL) {
		memcpy(disp1, ngl_dispatch, sizeof(void *) * NGL_SLOTS);
	}
	if (disp2 != NULL) {
		memcpy(disp2, ngl_dispatch, sizeof(void *) * NGL_SLOTS);
	}
	*out = g;
	ngl_log("negronigl: EAGLContext GLI %p API %d on Mesa%s", (void *)g, api, lead ? " (shares objects)" : "");
	return 0;
}

/* -[EAGLContext dealloc] (0x1d3f51714) calls this, then zeroes both dispatch tables */
NGL_GLD int
gliDestroyContext(void *rctx)
{
	struct ngl_gli *g = rctx;
	if (g == NULL) {
		return 0;
	}
	ngl_gli_view_unbind(g);         /* detach the drawable (no GL calls) */
	if (ngl_cur == g) {
		ngl_bind(NULL);         /* Mesa leaves g on this thread */
	}
	share_unlink(g);
	pthread_mutex_lock(&bind_lock);
	bool later = g->binds > 0;      /* still ngl_cur on another thread */
	if (later) {
		g->zombie = true;
	}
	pthread_mutex_unlock(&bind_lock);
	if (later) {
		ngl_log("negronigl: GLI %p destroyed while current on another thread: freed when it switches",
		    (void *)g);
		return 0;
	}
	reap(g);
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

NGL_GLD int
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
		/* {target, invert}: the texture is already bound by 0x38e. The flip is not applied (open). */
		static int logged;
		if (params != NULL && params[1] && !__atomic_exchange_n(&logged, 1, __ATOMIC_RELAXED)) {
			ngl_log("negronigl: gliSetInteger 0x399: inverted IOSurface render (no flip applied)");
		}
		return 0;
	}
	if (pname == 0x263 || pname == 0x264) {
		/* -setBlockFence:onQueue: (0x1d3f52018): we never call the block back, so refuse (the
		 * method returns NO) instead of letting a caller wait for it */
		return NGL_ERR_BAD_ATTRIBUTE;
	}
	return 0;               /* MTEngine/version/label/profiler integers: accept and ignore */
}

NGL_GLD int
gliGetInteger(void *rctx, uint32_t pname, void *out)
{
	if ((struct ngl_gli *)rctx == NULL) {
		return NGL_ERR_BAD_CONTEXT;
	}
	if (out == NULL) {
		return 0;
	}
	if (pname == 0x7aa) {
		*(void **)out = NULL;   /* GLCGetProfilerStorage (0x1d3f5299c) reads 8 bytes: no storage */
	} else {
		*(int32_t *)out = 0;    /* e.g. 0x139 (isMultiThreaded): no */
	}
	return 0;
}
