// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

// Copied from https://github.com/Uniswap/v4-core

/// @title FixedPoint128
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Used in SqrtPriceMath.sol
library FixedPoint128 {
    uint8 internal constant RESOLUTION = 128;
    // Q96 = 2**96 = 1 << 96
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
}