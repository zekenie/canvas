// The mess dial: one number, 0 (tidy) to 1 (loose), and everything it sets. Each setting is linear in `mess`, so the dial is monotone
// by construction: more mess never makes a pill cheaper, a cap larger or good enough harder to reach.
//
//   mess      0.0    0.2    0.5    0.8    1.0
//   mu        2.00   2.80   4.00   5.20   6.00     the price of a pill in the cost C           = 2 + 4 mess
//   cap       50%    40%    25%    10%     0%        the safety cap: share of the board's leaves promoted at most = 0.5 (1 - mess)
//   margin    1      1      2      3      3         the least gain margin, in pills (noise may raise it)          = round(1 + 2 mess)
//   X/arrow   0      .04    .10    .16    .20       good enough: crossings per arrow at most                      = 0.2 mess
//   Fx/arrow  0      .02    .05    .08    .10       good enough: frame-border crossings per arrow at most         = 0.1 mess
//   NE/arrow  0      0      0      .12    .20       good enough: arrows over shapes per arrow at most             = 0.4 max(0, mess - 0.5)
//   aspect    2      2.4    3      3.6    4         good enough: the board's aspect at most                       = 2 + 2 mess
//
// The default is 0.1: the owner found it almost good enough. 0.5 is the middle (mu 4, cap 25%, margin 2 pills, X 0.1, Fx 0.05, NE 0, aspect 3).
export const DEFAULT_MESS = 0.1;
// The search itself (which hub is tried, what a layout costs) runs at the reference price of a pill, REF_MU, whatever the dial: the sequence of promotions
// is the same for every mess, and the dial says how far down it the loop goes (the cap, the margin, the price of the pills it adds, good enough). That makes the
// dial monotone by construction: a lower mess never stops earlier. The cost C the report gives is at the dial's own mu.
export const REF_MU = 4;

const round = (x, d = 1e4) => Math.round(x * d) / d;

export function dial(mess) {
  const m = mess == null || Number.isNaN(+mess) ? DEFAULT_MESS : Math.min(1, Math.max(0, +mess));
  return {
    mess: m,
    mu: round(2 + 4 * m),
    capShare: round(0.5 * (1 - m)),
    marginPills: Math.round(1 + 2 * m),
    good: { xPerArrow: round(0.2 * m), fxPerArrow: round(0.1 * m), nePerArrow: round(0.4 * Math.max(0, m - 0.5)), aspect: round(2 + 2 * m) },
  };
}

/** Whether a layout's terms are good enough under the dial (n: arrows, plain and into shared pills). */
export function isGood(d, { NE, X, Fx, aspect }, n) {
  const k = Math.max(1, n);
  return NE <= d.good.nePerArrow * k && X <= d.good.xPerArrow * k && Fx <= d.good.fxPerArrow * k && aspect <= d.good.aspect;
}
