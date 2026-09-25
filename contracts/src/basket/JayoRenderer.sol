// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {JayoBasket} from "./JayoBasket.sol";
import {IJayoRenderer} from "../interfaces/IJayoRenderer.sol";

/// @title JayoRenderer
/// @notice Draws what a wallet or explorer shows for a Jayo position: its current
///         holdings, its plan for new money, how it has been funded, a small image,
///         and a link to the position's own page.
///
/// @dev Everything is read from the basket's public views at the moment of the
///      call; nothing is stored here except two display strings fixed at
///      deployment. A token symbol comes from the token itself and is reduced to
///      `[A-Za-z0-9.-]`, at most 11 characters, before it goes into JSON or SVG, so
///      a token cannot inject markup even if a route were ever added for one that
///      tried.
contract JayoRenderer is IJayoRenderer {
    using Strings for uint256;

    /// @notice Where a position's page lives, without a trailing slash.
    string public siteUrl;
    /// @notice One sentence saying which network this is and what the assets are worth.
    string public networkNote;

    constructor(string memory siteUrl_, string memory networkNote_) {
        siteUrl = siteUrl_;
        networkNote = networkNote_;
    }

    function tokenURI(address basket, uint256 tokenId) external view returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(tokenJSON(basket, tokenId))));
    }

    /// @notice The metadata as plain JSON, for anyone who wants to read it directly.
    function tokenJSON(address basket, uint256 tokenId) public view returns (string memory) {
        JayoBasket b = JayoBasket(basket);
        (address[] memory assets, uint256[] memory amounts) = b.holdingsOf(tokenId);
        JayoBasket.Allocation[] memory plan = b.allocationOf(tokenId);
        IERC20Metadata usdg = IERC20Metadata(address(b.usdg()));
        string memory usdgSym = _symbol(address(usdg));
        string memory funded = string.concat(_amount(b.totalFunded(tokenId), _decimals(address(usdg)), 2), " ", usdgSym);
        string memory purchases = uint256(b.fundingCount(tokenId)).toString();

        string memory attrs;
        for (uint256 i; i < assets.length; ++i) {
            attrs = string.concat(
                attrs,
                '{"trait_type":"Holds ', _symbol(assets[i]), '","value":"',
                _amount(amounts[i], _decimals(assets[i]), 6), '"},'
            );
        }
        attrs = string.concat(
            attrs,
            '{"trait_type":"Plan for new money","value":"', _planText(plan), '"},',
            '{"trait_type":"Plan version","display_type":"number","value":', uint256(b.allocationVersion(tokenId)).toString(), "},",
            '{"trait_type":"Purchases","display_type":"number","value":', purchases, "},",
            '{"trait_type":"Funded","value":"', funded, '"}'
        );

        return string.concat(
            '{"name":"Jayo basket #', tokenId.toString(), '",',
            '"description":"One individually owned basket of tokens. Its holdings are read from the contract when you look. ',
            networkNote, '",',
            '"external_url":"', siteUrl, "/?basket=", tokenId.toString(), '",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(tokenId, assets, amounts, plan, funded, purchases))), '",',
            '"attributes":[', attrs, "]}"
        );
    }

    // ------------------------------------------------------------------ image

    function _svg(
        uint256 tokenId,
        address[] memory assets,
        uint256[] memory amounts,
        JayoBasket.Allocation[] memory plan,
        string memory funded,
        string memory purchases
    ) internal view returns (string memory s) {
        s = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400" font-family="Helvetica,Arial,sans-serif">',
            '<rect width="400" height="400" rx="28" fill="#FFFFFF"/><rect x="1" y="1" width="398" height="398" rx="27" fill="none" stroke="#D5DEE1" stroke-width="2"/>',
            '<text x="32" y="56" font-size="15" fill="#0B5563" font-weight="700">Jayo basket</text>',
            '<text x="32" y="100" font-size="40" font-weight="700" fill="#0F2229">#', tokenId.toString(), "</text>",
            _planBar(plan)
        );
        uint256 y = 196;
        uint256 shown = assets.length > 6 ? 6 : assets.length;
        if (shown == 0) {
            s = string.concat(s, '<text x="32" y="', y.toString(), '" font-size="17" fill="#4B6068">Holds nothing yet</text>');
        }
        for (uint256 i; i < shown; ++i) {
            s = string.concat(
                s,
                '<text x="32" y="', y.toString(), '" font-size="18" font-weight="700" fill="#0F2229">', _symbol(assets[i]), "</text>",
                '<text x="368" y="', y.toString(), '" font-size="18" text-anchor="end" fill="#0F2229">',
                _amount(amounts[i], _decimals(assets[i]), 6), "</text>"
            );
            y += 30;
        }
        s = string.concat(
            s,
            '<text x="32" y="344" font-size="13" fill="#4B6068">Funded ', funded, " in ", purchases, " purchase(s)</text>",
            '<text x="32" y="368" font-size="13" fill="#8A5A0E">', networkNote, "</text></svg>"
        );
    }

    function _planBar(JayoBasket.Allocation[] memory plan) internal pure returns (string memory s) {
        s = '<text x="32" y="138" font-size="13" fill="#4B6068">Plan for new money</text>';
        uint256 x = 32;
        for (uint256 i; i < plan.length; ++i) {
            uint256 w = (336 * uint256(plan[i].weightBps)) / 10_000;
            if (i == plan.length - 1) w = 368 - x; // absorb rounding so the bar is full
            s = string.concat(
                s, '<rect x="', x.toString(), '" y="148" width="', w.toString(), '" height="12" fill="', _colour(i), '"/>'
            );
            x += w;
        }
    }

    function _colour(uint256 i) internal pure returns (string memory) {
        string[8] memory palette =
            ["#0B5563", "#EE6A4C", "#E6B23A", "#5B9FD1", "#7E5AA2", "#3E9E86", "#C7577A", "#8A6D52"];
        return palette[i % 8];
    }

    // ------------------------------------------------------------------ text

    function _planText(JayoBasket.Allocation[] memory plan) internal view returns (string memory s) {
        for (uint256 i; i < plan.length; ++i) {
            s = string.concat(
                s, i == 0 ? "" : " / ", _symbol(plan[i].asset), " ", _amount(plan[i].weightBps, 2, 2), "%"
            );
        }
    }

    /// @dev `amount` in `decimals`, shown with at most `maxFrac` fraction digits and
    ///      trailing zeros removed. A non-zero amount too small to show is "<0.000001".
    function _amount(uint256 amount, uint8 decimals, uint8 maxFrac) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 whole = amount / unit;
        uint256 frac = amount % unit;
        if (decimals > maxFrac) frac /= 10 ** (decimals - maxFrac);
        uint8 digits = decimals > maxFrac ? maxFrac : decimals;

        bytes memory f = bytes(frac.toString());
        bytes memory padded = new bytes(digits);
        for (uint256 i; i < digits; ++i) {
            padded[i] = i < digits - f.length ? bytes1("0") : f[i - (digits - f.length)];
        }
        uint256 len = digits;
        while (len > 0 && padded[len - 1] == "0") --len;

        if (whole == 0 && len == 0 && amount != 0) {
            return string.concat("<0.", _zeros(digits - 1), "1");
        }
        if (len == 0) return whole.toString();
        bytes memory trimmed = new bytes(len);
        for (uint256 i; i < len; ++i) trimmed[i] = padded[i];
        return string.concat(whole.toString(), ".", string(trimmed));
    }

    function _zeros(uint256 n) internal pure returns (string memory) {
        bytes memory z = new bytes(n);
        for (uint256 i; i < n; ++i) z[i] = "0";
        return string(z);
    }

    function _symbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory sym) {
            bytes memory raw = bytes(sym);
            uint256 n = raw.length > 11 ? 11 : raw.length;
            bytes memory clean = new bytes(n);
            for (uint256 i; i < n; ++i) {
                bytes1 c = raw[i];
                bool ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "-";
                clean[i] = ok ? c : bytes1("?");
            }
            return n == 0 ? "?" : string(clean);
        } catch {
            return "?";
        }
    }

    function _decimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d > 36 ? 36 : d;
        } catch {
            return 18;
        }
    }
}
