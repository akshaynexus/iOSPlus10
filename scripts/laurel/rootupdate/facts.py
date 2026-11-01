"""What the update plan needs from the phone. Read-only on the phone. docs/laurel_sprout/root-update.md."""
import os

import plan


def read_phone(ph, d, meta, rows):
    """Everything the plan needs. Read-only on the phone."""
    paths = [r.path for r in rows] + list(meta.get('dyld', {}))
    paths += [c for c in plan.CACHES]
    have = plan.parse_stat(ph.call('p_stat', paths), ph.R)
    want_hash = [r.path for r in rows if r.kind == 'f' and r.cls == 'i' and r.path in have and have[r.path][0] == 'f' and have[r.path][4] == r.size]
    hashes = plan.parse_hash(ph.call('p_hash', want_hash), ph.R) if want_hash else {}
    want_link = [r.path for r in rows if r.kind == 'l' and r.path in have and have[r.path][0] == 'l']
    links = dict(s.split('\t', 1) for s in ph.call('p_links', want_link).splitlines()) if want_link else {}
    small = [r.path for r in rows if r.cls in 'ma' and r.path in have]
    tops = plan.parse_stat(ph.call('p_stat', [plan.VERSION, plan.FILES, plan.MANIFEST]), ph.R)
    pulled = ph.pull(small + list(tops))
    prev_base, prev_first, prev_paths = plan.previous(pulled.get(plan.FILES))
    if prev_paths:      # stat of what an older build installed
        have.update(plan.parse_stat(ph.call('p_stat', prev_paths), ph.R))
    return have, hashes, links, pulled, prev_base, prev_first, prev_paths


def build_plan(d, meta, rows, phone_facts):
    have, hashes, links, pulled, prev_base, prev_first, prev_paths = phone_facts

    def base_of(p):
        try:
            with open(os.path.join(d, 'base', p), 'rb') as fh:
                return fh.read()
        except OSError:
            return None

    def store_of(sha):
        with open(os.path.join(d, 'store', sha), 'rb') as fh:
            return fh.read()

    acts, n = plan.compare(rows, have, links, hashes, pulled, base_of, store_of)
    gone, stale_problems = plan.stale(prev_paths, rows, plan.stock_paths(d), have)
    acts += gone
    for c in plan.CACHES:
        if c in have and any(not plan.trivial(x) for x in acts):
            acts.append(plan.Act('del', c, 'cache, made again at boot'))
    phone_first = plan.strip_update(pulled.get(plan.MANIFEST, b'').decode('utf-8', 'replace').partition('\n')[0])
    return acts, n, stale_problems, phone_first or None, prev_base is None, have, pulled, prev_base


def problems(meta, info, acts, stale_problems, have, pulled, prev_base):
    build = ''
    try:
        build = plan.merge.load(pulled.get(plan.VERSION, b'')).get('ProductBuildVersion', '')
    except Exception:  # noqa: BLE001  no file or a broken one: no answer, the base check still runs
        pass
    dyld_have = {p: have[p][4] for p in meta.get('dyld', {}) if p in have}
    need = plan.bytes_put(acts) + plan.rollback_bytes(acts, have)
    return plan.base_problems(meta, build, prev_base, dyld_have) + plan.no_update_problems(acts) + stale_problems + plan.info_problems(meta, info, need)
