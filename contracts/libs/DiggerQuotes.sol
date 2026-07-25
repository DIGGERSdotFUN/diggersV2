// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerV3} from "./DiggerV3.sol";

/**
 * @title DiggerQuotes
 * @notice View-only swap quotes kept out of the `Diggers` runtime.
 * @dev Linked external library. Thin facade over {DiggerV3.quoteExactInputSingle} used by
 *      `DiggersHub` buy/sell preview views and {DiggerBuybackLib} for fee-inclusive
 *      single-pool exact-input sizing. Keeping quotes out of the singleton preserves
 *      EIP-170 headroom on the hot create/swap/harvest paths.
 * @author BasedDopamine
 */
library DiggerQuotes {
    /**
     * @notice Fee-inclusive exact-input quote for one pool step.
     * @dev Delegates to {DiggerV3.quoteExactInputSingle} and discards the post-trade
     *      sqrt-price; callers that need only `amountOut` use this wrapper.
     * @param pool Uniswap V3 pool address for the digger token.
     * @param poolFee Pool fee tier in Uniswap millionths (e.g. 10000 = 1%).
     * @param zeroForOne `true` = quote→token (buy), `false` = token→quote (sell).
     * @param amountIn Exact input amount (quote wei when `zeroForOne`, token wei otherwise).
     * @return amountOut Expected output after the pool fee, before caller slippage checks.
     */
    function quoteExactInput(address pool, uint24 poolFee, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        (amountOut,) = DiggerV3.quoteExactInputSingle(pool, poolFee, zeroForOne, amountIn);
    }
}
