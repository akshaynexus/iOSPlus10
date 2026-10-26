/*
 * negronigl EAGL shim: CoreAnimation's OpenGL ES renderer (CA::OGL::GLESContext) on Mesa.
 *
 * CA uses EAGLContext through -initWithAPI:properties:, -API, -setParameter:to:,
 * -getMacroContextPrivate, -texImageIOSurface:..., -attachImage:toCoreSurface:invertedRender:,
 * +setCurrentContext: and +currentContext. Every GL call goes through the GLI table from
 * -getMacroContextPrivate: {rctx, disp[1036]}, called as disp[slot](rctx, args) (gli-slots.txt,
 * gli_dispatch.c). These methods are replaced; contexts made before, or that Mesa cannot make,
 * stay Apple's. Method list: ios-sailfish tools/sweetgl/eagl.c and HackiOS userland/src/eagl.c (MIT).
 */
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

#include "negronigl.h"

typedef unsigned long NSUInteger;
#ifndef YES
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#endif

__thread struct ngl_gli *ngl_cur;
int ngl_check_errors;

#define MAX_CTX 32
static struct ngl_gli *ctxs[MAX_CTX];
static pthread_mutex_t ctx_lock = PTHREAD_MUTEX_INITIALIZER;
static IMP orig_init, orig_dealloc, orig_api, orig_set_param, orig_macro, orig_tex_iosurface, orig_tex_iosurface9,
    orig_attach, orig_set_current, orig_current, orig_rb_storage, orig_present, orig_present_at, orig_present_after;

static struct ngl_gli *
lookup(id eagl)
{
	struct ngl_gli *g = NULL;
	pthread_mutex_lock(&ctx_lock);
	for (int i = 0; i < MAX_CTX && g == NULL && eagl != nil; i++) {
		if (ctxs[i] && ctxs[i]->eagl == (void *)eagl) {
			g = ctxs[i];
		}
	}
	pthread_mutex_unlock(&ctx_lock);
	return g;
}

void
ngl_bind(struct ngl_gli *g)
{
#ifdef NGL_PLUGIN
	struct ngl_gli *old = ngl_cur;
#endif
	ngl_make_current(g ? g->ctx : NULL);
	ngl_cur = g;
#ifdef NGL_PLUGIN
	/* NegroniGL.bundle: a context destroyed on another thread while current here is freed only
	 * now, after Mesa switched away from it (plugin/gli_context.c gliDestroyContext) */
	if (old != g) {
		ngl_gli_bound(old, g);
	}
#endif
}

void
ngl_unsupported(int slot)
{
	static unsigned char seen[NGL_SLOTS];
	if (slot >= 0 && slot < NGL_SLOTS && !seen[slot]) {
		seen[slot] = 1;
		ngl_log("negronigl: unsupported GLI slot %d (%s)", slot, ngl_slot_names[slot]);
	}
}

void
ngl_post(int slot)
{
	static unsigned char logged[NGL_SLOTS];
	GLenum e = glGetError();
	if (e != GL_NO_ERROR && slot >= 0 && slot < NGL_SLOTS && logged[slot] < 3) {
		logged[slot]++;
		ngl_log("negronigl: GL error %#x after slot %d %s", e, slot, ngl_slot_names[slot]);
	}
}

/* ---- texture units: Apple's GL keeps a 2D and a rect binding per unit, Mesa's ES only 2D ---- */

int
ngl_active_unit(void)
{
	GLint active = GL_TEXTURE0;
	glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
	return (active - GL_TEXTURE0) & (NGL_UNITS - 1);
}

GLenum
ngl_tgt(GLenum target)
{
	struct ngl_state *st = ngl_cur ? ngl_cur->st : NULL;
	if (st != NULL) {
		int u = ngl_active_unit();
		GLuint want = target == GL_TEXTURE_2D ? st->unit_2d[u] : st->unit_rect[u];
		if (st->unit_held[u] != want) {
			glBindTexture(GL_TEXTURE_2D, want);
			st->unit_held[u] = want;
		}
	}
	return GL_TEXTURE_2D;
}

/* level-0 size of the texture bound to the active unit (rect scale without GL queries) */
void
ngl_tex_size(GLenum target, GLint level, GLsizei w, GLsizei h)
{
	struct ngl_state *st = ngl_cur ? ngl_cur->st : NULL;
	if (st == NULL || level != 0 || (target != GL_TEXTURE_2D && target != NGL_GL_TEXTURE_RECTANGLE)) {
		return;
	}
	GLint tex = 0;
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
	if (tex > 0 && tex < NGL_NAMES) {
		st->tex_w[tex] = (uint16_t)w;
		st->tex_h[tex] = (uint16_t)h;
	}
}

/* ---- hand-written GLI slots (gen-gli.py HAND) ---- */

static struct ngl_state *
st_of(void *rctx)
{
	return ((struct ngl_gli *)rctx)->st;
}

/* Apple's slot 591 is DeleteObjectARB: a shader or a program */
void
ngl_h_DeleteObject(void *rctx, GLuint obj)
{
	NGL_CUR(rctx);
	if (glIsProgram(obj)) {
		glDeleteProgram(obj);
	} else {
		ngl_shader_deleted(st_of(rctx), obj);
		glDeleteShader(obj);
	}
	NGL_POST(591);
}

