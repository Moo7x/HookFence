// The keeper's rules, in one place. Pure functions: no network, no keys.
//
// They mirror DemoPriceFeed version 2 exactly, so the keeper only sends an update
// the feed will accept. A move the feed would refuse is reported, not attempted:
// the feed then ages out and buying stops until a person looks - failing closed
// is the intended outcome, not a malfunction.

export const BAND_WINDOW = 86_400n;

/** How far `to` is from `from`, in basis points, rounded down. */
export function moveBps(from, to) {
  const diff = to > from ? to - from : from - to;
  return (diff * 10_000n) / from;
}

function exceeds(from, to, limitBps) {
  const diff = to > from ? to - from : from - to;
  return diff * 10_000n > from * limitBps;
}

/**
 * Decide whether to publish `next` to a feed in `state`.
 *
 * state: { answer, updatedAt, maxStepBps, minUpdateInterval, maxDailyMoveBps,
 *          bandAnchor, bandStartedAt }   (all bigint)
 * Returns { action: "send" | "wait" | "skip", reason, ... }.
 */
export function decide(state, next, now) {
  if (next <= 0n) return { action: "skip", reason: "the pool has no price" };
  if (now < state.updatedAt + state.minUpdateInterval) {
    return { action: "wait", reason: "updated too recently", retryAt: state.updatedAt + state.minUpdateInterval };
  }
  if (state.maxStepBps !== 0n && exceeds(state.answer, next, state.maxStepBps)) {
    return { action: "skip", reason: "move exceeds the per-update step", moveBps: moveBps(state.answer, next) };
  }
  if (state.maxDailyMoveBps !== 0n) {
    // A new 24-hour window starts from the answer standing when the old one ends.
    const anchor = now >= state.bandStartedAt + BAND_WINDOW ? state.answer : state.bandAnchor;
    if (exceeds(anchor, next, state.maxDailyMoveBps)) {
      return { action: "skip", reason: "move exceeds the 24-hour band", moveBps: moveBps(anchor, next) };
    }
  }
  return { action: "send", reason: "within every bound", moveBps: moveBps(state.answer, next) };
}

/**
 * USD price of the equity in a stablecoin/equity pool, 8 decimals, from the
 * pool's sqrtPriceX96. Same integer maths as contracts/src/testnet/PoolPriceReader.sol
 * (18-decimal equity, 6-decimal stable).
 */
export function usdPrice8(sqrtPriceX96, stableIsCurrency0) {
  if (sqrtPriceX96 === 0n) return 0n;
  const Q96 = 1n << 96n;
  const ratioX96 = (sqrtPriceX96 * sqrtPriceX96) / Q96;
  if (ratioX96 === 0n) return 0n;
  const E20 = 10n ** 20n; // 1e12 (18dp vs 6dp) * 1e8 (feed decimals)
  return stableIsCurrency0 ? (E20 * Q96) / ratioX96 : (ratioX96 * E20) / Q96;
}
