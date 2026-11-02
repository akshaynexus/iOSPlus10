#!/bin/bash
# The transient-texture pool's rules (flame-ios26/0004, phone/metal2/laurel_rules.h) on the host: a frame's targets come back, same key only, caps hold, stale ones leave. No GPU.
#   scripts/ios26/test-texture-pool.sh       Input: the flame tree of scripts/laurel/ios26-metal-build.sh fetch. Exit 0: PASS.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cat > "$W/t.c" <<'C'
#include <stdio.h>
#include "laurel_rules.h"
#define OK(x) do{if(!(x)){printf("FAIL %s\n",#x);bad=1;}}while(0)
int main(void){
 int bad=0;static struct laurel_pool p;uint64_t a[8]={80,722,1562,5,32},b[8]={115,896,320,5,32};
 const uint64_t cap=96ull<<20;
 /* one frame's targets come back and the next frame takes each: 0 new textures in the second frame */
 void *h1=(void*)0x10,*h2=(void*)0x20;unsigned made=0;
 for(int frame=0;frame<100;frame++){
  void *x=laurel_pool_take(&p,a);if(!x){x=h1;made++;}
  void *y=laurel_pool_take(&p,b);if(!y){y=h2;made++;}
  OK(x==h1&&y==h2);
  laurel_pool_put(&p,x,a,4600000,frame*16000ull);laurel_pool_put(&p,y,b,2400000,frame*16000ull);
 }
 printf("100 frames, 2 targets each: %u made\n",made);OK(made==2);
 /* another key: nothing */
 uint64_t c[8]={80,1,1,5,32};OK(laurel_pool_take(&p,c)==0);
 /* stale: 2 s */
 OK(!laurel_pool_oldest_stale(&p,100*16000ull));OK(laurel_pool_oldest_stale(&p,99*16000ull+LAUREL_POOL_MAX_AGE_US+1));
 /* caps: slots and bytes */
 unsigned n=0;while(laurel_pool_drop_oldest(&p))n++;OK(n==2);OK(p.bytes==0);
 for(unsigned i=0;i<100;i++){while(!laurel_pool_fits(&p,8u<<20,cap,LAUREL_POOL_SLOTS))laurel_pool_drop_oldest(&p);laurel_pool_put(&p,(void*)(uintptr_t)(i+1),a,8u<<20,0);}
 OK(p.bytes<=cap);OK(p.count<=LAUREL_POOL_SLOTS);printf("after 100 of 8 MiB: %u held, %llu MiB\n",p.count,(unsigned long long)(p.bytes>>20));
 /* the threadgroup answer: A610, A640, Apple */
 OK(laurel_kernel_max_threads(1024,32,16384)==512);OK(laurel_kernel_max_threads(1024,32,32768)==1024);OK(laurel_kernel_max_threads(1024,32,0)==1024);
 puts(bad?"texture-pool: FAIL":"texture-pool: PASS");return bad;
}
C
cc -std=c11 -Wall -I "$REPO/out/ios26/metal/src/flame/phone/metal2" "$W/t.c" -o "$W/t"
"$W/t"
