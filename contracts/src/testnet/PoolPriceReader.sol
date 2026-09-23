// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @title PoolPriceReader
/// @notice Reads a Uniswap v4 pool's spot price and expresses it as an 8-decimal
///         USD figure, the shape a Chainlink aggregator answer takes.
///
/// @dev FOR TESTNET USE ONLY, and the reason is the whole point.
///
///      On Robinhood Chain **mainnet**, Chainlink publishes genuine equity feeds —
///      Robinhood TSLA / USD `0x4A1166a659A55625345e9515b32adECea5547C38`,
///      Robinhood AMZN / USD `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C`,
///      USDG / USD `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` — and the policy
///      points at those. The reference is then independent of the venue being
///      checked, which is what makes the floor mean anything.
///
///      On **testnet** there is no such directory: `feeds-robinhood-testnet.json`
///      is a 404, and the nine aggregators that are live there are other teams'
///      fixtures. So the reference has to come from somewhere, and the two
///      candidates are both imperfect:
///
///        (a) the real mainnet price. Read on 2026-09-23 that is $380.26 for
///            TSLA and $256.91 for AMZN, while the testnet pools price them at
///            about $252 and $182. Using mainnet would reject every testnet
///            trade — not because anything is wrong, but because two unrelated
///            venues disagree by 30%.
///
///        (b) the testnet pool's own price, which is this contract.
///
///      (b) is the one that lets the demo run, and it comes with a limitation
///      that has to be said out loud rather than buried: on testnet the
///      reference is derived from the same venue it is checking. It still
///      catches the LP fee and the price impact *of the trade being made* —
///      which is what the thin testnet liquidity actually threatens — but it
///      cannot catch the venue being mispriced against the outside world. That
///      second guarantee exists only on mainnet, where the feed is Chainlink's.
library PoolPriceReader {
    /// @dev PoolManager stores pool state in mapping slot 6; slot0 is the first word.
    uint256 internal constant POOLS_SLOT = 6;

    /// @notice USD price of one whole `stock`, to 8 decimals, from the pool's spot.
    /// @param stableIsCurrency0 whether the 6-decimal stablecoin sorts first.
    /// @dev Assumes an 18-decimal equity token against a 6-decimal stablecoin held
    ///      at $1, which is exactly the pair this is used for. Anything else would
    ///      need the decimals passed in, and this deliberately does not pretend to
    ///      be general.
    function usdPrice8(IPoolManager manager, PoolKey memory key, bool stableIsCurrency0)
        internal
        view
        returns (uint256)
    {
        uint160 sqrtPriceX96 = sqrtPrice(manager, key);
        if (sqrtPriceX96 == 0) return 0;

        // currency1 per currency0, in raw units, scaled by 2**96.
        uint256 ratioX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        if (ratioX96 == 0) return 0;

        // 1e20 == 1e12 (18dp equity vs 6dp stable) * 1e8 (feed decimals).
        return stableIsCurrency0
            ? Math.mulDiv(1e20, 1 << 96, ratioX96) // ratio is equity per stable
            : Math.mulDiv(ratioX96, 1e20, 1 << 96); // ratio is stable per equity
    }

    function sqrtPrice(IPoolManager manager, PoolKey memory key) internal view returns (uint160) {
        bytes32 id = keccak256(abi.encode(key));
        bytes32 stateSlot = keccak256(abi.encode(id, POOLS_SLOT));
        return uint160(uint256(manager.extsload(stateSlot)));
    }
}
