// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDRocks} from "../src/IMDRocks.sol";

contract RockHandler is Test {
    IMDRocks public immutable rocks;
    address[4] public buyers = [address(0xA11CE), address(0xB0B), address(0xCA11), address(0xD00D)];

    constructor(IMDRocks target) {
        rocks = target;
        for (uint256 i; i < buyers.length; ++i) {
            vm.deal(buyers[i], 100 ether);
        }
    }

    function purchase(uint8 who, bool correct, uint96 amount) external {
        uint256 next = rocks.nextRock();
        uint256 price = next < 100 ? rocks.priceOf(next) : 0;
        uint256 value = correct ? price : uint256(amount) % 1 ether;
        address buyer = buyers[who % buyers.length];
        vm.prank(buyer);
        (bool success,) = address(rocks).call{value: value}(abi.encodeCall(rocks.buy, ()));
        assertEq(success, next < 100 && value == price);
        assertEq(rocks.nextRock(), next + (success ? 1 : 0));
    }

    function transfer(uint8 numberSeed, uint8 toSeed) external {
        uint256 number = uint256(numberSeed) % rocks.nextRock();
        address owner = rocks.ownerOf(number);
        address to = buyers[toSeed % buyers.length];
        vm.prank(owner);
        rocks.transferFrom(owner, to, number);
    }
}

contract IMDRocksInvariantTest is Test {
    address private constant RESERVE = 0xE89eB4D7153958F9436E2c3fe30D6F2024404cB0;
    IMDRocks private rocks;
    RockHandler private handler;
    uint256 private startingPayoutBalance;

    function setUp() public {
        rocks = new IMDRocks(RESERVE);
        handler = new RockHandler(rocks);
        startingPayoutBalance = RESERVE.balance;
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = RockHandler.purchase.selector;
        selectors[1] = RockHandler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SequentialBoundedSupplyOwnershipAndPayments() public view {
        uint256 next = rocks.nextRock();
        assertGe(next, 10);
        assertLe(next, 100);
        assertEq(rocks.totalSupply(), next);
        assertEq(address(rocks).balance, 0);
        uint256 balances = rocks.balanceOf(RESERVE);
        for (uint256 i; i < 4; ++i) {
            balances += rocks.balanceOf(handler.buyers(i));
        }
        assertEq(balances, next);
        uint256 expectedPaid;
        for (uint256 n; n < next; ++n) {
            address owner = rocks.ownerOf(n);
            bool known = owner == RESERVE;
            for (uint256 i; i < 4; ++i) {
                known = known || owner == handler.buyers(i);
            }
            assertTrue(known);
            if (n >= 10) expectedPaid += 10_000_000_000_000 * (1 + n * n);
        }
        assertEq(RESERVE.balance - startingPayoutBalance, expectedPaid);
        (bool exists,) = address(rocks).staticcall(abi.encodeCall(rocks.ownerOf, (next)));
        assertFalse(exists);
    }
}
