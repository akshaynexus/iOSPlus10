/* Host mock */
#include <stdint.h>
#include <time.h>
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
static inline int mach_timebase_info(mach_timebase_info_data_t *t) { t->numer = t->denom = 1; return 0; }
static inline uint64_t mach_absolute_time(void) { struct timespec s; clock_gettime(CLOCK_MONOTONIC, &s); return (uint64_t)s.tv_sec * 1000000000ull + (uint64_t)s.tv_nsec; }
