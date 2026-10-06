// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDRocks} from "../../src/IMDRocks.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract DeploymentFactory {
    function deploy(address payout) external returns (IMDRocks) {
        return new IMDRocks(payout);
    }
}

contract PayoutProbe {
    IMDRocks public rocks;
    bool public reject;
    bool public reenter;
    bool public propagateFailure;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryResult;
    uint256 public observedNext;
    uint256 public observedSupply;
    address public observedOwner;

    function configure(IMDRocks target, bool reject_, bool reenter_, bool propagateFailure_) external {
        rocks = target;
        reject = reject_;
        reenter = reenter_;
        propagateFailure = propagateFailure_;
    }

    receive() external payable {
        require(!reject, "Payout rejected");
        observedNext = rocks.nextRock();
        observedSupply = rocks.totalSupply();
        observedOwner = rocks.ownerOf(observedNext - 1);
        if (reenter) {
            attempted = true;
            uint256 value = observedNext < 100 ? rocks.priceOf(observedNext) : 0;
            (reentrySucceeded, reentryResult) = address(rocks).call{value: value}(abi.encodeCall(rocks.buy, ()));
            require(!propagateFailure || reentrySucceeded, "Propagated reentry failure");
        }
    }
}

contract BuyerProbe is IERC721Receiver {
    IMDRocks public immutable rocks;
    bool public reject;
    bool public reenter;
    bool public propagateFailure;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryResult;
    uint256 public observedNext;
    uint256 public observedSupply;
    address public observedOwner;
    address public callbackOperator;
    address public callbackFrom;
    address public transferTo;

    constructor(IMDRocks target) {
        rocks = target;
    }

    function configure(bool reject_, bool reenter_, bool propagateFailure_, address transferTo_) external {
        reject = reject_;
        reenter = reenter_;
        propagateFailure = propagateFailure_;
        transferTo = transferTo_;
    }

    function purchase() external payable returns (uint256) {
        return rocks.buy{value: msg.value}();
    }

    function onERC721Received(address operator, address from, uint256 number, bytes calldata)
        external
        returns (bytes4)
    {
        require(msg.sender == address(rocks), "Unexpected collection");
        observedNext = rocks.nextRock();
        observedSupply = rocks.totalSupply();
        observedOwner = rocks.ownerOf(number);
        callbackOperator = operator;
        callbackFrom = from;
        if (reenter) {
            attempted = true;
            uint256 value = observedNext < 100 ? rocks.priceOf(observedNext) : 0;
            (reentrySucceeded, reentryResult) = address(rocks).call{value: value}(abi.encodeCall(rocks.buy, ()));
            require(!propagateFailure || reentrySucceeded, "Propagated reentry failure");
        }
        if (transferTo != address(0)) rocks.transferFrom(address(this), transferTo, number);
        return reject ? bytes4(0) : IERC721Receiver.onERC721Received.selector;
    }
}

contract NonReceiverBuyer {
    function purchase(IMDRocks rocks) external payable {
        rocks.buy{value: msg.value}();
    }
}

/// @dev Test-only adversary: the opcode is never part of the application runtime.
contract ForcedEther {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
