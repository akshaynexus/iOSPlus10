/* Host mock, see cam5_mock.c */
#ifndef CAM5_MOCK_INT_H
#define CAM5_MOCK_INT_H
#include <stdint.h>
enum { T_STR = 1, T_NUM, T_DICT, T_ARR, T_BOOL, T_SET, T_POOL, T_PB, T_MISC, T_DERIVED };
struct mock_obj {
	uintptr_t magic;
	int type, refs;
	char *text;
	double num;
	const void **k, **v;
	long n, cap;
	/* T_PB, T_POOL */
	uint32_t w, h, pf;
	uint8_t *mem;
	struct mock_vtable_ *vt;
	void *storage;
};
struct mock_obj *mock_make(int type);
#endif
