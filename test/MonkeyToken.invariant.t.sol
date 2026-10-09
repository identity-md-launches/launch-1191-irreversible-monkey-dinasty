// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MonkeyToken} from "../src/MonkeyToken.sol";

/// @notice Drives MonkeyToken with six keyed actors (one of them the deployer that received the
///         whole supply) through every state-changing entry point, in random order with bounded
///         inputs, and keeps a ghost ledger of what each balance, allowance and nonce must be.
/// @dev Every handler either performs a call that must succeed and records its effect, or performs
///      a call that must fail and checks that nothing moved. The suite runs with fail-on-revert, so
///      an unexpected revert anywhere is itself a failure.
contract MonkeyHandler is CommonBase, StdAssertions, StdCheats, StdUtils {
    uint256 public constant INITIAL_SUPPLY = 67_676_767 * 1e18;
    uint256 internal constant ACTOR_COUNT = 6;

    MonkeyToken public token;
    address public deployer;
    address[] public actors;
    mapping(address => uint256) internal keyOf;

    // ---- ghost ledger -------------------------------------------------------------------------
    uint256 public ghost_burned;
    mapping(address => uint256) public ghost_in;
    mapping(address => uint256) public ghost_out;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    mapping(address => uint256) public ghost_nonce;

    // ---- call counters, for the summary and for sanity in the test ---------------------------
    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_approve;
    uint256 public calls_burn;
    uint256 public calls_burnFrom;
    uint256 public calls_permit;
    uint256 public rejected_overBalance;
    uint256 public rejected_zeroReceiver;
    uint256 public rejected_overAllowance;
    uint256 public rejected_permitReplay;
    uint256 public rejected_permitExpired;
    uint256 public rejected_permitForged;
    uint256 public rejected_adminCalls;

    constructor() {
        for (uint256 i = 1; i <= ACTOR_COUNT; ++i) {
            uint256 key = uint256(keccak256(abi.encode("monkey-actor", i)));
            address actor = vm.addr(key);
            actors.push(actor);
            keyOf[actor] = key;
        }
        deployer = actors[0];
        vm.prank(deployer);
        token = new MonkeyToken();
        ghost_in[deployer] = INITIAL_SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function expectedBalance(address actor) public view returns (uint256) {
        return ghost_in[actor] - ghost_out[actor];
    }

    // ---- successful paths ------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 supplyBefore = token.totalSupply();
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        ghost_out[from] += amount;
        ghost_in[to] += amount;
        calls_transfer++;

        assertEq(token.totalSupply(), supplyBefore, "transfer changed supply");
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender short by wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver got wrong amount");
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // One in eight approvals is unlimited, so the infinite-allowance path is exercised.
        if (amount % 8 == 0) amount = type(uint256).max;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");

        ghost_allowance[owner][spender] = amount;
        calls_approve++;
        assertEq(token.allowance(owner, spender), amount, "approve did not overwrite");
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        ghost_out[owner] += amount;
        ghost_in[to] += amount;
        if (allowed != type(uint256).max) ghost_allowance[owner][spender] = allowed - amount;
        calls_transferFrom++;

        assertEq(token.totalSupply(), supplyBefore, "transferFrom changed supply");
        assertEq(token.allowance(owner, spender), ghost_allowance[owner][spender], "allowance spent wrongly");
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 supplyBefore = token.totalSupply();
        uint256 before = token.balanceOf(from);

        vm.prank(from);
        token.burn(amount);

        ghost_out[from] += amount;
        ghost_burned += amount;
        calls_burn++;

        assertEq(token.totalSupply(), supplyBefore - amount, "burn changed supply by wrong amount");
        assertEq(token.balanceOf(from), before - amount, "burn changed balance by wrong amount");
    }

    function burnFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(spender);
        token.burnFrom(owner, amount);

        ghost_out[owner] += amount;
        ghost_burned += amount;
        if (allowed != type(uint256).max) ghost_allowance[owner][spender] = allowed - amount;
        calls_burnFrom++;

        assertEq(token.totalSupply(), supplyBefore - amount, "burnFrom changed supply by wrong amount");
    }

    /// @dev A valid permit relayed by a random actor, then the same signature replayed, which must fail.
    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 relayerSeed, uint256 value, uint256 ttl) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address relayer = _actor(relayerSeed);
        uint256 deadline = block.timestamp + bound(ttl, 0, 30 days);
        uint256 nonce = token.nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, value, nonce, deadline);

        vm.prank(relayer);
        token.permit(owner, spender, value, deadline, v, r, s);

        ghost_allowance[owner][spender] = value;
        ghost_nonce[owner] += 1;
        calls_permit++;
        assertEq(token.allowance(owner, spender), value, "permit set wrong allowance");
        assertEq(token.nonces(owner), nonce + 1, "permit did not consume the nonce");

        // Replay: the nonce moved, so the digest differs and the recovered signer is someone else.
        vm.prank(relayer);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, value, deadline, v, r, s);
        rejected_permitReplay++;
        assertEq(token.allowance(owner, spender), value, "replay changed the allowance");
        assertEq(token.nonces(owner), nonce + 1, "replay consumed a nonce");
    }

    function warp(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 7 days));
    }

    // ---- paths that must be refused, with nothing moved ----------------------------------------

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + bound(excess, 1, INITIAL_SUPPLY);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        token.transfer(to, amount);

        rejected_overBalance++;
        assertEq(token.balanceOf(from), balance, "refused transfer moved the balance");
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 balance = token.balanceOf(from);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);

        rejected_zeroReceiver++;
        assertEq(token.balanceOf(from), balance, "refused transfer moved the balance");
        assertEq(token.balanceOf(address(0)), 0, "the zero address received tokens");
    }

    function transferFromOverLimit(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        (uint256 amount, bytes memory expected) = _overLimit(owner, spender, allowed, balance, excess);

        vm.prank(spender);
        vm.expectRevert(expected);
        token.transferFrom(owner, to, amount);

        rejected_overAllowance++;
        assertEq(token.balanceOf(owner), balance, "refused transferFrom moved the balance");
        assertEq(token.allowance(owner, spender), allowed, "refused transferFrom spent allowance");
    }

    function burnFromOverLimit(uint256 spenderSeed, uint256 ownerSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        uint256 supply = token.totalSupply();
        (uint256 amount, bytes memory expected) = _overLimit(owner, spender, allowed, balance, excess);

        vm.prank(spender);
        vm.expectRevert(expected);
        token.burnFrom(owner, amount);

        rejected_overAllowance++;
        assertEq(token.totalSupply(), supply, "refused burnFrom changed supply");
        assertEq(token.balanceOf(owner), balance, "refused burnFrom moved the balance");
    }

    function permitExpired(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 past) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 deadline = bound(past, 0, block.timestamp - 1);
        uint256 nonce = token.nonces(owner);
        uint256 allowed = token.allowance(owner, spender);
        (uint8 v, bytes32 r, bytes32 s) = _sign(owner, spender, value, nonce, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, spender, value, deadline, v, r, s);

        rejected_permitExpired++;
        assertEq(token.nonces(owner), nonce, "expired permit consumed a nonce");
        assertEq(token.allowance(owner, spender), allowed, "expired permit changed the allowance");
    }

    /// @dev Signed by a different actor than the claimed owner: must be refused and leave no trace.
    function permitForged(uint256 ownerSeed, uint256 forgerSeed, uint256 spenderSeed, uint256 value) external {
        address owner = _actor(ownerSeed);
        address forger = _actor(forgerSeed);
        if (forger == owner) forger = actors[(_index(forgerSeed) + 1) % actors.length];
        address spender = _actor(spenderSeed);
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(owner);
        uint256 allowed = token.allowance(owner, spender);
        (uint8 v, bytes32 r, bytes32 s) = _signAs(forger, owner, spender, value, nonce, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, forger, owner));
        token.permit(owner, spender, value, deadline, v, r, s);

        rejected_permitForged++;
        assertEq(token.nonces(owner), nonce, "forged permit consumed a nonce");
        assertEq(token.allowance(owner, spender), allowed, "forged permit changed the allowance");
    }

    /// @dev Admin-style calls from any actor, including the deployer. None exists on this token, so
    ///      every one must fail to change the supply or any balance. The ledger invariants check the
    ///      balances; this handler checks the supply and that the call did not succeed.
    function adminCall(uint256 callerSeed, uint256 targetSeed, uint256 which) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        string[18] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "freeze(address)",
            "lock(address)",
            "seize(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)"
        ];
        string memory signature = signatures[bound(which, 0, signatures.length - 1)];
        uint256 supply = token.totalSupply();

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(signature, target, type(uint128).max));

        rejected_adminCalls++;
        assertFalse(ok, string.concat("unexpected function exists: ", signature));
        assertEq(token.totalSupply(), supply, "an admin-style call changed the supply");
    }

    // ---- helpers ------------------------------------------------------------------------------------

    /// @dev An amount that exceeds whichever of balance and allowance binds first, and the error
    ///      the token must raise for it. OpenZeppelin checks the allowance before the balance,
    ///      and an unlimited allowance is never checked at all. Never overflows: the base is at
    ///      most the owner's balance, which is at most the supply.
    function _overLimit(address owner, address spender, uint256 allowed, uint256 balance, uint256 excess)
        internal
        pure
        returns (uint256 amount, bytes memory expected)
    {
        uint256 base = balance < allowed ? balance : allowed;
        amount = base + bound(excess, 1, INITIAL_SUPPLY);
        if (allowed != type(uint256).max && amount > allowed) {
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        } else {
            expected = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount);
        }
    }

    function _index(uint256 seed) internal view returns (uint256) {
        return bound(seed, 0, actors.length - 1);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[_index(seed)];
    }

    function _sign(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        return _signAs(owner, owner, spender, value, nonce, deadline);
    }

    function _signAs(address signer, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(keyOf[signer], digest);
    }
}

