#!/bin/zsh
# Builds Splash-ai.mp4: per-shot AI stills behind the live film band.
set -e
cd "$(dirname "$0")"
python3 - <<'PY'
segs=[tuple(map(int,l.split())) for l in open('segs.txt') if l.strip()]
with open('stills.txt','w') as f:
    for i,(a,b) in enumerate(segs):
        f.write(f"file 'stills/{i:03d}.png'\nduration {(b-a)/60:.6f}\n")
    f.write(f"file 'stills/{len(segs)-1:03d}.png'\n")
PY
ffmpeg -loglevel error -y -i ~/Documents/venicesarin/Resources/Splash.mp4 -f concat -safe 0 -i stills.txt -loop 1 -framerate 60 -t 10.7834 -i mask.png -filter_complex "
[1:v]fps=60,scale=1320:2868,setsar=1,format=yuv444p[bg];
[0:v]crop=iw-16:ih-8:8:4,scale=1320:708:flags=lanczos,setsar=1,pad=1320:2868:0:1080,fillborders=top=1080:bottom=1080:mode=smear,format=yuv444p[a];
[2:v]format=gray,scale=1320:2868[m];
[a][bg][m]maskedmerge,noise=alls=2:allf=t,format=yuv420p10le[v]" -map "[v]" -t 10.7834 -an -c:v libx265 -crf 16 -preset medium -x265-params log-level=error -tag:v hvc1 -movflags +faststart Splash-ai.mp4