void
ngl_h_ShaderSource(void *rctx, GLuint shader, GLsizei count, const GLchar *const *string, const GLint *length)
{
	NGL_CUR(rctx);
	size_t n = 0;
	for (GLsizei i = 0; i < count; i++) {
		n += length && length[i] >= 0 ? (size_t)length[i] : strlen(string[i]);
	}
	char *src = malloc(n + 1), *p = src;
	if (src == NULL) {
		glShaderSource(shader, count, string, length);
		return;
	}
	for (GLsizei i = 0; i < count; i++) {
		size_t l = length && length[i] >= 0 ? (size_t)length[i] : strlen(string[i]);
		memcpy(p, string[i], l);
		p += l;
	}
	*p = 0;
	src = ngl_shader_rewrite(st_of(rctx), shader, src);
	const GLchar *one = src;
	glShaderSource(shader, 1, &one, NULL);
	free(src);
	NGL_POST(595);
}

/* failures logged with the info log and the source: CA does not ask */
void
ngl_h_CompileShader(void *rctx, GLuint shader)
{
	NGL_CUR(rctx);
	glCompileShader(shader);
	GLint ok = 0;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		static char log[1024], src[4096];
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		glGetShaderSource(shader, sizeof(src), NULL, src);
		ngl_log("negronigl: shader %u compile failed: %.400s", shader, log);
		for (size_t i = 0, n = strlen(src); i < n; i += 400) {
			ngl_log("negronigl:   src %.400s", src + i);
		}
	}
}

void
ngl_h_LinkProgram(void *rctx, GLuint program)
{
	NGL_CUR(rctx);
	glLinkProgram(program);
	GLint ok = 0;
	glGetProgramiv(program, GL_LINK_STATUS, &ok);
	if (ok) {
		ngl_program_linked(st_of(rctx), program);
	} else {
		static char log[1024];
		glGetProgramInfoLog(program, sizeof(log), NULL, log);
		ngl_log("negronigl: program %u link failed: %.400s", program, log);
	}
}

const GLubyte *
ngl_h_GetString(void *rctx, GLenum name)
{
	NGL_CUR(rctx);
	const GLubyte *s = glGetString(name);
	if (name == GL_EXTENSIONS) {
		return (const GLubyte *)ngl_extensions((const char *)s);
	}
	return s;
}

/* Apple's ES takes internalformat GL_RGBA with format GL_BGRA; Mesa wants GL_BGRA for both */
void
ngl_h_TexImage2D(void *rctx, GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
    GLint border, GLenum format, GLenum type, const GLvoid *pixels)
{
	NGL_CUR(rctx);
	struct ngl_state *st = st_of(rctx);
	target = NGL_TGT(target);
	ngl_copy_forget(st, st->unit_held[ngl_active_unit()]);
	ngl_set_swizzle(st, target, false);
	if (format == GL_BGRA_EXT && (internalformat == GL_RGBA || internalformat == GL_RGBA8)) {
		internalformat = GL_BGRA_EXT;
	}
	glTexImage2D(target, level, internalformat, width, height, border, format, type, pixels);
	NGL_POST(301);
	ngl_tex_size(target, level, width, height);
}

void
ngl_h_BindTexture(void *rctx, GLenum target, GLuint texture)
{
	NGL_CUR(rctx);
	struct ngl_state *st = st_of(rctx);
	if (target == GL_TEXTURE_2D || target == NGL_GL_TEXTURE_RECTANGLE) {
		int u = ngl_active_unit();
		*(target == GL_TEXTURE_2D ? &st->unit_2d[u] : &st->unit_rect[u]) = texture;
		st->unit_held[u] = texture;
		glBindTexture(GL_TEXTURE_2D, texture);
	} else {
		glBindTexture(target, texture);
	}
	NGL_POST(5);
}

/* GL unbinds deleted textures from every unit: so do the shadows */
void
ngl_h_DeleteTextures(void *rctx, GLsizei n, const GLuint *textures)
{
	NGL_CUR(rctx);
	struct ngl_state *st = st_of(rctx);
	for (GLsizei i = 0; i < n; i++) {
		GLuint t = textures[i];
		ngl_copy_forget(st, t);
		if (t < NGL_NAMES) {
			st->tex_argb[t] = 0;
			st->tex_w[t] = st->tex_h[t] = 0;
		}
		for (int u = 0; u < NGL_UNITS; u++) {
			if (st->unit_2d[u] == t) {
				st->unit_2d[u] = 0;
			}
			if (st->unit_rect[u] == t) {
				st->unit_rect[u] = 0;
			}
			if (st->unit_held[u] == t) {
				st->unit_held[u] = 0;
			}
		}
	}
	glDeleteTextures(n, textures);
	NGL_POST(59);
}

void
ngl_h_FramebufferTexture2D(void *rctx, GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level)
{
	NGL_CUR(rctx);
	glFramebufferTexture2D(target, attachment, textarget == NGL_GL_TEXTURE_RECTANGLE ? GL_TEXTURE_2D : textarget,
	    texture, level);
	NGL_POST(677);
}

