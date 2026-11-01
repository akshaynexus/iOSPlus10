/*
 * Host mock of CoreFoundation, CoreMedia and CoreVideo for cam5_test.c: every object is counted, so a retain that is never released, or a
 * buffer never given back, shows. Stands in for Apple's code in shape only. Under AddressSanitizer (scripts/laurel/cam-leak-test.sh).
 */
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CoreVideo/CoreVideo.h>
#include "cam5_mock.h"

#include "cam5_mock_int.h"

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
long mock_live_objects, mock_live_buffers, mock_buffers_made;
void *_NSConcreteMallocBlock[32], *_NSConcreteGlobalBlock[32];
const int kCFTypeArrayCallBacks, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks, kCFTypeSetCallBacks;
static struct mock_obj b_true = { 1, T_BOOL, 1 << 30, NULL, 1 }, b_false = { 1, T_BOOL, 1 << 30, NULL, 0 };
CFBooleanRef kCFBooleanTrue = &b_true, kCFBooleanFalse = &b_false;

static bool
is_block(const void *o)
{
	return *(void *const *)o == (void *)_NSConcreteGlobalBlock || *(void *const *)o == (void *)_NSConcreteMallocBlock;
}

/* what is alive, for the line of a failed run */
#define TRACK 4096
static struct mock_obj *alive[TRACK];

void
mock_dump_live(void)
{
	for (int i = 0; i < TRACK; i++) {
		if (alive[i] != NULL) {
			printf("cam5: alive: type %d refs %d n %ld text %s\n", alive[i]->type, alive[i]->refs, alive[i]->n, alive[i]->text ? alive[i]->text : "-");
		}
	}
}

struct mock_obj *
mock_make(int type)
{
	struct mock_obj *o = calloc(1, sizeof(*o));

	o->magic = 1;
	o->type = type;
	o->refs = 1;
	pthread_mutex_lock(&lock);
	for (int i = 0; i < TRACK; i++) {
		if (alive[i] == NULL) {
			alive[i] = o;
			break;
		}
	}
	pthread_mutex_unlock(&lock);
	__atomic_add_fetch(&mock_live_objects, 1, __ATOMIC_SEQ_CST);
	return o;
}

CFStringRef
mock_cfstr(const char *s)
{
	static struct mock_obj *table[256];
	static int n;
	struct mock_obj *o;

	pthread_mutex_lock(&lock);
	for (int i = 0; i < n; i++) {
		if (strcmp(table[i]->text, s) == 0) {
			pthread_mutex_unlock(&lock);
			return table[i];
		}
	}
	o = calloc(1, sizeof(*o));
	o->magic = 1;
	o->type = T_STR;
	o->refs = 1 << 30;
	o->text = strdup(s);
	table[n++] = o;
	pthread_mutex_unlock(&lock);
	return o;
}

CFTypeRef
CFRetain(CFTypeRef p)
{
	if (!is_block(p)) {
		__atomic_add_fetch(&((struct mock_obj *)p)->refs, 1, __ATOMIC_SEQ_CST);
	}
	return p;
}

void
CFRelease(CFTypeRef p)
{
	struct mock_obj *o = (struct mock_obj *)p;

	if (is_block(p) || __atomic_sub_fetch(&o->refs, 1, __ATOMIC_SEQ_CST) != 0) {
		return;
	}
	if (o->type == T_DERIVED) {
		mock_derived_finalize(o);
		free(o->storage);
	}
	for (long i = 0; i < o->n; i++) {
		if (o->k != NULL && o->k[i] != NULL) {
			CFRelease(o->k[i]);
		}
		CFRelease(o->v[i]);
	}
	free(o->k);
	free(o->v);
	free(o->text);
	free(o->mem);
	if (o->type == T_PB) {
		__atomic_sub_fetch(&mock_live_buffers, 1, __ATOMIC_SEQ_CST);
	}
	__atomic_sub_fetch(&mock_live_objects, 1, __ATOMIC_SEQ_CST);
	pthread_mutex_lock(&lock);
	for (int i = 0; i < TRACK; i++) {
		if (alive[i] == o) {
			alive[i] = NULL;
			break;
		}
	}
	pthread_mutex_unlock(&lock);
	free(o);
}

CFTypeID CFGetTypeID(CFTypeRef o) { return is_block(o) ? 99 : (CFTypeID)((const struct mock_obj *)o)->type; }
CFTypeID CFStringGetTypeID(void) { return T_STR; }
CFTypeID CFNumberGetTypeID(void) { return T_NUM; }
CFTypeID CFDictionaryGetTypeID(void) { return T_DICT; }
CFTypeID CFArrayGetTypeID(void) { return T_ARR; }
CFTypeID CFBooleanGetTypeID(void) { return T_BOOL; }
CFTypeID CVPixelBufferPoolGetTypeID(void) { return T_POOL; }
Boolean CFBooleanGetValue(CFBooleanRef b) { return b->num != 0; }

CFStringRef
CFStringCreateWithCString(CFAllocatorRef a, const char *s, int e)
{
	struct mock_obj *o = mock_make(T_STR);

	o->text = strdup(s);
	return o;
}

