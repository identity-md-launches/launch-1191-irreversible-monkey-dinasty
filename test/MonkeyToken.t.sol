// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {MonkeyToken} from "../src/MonkeyToken.sol";
import {DeployMonkeyToken} from "../script/DeployMonkeyToken.s.sol";

/// @notice Deploys the token from a contract, the way the launch factory does, so the tests can
///         check that `msg.sender` (not `tx.origin` or anything else) receives the supply.
contract FactoryStandIn {
    MonkeyToken public token;

    function launch() external returns (MonkeyToken) {
        token = new MonkeyToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract MonkeyTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 67_676_767 * 1e18;

    MonkeyToken internal token;
    FactoryStandIn internal factory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal signerKey = 0xA11CE;
    address internal signer = vm.addr(0xA11CE);

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        factory = new FactoryStandIn();
        token = factory.launch();
    }

    // ------------------------------------------------------------------
    // Metadata and supply
    // ------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Irreversible Monkey Dinasty");
        assertEq(token.symbol(), "MONKEY");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), token.name());
        assertEq(token.TOKEN_SYMBOL(), token.symbol());
    }

    function test_supplyConstantsAgree() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 67_676_767);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 67_676_767_000_000_000_000_000_000);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply");
        assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY, "deployer holds everything");
        assertEq(token.balanceOf(address(this)), 0, "the test (tx origin of the launch) got nothing");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), address(this), EXPECTED_SUPPLY);
        MonkeyToken fresh = new MonkeyToken();
        assertEq(fresh.balanceOf(address(this)), EXPECTED_SUPPLY);
    }

    function test_deployScriptMintsToCaller() public {
        DeployMonkeyToken deployer = new DeployMonkeyToken();
        MonkeyToken deployed = deployer.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(deployer)), EXPECTED_SUPPLY);
        assertEq(deployed.name(), "Irreversible Monkey Dinasty");
    }

    function test_eachDeploymentIsIndependent() public {
        MonkeyToken second = new MonkeyToken();
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(address(factory)), 0);
    }

    // ------------------------------------------------------------------
    // No mint path, no admin surface
    // ------------------------------------------------------------------

    function test_noMintOrAdminSelectorsExist() public {
        string[14] memory signatures = [
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
            "freeze(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], stranger, type(uint128).max);
            // From a stranger.
            vm.prank(stranger);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            // From the deployer, the only address a token would plausibly trust.
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(stranger), 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ------------------------------------------------------------------
    // Transfers: exact amounts, no tax, standard failures
    // ------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1234e18;
        assertTrue(factory.send(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY - amount);

        vm.prank(alice);
        assertTrue(token.transfer(bob, amount / 3));
        assertEq(token.balanceOf(bob), amount / 3);
        assertEq(token.balanceOf(alice), amount - amount / 3);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "transfers never change supply");
    }

    function test_transferEmitsEvent() public {
        factory.send(alice, 10e18);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, bob, 4e18);
        vm.prank(alice);
        token.transfer(bob, 4e18);
    }

    function test_transferWholeBalanceAndZero() public {
        factory.send(alice, 5e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 5e18));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 5e18);
        // Zero-value transfers are valid ERC-20 and must not revert.
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 5e18);
    }

    function test_launchFlowsArriveWhole() public {
        // 10% to a distributor, then claimed whole; 84% to a pool stand-in; 6% remainder.
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainder = 0x70bcBDE387539d95ffE6d43EDBf7C6AA2dA87A09;
        uint256 swarm = EXPECTED_SUPPLY * 1000 / 10_000;
        uint256 seed = EXPECTED_SUPPLY * 8400 / 10_000;
        uint256 rest = EXPECTED_SUPPLY - swarm - seed;

        assertTrue(factory.send(distributor, swarm));
        assertTrue(factory.send(pool, seed));
        assertTrue(factory.send(remainder, rest));
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(pool), seed);
        assertEq(token.balanceOf(remainder), rest);
        assertEq(token.balanceOf(address(factory)), 0);

        vm.prank(distributor);
        assertTrue(token.transfer(alice, swarm));
        assertEq(token.balanceOf(alice), swarm);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        factory.send(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 1e18 + 1));
        token.transfer(bob, 1e18 + 1);
    }

    function test_transferFromEmptyAccountReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        factory.send(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        assertTrue(factory.send(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(to), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------
    // Allowances
    // ------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        factory.send(alice, 100e18);
        vm.prank(alice);
        assertTrue(token.approve(bob, 60e18));
        assertEq(token.allowance(alice, bob), 60e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, stranger, 25e18));
        assertEq(token.balanceOf(stranger), 25e18);
        assertEq(token.balanceOf(alice), 75e18);
        assertEq(token.allowance(alice, bob), 35e18, "allowance is spent");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.send(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, stranger, 1e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        factory.send(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromRevertsOverAllowance() public {
        factory.send(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10e18, 11e18));
        token.transferFrom(alice, bob, 11e18);
    }

    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        factory.send(alice, 100e18);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(alice, address(factory), 1);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------
    // Burning: supply may shrink, only by the holder's own choice
    // ------------------------------------------------------------------

    function test_holderCanBurnOwnTokens() public {
        factory.send(alice, 10e18);
        vm.prank(alice);
        token.burn(4e18);
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - 4e18);
    }

    function test_burnMoreThanBalanceReverts() public {
        factory.send(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        token.burn(11e18);
    }

    function test_burnFromRequiresAllowance() public {
        factory.send(alice, 10e18);
        // Nobody, not even the deployer, can burn a holder's tokens without an allowance.
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1e18)
        );
        token.burnFrom(alice, 1e18);
        assertEq(token.balanceOf(alice), 10e18);

        vm.prank(alice);
        token.approve(bob, 3e18);
        vm.prank(bob);
        token.burnFrom(alice, 3e18);
        assertEq(token.balanceOf(alice), 7e18);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - 3e18);
    }

    function test_burnedSupplyNeverComesBack() public {
        factory.send(alice, 10e18);
        vm.prank(alice);
        token.burn(10e18);
        uint256 after_ = token.totalSupply();
        // A later deployer-side transfer cannot recreate it.
        factory.send(bob, 1e18);
        assertEq(token.totalSupply(), after_);
    }

    // ------------------------------------------------------------------
    // ERC-2612 permit
    // ------------------------------------------------------------------

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 7e18, 0, deadline));

        vm.prank(stranger); // anyone may relay a permit
        token.permit(signer, bob, 7e18, deadline, v, r, s);

        assertEq(token.allowance(signer, bob), 7e18);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitReplayReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 7e18, 0, deadline));
        token.permit(signer, bob, 7e18, deadline, v, r, s);

        // The nonce has moved on, so the same signature now recovers some other address.
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(signer, bob, 7e18, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 7e18, "allowance unchanged by the replay");
        assertEq(token.nonces(signer), 1);
    }

    function test_permitExpiredReverts() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _permitDigest(signer, bob, 7e18, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, bob, 7e18, deadline, v, r, s);
    }

    function test_permitWrongSignerReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 otherKey = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherKey, _permitDigest(signer, bob, 7e18, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(otherKey), signer));
        token.permit(signer, bob, 7e18, deadline, v, r, s);
    }

    function test_domainSeparatorUsesTokenName() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Irreversible Monkey Dinasty")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
        assertEq(IERC20Permit(address(token)).nonces(signer), 0);
    }
}
