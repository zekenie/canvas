#!/usr/bin/env python3
"""The app icon's tool: the artwork made into the .icns the app carries, and previews of an artwork as
macOS shows it.

`AppIcon.svg` is a full-bleed 1024x1024 artboard (viewBox 0 0 1024 1024), as Icon Composer takes one;
`AppIcon-small.svg` is the same picture redrawn for 16 points, 32 pixels on a Retina screen (no text
bars, a heavier string and pins). macOS 26 cuts its own shape out of an Icon Composer icon, but draws a plain .icns as it is, and
shrinks one whose shape isn't the system's onto a gray plate. So `compose` does to an artwork what the
system does to an Icon Composer one: scales it into the 824-point body of the 1024 canvas, clips it to the
body's shape (continuous corners, traced from Finder's and Notes' icons in macOS 26.6), and adds the
system's drop shadow and a faint glass rim (`data-rim="off"` on an artwork's root turns the rim off). The
app's .icns is made of that, so macOS shows it as drawn.

  icon.py build                                AppIcon.icns from AppIcon.svg and AppIcon-small.svg: run it
                                               after changing either, and commit all three (the app's
                                               build only copies the .icns)
  icon.py compose ART.svg [-o OUT.svg]         the icon as macOS draws it, as an SVG
  icon.py png ART.svg PIXELS -o OUT.png        that icon rendered at PIXELS (transparent)
  icon.py icns ART.svg [--small S.svg] -o OUT  an .icns of the composed icon, S's for 32 pixels
  icon.py stage ART.svg [-o OUT.png]           one artwork large, in a dark and a light Dock and in
                                               Command-Tab among this Mac's own icons, and small; by
                                               default to out/<stem>.stage.png beside it
  icon.py sheet ART.svg... -o OUT.png          artworks side by side: the Dock lineup, then a row each
  icon.py mask [-o OUT.svg]                    the shape and the guides on the 1024 artboard
  icon.py dock ART.svg... [--names N...]       a do-nothing app for each artwork, opened, so each sits in
                                               the real Dock and in Command-Tab (`icon.py dock --quit`)

Rendering is headless Google Chrome at 2x, so a CSS pixel is a point on a Retina display. A stage's
neighbors are this Mac's own app icons, drawn into context/ the first time one is needed (Apple's
artwork: never committed). A stage or sheet row is named from meta.json beside the artwork
({"name", "idea"}), else from its folder.
"""
import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONTEXT = os.path.join(ROOT, "context")
CACHE = os.path.join(ROOT, ".cache")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


# What swiftc runs with: SDKROOT out of it, since the system's python3 (an xcrun shim) sets SDKROOT to
# xcrun's own pick, which can be an SDK this swiftc rejects; the SDK goes by -sdk instead.
SWIFTC_ENV = {k: v for k, v in os.environ.items() if k != "SDKROOT"}


def sdk():
    """An SDK swiftc accepts: the first that type-checks of build.sh's own pick (build/.sdk), SDKROOT
    (which may be xcrun's, above), xcrun's and the installed ones, newest first."""
    picked = os.path.join(os.path.dirname(ROOT), "build", ".sdk")
    candidates = [open(picked).read().strip() if os.path.exists(picked) else "", os.environ.get("SDKROOT", ""),
                  subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()]
    tools = "/Library/Developer/CommandLineTools/SDKs"
    if os.path.isdir(tools):
        found = [os.path.join(tools, n) for n in os.listdir(tools) if re.match(r"MacOSX\d", n)]
        candidates += sorted(found, key=lambda p: [int(d) for d in re.findall(r"\d+", os.path.basename(p))], reverse=True)
    os.makedirs(CACHE, exist_ok=True)
    probe = os.path.join(CACHE, "probe.swift")
    with open(probe, "w") as f:
        f.write("let x = 1\n")
    for candidate in filter(None, candidates):
        if subprocess.run(["swiftc", "-sdk", candidate, "-typecheck", probe], capture_output=True, env=SWIFTC_ENV).returncode == 0:
            return candidate
    sys.exit("no installed SDK works with this swiftc; set SDKROOT")


