# Sourced by kernel-ios26-linux.sh after a link: every check of kernel-linux.sh, then copy to out/. Any failure: no kernel in out/.
O=$W/out/kernel.ios26.development.sweet.$PAGES
mkdir -p "$W/out"
pat='\t(cas\w*|ldadd\w*|ldset\w*|ldclr\w*|ldeor\w*|swp\w*|ldapr\w*)\s'
n=$(llvm-objdump -d --mattr=+v8.5a "$K" | grep -cP "$pat" || true)
echo "kernel-ios26: LSE/RCpc instructions in the kernel: $n (must be 0: Kryo 260 is ARMv8.0)"
python3 -I "$REPO/scripts/laurel/printf-arg-check.py" "$XNU_SRC" || exit 1
# the same 21 words as the iOS 16 kernel: data under these symbols, decoded as instructions (2026-11-02)
python3 -I "$REPO/scripts/laurel/armv80-check.py" --data-syms K256,_lz4_decode_asm,fleh_irq_sp1,fleh_fiq_sp1,preempt_underflow,preempt_count_notzero,_update_mdscr "$K.unstripped" || exit 1
if [ "$n" != 0 ]; then
  llvm-objdump -d --mattr=+v8.5a "$K.unstripped" | grep -P "^[0-9a-f]+ <|$pat" | grep -B1 -P "$pat" | grep -P '^[0-9a-f]+ <' | sort -u >&2 || true
  echo "kernel-ios26: kernel has ARMv8.1+ instructions (functions above); not usable on the Mi A3" >&2; exit 1
fi
cp "$K" "$O"; [ -s "$K.unstripped" ] && cp "$K.unstripped" "$O.unstripped"
ln -sfn "$(basename "$O")" "$W/out/kernel.ios26.development.sweet"
(cd "$W/out" && sha256sum "$(basename "$O")" > SHA256SUMS)
cp "$W/series-report.txt" "$W/out/" 2>/dev/null || true
file "$O"; ls -l "$O"; cat "$W/out/SHA256SUMS"; tail -1 "$W/out/series-report.txt"
echo "kernel-ios26: $O"
