#!/usr/bin/env python3
"""Independent check: compares every tag item of the edited files (build/e2e-report/edited) with the original
fixtures using mutagen. Only the album may differ. Run from desktop/ after `gradlew test --tests *TagPreservationTest*`."""
import hashlib, os, sys, mutagen
SRC = "src/test/resources/audio/rich"; OUT = "build/e2e-report/edited"
ALBUM = {"TALB", "ALBUM", "album", "\xa9alb", "Album"}
def dump(path):
    f = mutagen.File(path); out = {}
    for k, v in (f.tags or {}).items():
        if hasattr(v, "data"): v = hashlib.sha1(v.data).hexdigest()
        elif isinstance(v, list): v = [hashlib.sha1(bytes(x)).hexdigest() if isinstance(x, (bytes, bytearray)) else str(x) for x in v]
        else: v = str(v)
        out[k] = v
    if hasattr(f, "pictures"): out["__pictures"] = [(p.type, p.mime, hashlib.sha1(p.data).hexdigest()) for p in f.pictures]
    return out
bad = 0
for n in sorted(os.listdir(OUT)):
    a, b = dump(os.path.join(SRC, n)), dump(os.path.join(OUT, n))
    diff = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k) and k.split(":")[0] not in ALBUM)
    alb = [b.get(k) for k in b if k.split(":")[0] in ALBUM]
    print(("OK  " if not diff else "DIFF"), n, "items=%d" % len(a), "album=%s" % alb, diff[:5])
    bad += bool(diff)
sys.exit(1 if bad else 0)