def helper(name):
    """The Swift helper tools/<name>.swift, compiled into .cache the first time it's needed."""
    exe, source = os.path.join(CACHE, name), os.path.join(HERE, name + ".swift")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(source):
        os.makedirs(CACHE, exist_ok=True)
        if subprocess.run(["swiftc", "-sdk", sdk(), "-O", source, "-o", exe], env=SWIFTC_ENV).returncode != 0:
            sys.exit(f"swiftc couldn't build tools/{name}.swift")
    return exe

# The body: 824 points of the 1024 canvas, 100 in from each side, its corners continuous (the
# rounded rectangle iOS and macOS draw, radius 211, traced from Finder's and Notes' icons in macOS 26.6).
BODY_ORIGIN, BODY_SIZE, BODY_RADIUS = 100.0, 824.0, 211.0
# The shadow under it, fitted to the same icons: black, a quarter, 9 down, blurred 16.
SHADOW_DY, SHADOW_BLUR, SHADOW_OPACITY = 9, 16, 0.25

K = (1.52866483, 1.08849323, 0.86840689, 0.66993427, 0.06549600, 0.37761010, 0.16624661)


def squircle(x, y, w, h, r):
    """A rectangle with continuous corners of radius r, as an SVG path."""
    a, b, c, d, e, f, g = (k * r for k in K)
    R, B = x + w, y + h
    n = lambda v: f"{v:.2f}".rstrip("0").rstrip(".")
    p = lambda *xy: " ".join(f"{n(xy[i])},{n(xy[i + 1])}" for i in range(0, len(xy), 2))
    return (
        f"M{p(x + a, y)} L{p(R - a, y)} "
        f"C{p(R - b, y, R - c, y, R - d, y + e)} C{p(R - f, y + g, R - g, y + f, R - e, y + d)} C{p(R, y + c, R, y + b, R, y + a)} "
        f"L{p(R, B - a)} "
        f"C{p(R, B - b, R, B - c, R - e, B - d)} C{p(R - g, B - f, R - f, B - g, R - d, B - e)} C{p(R - c, B, R - b, B, R - a, B)} "
        f"L{p(x + a, B)} "
        f"C{p(x + b, B, x + c, B, x + d, B - e)} C{p(x + f, B - g, x + g, B - f, x + e, B - d)} C{p(x, B - c, x, B - b, x, B - a)} "
        f"L{p(x, y + a)} "
        f"C{p(x, y + b, x, y + c, x + e, y + d)} C{p(x + g, y + f, x + f, y + g, x + d, y + e)} C{p(x + c, y, x + b, y, x + a, y)} Z"
    )


BODY = squircle(BODY_ORIGIN, BODY_ORIGIN, BODY_SIZE, BODY_SIZE, BODY_RADIUS)
# The same shape on the full-bleed artboard.
ARTBOARD_RADIUS = BODY_RADIUS * 1024 / BODY_SIZE
MASK = squircle(0, 0, 1024, 1024, ARTBOARD_RADIUS)


def read_artwork(path):
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"<\?xml[^>]*\?>", "", text)
    text = re.sub(r"<!DOCTYPE[^>]*>", "", text, flags=re.S)
    m = re.search(r"<svg\b([^>]*)>", text, flags=re.S)
    if not m:
        sys.exit(f"{path}: no <svg> root")
    attrs = m.group(1)
    end = text.rfind("</svg>")
    inner = text[m.end():end]
    vb = re.search(r'viewBox\s*=\s*"([^"]*)"', attrs)
    viewbox = vb.group(1) if vb else "0 0 1024 1024"
    rim = not re.search(r'data-rim\s*=\s*"off"', attrs)
    return viewbox, inner, rim


