"""Outpaint one still per splash shot with SDXL inpainting on the Apple GPU.

For each segment in segs.txt (frame ranges at 60 fps) the middle frame is
placed full-width in the centre of a portrait canvas, the margins are
pre-filled with a blurred edge smear as a starting point, and SDXL paints the
top and bottom. Output: stills/NNN.png at 1320x2868.
"""
import os
import subprocess
import sys
import time

import numpy as np
import torch
from diffusers import AutoPipelineForInpainting
from PIL import Image, ImageFilter

SRC = os.path.expanduser("~/Documents/venicesarin/Resources/Splash.mp4")
OUT = "stills"
W, H = 768, 1664          # SDXL canvas, same aspect as 1320x2868
FW, FH = 768, 411         # the shot, full width
TOP = (H - FH) // 2
os.makedirs(OUT, exist_ok=True)
os.makedirs("keys", exist_ok=True)

segs = [tuple(map(int, l.split())) for l in open("segs.txt") if l.strip()]
only = set(map(int, sys.argv[1:])) if len(sys.argv) > 1 else None

pipe = AutoPipelineForInpainting.from_pretrained(
    "diffusers/stable-diffusion-xl-1.0-inpainting-0.1",
    torch_dtype=torch.float16, variant="fp16",
).to("mps")
pipe.set_progress_bar_config(disable=True)

PROMPT = ("seamless continuation of the same photograph above and below, "
          "surreal still life, studio photography, soft natural light, "
          "clean backdrop, high detail, sharp, 8k")
NEG = "text, letters, watermark, border, frame, split screen, collage, people, face, blurry, lowres, artifacts"

for i, (a, b) in enumerate(segs):
    if only is not None and i not in only:
        continue
    dst = f"{OUT}/{i:03d}.png"
    if os.path.exists(dst):
        continue
    t0 = time.time()
    mid = (a + b) // 2
    key = f"keys/{i:03d}.png"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", SRC, "-vf",
                    f"select=eq(n\\,{mid}),crop=iw-16:ih-8:8:4", "-frames:v", "1", key], check=True)
    shot = Image.open(key).convert("RGB").resize((FW, FH), Image.LANCZOS)

    # Starting canvas: the edge rows smeared outward and blurred.
    arr = np.array(shot)
    canvas = np.zeros((H, W, 3), np.uint8)
    canvas[TOP:TOP + FH] = arr
    canvas[:TOP] = arr[0]
    canvas[TOP + FH:] = arr[-1]
    init = Image.fromarray(canvas).filter(ImageFilter.GaussianBlur(24))
    init.paste(shot, (0, TOP))

    # Paint everything outside the shot, with a small overlap into it.
    overlap = 10
    mask = np.full((H, W), 255, np.uint8)
    mask[TOP + overlap:TOP + FH - overlap] = 0
    mask_img = Image.fromarray(mask).filter(ImageFilter.GaussianBlur(6))

    gen = torch.Generator("mps").manual_seed(1000 + i)
    out = pipe(prompt=PROMPT, negative_prompt=NEG, image=init, mask_image=mask_img,
               width=W, height=H, num_inference_steps=26, guidance_scale=6.5,
               strength=0.99, generator=gen).images[0]
    out = out.resize((1320, 2868), Image.LANCZOS)
    out.save(dst)
    print(f"{i:03d} frames {a}-{b} {time.time() - t0:.1f}s", flush=True)
