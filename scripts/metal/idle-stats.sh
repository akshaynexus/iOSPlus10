#!/bin/sh
# Idle cost of the Metal path, from the logs we already have (no phone write):
#   - kernel log (logs/usblog.log, `make usblog`): the `NEGRONI FB STAT` lines (swaps/s, presents/s per second) and the
#     `NEGRONI GPU WATCH` samples (RBBM status, 0x1 = idle, anything else = busy; gxclk).
#   - plugin telemetry (backboardd writes it every 10 s to /var/db/negronimetal/metal.log while /var/db/negronimetal/telemetry
#     exists): two snapshots of the `S c<commits>/<failures> d<completed> p<pipelines> x<problems> R<passes> D<draws>
#     F<full-screen passes> M<biggest pass KiB> C<dispatches> B<blits>` row give command buffers, passes and blits per second,
#     and the `J surface cache n= bytes= us=` row the CPU `dc civac` cost of flushSurfaces (flame/0010 knob).
#
#   scripts/metal/idle-stats.sh [-s SECONDS] [-l LOGFILE]     kernel-log part over the last SECONDS (default 120) of LOGFILE
#   scripts/metal/idle-stats.sh telemetry [SECONDS]           pull metal.log now and again after SECONDS (default 20), print the rates
#
# Read it while the phone is idle (screen on, nothing moving) and again while scrolling, to compare. Keep the GPU answers in mind:
# since 0384 the kernel governor picks the clock (lowest level 220 MHz when idle; negronigpu_level=N fixes it), and IFPC
# collapses GX between frames; this script shows whether the bridge adds work on top (presents/s > 0 or RBBM busy while
# nothing moves), which keeps the governor and GX up.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SECS=120
LOG=$REPO/logs/usblog.log
mode=kernel
case "${1:-}" in telemetry) mode=telemetry; SECS=${2:-20}; shift $# ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SECS=$2; shift 2 ;;
    -l) LOG=$2; shift 2 ;;
    *) echo "usage: $0 [-s SECONDS] [-l LOGFILE] | telemetry [SECONDS]" >&2; exit 2 ;;
  esac
done

if [ $mode = kernel ]; then
  [ -f "$LOG" ] || { echo "no $LOG (make usblog)" >&2; exit 1; }
  # the last SECS seconds by the HH:MM:SS prefix of the last line
  last=$(tail -n 1 "$LOG" | cut -c1-8)
  awk -v last="$last" -v secs="$SECS" '
    function t(s,  a){split(s,a,":");return a[1]*3600+a[2]*60+a[3]}
    BEGIN{end=t(last);start=end-secs}
    { s=substr($0,1,8); if(s !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) next; now=t(s); if(now<start||now>end) next }
    /NEGRONI FB STAT/ {
      for(i=1;i<=NF;i++){ if($i=="swaps/s")sw+=$(i+1); if($i=="presents/s"){pr+=$(i+1); if($(i+1)==0)idle++; else active++} }
      stat++ }
    /NEGRONI GPU WATCH/ {
      for(i=1;i<=NF;i++){ if($i=="RBBM"){ if($(i+1)=="0x1")gidle++; else gbusy++ } if($i=="gxclk"){clk[$(i+1)]++} }
      watch++ }
    END{
      printf("window: last %d s of the log (until %s)\n", secs, last);
      if(stat){printf("FB STAT lines %d: seconds with presents/s 0: %d, with presents: %d; mean swaps/s %.1f presents/s %.1f\n",stat,idle,active,sw/stat,pr/stat)}
      else print "no FB STAT lines in the window";
      if(watch){printf("GPU WATCH samples %d: RBBM idle (0x1) %d, busy %d (%.0f%% busy); gxclk:",watch,gidle,gbusy,100*gbusy/watch); for(k in clk)printf(" %s MHz x%d",k,clk[k]); printf("\n")}
      else print "no GPU WATCH samples in the window (the watch logs only while the kernel GPU watch runs)";
    }' "$LOG"
  exit 0
fi

# telemetry: two snapshots of the S and J rows of backboardd's telemetry
SSH=$REPO/scripts/net/ssh-phone.sh
snap() { "$SSH" "grep -a -A40 'NMTL\\[[0-9]* backboardd\\]: telemetry' /var/db/negronimetal/metal.log | grep -a '^S \\|^J surface cache' | tail -n 2"; }
"$SSH" "test -e /var/db/negronimetal/telemetry" 2>/dev/null || {
  echo "telemetry is off: scripts/net/ssh-phone.sh 'touch /var/db/negronimetal/telemetry' (backboardd writes a table every 10 s; no restart needed)" >&2; exit 1; }
a=$(snap); sleep "$SECS"; b=$(snap)
printf "before:\n%s\nafter (%s s later):\n%s\n" "$a" "$SECS" "$b"
printf "%s\n%s\n" "$a" "$b" | awk -v secs="$SECS" '
  /^S / { n++; for(i=2;i<=NF;i++){ k=substr($i,1,1); v=substr($i,2); sub("/.*","",v); sub("k$","",v); val[n,k]=v+0 } }
  /^J surface cache/ { m++; for(i=4;i<=NF;i++){ split($i,kv,"="); j[m,kv[1]]=kv[2]+0 } }
  END{
    if(n>=2){ printf("per second: command buffers %.2f (completed %.2f), render passes %.2f, draws %.1f, full-screen passes %.2f, dispatches %.2f, blits %.2f\n",
      (val[2,"c"]-val[1,"c"])/secs,(val[2,"d"]-val[1,"d"])/secs,(val[2,"R"]-val[1,"R"])/secs,(val[2,"D"]-val[1,"D"])/secs,
      (val[2,"F"]-val[1,"F"])/secs,(val[2,"C"]-val[1,"C"])/secs,(val[2,"B"]-val[1,"B"])/secs) }
    else print "fewer than two S rows: is backboardd on the Metal device, and was the telemetry file there for 10 s?";
    if(m>=2){ printf("flushSurfaces: %.1f flushes/s, %.1f MiB/s, %.1f ms CPU per second\n",(j[2,"n"]-j[1,"n"])/secs,(j[2,"bytes"]-j[1,"bytes"])/secs/1048576,(j[2,"us"]-j[1,"us"])/secs/1000) }
  }'