/*
 * glFlush (view.c ngl_flush): the flush submits the batch at once (an imported IOSurface is a
 * shared bo, so freedreno does not defer the submit), the kernel marks every IOSurface listed in it
 * with the submission's fence, and the display waits on the fence recorded at SwapEnd (patch 0254,
 * docs/gpu-abi.md section 8). NEGRONIGL_FINISH=1 puts back glFinish on every flush (the ios-spes
 * default; needed with a kernel older than 0254).
 */
void
ngl_h_Flush(void *rctx)
{
	NGL_CUR(rctx);
	ngl_flush();
}

void
ngl_h_FinishObjectAPPLE(void *rctx, GLenum object, GLint name)
{
	NGL_CUR(rctx);
	glFinish();
}

GLboolean
ngl_h_TestObjectAPPLE(void *rctx, GLenum object, GLuint name)
{
	NGL_CUR(rctx);
	glFinish();
	return GL_TRUE;
}

void
ngl_h_FinishFenceAPPLE(void *rctx, GLuint fence)
{
	NGL_CUR(rctx);
	glFinish();
}

/* ---- before each draw ---- */

/* name of the color texture of the bound FBO, 0 if none */
static GLint
fb_texture(void)
{
	GLint fb = 0, type = 0, att = 0;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
	if (fb == 0) {
		return 0;
	}
	glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE,
	    &type);
	if (type != GL_TEXTURE) {
		return 0;
	}
	glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,
	    &att);
	return att;
}

static void
tex_size_of(struct ngl_state *st, GLuint tex, int unit, GLint *w, GLint *h)
{
	*w = *h = 0;
	if (tex < NGL_NAMES) {
		*w = st->tex_w[tex];
		*h = st->tex_h[tex];
	}
	if (*w <= 0 || *h <= 0) {
		GLint active = GL_TEXTURE0;
		glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
		glActiveTexture(GL_TEXTURE0 + unit);
		glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, w);
		glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, h);
		glActiveTexture(active);
	}
}

/* which units the program's samplers read (read once per link; CA sets them at link time) */
static uint16_t
program_units(struct ngl_state *st, GLint prog)
{
	if (prog <= 0 || prog >= NGL_NAMES) {
		return 0;
	}
	if (!(st->prog_units[prog] & 0x8000)) {
		uint16_t m = 0x8000;
		GLint n = 0;
		glGetProgramiv(prog, GL_ACTIVE_UNIFORMS, &n);
		for (GLint i = 0; i < n; i++) {
			char name[64];
			GLint size = 0, unit = 0;
			GLenum t = 0;
			glGetActiveUniform(prog, i, sizeof(name), NULL, &size, &t, name);
			if (t == GL_SAMPLER_2D) {
				glGetUniformiv(prog, glGetUniformLocation(prog, name), &unit);
				m |= unit >= 0 && unit < NGL_FBFETCH_UNIT ? (uint16_t)(1u << unit) : 0;
			}
		}
		st->prog_units[prog] = m;
	}
	return st->prog_units[prog];
}

static void
draw_prep(struct ngl_state *st)
{
	GLint prog = 0;
	glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
	struct ngl_rect_prog *rp = prog > 0 && prog < NGL_NAMES && st->rect_prog[prog].program ? &st->rect_prog[prog] : NULL;
	GLint rect_unit = -1;
	if (rp != NULL) {
		rect_unit = 0;
		if (rp->sampler >= 0) {
			glGetUniformiv(prog, rp->sampler, &rect_unit);
		}
	}
	int active = -1;
	for (int u = 0; u < NGL_FBFETCH_UNIT; u++) {
		GLuint want = u == rect_unit ? st->unit_rect[u] : st->unit_2d[u];
		if (st->unit_held[u] != want) {
			if (active < 0) {
				active = ngl_active_unit();
			}
			glActiveTexture(GL_TEXTURE0 + u);
			glBindTexture(GL_TEXTURE_2D, want);
			st->unit_held[u] = want;
		}
		if (want != 0) {
			ngl_copy_refresh(st, u, &active);
		}
	}
	if (active >= 0) {
		glActiveTexture(GL_TEXTURE0 + active);
	}
	if (rp != NULL && rp->scale >= 0 && rect_unit >= 0 && rect_unit < NGL_UNITS) {
		GLint w, h;
		tex_size_of(st, st->unit_rect[rect_unit], rect_unit, &w, &h);
		glUniform2f(rp->scale, w > 0 ? 1.0f / (GLfloat)w : 1.0f, h > 0 ? 1.0f / (GLfloat)h : 1.0f);
	}
	GLint fbt = prog > 0 ? fb_texture() : 0;
	if (fbt <= 0) {
		return;
	}
	bool barrier = false;
	if (prog < NGL_NAMES && st->fbf_sampler[prog] > 0) {
		/* emulated framebuffer fetch: the color texture on its own unit */
		GLint w, h, act = GL_TEXTURE0;
		glGetIntegerv(GL_ACTIVE_TEXTURE, &act);
		glActiveTexture(GL_TEXTURE0 + NGL_FBFETCH_UNIT);
		glBindTexture(GL_TEXTURE_2D, (GLuint)fbt);
		st->unit_held[NGL_FBFETCH_UNIT] = (GLuint)fbt;
		glActiveTexture(act);
		tex_size_of(st, (GLuint)fbt, NGL_FBFETCH_UNIT, &w, &h);
		glUniform1i(st->fbf_sampler[prog] - 1, NGL_FBFETCH_UNIT);
		if (st->fbf_scale[prog] > 0) {
			glUniform2f(st->fbf_scale[prog] - 1, w > 0 ? 1.0f / (GLfloat)w : 1.0f, h > 0 ? 1.0f / (GLfloat)h : 1.0f);
		}
		barrier = true;
	}
	/* CA reads the destination by sampling the texture it renders into: earlier draws must land first */
	uint16_t units = program_units(st, prog);
	for (int u = 0; u < NGL_FBFETCH_UNIT && !barrier; u++) {
		barrier = (units & (1u << u)) && st->unit_held[u] == (GLuint)fbt;
	}
	if (barrier) {
		glTextureBarrierNV();
	}
}

