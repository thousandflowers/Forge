#!/usr/bin/env python3
"""Make one real file for every format Forge says it reads.

    conformance_fixtures.py OUT_FOLDER [--raw] [--fresh]

Files already there are kept unless --fresh is given.

Everything is made with tools other than Forge (sips, ImageMagick, ffmpeg, pandoc,
textutil, usdcat, fonttools), so a file Forge cannot read is Forge's doing. Camera
raw files cannot be made: --raw downloads the smallest public-domain sample of each
kind from raw.pixls.us. What could not be made is listed at the end, not hidden.
"""
import csv, json, os, plistlib, re, shutil, subprocess, sys, urllib.parse, urllib.request

OUT = os.path.abspath(sys.argv[1]); WANT_RAW = "--raw" in sys.argv; FRESH = "--fresh" in sys.argv
WORK = OUT + ".work"
for d in (OUT, WORK): os.makedirs(d, exist_ok=True)
FONT = "/System/Library/Fonts/Helvetica.ttc"
made, missing = {}, {}

def run(cmd, **kw):
    try: return subprocess.run(cmd, capture_output=True, timeout=180, **kw).returncode == 0
    except Exception: return False
def out(ext): return f"{OUT}/sample.{ext}"
def good(ext): return os.path.exists(out(ext)) and (os.path.isdir(out(ext)) or os.path.getsize(out(ext)) > 0)
def attempt(ext, how, *cmds):
    """Try each command until one leaves the file."""
    if good(ext) and not FRESH: made[ext] = "kept"; return True
    for cmd in cmds:
        if callable(cmd): cmd()
        else: run(cmd)
        if good(ext): made[ext] = how; return True
        if os.path.exists(out(ext)) and not os.path.isdir(out(ext)): os.remove(out(ext))
    missing[ext] = how; return False
def text(ext, body, how="written by hand"):
    open(out(ext), "w").write(body); made[ext] = how

# ---- pictures
base = WORK + "/base.png"
run(["magick", "-size", "640x480", "gradient:red-blue", "-font", FONT, "-pointsize", "60", "-fill", "white", "-annotate", "+40+240", "FORGE 123", base])
SIPS = {"jpeg": "jpeg", "tif": "tiff", "tiff": "tiff", "heif": "heic", "pic": "pict", "pict": "pict"}
for ext in "astc atx avif bmp dds exr gif heic heif icns ico jp2 jpeg jxl ktx ktx2 pbm pic pict png psd pvr sgi tga tif tiff webp dicom mpo".split():
    square = WORK + "/square.png"; run(["magick", base, "-resize", "256x256!", square])
    src = square if ext in ("icns", "ico", "pvr") else base
    attempt(ext, "sips or ImageMagick", ["sips", "-s", "format", SIPS.get(ext, ext), src, "--out", out(ext)],
            ["magick", src, ("dcm:" if ext == "dicom" else "") + out(ext)])
text("svg", '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480"><rect width="640" height="480" fill="#c33"/><text x="40" y="240" font-size="60" fill="white">FORGE 123</text></svg>\n')
attempt("heics", "ffmpeg cannot write it; ImageMagick as a sequence", ["magick", base, base, out("heics")])

# ---- camera raw: nothing makes these, so public-domain samples are fetched
RAW = "3fr arw cr2 cr3 crw dcr dng erf fff iiq mos mrw nef nrw orf pef raf raw rw2 rwl sr2 srf srw".split()
if WANT_RAW:
    index = WORK + "/pixls.json"
    if not os.path.exists(index): urllib.request.urlretrieve("https://raw.pixls.us/json/getrepository.php?set=all", index)
    found = {}
    for row in json.load(open(index))["data"]:
        m = re.search(r"href='([^']+/nice/[^']+)'.*?\(([\d.]+)MB\)", row[7])
        if not m: continue
        url, size = m.group(1).replace("\\/", "/"), float(m.group(2)); ext = url.rsplit(".", 1)[-1].lower()
        if ext in RAW: found.setdefault(ext, []).append((size, url))
    def readable(path):  # macOS reads raw files camera by camera, so a sample only counts if it opens here
        r = subprocess.run(["sips", "-g", "pixelWidth", path], capture_output=True, text=True)
        return "pixelWidth: " in r.stdout and "<nil>" not in r.stdout
    for ext in RAW:
        if good(ext) and readable(out(ext)): made[ext] = "kept"; continue
        tried = 0
        for size, url in sorted(found.get(ext, []))[:8]:
            if size > 45: break
            tried += 1
            run(["curl", "-sfL", "-m", "170", "-o", out(ext), urllib.parse.quote(url, safe=":/")])
            if good(ext) and readable(out(ext)): made[ext] = f"raw.pixls.us, {size} MB"; break
        else:
            if good(ext): made[ext] = "raw.pixls.us"; missing[ext] = f"sample kept, but macOS itself opens none of the {tried} tried (camera not supported)"
            else: missing[ext] = "no public sample on raw.pixls.us"
else:
    for ext in RAW: missing[ext] = "camera raw: run again with --raw to download a sample"

