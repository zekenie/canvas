// The groups `cluster` made, in the form the spike kept them (strategy/groups.json, the spike's data/groups-decided.json): every board's containers and the group each item is in.
//   node corpus-groups.mjs <clusters.json>
import fs from 'fs';
const r = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
process.stdout.write(JSON.stringify({ made: 'cluster.mjs --frames=units --res=1.5, EMB=openai-3-large, a link weighed by its rank', boards: r.boards.map(({ board, levels }) => ({ board, levels })) }, null, 1) + '\n');
