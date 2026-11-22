#!/usr/bin/env python3
"""Second opinion on a conformance report: open every file Forge wrote with a tool
that is not Forge, and check it holds what the original held.

    conformance_check.py report.formats.tsv

A row passes when the output decodes (sips / ImageMagick / ffprobe / pdftotext /
pandoc / plistlib / usdcat / fonttools) and, where it can be told, still carries
the picture's size, the recording's length, or the document's words.
"""
import csv, json, os, plistlib, subprocess, sys

def sh(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, errors="replace"); return r.returncode, r.stdout
    except Exception: return 1, ""
def dims(p):
    rc, o = sh(["sips", "-g", "pixelWidth", "-g", "pixelHeight", p]); v = [l.split()[-1] for l in o.splitlines() if "pixel" in l]
    if len(v) == 2 and v[0].isdigit(): return int(v[0]), int(v[1])
    rc, o = sh(["magick", "identify", "-format", "%w %h\n", p + "[0]"]); q = o.split()
    return (int(q[0]), int(q[1])) if len(q) >= 2 and q[0].isdigit() else None
def probe(p):
    rc, o = sh(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", p])
    try: j = json.loads(o)
    except Exception: return None
    kinds = [s.get("codec_type") for s in j.get("streams", [])]
    try: dur = float(j.get("format", {}).get("duration", "nan"))
    except ValueError: dur = float("nan")
    return dur, kinds
def words(p):
    e = p.rsplit(".", 1)[-1].lower()
    if e in ("rtf", "docx", "doc", "odt"): return sh(["textutil", "-convert", "txt", "-stdout", p])[1]
    if e == "pdf": return sh(["pdftotext", p, "-"])[1]
    if e in ("epub",): return sh(["pandoc", p, "-t", "plain"])[1]
    try: return open(p, errors="replace").read()
    except Exception: return ""

IMAGE = set("astc atx avif bmp dds exr gif heic heics icns ico jp2 jpeg jpg ktx ktx2 pbm ppm png psd pvr tga tiff tif webp".split())
SOUND = set("aiff caf flac m4a m4b wav mp3 ogg opus".split()); FILM = set("m4v mov mp4 mkv webm".split())
WORDS = ("HeadingAlpha", "CellMike"); DATA = ("Ada", "Grace")
SRC = os.environ.get("FORGE_CONFORMANCE_FIXTURES", "")
verdicts = {}
rows = [r for r in csv.reader(open(sys.argv[1]), delimiter="\t") if len(r) >= 6]
bad = []
for name, kind, label, status, secs, detail in rows:
    if status != "ok": continue
    src = os.path.join(SRC, name)
    for path in [p for p in detail.split(" /") if p]:
        path = path if path.startswith("/") else "/" + path
        if not os.path.exists(path): bad.append((name, label, "GONE", path)); continue
        files = [os.path.join(path, f) for f in sorted(os.listdir(path))] if os.path.isdir(path) else [path]
        f = files[0]; e = f.rsplit(".", 1)[-1].lower(); why = None
        if e in IMAGE:
            d = dims(f)
            if d is None: why = "does not decode"
            elif kind == "image":
                s = dims(src)
                if s and d != s and e not in ("icns", "ico"): why = f"size {d[0]}x{d[1]}, original {s[0]}x{s[1]}"
        elif e in SOUND or e in FILM:
            pr = probe(f)
            if pr is None or not pr[1]: why = "no stream in it"
            elif kind in ("audio", "video"):
                sp = probe(src)
                if sp and sp[0] == sp[0] and not abs(pr[0] - sp[0]) < 0.35: why = f"lasts {pr[0]:.2f}s, original {sp[0]:.2f}s"
                if e in FILM and kind == "video" and "video" not in pr[1]: why = "no picture"
                if e in FILM and kind == "video" and sp and "audio" in sp[1] and "audio" not in pr[1]: why = "sound lost"
            elif not pr[0] > 1: why = f"lasts {pr[0]:.2f}s"
        elif e == "pdf":
            if kind == "document" and not all(w in words(f) for w in WORDS): why = "words not in it"
        elif e in ("txt", "html", "rtf", "docx", "md", "markdown", "srt", "vtt", "sbv"):
            body = words(f)
            if kind in ("document", "subtitle") and not all(w in body for w in WORDS): why = "words lost: " + " ".join(w for w in WORDS if w not in body)
            if kind == "image" and name.split(".")[-1] not in ("svg",) and "FORGE" not in body.upper(): why = f"text not read: {body.strip()[:30]!r}"
        elif e in ("json", "csv", "tsv", "plist", "toml"):
            raw = open(f, "rb").read(); body = raw.decode("utf8", "replace")
            try:
                if e == "plist": body = json.dumps(plistlib.loads(raw), default=str)
                if e == "json": json.loads(body)
            except Exception as ex: why = f"does not parse: {str(ex)[:50]}"
            if not why and name.split(".")[-1] != "toml" and not all(w in body for w in DATA): why = "values lost"
        if why: bad.append((name, label, why, f))
ok = sum(1 for r in rows if r[3] == "ok")
print(f"{len(rows)} attempts, {ok} reported ok, {len(bad)} of those fail the second opinion")
group = {}
for name, label, why, f in bad: group.setdefault((label, why.split(",")[0].split(":")[0]), []).append((name, why))
for (label, w), items in sorted(group.items()):
    print(f"  -> {label:9} {w:22} {len(items):3}: " + " ".join(sorted(set(n.split('.')[-1] for n, _ in items)))[:150] + f"   e.g. {items[0][1][:60]}")
