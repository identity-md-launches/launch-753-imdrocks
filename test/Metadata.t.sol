// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDRocks} from "../src/IMDRocks.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MetadataTest is Test {
    address private constant RESERVE = 0xE89eB4D7153958F9436E2c3fe30D6F2024404cB0;
    address private constant BUYER = address(0xA11CE);
    IMDRocks private rocks;

    function setUp() public {
        rocks = new IMDRocks(RESERVE);
        vm.deal(BUYER, 20 ether);
    }

    function test_UnmintedMetadataRevertsButEveryImageCanBePreviewed() public {
        for (uint256 n; n < 100; ++n) {
            _assertSvgWellFormed(bytes(rocks.imageOf(n)));
            if (n >= 10) {
                vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, n));
                rocks.tokenURI(n);
            }
        }
    }

    function test_AllMetadataDecodesAndMatchesImagePriceAndDistinctTint() public {
        bytes32[100] memory previewHashes;
        for (uint256 n; n < 100; ++n) {
            previewHashes[n] = keccak256(bytes(rocks.imageOf(n)));
        }
        for (uint256 n = 10; n < 100; ++n) {
            uint256 price = rocks.priceOf(n);
            vm.prank(BUYER);
            rocks.buy{value: price}();
        }

        bytes32[100] memory tintHashes;
        bytes32 geometryHash;
        for (uint256 n; n < 100; ++n) {
            string memory json = string(_decodeDataURI(rocks.tokenURI(n), "data:application/json;base64,"));
            assertEq(vm.parseJsonString(json, ".name"), string.concat("IMDRock #", vm.toString(n)));
            string memory description = vm.parseJsonString(json, ".description");
            assertGt(bytes(description).length, 0);
            for (uint256 i; i < bytes(description).length; ++i) {
                assertTrue(bytes(description)[i] != 0x0a && bytes(description)[i] != 0x0d);
            }
            assertEq(vm.parseJsonKeys(json, ".").length, 4);
            assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "Number");
            assertEq(vm.parseJsonUint(json, ".attributes[0].value"), n);
            assertEq(vm.parseJsonString(json, ".attributes[1].trait_type"), "Tint");
            assertEq(vm.parseJsonString(json, ".attributes[2].trait_type"), "Price");
            assertFalse(vm.keyExistsJson(json, ".attributes[3]"));
            assertEq(_parseEth(vm.parseJsonString(json, ".attributes[2].value")), rocks.priceOf(n));
            string memory tint = vm.parseJsonString(json, ".attributes[1].value");
            _assertTint(tint, n);
            tintHashes[n] = keccak256(bytes(tint));
            for (uint256 i; i < n; ++i) {
                assertNotEq(tintHashes[i], tintHashes[n], "Tint repeated");
            }

            bytes memory svg = _decodeDataURI(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");
            assertEq(string(svg), rocks.imageOf(n));
            assertEq(keccak256(svg), previewHashes[n]);
            _assertSvgWellFormed(svg);
            bytes32 masked = _geometryWithoutTint(svg, bytes(tint));
            if (n == 0) geometryHash = masked;
            else assertEq(masked, geometryHash, "Art differs beyond the base tint");
        }
    }

    function test_MetadataRemainsTheSameAfterTransfer() public {
        string memory beforeURI = rocks.tokenURI(0);
        vm.prank(RESERVE);
        rocks.transferFrom(RESERVE, BUYER, 0);
        assertEq(rocks.tokenURI(0), beforeURI);
    }

    function _decodeDataURI(string memory uri, string memory prefix) private pure returns (bytes memory decoded) {
        bytes memory raw = bytes(uri);
        bytes memory head = bytes(prefix);
        assertGt(raw.length, head.length);
        for (uint256 i; i < head.length; ++i) {
            assertEq(raw[i], head[i]);
        }
        uint256 size = raw.length - head.length;
        assertEq(size % 4, 0, "Base64 length");
        uint256 padding;
        if (raw[raw.length - 1] == "=") ++padding;
        if (raw[raw.length - 2] == "=") ++padding;
        decoded = new bytes(size / 4 * 3 - padding);
        bytes memory encoded = new bytes(size);
        uint256 cursor;
        for (uint256 i; i < size; i += 4) {
            uint256 word;
            for (uint256 j; j < 4; ++j) {
                bytes1 ch = raw[head.length + i + j];
                encoded[i + j] = ch;
                if (ch == "=") assertGe(i + j, size - padding, "Interior padding");
                word = (word << 6) | _base64Digit(ch);
            }
            for (uint256 j; j < 3 && cursor < decoded.length; ++j) {
                decoded[cursor++] = bytes1(uint8((word >> (16 - j * 8)) & 255));
            }
        }
        // Independent native encoding checks padding and all decoded bytes.
        assertEq(vm.toBase64(decoded), string(encoded));
    }

    function _base64Digit(bytes1 ch) private pure returns (uint256) {
        uint256 c = uint8(ch);
        if (c >= 65 && c <= 90) return c - 65;
        if (c >= 97 && c <= 122) return c - 71;
        if (c >= 48 && c <= 57) return c + 4;
        if (ch == "+") return 62;
        if (ch == "/") return 63;
        assertEq(ch, "=", "Invalid base64 character");
        return 0;
    }

    function _parseEth(string memory value) private pure returns (uint256 weiValue) {
        bytes memory decimal = bytes(value);
        assertGe(decimal.length, 3);
        assertEq(decimal[0], "0");
        assertEq(decimal[1], ".");
        uint256 fractionalDigits = decimal.length - 2;
        assertLe(fractionalDigits, 18);
        for (uint256 i = 2; i < decimal.length; ++i) {
            assertTrue(decimal[i] >= "0" && decimal[i] <= "9", "Invalid ETH decimal");
            weiValue = weiValue * 10 + uint8(decimal[i]) - 48;
        }
        return weiValue * (10 ** (18 - fractionalDigits));
    }

    function _assertTint(string memory tint, uint256 number) private pure {
        bytes memory colour = bytes(tint);
        assertEq(colour.length, 7);
        assertEq(colour[0], "#");
        for (uint256 i = 1; i < 7; ++i) {
            assertTrue((colour[i] >= "0" && colour[i] <= "9") || (colour[i] >= "a" && colour[i] <= "f"));
        }
        if (number == 0) {
            assertEq(colour[1], colour[3]);
            assertEq(colour[1], colour[5]);
            assertEq(colour[2], colour[4]);
            assertEq(colour[2], colour[6]);
        }
    }

    function _geometryWithoutTint(bytes memory svg, bytes memory tint) private pure returns (bytes32) {
        uint256 matches;
        for (uint256 i; i + tint.length <= svg.length; ++i) {
            if (svg[i] != "#") continue;
            bool same = true;
            for (uint256 j; j < tint.length; ++j) {
                if (svg[i + j] != tint[j]) same = false;
            }
            if (same) {
                ++matches;
                for (uint256 j; j < tint.length; ++j) {
                    svg[i + j] = "_";
                }
            }
        }
        assertEq(matches, 1, "The base tint must be used exactly once");
        return keccak256(svg);
    }

    /// @dev Strict parser for the static SVG subset used here: balanced tags, quoted attributes,
    /// one root, a square viewBox, SVG namespace, no text/scripts/entities or external resources.
    function _assertSvgWellFormed(bytes memory svg) private pure {
        bytes32[8] memory stack;
        uint256 depth;
        uint256 roots;
        uint256 paths;
        uint256 cursor;
        bool namespaceSeen;
        bool squareSeen;
        while (cursor < svg.length) {
            assertEq(svg[cursor++], "<");
            bool closing = svg[cursor] == "/";
            if (closing) ++cursor;
            uint256 start = cursor;
            while (svg[cursor] != " " && svg[cursor] != ">" && svg[cursor] != "/") ++cursor;
            bytes32 tag = keccak256(_slice(svg, start, cursor));
            bool root = tag == keccak256("svg");
            assertTrue(
                root || tag == keccak256("rect") || tag == keccak256("ellipse") || tag == keccak256("g")
                    || tag == keccak256("path")
            );
            if (closing) {
                assertGt(depth, 0);
                assertEq(stack[--depth], tag);
                assertEq(svg[cursor++], ">");
                continue;
            }
            if (depth == 0) {
                assertTrue(root);
                ++roots;
            }
            if (tag == keccak256("path")) ++paths;
            while (svg[cursor] == " ") {
                ++cursor;
                start = cursor;
                while (svg[cursor] != "=") ++cursor;
                bytes32 attribute = keccak256(_slice(svg, start, cursor));
                assertNotEq(attribute, keccak256("href"));
                assertNotEq(attribute, keccak256("onload"));
                ++cursor;
                assertEq(svg[cursor++], '"');
                start = cursor;
                while (svg[cursor] != '"') {
                    assertTrue(svg[cursor] != "<" && svg[cursor] != "&");
                    ++cursor;
                }
                if (root && attribute == keccak256("xmlns")) {
                    assertEq(string(_slice(svg, start, cursor)), "http://www.w3.org/2000/svg");
                    namespaceSeen = true;
                }
                if (root && attribute == keccak256("viewBox")) {
                    assertEq(string(_slice(svg, start, cursor)), "0 0 400 400");
                    squareSeen = true;
                }
                ++cursor;
            }
            if (svg[cursor] == "/") ++cursor;
            else stack[depth++] = tag;
            assertEq(svg[cursor++], ">");
        }
        assertEq(depth, 0);
        assertEq(roots, 1);
        assertGe(paths, 4);
        assertTrue(namespaceSeen && squareSeen);
    }

    function _slice(bytes memory value, uint256 start, uint256 end) private pure returns (bytes memory result) {
        result = new bytes(end - start);
        for (uint256 i; i < result.length; ++i) {
            result[i] = value[start + i];
        }
    }
}
