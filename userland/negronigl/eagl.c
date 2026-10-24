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
    orig_attach, orig_set_current, orig_current, orig_rb_storage, orig_present;

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
	ngl_make_current(g ? g->ctx : NULL);
	ngl_cur = g;
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
 * flush = finish: CA hands rendered IOSurfaces to the display (IOMobileFramebuffer swap) without
 * waiting for the GPU (ios-sailfish found the same). Per-surface fences would let the GPU run ahead.
 */
void
ngl_h_Flush(void *rctx)
{
	NGL_CUR(rctx);
	glFinish();
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

/* CAEAGLLayer storage: CA's render server does not use it (it draws into IOSurfaces) */
static BOOL
m_rb_storage(id self, SEL cmd, NSUInteger target, id drawable)
{
	if (lookup(self) == NULL) {
		return ((BOOL (*)(id, SEL, NSUInteger, id))orig_rb_storage)(self, cmd, target, drawable);
	}
	ngl_log("negronigl: renderbufferStorage:fromDrawable: on a Mesa context: not supported");
	return NO;
}

static BOOL
m_present(id self, SEL cmd, NSUInteger target)
{
	struct ngl_gli *g = lookup(self);
	if (g == NULL) {
		return ((BOOL (*)(id, SEL, NSUInteger))orig_present)(self, cmd, target);
	}
	NGL_CUR(g);
	glFinish();
	return YES;
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
	orig_set_current = swap(meta, "setCurrentContext:", m_set_current);
	orig_current = swap(meta, "currentContext", m_current);
	ngl_log("negronigl: EAGL shim installed%s", ngl_check_errors ? " (GL error checks on)" : "");
}
