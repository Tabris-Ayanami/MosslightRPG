"""Copy a small, attributed subset of existing demo assets into this project."""
from pathlib import Path
import json
import shutil

project = Path(__file__).resolve().parents[1]
library = Path('F:/demo/crpg/SourceAssets/ThirdParty')
records = []
names = ['CommonTree_1', 'CommonTree_3', 'TwistedTree_1', 'Rock_Medium_1',
         'Rock_Medium_2', 'Rock_Medium_3', 'Rock_Large_1', 'Bush_Common',
         'Fern_1', 'Flower_3_Group', 'RockPath_Round_Small_1']
target = project / 'assets/nature'
target.mkdir(parents=True, exist_ok=True)
for name in names:
    source = library / 'Nature/glTF' / (name + '.gltf')
    if not source.exists():
        print('Unavailable optional model:', name)
        continue
    doc = json.loads(source.read_text(encoding='utf-8'))
    for entry in doc.get('buffers', []) + doc.get('images', []):
        uri = entry.get('uri', '')
        if uri and not uri.startswith('data:'):
            dependency = (source.parent / uri).resolve()
            dest = target / dependency.name
            shutil.copy2(dependency, dest)
            entry['uri'] = dest.name
    (target / source.name).write_text(json.dumps(doc, ensure_ascii=False), encoding='utf-8')
    records.append({'source': str(source), 'target': 'assets/nature/' + source.name,
                    'author': 'Quaternius', 'license': 'CC0-1.0'})
for name in ['Arch_Round_RoundColumn', 'Arch_Gothic', 'Column_Round', 'Column_Round_Short',
             'BridgeSection', 'Bricks', 'Brick', 'Floor_Diamond']:
    source = library / 'Ruins' / (name + '.fbx')
    shutil.copy2(source, project / 'assets/ruins' / source.name)
    records.append({'source': str(source), 'target': 'assets/ruins/' + source.name,
                    'author': 'Quaternius', 'license': 'CC0-1.0'})
for name in ['grassleaf.png', 'accentleaf.png']:
    shutil.copy2(library / 'DylearnGrass/Textures and Materials' / name, project / 'assets/foliage' / name)
shutil.copy2(library / 'Nature/License_Standard.txt', project / 'assets/licenses/Quaternius-Nature.txt')
shutil.copy2(library / 'Ruins/License.txt', project / 'assets/licenses/Quaternius-Ruins.txt')
shutil.copy2(library / 'DylearnGrass/LICENSE.txt', project / 'assets/licenses/Dylearn-Grass.txt')
(project / 'assets/manifest.json').write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding='utf-8')
print('Imported', len(records), 'models from the existing demo library.')