void
ngl_h_DrawArrays(void *rctx, GLenum mode, GLint first, GLsizei count)
{
	NGL_CUR(rctx);
	draw_prep(st_of(rctx));
	glDrawArrays(mode, first, count);
	NGL_POST(65);
}

void
ngl_h_DrawElements(void *rctx, GLenum mode, GLsizei count, GLenum type, const GLvoid *indices)
{
	NGL_CUR(rctx);
	draw_prep(st_of(rctx));
	glDrawElements(mode, count, type, indices);
	NGL_POST(67);
}

/* ---- EAGLContext methods ---- */

static id
m_init(id self, SEL cmd, NSUInteger api, id props)
{
	struct ngl_ctx *ctx = api >= 2 && ngl_init() ? ngl_create((int)api, NULL) : NULL;
	struct ngl_gli *g = ctx ? calloc(1, sizeof(*g)) : NULL;
	struct ngl_state *st = g ? calloc(1, sizeof(*st)) : NULL;
	int slot = -1;
	pthread_mutex_lock(&ctx_lock);
	for (int i = 0; i < MAX_CTX && slot < 0 && st; i++) {
		if (ctxs[i] == NULL) {
			slot = i;
			g->rctx = g;
			memcpy(g->disp, ngl_dispatch, sizeof(g->disp));
			g->eagl = (void *)self;
			g->api = (unsigned)api;
			g->ctx = ctx;
			g->st = st;
			ctxs[i] = g;
		}
	}
	pthread_mutex_unlock(&ctx_lock);
	if (slot < 0) {
		free(st);
		free(g);
		ngl_destroy(ctx);
		ngl_log("negronigl: EAGLContext API %lu: no Mesa context, Apple's EAGL instead", api);
		return ((id (*)(id, SEL, NSUInteger, id))orig_init)(self, cmd, api, props);
	}
	ngl_log("negronigl: EAGLContext %p API %lu on Mesa (GLI %p)", (void *)self, api, (void *)g);
	return self;
}

static void
m_dealloc(id self, SEL cmd)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		((void (*)(id, SEL))orig_dealloc)(self, cmd);
		return;
	}
	pthread_mutex_lock(&ctx_lock);
	for (int i = 0; i < MAX_CTX; i++) {
		if (ctxs[i] == g) {
			ctxs[i] = NULL;
		}
	}
	pthread_mutex_unlock(&ctx_lock);
	ngl_view_unbind(g);             /* detach the CAEAGLLayer drawable, if any (no GL calls) */
	if (ngl_cur == g) {
		ngl_bind(NULL);
	}
	ngl_destroy(g->ctx);
	free(g->st);
	free(g);
	/* EAGLContext's own init never ran for it: skip its dealloc, run NSObject's */
	struct objc_super sup = {self, class_getSuperclass(objc_getClass("EAGLContext"))};
	((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, cmd);
}

static NSUInteger
m_api(id self, SEL cmd)
{
	struct ngl_gli *g = lookup(self);
	return g ? g->api : ((NSUInteger (*)(id, SEL))orig_api)(self, cmd);
}

static BOOL
m_set_param(id self, SEL cmd, uint32_t pname, const int32_t *value)
{
	if (lookup(self) == NULL) {
		return ((BOOL (*)(id, SEL, uint32_t, const int32_t *))orig_set_param)(self, cmd, pname, value);
	}
	ngl_log("negronigl: setParameter %#x to %d (ignored)", pname, value ? *value : 0);
	return YES;
}

static void *
m_macro(id self, SEL cmd)
{
	struct ngl_gli *g = lookup(self);
	return g ? (void *)g : ((void *(*)(id, SEL))orig_macro)(self, cmd);
}

