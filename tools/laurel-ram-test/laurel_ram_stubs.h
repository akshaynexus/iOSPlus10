/* Host stand-ins for what osfmk/arm64/laurel_ram.c needs (scripts/laurel/ram-map-test.sh). */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define SWEET 1
typedef struct { uint64_t physBase, memSize; } boot_args;
typedef const void *DTEntry;
#define kSuccess 0
int SecureDTLookupEntry(void *parent, const char *path, DTEntry *out);
int SecureDTGetProperty(DTEntry e, const char *name, void const **prop, unsigned int *len);
bool PE_parse_boot_argn(const char *name, void *value, int size);
typedef unsigned int ppnum_t;
struct vm_page { ppnum_t phys; int vmp_q_state; };
typedef struct vm_page *vm_page_t;
extern struct vm_page vm_pages[1];
extern int vm_himemory_mode;
#define FALSE 0
#define VM_PAGE_ON_FREE_Q 1
#define VM_PAGE_GET_PHYS_PAGE(m) ((m)->phys)
#define atop_64(x) ((x) >> 12)
#define ptoa_64(x) ((x) << 12)
#define STARTUP(a, b, c) static void (*const unused_##c)(void) __attribute__((unused)) = c
