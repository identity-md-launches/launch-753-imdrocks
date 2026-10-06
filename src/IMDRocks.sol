// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title IMDRocks
/// @notice One hundred original, on-chain rocks, sold in ascending token order.
contract IMDRocks is ERC721, ReentrancyGuard {
    using Strings for uint256;

    string public constant NAME = "IMDRocks";
    string public constant SYMBOL = "IMDROCK";
    uint256 public constant MAX_SUPPLY = 100;
    uint256 private constant PRICE_UNIT = 10_000_000_000_000;

    address payable public immutable payout;
    uint256 public nextRock = 10;

    error InvalidPayout();
    error InvalidRock(uint256 number);
    error SoldOut();
    error IncorrectPayment(uint256 expected, uint256 received);
    error PayoutFailed();

    /// @param reserveAndPayout Receives rocks 0..9 and every sale payment; never the factory by default.
    constructor(address reserveAndPayout) ERC721(NAME, SYMBOL) {
        if (reserveAndPayout == address(0) || reserveAndPayout == address(this)) revert InvalidPayout();
        payout = payable(reserveAndPayout);
        // Reserve minting intentionally has no receiver callbacks during construction.
        for (uint256 i; i < 10; ++i) {
            _mint(reserveAndPayout, i);
        }
    }

    function name() public pure override returns (string memory) {
        return NAME;
    }

    function symbol() public pure override returns (string memory) {
        return SYMBOL;
    }

    /// @notice Number minted so far, including the ten reserved rocks. There is no burn function.
    function totalSupply() external view returns (uint256) {
        return nextRock;
    }

    /// @notice Fixed price in wei, including for valid rocks that have not yet been minted.
    function priceOf(uint256 number) public pure returns (uint256) {
        if (number >= MAX_SUPPLY) revert InvalidRock(number);
        return PRICE_UNIT * (1 + number * number);
    }

    /// @notice Buys exactly the next rock. Contract buyers must implement IERC721Receiver.
    /// @dev All mint state is set before callbacks. Any receiver or payout failure rolls everything back.
    function buy() external payable nonReentrant returns (uint256 number) {
        number = nextRock;
        if (number == MAX_SUPPLY) revert SoldOut();
        uint256 price = priceOf(number);
        if (msg.value != price) revert IncorrectPayment(price, msg.value);

        nextRock = number + 1;
        _safeMint(msg.sender, number);
        (bool paid,) = payout.call{value: msg.value}("");
        if (!paid) revert PayoutFailed();
    }

    /// @notice Raw SVG preview for any rock 0..99, whether minted yet or not.
    function imageOf(uint256 number) public pure returns (string memory) {
        if (number >= MAX_SUPPLY) revert InvalidRock(number);
        // Original hand-drawn silhouette and facets. Only this single base fill varies by number.
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">'
            '<rect width="400" height="400" fill="#eee9df"/>'
            '<ellipse cx="202" cy="304" rx="133" ry="24" fill="#322e29" opacity=".16"/>'
            '<g stroke="#383b3b" stroke-width="3.5" stroke-linejoin="round">' '<path fill="',
            _tint(number),
            '" d="M65 249 Q68 223 87 190 L120 143 Q126 134 140 133 L214 112 '
            "Q226 108 238 116 L291 148 Q301 153 306 167 L334 225 Q341 242 331 260 "
            'L305 291 Q299 299 281 302 L180 315 Q167 316 153 310 L91 291 Q77 286 74 274 Z"/>'
            '<path fill="#fff" opacity=".26" stroke="none" ' 'd="M87 190 L125 139 L220 113 L183 184 L111 211 Z"/>'
            '<path fill="#fff" opacity=".12" stroke="none" ' 'd="M220 113 L238 116 L298 153 L274 205 L183 184 Z"/>'
            '<path fill="#000" opacity=".13" stroke="none" '
            'd="M274 205 L305 165 L336 235 L331 260 L302 295 L253 265 Z"/>'
            '<path fill="#000" opacity=".23" stroke="none" '
            'd="M65 249 L111 211 L149 263 L180 315 L91 291 L74 274 Z"/>'
            '<path fill="#000" opacity=".09" stroke="none" ' 'd="M149 263 L253 265 L302 295 L180 315 Z"/>'
            '<path fill="none" opacity=".38" stroke-width="2" '
            'd="M125 140 L111 211 L149 263 L253 265 L274 205 L298 154 M111 211 L183 184 '
            'L220 114 M183 184 L274 205 M149 263 L180 313"/>'
            '<path fill="none" opacity=".35" stroke-width="2" stroke-linecap="round" '
            'd="M201 223 L213 229 L209 242 M102 248 L108 258 M286 238 L290 230"/>' "</g></svg>"
        );
    }

    function tokenURI(uint256 number) public view override returns (string memory) {
        _requireOwned(number);
        string memory attributes = string.concat(
            '[{"trait_type":"Number","value":',
            number.toString(),
            '},{"trait_type":"Tint","value":"',
            _tint(number),
            '"},{"trait_type":"Price","value":"',
            _priceInEth(number),
            '"}]'
        );
        string memory metadata = string.concat(
            '{"name":"IMDRock #',
            number.toString(),
            '","description":"A hand-drawn on-chain boulder, one of 100 rocks in a circle of colour.",'
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(imageOf(number))),
            '","attributes":',
            attributes,
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(metadata)));
    }

    function _priceInEth(uint256 number) private pure returns (string memory) {
        // One price unit is 0.00001 ETH. Five fractional digits represent every price exactly.
        bytes memory fraction = bytes((priceOf(number) / PRICE_UNIT).toString());
        bytes memory decimal = bytes("0.00000");
        for (uint256 i; i < fraction.length; ++i) {
            decimal[decimal.length - fraction.length + i] = fraction[i];
        }
        return string(decimal);
    }

    function _tint(uint256 number) private pure returns (string memory) {
        uint256 rgb = 0x929292; // Rock zero is neutral stone grey.
        if (number != 0) {
            // 99 evenly spaced hues, fixed saturation/value; six linear RGB wheel segments.
            uint256 hue = (number - 1) * 1536 / 99;
            uint256 sector = hue / 256;
            uint256 rising = 112 + (hue % 256) * 79 / 256;
            uint256 falling = 191 - (hue % 256) * 79 / 256;
            if (sector == 0) rgb = (191 << 16) | (rising << 8) | 112;
            else if (sector == 1) rgb = (falling << 16) | (191 << 8) | 112;
            else if (sector == 2) rgb = (112 << 16) | (191 << 8) | rising;
            else if (sector == 3) rgb = (112 << 16) | (falling << 8) | 191;
            else if (sector == 4) rgb = (rising << 16) | (112 << 8) | 191;
            else rgb = (191 << 16) | (112 << 8) | falling;
        }
        bytes16 digits = "0123456789abcdef";
        bytes memory colour = new bytes(7);
        colour[0] = "#";
        for (uint256 i; i < 6; ++i) {
            colour[6 - i] = digits[rgb & 15];
            rgb >>= 4;
        }
        return string(colour);
    }
}
