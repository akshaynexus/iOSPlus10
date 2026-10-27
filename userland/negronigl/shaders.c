/*
 * negronigl: CA's shader sources made acceptable to Mesa's GLSL ES compiler.
 *
 *  - rectangle textures: Apple's ES has GL_TEXTURE_RECTANGLE (sampler2DRect, texture2DRect with
 *    texel coordinates); here they are 2D textures and the coordinates are scaled by a uniform
 *    ngl_rect_scale = 1/size, set before each draw (eagl.c draw_prep).
 *  - an undeclared coord_arg (CA's inverted-mask shader; Apple's compiler accepts it) is declared.
 *  - GL_EXT_shader_framebuffer_fetch: Mesa's freedreno on a6xx/a7xx exposes it itself (native);
 *    if it does not (or NEGRONIGL_FBFETCH=emulate), gl_LastFragData[0] becomes a texture read of
 *    the framebuffer's own color texture, bound to unit NGL_FBFETCH_UNIT before the draw.
 *  - full precision (2026-10-27): "lowp" and "mediump" are defined to "highp" in every shader. On Adreno
 *    mediump is a 16-bit float: CA's gradient lookup (32x1024 table, the "c_st" fragment shader) then gives
 *    about 60 shades and the Weather widget sky draws in bands. Idea and text from HackiOS
 *    (out/src/hackios-next 8851317 userland/src/eagl.c:3621-3634, MIT, Copyright (c) 2025-2026 the HakiOS
 *    authors). NEGRONIGL_PRECISION=0 keeps the shaders' own precision. Self-check: a shader that does not
 *    compile with the two defines is compiled again without them (eagl.c ngl_h_CompileShader).
 * Ideas from ios-sailfish tools/sweetgl/eagl.c (rect_prelude, fbfetch_rewrite); own code.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "negronigl.h"

static int fbfetch_mode = -1;           /* 1 native, 0 emulated */

bool
ngl_fbfetch_native(void)
{
	if (fbfetch_mode < 0) {
		const char *e = getenv("NEGRONIGL_FBFETCH");
		const char *ext = (const char *)glGetString(GL_EXTENSIONS);
		bool has = ext != NULL && strstr(ext, "GL_EXT_shader_framebuffer_fetch") != NULL;
		fbfetch_mode = e && strcmp(e, "emulate") == 0 ? 0 : has ? 1 : 0;
		ngl_log("negronigl: framebuffer fetch %s (Mesa %s it)", fbfetch_mode ? "native" : "emulated",
		    has ? "has" : "lacks");
	}
	return fbfetch_mode == 1;
}

const char *
ngl_extensions(const char *mesa)
{
	static char *ext;
	if (mesa == NULL || ngl_fbfetch_native()) {
		return mesa;
	}
	if (ext == NULL && asprintf(&ext, "%s GL_EXT_shader_framebuffer_fetch", mesa) < 0) {
		ext = NULL;
	}
	return ext ? ext : mesa;
}

/* offset just after the leading preprocessor lines (#version, #extension, blank) */
static size_t
after_directives(const char *src)
{
	size_t at = 0;
	while (src[at] == '#' || src[at] == ' ' || src[at] == '\n' || src[at] == '\t') {
		const char *nl = strchr(src + at, '\n');
		if (nl == NULL) {
			break;
		}
		at = (size_t)(nl - src + 1);
	}
	return at;
}

/* the offset after the #version line (only white space may come before it), else 0 */
static size_t
after_version(const char *src)
{
	size_t at = strspn(src, " \t\r\n");
	if (strncmp(src + at, "#version", 8) != 0) {
		return 0;
	}
	const char *nl = strchr(src + at, '\n');
	return nl ? (size_t)(nl - src + 1) : strlen(src);
}

/* src with text inserted at offset at (src is freed) */
static char *
insert_at(char *src, size_t at, const char *text)
{
	size_t n = strlen(src), t = strlen(text);
	char *out = malloc(n + t + 1);
	if (out == NULL) {
		return src;
	}
	memcpy(out, src, at);
	memcpy(out + at, text, t);
	memcpy(out + at + t, src + at, n - at + 1);
	free(src);
	return out;
}

/* src with every "from" replaced by "to" (src is freed) */
static char *
replace_all(char *src, const char *from, const char *to)
{
	size_t fl = strlen(from), tl = strlen(to), count = 0;
	for (const char *p = strstr(src, from); p; p = strstr(p + fl, from)) {
		count++;
	}
	if (count == 0) {
		return src;
	}
	char *out = malloc(strlen(src) + count * (tl > fl ? tl - fl : 0) + 1), *o = out;
	if (out == NULL) {
		return src;
	}
	for (const char *p = src;;) {
		const char *q = strstr(p, from);
		if (q == NULL) {
			strcpy(o, p);
			break;
		}
		memcpy(o, p, (size_t)(q - p));
		o += q - p;
		memcpy(o, to, tl);
		o += tl;
		p = q + fl;
	}
	free(src);
	return out;
}

