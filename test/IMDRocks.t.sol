// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IMDRocks} from "../src/IMDRocks.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DeploymentFactory, PayoutProbe, BuyerProbe, NonReceiverBuyer, ForcedEther} from "./helpers/SaleActors.sol";

contract IMDRocksTest is Test {
    address internal constant RESERVE = 0xE89eB4D7153958F9436E2c3fe30D6F2024404cB0;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    IMDRocks internal rocks;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function setUp() public {
        rocks = new DeploymentFactory().deploy(RESERVE);
        vm.deal(ALICE, 20 ether);
        vm.deal(BOB, 20 ether);
    }

    function test_ConstructorReservesAndConstants() public view {
        assertEq(rocks.name(), "IMDRocks");
        assertEq(rocks.symbol(), "IMDROCK");
        assertEq(rocks.NAME(), rocks.name());
        assertEq(rocks.SYMBOL(), rocks.symbol());
        assertEq(rocks.MAX_SUPPLY(), 100);
        assertEq(rocks.nextRock(), 10);
        assertEq(rocks.totalSupply(), 10);
        assertEq(rocks.payout(), RESERVE);
        assertEq(rocks.balanceOf(RESERVE), 10);
        assertEq(rocks.balanceOf(address(this)), 0);
        for (uint256 n; n < 10; ++n) {
            assertEq(rocks.ownerOf(n), RESERVE);
        }
    }

    function test_ConstructorEmitsTenIndividualTransfers() public {
        DeploymentFactory factory = new DeploymentFactory();
        vm.recordLogs();
        IMDRocks deployed = factory.deploy(RESERVE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 10);
        for (uint256 n; n < 10; ++n) {
            assertEq(logs[n].emitter, address(deployed));
            assertEq(logs[n].topics.length, 4);
            assertEq(logs[n].topics[0], keccak256("Transfer(address,address,uint256)"));
            assertEq(logs[n].topics[1], bytes32(0));
            assertEq(logs[n].topics[2], bytes32(uint256(uint160(RESERVE))));
            assertEq(logs[n].topics[3], bytes32(n));
            assertEq(logs[n].data.length, 0);
        }
        assertEq(deployed.balanceOf(address(factory)), 0);
    }

    function test_InvalidPayoutRejected() public {
        vm.expectRevert(IMDRocks.InvalidPayout.selector);
        new IMDRocks(address(0));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(IMDRocks.InvalidPayout.selector);
        new IMDRocks(predicted);
    }

    function test_PricesForEveryRock() public view {
        for (uint256 n; n < 100; ++n) {
            assertEq(rocks.priceOf(n), 10_000_000_000_000 * (1 + n * n));
        }
        assertEq(rocks.priceOf(0), 0.00001 ether);
        assertEq(rocks.priceOf(10), 0.00101 ether);
        assertEq(rocks.priceOf(99), 0.09802 ether);
    }

    function testFuzz_InvalidNumbersRevertBeforeArithmetic(uint256 n) public {
        n = bound(n, 100, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IMDRocks.InvalidRock.selector, n));
        rocks.priceOf(n);
        vm.expectRevert(abi.encodeWithSelector(IMDRocks.InvalidRock.selector, n));
        rocks.imageOf(n);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, n));
        rocks.tokenURI(n);
    }

    function test_EntireSaleInOrderExactPayoutAndNoWalletLimit() public {
        uint256 initialBalance = RESERVE.balance;
        uint256 paid;
        for (uint256 n = 10; n < 100; ++n) {
            uint256 price = rocks.priceOf(n);
            uint256 beforeBalance = RESERVE.balance;
            vm.expectEmit(true, true, true, true, address(rocks));
            emit Transfer(address(0), ALICE, n);
            vm.prank(ALICE);
            assertEq(rocks.buy{value: price}(), n);
            paid += price;
            assertEq(RESERVE.balance - beforeBalance, price);
            assertEq(address(rocks).balance, 0);
            assertEq(rocks.nextRock(), n + 1);
            assertEq(rocks.totalSupply(), n + 1);
            assertEq(rocks.ownerOf(n), ALICE);
            assertEq(rocks.balanceOf(ALICE), n - 9);
        }
        assertEq(RESERVE.balance - initialBalance, paid);
        assertEq(paid, 3.28155 ether);
        assertEq(rocks.totalSupply(), 100);
        vm.expectRevert(IMDRocks.SoldOut.selector);
        vm.prank(ALICE);
        rocks.buy{value: 0.10001 ether}();
        vm.expectRevert(IMDRocks.SoldOut.selector);
        rocks.buy();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 100));
        rocks.ownerOf(100);
        assertEq(address(rocks).balance, 0);
    }

    function test_OneWeiUnderAndOverAtEverySalePosition() public {
        for (uint256 n = 10; n < 100; ++n) {
            uint256 price = rocks.priceOf(n);
            _expectWrongPayment(price - 1, price);
            _expectWrongPayment(price + 1, price);
            assertEq(rocks.nextRock(), n);
            assertEq(rocks.totalSupply(), n);
            _buyAs(ALICE);
        }
    }

    function testFuzz_InexactPaymentReverts(uint96 value) public {
        uint256 price = rocks.priceOf(10);
        vm.assume(value != price);
        vm.deal(ALICE, value);
        _expectWrongPayment(value, price);
        assertEq(rocks.nextRock(), 10);
        assertEq(rocks.totalSupply(), 10);
    }

    function test_OutOfOrderDuplicateAndStaleTransactionsFail() public {
        uint256 firstPrice = rocks.priceOf(10);
        _expectWrongPayment(rocks.priceOf(9), firstPrice);
        _expectWrongPayment(rocks.priceOf(11), firstPrice);
        _expectWrongPayment(rocks.priceOf(99), firstPrice);
        _buyAs(ALICE);
        // A second transaction prepared for #10 must fail, even if sent by another buyer.
        vm.expectRevert(abi.encodeWithSelector(IMDRocks.IncorrectPayment.selector, rocks.priceOf(11), firstPrice));
        vm.prank(BOB);
        rocks.buy{value: firstPrice}();
        assertEq(rocks.ownerOf(10), ALICE);
        assertEq(rocks.nextRock(), 11);
        _buyAs(BOB);
        assertEq(rocks.ownerOf(11), BOB);
    }

    function test_NoAlternateMintOrControlEntryPoints() public {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeWithSignature("buy(uint256)", 99);
        calls[1] = abi.encodeWithSignature("mint(address,uint256)", ALICE, 100);
        calls[2] = abi.encodeWithSignature("mint(address,uint256)", ALICE, 0);
        calls[3] = abi.encodeWithSignature("burn(uint256)", 0);
        calls[4] = abi.encodeWithSignature("withdraw()");
        calls[5] = abi.encodeWithSignature("owner()");
        calls[6] = abi.encodeWithSignature("pause()");
        calls[7] = abi.encodeWithSignature("upgradeTo(address)", ALICE);
        calls[8] = abi.encodeWithSignature("setPrice(uint256)", 0);
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(rocks).call(calls[i]);
            assertFalse(success);
        }
        assertEq(rocks.nextRock(), 10);
        assertEq(rocks.ownerOf(0), RESERVE);
    }

    function test_PayoutRejectionRollsBackAndCanRecover() public {
        PayoutProbe payout = new PayoutProbe();
        IMDRocks sale = new IMDRocks(address(payout));
        payout.configure(sale, true, false, false);
        uint256 price = sale.priceOf(10);
        uint256 buyerBalance = ALICE.balance;
        vm.expectRevert(IMDRocks.PayoutFailed.selector);
        vm.prank(ALICE);
        sale.buy{value: price}();
        assertEq(sale.nextRock(), 10);
        assertEq(sale.totalSupply(), 10);
        assertEq(sale.balanceOf(ALICE), 0);
        assertEq(ALICE.balance, buyerBalance);
        assertEq(address(sale).balance, 0);
        assertEq(address(payout).balance, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 10));
        sale.ownerOf(10);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 10));
        sale.tokenURI(10);
        payout.configure(sale, false, false, false);
        vm.prank(ALICE);
        sale.buy{value: price}();
        assertEq(sale.ownerOf(10), ALICE);
        assertEq(address(payout).balance, price);
    }

    function test_PayoutReentryBlockedWithStateAlreadyUpdated() public {
        PayoutProbe payout = new PayoutProbe();
        IMDRocks sale = new IMDRocks(address(payout));
        payout.configure(sale, false, true, false);
        vm.deal(address(payout), 1 ether);
        uint256 price = sale.priceOf(10);
        vm.prank(ALICE);
        sale.buy{value: price}();
        assertTrue(payout.attempted());
        assertFalse(payout.reentrySucceeded());
        assertEq(payout.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(payout.observedNext(), 11);
        assertEq(payout.observedSupply(), 11);
        assertEq(payout.observedOwner(), ALICE);
        assertEq(sale.nextRock(), 11);
        assertEq(address(payout).balance, 1 ether + price);
        assertEq(address(sale).balance, 0);
        payout.configure(sale, false, true, true);
        uint256 nextPrice = sale.priceOf(11);
        vm.expectRevert(IMDRocks.PayoutFailed.selector);
        vm.prank(ALICE);
        sale.buy{value: nextPrice}();
        assertEq(sale.nextRock(), 11);
        assertEq(sale.balanceOf(ALICE), 1);
        assertEq(address(payout).balance, 1 ether + price);
    }

    function test_ReceiverReentryBlockedWithStateAlreadyUpdated() public {
        BuyerProbe buyer = new BuyerProbe(rocks);
        buyer.configure(false, true, false, address(0));
        vm.deal(address(buyer), 1 ether);
        uint256 price = rocks.priceOf(10);
        uint256 beforePayout = RESERVE.balance;
        buyer.purchase{value: price}();
        assertTrue(buyer.attempted());
        assertFalse(buyer.reentrySucceeded());
        assertEq(buyer.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(buyer.observedNext(), 11);
        assertEq(buyer.observedSupply(), 11);
        assertEq(buyer.observedOwner(), address(buyer));
        assertEq(buyer.callbackOperator(), address(buyer));
        assertEq(buyer.callbackFrom(), address(0));
        assertEq(rocks.nextRock(), 11);
        assertEq(rocks.balanceOf(address(buyer)), 1);
        assertEq(address(buyer).balance, 1 ether);
        assertEq(RESERVE.balance - beforePayout, price);
        assertEq(address(rocks).balance, 0);
    }

    function test_ReceiverRejectionAndPropagatedReentryRollBack() public {
        BuyerProbe buyer = new BuyerProbe(rocks);
        uint256 price = rocks.priceOf(10);
        uint256 beforePayout = RESERVE.balance;
        buyer.configure(true, false, false, address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(buyer)));
        buyer.purchase{value: price}();
        assertEq(rocks.nextRock(), 10);
        buyer.configure(false, true, true, address(0));
        vm.deal(address(buyer), 1 ether);
        vm.expectRevert(bytes("Propagated reentry failure"));
        buyer.purchase{value: price}();
        assertEq(rocks.nextRock(), 10);
        assertEq(rocks.balanceOf(address(buyer)), 0);
        assertEq(RESERVE.balance, beforePayout);
        assertEq(address(rocks).balance, 0);
        buyer.configure(false, false, false, address(0));
        buyer.purchase{value: price}();
        assertEq(rocks.ownerOf(10), address(buyer));
    }

    function test_NonReceiverCannotBuy() public {
        NonReceiverBuyer buyer = new NonReceiverBuyer();
        uint256 price = rocks.priceOf(10);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(buyer)));
        buyer.purchase{value: price}(rocks);
        assertEq(rocks.nextRock(), 10);
        assertEq(address(rocks).balance, 0);
    }

    function test_ReceiverMayTransferNewRockWithoutAffectingSale() public {
        BuyerProbe buyer = new BuyerProbe(rocks);
        buyer.configure(false, false, false, BOB);
        uint256 beforePayout = RESERVE.balance;
        uint256 price = rocks.priceOf(10);
        buyer.purchase{value: price}();
        assertEq(rocks.ownerOf(10), BOB);
        assertEq(rocks.balanceOf(address(buyer)), 0);
        assertEq(rocks.nextRock(), 11);
        assertEq(RESERVE.balance - beforePayout, price);
    }

    function test_DirectEtherUnknownSelectorAndPayableTransferRejected() public {
        (bool plain,) = address(rocks).call{value: 1 wei}("");
        (bool unknown,) = address(rocks).call{value: 1 wei}(hex"deadbeef");
        (bool empty,) = address(rocks).call("");
        vm.deal(RESERVE, 1 ether);
        vm.prank(RESERVE);
        (bool transfer,) = address(rocks).call{value: 1 wei}(abi.encodeCall(rocks.transferFrom, (RESERVE, ALICE, 0)));
        assertFalse(plain);
        assertFalse(unknown);
        assertFalse(empty);
        assertFalse(transfer);
        assertEq(address(rocks).balance, 0);
        assertEq(rocks.ownerOf(0), RESERVE);
    }

    function test_ForcedEtherCannotBePreventedAndDoesNotChangeSale() public {
        new ForcedEther{value: 1 ether}(payable(address(rocks)));
        assertEq(address(rocks).balance, 1 ether);
        uint256 beforePayout = RESERVE.balance;
        _buyAs(ALICE);
        assertEq(RESERVE.balance - beforePayout, rocks.priceOf(10));
        assertEq(address(rocks).balance, 1 ether);
        assertEq(rocks.nextRock(), 11);
        (bool withdrew,) = address(rocks).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(withdrew);
    }

    function test_ERC165InterfacesAndNoRoyalties() public view {
        assertTrue(rocks.supportsInterface(0x01ffc9a7));
        assertTrue(rocks.supportsInterface(0x80ac58cd));
        assertTrue(rocks.supportsInterface(0x5b5e139f));
        assertFalse(rocks.supportsInterface(0x780e9d63)); // Enumeration is not advertised.
        assertFalse(rocks.supportsInterface(0x2a55205a)); // ERC-2981.
        assertFalse(rocks.supportsInterface(0xffffffff));
    }

    function test_ApprovalsTransfersRevocationAndNoFee() public {
        uint256 beforePayout = RESERVE.balance;
        vm.expectEmit(true, true, true, true, address(rocks));
        emit Approval(RESERVE, ALICE, 0);
        vm.prank(RESERVE);
        rocks.approve(ALICE, 0);
        assertEq(rocks.getApproved(0), ALICE);
        vm.prank(ALICE);
        rocks.transferFrom(RESERVE, BOB, 0);
        assertEq(rocks.ownerOf(0), BOB);
        assertEq(rocks.getApproved(0), address(0));
        assertEq(rocks.balanceOf(RESERVE), 9);
        assertEq(rocks.balanceOf(BOB), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, ALICE, 0));
        vm.prank(ALICE);
        rocks.transferFrom(BOB, ALICE, 0);
        vm.expectEmit(true, true, false, true, address(rocks));
        emit ApprovalForAll(BOB, ALICE, true);
        vm.prank(BOB);
        rocks.setApprovalForAll(ALICE, true);
        vm.prank(ALICE);
        rocks.transferFrom(BOB, BOB, 0);
        assertEq(rocks.balanceOf(BOB), 1);
        vm.prank(BOB);
        rocks.setApprovalForAll(ALICE, false);
        assertFalse(rocks.isApprovedForAll(BOB, ALICE));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, ALICE, 0));
        vm.prank(ALICE);
        rocks.transferFrom(BOB, ALICE, 0);
        vm.prank(BOB);
        rocks.transferFrom(BOB, ALICE, 0);
        assertEq(RESERVE.balance, beforePayout);
        assertEq(rocks.totalSupply(), 10);
    }

    function test_UnauthorizedTransfersApprovalsWrongOwnerAndZeroRecipientFail() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, ALICE, 0));
        vm.prank(ALICE);
        rocks.transferFrom(RESERVE, ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, ALICE));
        vm.prank(ALICE);
        rocks.approve(BOB, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, BOB, 0, RESERVE));
        vm.prank(RESERVE);
        rocks.transferFrom(BOB, ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        vm.prank(RESERVE);
        rocks.transferFrom(RESERVE, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 100));
        vm.prank(ALICE);
        rocks.transferFrom(address(0), ALICE, 100);
        assertEq(rocks.ownerOf(0), RESERVE);
        assertEq(rocks.totalSupply(), 10);
    }

    function test_SafeTransferChecksReceiverAndRollsBackOnRejection() public {
        BuyerProbe receiver = new BuyerProbe(rocks);
        receiver.configure(true, false, false, address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        vm.prank(RESERVE);
        rocks.safeTransferFrom(RESERVE, address(receiver), 0);
        assertEq(rocks.ownerOf(0), RESERVE);
        receiver.configure(false, false, false, address(0));
        vm.prank(RESERVE);
        rocks.safeTransferFrom(RESERVE, address(receiver), 0, hex"cafe");
        assertEq(rocks.ownerOf(0), address(receiver));
        assertEq(receiver.callbackOperator(), RESERVE);
        assertEq(receiver.callbackFrom(), RESERVE);
        assertEq(rocks.totalSupply(), 10);
    }

    function test_DeploymentBoundsAndForbiddenRuntimeOpcodes() public view {
        bytes memory code = address(rocks).code;
        assertLe(code.length, 24_576);
        assertLe(type(IMDRocks).creationCode.length + 32, 49_152);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "Forbidden application opcode");
        }
    }

    function _buyAs(address buyer) internal {
        uint256 price = rocks.priceOf(rocks.nextRock());
        vm.prank(buyer);
        rocks.buy{value: price}();
    }

    function _expectWrongPayment(uint256 value, uint256 expected) internal {
        uint256 payoutBefore = RESERVE.balance;
        uint256 buyerBefore = ALICE.balance;
        vm.expectRevert(abi.encodeWithSelector(IMDRocks.IncorrectPayment.selector, expected, value));
        vm.prank(ALICE);
        rocks.buy{value: value}();
        assertEq(RESERVE.balance, payoutBefore);
        assertEq(ALICE.balance, buyerBefore);
        assertEq(address(rocks).balance, 0);
    }
}
