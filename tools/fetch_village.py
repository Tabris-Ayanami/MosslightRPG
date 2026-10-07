"""Fetch Quaternius' CC0 village from the author's Poly Pizza distribution pages."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'assets/village'
cache = ROOT / '.work/village-poly.html'
if cache.exists():
    html = cache.read_text(encoding='utf-8-sig')
else:
    request = urllib.request.Request('https://poly.pizza/bundle/Medieval-Village-Pack-NsHhjhlrfY', headers={'User-Agent':'Mozilla/5.0'})
    with urllib.request.urlopen(request, timeout=60) as response:
        html = response.read().decode('utf-8')
items, _ = json.JSONDecoder().raw_decode(html[html.index('"Models":') + 9:])
names = {0:'House_1', 1:'House_2', 5:'House_3', 6:'Blacksmith', 8:'Inn', 9:'Bell_Tower'}
wanted = {'Well', 'Market Stand', 'Cart', 'Barrel', 'Crate', 'Fence', 'Bench', 'Hay', 'Bags'}
for item in items:
    if item['title'] in wanted:
        name = item['title'].replace(' ', '_')
        if name in names.values():
            name += '_2'
        names[item['id']] = name

def read(url):
    req = urllib.request.Request(url, headers={'User-Agent':'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=60) as res:
        return res.read()

def download(item):
    name = names[item['id']]
    page_url = 'https://poly.pizza/m/' + item['publicID']
    page = read(page_url).decode('utf-8')
    url = re.search(r'https://static\.poly\.pizza/[^"<>\s&]+?\.glb(?:["&])', page).group(0)[:-1]
    data = read(url)
    if data[:4] != b'glTF':
        raise ValueError(f'{name}: not a GLB file')
    (DEST / (name+'.glb')).write_bytes(data)
    print(name, len(data), flush=True)
    return {'target':'assets/village/'+name+'.glb', 'source':page_url, 'download':url,
            'author':'Quaternius','license':'CC0-1.0','sha256':hashlib.sha256(data).hexdigest()}

DEST.mkdir(parents=True, exist_ok=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    sources = list(pool.map(download, [i for i in items if i['id'] in names]))
(DEST/'source.json').write_text(json.dumps(sources, indent=2)+'\n', encoding='utf-8')
(DEST/'LICENSE.txt').write_text('Medieval Village Pack by Quaternius\nCC0 1.0 Universal\nhttps://creativecommons.org/publicdomain/zero/1.0/\nhttps://quaternius.com/packs/medievalvillage.html\nDistributed by the author at https://poly.pizza/bundle/Medieval-Village-Pack-NsHhjhlrfY\n',encoding='utf-8')