/// @notice Invariants that must hold after every call sequence the handler can produce.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MonkeyTokenInvariantTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 67_676_767 * 1e18;

    MonkeyHandler internal handler;
    MonkeyToken internal token;

    function setUp() public {
        handler = new MonkeyHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = MonkeyHandler.transfer.selector;
        selectors[1] = MonkeyHandler.approve.selector;
        selectors[2] = MonkeyHandler.transferFrom.selector;
        selectors[3] = MonkeyHandler.burn.selector;
        selectors[4] = MonkeyHandler.burnFrom.selector;
        selectors[5] = MonkeyHandler.permit.selector;
        selectors[6] = MonkeyHandler.warp.selector;
        selectors[7] = MonkeyHandler.transferOverBalance.selector;
        selectors[8] = MonkeyHandler.transferToZeroAddress.selector;
        selectors[9] = MonkeyHandler.transferFromOverLimit.selector;
        selectors[10] = MonkeyHandler.burnFromOverLimit.selector;
        selectors[11] = MonkeyHandler.permitExpired.selector;
        selectors[12] = MonkeyHandler.permitForged.selector;
        selectors[13] = MonkeyHandler.adminCall.selector;
        selectors[14] = MonkeyHandler.transfer.selector; // weighted: transfers are the common case

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The fixed supply only ever shrinks, and only by what holders burned.
    function invariant_supplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY - handler.ghost_burned(), "supply != initial - burned");
        assertLe(token.totalSupply(), INITIAL_SUPPLY, "supply grew");
    }

    /// @dev What the token reports as supply is exactly what the actors hold between them.
    function invariant_supplyEqualsSumOfBalances() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances != supply");
    }

    /// @dev Each balance is exactly what flowed in minus what flowed out: no tax, no reflection,
    ///      no rounding, nothing moved by anyone but the holder or an approved spender.
    function invariant_balancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "balance != ledger");
        }
    }

    /// @dev Allowances are exactly what approve/permit set minus what transferFrom/burnFrom spent,
    ///      and an unlimited allowance is never decremented.
    function invariant_allowancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance != ledger"
                );
            }
        }
    }

    /// @dev One nonce per accepted permit; refused permits consume none.
    function invariant_noncesMatchAcceptedPermits() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertEq(token.nonces(actor), handler.ghost_nonce(actor), "nonce != accepted permits");
        }
    }

    function invariant_zeroAddressAndTokenHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "token contract holds tokens");
        assertEq(token.balanceOf(address(handler)), 0, "handler holds tokens");
    }

    function invariant_metadataIsImmutable() public view {
        assertEq(token.name(), "Irreversible Monkey Dinasty");
        assertEq(token.symbol(), "MONKEY");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), INITIAL_SUPPLY);
    }

    /// @dev Not a property of the token: a guard that the handler really exercised its paths, so a
    ///      green run cannot be vacuous. Checked once, at the end of each run.
    function afterInvariant() public view {
        uint256 exercised = handler.calls_transfer() + handler.calls_transferFrom() + handler.calls_approve()
            + handler.calls_burn() + handler.calls_burnFrom() + handler.calls_permit();
        uint256 rejected = handler.rejected_overBalance() + handler.rejected_zeroReceiver()
            + handler.rejected_overAllowance() + handler.rejected_permitReplay() + handler.rejected_permitExpired()
            + handler.rejected_permitForged() + handler.rejected_adminCalls();
        assertGt(exercised + rejected, 0, "the handler was never called");
    }
}
