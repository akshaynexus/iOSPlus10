"""Merge what our root steps set into the phone's own /private/var files. docs/laurel_sprout/root-update.md "What stays".

Input of a plist merge: base (the stock file, {} when the stock root had none), final (the same file after our steps), phone (what the phone has).
Only the difference base -> final is ours; every other key stays as the phone has it:
- a dictionary merges key by key, so a dictionary that our steps made (Sets of preferences.plist) keeps the phone's other entries (the Wi-Fi service);
- a list: our new items move to the end (ServiceOrder: the USB service stays last), items we removed go, the phone's others stay;
- OWNED subtrees are ours as a whole (our USB service: an old Router and DNS must go);
- a key in OWNER_SETTINGS is a default: the phone's value stays when it has one (language, Bold Text, Location Services).
"""
import plistlib

# The owner can change these in Settings; the root only gives the first value
OWNER_SETTINGS = {'AppleLanguages', 'AppleLocale', 'EnhancedTextLegibilityEnabled', 'LocationServicesEnabledIn8.0'}
OWNED = {'preferences.plist': ('NetworkServices',)}


def ident(item):
    if isinstance(item, dict) and 'BSD Name' in item:
        return ('BSD Name', item['BSD Name'])
    return repr(item)


def merge_list(base, final, phone):
    base_ids = {ident(x) for x in base}
    final_ids = {ident(x) for x in final}
    new = [x for x in final if ident(x) not in base_ids]
    drop = {ident(x) for x in new} | (base_ids - final_ids)
    return [x for x in phone if ident(x) not in drop] + new


def merge_dict(base, final, phone, owned=(), path=()):
    out = dict(phone)
    for k, v in final.items():
        here = path + (k,)
        if k in base and base[k] == v:
            continue
        if not path and k in OWNER_SETTINGS and k in phone:
            continue
        cur = out.get(k)
        old = base.get(k)
        if len(here) == 2 and here[0] in owned:   # a child of an owned key is ours as a whole
            out[k] = v
        elif isinstance(v, dict) and isinstance(cur, dict):
            out[k] = merge_dict(old if isinstance(old, dict) else {}, v, cur, owned, here)
        elif isinstance(v, list) and isinstance(cur, list):
            out[k] = merge_list(old if isinstance(old, list) else [], v, cur)
        else:
            out[k] = v
    for k in base:
        if k not in final:
            out.pop(k, None)
    return out


def same_set(final, phone):
    """preferences.plist: our service goes into the phone's current set, also when its name differs from the image's."""
    want, have = final.get('CurrentSet'), phone.get('CurrentSet')
    if not want or not have or want == have or not isinstance(final.get('Sets'), dict):
        return final
    out = dict(final, CurrentSet=have, Sets=dict(final['Sets']))
    moved = out['Sets'].pop(want.rsplit('/', 1)[-1], None)
    if moved is not None:
        out['Sets'][have.rsplit('/', 1)[-1]] = moved
    return out


def merge_plist(name, base, final, phone):
    if name == 'preferences.plist':
        final = same_set(final, phone)
    return merge_dict(base, final, phone, OWNED.get(name, ()))


def load(data):
    return plistlib.loads(data)


def dump(value, like):
    """The phone's own format: binary stays binary, XML stays XML."""
    fmt = plistlib.FMT_BINARY if like[:6] == b'bplist' else plistlib.FMT_XML
    return plistlib.dumps(value, fmt=fmt, sort_keys=False)


def merge_file(name, base_bytes, final_bytes, phone_bytes):
    """New bytes for the phone, or None when the phone already has every key of ours. Phone file that cannot be read: the final file."""
    final = load(final_bytes)
    base = load(base_bytes) if base_bytes else {}
    try:
        phone = load(phone_bytes)
    except Exception:  # noqa: BLE001  plistlib raises many kinds on a broken file
        return final_bytes
    out = merge_plist(name, base, final, phone)
    return None if out == phone else dump(out, phone_bytes)


def merge_lines(final_bytes, phone_bytes):
    """authorized_keys: the phone's lines stay, ours are added. None = nothing to add."""
    have = phone_bytes.decode('utf-8', 'replace').splitlines()
    add = [s for s in final_bytes.decode('utf-8', 'replace').splitlines() if s.strip() and s not in have]
    if not add:
        return None
    return ('\n'.join(have + add) + '\n').encode()
