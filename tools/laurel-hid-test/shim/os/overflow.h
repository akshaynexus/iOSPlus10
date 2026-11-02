#include "hostkern.h"
#define os_add_overflow(a, b, r) __builtin_add_overflow((a), (b), (r))
#define os_add3_overflow(a, b, c, r) __extension__({ __typeof(*(r)) _t; __builtin_add_overflow((a), (b), &_t) | __builtin_add_overflow(_t, (c), (r)); })
#define os_mul_overflow(a, b, r) __builtin_mul_overflow((a), (b), (r))
