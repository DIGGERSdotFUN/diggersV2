// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

/**
 * @title DiggerCharset
 * @notice Pure on-chain charset validation and case-insensitive keying for the name
 *         registry. Symbols and names are two symmetric keys; a token contends on both.
 * @dev `internal` on purpose: these fold + hash helpers inline into whichever library
 *      links them (the registry lib), keeping them off the `Diggers` singleton runtime.
 *      Keys are `keccak256` of the byte-folded string (A–Z → a–z), so `PEPE`, `pepe`,
 *      and `Pepe` collapse to one key. No unicode: any byte ≥ 0x80, punctuation, or
 *      control byte reverts — the charset is strictly `[A-Za-z0-9]` (names also allow
 *      single internal spaces).
 * @author BasedDopamine
 */
library DiggerCharset {
    /// @notice Symbol failed the `[A-Za-z0-9]`, length 1..10 charset.
    error InvalidSymbol();

    /// @notice Name failed the `[A-Za-z0-9]` + single-internal-space, length 1..32 charset.
    error InvalidName();

    /// @dev Max symbol length (chars).
    uint256 private constant MAX_SYMBOL = 10;

    /// @dev Max name length (chars, spaces included).
    uint256 private constant MAX_NAME = 32;

    /**
     * @notice Validates a symbol and returns its case-folded registry key.
     * @dev Mutates the in-memory `bytes` copy (A–Z → a–z) before hashing; the caller's
     *      original string storage is untouched. Reverts {InvalidSymbol} on empty,
     *      overlong, or out-of-charset bytes.
     * @param symbol Raw symbol string.
     * @return key `keccak256` of the lowercased bytes.
     */
    function symbolKey(string memory symbol) internal pure returns (bytes32 key) {
        bytes memory b = bytes(symbol);
        uint256 len = b.length;
        if (len == 0 || len > MAX_SYMBOL) revert InvalidSymbol();

        for (uint256 i; i < len; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x41 && c <= 0x5A) {
                b[i] = bytes1(c + 32); // A–Z → a–z
            } else if (!((c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39))) {
                revert InvalidSymbol(); // not a–z / 0–9
            }
        }
        key = keccak256(b);
    }

    /**
     * @notice Validates a name and returns its case-folded registry key.
     * @dev Allows single spaces between words; rejects leading, trailing, or doubled
     *      spaces so " ab", "ab ", and "a  b" are all invalid. Same in-memory fold as
     *      {symbolKey}; reverts {InvalidName} on empty, overlong, or out-of-charset bytes.
     * @param name Raw name string.
     * @return key `keccak256` of the lowercased bytes.
     */
    function nameKey(string memory name) internal pure returns (bytes32 key) {
        bytes memory b = bytes(name);
        uint256 len = b.length;
        if (len == 0 || len > MAX_NAME) revert InvalidName();

        for (uint256 i; i < len; ++i) {
            uint8 c = uint8(b[i]);
            if (c == 0x20) {
                // space: not first, not last, not doubled
                if (i == 0 || i == len - 1 || uint8(b[i - 1]) == 0x20) revert InvalidName();
            } else if (c >= 0x41 && c <= 0x5A) {
                b[i] = bytes1(c + 32); // A–Z → a–z
            } else if (!((c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39))) {
                revert InvalidName(); // not a–z / 0–9 / space
            }
        }
        key = keccak256(b);
    }
}
