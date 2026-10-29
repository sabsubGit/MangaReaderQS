#!/usr/bin/env python3
"""Manga library and CBZ pages for the shell's reader (Manga.qml).

    manga.py library                  every series under ~/Manga, as JSON
    manga.py open FILE.cbz            unpack a chapter, list its pages
    manga.py progress FILE.cbz PAGE N remember the page (N = page count)
    manga.py setting KEY VALUE        reader settings (rtl, fit, sort)
    manga.py mark NAME read|unread    the whole series
    manga.py markch FILE read|unread [--before]   one chapter (and those before it)
    manga.py order NAME...            the library's custom order
    manga.py delete series NAME       to the Trash, and forget it (so it can be downloaded again)
    manga.py delete chapter FILE      to the Trash (updates will not bring it back)

  Downloads and updates (gallery-dl; these print as they go, for a terminal):
    manga.py get URL                  download a series and remember its URL
    manga.py check [NAME]             look for new chapters (lists only, downloads nothing)
    manga.py update [NAME]            download the new chapters check found
    manga.py source DIR               gallery-dl calls this per chapter (see its config)
    manga.py setsource NAME URL       remember a series' URL by hand
    manga.py setcover NAME PATH       use one of its covers ("" = back to the default)
    manga.py covers NAME URL          add every cover MangaDex has (URL: its MangaDex page)

  Background queue (what the reader and /manga <url> use):
    manga.py queue add URL...         queue series, start the worker if idle
    manga.py queue updates [NAME]     queue every series check found new chapters for
    manga.py queue status             what is downloading and waiting, as JSON
    manga.py queue cancel             empty the queue and stop the current download
    manga.py worker                   the worker (started by `queue add`)

Layout: ~/Manga/<Series>/<chapter>.cbz, which is what the gallery-dl config
in this repo writes. A .cbz lying directly in ~/Manga is a series of its own.

Cover art: an image in <Series>/covers/ (gallery-dl fetches MangaDex's) or a
<Series>/cover.jpg; otherwise the first page of the first chapter. For sites
gallery-dl has no cover download for (WeebCentral...), cover.jpg is taken once
from the series page's preview image (og:image), when the series gets a URL
or at its next update check.

Updates: a series' URL is kept in <Series>/.source. `check` asks the site
for the chapter list only (`gallery-dl -g`: one listing per series, no chapter
pages), compares it with the list from the last download, and records how
many are new. Series are checked one at a time with a pause in between.

Chapters are unpacked into ~/.cache/quickshell/manga/pages (the last few
only); covers are small JPEGs of a series' first page. Reading progress is in
~/.local/state/quickshell/manga.json.
"""
import contextlib
import fcntl
import signal
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

ROOT = os.path.expanduser(os.environ.get("MANGA_DIR", "~/Manga"))
CACHE = os.path.expanduser("~/.cache/quickshell/manga")
STATE = os.path.expanduser(os.environ.get("MANGA_STATE", "~/.local/state/quickshell/manga.json"))

# Separate libraries, each with its own folder and reading state:
#   manga.py --collection doujin library
# "manga" is the default; downloads, update checks and the queue are manga-only.
COLLECTION = "manga"
COLLECTIONS = {
    "manga": (ROOT, STATE),
    "doujin": (os.path.expanduser(os.environ.get("DOUJIN_DIR", "~/Doujin")),
               os.path.join(os.path.dirname(STATE), "doujin.json")),
}
IMAGES = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp")
KEEP_UNPACKED = 6
UA = "MangaReaderQS/1.0 (personal manga reader)"


def natural(s):
    """Sort key where "c2" comes before "c10"."""
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def key(path):
    """Cache name for a file; changes when the file does."""
    st = os.stat(path)
    return hashlib.md5("{}|{}|{}".format(path, st.st_size, int(st.st_mtime)).encode()).hexdigest()[:16]


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, STATE)


@contextlib.contextmanager
def changing_state():
    """Load, change, save -- under a lock, because the reader saves progress
    while a long update check runs in another process."""
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        yield state
        save_state(state)


ARCHIVES = (".cbz", ".cbr")


def is_archive(name):
    return name.lower().endswith(ARCHIVES)


def pages_in(zf):
    return page_names(zf.namelist())


def page_names(names):
    names = [n for n in names if n.lower().endswith(IMAGES) and not n.endswith("/")
             and "__MACOSX" not in n]
    return sorted(names, key=natural)


# Comic archives are normally zip (.cbz); some are RAR (.cbr -- or a RAR that
# was only named .cbz). Those go through bsdtar (libarchive), which reads RAR.

def _glob_escape(name):
    """bsdtar takes member names as patterns: [ ] * ? and backslash must be escaped."""
    return re.sub(r"([\[\]*?\\])", r"\\\1", name)


def archive_pages(path):
    """The page images in a comic archive, in reading order."""
    try:
        with zipfile.ZipFile(path) as zf:
            return pages_in(zf)
    except zipfile.BadZipFile:
        r = subprocess.run(["bsdtar", "-tf", path], capture_output=True, text=True)
        if r.returncode != 0:
            raise OSError(r.stderr.strip() or "not a comic archive")
        return page_names(r.stdout.splitlines())


def read_page(path, name):
    """One page's bytes."""
    try:
        with zipfile.ZipFile(path) as zf:
            return zf.read(name)
    except zipfile.BadZipFile:
        r = subprocess.run(["bsdtar", "-xOf", path, _glob_escape(name)], capture_output=True)
        if r.returncode != 0 or not r.stdout:
            raise OSError(r.stderr.decode(errors="replace").strip() or "could not read " + name)
        return r.stdout


def unpack_pages(path, tmp, out):
    """All pages into tmp as 0000.ext, 0001.ext... (paths under out)."""
    names = archive_pages(path)
    try:
        with zipfile.ZipFile(path) as zf:
            src = zf
            def get(n):
                return src.open(n)
            return _write_pages(names, get, tmp, out)
    except zipfile.BadZipFile:
        # RAR: unpack everything once with bsdtar into a scratch folder (it
        # refuses paths that would leave it), then number the pages.
        raw = tmp + ".raw"
        shutil.rmtree(raw, ignore_errors=True)
        os.makedirs(raw)
        try:
            r = subprocess.run(["bsdtar", "-xf", path, "-C", raw], capture_output=True, text=True)
            if r.returncode != 0:
                raise OSError(r.stderr.strip() or "could not unpack")
            return _write_pages(names, lambda n: open(os.path.join(raw, n), "rb"), tmp, out)
        finally:
            shutil.rmtree(raw, ignore_errors=True)


