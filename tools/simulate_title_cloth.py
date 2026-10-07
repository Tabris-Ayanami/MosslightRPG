"""Bake the actual coat surface, retaining UVs and the original unmodified gameplay GLB.

Run after bake_title_story.gd, then pack_title_cloth.gd. Numpy is the only dependency.
Rest lengths come from the standing mesh; warm-up walks the animated body back into
the lying pose, avoiding the penetrated initial state of a teleported flat coat.
"""
from pathlib import Path
import json
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.work/title-story'
G = json.loads((WORK / 'geometry.json').read_text(encoding='utf8'))
FPS = float(G['fps'])
M = np.fromfile(WORK / 'skin-matrices.bin', '<f4').reshape(-1, len(G['bindings']), 3, 4)
BODY = np.fromfile(WORK / 'body-points.bin', '<f4').reshape(-1, 8, 3)
NFRAME = len(M)
OUT_FPS = 30
DT = 1 / 240
FLOOR = .043

positions, weights, bones, uv, normals, tris, partitions = [], [], [], [], [], [], []
offset = 0
for s in G['surfaces']:
    indices = np.asarray(s['cloth_indices'], int).reshape(-1, 3)
    ids = np.unique(indices)
    remap = np.full(len(s['positions']), -1, int)
    remap[ids] = np.arange(len(ids)) + offset
    positions.extend(np.asarray(s['positions'])[ids])
    weights.extend(np.asarray(s['weights']).reshape(-1, int(s['influences']))[ids])
    bones.extend(np.asarray(s['bones']).reshape(-1, int(s['influences']))[ids])
    uv.extend(np.asarray(s['uv'])[ids])
    normals.extend(np.asarray(s['normals'])[ids])
    mapped = remap[indices]
    tris.extend(mapped)
    partitions.append({'ids': ids.tolist(), 'triangles': mapped.tolist(), 'offset': offset,
                       'upper_indices': s['upper_indices']})
    offset += len(ids)
positions, weights, bones = np.asarray(positions), np.asarray(weights), np.asarray(bones, int)
triangles = np.asarray(tris, int)
homogeneous = np.column_stack((positions, np.ones(len(positions))))
targets = np.empty((NFRAME, len(positions), 3), np.float32)
for start in range(0, NFRAME, 40):
    end = min(start + 40, NFRAME)
    targets[start:end] = np.einsum('fnkij,nj,nk->fni', M[start:end, bones], homogeneous, weights)
REST_TIME = float(G['rest_time'])
rest = targets[round(REST_TIME * FPS)].astype(float)
_, representatives, weld = np.unique(np.round(rest / .00003).astype(np.int64), axis=0,
                                      return_index=True, return_inverse=True)
rest_points = rest[representatives]
point_targets = targets[:, representatives]
particle_triangles = weld[triangles]
valid = ((particle_triangles[:,0] != particle_triangles[:,1]) &
         (particle_triangles[:,1] != particle_triangles[:,2]) &
         (particle_triangles[:,0] != particle_triangles[:,2]))
particle_triangles = particle_triangles[valid]
waist_height = BODY[round(REST_TIME * FPS),0,1]
# The rigid/dynamic seam must stay welded, irrespective of a new animation's
# standing pelvis height. Attach upper waist vertices relative to that pelvis.
seam = np.zeros(len(positions),bool)
for s,part in zip(G['surfaces'],partitions):
    seam[part['offset']:part['offset']+len(part['ids'])] = np.isin(part['ids'],s['upper_indices'])
fixed_seam = np.zeros(len(rest_points),bool)
np.logical_or.at(fixed_seam,weld,seam)
fixed = (rest_points[:,1] > waist_height+.02) | fixed_seam
inv_mass = (~fixed).astype(float)

edge_map = {}
for a,b,c in particle_triangles:
    for i,j,opposite in [(a,b,c),(b,c,a),(c,a,b)]:
        edge_map.setdefault(tuple(sorted((int(i),int(j)))), []).append(int(opposite))
