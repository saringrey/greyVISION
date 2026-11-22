# Builds gv_splash_intro.wav and gv_splash_tail.wav from the glitch clip.
# Usage: ffmpeg -i glitch-sound-hd.mp3 -f f32le -ac 2 -ar 44100 raw.f32 && python3 make_bed.py
# The tail is a 15s granular, low-passed drone resynthesised from the dull
# rumble at 2.44-2.78s of the clip, so no repeat is audible; its end is
# crossfaded into its start so it loops with no seam.
import numpy as np, wave, sys
rng=np.random.default_rng(11)
sr=44100
x=np.fromfile('raw.f32',dtype='<f4').reshape(-1,2)
seg=x[int(2.44*sr):int(2.78*sr)]
G=int(0.22*sr); hop=G//6; T=int(16*sr)
win=np.hanning(G)[:,None]
out=np.zeros((T+G,2)); norm=np.zeros((T+G,1))
for p in range(0,T,hop):
    s=rng.integers(0,len(seg)-G)
    out[p:p+G]+=seg[s:s+G]*win; norm[p:p+G]+=win
D=out[:T]/np.maximum(norm[:T],1e-3)
F=np.fft.rfft(D,axis=0); fr=np.fft.rfftfreq(T,1/sr)
F*=(1/(1+(fr/900)**4))[:,None]
D=np.fft.irfft(F,n=T,axis=0)
# slow AGC: divide by 0.6s smoothed envelope
k=int(0.6*sr); env=np.sqrt(np.convolve((D**2).mean(1),np.ones(k)/k,mode='same'))[:,None]
D=D/np.maximum(env,1e-4)
target=np.sqrt((seg**2).mean())*0.85; D*=target/np.sqrt((D**2).mean())
X=int(0.8*sr); Y=int(0.8*sr); N=T-X-int(0.4*sr)
L=D[X:X+N].copy(); t=np.linspace(0,1,Y)[:,None]
L[-Y:]=D[X+N-Y:X+N]*np.cos(t*np.pi/2)+D[X-Y:X]*np.sin(t*np.pi/2)
a=int(0.58*sr); b=int(2.62*sr); C=int(0.35*sr)
clip=x[a:b].copy(); fi=int(0.01*sr); clip[:fi]*=np.linspace(0,1,fi)[:,None]
head=D[:X].copy(); tc=np.linspace(0,1,C)[:,None]
intro=np.concatenate([clip[:-C],clip[-C:]*np.cos(tc*np.pi/2)+head[:C]*np.sin(tc*np.pi/2),head[C:]])
def w(name,arr):
    pcm=(np.clip(arr,-1,1)*32767).astype('<i2')
    with wave.open(name,'wb') as f:
        f.setnchannels(2); f.setsampwidth(2); f.setframerate(sr); f.writeframes(pcm.tobytes())
w('gv_splash_intro.wav',intro); w('gv_splash_tail.wav',L)
r=lambda s:20*np.log10(np.sqrt((s**2).mean()))
ww=int(0.25*sr); v=[r(L[i:i+ww]) for i in range(0,len(L)-ww,ww)]
print(len(intro)/sr,len(L)/sr,round(r(L),1),round(min(v),1),round(max(v),1),np.abs(L[-1]-L[0]).max(),np.abs(L).max())
