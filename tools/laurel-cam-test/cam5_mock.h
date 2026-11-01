/* Host mock, see cam5_mock.c */
#ifndef CAM5_MOCK_H
#define CAM5_MOCK_H
#include <CoreVideo/CoreVideo.h>
extern long mock_live_objects, mock_live_buffers, mock_buffers_made;
extern volatile int mock_pool_refuse;
extern void *_NSConcreteMallocBlock[32], *_NSConcreteGlobalBlock[32];
void mock_cv_init(void);
void mock_dump_live(void);
CFDictionaryRef mock_pool(uint32_t w, uint32_t h, uint32_t pf);
CVPixelBufferRef mock_pb_retain(CVPixelBufferRef b);
struct mock_obj *mock_derived_make(void *vt, size_t storage);
void *mock_derived_storage(struct mock_obj *o);
void *mock_derived_vt(struct mock_obj *o);
void mock_derived_finalize(struct mock_obj *o);
#endif
