# Sourced by kernel-ios26-linux.sh after a link: every check of kernel-linux.sh, then copy to out/. Any failure: no kernel in out/.
O=$W/out/kernel.ios26.development.sweet.$PAGES
mkdir -p "$W/out"
python3 -I "$BS" kernel-verify --kernel "$K" --work "$W" --stamp "$STAMP" --t0 "$T0" --xnu "$XNU_SRC" || exit 1
# the variant asked for: 0142 (sweet_early_map_final, sweet_early_fb_mapped) exists only with TOPAZ_4K
has4k=0
llvm-nm "$K.unstripped" 2>/dev/null | grep -E ' _sweet_early_(map_final|fb_mapped)$' >/dev/null && has4k=1
{ [ "$PAGES" = 4k ] && [ $has4k = 1 ]; } || { [ "$PAGES" = 16k ] && [ $has4k = 0 ]; } || { echo "kernel-ios26: not the PAGES=$PAGES variant (TOPAZ_4K symbol: $has4k)" >&2; exit 1; }
pat='\t(cas\w*|ldadd\w*|ldset\w*|ldclr\w*|ldeor\w*|swp\w*|ldapr\w*)\s'
n=$(llvm-objdump -d --mattr=+v8.5a "$K" | grep -cP "$pat" || true)
echo "kernel-ios26: LSE/RCpc instructions in the kernel: $n (must be 0: Kryo 260 is ARMv8.0)"
python3 -I "$REPO/scripts/laurel/printf-arg-check.py" "$XNU_SRC" || exit 1
python3 -I "$REPO/scripts/laurel/copyio-table-check.py" "$K.unstripped" || exit 1
# 22 words (21 on the iOS 16 kernel, same symbols + one lz4 constant): data under these symbols, decoded as instructions (2026-11-02)
python3 -I "$REPO/scripts/laurel/armv80-check.py" --data-syms K256,_lz4_decode_asm,_lz4_encode_2gb,fleh_irq_sp1,fleh_fiq_sp1,preempt_underflow,preempt_count_notzero,_update_mdscr "$K.unstripped" || exit 1
if [ "$n" != 0 ]; then
  llvm-objdump -d --mattr=+v8.5a "$K.unstripped" | grep -P "^[0-9a-f]+ <|$pat" | grep -B1 -P "$pat" | grep -P '^[0-9a-f]+ <' | sort -u >&2 || true
  echo "kernel-ios26: kernel has ARMv8.1+ instructions (functions above); not usable on the Mi A3" >&2; exit 1
fi
cp "$K" "$O"; [ -s "$K.unstripped" ] && cp "$K.unstripped" "$O.unstripped"
ln -sfn "$(basename "$O")" "$W/out/kernel.ios26.development.sweet"
(cd "$W/out" && sha256sum "$(basename "$O")" > SHA256SUMS)
cp "$W/series-report.txt" "$W/out/" 2>/dev/null || true
sed "s#$REPO/##" "$W/series-report.txt" > "$REPO/docs/laurel_sprout/ios26-kernel-series.txt"
python3 -I "$BS" kernel-seal "$K" "$O" "$STAMP"
python3 -I "$BS" kernel-check "$O"
file "$O"; ls -l "$O"; cat "$W/out/SHA256SUMS"; tail -1 "$W/out/series-report.txt"
echo "kernel-ios26: boot line: LAUREL BUILD: $STAMP"
echo "kernel-ios26: total $(( $(date +%s) - T0 )) s"
echo "kernel-ios26: $O"
