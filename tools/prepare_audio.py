"""Authoring only: prepare attributed audio assets, with reproducible edits.

Requires numpy, scipy, soundfile and py7zr (installed into .work/audio/python).
The game only uses the resulting WAV/OGG files; no Python runtime is needed.
"""
from pathlib import Path
import hashlib
import html
import json
import re
import shutil
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".work/audio"
sys.path.insert(0, str(WORK / "python"))
import numpy as np
import soundfile as sf
import py7zr
from scipy.signal import butter, sosfilt, resample_poly
from math import gcd

ASSETS = ROOT / "assets/audio"
SOURCES = {
    "fantozzi": ("Fantozzi; sliced by qubodup", "CC0-1.0", "https://opengameart.org/content/fantozzis-footsteps-grasssand-stone"),
    "rubberduck": ("rubberduck", "CC0-1.0", "https://opengameart.org/content/100-cc0-sfx-2"),
    "kenney": ("Kenney", "CC0-1.0", "https://kenney.nl/assets/rpg-audio"),
    "birds": ("isaiah658", "CC0-1.0", "https://opengameart.org/content/ambient-bird-sounds"),
    "crickets": ("dklon", "CC-BY-3.0", "https://opengameart.org/content/crickets"),
    "exploration": ("Kilua Boy", "CC0-1.0", "https://opengameart.org/content/sunset-walk-ambient-quiet-sweet-loop"),
    "village": ("bobjt", "CC0-1.0", "https://opengameart.org/content/peacefull-ville"),
}
records = []

def fetch(url, filename):
    path = WORK / "originals" / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        request = urllib.request.Request(url, headers={"User-Agent": "MosslightRPG asset preparation"})
        with urllib.request.urlopen(request, timeout=45) as response:
            path.write_bytes(response.read())
    return path

def link_from_page(source, filename_prefix, suffix):
    page = fetch(SOURCES[source][2], source + ".html").read_text(encoding="utf-8")
    links = [html.unescape(x) for x in re.findall(r'href="([^"]+)"', page)]
    return next(x for x in links if "/sites/default/files/" in x and x.rsplit("/", 1)[-1].startswith(filename_prefix) and x.endswith(suffix))