const char ngl_precision_prelude[] =
    "#define lowp highp /* negronigl precision */\n"
    "#define mediump highp /* negronigl precision */\n";

bool
ngl_full_precision(void)
{
	static int on = -1;
	if (on < 0) {
		on = ngl_env_on("NEGRONIGL_PRECISION", true) ? 1 : 0;
		ngl_log("negronigl: shader precision %s", on ? "highp everywhere (NEGRONIGL_PRECISION=0: as written)" :
		    "as written (NEGRONIGL_PRECISION=0)");
	}
	return on == 1;
}

static const char rect_prelude[] =
    "#define sampler2DRect sampler2D\n"
    "#define texture2DRect(s, c) texture2D(s, (c) * ngl_rect_scale)\n"
    "uniform highp vec2 ngl_rect_scale;\n";

static const char fbf_decl[] =
    "uniform lowp sampler2D ngl_fb;\n"
    "uniform highp vec2 ngl_fb_scale;\n";

char *
ngl_shader_rewrite(struct ngl_state *st, GLuint shader, char *src)
{
	uint8_t kind = 0;
	if (strstr(src, "coord_arg") && !strstr(src, "vec4 coord_arg")) {
		src = insert_at(src, after_directives(src), "uniform highp vec4 coord_arg;\n");
	}
	const char *rect = strstr(src, "sampler2DRect");
	if (rect != NULL) {
		const char *name = rect + strlen("sampler2DRect");
		while (*name == ' ' || *name == '\t') {
			name++;
		}
		size_t l = strspn(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_");
		if (st && shader < NGL_NAMES && l > 0 && l < sizeof(st->rect_sampler[0])) {
			snprintf(st->rect_sampler[shader], sizeof(st->rect_sampler[0]), "%.*s", (int)l, name);
			kind |= 1;
		}
		src = insert_at(src, after_directives(src), rect_prelude);
	}
	if (strstr(src, "gl_LastFragData") && !ngl_fbfetch_native()) {
		char *ext = strstr(src, "#extension GL_EXT_shader_framebuffer_fetch");
		for (char *e = ext; e && *e && *e != '\n'; e++) {
			*e = ' ';
		}
		src = insert_at(src, after_directives(src), fbf_decl);
		src = replace_all(src, "gl_LastFragData[0]", "texture2D(ngl_fb, gl_FragCoord.xy * ngl_fb_scale)");
		kind |= 2;
	}
	if (ngl_full_precision() && !strstr(src, ngl_precision_prelude)) {
		/* right after #version (else at the top), not at after_directives(): that also skips indented code
		 * lines, so the defines could land after declarations and leave a uniform mediump in one stage and
		 * highp in the other (a link error) */
		src = insert_at(src, after_version(src), ngl_precision_prelude);
	}
	if (st && shader < NGL_NAMES) {
		st->shader_kind[shader] = kind;
	}
	return src;
}

void
ngl_shader_deleted(struct ngl_state *st, GLuint shader)
{
	if (st && shader < NGL_NAMES) {
		st->shader_kind[shader] = 0;
	}
}

void
ngl_program_linked(struct ngl_state *st, GLuint program)
{
	if (st == NULL || program >= NGL_NAMES) {
		return;
	}
	GLuint sh[8];
	GLsizei n = 0;
	glGetAttachedShaders(program, 8, &n, sh);
	st->rect_prog[program] = (struct ngl_rect_prog){0};
	st->fbf_sampler[program] = st->fbf_scale[program] = 0;
	st->prog_units[program] = 0;
	for (GLsizei i = 0; i < n; i++) {
		uint8_t k = sh[i] < NGL_NAMES ? st->shader_kind[sh[i]] : 0;
		if ((k & 1) && st->rect_prog[program].program == 0) {
			st->rect_prog[program] = (struct ngl_rect_prog){
			    .program = program,
			    .scale = glGetUniformLocation(program, "ngl_rect_scale"),
			    .sampler = glGetUniformLocation(program, st->rect_sampler[sh[i]]),
			};
		}
		if (k & 2) {
			st->fbf_sampler[program] = glGetUniformLocation(program, "ngl_fb") + 1;
			st->fbf_scale[program] = glGetUniformLocation(program, "ngl_fb_scale") + 1;
		}
	}
}