def compose_svg(path):
    viewbox, inner, rim = read_artwork(path)
    o, s = BODY_ORIGIN, BODY_SIZE
    rim_layer = (
        '<use href="#__f_body" fill="none" stroke="url(#__f_rim)" stroke-width="8" filter="url(#__f_soft)"/>' if rim else ""
    )
    return f"""<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<path id="__f_body" d="{BODY}"/>
<clipPath id="__f_clip"><use href="#__f_body"/></clipPath>
<filter id="__f_shadow" x="-10%" y="-10%" width="120%" height="125%" color-interpolation-filters="sRGB">
<feGaussianBlur in="SourceAlpha" stdDeviation="{SHADOW_BLUR}"/><feOffset dy="{SHADOW_DY}"/>
<feComponentTransfer><feFuncA type="linear" slope="{SHADOW_OPACITY}"/></feComponentTransfer>
</filter>
<linearGradient id="__f_rim" x1="0" y1="{o}" x2="0" y2="{o + s}" gradientUnits="userSpaceOnUse">
<stop offset="0" stop-color="#fff" stop-opacity=".34"/><stop offset=".45" stop-color="#fff" stop-opacity=".1"/><stop offset="1" stop-color="#fff" stop-opacity=".18"/>
</linearGradient>
<filter id="__f_soft" x="-5%" y="-5%" width="110%" height="110%"><feGaussianBlur stdDeviation="1.5"/></filter>
</defs>
<use href="#__f_body" filter="url(#__f_shadow)"/>
<g clip-path="url(#__f_clip)">
<svg x="{o}" y="{o}" width="{s}" height="{s}" viewBox="{viewbox}" overflow="hidden">{inner}</svg>
{rim_layer}
</g>
</svg>
"""


def out_dir_for(art):
    d = os.path.join(os.path.dirname(os.path.abspath(art)), "out")
    os.makedirs(d, exist_ok=True)
    return d


def stem(art):
    return os.path.splitext(os.path.basename(art))[0]


def composed_path(art):
    """Writes the composed icon beside the artwork (out/<stem>.composed.svg) and returns its path."""
    out = os.path.join(out_dir_for(art), stem(art) + ".composed.svg")
    with open(out, "w", encoding="utf-8") as f:
        f.write(compose_svg(art))
    return out


def meta_for(art):
    d = os.path.dirname(os.path.abspath(art))
    name, idea = os.path.basename(d).replace("-", " ").title(), ""
    mp = os.path.join(d, "meta.json")
    if os.path.exists(mp):
        try:
            m = json.load(open(mp))
            name, idea = m.get("name", name), m.get("idea", "")
            # An alternate's own name and idea: {"alt": {"name", "idea"}} for alt.svg.
            if stem(art) in m:
                return m[stem(art)].get("name", f"{name} · {stem(art)}"), m[stem(art)].get("idea", idea)
        except Exception:
            pass
    if stem(art) != "icon":
        name = f"{name} · {stem(art)}"
    return name, idea


def shoot(page_html, png, width, height, scale=2, transparent=False):
    if not os.path.exists(CHROME):
        sys.exit(f"rendering takes Google Chrome, at {CHROME}")
    os.makedirs(CACHE, exist_ok=True)
    if os.path.exists(png):
        os.remove(png)
    work = tempfile.mkdtemp(prefix="shot-", dir=CACHE)
    try:
        page = os.path.join(work, "page.html")
        with open(page, "w", encoding="utf-8") as f:
            f.write(page_html)
        args = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                f"--force-device-scale-factor={scale}", f"--window-size={int(width)},{int(height)}",
                f"--user-data-dir={os.path.join(work, 'profile')}", f"--screenshot={os.path.abspath(png)}"]
        if transparent:
            args.append("--default-background-color=00000000")
        args.append("file://" + page)
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        if not os.path.exists(png):
            sys.exit("Chrome wrote no screenshot")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def url(path):
    return "file://" + os.path.abspath(path)


# A stage's neighbors: the apps of a Dock as it comes, and a few that run beside this one.
CONTEXT_APPS = {
    "finder": "/System/Library/CoreServices/Finder.app", "apps": "/System/Applications/Apps.app",
    "messages": "/System/Applications/Messages.app", "photos": "/System/Applications/Photos.app",
    "calendar": "/System/Applications/Calendar.app", "notes": "/System/Applications/Notes.app",
    "reminders": "/System/Applications/Reminders.app", "app-store": "/System/Applications/App Store.app",
    "system-settings": "/System/Applications/System Settings.app", "claude": "/Applications/Claude.app",
    "google-chrome": "/Applications/Google Chrome.app", "terminal": "/System/Applications/Utilities/Terminal.app",
}