edges = np.array(list(edge_map), int)
bend = np.array([(v[0],v[1]) for v in edge_map.values() if len(v)==2 and v[0]!=v[1]], int)
all_edges = np.concatenate((edges, bend))
rest_length = np.linalg.norm(rest_points[all_edges[:,1]] - rest_points[all_edges[:,0]], axis=1)
compliance = np.r_[np.full(len(edges), 2.e-8), np.full(len(bend), 1.e-4)]
good = (rest_length > .0001) & ((inv_mass[all_edges[:,0]] + inv_mass[all_edges[:,1]]) > 0)
all_edges, rest_length, compliance = all_edges[good], rest_length[good], compliance[good]

# Graph colouring permits Gauss-Seidel updates without competing writes to a particle.
colors, occupied = [], []
for index,(a,b) in enumerate(all_edges):
    for color, used in enumerate(occupied):
        if a not in used and b not in used: break
    else:
        color = len(occupied); occupied.append(set()); colors.append([])
    occupied[color].update((a,b)); colors[color].append(index)
groups = [np.asarray(c,int) for c in colors]

def sample(array, time):
    f = np.clip(time * FPS, 0, NFRAME-1)
    i = min(int(f), NFRAME-2)
    return array[i]*(1-(f-i)) + array[i+1]*(f-i)

def capsules(body):
    # Waist/thigh/calf/boot volumes are evaluated from the same baked body pose.
    pairs = [(0,1,.246),(2,3,.176),(3,4,.122),(5,6,.176),(6,7,.122)]
    return [(body[a],body[b],r+.010) for a,b,r in pairs]

def project(p, colliders, hint=None):
    q = p.copy()
    for a,b,r in colliders:
        ab = b-a
        along = np.clip(((q-a) @ ab)/max(float(ab @ ab),1.e-8),0,1)
        center = a+along[:,None]*ab
        delta = q-center
        length = np.linalg.norm(delta,axis=1)
        mask = length < r
        normal = delta/np.maximum(length,1.e-9)[:,None]
        if hint is not None:
            old_along=np.clip(((hint-a)@ab)/max(float(ab@ab),1.e-8),0,1)
            old_delta=hint-(a+old_along[:,None]*ab)
            old_length=np.linalg.norm(old_delta,axis=1)
            # A stretch constraint can cross the middle of a thigh in one solve
            # even at a tiny time step. Preserve its previous contact side instead
            # of ejecting the fabric from the opposite side in the next frame.
            crossed=((delta*old_delta).sum(axis=1)<0)&(old_length<r*1.35)&(old_length>r*.65)&(length<r*1.4)
            normal[crossed]=old_delta[crossed]/old_length[crossed,None]
            mask |= crossed
        q[mask]=center[mask]+normal[mask]*r
    q[:,1] = np.maximum(q[:,1],FLOOR)
    return q

x = rest_points.copy()
previous = x.copy()
max_strain = 0.

def step(time):
    global x, previous
    anchors = sample(point_targets,time)
    colliders = capsules(sample(BODY,time))
    old = x.copy()
    velocity = (x-previous)*np.exp(-3.8*DT)
    # Only the waist is pinned. Lower fabric may settle independently of the rig.
    guide = np.clip((rest_points[:,1]-.4)/1.2,0,1)[:,None] * 1.5
    acceleration = (anchors-x)*guide + [0,-9.8,0]
    x += velocity + acceleration*DT*DT
    x[fixed] = anchors[fixed]
    lambdas = np.zeros(len(all_edges))
    for iteration in range(2):
        for group in groups:
            a,b = all_edges[group].T
            delta = x[b]-x[a]
            length = np.maximum(np.linalg.norm(delta,axis=1),1.e-9)
            alpha = compliance[group]/(DT*DT)
            dl = (-(length-rest_length[group])-alpha*lambdas[group])/(inv_mass[a]+inv_mass[b]+alpha)
            lambdas[group] += dl
            correction = delta*(dl/length)[:,None]
            x[a] -= correction*inv_mass[a,None]
            x[b] += correction*inv_mass[b,None]
        projected = project(x,colliders,old)
        x[~fixed] = projected[~fixed]
        # Mid-edge contacts constrain fabric between its vertices, which sparse
        # bone collisions cannot protect. Corrections are shared by each seam.
        if iteration==1:
            a,b = edges.T
            middle = (x[a]+x[b])*.5
            correction = project(middle,colliders,(old[a]+old[b])*.5)-middle
            weight = inv_mass[a]+inv_mass[b]
            correction *= (2/np.maximum(weight,1))[:,None]
            accum = np.zeros_like(x); counts = np.zeros(len(x))
            np.add.at(accum,a,correction*inv_mass[a,None]); np.add.at(accum,b,correction*inv_mass[b,None])
            np.add.at(counts,a,inv_mass[a]); np.add.at(counts,b,inv_mass[b])
            x += accum/np.maximum(counts,1)[:,None]
            x[~fixed] = project(x,colliders,old)[~fixed]
    previous = old
    contact = (x[:,1] < FLOOR+.005)
    for a,b,r in colliders:
        ab=b-a
        center=a+np.clip(((x-a)@ab)/max(float(ab@ab),1.e-8),0,1)[:,None]*ab
        contact |= np.linalg.norm(x-center,axis=1)<r+.005
    previous[contact] = previous[contact]*.3+x[contact]*.7
    return x[weld]