def read(path, mono=False):
    data, rate = sf.read(path, always_2d=True, dtype="float32")
    if mono:
        data = data.mean(axis=1, keepdims=True)
    if rate != 44100:
        divisor = gcd(rate, 44100)
        data = resample_poly(data, 44100 // divisor, rate // divisor, axis=0)
    return data, 44100

def write(data, source_path, source, relative, edits):
    target = ASSETS / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    with sf.SoundFile(target, mode="w", samplerate=44100, channels=data.shape[1],
                      subtype="VORBIS" if target.suffix==".ogg" else "PCM_16") as stream:
        # Bounded writes avoid libsndfile's large-block Vorbis stack allocation.
        for start in range(0,len(data),16384): stream.write(data[start:start+16384])
    decoded, _ = sf.read(target, always_2d=True)
    record = {"file":relative,"source":source,"original":source_path.name,
              "original_sha256":hashlib.sha256(source_path.read_bytes()).hexdigest(),
              "sha256":hashlib.sha256(target.read_bytes()).hexdigest(),
              "seconds":round(len(decoded)/44100,4),"channels":decoded.shape[1],
              "peak":round(float(np.max(np.abs(decoded))),5),
              "rms_db":round(float(20*np.log10(max(1e-9,np.sqrt(np.mean(decoded**2))))),2),"edits":edits}
    assert record["peak"] < .98 and record["peak"] > .001, record
    records.append(record)
    print(relative, record["seconds"], record["rms_db"], "dB RMS", flush=True)

def step(path, source, relative, highpass=75, rms=.065):
    data, rate = read(path, True)
    data = sosfilt(butter(2, highpass, fs=rate, btype="highpass", output="sos"), data, axis=0)
    envelope = np.max(np.abs(data), axis=1)
    active = np.flatnonzero(envelope > max(.0005, float(envelope.max())*.012))
    if len(active):
        data = data[max(0,active[0]-220):min(len(data),active[-1]+1200)]
    data -= data.mean(axis=0)
    data *= min(.68/max(1e-8,float(np.max(np.abs(data)))), rms/max(1e-8,float(np.sqrt(np.mean(data**2)))))
    fade = min(132,len(data)//4)
    data[:fade] *= np.linspace(0,1,fade)[:,None]
    tail = min(880,len(data)//4)
    data[-tail:] *= np.linspace(1,0,tail)[:,None]
    write(data,path,source,relative,"mono 44.1 kHz; high-pass; silence trim; RMS/peak gain; 3 ms attack and 20 ms tail fade")

def loop(path, source, relative, seconds=None, rms=.12, crossfade=.8, highpass=50):
    data, rate = read(path)
    if seconds: data = data[:int(seconds*rate)]
    data = sosfilt(butter(2,highpass,fs=rate,btype="highpass",output="sos"),data,axis=0)
    # Wrap the tail over the start. The resulting end follows immediately into
    # the crossfaded head, without a silent gap or discontinuous sample jump.
    n = min(int(crossfade*rate), len(data)//8)
    t = np.linspace(0,1,n)[:,None]
    head = data[-n:]*(1-t) + data[:n]*t
    data = np.concatenate([head,data[n:-n]])
    data -= data.mean(axis=0)
    data *= min(.70/max(1e-8,float(np.max(np.abs(data)))), rms/max(1e-8,float(np.sqrt(np.mean(data**2)))))
    write(data,path,source,relative,f"44.1 kHz; high-pass {highpass} Hz; {crossfade}s wrap crossfade; RMS/peak gain; OGG Vorbis")

def main():
    archive = fetch(link_from_page("fantozzi","Fantozzi-footsteps",".7z"),"Fantozzi-footsteps.7z")
    extracted = WORK / "fantozzi"
    if not extracted.exists():
        with py7zr.SevenZipFile(archive) as package: package.extractall(extracted)
    candidates = sorted(extracted.rglob("*.flac"))
    print("FANTOZZI",[x.name for x in candidates],flush=True)
    for kind, keyword in [("grass","sand"),("stone","stone")]:
        selected = [p for p in candidates if keyword in p.name.lower()]
        assert selected, (kind,candidates)
        for i,path in enumerate(selected): step(path,"fantozzi",f"footsteps/{kind}_{i+1:02}.wav")
    rubber = Path("F:/demo/crpg/SourceAssets/ThirdParty/Audio/rubberduck_100_cc0_sfx_2/original")
    if not rubber.exists():
        rubber = WORK / "rubberduck"
        archive = fetch("https://opengameart.org/sites/default/files/sfx_100_v2.zip", "sfx_100_v2.zip")
        if not rubber.exists():
            with zipfile.ZipFile(archive) as package: package.extractall(rubber)
    for kind,keyword in [("water","footstep_wet"),("wood","footstep_wood"),("dirt","footstep_0")]:
        for i,path in enumerate(sorted(rubber.rglob(f"*{keyword}*.ogg"))): step(path,"rubberduck",f"footsteps/{kind}_{i+1:02}.wav")
    loop(next(rubber.rglob("sfx100v2_loop_water_01.ogg")),"rubberduck","ambience/water.ogg",rms=.15,crossfade=.22,highpass=100)
    birds = fetch(link_from_page("birds","birds-isaiah658",".ogg"),"birds.ogg")
    loop(birds,"birds","ambience/birds.ogg",rms=.1,crossfade=1.2,highpass=200)
    crickets = fetch(link_from_page("crickets","crickets",".mp3"),"crickets.mp3")
    loop(crickets,"crickets","ambience/crickets.ogg",rms=.075,crossfade=1.0,highpass=400)
    for kind,prefix in [("exploration","SunsetWalk"),("village","peaceful_ville_2023")]:
        path=fetch(link_from_page(kind,prefix,".ogg"),kind+".ogg")
        loop(path,kind,"music/"+kind+".ogg",rms=.15,crossfade=.015,highpass=30)
    kenney = WORK / "kenney"
    if not kenney.exists():
        archive = fetch("https://kenney.nl/media/pages/assets/rpg-audio/8e99002d76-1677590336/kenney_rpg-audio.zip", "kenney_rpg-audio.zip")
        with zipfile.ZipFile(archive) as package: package.extractall(kenney)
    for name in ["cloth1","cloth2","cloth3","cloth4","knifeSlice","knifeSlice2"]:
        path=next(kenney.rglob(name+".ogg"))
        step(path,"kenney","effects/"+name+".wav",rms=.12)
    licenses = ASSETS/"licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copyfile(kenney/"License.txt", licenses/"Kenney.txt")
    (ASSETS/"manifest.json").write_text(json.dumps({"sources":{key:{"author":v[0],"license":v[1],"url":v[2]} for key,v in SOURCES.items()},"files":records},ensure_ascii=False,indent=2),encoding="utf-8")

if __name__=="__main__": main()