# ---- sound and film
FF = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
wav = WORK + "/tone.wav"; mov = WORK + "/clip.mov"
# A spoken sentence rather than a tone, so that turning sound into text has words to find,
# and a subtitle track in the film, so that taking the subtitles out has some to take.
SPOKEN = "The quick brown fox jumps over the lazy dog. Forge converts this recording."
run(["say", "-v", "Samantha", "-o", WORK + "/say.aiff", SPOKEN])
run(FF + ["-i", WORK + "/say.aiff", "-ac", "2", "-ar", "44100", wav])
open(WORK + "/track.srt", "w").write("1\n00:00:00,000 --> 00:00:02,000\nHeadingAlpha first line\n\n2\n00:00:02,100 --> 00:00:04,000\nCellMike second line\n\n")
run(FF + ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=6", "-i", wav, "-i", WORK + "/track.srt",
          "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "mov_text", "-t", "4.6", mov])
SOUND = {  # extension -> extra ffmpeg arguments
    "wav": [], "aiff": [], "aifc": ["-f", "aiff", "-c:a", "pcm_s16be"], "caf": [], "flac": [], "m4a": [], "m4b": ["-f", "ipod"], "m4r": ["-f", "ipod"],
    "mp3": [], "mp2": [], "m1a": ["-f", "mp2"], "m2a": ["-f", "mp2"], "aac": [], "ac3": [], "eac3": [], "au": [], "w64": [],
    "ogg": ["-c:a", "libopus"], "opus": [], "wma": [], "mka": [], "amr": ["-ar", "8000", "-ac", "1"], "awb": ["-ar", "16000", "-ac", "1"],
    "loas": ["-f", "latm", "-c:a", "aac"],
}
for ext, extra in SOUND.items(): attempt(ext, "ffmpeg", FF + ["-i", wav, *extra, out(ext)])
attempt("xhe", "afconvert (xHE-AAC)", lambda: (run(["afconvert", "-f", "m4af", "-d", "usac", wav, WORK + "/xhe.m4a"]), os.path.exists(WORK + "/xhe.m4a") and shutil.copy(WORK + "/xhe.m4a", out("xhe"))))
FILM = {
    "mov": ["-map", "0", "-c", "copy"], "mp4": ["-map", "0", "-c", "copy"], "m4v": ["-map", "0", "-c", "copy"], "mqv": ["-c", "copy", "-f", "mov"], "qta": ["-vn", "-c", "copy", "-f", "mov"],
    "3gpp": ["-f", "3gp", "-c:v", "libx264", "-c:a", "aac"], "3g2": ["-c:v", "libx264", "-c:a", "aac"],
    "avi": [], "dv": ["-s", "720x576", "-r", "25", "-ar", "48000", "-ac", "2", "-pix_fmt", "yuv420p"],
    "mpeg": [], "m2v": ["-an", "-c:v", "mpeg2video"], "m2p": ["-f", "vob"], "vob": [], "mod": ["-f", "vob"],
    "ts": ["-c", "copy"], "mts": ["-c", "copy", "-f", "mpegts"], "m2t": ["-c", "copy", "-f", "mpegts"],
    "mkv": ["-map", "0", "-c:v", "copy", "-c:a", "copy", "-c:s", "srt"], "webm": [], "flv": [], "wmv": [], "ogv": [],
}
for ext, extra in FILM.items(): attempt(ext, "ffmpeg", FF + ["-i", mov, *extra, out(ext)])
for ext in ("aa", "aax", "m4p"): missing[ext] = "copy-protected by design: no file without a purchase"
for ext in ("aivu", "sc2", "avci", "axr", "dxo", "nefx"): missing[ext] = "no tool here writes it and no public sample found"

# ---- captions and playlists
CUES = [("00:00:00", "000", "00:00:01", "500", "HeadingAlpha first line"), ("00:00:01", "600", "00:00:02", "900", "CellMike second line")]
text("srt", "".join(f"{i+1}\n{a},{b} --> {c},{d}\n{t}\n\n" for i, (a, b, c, d, t) in enumerate(CUES)))
vtt = "WEBVTT\n\n" + "".join(f"{a}.{b} --> {c}.{d}\n{t}\n\n" for a, b, c, d, t in CUES)
text("vtt", vtt); text("webvtt", vtt)
text("sbv", "".join(f"{a[1:]}.{b},{c[1:]}.{d}\n{t}\n\n" for a, b, c, d, t in CUES))
text("sub", "".join(f"{{{i*40}}}{{{i*40+35}}}{t}\n" for i, (*_, t) in enumerate(CUES)))
text("ttml", '<?xml version="1.0" encoding="UTF-8"?>\n<tt xmlns="http://www.w3.org/ns/ttml"><body><div>' + "".join(f'<p begin="{a}.{b}" end="{c}.{d}">{t}</p>' for a, b, c, d, t in CUES) + "</div></body></tt>\n")
text("itt", open(out("ttml")).read())
text("scc", "Scenarist_SCC V1.0\n\n00:00:00:00\t9420 9420 94ae 94ae 9452 9452 c8e5 e1e4 e96e e7c1 ecf0 68e1 942f 942f\n\n00:00:01:15\t942c 942c\n\n")
text("m3u", "#EXTM3U\n#EXTINF:3,Tone\nsample.mp3\n"); text("pls", "[playlist]\nFile1=sample.mp3\nTitle1=Tone\nLength1=3\nNumberOfEntries=1\nVersion=2\n")

# ---- documents
md = "# HeadingAlpha\n\nA paragraph with **BoldBravo** and a [link](https://example.com).\n\n| Name | City |\n|---|---|\n| Ada | CellMike |\n\n- ItemOne\n- ItemTwo\n\nPerché così: èàü.\n"
text("md", md)
attempt("txt", "pandoc", ["pandoc", out("md"), "-t", "plain", "-o", out("txt")])
for ext in "html rtf docx odt epub rst tex org ipynb fb2 textile adoc pptx typ opml".split(): attempt(ext, "pandoc", ["pandoc", out("md"), "-s", "-o", out(ext)])
attempt("pdf", "cupsfilter", lambda: open(out("pdf"), "wb").write(subprocess.run(["cupsfilter", "-m", "application/pdf", out("txt")], capture_output=True).stdout))
for ext in ("doc", "rtfd", "webarchive", "wordml"): attempt(ext, "textutil", ["textutil", "-convert", ext, out("docx"), "-output", out(ext)])

# ---- data
rows = [{"id": 1, "name": "Ada", "city": "London", "admin": True}, {"id": 2, "name": "Grace", "city": "New York", "admin": False}]
json.dump(rows, open(out("json"), "w")); made["json"] = "python"
for ext, sep in (("csv", ","), ("tsv", "\t")):
    with open(out(ext), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]), delimiter=sep); w.writeheader(); w.writerows(rows)
    made[ext] = "python"
