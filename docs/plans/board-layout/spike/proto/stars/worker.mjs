// stars2's worker: one configuration of the layout, for the board the main thread names.
import { parentPort } from 'worker_threads';
import { fileURLToPath } from 'url';
import path from 'path';
import { load } from '../harness.mjs';
import { runConfig } from './module.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const m = load(path.resolve(here, '../../data'));
parentPort.on('message', async ({ board, i }) => { parentPort.postMessage(await runConfig(m, board, i)); });
