// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Irreversible Monkey Dinasty (MONKEY)
/// @notice A fixed-supply ERC-20. The whole supply of 67,676,767 MONKEY (18 decimals) is minted
///         once, in the constructor, to the deployer (`msg.sender`). Nothing can mint afterwards.
/// @dev Design choices, in order of importance to the launch:
///      - No owner, no admin, no pause, no blocklist, no upgrade path. There is no privileged
///        address at all, so nobody can move or freeze a holder's balance.
///      - No fee, tax, or burn on transfer: every transfer delivers exactly the amount sent, so
///        the launch flows (factory -> distributor, factory -> pool, pool <-> traders) move exactly
///        what they say.
///      - Supply can only shrink: holders may burn their own tokens (ERC20Burnable), and
///        `burnFrom` only spends an allowance the holder granted. Supply never grows.
///      - ERC-2612 `permit` for gasless approvals, as in OpenZeppelin's ERC20Permit.
///      The constructor takes no arguments and calls no other contract, so the launch can deploy
///      it on an empty chain.
contract MonkeyToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice The token's human-readable name, exactly as requested.
    string public constant TOKEN_NAME = "Irreversible Monkey Dinasty";

    /// @notice The token's ticker symbol.
    string public constant TOKEN_SYMBOL = "MONKEY";

    /// @notice Whole-token supply before decimals are applied.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 67_676_767;

    /// @notice The complete, fixed supply in minor units (18 decimals): 67,676,767 * 1e18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** 18;

    /// @notice Mints the full supply to the deployer once. No other mint path exists.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