def ctx(name):
    """One of this Mac's app icons as the system draws it (a generic one where the app isn't installed)."""
    png_path = os.path.join(CONTEXT, name + ".png")
    if not os.path.exists(png_path):
        os.makedirs(CONTEXT, exist_ok=True)
        subprocess.run([helper("iconpng"), CONTEXT_APPS[name], "256", png_path], check=True)
    return url(png_path)


FONT = '-apple-system, "SF Pro Text", "Helvetica Neue", sans-serif'
WALL_DARK = ("radial-gradient(120% 140% at 15% 0%, #3b3f7a 0%, rgba(59,63,122,0) 55%),"
             "radial-gradient(90% 120% at 90% 100%, #6a3554 0%, rgba(106,53,84,0) 60%),"
             "linear-gradient(160deg, #1d2140 0%, #141526 60%, #20142a 100%)")
WALL_LIGHT = ("radial-gradient(110% 130% at 10% 0%, #bfd7ff 0%, rgba(191,215,255,0) 60%),"
              "radial-gradient(90% 120% at 100% 100%, #ffd9c4 0%, rgba(255,217,196,0) 65%),"
              "linear-gradient(160deg, #dfe8f7 0%, #f3ecf3 60%, #f6e6dc 100%)")

BASE_CSS = f"""
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ background: #111113; color: #f5f5f7; font-family: {FONT}; -webkit-font-smoothing: antialiased; }}
.label {{ font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: rgba(235,235,245,.55); }}
.panel {{ position: relative; border-radius: 14px; overflow: hidden; }}
.panel > .label {{ position: absolute; left: 12px; top: 10px; z-index: 2; }}
.wall-dark {{ background: {WALL_DARK}; }}
.wall-light {{ background: {WALL_LIGHT}; }}
.wall-light > .label {{ color: rgba(0,0,0,.45); }}
.dock {{ position: absolute; left: 50%; bottom: 10px; transform: translateX(-50%); display: flex; align-items: flex-start;
        gap: 2px; padding: 5px 7px 11px; border-radius: 24px; }}
.dock.dark {{ background: rgba(38,38,44,.42); backdrop-filter: blur(24px) saturate(160%); border: 1px solid rgba(255,255,255,.13);
             box-shadow: inset 0 1px 0 rgba(255,255,255,.10), 0 8px 24px rgba(0,0,0,.35); }}
.dock.light {{ background: rgba(255,255,255,.38); backdrop-filter: blur(24px) saturate(160%); border: 1px solid rgba(255,255,255,.6);
              box-shadow: inset 0 1px 0 rgba(255,255,255,.5), 0 8px 24px rgba(0,0,0,.12); }}
.tile {{ position: relative; display: block; }}
.tile img {{ display: block; }}
.tile .run {{ position: absolute; left: 50%; bottom: -7px; width: 4px; height: 4px; margin-left: -2px; border-radius: 2px; }}
.dock.dark .run {{ background: rgba(255,255,255,.6); }}
.dock.light .run {{ background: rgba(0,0,0,.5); }}
.dock .sep {{ width: 1px; align-self: stretch; margin: 4px 5px 0; }}
.dock.dark .sep {{ background: rgba(255,255,255,.18); }}
.dock.light .sep {{ background: rgba(0,0,0,.15); }}
.switcher {{ position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); padding: 14px 14px 34px; border-radius: 30px;
            display: flex; gap: 4px; background: rgba(36,36,40,.5); backdrop-filter: blur(30px) saturate(160%);
            border: 1px solid rgba(255,255,255,.14); box-shadow: inset 0 1px 0 rgba(255,255,255,.1), 0 20px 50px rgba(0,0,0,.45); }}
.switcher .slot {{ position: relative; padding: 6px; border-radius: 20px; }}
.switcher .slot.on {{ background: rgba(255,255,255,.17); }}
.switcher .slot img {{ display: block; }}
.switcher .name {{ position: absolute; left: 0; right: 0; bottom: -26px; text-align: center; font-size: 13px; font-weight: 500;
                  color: rgba(255,255,255,.92); white-space: nowrap; }}
.canvas {{ background-color: #1c1c1c; background-image: radial-gradient(circle, rgba(255,255,255,.14) 1px, transparent 1.3px);
          background-size: 20px 20px; background-position: 10px 10px; }}
.sizes {{ display: flex; align-items: center; justify-content: center; gap: 22px; height: 100%; }}
.sizes figure {{ display: flex; flex-direction: column; align-items: center; gap: 6px; }}
.sizes figcaption {{ font-size: 10px; color: rgba(235,235,245,.5); }}
.light .sizes figcaption, .sizes.light figcaption {{ color: rgba(0,0,0,.45); }}
"""


