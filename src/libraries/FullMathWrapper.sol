// SPDX-License-Identifier: MIT
pragma solidity >=0.4.0 <0.8.0;

import "./FullMathUnderlying.sol";

library FullMathWrapper {
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) external pure returns (uint256 result) {
        result = FullMathUnderlying.mulDiv(a, b, denominator);
    }

    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) external pure returns (uint256 result) {
        result = FullMathUnderlying.mulDivRoundingUp(a, b, denominator);
    }
}