with open(out("plist"), "wb") as f: plistlib.dump(rows, f)
made["plist"] = "python"
text("toml", 'title = "Forge"\ncount = 2\n\n[owner]\nname = "Ada"\ncity = "London"\n')
text("yaml", "".join(f"- id: {r['id']}\n  name: {r['name']}\n  city: {r['city']}\n" for r in rows))
text("xml", "<?xml version=\"1.0\"?>\n<rows>" + "".join(f"<row><id>{r['id']}</id><name>{r['name']}</name></row>" for r in rows) + "</rows>\n")

# ---- 3D: a unit tetrahedron, in each text format; the binary ones through Apple's usdcat
V = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)]; F3 = [(0, 2, 1), (0, 1, 3), (0, 3, 2), (1, 2, 3)]
text("obj", "".join(f"v {x} {y} {z}\n" for x, y, z in V) + "".join(f"f {a+1} {b+1} {c+1}\n" for a, b, c in F3))
text("stl", "solid t\n" + "".join("facet normal 0 0 0\n outer loop\n" + "".join(f"  vertex {V[i][0]} {V[i][1]} {V[i][2]}\n" for i in f) + " endloop\nendfacet\n" for f in F3) + "endsolid t\n")
text("ply", f"ply\nformat ascii 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\nelement face 4\nproperty list uchar int vertex_indices\nend_header\n" + "".join(f"{x} {y} {z}\n" for x, y, z in V) + "".join(f"3 {a} {b} {c}\n" for a, b, c in F3))
text("usda", '#usda 1.0\n(\n    defaultPrim = "T"\n    upAxis = "Y"\n)\ndef Mesh "T"\n{\n    int[] faceVertexCounts = [3, 3, 3, 3]\n    int[] faceVertexIndices = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]\n    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)]\n}\n')
attempt("usdc", "usdcat", ["usdcat", out("usda"), "-o", out("usdc")])
attempt("usd", "usdcat", ["usdcat", out("usda"), "-o", out("usd")])
attempt("usdz", "usdzip", ["usdzip", out("usdz"), out("usdc")])
missing["abc"] = "Alembic: no tool here writes it"

# ---- fonts
def first(*globs):
    import glob
    for g in globs:
        for p in sorted(glob.glob(g)): return p
ttf = first("/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Supplemental/*.ttf")
otf = first("/System/Library/Fonts/Supplemental/*.otf", "/Library/Fonts/*.otf", os.path.expanduser("~/Library/Fonts/*.otf"))
attempt("ttf", "a system font", lambda: ttf and shutil.copy(ttf, out("ttf")))
attempt("otf", "a system font, or fonttools", lambda: otf and shutil.copy(otf, out("otf")))
for flavor in ("woff", "woff2"):
    attempt(flavor, "fonttools", ["pyftsubset", out("ttf"), "--unicodes=U+0020-007E", f"--flavor={flavor}", f"--output-file={out(flavor)}"])

names = sorted(os.listdir(OUT))
print(f"{len(names)} files in {OUT}")
print("could not be made:")
for ext, why in sorted(missing.items()): print(f"  {ext:10} {why}")
