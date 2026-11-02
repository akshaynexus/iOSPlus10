/* collect_ios.c: the phone's data as text; shared paths of the helper and the collector (docs/laurel_sprout/xnutils.md). */
#ifndef XNUTILS_COLLECT_H
#define XNUTILS_COLLECT_H

#ifndef XT_ROOT
#define XT_ROOT          ""     /* scripts/laurel/xnutils-test.sh builds the helper's file code for a folder on the host */
#endif
#ifndef XT_MOBILE_UID
#define XT_MOBILE_UID    501
#endif
#define XT_DB            XT_ROOT "/private/var/db/negronimetal"
#define XT_METAL_CLIENTS XT_DB "/clients"
#define XT_METAL_OFF     XT_DB "/off"
#define XT_METAL_STRIKES XT_DB "/strikes"
#define XT_METAL_CACHE   XT_DB "/cache"
#define XT_METAL_GATE    XT_DB "/gate"
#define XT_METAL_BUNDLE  XT_ROOT "/System/Library/Extensions/NegroniMetal.bundle"
#define XT_METAL_LOCAL   XT_METAL_BUNDLE "/clients.local"
/* userland/laurel/metal/metal_gate.c: the gate changes a list only when its first line is this mark */
#define XT_GATE_MARK     "# laurel-metal-gate"
#define XT_METAL_PROBES  "metalprobe m2vtest carenderprobe layerprobe"
#ifdef XT_IOS26
/* [V boot 11, 2026-11-03] "* -backboardd" here took the compositor off the GPU: 23F84 has no GL path. Same list as scripts/laurel/root-add-metal-ios26.sh */
#define XT_METAL_WIDE    "* -chronod -cameracaptured -PosterBoard"
#else
#define XT_METAL_WIDE    "* -backboardd"
#endif
/* userland/laurel/gpu/bbd_wrap.c reads this file at each start of backboardd */
#define XT_GL_DIR        XT_ROOT "/private/var/db/laurelgl"
#define XT_GL_OFF        XT_GL_DIR "/off"

/* key=value text + kern.laurel_stats, in a buffer of the collector; valid until the next call. NULL: no memory. */
char *collect(void);

/* the parts of collect(): collect_files.c, collect_procs.c, collect_dev.c. kv: one key=value line (collect_ios.c). */
void kv(const char *key, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void xt_collect_files(void);
void xt_collect_procs(void);
void xt_collect_memory(void);
void xt_collect_battery(void);
void xt_collect_network(void);
#endif