def tile(src, size, running=False):
    run = '<i class="run"></i>' if running else ""
    return f'<span class="tile"><img src="{src}" width="{size}" height="{size}">{run}</span>'


def dock(icons, theme, size=48):
    """icons: list of (src, running) or 'sep'."""
    parts = []
    for i in icons:
        parts.append('<span class="sep"></span>' if i == "sep" else tile(i[0], size, i[1]))
    return f'<div class="dock {theme}">{"".join(parts)}</div>'


def switcher(srcs, selected, name, size=128):
    slots = []
    for i, s in enumerate(srcs):
        on = " on" if i == selected else ""
        label = f'<div class="name">{html.escape(name)}</div>' if i == selected else ""
        slots.append(f'<div class="slot{on}"><img src="{s}" width="{size}" height="{size}">{label}</div>')
    return f'<div class="switcher">{"".join(slots)}</div>'


def dock_row(ours):
    """A Dock like the owner's: Finder, the pinned apps, ours among them, then running apps past the divider."""
    left = [(ctx("finder"), True), (ctx("apps"), False), (ctx("messages"), True), (ctx("photos"), False), (ctx("calendar"), False),
            (ctx("notes"), True), (ours, True), (ctx("reminders"), False), (ctx("app-store"), False), (ctx("system-settings"), False)]
    right = [(ctx("claude"), True), (ctx("google-chrome"), True), (ctx("terminal"), True)]
    return left + ["sep"] + right


def sizes_html(src, theme):
    figs = "".join(
        f'<figure><img src="{src}" width="{s}" height="{s}"><figcaption>{s} pt</figcaption></figure>' for s in (64, 32, 16)
    )
    return f'<div class="sizes {theme}">{figs}</div>'