def _write_pages(names, get, tmp, out):
    pages = []
    # Pages get plain numbered names: nothing inside the archive decides
    # where a file is written.
    for i, n in enumerate(names):
        dest = "{:04d}{}".format(i, os.path.splitext(n)[1].lower())
        with get(n) as src, open(os.path.join(tmp, dest), "wb") as dst:
            shutil.copyfileobj(src, dst)
        pages.append(os.path.join(out, dest))
    return pages


def all_covers(folder):
    """Every cover image a series has: its main cover.* first, then the
    per-volume ones gallery-dl saves in covers/ (MangaDex: "03_en.png")."""
    if folder == ROOT or not os.path.isdir(folder):
        return []
    found = sorted((os.path.join(folder, f) for f in os.listdir(folder)
                    if f.lower().startswith("cover.") and f.lower().endswith(IMAGES)), key=natural)
    d = os.path.join(folder, "covers")
    if os.path.isdir(d):
        found += [os.path.join(d, f) for f in sorted(os.listdir(d), key=cover_order)
                  if f.lower().endswith(IMAGES)]
    return found


def cover_order(name):
    """Volume order, a variant ("02.1") right after its volume ("02"), then
    language: 01_en, 01_ja, 02_en, 02_ja, 02.1_en..."""
    m = re.match(r"(\d+)(?:\.(\d+))?_(\w+)", name)
    return (int(m.group(1)), int(m.group(2) or 0), m.group(3)) if m else (1e9, 0, name)


def picked_cover(folder):
    """The cover chosen in the reader's cover viewer: <Series>/.cover holds its
    path relative to the folder. "" when none is chosen (or it is gone)."""
    try:
        with open(os.path.join(folder, ".cover"), encoding="utf-8") as f:
            rel = f.read().strip()
    except OSError:
        return ""
    path = os.path.normpath(os.path.join(folder, rel))
    return path if rel and path.startswith(folder + os.sep) and os.path.isfile(path) else ""


def cover_art(folder):
    """The series' cover: the one picked in the viewer, else the main
    cover.*, else the first volume cover."""
    if folder == ROOT:
        return ""
    picked = picked_cover(folder)
    if picked:
        return picked
    found = all_covers(folder)
    return found[0] if found else ""


def set_cover(name, path):
    """Pick a series' cover (one of its own images), or "" for the default."""
    folder = folder_of(name)
    if not folder:
        return {"ok": False, "error": "No series folder " + name}
    note = os.path.join(folder, ".cover")
    if not path:
        with contextlib.suppress(OSError):
            os.remove(note)
        return {"ok": True}
    path = os.path.normpath(path)
    if path not in all_covers(folder):
        return {"ok": False, "error": "Not one of this series' covers: " + path}
    with open(note, "w", encoding="utf-8") as f:
        f.write(os.path.relpath(path, folder) + "\n")
    return {"ok": True}


def work_title(name):
    """Split an archive-style name into a title and who made it:
      '110330 (C83) [Circle (Artist)] Title (Parody) [English] [Group]'
        -> ('Title (Parody)', 'Artist')
    Names that do not look like that come back as they are."""
    s = re.sub(r"^\d+\s+", "", name)                    # a gallery id
    s = re.sub(r"^(\([^)]*\)\s*)+", "", s)               # (C83) event
    by = ""
    m = re.match(r"\[([^\]]*)\]\s*", s)
    if m:
        inner = m.group(1)
        a = re.search(r"\(([^)]*)\)\s*$", inner)
        by = (a.group(1) if a else inner).strip()
        s = s[m.end():]
    s = re.sub(r"(\s*[\[{][^\]}]*[\]}])+\s*$", "", s)   # [English] [Group] {..}
    s = re.sub(r"\s{2,}", " · ", s.strip())                # "Japanese  English" titles
    return (s or name), by


def gdl_meta(d):
    """work_meta's fields from gallery-dl's info.json for a gallery (nhentai,
    hitomi...: tags, artist(s), group(s), parody, characters, language, date).
    Values may be a string or a list; tags may carry a "female:" / "male:" /
    "tag:" prefix."""
    def items(*keys):
        out = []
        for k in keys:
            v = d.get(k)
            for x in (v if isinstance(v, list) else [v] if v else []):
                if isinstance(x, dict):
                    x = x.get("name") or x.get("tag") or ""
                x = str(x).strip().lower()
                if x and x not in out:
                    out.append(x)
        return out
    tags = [t.split(":", 1)[1] if ":" in t and t.split(":", 1)[0] in ("female", "male", "tag", "misc", "other", "mixed")
            else t for t in items("tags")]
    date = str(d.get("date") or "")[:10]
    return {
        "date": date if re.fullmatch(r"\d{4}-\d\d-\d\d", date) else "",
        "writer": ", ".join(items("artist", "artists")),
        "circle": ", ".join(items("group", "groups")),
        "genre": str(d.get("type") or ""),
        "tags": tags,
        "parodies": items("parody", "parodies"),
        "characters": items("characters", "character"),
        # "language" is the word ("english"); "lang" a code, only as a fallback.
        "languages": [l for l in (items("language") or items("lang")) if l not in ("translated", "rewrite")],
    }


