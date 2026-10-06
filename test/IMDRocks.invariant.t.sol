// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDRocks} from "../src/IMDRocks.sol";
import {BuyerProbe} from "./helpers/SaleActors.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RockHandler is Test {
    IMDRocks public immutable rocks;
    BuyerProbe public immutable receiver;
    address[4] public buyers = [address(0xA11CE), address(0xB0B), address(0xCA11), address(0xD00D)];
    uint256 public ghostNext = 10;
    uint256 public ghostPaid;
    address[100] public ghostOwner;
    address[100] public ghostApproval;
    mapping(address => uint256) public ghostBalance;
    mapping(address => uint256) public ghostSpent;
    mapping(address => mapping(address => bool)) public ghostOperator;

    constructor(IMDRocks target) {
        rocks = target;
        receiver = new BuyerProbe(target);
        vm.deal(address(receiver), 1 ether); // Enough to reach the guard at every price.
        vm.deal(address(this), 100 ether);
        for (uint256 i; i < buyers.length; ++i) {
            vm.deal(buyers[i], 100 ether);
        }
        address reserve = target.payout();
        ghostBalance[reserve] = 10;
        for (uint256 n; n < 10; ++n) {
            ghostOwner[n] = reserve;
        }
    }

    function purchase(uint8 who, bool correct, uint96 amount) public {
        uint256 next = ghostNext;
        uint256 price = _price(next);
        uint256 value = correct ? price : bound(uint256(amount), 0, 1 ether);
        address buyer = buyers[who % buyers.length];
        uint256 beforeBalance = buyer.balance;
        vm.prank(buyer);
        (bool success, bytes memory result) = address(rocks).call{value: value}(abi.encodeCall(rocks.buy, ()));
        assertEq(success, next < 100 && value == price);
        if (success) {
            assertEq(abi.decode(result, (uint256)), next);
            _recordPurchase(buyer, buyer, value);
        }
        assertEq(buyer.balance, beforeBalance - (success ? value : 0));
        assertEq(rocks.nextRock(), ghostNext);
    }

    /// @dev Multiple independent buy calls make sellout reachable within a fuzz sequence.
    function purchaseBatch(uint8 who, uint8 countSeed) external {
        uint256 count = bound(countSeed, 1, 12);
        for (uint256 i; i < count; ++i) {
            purchase(who, true, 0);
        }
    }

    function receiverPurchase(uint8 modeSeed, uint8 recipientSeed) external {
        uint256 mode = modeSeed % 5;
        uint256 price = _price(ghostNext);
        uint256 next = ghostNext;
        address recipient = mode == 4 ? buyers[recipientSeed % buyers.length] : address(receiver);
        receiver.configure(mode == 1, mode == 2 || mode == 3, mode == 3, mode == 4 ? recipient : address(0));
        uint256 beforeBalance = address(this).balance;
        (bool success, bytes memory result) =
            address(receiver).call{value: price}(abi.encodeCall(receiver.purchase, ()));
        assertEq(success, next < 100 && mode != 1 && mode != 3);
        if (success) {
            assertEq(abi.decode(result, (uint256)), next);
            assertEq(receiver.observedNext(), next + 1);
            assertEq(receiver.observedSupply(), next + 1);
            assertEq(receiver.observedOwner(), address(receiver));
            if (mode == 2) {
                assertTrue(receiver.attempted());
                assertFalse(receiver.reentrySucceeded());
                assertEq(
                    receiver.reentryResult(),
                    abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
                );
            }
            _recordPurchase(recipient, address(this), price);
        }
        assertEq(address(this).balance, beforeBalance - (success ? price : 0));
        assertEq(address(receiver).balance, 1 ether);
        assertEq(rocks.nextRock(), ghostNext);
    }

    function transfer(uint8 numberSeed, uint8 toSeed) external {
        uint256 number = bound(numberSeed, 0, ghostNext - 1);
        address owner = ghostOwner[number];
        address to = buyers[toSeed % buyers.length];
        vm.prank(owner);
        rocks.transferFrom(owner, to, number);
        _recordTransfer(number, to);
    }

    function approve(uint8 numberSeed, uint8 operatorSeed, bool all, bool enabled) external {
        uint256 number = bound(numberSeed, 0, ghostNext - 1);
        address owner = ghostOwner[number];
        uint256 index = operatorSeed % buyers.length;
        address operator = buyers[index];
        if (operator == owner) operator = buyers[(index + 1) % buyers.length];
        vm.prank(owner);
        if (all) {
            rocks.setApprovalForAll(operator, enabled);
            ghostOperator[owner][operator] = enabled;
        } else {
            address approved = enabled ? operator : address(0);
            rocks.approve(approved, number);
            ghostApproval[number] = approved;
        }
    }

    function transferAsOperator(uint8 numberSeed, uint8 callerSeed, uint8 toSeed) external {
        uint256 number = bound(numberSeed, 0, ghostNext - 1);
        address owner = ghostOwner[number];
        address caller = buyers[callerSeed % buyers.length];
        address to = buyers[toSeed % buyers.length];
        bool authorized = caller == owner || ghostApproval[number] == caller || ghostOperator[owner][caller];
        vm.prank(caller);
        (bool success,) = address(rocks).call(abi.encodeCall(rocks.transferFrom, (owner, to, number)));
        assertEq(success, authorized, "ERC721 authorization differs from model");
        if (success) _recordTransfer(number, to);
    }

    function directEther(uint8 who, uint96 amount, bool unknownSelector) external {
        address buyer = buyers[who % buyers.length];
        uint256 value = bound(uint256(amount), 0, 1 ether);
        uint256 beforeBalance = buyer.balance;
        vm.prank(buyer);
        (bool success,) = address(rocks).call{value: value}(unknownSelector ? bytes(hex"deadbeef") : bytes(""));
        assertFalse(success);
        assertEq(buyer.balance, beforeBalance);
    }

    function _recordPurchase(address recipient, address payer, uint256 value) private {
        ghostOwner[ghostNext++] = recipient;
        ++ghostBalance[recipient];
        ghostPaid += value;
        ghostSpent[payer] += value;
    }

    function _recordTransfer(uint256 number, address to) private {
        --ghostBalance[ghostOwner[number]];
        ++ghostBalance[to];
        ghostOwner[number] = to;
        ghostApproval[number] = address(0);
    }

    function _price(uint256 number) private pure returns (uint256) {
        return 10_000_000_000_000 * (1 + number * number);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract IMDRocksInvariantTest is Test {
    address private constant RESERVE = 0xE89eB4D7153958F9436E2c3fe30D6F2024404cB0;
    IMDRocks private rocks;
    RockHandler private handler;
    uint256 private startingPayoutBalance;

    function setUp() public {
        rocks = new IMDRocks(RESERVE);
        handler = new RockHandler(rocks);
        startingPayoutBalance = RESERVE.balance;
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = RockHandler.purchase.selector;
        selectors[1] = RockHandler.transfer.selector;
        selectors[2] = RockHandler.purchaseBatch.selector;
        selectors[3] = RockHandler.receiverPurchase.selector;
        selectors[4] = RockHandler.approve.selector;
        selectors[5] = RockHandler.transferAsOperator.selector;
        selectors[6] = RockHandler.directEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SequentialBoundedSupplyOwnershipAndPayments() public view {
        uint256 next = rocks.nextRock();
        assertGe(next, 10);
        assertLe(next, 100);
        assertEq(next, handler.ghostNext(), "Sale counter differs from successful purchases");
        assertEq(rocks.totalSupply(), next);
        assertEq(address(rocks).balance, 0);
        address receiver = address(handler.receiver());
        uint256 balances = rocks.balanceOf(RESERVE) + rocks.balanceOf(receiver);
        _assertAccount(RESERVE);
        _assertAccount(receiver);
        assertEq(address(handler).balance + handler.ghostSpent(address(handler)), 100 ether);
        assertEq(receiver.balance, 1 ether);
        for (uint256 i; i < 4; ++i) {
            address buyer = handler.buyers(i);
            _assertAccount(buyer);
            balances += rocks.balanceOf(buyer);
            assertEq(buyer.balance + handler.ghostSpent(buyer), 100 ether);
        }
        assertEq(balances, next);
        uint256 expectedPaid;
        for (uint256 n; n < next; ++n) {
            address owner = rocks.ownerOf(n);
            assertEq(owner, handler.ghostOwner(n), "Wrong token owner");
            assertEq(rocks.getApproved(n), handler.ghostApproval(n), "Wrong token approval");
            if (n >= 10) expectedPaid += 10_000_000_000_000 * (1 + n * n);
        }
        assertEq(RESERVE.balance - startingPayoutBalance, expectedPaid);
        assertEq(expectedPaid, handler.ghostPaid());
        (bool exists,) = address(rocks).staticcall(abi.encodeCall(rocks.ownerOf, (next)));
        assertFalse(exists);
    }

    function _assertAccount(address account) private view {
        assertEq(rocks.balanceOf(account), handler.ghostBalance(account), "Wrong individual NFT balance");
        for (uint256 i; i < 4; ++i) {
            address operator = handler.buyers(i);
            assertEq(rocks.isApprovedForAll(account, operator), handler.ghostOperator(account, operator));
        }
    }

    /// @dev Guarantees that the same handler assertions exercise each branch even before fuzzing.
    function test_HandlerSequenceReachesSelloutAndPreservesApprovals() public {
        handler.receiverPurchase(1, 0); // Reject NFT.
        handler.receiverPurchase(3, 0); // Propagate reentry failure.
        handler.receiverPurchase(2, 0); // Catch reentry failure.
        handler.receiverPurchase(4, 1); // Transfer newly minted NFT in callback.
        handler.approve(0, 0, false, true);
        handler.transferAsOperator(0, 0, 1);
        handler.transferAsOperator(0, 0, 2); // Stale approval.
        handler.approve(0, 2, true, true);
        handler.transferAsOperator(0, 2, 1); // Authorized self-transfer.
        handler.approve(0, 2, true, false);
        handler.transferAsOperator(0, 2, 3); // Revoked operator.
        for (uint256 i; i < 8; ++i) {
            handler.purchaseBatch(0, 12);
        }
        assertEq(handler.ghostNext(), 100);
        handler.purchase(1, true, 0);
        handler.receiverPurchase(0, 0);
        handler.transfer(99, 3);
        handler.directEther(0, 1, false);
        invariant_SequentialBoundedSupplyOwnershipAndPayments();
    }
}