def stage(art, out):
    src = url(composed_path(art))
    name, idea = meta_for(art)
    W, H = 1400, 772
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
.head {{ position: absolute; left: 24px; top: 18px; right: 24px; display: flex; align-items: baseline; gap: 14px; }}
.head h1 {{ font-size: 20px; font-weight: 650; }}
.head p {{ font-size: 13px; color: rgba(235,235,245,.6); }}
.hero {{ position: absolute; left: 24px; top: 60px; width: 440px; height: 440px; }}
.hero img {{ position: absolute; left: 20px; top: 20px; }}
.small-light {{ position: absolute; left: 24px; top: 512px; width: 440px; height: 120px; background: #f6f6f6; }}
.small-dark {{ position: absolute; left: 24px; top: 640px; width: 440px; height: 120px; background: #1c1c1c; }}
.d1 {{ position: absolute; left: 480px; top: 60px; width: 896px; height: 150px; }}
.d2 {{ position: absolute; left: 480px; top: 222px; width: 896px; height: 150px; }}
.sw {{ position: absolute; left: 480px; top: 384px; width: 896px; height: 376px; }}
</style></head><body>
<div class="head"><h1>{html.escape(name)}</h1><p>{html.escape(idea)}</p></div>
<div class="panel canvas hero"><img src="{src}" width="400" height="400"></div>
<div class="panel small-light">{sizes_html(src, "light")}</div>
<div class="panel small-dark">{sizes_html(src, "dark")}</div>
<div class="panel wall-dark d1"><div class="label">Dock · dark</div>{dock(dock_row(src), "dark")}</div>
<div class="panel wall-light d2"><div class="label">Dock · light</div>{dock(dock_row(src), "light")}</div>
<div class="panel wall-dark sw"><div class="label">⌘-Tab</div>{switcher([ctx("finder"), ctx("claude"), ctx("google-chrome"), src, ctx("notes"), ctx("messages")], 3, "Infinite Canvas")}</div>
</body></html>"""
    shoot(page, out, W, H)


def strip_section(arts, title, top, W):
    """A row of related artworks (one idea in several colors, say): each large-ish, at 32 and 16 pt, and
    all of them in a dark Dock."""
    srcs = [url(composed_path(a)) for a in arts]
    cells = "".join(
        f'<figure><img src="{s}" width="150" height="150"><figcaption>{html.escape(meta_for(a)[0])}</figcaption>'
        f'<div class="tinyrow"><img src="{s}" width="32" height="32"><img src="{s}" width="16" height="16"></div></figure>'
        for a, s in zip(arts, srcs))
    css = f"""
.strip {{ position: absolute; left: 24px; top: {top}px; width: {W - 48}px; height: 268px; background: #1c1c1c; }}
.strip .cells {{ position: absolute; left: 12px; top: 34px; display: flex; gap: 14px; }}
.strip figure {{ display: flex; flex-direction: column; align-items: center; gap: 4px; width: 156px; }}
.strip figcaption {{ font-size: 12px; color: rgba(235,235,245,.75); }}
.strip .tinyrow {{ display: flex; gap: 14px; align-items: center; background: #f6f6f6; border-radius: 8px; padding: 5px 12px; }}
.strip .sdock {{ position: absolute; right: 10px; top: 10px; bottom: 10px; width: {max(360, 52 * len(arts) + 60)}px; border-radius: 12px; overflow: hidden; }}
"""
    body = (f'<div class="panel strip"><div class="label">{html.escape(title)}</div><div class="cells">{cells}</div>'
            f'<div class="sdock wall-dark">{dock([(s, True) for s in srcs], "dark")}</div></div>')
    return css, body, 268 + 14


def sheet(arts, out, title, strip=None, strip_title=""):
    srcs = [url(composed_path(a)) for a in arts]
    metas = [meta_for(a) for a in arts]
    n = len(arts)
    W = 1520
    row_h = 236
    # The lineups: every artwork in one Dock (dark and light) and in one Command-Tab, at true size.
    sw_size = min(128, int((W - 48 - 28) / max(n, 1)) - 16)
    top = 60 + 124 + 12 + sw_size + 120 + 24
    strip_css, strip_body = "", ""
    if strip:
        strip_css, strip_body, strip_h = strip_section(strip, strip_title, top, W)
        top += strip_h
    H = top + n * (row_h + 14) + 16
    numbers = "".join(f'<span style="width:50px;text-align:center">{i + 1}</span>' for i in range(n))
    rows = []
    for i, (s, (name, idea)) in enumerate(zip(srcs, metas)):
        y = top + i * (row_h + 14)
        mini_dock = dock([(ctx("finder"), True), (ctx("messages"), True), (ctx("notes"), True), (s, True),
                          (ctx("calendar"), False), "sep", (ctx("claude"), True)], "dark")
        tiny = lambda theme: (f'<div class="sizes {theme}"><figure><img src="{s}" width="32" height="32"><figcaption>32</figcaption></figure>'
                                  f'<figure><img src="{s}" width="16" height="16"><figcaption>16</figcaption></figure></div>')
        rows.append(f"""
<div class="row" style="top:{y}px">
  <div class="rname"><b>{i + 1}</b><h2>{html.escape(name)}</h2><p>{html.escape(idea)}</p></div>
  <div class="panel canvas hero"><img src="{s}" width="216" height="216"></div>
  <div class="panel wall-dark dk">{mini_dock}</div>
  <div class="panel wall-dark sw">{switcher([ctx("claude"), s, ctx("notes")], 1, "Infinite Canvas")}</div>
  <div class="panel tiny" style="background:#f6f6f6">{tiny("light")}</div>
  <div class="panel tiny2" style="background:#1c1c1c">{tiny("")}</div>
</div>""")
    x_dock = 212 + row_h + 12
    x_sw = x_dock + 360 + 12
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
.title {{ position: absolute; left: 24px; top: 18px; font-size: 22px; font-weight: 650; }}
.lineup {{ position: absolute; top: 60px; height: 124px; width: {(W - 48 - 12) // 2}px; }}
.lineup .nums {{ position: absolute; left: 50%; transform: translateX(-50%); top: 14px; display: flex; gap: 2px; font-size: 12px; font-weight: 600; color: rgba(255,255,255,.7); }}
.wall-light .nums {{ color: rgba(0,0,0,.55); }}
.lineup .dock {{ bottom: 14px; }}
.swl {{ position: absolute; left: 24px; top: 196px; width: {W - 48}px; height: {sw_size + 120}px; }}
.row {{ position: absolute; left: 24px; right: 24px; height: {row_h}px; }}
.rname {{ position: absolute; left: 0; top: 0; width: 196px; }}
.rname b {{ display: inline-block; font-size: 13px; color: rgba(235,235,245,.5); margin-bottom: 4px; }}
.rname h2 {{ font-size: 17px; font-weight: 650; line-height: 1.2; }}
.rname p {{ font-size: 12px; line-height: 1.4; color: rgba(235,235,245,.62); margin-top: 6px; }}
.row .hero {{ position: absolute; left: 212px; top: 0; width: {row_h}px; height: {row_h}px; }}
.row .hero img {{ position: absolute; left: 10px; top: 10px; }}
.row .dk {{ position: absolute; left: {x_dock}px; top: 0; width: 360px; height: {row_h}px; }}
.row .sw {{ position: absolute; left: {x_sw}px; top: 0; width: 480px; height: {row_h}px; }}
.row .tiny {{ position: absolute; right: 0; top: 0; width: 160px; height: {row_h // 2 - 4}px; }}
.row .tiny2 {{ position: absolute; right: 0; top: {row_h // 2 + 4}px; width: 160px; height: {row_h // 2 - 4}px; }}
{strip_css}
</style></head><body>
<div class="title">{html.escape(title)}</div>
<div class="panel wall-dark lineup" style="left:24px"><div class="nums">{numbers}</div>{dock([(s, True) for s in srcs], "dark")}</div>
<div class="panel wall-light lineup" style="left:{24 + (W - 48 - 12) // 2 + 12}px"><div class="nums">{numbers}</div>{dock([(s, True) for s in srcs], "light")}</div>
<div class="panel wall-dark swl"><div class="label">⌘-Tab</div>{switcher(srcs, 0, "Infinite Canvas", size=sw_size)}</div>
{strip_body}
{''.join(rows)}
</body></html>"""
    shoot(page, out, W, H)


def png(art, pixels, out):
    src = url(composed_path(art))
    page = f'<!doctype html><html><body style="margin:0;background:transparent"><img src="{src}" width="{pixels}" height="{pixels}" style="display:block"></body></html>'
    shoot(page, out, pixels, pixels, scale=1, transparent=True)



# The .icns's images, in points and scale. Not 16 and 32 at 1x: macOS 26 draws those (iconutil stores
# them in the old raw formats, ic04 and ic05) on its gray plate even when their shape is the system's,
# and without them scales the Retina ones down, unplated.
ICONSET = [(16, 2), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
# Nowhere under a hidden folder (this checkout is under .claude/): LaunchServices ignores apps there,
# and the Dock would show a blank icon. ICON_PREVIEW_APPS overrides it.
APPS = os.environ.get("ICON_PREVIEW_APPS") or os.path.join(tempfile.gettempdir(), "infinite-canvas-icon-previews")


def icns(art, out, small=None):
    os.makedirs(CACHE, exist_ok=True)
    work = tempfile.mkdtemp(prefix="iconset-", dir=CACHE)
    try:
        iconset = os.path.join(work, "AppIcon.iconset")
        os.makedirs(iconset)
        rendered = {}
        for points, scale in ICONSET:
            px = points * scale
            if px not in rendered:
                rendered[px] = os.path.join(work, f"{px}.png")
                png(small if small and px <= 32 else art, px, rendered[px])
            name = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
            shutil.copy(rendered[px], os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def make_app(art, name, slug):
    app = os.path.join(APPS, f"{slug}.app")
    shutil.rmtree(app, ignore_errors=True)
    os.makedirs(os.path.join(app, "Contents", "MacOS"))
    os.makedirs(os.path.join(app, "Contents", "Resources"))
    shutil.copy(helper("stub"), os.path.join(app, "Contents", "MacOS", "stub"))
    # An artwork's small version, if it has one beside it (AppIcon-small.svg for AppIcon.svg), as the app's build has.
    small = os.path.splitext(art)[0] + "-small.svg"
    icns(art, os.path.join(app, "Contents", "Resources", "AppIcon.icns"), small if os.path.exists(small) else None)
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>{html.escape(name)}</string>
<key>CFBundleDisplayName</key><string>{html.escape(name)}</string>
<key>CFBundleIdentifier</key><string>local.icon-preview.{slug}</string>
<key>CFBundleExecutable</key><string>stub</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>CFBundleVersion</key><string>{int(os.path.getmtime(art))}</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
"""
    with open(os.path.join(app, "Contents", "Info.plist"), "w") as f:
        f.write(plist)
    subprocess.run(["codesign", "--force", "--sign", "-", app], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return app


def quit_apps():
    subprocess.run(["pkill", "-f", os.path.join(APPS, "")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def mask_svg():
    c = 512
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<rect width="1024" height="1024" fill="#dcdce0"/>
<path d="{MASK}" fill="#fff" stroke="#0a84ff" stroke-width="3"/>
<circle cx="{c}" cy="{c}" r="400" fill="none" stroke="#ff375f" stroke-width="2" stroke-dasharray="10 8"/>
<rect x="160" y="160" width="704" height="704" fill="none" stroke="#30d158" stroke-width="2" stroke-dasharray="10 8"/>
<line x1="512" y1="0" x2="512" y2="1024" stroke="#8e8e93" stroke-width="1"/>
<line x1="0" y1="512" x2="1024" y2="512" stroke="#8e8e93" stroke-width="1"/>
</svg>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compose"); c.add_argument("art"); c.add_argument("-o")
    p = sub.add_parser("png"); p.add_argument("art"); p.add_argument("pixels", type=int); p.add_argument("-o", required=True)
    s = sub.add_parser("stage"); s.add_argument("art"); s.add_argument("-o")
    sh = sub.add_parser("sheet"); sh.add_argument("arts", nargs="+"); sh.add_argument("-o", required=True); sh.add_argument("--title", default="App icon directions")
    sh.add_argument("--strip", nargs="*", help="artworks shown together in one row above the others"); sh.add_argument("--strip-title", default="")
    m = sub.add_parser("mask"); m.add_argument("-o")
    i = sub.add_parser("icns"); i.add_argument("art"); i.add_argument("--small"); i.add_argument("-o", required=True)
    sub.add_parser("build")
    d = sub.add_parser("dock"); d.add_argument("arts", nargs="*"); d.add_argument("--names", nargs="*"); d.add_argument("--quit", action="store_true")
    d.add_argument("--no-open", action="store_true")
    a = ap.parse_args()
    if a.cmd == "compose":
        text = compose_svg(a.art)
        if a.o:
            open(a.o, "w").write(text)
        else:
            sys.stdout.write(text)
    elif a.cmd == "png":
        png(a.art, a.pixels, a.o)
    elif a.cmd == "stage":
        out = a.o or os.path.join(out_dir_for(a.art), stem(a.art) + ".stage.png")
        stage(a.art, out)
        print(out)
    elif a.cmd == "sheet":
        sheet(a.arts, a.o, a.title, a.strip, a.strip_title)
        print(a.o)
    elif a.cmd == "icns":
        icns(a.art, a.o, a.small)
    elif a.cmd == "build":
        out = os.path.join(ROOT, "AppIcon.icns")
        icns(os.path.join(ROOT, "AppIcon.svg"), out, os.path.join(ROOT, "AppIcon-small.svg"))
        print(out)
    elif a.cmd == "dock":
        quit_apps()
        if a.quit:
            return
        for k, art in enumerate(a.arts):
            name = a.names[k] if a.names and k < len(a.names) else f"{k + 1} {meta_for(art)[0]}"
            slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
            app = make_app(art, name, slug)
            print(app)
            if not a.no_open:
                subprocess.run(["open", "-g", app])
    elif a.cmd == "mask":
        text = mask_svg()
        if a.o:
            open(a.o, "w").write(text)
        else:
            sys.stdout.write(text)


if __name__ == "__main__":
    main()
