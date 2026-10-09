// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MonkeyToken} from "../src/MonkeyToken.sol";

/// @notice Deploys through CREATE2 the way the launch factory does, so the tests can check that
///         the deploying contract (not the transaction origin) receives the supply at the address
///         anyone can predict from the creation code and salt.
contract Create2Deployer {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }
}

/// @notice Edge inputs, boundary values and failure paths beyond the suite in MonkeyToken.t.sol:
///         zero, one wei, the whole supply, the maximum, the same call twice, callers who are not
///         who the code assumed, malformed and malleable signatures, and cross-chain replay.
/// forge-config: default.fuzz.runs = 1000
contract MonkeyTokenEdgeTest is Test {
    uint256 internal constant SUPPLY = 67_676_767 * 1e18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    MonkeyToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal ownerKey = 0xC0FFEE;
    address internal owner;

    function setUp() public {
        owner = vm.addr(ownerKey);
        vm.prank(deployer);
        token = new MonkeyToken();
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(deployer);
        token.transfer(to, amount);
    }

    function _digest(address owner_, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    // ------------------------------------------------------------------
    // Supply and deployment
    // ------------------------------------------------------------------

    function test_supplyIsExactlyTheRequestedFigure() public view {
        // 67,676,767 whole tokens, 18 decimals, as the requester wrote it.
        assertEq(token.totalSupply(), 67_676_767_000_000_000_000_000_000);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 67_676_767, "whole-token count");
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0, "no fractional dust in the supply");
        assertEq(vm.toString(token.totalSupply()), "67676767000000000000000000", "manifest minor units");
    }

    function test_supplyGoesToMsgSenderNotTxOrigin() public {
        address origin = makeAddr("origin");
        address sender = makeAddr("sender");
        vm.prank(sender, origin);
        MonkeyToken fresh = new MonkeyToken();
        assertEq(fresh.balanceOf(sender), SUPPLY, "msg.sender holds the supply");
        assertEq(fresh.balanceOf(origin), 0, "tx.origin holds nothing");
    }

    function test_create2DeploymentMintsToTheDeployingContract() public {
        Create2Deployer factory = new Create2Deployer();
        bytes memory code = type(MonkeyToken).creationCode;
        bytes32 salt = bytes32(uint256(7));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );

        vm.prank(alice, alice); // an EOA drives the factory, as the launch would
        address deployed = factory.deploy(code, salt);

        assertEq(deployed, predicted, "address is predictable from code and salt");
        MonkeyToken launched = MonkeyToken(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "the factory holds everything");
        assertEq(launched.balanceOf(alice), 0, "the driver holds nothing");
        assertEq(launched.balanceOf(deployed), 0, "the token holds nothing");
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        // Appending arguments the constructor does not declare must not change who gets the supply
        // or how much; the floor deploys the code with the manifest's (empty) argument list.
        Create2Deployer factory = new Create2Deployer();
        address deployed = factory.deploy(type(MonkeyToken).creationCode, bytes32(0));
        assertEq(MonkeyToken(deployed).balanceOf(address(factory)), SUPPLY);
    }

    function test_sameSaltCannotDeployTwice() public {
        Create2Deployer factory = new Create2Deployer();
        factory.deploy(type(MonkeyToken).creationCode, bytes32(uint256(1)));
        vm.expectRevert();
        factory.deploy(type(MonkeyToken).creationCode, bytes32(uint256(1)));
    }

    function test_tokenHasNoReceiveOrFallback() public {
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "plain ETH transfer must be refused");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "unknown selector must be refused");
        assertEq(address(token).balance, 0);
    }

    // ------------------------------------------------------------------
    // Transfers at the boundaries
    // ------------------------------------------------------------------

    function test_transferOneWei() public {
        _give(alice, 1);
        assertEq(token.balanceOf(alice), 1);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_transferEntireSupplyInOneCall() public {
        _give(alice, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferSupplyPlusOneRevertsEvenForDeployer() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferMaxUintReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_selfTransferLeavesBalanceUnchanged() public {
        _give(alice, 10e18);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 10e18));
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferOverBalanceReverts() public {
        _give(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.transfer(alice, 10e18 + 1);
    }

    function test_zeroTransferFromEmptyAccountSucceedsAndEmits() public {
        assertEq(token.balanceOf(carol), 0);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(carol, bob, 0);
        vm.prank(carol);
        assertTrue(token.transfer(bob, 0));
    }

    function test_zeroTransferToZeroAddressStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferToTokenContractSucceedsAndIsUnrecoverable() public {
        // Documented behaviour: there is no admin and no rescue function, so tokens sent to the
        // token's own address are stuck. The transfer itself is a valid ERC-20 transfer.
        _give(alice, 1e18);
        vm.prank(alice);
        assertTrue(token.transfer(address(token), 1e18));
        assertEq(token.balanceOf(address(token)), 1e18);
        // Nobody can spend them: the contract never approves anyone.
        assertEq(token.allowance(address(token), deployer), 0);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1e18));
        token.transferFrom(address(token), deployer, 1e18);
    }

    function test_sameTransferTwiceSpendsTwice() public {
        _give(alice, 2e18);
        vm.startPrank(alice);
        token.transfer(bob, 1e18);
        token.transfer(bob, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1e18));
        token.transfer(bob, 1e18);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 2e18);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 start, uint256 amount) public {
        start = bound(start, 0, SUPPLY);
        amount = bound(amount, 0, start);
        _give(alice, start);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), start);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitTransferEqualsSingleTransfer(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        MonkeyToken other;
        vm.prank(deployer);
        other = new MonkeyToken();

        vm.startPrank(deployer);
        token.transfer(alice, total);
        other.transfer(alice, first);
        other.transfer(alice, total - first);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), other.balanceOf(alice), "a split delivers the same as one call");
        assertEq(token.balanceOf(deployer), other.balanceOf(deployer));
    }

    function testFuzz_anyAmountOverBalanceRevertsWithExactError(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - balance);
        _give(alice, balance);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + excess)
        );
        token.transfer(bob, balance + excess);
        assertEq(token.balanceOf(alice), balance, "a refused transfer moved nothing");
    }

    function testFuzz_noCallerButTheHolderCanMoveAHolderBalance(address caller, uint256 amount) public {
        _give(alice, 100e18);
        amount = bound(amount, 1, 100e18);
        vm.assume(caller != alice);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, 0, amount));
        token.transferFrom(alice, caller, amount);
        assertEq(token.balanceOf(alice), 100e18);
    }

    // ------------------------------------------------------------------
    // Allowances at the boundaries
    // ------------------------------------------------------------------

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(alice);
        token.approve(bob, 5e18);
        token.approve(bob, 2e18);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 2e18, "second approve replaces the first");
        vm.prank(alice);
        token.approve(bob, 0);
        assertEq(token.allowance(alice, bob), 0, "approve zero clears");
    }

    function test_approveDoesNotRequireABalance() public {
        assertEq(token.balanceOf(carol), 0);
        vm.prank(carol);
        assertTrue(token.approve(bob, SUPPLY));
        assertEq(token.allowance(carol, bob), SUPPLY);
        // The allowance is useless without a balance.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, 1));
        token.transferFrom(carol, bob, 1);
    }

    function test_transferFromWithAllowanceButNoBalanceRevertsOnBalance() public {
        _give(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 5e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        token.transferFrom(alice, carol, 2e18);
        assertEq(token.allowance(alice, bob), 5e18, "allowance not spent on a failed pull");
    }

    function test_transferFromSelfStillNeedsAllowance() public {
        _give(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromExactAllowanceZeroesIt() public {
        _give(alice, 3e18);
        vm.prank(alice);
        token.approve(bob, 3e18);
        vm.prank(bob);
        token.transferFrom(alice, carol, 3e18);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_maxMinusOneAllowanceIsDecremented() public {
        _give(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, 1e18);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1 - 1e18, "only exactly max is infinite");
    }

    function test_transferFromEmitsTransferButNoApprovalEvent() public {
        _give(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 1e18);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), carol);
        assertEq(abi.decode(logs[0].data, (uint256)), 1e18);
    }

    function test_approveEmitsApproval() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(alice, bob, 9);
        vm.prank(alice);
        token.approve(bob, 9);
    }

    function testFuzz_transferFromSpendsExactlyTheAmount(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, type(uint256).max - 1);
        amount = bound(amount, 0, allowance < SUPPLY ? allowance : SUPPLY);
        _give(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowance);
        vm.prank(bob);
        token.transferFrom(alice, carol, amount);
        assertEq(token.allowance(alice, bob), allowance - amount);
        assertEq(token.balanceOf(carol), amount);
        assertEq(token.balanceOf(alice), SUPPLY - amount);
    }

    // ------------------------------------------------------------------
    // Burning at the boundaries
    // ------------------------------------------------------------------

    function test_burnZeroIsANoOp() public {
        _give(alice, 1e18);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(0), 0);
        vm.prank(alice);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_burnFromEmptyAccountReverts() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, 1));
        token.burn(1);
    }

    function test_deployerCanBurnTheWholeSupply() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, address(0), SUPPLY);
        vm.prank(deployer);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(deployer), 0);
        // A dead token stays dead: nothing can mint it back, and transfers of zero still work.
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 0));
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(alice, 1);
    }

    function test_burnFromWithInfiniteAllowanceKeepsIt() public {
        _give(alice, 5e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.burnFrom(alice, 2e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY - 2e18);
    }

    function test_burnFromOverBalanceWithEnoughAllowanceRevertsOnBalance() public {
        _give(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        token.burnFrom(alice, 2e18);
        assertEq(token.allowance(alice, bob), 10e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnFromSelfNeedsSelfAllowance() public {
        _give(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.burnFrom(alice, 1);
    }

    function testFuzz_burnReducesSupplyAndBalanceExactly(uint256 held, uint256 burned) public {
        held = bound(held, 0, SUPPLY);
        burned = bound(burned, 0, held);
        _give(alice, held);
        vm.prank(alice);
        token.burn(burned);
        assertEq(token.balanceOf(alice), held - burned);
        assertEq(token.totalSupply(), SUPPLY - burned);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice), token.totalSupply(), "supply == sum of holders");
    }

    function testFuzz_burnOverBalanceAlwaysReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        _give(alice, held);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + excess)
        );
        token.burn(held + excess);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------
    // Permit: boundaries, malformed signatures, replay across chains
    // ------------------------------------------------------------------

    function test_permitAtExactDeadlineIsAccepted() public {
        uint256 deadline = block.timestamp; // not yet expired: only timestamp > deadline fails
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, deadline));
        token.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 1e18);
    }

    function test_permitOneSecondPastDeadlineReverts() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, bob, 1e18, deadline, v, r, s);
        assertEq(token.nonces(owner), 0, "no nonce consumed");
    }

    function test_permitMaxDeadlineAndMaxValue() public {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, _digest(owner, bob, type(uint256).max, 0, type(uint256).max));
        token.permit(owner, bob, type(uint256).max, type(uint256).max, v, r, s);
        assertEq(token.allowance(owner, bob), type(uint256).max);
        // ...and it behaves as an infinite allowance.
        _give(owner, 1e18);
        vm.prank(bob);
        token.transferFrom(owner, carol, 1e18);
        assertEq(token.allowance(owner, bob), type(uint256).max);
    }

    function test_permitZeroValueClearsAllowance() public {
        vm.prank(owner);
        token.approve(bob, 5e18);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 0, 0, block.timestamp));
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(owner, bob, 0);
        token.permit(owner, bob, 0, block.timestamp, v, r, s);
        assertEq(token.allowance(owner, bob), 0);
        assertEq(token.nonces(owner), 1);
    }

    function test_permitToZeroSpenderReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, address(0), 1, 0, block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1, block.timestamp, v, r, s);
    }

    function test_permitForZeroOwnerReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(address(0), bob, 1, 0, block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, owner, address(0)));
        token.permit(address(0), bob, 1, block.timestamp, v, r, s);
        assertEq(token.allowance(address(0), bob), 0);
    }

    function test_permitWithTamperedValueReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, block.timestamp));
        // The relayer submits a bigger value than was signed: recovers to a stranger.
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, bob, 2e18, block.timestamp, v, r, s);
        // ...or a different spender.
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, carol, 1e18, block.timestamp, v, r, s);
        assertEq(token.allowance(owner, bob), 0);
        assertEq(token.allowance(owner, carol), 0);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitWithWrongNonceReverts() public {
        // Signed for nonce 1 while the owner's nonce is 0: unusable now.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 1, block.timestamp));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, bob, 1e18, block.timestamp, v, r, s);
        // After a permit at nonce 0 it becomes valid: nonces are strictly sequential.
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(ownerKey, _digest(owner, carol, 7, 0, block.timestamp));
        token.permit(owner, carol, 7, block.timestamp, v0, r0, s0);
        token.permit(owner, bob, 1e18, block.timestamp, v, r, s);
        assertEq(token.nonces(owner), 2);
        assertEq(token.allowance(owner, bob), 1e18);
    }

    function test_permitMalleableSignatureReverts() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, block.timestamp));
        // Flip into the upper half of the curve order: same message, rejected as malleable.
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(uint256(n) - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        token.permit(owner, bob, 1e18, block.timestamp, vFlip, r, sHigh);
        assertEq(token.nonces(owner), 0);
    }

    function test_permitInvalidVReverts() public {
        (, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, block.timestamp));
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, bob, 1e18, block.timestamp, 29, r, s);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, bob, 1e18, block.timestamp, 0, r, s);
    }

    function test_permitAllZeroSignatureReverts() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, bob, 1e18, block.timestamp, 27, bytes32(0), bytes32(0));
        assertEq(token.allowance(owner, bob), 0);
    }

    function test_permitCannotBeReplayedOnAnotherChain() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, type(uint256).max));
        bytes32 homeSeparator = token.DOMAIN_SEPARATOR();
        uint256 homeChain = block.chainid;

        vm.chainId(homeChain + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != homeSeparator, "separator is chain-bound");
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, bob, 1e18, type(uint256).max, v, r, s);
        assertEq(token.nonces(owner), 0);

        vm.chainId(homeChain);
        assertEq(token.DOMAIN_SEPARATOR(), homeSeparator);
        token.permit(owner, bob, 1e18, type(uint256).max, v, r, s);
        assertEq(token.allowance(owner, bob), 1e18);
    }

    function test_permitSignatureIsBoundToThisTokenInstance() public {
        vm.prank(deployer);
        MonkeyToken twin = new MonkeyToken();
        assertTrue(twin.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR(), "separators differ by address");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, block.timestamp));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        twin.permit(owner, bob, 1e18, block.timestamp, v, r, s);
        assertEq(twin.allowance(owner, bob), 0);
    }

    function test_permitDoesNotMoveTokensOnlyApproves() public {
        _give(owner, 1e18);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(owner, bob, 1e18, 0, block.timestamp));
        token.permit(owner, bob, 1e18, block.timestamp, v, r, s);
        assertEq(token.balanceOf(owner), 1e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_eip5267DomainFields() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = IERC5267(address(token)).eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "Irreversible Monkey Dinasty");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function testFuzz_permitFromAnyKeyForAnySpenderAndValue(uint248 rawKey, address spender, uint256 value, uint64 ttl)
        public
    {
        uint256 key = bound(uint256(rawKey), 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(spender != address(0));
        address signer = vm.addr(key);
        uint256 deadline = block.timestamp + ttl;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(signer, spender, value, 0, deadline));

        vm.prank(carol); // any relayer
        token.permit(signer, spender, value, deadline, v, r, s);
        assertEq(token.allowance(signer, spender), value);
        assertEq(token.nonces(signer), 1);

        // Second use of the same signature is always refused.
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(signer, spender, value, deadline, v, r, s);
    }

    function testFuzz_permitByAnyoneButTheOwnerIsRefused(uint248 rawKey, uint256 value) public {
        uint256 forgerKey =
            bound(uint256(rawKey), 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(forgerKey != ownerKey);
        address forger = vm.addr(forgerKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(forgerKey, _digest(owner, bob, value, 0, block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, forger, owner));
        token.permit(owner, bob, value, block.timestamp, v, r, s);
        assertEq(token.allowance(owner, bob), 0);
        assertEq(token.nonces(owner), 0);
    }

    // ------------------------------------------------------------------
    // Launch floor rehearsal: the privileged-call list from the protected test, in one sequence
    // ------------------------------------------------------------------

    function test_privilegedCallsFromDeployerNeverFreezeOrMoveAHolder() public {
        _give(alice, SUPPLY / 1000);
        uint256 held = token.balanceOf(alice);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        (bool moved,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, deployer, 1));
        assertFalse(moved);
        assertEq(token.balanceOf(alice), held);
        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
