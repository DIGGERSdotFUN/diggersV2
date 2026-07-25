// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerMath} from "./DiggerMath.sol";
import {DiggerQuotes} from "./DiggerQuotes.sol";
import {IWETH9} from "./DiggerV3.sol";
import {DiggersToken} from "../DiggersToken.sol";

/**
 * @title DiggerBuybackLib
 * @notice Buyback preparation executed via `delegatecall` from `Diggers`, keeping its
 *         bytecode off the singleton. Runs the wrap step (fold parked native donations
 *         into the token's WETH pot), sizes the spend with the anti-sandwich cap, pulls
 *         the pot, and hands the launchpad a ready-to-swap native amount + min-out. The
 *         swap and burn stay in the launchpad (they need its internal V3 callback
 *         plumbing). Under delegatecall `address(this)` is the launchpad, so the sweeps
 *         and WETH ops below act on the singleton's own balances.
 * @dev Sits between opportunistic harvest (which may push creator-buyback carve ETH onto
 *      the token vault) and Diggers' `_swapV3` buy-then-burn. Quoting uses
 *      {DiggerQuotes.quoteExactInput} against the token's own pool; dual-native chains
 *      (Stable USDT0) skip wrap/unwrap and read a single shared native/quote balance.
 * @author BasedDopamine
 */
library DiggerBuybackLib {
    /// @dev 1e18 == 100%.
    uint256 private constant WAD = 1e18;

    /// @notice WETH payment failed inside the buyback preparation.
    error BuybackWethFailed();
    /// @notice Native park-back to the token vault failed.
    error BuybackParkFailed();

    /**
     * @notice Prepares a buyback after a settled user BUY: wrap step (Robinhood only),
     *         anti-sandwich sizing, pot pull. On return the launchpad holds `spend`
     *         native wei ready to swap (0 = nothing to do this pass; any remainder is
     *         parked back on `token`).
     * @dev Sizing rule — the buyback's token output may never exceed the carrying user
     *      buy's output. The FULL pot is quoted; when its output would exceed the user's,
     *      the spend scales to `pot · userOut / fullOut · 80%` (20% safety haircut). No
     *      start threshold: a dust buy can only ever unlock a dust buyback.
     *
     *      Dual-native mode (Stable's USDT0): the quote ERC-20 and native gas are ONE
     *      balance, so the pot is read from `token.balance` ONLY — adding
     *      `WETH.balanceOf(token)` would double-count the same funds — and there is no
     *      wrap step. All quoting happens in pool units (wei / quoteScale); the spend is
     *      floored to a unit-aligned wei amount so the swap carries zero dust.
     * @param token The launched token whose pot is being spent.
     * @param weth The quote token (token0 of the pool).
     * @param pool The token's V3 pool.
     * @param poolFee LP fee in millionths (10000 = 1%).
     * @param userAmountOut Token amount the carrying user buy just received.
     * @param wrapMinThreshold Gas-dust floor for the wrap step (wei; unused when dual).
     * @param quoteScale wei per pool unit (1 on Robinhood, 1e12 on Stable).
     * @param dualNative True when the quote ERC-20 shares the native balance.
     * @return spend Native wei to swap (already sitting native on the launchpad).
     * @return minOut Hard sanity floor for the swap output (bit-exact quote − 1 ppm).
     */
    function prepare(
        address token,
        address weth,
        address pool,
        uint24 poolFee,
        uint256 userAmountOut,
        uint256 wrapMinThreshold,
        uint256 quoteScale,
        bool dualNative
    ) external returns (uint256 spend, uint256 minOut) {
        uint256 pot;
        if (dualNative) {
            // ONE shared balance: the native pot IS the quote-token pot. Read one, never sum.
            pot = token.balance;
        } else {
            // Wrap step: fold parked native donations into the WETH pot once they clear the
            // gas-dust floor. A wrap-only pass (nothing spendable after) is a valid outcome.
            if (token.balance >= wrapMinThreshold) {
                uint256 swept = DiggersToken(payable(token)).sweepDonations();
                IWETH9(weth).deposit{value: swept}();
                if (!IWETH9(weth).transfer(token, swept)) revert BuybackWethFailed();
            }
            pot = IWETH9(weth).balanceOf(token); // non-dual is always 18-dec (scale == 1)
        }

        uint256 potUnits = pot / quoteScale;
        if (potUnits == 0 || userAmountOut == 0) return (0, 0);

        uint256 fullOut = DiggerQuotes.quoteExactInput(pool, poolFee, true, potUnits);
        if (fullOut == 0) return (0, 0);

        spend = pot;
        uint256 spendUnits = potUnits;
        if (fullOut > userAmountOut) {
            spend = DiggerMath.md512(pot, userAmountOut, fullOut) * 80 / 100;
            spendUnits = spend / quoteScale;
            if (spendUnits == 0) return (0, 0);
            spend = spendUnits * quoteScale; // unit-align: the swap must carry no dust
        }

        // Pull the pot onto the launchpad as native, then park the unspent remainder back.
        if (dualNative) {
            DiggersToken(payable(token)).sweepDonations();
            if (pot > spend) {
                (bool parked,) = token.call{value: pot - spend}("");
                if (!parked) revert BuybackParkFailed();
            }
        } else {
            DiggersToken(payable(token)).sweepErc20(weth);
            IWETH9(weth).withdraw(spend);
            if (pot > spend && !IWETH9(weth).transfer(token, pot - spend)) revert BuybackWethFailed();
        }

        // Hard sanity floor, not user slippage: the quoter is bit-exact and runs in the
        // same tx, so the real output can only differ by rounding dust (1 ppm shave).
        minOut = spendUnits == potUnits ? fullOut : DiggerQuotes.quoteExactInput(pool, poolFee, true, spendUnits);
        minOut -= minOut / 1e6;
    }
}
