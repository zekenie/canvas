"""Checks heuristic.py's promises on every board, and prints a digest to compare across hash seeds."""
import hashlib, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from heuristic import *
bad = []
digest = hashlib.sha256()
for b in gen.boards_for(PROD):
    d = decide(b)
    E, R, A = d['uses'], references(b), arrows(b)
    if R | A != E or R & A: bad.append((b, 'not a partition'))
    for x, y in E:
        if (y, x) in E and (((x, y) in R) != ((y, x) in R)): bad.append((b, 'pair split', x, y))
    for hub in d['hubs']:
        if any(y == hub and (x, y) not in R for x, y in E): bad.append((b, 'hub with an arrow in', hub))
    before = set(z for e in d['after_hubs'] for z in e)
    after = set(z for e in d['arrows'] for z in e)
    if before != after: bad.append((b, 'relays isolated', before - after))
    files, uses = board_uses(b)
    if references_of(files, uses, symbols, ftitle) != R: bad.append((b, 'references_of differs'))
    digest.update(json.dumps([b, sorted(map(list, R))]).encode())
nodes, uses, w = canvas_folders()
cr = references_of(nodes, uses, w)
digest.update(json.dumps(sorted(map(list, cr))).encode())
# edge cases of the generic function
assert references_of([], set(), lambda a, b: 1) == set()
assert references_of(['a', 'b'], {('a', 'b'), ('a', 'a'), ('a', 'z')}, lambda a, b: 1) == set()
star = ['hub'] + [f'u{i}' for i in range(8)]
uses_s = {(f'u{i}', 'hub') for i in range(8)} | {(f'u{i}', f'u{i+1}') for i in range(7)} | {(f'u{i}', f'u{(i+3) % 8}') for i in range(8)}
print('star test:', sorted(references_of(star, uses_s, lambda a, b: 1))[:3], '...')
print('problems:', bad or 'none')
print('digest:', digest.hexdigest()[:16])
