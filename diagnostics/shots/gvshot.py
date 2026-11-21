#!/usr/bin/env python3
"""Turn a device screenshot into a previewable HTML page.

Usage: gvshot.py <png> [crop_top_fraction] [width] [out_html]

Crops to the region below `crop_top_fraction` of the image height, scales it
to `width`, and writes a self-contained HTML file with the image inlined so the
preview server never has to serve sibling assets. JPEG keeps the page light
enough for the preview webview to composite.
"""
import base64
import io
import pathlib
import sys

from PIL import Image

src = sys.argv[1]
fraction = float(sys.argv[2]) if len(sys.argv) > 2 else 0.55
width = int(sys.argv[3]) if len(sys.argv) > 3 else 760
out = sys.argv[4] if len(sys.argv) > 4 else "diagnostics/shots/view.html"

image = Image.open(src).convert("RGB")
top = int(image.height * fraction)
image = image.crop((0, top, image.width, image.height))
if image.width > width:
    scale = width / image.width
    image = image.resize((width, max(1, int(image.height * scale))), Image.LANCZOS)

buffer = io.BytesIO()
image.save(buffer, format="JPEG", quality=82, optimize=True)
payload = base64.b64encode(buffer.getvalue()).decode()
html = (
    '<!doctype html>\n<html><head><meta charset="utf-8"/><title>device shot</title>\n'
    '<style>html,body{margin:0;background:#101012}'
    'img{display:block;width:100%;height:auto}</style>\n'
    '</head><body><img src="data:image/jpeg;base64,' + payload + '" alt="shot"/></body></html>'
)
pathlib.Path(out).write_text(html)
print(out, image.size, len(html))
