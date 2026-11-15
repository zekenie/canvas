// The stars prototype as the owner saw it: the layout, then shared pills (a pill two neighbours use, kept once when that stays clean).
import * as base from './module.mjs';
import { withShared } from '../planar/shared.mjs';
export const { layoutBoard } = withShared(base);
