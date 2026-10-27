/*
 * negroni_gpu_policy: one decision per process between Metal (NegroniMetal), GL (negronigl / NegroniGL.bundle)
 * and the CPU. Design and test steps: docs/gpu-hybrid-plan.md.
 *
 * Rules
 *   - A policy line gives the order to try for a process: "PATTERN API..." (API = metal, gl, cpu). The first
 *     matching line of /var/db/negronigpu/policy (owner), BUNDLE/gpu-policy.local, BUNDLE/gpu-policy (staged)
 *     wins. PATTERN is an fnmatch glob on the process name, or "ext:GLOB" on the NSExtensionPointIdentifier.
 *     No match: "metal gl cpu".
 *   - Each API has a health: OK, DISABLED (an owner switch: off file, not listed, boot-arg, memory rule) or
 *     FAILED (a self-check failed in this boot: dead-man strikes at the limit, GPU lost, a failure record).
 *   - Fallback: only a FAILED API is skipped for the next one. A DISABLED one keeps today's meaning (the
 *     process gets no device from it and nothing else changes). So an owner switch never moves a process to
 *     another API by surprise.
 *   - Never both broken: an API that FAILED in this boot is never chosen again in this boot for that process;
 *     when Metal and GL both failed, the answer is the CPU.
 *   - Kill switch for the whole component: /var/db/negronigpu/off, BUNDLE/gpu-policy.off or NEGRONIGPU=0:
 *     every call answers "no decision" (NGP_NONE) and the old gates decide alone.
 *
 * Metal's state is read, never written: the same files NegroniMetal.mm uses (clients, off, strikes, gpu-lost,
 * env). GL's dead-man (strikes) is owned here.
 *
 * No Objective-C; C99 + CoreFoundation (extension point) on Apple systems. Thread-safe for the calls a gate
 * makes once per process.
 */
#ifndef NEGRONI_GPU_POLICY_H
#define NEGRONI_GPU_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

enum ngp_api { NGP_NONE = -1, NGP_METAL = 0, NGP_GL = 1, NGP_CPU = 2 };
enum ngp_health { NGP_OK = 0, NGP_DISABLED = 1, NGP_FAILED = 2 };

#define NGP_DIR "/var/db/negronigpu"
#define NGP_METAL_DIR "/var/db/negronimetal"
#define NGP_METAL_BUNDLE "/System/Library/Extensions/NegroniMetal.bundle"
#define NGP_GL_DIR "/var/db/negronigl"
#define NGP_GL_BUNDLE "/System/Library/Extensions/NegroniGL.bundle"

const char *ngp_api_name(enum ngp_api api);

/* The log sink for the few lines the dead-man writes (default: stderr). */
void ngp_set_logger(void (*fn)(const char *line));

/* true = the component is off (kill switches above); every other call then answers NGP_NONE / OK */
bool ngp_off(void);

/* NSExtensionPointIdentifier of the main bundle, "" for no extension (cached) */
const char *ngp_extension_point(void);

/* The order for prog (ext may be NULL = ngp_extension_point()). Returns the count (1..3); rule gets the
 * matching line ("file:line PATTERN ORDER" or "default"). */
int ngp_order(const char *prog, const char *ext, enum ngp_api order[3], char *rule, size_t rule_size);

/* Health of each API for prog, with the reason. gl_bundle may be NULL (NGP_GL_BUNDLE). */
enum ngp_health ngp_metal_health(const char *prog, char *why, size_t size);
enum ngp_health ngp_gl_health(const char *prog, const char *gl_bundle, char *why, size_t size);

/* The API prog should use now: the first in its order that is OK, skipping FAILED ones; a DISABLED API
 * ends the walk with NGP_NONE when it is first (the old gates decide), else with the CPU. why gets one line. */
enum ngp_api ngp_choose(const char *prog, const char *ext, const char *gl_bundle, char *why, size_t size);

/* GL as the fallback renderer: NGP_GL when Metal comes before GL in prog's order, Metal FAILED and GL is OK;
 * NGP_CPU when Metal and GL both FAILED; else NGP_NONE (no fallback; the normal GL gate decides). */
enum ngp_api ngp_gl_fallback(const char *prog, const char *ext, const char *gl_bundle, char *why, size_t size);

/* A failure record for this boot: api is FAILED for prog until the next boot (or until the record file
 * NGP_DIR/state/<prog> or <cache>/negronigpu-state/<prog> is removed). */
bool ngp_record_failure(const char *prog, enum ngp_api api, const char *reason);

/*
 * GL dead-man (the NegroniMetal design, for GL): ngp_gl_arm writes "COUNT+1 BOOT" into
 * NGP_GL_DIR/strikes/<prog> (sandbox: <cache>/negronigl-strikes/<prog>) before the GL path is installed;
 * ngp_gl_frame_ok (first frames), a 15 s timer or exit() removes it. A crash or hang before that leaves the
 * count; at NEGRONIGL_STRIKE_LIMIT (default 2) in a row in one boot, GL is FAILED for prog.
 * ngp_gl_arm returns false (why set) when the limit is reached or no strike file can be kept.
 */
bool ngp_gl_arm(const char *prog, char *why, size_t size);
void ngp_gl_frame_ok(void);          /* cheap; clears the armed strike after NGP_GL_OK_FRAMES calls */
void ngp_gl_disarm(const char *why); /* clean refusal after arm: the strike is removed */
#define NGP_GL_OK_FRAMES 3

/* tests (host only): file system root prefix, boot id, process start time, extension point */
void ngp_test_set_root(const char *prefix);
void ngp_test_set_boot(const char *boot);
void ngp_test_set_proc_start(time_t t);
void ngp_test_set_ext(const char *ext);
void ngp_test_reset(void);

#ifdef __cplusplus
}
#endif
#endif