/* -texImageIOSurface:target:internalFormat:width:height:format:type:plane:invert: (CA's) */
static BOOL
m_tex_iosurface9(id self, SEL cmd, IOSurfaceRef s, NSUInteger target, NSUInteger ifmt, uint32_t w, uint32_t h,
    NSUInteger format, NSUInteger type, uint32_t plane, BOOL invert)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, IOSurfaceRef, NSUInteger, NSUInteger, uint32_t, uint32_t, NSUInteger, NSUInteger,
		    uint32_t, BOOL))orig_tex_iosurface9)(self, cmd, s, target, ifmt, w, h, format, type, plane, invert);
	}
	NGL_CUR(g);
	return ngl_bind_surface(s, NGL_TGT((GLenum)target), (GLenum)format, (GLenum)type, plane, "texImageIOSurface");
}

/* the public -texImageIOSurface:target:internalFormat:width:height:format:type:plane: */
static BOOL
m_tex_iosurface(id self, SEL cmd, IOSurfaceRef s, NSUInteger target, NSUInteger ifmt, uint32_t w, uint32_t h,
    NSUInteger format, NSUInteger type, uint32_t plane)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, IOSurfaceRef, NSUInteger, NSUInteger, uint32_t, uint32_t, NSUInteger, NSUInteger,
		    uint32_t))orig_tex_iosurface)(self, cmd, s, target, ifmt, w, h, format, type, plane);
	}
	NGL_CUR(g);
	return ngl_bind_surface(s, NGL_TGT((GLenum)target), (GLenum)format, (GLenum)type, plane, "texImageIOSurface");
}

static BOOL
m_attach(id self, SEL cmd, NSUInteger target, IOSurfaceRef s, BOOL inverted)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, NSUInteger, IOSurfaceRef, BOOL))orig_attach)(self, cmd, target, s, inverted);
	}
	NGL_CUR(g);
	return ngl_bind_surface(s, NGL_TGT((GLenum)target), 0, 0, 0, "attachImage");
}

/*
 * -renderbufferStorage:fromDrawable: on a Mesa context, as Apple's [V 20H392 0x1d3f518f4]: target must
 * be GL_RENDERBUFFER, the drawable must answer -nativeWindow (CAEAGLLayer: the _CAEAGLNativeWindow
 * table) and -drawableProperties (kEAGLDrawablePropertyRetainedBacking, ...ColorFormat). Apple then
 * calls gliBindViewES(ctx, NULL) and gliBindViewES(ctx, nativeWindow, retained, colorformat); view.c
 * ngl_view_bind does both steps. A nil drawable only detaches (Apple: YES).
 */
#define NGL_GL_RENDERBUFFER 0x8D41

static unsigned
color_format(id props, unsigned *retained)
{
	*retained = 0;
	unsigned fmt = 0x8058;                  /* GL_RGBA8_OES: EAGLColorFormatRGBA8 and nil */
	if (props == nil) {
		return fmt;
	}
	id key = (id)CFSTR("EAGLDrawablePropertyRetained");
	id v = ((id (*)(id, SEL, id))objc_msgSend)(props, sel_registerName("objectForKey:"), key);
	if (v != nil) {
		*retained = ((BOOL (*)(id, SEL))objc_msgSend)(v, sel_registerName("boolValue")) ? 1 : 0;
	}
	id c = ((id (*)(id, SEL, id))objc_msgSend)(props, sel_registerName("objectForKey:"),
	    (id)CFSTR("EAGLDrawablePropertyColorFormat"));
	if (c != nil && CFGetTypeID((CFTypeRef)c) == CFStringGetTypeID()) {
		if (CFStringCompare((CFStringRef)c, CFSTR("EAGLColorFormat565"), 0) == kCFCompareEqualTo) {
			fmt = 0x8D62;           /* GL_RGB565: drawn as BGRA, CA composites it the same */
		} else if (CFStringCompare((CFStringRef)c, CFSTR("EAGLColorFormatS8888"), 0) == kCFCompareEqualTo) {
			fmt = 0x8C43;           /* GL_SRGB8_ALPHA8: drawn as BGRA unorm (no sRGB encode) */
		} else if (CFStringCompare((CFStringRef)c, CFSTR("EAGLColorFormat8888"), 0) != kCFCompareEqualTo) {
			fmt = 0x93F2;           /* the XR10 forms: drawn as BGRA (8-bit display chain) */
		}
	}
	return fmt;
}

static BOOL
m_rb_storage(id self, SEL cmd, NSUInteger target, id drawable)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, NSUInteger, id))orig_rb_storage)(self, cmd, target, drawable);
	}
	if (target != NGL_GL_RENDERBUFFER) {
		return NO;
	}
	if (drawable == nil) {
		return ngl_view_bind(g, NULL, 0, 0) ? YES : NO;
	}
	SEL nws = sel_registerName("nativeWindow");
	if (!class_respondsToSelector(object_getClass(drawable), nws)) {
		ngl_log("negronigl: renderbufferStorage:fromDrawable: %s has no -nativeWindow (not a CAEAGLLayer)",
		    object_getClassName(drawable));
		return NO;
	}
	void *nw = ((void *(*)(id, SEL))objc_msgSend)(drawable, nws);
	if (nw == NULL) {
		ngl_log("negronigl: renderbufferStorage:fromDrawable: invalid drawable (no native window)");
		return NO;
	}
	id props = nil;
	SEL dps = sel_registerName("drawableProperties");
	if (class_respondsToSelector(object_getClass(drawable), dps)) {
		props = ((id (*)(id, SEL))objc_msgSend)(drawable, dps);
	}
	unsigned retained = 0, fmt = color_format(props, &retained);
	return ngl_view_bind(g, nw, fmt, retained) ? YES : NO;
}

