// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title TxBlacklistTestable
/// @notice Test-only fork of the production `TxBlacklist` contract (risk-control repo:
///         `forcetxblacklist` @ `hugo/ProxyMode/src/TxBlacklist.sol`), used exclusively by
///         xlayer-reth's own in-process integration tests
///         (`crates/builder/src/tests/xlayer_blacklist.rs`).
///
///         Differences from production, both deliberate simplifications for testability:
///         1. No `Ownable2StepUpgradeable` / no owner role at all. `setOperator`/`setOperators`
///            are permissionless here, so a test can bootstrap any account as an operator
///            directly, with no ownership-transfer handshake to simulate.
///         2. Not upgradeable: no proxy, no `initialize()`, no constructor to skip. Genesis
///            `alloc` predeploys never run a constructor anyway (the account's `code` field is
///            placed as-is, as if already deployed), so the production contract's
///            `_disableInitializers()`/`initialize()` split has no purpose here.
///
///         `isBlacklisted`/`areBlacklisted` (the only surface `OpEvm`'s deposit-blacklist
///         interception actually calls, via `evm.transact_system_call`) and the operator-gated
///         `addToBlacklist`/`batchAddToBlacklist`/`removeFromBlacklist`/`batchRemoveFromBlacklist`
///         are byte-identical in selector and behavior to production — only the admin surface
///         (who may call `setOperator`) is relaxed.
///
/// @dev NOT the deployed production contract — do not reuse this outside local devnet and
///      xlayer-reth tests. `scripts/inject-txblacklist-genesis-alloc.sh` compiles this source
///      with the pinned Foundry configuration inside the OP contracts image and caches the
///      resulting runtime bytecode locally before injecting it into genesis.
contract TxBlacklistTestable {
    /// @notice Maximum number of hashes accepted by a single list-write batch.
    uint256 public constant MAX_BATCH_SIZE = 500;

    /// @notice Whether an address is authorized to modify the blacklist.
    mapping(address => bool) public operators;

    /// @notice Whether a transaction source hash is currently banned.
    mapping(bytes32 => bool) public blacklisted;

    /// @notice Number of distinct non-zero hashes currently banned.
    uint256 public blacklistCount;

    event OperatorUpdated(address indexed operator, bool allowed);
    event TxBlacklisted(bytes32 indexed txHash, address indexed operator);
    event TxUnblacklisted(bytes32 indexed txHash, address indexed operator);

    error NotOperator();
    error ZeroAddress();
    error EmptyBatch();
    error BatchTooLarge(uint256 size);
    error InvalidTxHash();

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator();
        _;
    }

    /// @notice Test-only: permissionless (no `onlyOwner`) so any test account can grant itself
    ///         (or another test account) operator authority directly.
    function setOperator(address operator, bool allowed) external {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    /// @notice Test-only: permissionless, see `setOperator`.
    function setOperators(address[] calldata operatorList, bool allowed) external {
        uint256 len = operatorList.length;
        if (len == 0) revert EmptyBatch();
        for (uint256 i = 0; i < len;) {
            address operator = operatorList[i];
            if (operator == address(0)) revert ZeroAddress();
            operators[operator] = allowed;
            emit OperatorUpdated(operator, allowed);
            unchecked {
                ++i;
            }
        }
    }

    function addToBlacklist(bytes32 txHash) external onlyOperator {
        _add(txHash);
    }

    function batchAddToBlacklist(bytes32[] calldata txHashes) external onlyOperator {
        uint256 len = txHashes.length;
        if (len == 0) revert EmptyBatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len);
        for (uint256 i = 0; i < len;) {
            _add(txHashes[i]);
            unchecked {
                ++i;
            }
        }
    }

    function removeFromBlacklist(bytes32 txHash) external onlyOperator {
        _remove(txHash);
    }

    function batchRemoveFromBlacklist(bytes32[] calldata txHashes) external onlyOperator {
        uint256 len = txHashes.length;
        if (len == 0) revert EmptyBatch();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len);
        for (uint256 i = 0; i < len;) {
            _remove(txHashes[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns whether a single transaction source hash is currently banned.
    function isBlacklisted(bytes32 txHash) external view returns (bool) {
        return blacklisted[txHash];
    }

    /// @notice Returns the ban status of many hashes as a parallel array.
    function areBlacklisted(bytes32[] calldata txHashes) external view returns (bool[] memory results) {
        uint256 len = txHashes.length;
        results = new bool[](len);
        for (uint256 i = 0; i < len;) {
            results[i] = blacklisted[txHashes[i]];
            unchecked {
                ++i;
            }
        }
    }

    function _add(bytes32 txHash) internal {
        if (txHash == bytes32(0)) revert InvalidTxHash();
        if (!blacklisted[txHash]) {
            blacklisted[txHash] = true;
            blacklistCount += 1;
            emit TxBlacklisted(txHash, msg.sender);
        }
    }

    function _remove(bytes32 txHash) internal {
        if (blacklisted[txHash]) {
            blacklisted[txHash] = false;
            blacklistCount -= 1;
            emit TxUnblacklisted(txHash, msg.sender);
        }
    }
}
