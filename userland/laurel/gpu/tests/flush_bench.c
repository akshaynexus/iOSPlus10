/*
 * A frame as CoreAnimation draws it (counts from redwood-gl lines of boot 22:08: 80 draws, 7 clears, 3 offscreen pictures), timed on
 * the host with Mesa's freedreno on drm-shim (scripts/laurel/mesa-host-bench.sh). What it measures: the CPU time of the draws and of glFlush.
 * No GPU runs: this says nothing about GPU time.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1000000.0;
}

static const char vs[] = "#version 300 es\nin vec2 p; out vec2 v; uniform vec4 box;\n"
    "void main(){ v = p; gl_Position = vec4(box.xy + p * box.zw, 0.0, 1.0); }\n";
static const char fs[] = "#version 300 es\nprecision mediump float; in vec2 v; uniform sampler2D t; uniform float a; out vec4 c;\n"
    "void main(){ c = texture(t, v) * a; }\n";

static GLuint shader(GLenum kind, const char *text)
{
	GLuint s = glCreateShader(kind);
	GLint good = 0;

	glShaderSource(s, 1, &text, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &good);
	if (!good) {
		fprintf(stderr, "flush_bench: shader does not compile\n");
		exit(1);
	}
	return s;
}

static GLuint picture(int w, int h)
{
	GLuint t;

	glGenTextures(1, &t);
	glBindTexture(GL_TEXTURE_2D, t);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	return t;
}

static void quads(GLint box, GLint alpha, GLuint *tex, int ntex, int draws)
{
	static const GLushort index[6] = { 0, 1, 2, 2, 1, 3 };

	for (int i = 0; i < draws; i++) {
		glBindTexture(GL_TEXTURE_2D, tex[i % ntex]);
		glScissor(i * 7 % 500, i * 13 % 1200, 200, 300);
		glUniform4f(box, -1.0f + (float)(i % 5) * 0.3f, -1.0f + (float)(i % 9) * 0.2f, 0.3f, 0.2f);
		glUniform1f(alpha, 0.5f + (float)(i % 2) * 0.5f);
		glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, index);
	}
}

int main(int argc, char **argv)
{
	static const GLfloat corners[8] = { 0, 0, 1, 0, 0, 1, 1, 1 };
	static const EGLint context[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	static const EGLint config[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
	EGLDisplay d = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	EGLConfig c;
	EGLint n = 0;
	GLuint tex[16], off[3], fb[4], screen, p, vbo;
	enum { FRAMES = 600 };
	double draw_ms = 0, flush_ms = 0;

	if (d == EGL_NO_DISPLAY || !eglInitialize(d, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API) || !eglChooseConfig(d, config, &c, 1, &n) || n == 0) {
		fprintf(stderr, "flush_bench: no EGL\n");
		return 1;
	}
	if (!eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, eglCreateContext(d, c, EGL_NO_CONTEXT, context))) {
		fprintf(stderr, "flush_bench: no context\n");
		return 1;
	}
	p = glCreateProgram();
	glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
	glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(p, 0, "p");
	glLinkProgram(p);
	glUseProgram(p);
	GLint box = glGetUniformLocation(p, "box"), alpha = glGetUniformLocation(p, "a");

	glGenBuffers(1, &vbo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(corners), corners, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
	for (int i = 0; i < 16; i++) {
		tex[i] = picture(64 + i * 8, 64 + i * 8);
	}
	off[0] = picture(360, 780);
	off[1] = picture(180, 390);
	off[2] = picture(90, 195);
	screen = picture(720, 1560);
	glGenFramebuffers(4, fb);
	for (int i = 0; i < 4; i++) {
		glBindFramebuffer(GL_FRAMEBUFFER, fb[i]);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, i < 3 ? off[i] : screen, 0);
	}
	glEnable(GL_BLEND);
	glEnable(GL_SCISSOR_TEST);
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	for (int f = 0; f < FRAMES; f++) {
		double t0 = now_ms(), t1, t2;

		for (int i = 0; i < 3; i++) {
			glBindFramebuffer(GL_FRAMEBUFFER, fb[i]);
			glViewport(0, 0, 360 >> i, 780 >> i);
			glScissor(0, 0, 360 >> i, 780 >> i);
			glClear(GL_COLOR_BUFFER_BIT);
			quads(box, alpha, tex, 16, 12);
		}
		glBindFramebuffer(GL_FRAMEBUFFER, fb[3]);
		glViewport(0, 0, 720, 1560);
		glScissor(0, 0, 720, 1560);
		glClear(GL_COLOR_BUFFER_BIT);
		quads(box, alpha, tex, 16, 44);
		t1 = now_ms();
		glFlush();
		t2 = now_ms();
		if (f >= 100) {
			draw_ms += t1 - t0;
			flush_ms += t2 - t1;
		}
	}
	printf("flush_bench %-14s: %6.3f ms a frame in draws (flushes of the offscreen pictures in it), %6.3f ms in glFlush, %6.3f in all (%s)\n",
	    argc > 1 ? argv[1] : "?", draw_ms / (FRAMES - 100), flush_ms / (FRAMES - 100), (draw_ms + flush_ms) / (FRAMES - 100), glGetString(GL_RENDERER));
	return 0;
}
