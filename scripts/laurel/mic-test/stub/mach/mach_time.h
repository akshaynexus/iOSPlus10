/* Host test stub. */
#ifndef MIC_TEST_MACH_TIME_H
#define MIC_TEST_MACH_TIME_H
#include <stdint.h>
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
static inline uint64_t mach_absolute_time(void) { return 0; }
static inline int mach_timebase_info(mach_timebase_info_data_t *t) { t->numer = t->denom = 1; return 0; }
#endif