/* -presentRenderbuffer: / :atTime: / :afterMinimumDuration: (Apple: gliPresentViewES(ctx, 0|0|1, t)) */
static BOOL
m_present(id self, SEL cmd, NSUInteger target)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, NSUInteger))orig_present)(self, cmd, target);
	}
	return ngl_view_present(g, 0, 0.0) ? YES : NO;
}

static BOOL
m_present_at(id self, SEL cmd, NSUInteger target, double t)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, NSUInteger, double))orig_present_at)(self, cmd, target, t);
	}
	return ngl_view_present(g, 0, t) ? YES : NO;
}

static BOOL
m_present_after(id self, SEL cmd, NSUInteger target, double t)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, NSUInteger, double))orig_present_after)(self, cmd, target, t);
	}
	return ngl_view_present(g, 1, t) ? YES : NO;
}

static __thread id current_eagl;

static BOOL
m_set_current(id cls, SEL cmd, id eagl)
{
	struct ngl_gli *g = lookup(eagl);
	if (g != NULL) {
		ngl_bind(g);
		current_eagl = eagl;
		return YES;
	}
	if (ngl_cur != NULL) {
		ngl_bind(NULL);
	}
	current_eagl = nil;
	return ((BOOL (*)(id, SEL, id))orig_set_current)(cls, cmd, eagl);
}

static id
m_current(id cls, SEL cmd)
{
	return current_eagl ? current_eagl : ((id (*)(id, SEL))orig_current)(cls, cmd);
}

/*
 * -[IOSurface initWithClientBuffer:] (IOSurfaceWrapClientImage / IOSurfaceWrapClientMemory).
 * CA::Render::Image::retain_iosurface wraps the pixels of a page-aligned CPU image with
 * IOSurfaceWrapClientImage (kernel selector 6; 7 = WrapClientMemory). Our kernel's
 * IOSurfaceRootUserClient (UniXNU-negroni 0046) answers unknown selectors with success and a zeroed
 * lock result, so IOSurface.framework builds a client with id 0, size 0 and no shared state page
 * (client + 0x70 = lock result + 8 = NULL). CA::WindowServer::IOSurface::wrap_buffer then calls
 * iosurface_get_edr_factor -> IOSurfaceGetBulkAttachments, which copies from NULL + 0x30:
 * backboardd SIGSEGV far 0x30 (docs/notes.md 15a, 2026-10-25). Refuse such a client: the wrap
 * returns NULL (IOSurfaceWrapClientImage then releases the client), retain_iosurface returns NULL
 * and GLESContext::retain_image keeps the image without an IOSurface.
 * Layout [V 20H392]: _ioSurfaceClientCreateWithLockResult copies the lock result to client + 0x68;
 * IOSurfaceClientGetBulkAttachments reads [client + 0x70] + 0x30; the surface id is at client + 0x80.
 */
static IMP orig_wrap_init;

static id
m_surface_wrap_init(id self, SEL cmd, void *client)
{
	if (client != NULL && *(void *const *)((const char *)client + 0x70) == NULL) {
		static unsigned refused;
		unsigned n = __atomic_add_fetch(&refused, 1, __ATOMIC_RELAXED);
		if (n <= 4 || (n & (n - 1)) == 0) {
			ngl_log("negronigl: IOSurface wrap of client memory refused (id %u, no state page: kernel "
			    "IOSurfaceRoot selector 6/7 unsupported), %u so far",
			    *(const uint32_t *)((const char *)client + 0x80), n);
		}
		/* -[IOSurface dealloc] releases a NULL client (no-op), then NSObject frees self */
		((void (*)(id, SEL))objc_msgSend)(self, sel_registerName("release"));
		return nil;
	}
	return ((id (*)(id, SEL, void *))orig_wrap_init)(self, cmd, client);
}

static void
surface_wrap_install(void)
{
	Class cls = objc_getClass("IOSurface");
	Method m = cls ? class_getInstanceMethod(cls, sel_registerName("initWithClientBuffer:")) : NULL;
	if (m == NULL) {
		ngl_log("negronigl: IOSurface has no initWithClientBuffer:, wrap guard not installed");
		return;
	}
	orig_wrap_init = method_setImplementation(m, (IMP)m_surface_wrap_init);
}

static IMP
swap(Class cls, const char *sel, void *imp)
{
	Method m = class_getInstanceMethod(cls, sel_registerName(sel));
	if (m == NULL) {
		ngl_log("negronigl: EAGLContext has no %s", sel);
		return NULL;
	}
	return method_setImplementation(m, (IMP)imp);
}