/* only "%s %@", as say_once() */
CFStringRef
CFStringCreateWithFormat(CFAllocatorRef a, CFDictionaryRef d, CFStringRef f, ...)
{
	char b[512];
	va_list ap;
	const char *w;
	CFStringRef key;

	va_start(ap, f);
	w = va_arg(ap, const char *);
	key = va_arg(ap, CFStringRef);
	va_end(ap);
	snprintf(b, sizeof(b), "%s %s", w, key->text);
	return CFStringCreateWithCString(a, b, 0);
}

Boolean
CFStringGetCString(CFStringRef s, char *b, CFIndex n, int e)
{
	snprintf(b, (size_t)n, "%s", s->text);
	return true;
}

CFStringRef CFCopyDescription(CFTypeRef o) { return CFStringCreateWithCString(NULL, "(value)", 0); }

CFNumberRef
CFNumberCreate(CFAllocatorRef a, CFNumberType t, const void *v)
{
	struct mock_obj *o = mock_make(T_NUM);

	o->num = t == kCFNumberDoubleType ? *(const double *)v : t == kCFNumberFloatType ? *(const float *)v : t == kCFNumberSInt64Type ?
	    (double)*(const int64_t *)v : *(const int32_t *)v;
	return o;
}

Boolean
CFNumberGetValue(CFNumberRef n, CFNumberType t, void *v)
{
	if (t == kCFNumberDoubleType) { *(double *)v = n->num; } else if (t == kCFNumberFloatType) { *(float *)v = (float)n->num; }
	else if (t == kCFNumberSInt64Type) { *(int64_t *)v = (int64_t)n->num; } else { *(int32_t *)v = (int32_t)n->num; }
	return true;
}

CFArrayRef
CFArrayCreate(CFAllocatorRef a, const void **v, CFIndex n, const void *cb)
{
	struct mock_obj *o = mock_make(T_ARR);

	o->v = calloc((size_t)n + 1, sizeof(void *));
	for (long i = 0; i < n; i++) {
		o->v[i] = CFRetain(v[i]);
	}
	o->n = n;
	return o;
}

CFIndex CFArrayGetCount(CFArrayRef x) { return x->n; }
const void *CFArrayGetValueAtIndex(CFArrayRef x, CFIndex i) { return x->v[i]; }

static bool
same(const void *a, const void *b)
{
	if (a == b) {
		return true;
	}
	if (is_block(a) || is_block(b)) {
		return false;
	}
	const struct mock_obj *x = a, *y = b;

	return x->type == T_STR && y->type == T_STR && strcmp(x->text, y->text) == 0;
}

CFMutableDictionaryRef CFDictionaryCreateMutable(CFAllocatorRef a, CFIndex c, const void *k, const void *v) { return mock_make(T_DICT); }

void
CFDictionarySetValue(CFMutableDictionaryRef d, const void *k, const void *v)
{
	CFRetain(v);
	for (long i = 0; i < d->n; i++) {
		if (same(d->k[i], k)) {
			CFRelease(d->v[i]);
			d->v[i] = v;
			return;
		}
	}
	if (d->n == d->cap) {
		d->cap = d->cap ? d->cap * 2 : 8;
		d->k = realloc(d->k, (size_t)d->cap * sizeof(void *));
		d->v = realloc(d->v, (size_t)d->cap * sizeof(void *));
	}
	d->k[d->n] = CFRetain(k);
	d->v[d->n++] = v;
}

CFMutableDictionaryRef
CFDictionaryCreateMutableCopy(CFAllocatorRef a, CFIndex c, CFDictionaryRef d)
{
	struct mock_obj *o = mock_make(T_DICT);

	for (long i = 0; i < d->n; i++) {
		CFDictionarySetValue(o, d->k[i], d->v[i]);
	}
	return o;
}

const void *
CFDictionaryGetValue(CFDictionaryRef d, const void *k)
{
	for (long i = 0; i < d->n; i++) {
		if (same(d->k[i], k)) {
			return d->v[i];
		}
	}
	return NULL;
}

Boolean CFDictionaryContainsKey(CFDictionaryRef d, const void *k) { return CFDictionaryGetValue(d, k) != NULL; }
CFIndex CFDictionaryGetCount(CFDictionaryRef d) { return d->n; }
void CFDictionaryGetKeysAndValues(CFDictionaryRef d, const void **k, const void **v) { for (long i = 0; i < d->n; i++) { k[i] = d->k[i]; v[i] = d->v[i]; } }
void CFDictionaryApplyFunction(CFDictionaryRef d, void (*f)(const void *, const void *, void *), void *c) { for (long i = 0; i < d->n; i++) { f(d->k[i], d->v[i], c); } }
CFMutableSetRef CFSetCreateMutable(CFAllocatorRef a, CFIndex c, const void *cb) { return mock_make(T_DICT); }
Boolean CFSetContainsValue(CFSetRef s, const void *v) { return CFDictionaryContainsKey(s, v); }
void CFSetAddValue(CFMutableSetRef s, const void *v) { if (!CFDictionaryContainsKey(s, v)) { CFDictionarySetValue(s, v, v); } }