print(f'CLOTH surface vertices={len(positions)} particles={len(x)} triangles={len(triangles)} pins={fixed.sum()} constraints={len(all_edges)} colours={len(groups)}',flush=True)
print('CLOTH settling from bind/standing pose into rest',flush=True)
for i in range(4*240): step(REST_TIME*(1-(i+1)/(4*240)))
for i in range(240): step(0)
output = [x[weld].copy()]
count = round(float(G['duration'])*240)
for i in range(1,count+1):
    result = step(i/240)
    if i%8==0: output.append(result.copy())
    if i%480==0: print(f'CLOTH baked {i/240:.1f}s / {G["duration"]}',flush=True)
output = np.asarray(output,dtype=np.float32)
# Filter only subpixel vertex chatter; this never changes which body pose is shown.
filtered=output.copy()
kernel=np.asarray([1,4,6,4,1])/16
for i in range(1,len(output)-1):
    ids=np.clip(np.arange(i-2,i+3),0,len(output)-1)
    filtered[i]=np.einsum('f,fnc->nc',kernel,output[ids])
    # Waist seam vertices follow the matching native skeleton without any lag.
    filtered[i,fixed[weld]]=output[i,fixed[weld]]
for i in range(len(filtered)):
    cols=capsules(sample(BODY,i/OUT_FPS))
    free = ~fixed[weld]
    filtered[i,free] = project(filtered[i],cols,output[i])[free]

normals_out=np.zeros_like(filtered)
for frame,p in enumerate(filtered):
    a,b,c=triangles.T
    n=np.cross(p[b]-p[a],p[c]-p[a])
    # Godot triangle winding is clockwise.
    for index in (a,b,c): np.add.at(normals_out[frame],index,-n)
    normals_out[frame] /= np.maximum(np.linalg.norm(normals_out[frame],axis=1),1.e-9)[:,None]
filtered.astype('<f4').tofile(WORK/'cloth-positions.bin')
normals_out.astype('<f4').tofile(WORK/'cloth-normals.bin')
metadata={'width':len(positions),'height':len(filtered),'fps':OUT_FPS,'surfaces':partitions,
          'uv':np.asarray(uv).tolist(),'initial_positions':filtered[0].tolist(),
          'bounds_min':filtered.min(axis=(0,1)).tolist(),'bounds_max':filtered.max(axis=(0,1)).tolist(),
          'floor_min':float(filtered[:,:,1][:,~fixed[weld]].min()),
          'all_floor_min':float(filtered[:,:,1].min()),'pins':int(fixed.sum()),
          'seam_error':float(np.linalg.norm(filtered[:,seam]-targets[::2,seam],axis=-1).max()),
          'max_vertex_step':float(np.linalg.norm(np.diff(filtered,axis=0),axis=-1).max())}
assert metadata['seam_error'] < 1.e-5, 'Rigid/dynamic coat seam separated'
(WORK/'cloth.json').write_text(json.dumps(metadata),encoding='utf8')
print('CLOTH done',metadata['width'],metadata['height'],'min free surface y',metadata['floor_min'],flush=True)
