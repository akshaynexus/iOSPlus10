#!/bin/bash
# userland/metal/plugin/icon_store_rule.h on a folder like the phone's store: an old store is emptied of .isdata once, __cache_info__ stays, the second start removes nothing, a new generation empties it again. Control: a store with no stamp is old. Exit 0: PASS.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/s/CAA87851"
for i in 1 2 3; do : > "$W/s/CAA87851/$i.isdata"; done
: > "$W/s/CAA87851/__cache_info__"
cat > "$W/t.c" <<C
#include "icon_store_rule.h"
#include <assert.h>
int main(int c,char**v){ (void)c;
 int a=laurel_icon_store_refresh(v[1],1),b=laurel_icon_store_refresh(v[1],1);
 printf("first %d, second %d\n",a,b);assert(a==3&&b==0);
 char p[4096];snprintf(p,sizeof p,"%s/CAA87851/__cache_info__",v[1]);assert(access(p,F_OK)==0);
 snprintf(p,sizeof p,"%s/CAA87851/9.isdata",v[1]);close(open(p,O_CREAT|O_WRONLY,0644));
 int d=laurel_icon_store_refresh(v[1],1);assert(d==0&&access(p,F_OK)==0);
 int g=laurel_icon_store_refresh(v[1],2);printf("new generation %d\n",g);assert(g==1&&access(p,F_OK)!=0);
 assert(laurel_icon_store_refresh("/nonexistent/x",1)==-1);
 puts("icon-store: PASS");return 0;}
C
cc -std=c11 -D_DEFAULT_SOURCE -Wall -I "$REPO/userland/metal/plugin" "$W/t.c" -o "$W/t"
"$W/t" "$W/s"