/* at load (negronigl.c): CA picks its GLES renderer itself once -initWithAPI:3 works */
void
ngl_eagl_install(void)
{
	static int installed;
	if (__atomic_exchange_n(&installed, 1, __ATOMIC_ACQ_REL)) {
		return;                 /* once per process (ngl_load, ngl_layer_selftest) */
	}
	ngl_check_errors = ngl_env_on("NEGRONIGL_GLERR", false);
	Class cls = objc_getClass("EAGLContext");
	if (cls == Nil) {
		dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY | RTLD_GLOBAL);
		cls = objc_getClass("EAGLContext");
	}
	if (cls == Nil) {
		ngl_log("negronigl: no EAGLContext class, shim not installed");
		return;
	}
	Class meta = object_getClass((id)cls);
	orig_init = swap(cls, "initWithAPI:properties:", m_init);
	orig_dealloc = swap(cls, "dealloc", m_dealloc);
	orig_api = swap(cls, "API", m_api);
	orig_set_param = swap(cls, "setParameter:to:", m_set_param);
	orig_macro = swap(cls, "getMacroContextPrivate", m_macro);
	orig_tex_iosurface9 = swap(cls, "texImageIOSurface:target:internalFormat:width:height:format:type:plane:invert:",
	    m_tex_iosurface9);
	orig_tex_iosurface = swap(cls, "texImageIOSurface:target:internalFormat:width:height:format:type:plane:",
	    m_tex_iosurface);
	orig_attach = swap(cls, "attachImage:toCoreSurface:invertedRender:", m_attach);
	orig_rb_storage = swap(cls, "renderbufferStorage:fromDrawable:", m_rb_storage);
	orig_present = swap(cls, "presentRenderbuffer:", m_present);
	orig_present_at = swap(cls, "presentRenderbuffer:atTime:", m_present_at);
	orig_present_after = swap(cls, "presentRenderbuffer:afterMinimumDuration:", m_present_after);
	orig_set_current = swap(meta, "setCurrentContext:", m_set_current);
	orig_current = swap(meta, "currentContext", m_current);
	surface_wrap_install();
	ngl_log("negronigl: EAGL shim installed%s", ngl_check_errors ? " (GL error checks on)" : "");
}

#ifndef NGL_PLUGIN
/*
 * ngl_test --layer: a CAEAGLLayer drawable through the real EAGLContext methods of this process
 * (the shim is installed here first): -initWithAPI:3, +setCurrentContext:, a renderbuffer from
 * -renderbufferStorage:fromDrawable:, green clear read back by GL and from the drawable IOSurface
 * on the CPU, -presentRenderbuffer:, then a blue frame into the next drawable and a second present.
 * The layer gets its size from CoreAnimation; a shell process has no window server context, so the
 * layer is put into +[CAContext localContext] and committed [I: untested on the phone].
 * Returns 1 PASS, 0 FAIL, -1 no drawable surface (the layer has no size in this process).
 */
struct ngl_cgrect { double x, y, w, h; };
void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *pool);

static id
msg0(id o, const char *sel)
{
	return o ? ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName(sel)) : nil;
}

static bool
responds(id o, const char *sel)
{
	return o != nil && class_respondsToSelector(object_getClass(o), sel_registerName(sel));
}

/* BGRA pixel (x, y) of the surface, after the GPU is done (caller did glFinish) */
static uint32_t
surface_pixel(IOSurfaceRef s, size_t x, size_t y)
{
	uint32_t v = 0;
	if (s != NULL && IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) == 0) {
		const uint8_t *b = IOSurfaceGetBaseAddress(s);
		if (b != NULL && x < IOSurfaceGetWidth(s) && y < IOSurfaceGetHeight(s)) {
			memcpy(&v, b + y * IOSurfaceGetBytesPerRow(s) + x * 4, 4);
		}
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	}
	return v;
}

