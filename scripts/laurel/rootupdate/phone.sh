# Phone side of scripts/laurel/root-update.sh. docs/laurel_sprout/root-update.md. Runs in dash + toybox (out/ssh/ios), the only tools an old root surely has.
# The host sends this text + one call through `sh -s`, so a read-only call leaves no file on the phone. R = "" on the phone, a folder in the host test.
PATH=${ROOT_UPDATE_PHONE_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH}   # the variable: only the host test
export PATH
W=$R/private/var/root/laurel-update
S=$W/stage
RB=$R/private/var/root/laurel-rollback
TAB=$(printf '\t')

nul() { tr '\n' '\0'; }
# Remove one path of the plan. R can be empty, so the path itself is checked: never an empty, absolute or climbing one
rmp() {
  case $1 in
    ''|/*|..|../*|*/..|*/../*) echo "bad path: '$1'"; return 1 ;;
  esac
  rm -rf "$R/$1"
}

# stdin: relative paths. Out: hex mode, uid, gid, size, full path; a missing path gives no line. DIR: another top folder (the stage)
p_stat() {
  d=${1-$R}
  sed "s|^|$d/|" | nul | xargs -0 stat -c '%f %u %g %s %n' 2>/dev/null
  return 0
}
p_links() {
  while IFS= read -r p; do
    t=$(readlink "$R/$p") && printf '%s\t%s\n' "$p" "$t"
  done
  return 0
}
p_hash() {
  d=${1-$R}
  sed "s|^|$d/|" | nul | xargs -0 sha256sum 2>/dev/null
  return 0
}
# stdin: relative paths that exist. Out: a tar on stdout (plists, key file, version; small files only)
p_pull() {
  set --
  while IFS= read -r p; do set -- "$@" "$p"; done
  [ $# = 0 ] || tar cf - -C "$R/" "$@"
}
p_info() {
  echo "uid $(id -u)"
  echo "dev_var $(stat -c %d "$R/private/var/root")"
  echo "dev_root $(stat -c %d "$R/")"
  df -k "$R/" | tail -1 | sed 's/^/df /'
  if [ -z "$R" ]; then mount | grep ' on / ' | sed 's/^/mount /'; else echo "mount hfs test"; fi
  [ -f "$RB/latest" ] && echo "rollback $(cat "$RB/latest")"
  return 0
}

# stdin: mode uid gid path, in the stage. chown first: chown clears the setuid bit
p_fixmeta() {
  u=$(id -u)
  while IFS="$TAB" read -r mode uid gid p; do
    if [ "$u" = 0 ]; then chown -h "$uid:$gid" "$S/$p" || return 1; fi
    chmod "$mode" "$S/$p" || return 1
  done
}
# The tools every later step needs must start from the stage before anything changes. A kill (bad signature) is 137, a refused exec is 126
p_smoke() {
  while IFS= read -r p; do
    "$S/$p" --version </dev/null >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ge 126 ]; then echo "does not start: /$p (exit $rc)"; return 1; fi
  done
  return 0
}

# ID: the old copy of everything that will change. $W/rb.replace, $W/rb.new (from the host). Keep the 2 newest.
p_rollback_make() {
  id=$1
  D=$RB/$id
  mkdir -p "$D" || return 1
  chmod 700 "$RB" "$D"
  cp "$W/rb.replace" "$W/rb.new" "$D/" || return 1
  if [ -s "$D/rb.replace" ]; then
    nul < "$D/rb.replace" > "$D/rb.replace0"
    tar cf "$D/rollback.tar" -C "$R/" --null -T "$D/rb.replace0" || return 1
    have=$(tar tf "$D/rollback.tar" | wc -l)
    want=$(wc -l < "$D/rb.replace")
    if [ "$have" -lt "$want" ]; then echo "rollback tar has $have entries, wanted $want"; return 1; fi
  fi
  echo "$id" > "$RB/latest"
  n=0
  for x in $(ls -1 "$RB" | sort -r); do
    [ "$x" = latest ] && continue
    n=$((n + 1))
    [ "$n" -le 2 ] || rm -rf "${RB:?}/$x"
  done
  sync
  return 0
}

# One plan line: op a b c path, tab separated (no empty field).
# D mode uid gid: make a folder; M mode uid gid: owner and mode only; X: remove (a kind change); F: rename stage -> root; G: remove a gone path
p_one() {
  case $op in
    D) [ -d "$R/$p" ] || mkdir "$R/$p" || return 1
       if [ "$u" = 0 ]; then chown "$b:$c" "$R/$p" || return 1; fi
       chmod "$a" "$R/$p" ;;
    M) if [ "$u" = 0 ]; then chown -h "$b:$c" "$R/$p" || return 1; fi
       chmod "$a" "$R/$p" ;;
    X|G) rmp "$p" ;;
    F) mv -fT "$S/$p" "$R/$p" ;;
    *) echo "unknown plan line: $op"; return 1 ;;
  esac
}
# Every change is one rename or one small command. A dropped SSH does not stop this: the host starts it with setsid + nohup and reads the status file.
p_apply() {
  st=$1.status
  trap '' HUP PIPE
  echo running > "$st"
  n=0
  u=$(id -u)
  while IFS="$TAB" read -r op a b c p; do
    n=$((n + 1))
    if ! p_one; then
      echo "failed at line $n: $op /$p" > "$st"
      return 1
    fi
    [ $((n % 200)) != 0 ] || echo "running $n" > "$st"
  done < "$1"
  sync
  echo "done $n" > "$st"
  return 0
}
p_start() {
  rm -f "$W/plan.tsv.status"
  setsid nohup sh -c ". '$W/phone.sh'; p_apply '$W/plan.tsv'" </dev/null >>"$W/commit.log" 2>&1 &
  return 0
}
p_status() {
  cat "$W/plan.tsv.status" 2>/dev/null
  return 0
}

# Back to the old files: each one by rename, new paths removed. ID = the newest when empty.
p_rollback() {
  id=${1:-$(cat "$RB/latest" 2>/dev/null)}
  D=$RB/$id
  [ -n "$id" ] && [ -d "$D" ] || { echo "no rollback $id in $RB"; return 1; }
  rm -rf "$D/restore"
  mkdir "$D/restore" || return 1
  if [ -f "$D/rollback.tar" ]; then tar xpf "$D/rollback.tar" -C "$D/restore" --numeric-owner || return 1; fi
  # paths new in this update: files first, then folders, deepest first
  sort -r "$D/rb.new" | while IFS= read -r p; do
    if [ -d "$R/$p" ] && [ ! -L "$R/$p" ]; then rmdir "$R/$p" 2>/dev/null; else rm -f "$R/$p"; fi
  done
  while IFS= read -r p; do
    [ -e "$D/restore/$p" ] || [ -L "$D/restore/$p" ] || { echo "not in the rollback tar: /$p"; return 1; }
    mkdir -p "$(dirname "$R/$p")"
    # a kind change, or a folder that a gone step left: the old path comes back whole
    if [ -d "$R/$p" ] && [ ! -L "$R/$p" ]; then rmp "$p" || return 1; fi
    mv -fT "$D/restore/$p" "$R/$p" || return 1
  done < "$D/rb.replace"
  rm -rf "$D/restore"
  sync
  echo "rolled back $id"
  return 0
}
p_clean() {
  rm -rf "${W:?}/stage"
  return 0
}
# After the boot: what lsd must learn. Lines "R path" = register, "U path" = unregister; failed ones stay for the next run
p_register() {
  f=$W/register.list
  [ -s "$f" ] || { echo "register: nothing to do"; return 0; }
  command -v pmregister >/dev/null 2>&1 || { echo "register: off: no pmregister on this root"; return 0; }
  : > "$f.left"
  while read -r op p; do
    if [ "$op" = U ]; then a='-u'; else a=''; fi
    # shellcheck disable=SC2086
    if pmregister $a "$p" </dev/null; then echo "register: $op $p"; else echo "register: FAILED $op $p"; echo "$op $p" >> "$f.left"; fi
  done < "$f"
  mv -f "$f.left" "$f"
  return 0
}
p_first_line() {
  head -1 "$R/usr/share/laurel/root-manifest" 2>/dev/null
  return 0
}
p_net() {
  [ -x /usr/local/bin/usbnetcfg ] && [ -z "$R" ] && /usr/local/bin/usbnetcfg show 2>&1 | grep -E 'PrimaryInterface|Router' | head -4
  return 0
}