def work_meta(path):
    """What a work's ComicInfo.xml says (gallery-dl, nhentai and Mihon write
    one), plus what its file name says, cached per file:
      date "YYYY-MM-DD", writer, circle, genre, pages,
      tags / parodies / characters / languages (from "tag:x", "parody:x"...),
      uncensored (a tag, or the name).
    Only the doujin library asks for this."""
    out = os.path.join(CACHE, "meta", key(path) + ".json")
    try:
        with open(out, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    import xml.etree.ElementTree as ET
    meta = {"date": "", "writer": "", "circle": "", "genre": "", "pages": 0,
            "tags": [], "parodies": [], "characters": [], "languages": [], "uncensored": False}
    name = os.path.basename(path)
    try:
        names = archive_pages(path)
        meta["pages"] = len(names)
        x = None
        gdl = None
        with zipfile.ZipFile(path) as zf:
            info = next((n for n in zf.namelist() if n.lower().endswith("comicinfo.xml")), None)
            if info:
                x = ET.fromstring(zf.read(info))
            elif "info.json" in zf.namelist():           # /doujin downloads
                gdl = json.loads(zf.read("info.json"))
    except (OSError, zipfile.BadZipFile, ET.ParseError, ValueError):
        x = gdl = None
    if gdl:
        meta.update(gdl_meta(gdl))
    if x is not None:
        y, m, d = (x.findtext(k) or "" for k in ("Year", "Month", "Day"))
        if y.isdigit():
            meta["date"] = "{}-{:02d}-{:02d}".format(int(y), int(m) if m.isdigit() else 1,
                                                     int(d) if d.isdigit() else 1)
        meta["writer"] = (x.findtext("Writer") or "").strip()
        meta["circle"] = (x.findtext("Publisher") or "").strip()
        meta["genre"] = (x.findtext("Genre") or "").strip()
        groups = {"tag": "tags", "parody": "parodies", "character": "characters", "language": "languages"}
        for t in (x.findtext("Tags") or "").split(","):
            ns, _, v = t.strip().lower().partition(":")
            if v and ns in groups:
                meta[groups[ns]].append(v.strip())
    # "translated" / "rewrite" are not languages.
    meta["languages"] = [l for l in meta["languages"] if l not in ("translated", "rewrite")]
    if not meta["languages"]:
        m = re.findall(r"\[(english|japanese|chinese|korean|spanish|french|german|russian)\]", name, re.I)
        meta["languages"] = [l.lower() for l in m]
    meta["uncensored"] = ("uncensored" in meta["tags"] or "decensored" in meta["tags"]
                          or bool(re.search(r"(?i)uncensored|decensored", name)))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out + ".tmp", "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    os.replace(out + ".tmp", out)
    return meta


def cover_label(path):
    """'03_en.png' -> 'vol 3 · en', 'cover.jpg' -> 'main'."""
    stem = os.path.splitext(os.path.basename(path))[0]
    if stem.lower() == "cover":
        return "main"
    m = re.fullmatch(r"(\d+)(\.\d+)?_(\w+)", stem)            # 03_en, 02.1_ja (a variant)
    if m:
        vol = int(m.group(1))
        return ("vol " + str(vol) + (m.group(2) or "") if vol or m.group(2) else "no volume") + " · " + m.group(3)
    return stem


def cover(cbz, art=""):
    """A small JPEG of the cover art, or of the chapter's first page, made once."""
    src = art or cbz
    out = os.path.join(CACHE, "covers", key(src) + ".jpg")
    if os.path.exists(out):
        return out
    try:
        from PIL import Image
        if art:
            im = Image.open(art)
        else:
            import io
            names = archive_pages(cbz)
            if not names:
                return ""
            im = Image.open(io.BytesIO(read_page(cbz, names[0])))
            im.load()
        im.thumbnail((360, 520))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        im.convert("RGB").save(out + ".tmp", "JPEG", quality=85)
        os.replace(out + ".tmp", out)
        return out
    except Exception:
        return ""


def pretty(stem):
    """'c0012.5 Title [Group]' -> ('Chapter 12.5 · Title', 'Group')."""
    m = re.fullmatch(r"c(\d+)(\.\d+)?\s*(.*?)(?:\s*\[([^\]]*)\])?", stem)
    if not m:
        return stem, ""
    name = "Chapter {}{}".format(int(m.group(1)), m.group(2) or "")
    if m.group(3):
        name += " · " + m.group(3)
    return name, m.group(4) or ""


def page_count(cbz):
    try:
        return len(archive_pages(cbz))
    except OSError:
        return 0


def series_entries():
    """[(name, folder, [cbz files])] for everything under ROOT."""
    entries = []
    if os.path.isdir(ROOT):
        for name in sorted(os.listdir(ROOT), key=natural):
            p = os.path.join(ROOT, name)
            if name.startswith("."):
                continue
            if os.path.isdir(p):
                files = []
                for d, _, fs in os.walk(p):
                    files += [os.path.join(d, f) for f in fs if is_archive(f)]
                if files:
                    files.sort(key=lambda f: natural(os.path.relpath(f, p)))
                    entries.append((name, p, files))
            elif is_archive(name):
                entries.append((name[:-4], ROOT, [p]))
    return entries


def read_source(folder):
    try:
        with open(os.path.join(folder, ".source"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def library():
    state = load_state()
    progress = state.get("progress", {})
    updates = state.get("updates", {})
    # New chapters: the ones a series did not have when the library first saw
    # it, while unread. The first sight is the baseline, so old backlog never
    # counts; a chapter stops being new once read.
    baseline = state.get("baseline", {})
    first_seen = {}
    series = []
    for name, folder, files in series_entries():
        base = baseline.get(name)
        if base is None and COLLECTION == "manga":
            first_seen[name] = [os.path.basename(f) for f in files]
        base = set(base or [])
        chapters = []
        for f in files:
            pr = progress.get(f, {})
            stem = os.path.basename(f)[:-4]
            label, group = pretty(stem) if folder != ROOT else (name, "")
            chapters.append({
                "name": label,
                "group": group,
                "file": f,
                "page": pr.get("page", 0),
                "pages": pr.get("pages", 0),
                "done": pr.get("done", False),
                "read": pr.get("t", 0),
                "new": bool(base) and os.path.basename(f) not in base and not pr.get("done", False),
            })
        last = max(chapters, key=lambda c: c["read"])
        up = updates.get(name, {})
        meta = work_meta(files[0]) if COLLECTION == "doujin" and len(files) == 1 else None
        series.append({
            "name": name,
            "cover": cover(files[0], cover_art(folder)),
            "art": cover_art(folder),
            "covers": [{"path": c, "label": cover_label(c)} for c in all_covers(folder)],
            "chapters": chapters,
            "done": sum(1 for c in chapters if c["done"]),
            "read": last["read"],
            "resume": chapters.index(last) if last["read"] else -1,
            "title": work_title(name)[0],
            # Who made it: from "[Circle (Artist)]" in the name, else (a
            # /doujin download, named "<id> <title>") from its details.
            "by": work_title(name)[1] or (meta["writer"].title() if meta and meta["writer"] else ""),
            "meta": meta,
            "added": int(max(os.path.getmtime(f) for f in files)),
            "source": read_source(folder) if folder != ROOT else "",
            "updates": up.get("new", 0),
            "updateError": up.get("error", ""),
            "fresh": sum(1 for c in chapters if c["new"]),
        })
    if first_seen:
        with changing_state() as st:
            st.setdefault("baseline", {}).update(first_seen)
    settings = {"rtl": False, "fit": "page", "sort": "recent"}
    settings.update(state.get("settings", {}))
    return {"ok": True, "root": ROOT, "series": series, "settings": settings,
            "order": state.get("order", []), "checked": state.get("checked", 0)}


def open_chapter(cbz):
    if not os.path.isfile(cbz):
        return {"ok": False, "error": "File not found: " + cbz}
    out = os.path.join(CACHE, "pages", key(cbz))
    listing = os.path.join(out, ".pages.json")
    try:
        with open(listing, encoding="utf-8") as f:
            pages = json.load(f)
        os.utime(out)
    except (OSError, ValueError):
        try:
            tmp = out + ".tmp"
            shutil.rmtree(tmp, ignore_errors=True)
            os.makedirs(tmp)
            pages = unpack_pages(cbz, tmp, out)
            with open(os.path.join(tmp, ".pages.json"), "w", encoding="utf-8") as f:
                json.dump(pages, f)
            shutil.rmtree(out, ignore_errors=True)
            os.replace(tmp, out)
        except (OSError, zipfile.BadZipFile) as e:
            return {"ok": False, "error": "Could not open {}: {}".format(os.path.basename(cbz), e)}
        prune()
    pr = load_state().get("progress", {}).get(cbz, {})
    page = pr.get("page", 0)
    if pr.get("done") or page >= len(pages):
        page = 0
    return {"ok": True, "file": cbz, "pages": pages, "page": page}


def prune():
    base = os.path.join(CACHE, "pages")
    dirs = [os.path.join(base, d) for d in os.listdir(base) if not d.endswith(".tmp")]
    dirs.sort(key=os.path.getmtime, reverse=True)
    for d in dirs[KEEP_UNPACKED:]:
        shutil.rmtree(d, ignore_errors=True)


def progress(cbz, page, pages):
    with changing_state() as state:
        pr = state.setdefault("progress", {})
        old = pr.get(cbz, {})
        pr[cbz] = {"page": page, "pages": pages, "t": int(time.time()),
                   "done": old.get("done", False) or page >= pages - 1}
    return {"ok": True}


def setting(k, v):
    with changing_state() as state:
        s = state.setdefault("settings", {})
        s[k] = v == "1" if k == "rtl" else v
    return {"ok": True}


def set_read(files, read, state):
    pr = state.setdefault("progress", {})
    for f in files:
        if read:
            n = pr.get(f, {}).get("pages") or page_count(f)
            pr[f] = {"page": max(0, n - 1), "pages": n, "done": True,
                     "t": pr.get(f, {}).get("t", 0)}
        else:
            pr.pop(f, None)


def mark(name, read):
    for n, _, files in series_entries():
        if n == name:
            with changing_state() as state:
                set_read(files, read, state)
            return {"ok": True}
    return {"ok": False, "error": "No series " + name}


def mark_chapter(cbz, read, before):
    for _, _, files in series_entries():
        if cbz in files:
            with changing_state() as state:
                set_read(files[:files.index(cbz) + 1] if before else [cbz], read, state)
            return {"ok": True}
    return {"ok": False, "error": "No chapter " + cbz}


ARCHIVE = os.path.expanduser("~/.local/share/gallery-dl/archive.sqlite3")


def trash(path):
    """To the desktop Trash (recoverable), not deleted."""
    r = subprocess.run(["gio", "trash", path], capture_output=True, text=True)
    if r.returncode != 0:
        raise OSError((r.stderr.strip() or "gio trash failed") + ": " + path)


def gallery_sites():
    """gallery-dl's site (category) names."""
    try:
        from gallery_dl import extractor
        return {cls.category for cls in extractor._list_classes()}
    except Exception:
        return {"mangadex", "weebcentral"}


def forget_downloads(name, known_urls):
    """Drop a series from gallery-dl's download record, so downloading it again
    really downloads it. Entries are "<site><id>_<page>": MangaDex uses the
    chapter id (from the chapter URLs an update check saw), WeebCentral and
    most others "<series>_<chapter>"."""
    import sqlite3
    if not os.path.exists(ARCHIVE):
        return 0
    ids = {u.rstrip("/").rsplit("/", 1)[-1] for u in known_urls if "/chapter" in u}
    db = sqlite3.connect(ARCHIVE, timeout=30)
    try:
        n = 0
        for i in ids:
            n += db.execute("DELETE FROM archive WHERE instr(entry, ?) > 0", (i + "_",)).rowcount
        # "<site><series>_<chapter>_<page>": the series name right after a site name.
        # Only when what comes before is exactly a site name: "Mimi" must not
        # take "weebcentralMimi2_..." or "...XMimi_...".
        sites = gallery_sites()
        rows = db.execute("SELECT entry FROM archive WHERE instr(entry, ?) > 0", (name + "_",)).fetchall()
        for (entry,) in rows:
            if entry[:entry.index(name + "_")] in sites:
                n += db.execute("DELETE FROM archive WHERE entry = ?", (entry,)).rowcount
        db.commit()
        return n
    finally:
        db.close()


def delete_series(name):
    for n, folder, files in series_entries():
        if n != name:
            continue
        target = folder if folder != ROOT else files[0]
        state = load_state()
        known = state.get("known", {}).get(name, [])
        try:
            trash(target)
        except OSError as e:
            return {"ok": False, "error": str(e)}
        forgotten = forget_downloads(name, known)
        with changing_state() as state:
            pr = state.get("progress", {})
            for f in files:
                pr.pop(f, None)
            for k in ("known", "updates", "baseline"):
                state.get(k, {}).pop(name, None)
            if name in state.get("order", []):
                state["order"].remove(name)
        return {"ok": True, "forgotten": forgotten}
    return {"ok": False, "error": "No series " + name}


def delete_chapter(cbz):
    if not any(cbz in files for _, _, files in series_entries()):
        return {"ok": False, "error": "No chapter " + cbz}
    try:
        trash(cbz)
    except OSError as e:
        return {"ok": False, "error": str(e)}
    with changing_state() as state:
        state.get("progress", {}).pop(cbz, None)
    return {"ok": True}


def order(names):
    with changing_state() as state:
        state["order"] = names
    return {"ok": True}


# ── Downloads and updates ────────────────────────────────────────────────────

def say(*a):
    print(*a, flush=True)


def folder_of(name):
    for n, folder, _ in series_entries():
        if n == name and folder != ROOT:
            return folder
    return None


def own_cover(folder):
    return any(f.lower().startswith("cover.") and f.lower().endswith(IMAGES) for f in os.listdir(folder))


def mangadex_cover(folder, url):
    """MangaDex: the series' main cover (the one its page shows), from the API.
    gallery-dl's covers/ folder has every volume's, and the first of those is
    usually the oldest."""
    m = re.search(r"mangadex\.org/(?:title|manga)/([0-9a-f-]{36})", url)
    if not m:
        return False
    uuid = m.group(1)
    req = urllib.request.Request(
        "https://api.mangadex.org/manga/{}?includes[]=cover_art".format(uuid),
        headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)["data"]
    name = next((rel["attributes"]["fileName"] for rel in data["relationships"]
                 if rel["type"] == "cover_art" and rel.get("attributes")), None)
    if not name:
        return False
    img = "https://uploads.mangadex.org/covers/{}/{}.512.jpg".format(uuid, name)
    req = urllib.request.Request(img, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        blob = r.read(10_000_000)
    out = os.path.join(folder, "cover.jpg")
    with open(out + ".tmp", "wb") as f:
        f.write(blob)
    os.replace(out + ".tmp", out)
    say("Cover saved from " + img)
    return True


def mangadex_all_covers(folder, url):
    """Every cover MangaDex has for a series (each volume, each language,
    variants) into <Series>/covers/, named like gallery-dl's ("03_en.jpg",
    "02.1_ja.jpg" for a variant). For series whose chapters come from another
    site: MangaDex keeps covers even when its chapters were taken down.
    Files already there are skipped."""
    m = re.search(r"mangadex\.org/(?:title|manga)/([0-9a-f-]{36})", url)
    if not m:
        return {"ok": False, "error": "Not a MangaDex series URL"}
    uuid = m.group(1)
    found, offset = [], 0
    while True:
        q = "https://api.mangadex.org/cover?manga[]={}&limit=100&offset={}&order[volume]=asc".format(uuid, offset)
        with urllib.request.urlopen(urllib.request.Request(q, headers={"User-Agent": UA}), timeout=20) as r:
            d = json.load(r)
        found += d["data"]
        offset += len(d["data"])
        if not d["data"] or offset >= d.get("total", 0):
            break
    dest = os.path.join(folder, "covers")
    os.makedirs(dest, exist_ok=True)
    added = 0
    for c in found:
        a = c["attributes"]
        vol = a.get("volume") or "0"
        mv = re.fullmatch(r"(\d+)(\.\d+)?", vol)
        stem = "{:02d}{}".format(int(mv.group(1)), mv.group(2) or "") if mv else re.sub(r"\W", "_", vol)
        name = "{}_{}{}".format(stem, a.get("locale") or "xx", os.path.splitext(a["fileName"])[1].lower())
        out = os.path.join(dest, name)
        if os.path.exists(out):
            continue
        img = "https://uploads.mangadex.org/covers/{}/{}".format(uuid, a["fileName"])
        with urllib.request.urlopen(urllib.request.Request(img, headers={"User-Agent": UA}), timeout=60) as r:
            blob = r.read(30_000_000)
        with open(out + ".tmp", "wb") as f:
            f.write(blob)
        os.replace(out + ".tmp", out)
        added += 1
        time.sleep(0.3)
    return {"ok": True, "found": len(found), "added": added}


def add_covers(name, url):
    folder = folder_of(name)
    if not folder:
        return {"ok": False, "error": "No series folder " + name}
    try:
        return mangadex_all_covers(folder, url.strip())
    except Exception as e:
        return {"ok": False, "error": "{}: {}".format(type(e).__name__, e)}


def fetch_cover(folder, url):
    """cover.jpg for a series, once: MangaDex's main cover from its API, or for
    other sites the series page's og:image when the series has no art at all.
    Two requests at most (the page or API, the image)."""
    if not url or not folder or own_cover(folder):
        return
    if "mangadex.org" in url:
        try:
            mangadex_cover(folder, url)
        except Exception as e:
            say("No cover from MangaDex ({})".format(e))
        return
    if cover_art(folder):
        return
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as r:
            page = r.read(500000).decode("utf-8", "replace")
        m = (re.search(r'<meta[^>]+property=["\']og:image["\'][^>]*content=["\']([^"\']+)', page)
             or re.search(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]*property=["\']og:image["\']', page))
        if not m:
            return
        img = html.unescape(m.group(1))
        req = urllib.request.Request(img, headers={"User-Agent": UA, "Referer": url})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read(10_000_000)
        from PIL import Image
        import io
        im = Image.open(io.BytesIO(data))
        im.load()
        out = os.path.join(folder, "cover.jpg")
        im.convert("RGB").save(out + ".tmp", "JPEG", quality=92)
        os.replace(out + ".tmp", out)
        say("Cover saved from " + img)
    except Exception as e:
        say("No cover from the series page ({})".format(e))


def set_source(name, url):
    folder = folder_of(name)
    if not folder:
        return {"ok": False, "error": "No series folder " + name}
    with open(os.path.join(folder, ".source"), "w", encoding="utf-8") as f:
        f.write(url.strip() + "\n")
    with contextlib.redirect_stdout(sys.stderr):      # stdout is this command's JSON
        fetch_cover(folder, url.strip())
    return {"ok": True}


def hook_source(directory):
    """gallery-dl, per chapter folder: note the series URL that `get` passed
    on, in the series folder (the chapter folder's parent)."""
    url = os.environ.get("MANGA_URL", "")
    series = os.path.dirname(os.path.normpath(directory))
    if url and os.path.dirname(series) == os.path.normpath(ROOT) and read_source(series) != url:
        os.makedirs(series, exist_ok=True)      # gallery-dl makes it on the first page, after this
        with open(os.path.join(series, ".source"), "w", encoding="utf-8") as f:
            f.write(url + "\n")


_gdl = None


def _gallery_dl():
    """gallery-dl as a library, loaded once per process (with the user's
    config), and a job class that collects the chapter URLs a series page
    lists instead of printing them -- what `gallery-dl -g` does, without
    starting a new Python for every series. None if that is not possible."""
    global _gdl
    if _gdl is None:
        try:
            import logging
            from gallery_dl import config, job
            config.load()

            class Lister(job.UrlJob):
                def __init__(self, url, parent=None, depth=1):
                    self.found = parent.found if parent else []
                    job.UrlJob.__init__(self, url, parent, depth)

                def handle_url(self, url, _):
                    self.found.append(url)

                def handle_url_fallback(self, url, kwdict):
                    self.found.append(url)

            class Errors(logging.Handler):
                def __init__(self):
                    logging.Handler.__init__(self, logging.ERROR)
                    self.last = ""

                def emit(self, record):
                    self.last = "[{}][error] {}".format(record.name, record.getMessage())

            errors = Errors()
            logging.getLogger().addHandler(errors)
            _gdl = (Lister, errors)
        except Exception:
            _gdl = False
    return _gdl or None


def list_chapters(url):
    """The chapter URLs a series page lists, without visiting the chapters."""
    gdl = _gallery_dl()
    if gdl:
        Lister, errors = gdl
        errors.last = ""
        try:
            j = Lister(url)
            status = j.run()
        except Exception as e:
            return None, "{}: {}".format(type(e).__name__, e)
        urls = sorted({u for u in j.found if u.startswith("http")})
        if status and not urls:
            return None, errors.last or "gallery-dl could not list " + url
        return urls, ""
    try:
        r = subprocess.run(["gallery-dl", "-g", url], capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    urls = sorted({l.strip() for l in r.stdout.splitlines() if l.startswith("http")})
    if r.returncode != 0 and not urls:
        err = (r.stderr.strip().splitlines() or ["gallery-dl failed"])[-1]
        return None, err
    return urls, ""


def remember_chapters(name, url):
    urls, err = list_chapters(url)
    with changing_state() as state:
        if urls is not None:
            state.setdefault("known", {})[name] = urls
            state.setdefault("updates", {})[name] = {"new": 0, "t": int(time.time()), "error": ""}
        else:
            state.setdefault("updates", {}).setdefault(name, {})["error"] = err


def get(url, on_line=None, chapters=None):
    """Download (or catch up) a series. Returns (exit code, series name or "").
    on_line gets each line gallery-dl prints, and the process (to stop it).
    chapters: just these chapter URLs of the series (from an update check)
    instead of the whole series."""
    say("gallery-dl", url, "({} new chapters)".format(len(chapters)) if chapters else "")
    targets = list(chapters) if chapters else [url]
    # A series downloaded for the first time: none of it is "new".
    was_there = any(read_source(folder) == url for _, folder, _ in series_entries() if folder != ROOT)
    env = dict(os.environ, MANGA_URL=url)
    if on_line is None:
        code = subprocess.run(["gallery-dl"] + targets, env=env).returncode
    else:
        p = subprocess.Popen(["gallery-dl"] + targets, env=env, text=True, bufsize=1,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True)    # its own group, for cancel
        for line in p.stdout:
            say(line.rstrip("\n"))
            on_line(line, p)
        code = p.wait()
    for name, folder, files in series_entries():
        if folder != ROOT and read_source(folder) == url:
            remember_chapters(name, url)
            fetch_cover(folder, url)
            if not was_there:
                with changing_state() as state:
                    state.setdefault("baseline", {})[name] = [os.path.basename(f) for f in files]
            say("\n{}: done{}".format(name, "" if code == 0 else " (with errors, exit {})".format(code)))
            return code, name
    say("\nDone (exit {}).".format(code))
    return code, ""


def with_sources(only):
    out = []
    for name, folder, _ in series_entries():
        if folder != ROOT and (not only or name == only):
            url = read_source(folder)
            if url:
                out.append((name, url))
    return out


CHECK = os.path.join(os.path.dirname(STATE), "manga-check.json")


def check_progress(data):
    """How far a running check is, for the reader (None = finished)."""
    if data is None:
        with contextlib.suppress(OSError):
            os.remove(CHECK)
        return
    tmp = CHECK + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, CHECK)


def read_check_progress():
    try:
        with open(CHECK, encoding="utf-8") as f:
            data = json.load(f)
        os.kill(data["pid"], 0)         # a crashed check leaves its file behind
        return data
    except (OSError, ValueError, KeyError):
        return None


def check(only):
    os.makedirs(os.path.dirname(CHECK), exist_ok=True)
    lock = open(CHECK + ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return {"ok": False, "error": "A check is already running"}
    todo = with_sources(only)
    started = int(time.time())
    # One lane per site, side by side; within a lane one series at a time with
    # a pause, so each site sees the same pace as a single queue would give it.
    lanes = {}
    for name, url in todo:
        lanes.setdefault(url.split("/")[2] if "://" in url else "?", []).append((name, url))
    try:
        if len(lanes) <= 1:
            results = {}
            _check(todo, results, lambda i, name: check_progress(
                {"pid": os.getpid(), "i": i, "n": len(todo), "name": name, "started": started}))
        else:
            results = _check_lanes(lanes, len(todo), started)
    finally:
        check_progress(None)
    with changing_state() as state:
        state["checked"] = int(time.time())
    return {"ok": True, "checked": len(todo), "results": results}


def _check_lanes(lanes, total, started):
    """Run each site's lane as its own process (`check-lane`), and keep the
    combined progress up to date for the reader."""
    procs = []
    for host, items in lanes.items():
        lane_file = CHECK + "." + re.sub(r"[^\w.-]", "_", host)
        with open(lane_file + ".todo", "w", encoding="utf-8") as f:
            json.dump(items, f, ensure_ascii=False)
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--collection", COLLECTION,
                              "check-lane", lane_file], stdout=subprocess.PIPE, text=True)
        procs.append((p, lane_file))
    while any(p.poll() is None for p, _ in procs):
        done, names = 0, []
        for p, lane_file in procs:
            try:
                with open(lane_file, encoding="utf-8") as f:
                    st = json.load(f)
                done += st["i"]
                if p.poll() is None and st.get("name"):
                    names.append(st["name"])
            except (OSError, ValueError):
                pass
        check_progress({"pid": os.getpid(), "i": min(done, total - 1), "n": total,
                        "name": " · ".join(names), "started": started})
        time.sleep(0.5)
    results = {}
    for p, lane_file in procs:
        try:
            results.update(json.loads(p.stdout.read() or "{}").get("results", {}))
        except ValueError:
            pass
        for f in (lane_file, lane_file + ".todo"):
            with contextlib.suppress(OSError):
                os.remove(f)
    return results


def check_lane(lane_file):
    """One site's share of a check (started by check())."""
    with open(lane_file + ".todo", encoding="utf-8") as f:
        todo = [tuple(x) for x in json.load(f)]

    def progress(i, name):
        tmp = lane_file + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"i": i, "name": name}, f, ensure_ascii=False)
        os.replace(tmp, lane_file)

    results = {}
    _check(todo, results, progress)
    progress(len(todo), "")
    return {"ok": True, "results": results}


def _check(todo, results, progress):
    for i, (name, url) in enumerate(todo):
        progress(i, name)
        if i:
            time.sleep(1.5)         # one series at a time per site, gently
        urls, err = list_chapters(url)
        with contextlib.redirect_stdout(sys.stderr):
            fetch_cover(folder_of(name), url)
        with changing_state() as state:
            known = state.setdefault("known", {})
            up = state.setdefault("updates", {})
            if urls is None:
                up.setdefault(name, {})["error"] = err
                results[name] = {"new": up[name].get("new", 0), "error": err}
                continue
            if name not in known:   # first look: what is there now is the baseline
                known[name] = urls
            fresh = sorted(set(urls) - set(known[name]))
            new = len(fresh)
            # The new chapter URLs too: "Download new" fetches just these
            # instead of walking the whole series (Mimi: 1 chapter, not 251).
            up[name] = {"new": new, "urls": fresh, "t": int(time.time()), "error": ""}
            results[name] = {"new": new, "error": ""}


def update(only):
    state = load_state()
    todo = [(n, u) for n, u in with_sources(only)
            if only or state.get("updates", {}).get(n, {}).get("new", 0) > 0]
    if not todo:
        say("Nothing to download. Run a check first, or the series has no saved URL.")
    for i, (name, url) in enumerate(todo):
        say("\n== {} ({}/{})".format(name, i + 1, len(todo)))
        get(url)


# ── Background queue ─────────────────────────────────────────────────────────
# One worker downloads one series at a time; the queue and what the worker is
# doing are in manga-queue.json next to the state file, its output in
# manga-download.log. The reader shows both.

QUEUE = os.path.join(os.path.dirname(STATE), "manga-queue.json")
LOG = os.path.join(os.path.dirname(STATE), "manga-download.log")


@contextlib.contextmanager
def changing_queue():
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    with open(QUEUE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(QUEUE, encoding="utf-8") as f:
                q = json.load(f)
        except (OSError, ValueError):
            q = {}
        q.setdefault("items", [])
        q.setdefault("current", None)
        q.setdefault("finished", 0)
        yield q
        tmp = QUEUE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(q, f, ensure_ascii=False)
        os.replace(tmp, QUEUE)


def label_for(url):
    """A name to show before the series folder exists: the known series, or
    the readable part of the URL."""
    for name, url2 in with_sources(""):
        if url2 == url:
            return name
    parts = [p for p in url.split("?")[0].split("/") if p]
    slug = parts[-1] if parts else url
    return slug.replace("-", " ") if not re.fullmatch(r"[0-9a-fA-F-]{20,}", slug) else url


def worker_running():
    try:
        with open(QUEUE + ".worker", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
    except OSError:
        return True


def start_worker():
    if worker_running():
        return
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as log:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "worker"],
                         stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         start_new_session=True)


def queue_add(urls):
    """Queue downloads into the collection this was called for: manga series
    into ~/Manga, or (--collection doujin) galleries into the doujin library."""
    with changing_queue() as q:
        cur = (q["current"] or {}).get("url")
        for url in urls:
            url = url.strip()
            if url and url != cur and all(i["url"] != url for i in q["items"]):
                q["items"].append({"url": url, "added": int(time.time()), "collection": COLLECTION,
                                   "name": label_for(url) if COLLECTION == "manga" else slug_of(url)})
    start_worker()
    return queue_status()


def slug_of(url):
    parts = [p for p in url.split("?")[0].split("/") if p]
    return " ".join(parts[-2:]) if len(parts) > 2 else url


def get_doujin(url, on_line):
    """A gallery into the doujin library as one "<id> <title>.cbz", with its
    details as info.json inside (the filter panel reads it). The gallery-dl
    config has the two steps ("doujin-info", "doujin-cbz")."""
    root = COLLECTIONS["doujin"][0]
    say("gallery-dl (doujin)", url)
    p = subprocess.Popen(
        ["gallery-dl",
         "-o", "base-directory=" + root + "/",
         "-o", 'directory=["{gallery_id|id} {title}"]',
         "-o", 'postprocessors=["doujin-info", "doujin-cbz"]',
         url],
        text=True, bufsize=1, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        start_new_session=True)
    for line in p.stdout:
        say(line.rstrip("\n"))
        on_line(line, p)
    return p.wait()


def doujin_files():
    root = COLLECTIONS["doujin"][0]
    try:
        return {f for f in os.listdir(root) if is_archive(f)}
    except OSError:
        return set()


def queue_updates(only):
    """Queue what update checks found: just the new chapters of each series
    when the check listed them, else (an older check, or `only` asked for one
    series by hand) the whole series."""
    state = load_state()
    ups = state.get("updates", {})
    todo = [(n, u) for n, u in with_sources(only) if only or ups.get(n, {}).get("new", 0) > 0]
    with changing_queue() as q:
        cur = (q["current"] or {}).get("url")
        for name, url in todo:
            if url == cur or any(i["url"] == url for i in q["items"]):
                continue
            item = {"url": url, "name": name, "added": int(time.time())}
            fresh = ups.get(name, {}).get("urls") or []
            if ups.get(name, {}).get("new", 0) > 0 and fresh:
                item["chapters"] = fresh
            q["items"].append(item)
    start_worker()
    return queue_status()


def queue_status():
    with changing_queue() as q:
        out = dict(q)
    out["running"] = worker_running()
    out["check"] = read_check_progress()
    out["ok"] = True
    return out


def queue_cancel():
    with changing_queue() as q:
        q["items"] = []
        pid = (q["current"] or {}).get("pid")
        if pid:
            q["current"]["cancelled"] = True
    if pid:
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            pass
    return queue_status()


def notify(summary, body=""):
    try:
        subprocess.run(["notify-send", "-a", "Manga", "-i", "folder-download", summary, body],
                       timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def count_cbz():
    return {f for _, _, files in series_entries() for f in files}


def worker():
    lock = open(QUEUE + ".worker", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return                          # one is already running
    while True:
        with changing_queue() as q:
            if not q["items"]:
                q["current"] = None
                return
            item = q["items"].pop(0)
            q["current"] = dict(item, started=int(time.time()), files=0, chapter="")
        say("\n==== {}  {}".format(time.strftime("%Y-%m-%d %H:%M"), item["url"]))
        doujin = item.get("collection") == "doujin"
        before = doujin_files() if doujin else count_cbz()
        seen = {"files": 0, "written": 0.0, "pid": False}

        def on_line(line, proc, item=item):
            # gallery-dl prints each file it saves; "# " marks skipped ones.
            line = line.strip()
            # "/path" = a page saved, "# /path" = one already there (skipped).
            skipped = line.startswith("# /")
            saved = line.startswith("/")
            if skipped:
                line = line[2:]
            if saved:
                seen["files"] += 1
            saved = saved or skipped
            # Status at most once a second (and at once, so cancel has the pid).
            if seen["pid"] and (not saved or time.time() - seen["written"] < 1):
                return
            seen["pid"] = True
            seen["written"] = time.time()
            with changing_queue() as q:
                cur = q["current"]
                if not cur or cur["url"] != item["url"]:
                    return
                cur["pid"] = proc.pid
                cur["files"] = seen["files"]
                if saved and doujin:          # <doujin dir>/<id> <title>/page
                    cur["name"] = work_title(os.path.basename(os.path.dirname(line)))[0]
                    cur["chapter"] = "{} pages".format(seen["files"]) if seen["files"] else ""
                elif saved:
                    cur["chapter"] = os.path.basename(os.path.dirname(line))
                    cur["name"] = os.path.basename(os.path.dirname(os.path.dirname(line))) or cur["name"]

        if doujin:
            code = get_doujin(item["url"], on_line)
            added = sorted(doujin_files() - before)
            with changing_queue() as q:
                cancelled = (q["current"] or {}).get("cancelled")
                q["current"] = None
                q["finished"] += 1
            if cancelled:
                notify("Doujin download stopped", item["name"])
            elif added:
                notify("Saved to the doujin library", "\n".join(work_title(f[:-4])[0] for f in added))
            elif code == 0:
                notify("Doujin already in the library", item["name"])
            else:
                notify("Doujin download problem", "gallery-dl exit {}. Details: {}".format(
                    code, LOG.replace(os.path.expanduser("~"), "~")))
            continue
        code, name = get(item["url"], on_line, item.get("chapters"))
        new = len(count_cbz() - before)
        with changing_queue() as q:
            cancelled = (q["current"] or {}).get("cancelled")
            q["current"] = None
            q["finished"] += 1
        name = name or item["name"]
        if cancelled:
            notify("Manga download stopped", name)
        elif code == 0:
            notify("Downloaded " + name,
                   "{} new chapter{}".format(new, "" if new == 1 else "s") if new else "Already up to date")
        else:
            notify("Download problem: " + name,
                   "{} new chapter{}, gallery-dl exit {}. Details: {}".format(
                       new, "" if new == 1 else "s", code, LOG.replace(os.path.expanduser("~"), "~")))


def main():
    global ROOT, STATE, COLLECTION
    a = sys.argv[1:]
    if a[:1] == ["--collection"] and len(a) > 1:
        if a[1] not in COLLECTIONS:
            print(json.dumps({"ok": False, "error": "No collection " + a[1]}))
            return
        ROOT, STATE = COLLECTIONS[a[1]]
        COLLECTION = a[1]
        a = a[2:]
    os.makedirs(CACHE, exist_ok=True)
    if a == ["library"]:
        out = library()
    elif len(a) == 2 and a[0] == "open":
        out = open_chapter(a[1])
    elif len(a) == 4 and a[0] == "progress":
        out = progress(a[1], int(a[2]), int(a[3]))
    elif len(a) == 3 and a[0] == "setting" and a[1] in ("rtl", "fit", "sort"):
        out = setting(a[1], a[2])
    elif len(a) == 3 and a[0] == "mark" and a[2] in ("read", "unread"):
        out = mark(a[1], a[2] == "read")
    elif len(a) in (3, 4) and a[0] == "markch" and a[2] in ("read", "unread"):
        out = mark_chapter(a[1], a[2] == "read", a[3:] == ["--before"])
    elif len(a) == 3 and a[:2] == ["delete", "series"]:
        out = delete_series(a[2])
    elif len(a) == 3 and a[:2] == ["delete", "chapter"]:
        out = delete_chapter(a[2])
    elif a[:1] == ["order"]:
        out = order(a[1:])
    elif len(a) == 3 and a[0] == "covers":
        out = add_covers(a[1], a[2])
    elif len(a) == 3 and a[0] == "setcover":
        out = set_cover(a[1], a[2])
    elif len(a) == 3 and a[0] == "setsource":
        out = set_source(a[1], a[2])
    elif len(a) == 2 and a[0] == "check-lane":
        out = check_lane(a[1])
    elif len(a) in (1, 2) and a[0] == "check":
        out = check(a[1] if len(a) == 2 else "")
    # The rest print as they go and end there.
    elif len(a) == 2 and a[0] == "source":
        return hook_source(a[1])
    elif len(a) == 2 and a[0] == "get":
        return get(a[1])
    elif len(a) in (1, 2) and a[0] == "update":
        return update(a[1] if len(a) == 2 else "")
    elif len(a) >= 3 and a[:2] == ["queue", "add"]:
        out = queue_add(a[2:])
    elif len(a) in (2, 3) and a[:2] == ["queue", "updates"]:
        out = queue_updates(a[2] if len(a) == 3 else "")
    elif a == ["queue", "status"]:
        out = queue_status()
    elif a == ["queue", "cancel"]:
        out = queue_cancel()
    elif a == ["worker"]:
        return worker()
    else:
        out = {"ok": False, "error": "usage: see the top of manga.py"}
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
