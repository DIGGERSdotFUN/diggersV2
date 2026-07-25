// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.35;

import {DiggerCharset} from "./DiggerCharset.sol";
import {IDiggers} from "../interfaces/IDiggers.sol";

/**
 * @title DiggerRegistryLib
 * @notice Name registry logic executed via `delegatecall` from `Diggers`, so its bytecode
 *         lives off the singleton while it reads and writes the launchpad's registry
 *         storage. There is NO name-vs-symbol distinction: a token's folded name and
 *         folded symbol are both keys in ONE shared `lockCount` set of "name objects".
 * @dev Storage-pointer parameters resolve in Diggers' context under delegatecall; no state
 *      lives here. Each object stores TWO numbers: how many LIVE blue-chip tokens
 *      currently lock it (see {DiggerGraduationLib} — promotion increments, demotion
 *      decrements) and, once the LAST lock drops, a 24h creation-grace deadline so a
 *      wrongfully demoted blue chip cannot be name-sniped before it can recover.
 *      Creation is gated ONLY by those two: both keys at count zero AND past grace.
 *      There are no other clocks: no launch lock, no paid extensions.
 * @author BasedDopamine
 */
library DiggerRegistryLib {
    /**
     * @notice Charset-validates both strings and runs the creation gate: both objects
     *         must be unlocked (no live blue-chip token holds them) AND out of their
     *         post-demotion grace window.
     * @param lockCount Per-key live blue-chip lock counts (Diggers storage).
     * @param graceUntil Per-key post-demotion creation-grace deadlines (Diggers storage).
     * @param name Proposed token name (charset-validated by {DiggerCharset.nameKey}).
     * @param symbol Proposed token symbol (charset-validated by {DiggerCharset.symbolKey}).
     * @return nameKey Folded keccak key for `name`.
     * @return symbolKey Folded keccak key for `symbol`.
     */
    function precheck(
        mapping(bytes32 => uint32) storage lockCount,
        mapping(bytes32 => uint64) storage graceUntil,
        string calldata name,
        string calldata symbol
    ) external view returns (bytes32 nameKey, bytes32 symbolKey) {
        nameKey = DiggerCharset.nameKey(name);
        symbolKey = DiggerCharset.symbolKey(symbol);

        if (lockCount[nameKey] != 0) revert IDiggers.NameReserved();
        if (lockCount[symbolKey] != 0) revert IDiggers.SymbolReserved();
        if (block.timestamp < graceUntil[nameKey]) revert IDiggers.NameInGrace();
        if (block.timestamp < graceUntil[symbolKey]) revert IDiggers.SymbolInGrace();
    }

    /**
     * @notice Permanently reserves a name + symbol pair so no token can ever launch with
     *         them — the platform brand guard. Irreversible: the count-1 has no owning
     *         token, and only a demotion of the owning token can ever decrement.
     * @dev Owner-gated by the Diggers caller. Sets both keys to lock count 1 with no
     *      grace stamp (grace only applies after a live blue-chip's last lock drops).
     * @param lockCount Per-key live blue-chip lock counts (Diggers storage).
     * @param name Name object to reserve forever.
     * @param symbol Symbol object to reserve forever.
     */
    function reserveForever(
        mapping(bytes32 => uint32) storage lockCount,
        string calldata name,
        string calldata symbol
    ) external {
        lockCount[DiggerCharset.nameKey(name)] = 1;
        lockCount[DiggerCharset.symbolKey(symbol)] = 1;
    }

    // ---------------------------------------------------------------- views

    /// @dev The registry views (isNameFree/isSymbolFree/keyStateOf) live on the
    ///      DiggersHub, which folds keys with the same {DiggerCharset} and reads the two
    ///      registry mappings through raw extsload slots — identical gate, one address.
}
