// The test's known answers: K5 and K3,3 are not planar, and each is planar less any one edge; a grid, a wheel and K4 are planar.
import { isPlanar, edgeCuts, hubCuts } from './planar.mjs';
const K = (n) => { const e = []; for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) e.push([i, j]); return e; };
const K33 = []; for (const a of [0, 1, 2]) for (const b of [3, 4, 5]) K33.push([a, b]);
const grid = []; for (let r = 0; r < 5; r++) for (let c = 0; c < 5; c++) { const v = r * 5 + c; if (c < 4) grid.push([v, v + 1]); if (r < 4) grid.push([v, v + 5]); }
const wheel = []; for (let i = 1; i <= 8; i++) { wheel.push([0, i]); wheel.push([i, i === 8 ? 1 : i + 1]); }
// the Petersen graph: not planar, skewness 2
const pet = [[0,1],[1,2],[2,3],[3,4],[4,0],[0,5],[1,6],[2,7],[3,8],[4,9],[5,7],[7,9],[9,6],[6,8],[8,5]];
const checks = [
  ['K4 planar', isPlanar(4, K(4)) === true],
  ['K5 not planar', isPlanar(5, K(5)) === false],
  ['K5 less an edge planar', isPlanar(5, K(5).slice(1)) === true],
  ['K3,3 not planar', isPlanar(6, K33) === false],
  ['K3,3 less an edge planar', isPlanar(6, K33.slice(1)) === true],
  ['grid planar', isPlanar(25, grid) === true],
  ['wheel planar', isPlanar(9, wheel) === true],
  ['Petersen not planar', isPlanar(10, pet) === false],
  ['Petersen: 2 edge cuts', edgeCuts(10, pet).length === 2],
  ['K6 not planar', isPlanar(6, K(6)) === false],
  ['K6: 3 edge cuts', edgeCuts(6, K(6)).length === 3],
  ['K5: 1 hub', hubCuts(5, K(5)).length === 1],
  ['K7: 3 hubs', hubCuts(7, K(7)).length === 3],
  ['two K5s joined by an edge: not planar', isPlanar(10, K(5).concat(K(5).map(([a, b]) => [a + 5, b + 5]), [[0, 5]])) === false],
];
let bad = 0;
for (const [name, ok] of checks) { if (!ok) bad++; console.log(ok ? 'ok  ' : 'FAIL', name); }
process.exit(bad ? 1 : 0);
