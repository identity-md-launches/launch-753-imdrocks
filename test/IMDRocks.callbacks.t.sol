// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDRocks} from "src/IMDRocks.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PayoutProbe, BuyerProbe} from "./helpers/SaleActors.sol";

contract MutatingRockReceiver is IERC721Receiver {
    IMDRocks private immutable rocks;
    address private immutable destination;
    address private immutable operator;
    uint256 public callbacks;

    constructor(IMDRocks target, address recipient, address approved) {
        rocks = target;
        destination = recipient;
        operator = approved;
    }

    function purchase() external payable {
        rocks.buy{value: msg.value}();
    }

    function onERC721Received(address, address, uint256 number, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(rocks));
        ++callbacks;
        // Mutate a previously owned token, global approvals, and the new token.
        rocks.approve(operator, 0);
        rocks.setApprovalForAll(operator, true);
        rocks.transferFrom(address(this), destination, number);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// forge-config: default.fuzz.runs = 128
contract IMDRocksCallbackTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    IMDRocks private rocks;
    PayoutProbe private payout;

    function setUp() public {
        payout = new PayoutProbe();
        rocks = new IMDRocks(address(payout));
        payout.configure(rocks, false, false, false);
        vm.deal(ALICE, 10 ether);
        vm.deal(address(this), 10 ether);
    }

    function testFuzz_PayoutFailureAtAnySalePositionCanRetry(uint8 numberSeed) public {
        uint256 number = bound(numberSeed, 10, 99);
        _advanceTo(number);
        uint256 buyerBefore = ALICE.balance;
        uint256 reserveBefore = address(payout).balance;
        uint256 price = 10_000_000_000_000 * (1 + number * number);
        payout.configure(rocks, true, false, false);
        vm.expectRevert(IMDRocks.PayoutFailed.selector);
        vm.prank(ALICE);
        rocks.buy{value: price}();
        assertEq(ALICE.balance, buyerBefore);
        assertEq(address(payout).balance, reserveBefore);
        assertEq(rocks.balanceOf(ALICE), number - 10);
        _assertUnminted(number);

        payout.configure(rocks, false, false, false);
        vm.prank(ALICE);
        assertEq(rocks.buy{value: price}(), number);
        assertEq(rocks.nextRock(), number + 1);
        assertEq(rocks.ownerOf(number), ALICE);
        assertEq(address(payout).balance, reserveBefore + price);
        assertEq(ALICE.balance, buyerBefore - price);
        assertEq(address(rocks).balance, 0);
    }

    function test_PayoutFailureUnwindsCallbackTransfersApprovalsAndExternalState() public {
        MutatingRockReceiver receiver = new MutatingRockReceiver(rocks, BOB, ALICE);
        vm.prank(address(payout));
        rocks.transferFrom(address(payout), address(receiver), 0);
        uint256 initialBalance = address(this).balance;
        payout.configure(rocks, true, false, false);

        vm.expectRevert(IMDRocks.PayoutFailed.selector);
        receiver.purchase{value: 0.00101 ether}();
        _assertUnminted(10);
        assertEq(rocks.ownerOf(0), address(receiver));
        assertEq(rocks.getApproved(0), address(0));
        assertFalse(rocks.isApprovedForAll(address(receiver), ALICE));
        assertEq(rocks.balanceOf(BOB), 0);
        assertEq(rocks.balanceOf(address(receiver)), 1);
        assertEq(receiver.callbacks(), 0);
        assertEq(address(this).balance, initialBalance);
        assertEq(address(payout).balance, 0);

        // Retrying the identical callback proves its mutations executed and were rolled back.
        payout.configure(rocks, false, false, false);
        receiver.purchase{value: 0.00101 ether}();
        assertEq(rocks.ownerOf(10), BOB);
        assertEq(rocks.getApproved(0), ALICE);
        assertTrue(rocks.isApprovedForAll(address(receiver), ALICE));
        assertEq(receiver.callbacks(), 1);
        assertEq(payout.observedNext(), 11);
        assertEq(payout.observedOwner(), BOB);
        assertEq(address(payout).balance, 0.00101 ether);
        assertEq(address(this).balance, initialBalance - 0.00101 ether);
    }

    function test_BothCallbacksAttemptReentryAtLastRockAndNo101stMint() public {
        _advanceTo(99);
        BuyerProbe receiver = new BuyerProbe(rocks);
        receiver.configure(false, true, false, address(0));
        payout.configure(rocks, false, true, false);
        vm.deal(address(receiver), 1 ether);
        uint256 reserveBefore = address(payout).balance;
        assertEq(receiver.purchase{value: 0.09802 ether}(), 99);

        bytes memory guarded = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertTrue(receiver.attempted());
        assertTrue(payout.attempted());
        assertFalse(receiver.reentrySucceeded());
        assertFalse(payout.reentrySucceeded());
        assertEq(receiver.reentryResult(), guarded);
        assertEq(payout.reentryResult(), guarded);
        assertEq(receiver.observedNext(), 100);
        assertEq(payout.observedNext(), 100);
        assertEq(receiver.observedSupply(), 100);
        assertEq(payout.observedSupply(), 100);
        assertEq(rocks.ownerOf(99), address(receiver));
        assertEq(address(receiver).balance, 1 ether);
        assertEq(address(payout).balance, reserveBefore + 0.09802 ether);
        assertEq(rocks.nextRock(), 100);
        assertEq(rocks.totalSupply(), 100);

        vm.expectRevert(IMDRocks.SoldOut.selector);
        receiver.purchase{value: 0.10001 ether}();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 100));
        rocks.ownerOf(100);
        assertEq(address(rocks).balance, 0);
    }

    function test_LastRockFailuresDoNotLatchSoldOutOrReentrancyGuard() public {
        _advanceTo(99);
        BuyerProbe receiver = new BuyerProbe(rocks);
        uint256 reserveBefore = address(payout).balance;
        receiver.configure(true, false, false, address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        receiver.purchase{value: 0.09802 ether}();
        _assertUnminted(99);

        receiver.configure(false, false, false, BOB);
        payout.configure(rocks, true, false, false);
        vm.expectRevert(IMDRocks.PayoutFailed.selector);
        receiver.purchase{value: 0.09802 ether}();
        _assertUnminted(99);
        assertEq(rocks.balanceOf(BOB), 0);
        assertEq(address(payout).balance, reserveBefore);

        payout.configure(rocks, false, false, false);
        assertEq(receiver.purchase{value: 0.09802 ether}(), 99);
        assertEq(rocks.ownerOf(99), BOB);
        assertEq(rocks.nextRock(), 100);
        assertEq(rocks.totalSupply(), 100);
        assertEq(address(payout).balance, reserveBefore + 0.09802 ether);
        assertEq(address(rocks).balance, 0);
    }

    function _advanceTo(uint256 number) private {
        for (uint256 n = 10; n < number; ++n) {
            uint256 price = 10_000_000_000_000 * (1 + n * n);
            vm.prank(ALICE);
            rocks.buy{value: price}();
        }
    }

    function _assertUnminted(uint256 number) private {
        assertEq(rocks.nextRock(), number);
        assertEq(rocks.totalSupply(), number);
        assertEq(address(rocks).balance, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, number));
        rocks.ownerOf(number);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, number));
        rocks.tokenURI(number);
    }
}
