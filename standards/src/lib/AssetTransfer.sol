// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.24;

/// @title AssetTransfer
/// @notice Moves the native coin (`asset == address(0)`) or an ERC-20, treating the token kinds
///         that exist in practice correctly: ones that return `true`, ones that return nothing
///         (USDT on Ethereum), and ones that revert. A call to an address with no code is a
///         failure, not a silent success — otherwise a mistyped token address would "pay".
library AssetTransfer {
    error AssetTransferFailed(address asset, address to, uint256 amount);

    function send(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{ value: amount }("");
            if (!ok) revert AssetTransferFailed(asset, to, amount);
            return;
        }
        _call(asset, abi.encodeWithSelector(0xa9059cbb, to, amount), to, amount);
    }

    /// @notice Pull `amount` of an ERC-20 from `from` and return what actually arrived, so a
    ///         fee-on-transfer token is credited with what the vault holds, not what was asked.
    function pull(address asset, address from, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) return 0;
        uint256 before = balanceOf(asset, address(this));
        _call(asset, abi.encodeWithSelector(0x23b872dd, from, address(this), amount), from, amount);
        received = balanceOf(asset, address(this)) - before;
    }

    function balanceOf(address asset, address who) internal view returns (uint256) {
        if (asset == address(0)) return who.balance;
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSelector(0x70a08231, who));
        if (!ok || data.length < 32) revert AssetTransferFailed(asset, who, 0);
        return abi.decode(data, (uint256));
    }

    function _call(address asset, bytes memory data, address party, uint256 amount) private {
        if (asset.code.length == 0) revert AssetTransferFailed(asset, party, amount);
        (bool ok, bytes memory ret) = asset.call(data);
        if (!ok) revert AssetTransferFailed(asset, party, amount);
        if (ret.length != 0) {
            if (ret.length < 32 || !abi.decode(ret, (bool))) {
                revert AssetTransferFailed(asset, party, amount);
            }
        }
    }
}