/* clear to (r, g, b), read the middle back with GL (RGBA) and from the drawable (BGRA in memory) */
static bool
layer_frame(struct ngl_gli *g, int w, int h, float r, float gr, float b, uint32_t want_bgra, const char *what)
{
	glViewport(0, 0, w, h);
	glClearColor(r, gr, b, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	uint8_t px[4] = {0};
	glReadPixels(w / 2, h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	glFinish();
	uint32_t mem = surface_pixel(g->view_surface, (size_t)w / 2, (size_t)h / 2);
	bool gl_ok = px[0] == (uint8_t)(r * 255) && px[1] == (uint8_t)(gr * 255) && px[2] == (uint8_t)(b * 255);
	bool mem_ok = mem == want_bgra;
	ngl_log("negronigl: layer selftest %s: GL %02x%02x%02x%02x, IOSurface %u BGRA word %08x (want %08x): %s", what,
	    px[0], px[1], px[2], px[3], g->view_surface ? IOSurfaceGetID(g->view_surface) : 0, mem, want_bgra,
	    gl_ok && mem_ok ? "ok" : "WRONG");
	return gl_ok && mem_ok;
}

int
ngl_layer_selftest(int w, int h)
{
	if (w <= 0 || h <= 0 || !ngl_init()) {
		return 0;
	}
	dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_GLOBAL);
	dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY | RTLD_GLOBAL);
	ngl_eagl_install();
	Class lc = objc_getClass("CAEAGLLayer"), ec = objc_getClass("EAGLContext"), tc = objc_getClass("CATransaction");
	if (lc == Nil || ec == Nil || orig_init == NULL) {
		ngl_log("negronigl: layer selftest: no CAEAGLLayer/EAGLContext or the shim is not installed");
		return 0;
	}
	void *pool = objc_autoreleasePoolPush();
	int result = 0;
	id layer = msg0(msg0((id)lc, "alloc"), "init");
	((void (*)(id, SEL, struct ngl_cgrect))objc_msgSend)(layer, sel_registerName("setBounds:"),
	    (struct ngl_cgrect){0, 0, w, h});
	((void (*)(id, SEL, double))objc_msgSend)(layer, sel_registerName("setContentsScale:"), 1.0);
	((void (*)(id, SEL, BOOL))objc_msgSend)(layer, sel_registerName("setOpaque:"), YES);
	const void *keys[] = {CFSTR("EAGLDrawablePropertyRetained"), CFSTR("EAGLDrawablePropertyColorFormat")};
	const void *vals[] = {kCFBooleanFalse, CFSTR("EAGLColorFormat8888")};
	CFDictionaryRef props = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setDrawableProperties:"), (id)props);
	CFRelease(props);
	id cactx = nil;
	Class cc = objc_getClass("CAContext");
	if (cc != Nil && responds((id)cc, "localContext")) {
		cactx = msg0((id)cc, "localContext");
		if (responds(cactx, "setLayer:")) {
			((void (*)(id, SEL, id))objc_msgSend)(cactx, sel_registerName("setLayer:"), layer);
		}
	}
	msg0((id)tc, "flush");
	id ctx = ((id (*)(id, SEL, NSUInteger, id))objc_msgSend)(msg0((id)ec, "alloc"),
	    sel_registerName("initWithAPI:properties:"), 3, nil);
	struct ngl_gli *g = lookup(ctx);
	if (g == NULL) {
		ngl_log("negronigl: layer selftest: EAGLContext API 3 is not a Mesa context");
		msg0(ctx, "release");
		goto out;
	}
	((BOOL (*)(id, SEL, id))objc_msgSend)((id)ec, sel_registerName("setCurrentContext:"), ctx);
	GLuint fb = 0, rb = 0;
	glGenFramebuffers(1, &fb);
	glBindFramebuffer(GL_FRAMEBUFFER, fb);
	glGenRenderbuffers(1, &rb);
	glBindRenderbuffer(GL_RENDERBUFFER, rb);
	SEL st = sel_registerName("renderbufferStorage:fromDrawable:");
	BOOL stored = ((BOOL (*)(id, SEL, NSUInteger, id))objc_msgSend)(ctx, st, GL_RENDERBUFFER, layer);
	if (!stored) {
		ngl_log("negronigl: layer selftest: renderbufferStorage:fromDrawable: NO (%s)",
		    g->view != NULL ? "drawable attached, no IOSurface" : "no drawable: the layer has no size here");
		result = -1;
		goto done;
	}
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	GLint rw = 0, rh = 0;
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &rw);
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &rh);
	GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	uint32_t first = g->view_surface ? IOSurfaceGetID(g->view_surface) : 0;
	ngl_log("negronigl: layer selftest: renderbuffer %u = drawable IOSurface %u, %dx%d, framebuffer %#x", rb, first,
	    rw, rh, fbs);
	bool ok = fbs == GL_FRAMEBUFFER_COMPLETE && rw == w && rh == h;
	ok = layer_frame(g, rw, rh, 0.0f, 1.0f, 0.0f, 0xff00ff00u, "frame 1 green") && ok;
	SEL pr = sel_registerName("presentRenderbuffer:");
	BOOL p1 = ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(ctx, pr, GL_RENDERBUFFER);
	uint32_t second = g->view_surface ? IOSurfaceGetID(g->view_surface) : 0;
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	ok = layer_frame(g, rw, rh, 0.0f, 0.0f, 1.0f, 0xff0000ffu, "frame 2 blue") && ok;
	BOOL p2 = ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(ctx, pr, GL_RENDERBUFFER);
	ok = ok && p1 && p2;
	ngl_log("negronigl: layer selftest %dx%d: present %d %d, drawables IOSurface %u then %u%s: %s", w, h, p1, p2,
	    first, second, first == second ? " (one buffer)" : "", ok ? "PASS" : "FAIL");
	result = ok ? 1 : 0;
done:
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glDeleteFramebuffers(1, &fb);
	glDeleteRenderbuffers(1, &rb);
	((BOOL (*)(id, SEL, id))objc_msgSend)((id)ec, sel_registerName("setCurrentContext:"), nil);
	msg0(ctx, "release");
out:
	if (cactx != nil && responds(cactx, "setLayer:")) {
		((void (*)(id, SEL, id))objc_msgSend)(cactx, sel_registerName("setLayer:"), nil);
	}
	msg0(layer, "release");
	objc_autoreleasePoolPop(pool);
	return result;
}
#endif
