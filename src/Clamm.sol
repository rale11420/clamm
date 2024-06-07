// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

import "./lib/Tick.sol";
import "./lib/TickMath.sol";
import "./lib/Position.sol";
import "./lib/SafeCast.sol";
import "./lib/SqrtPriceMath.sol";
import "./interfaces/IERC20.sol";

function checkTicks(int24 tickLower, int24 tickUpper) pure {
    require(tickLower < tickUpper);
    require(tickLower >= TickMath.MIN_TICK);
    require(tickUpper <= TickMath.MAX_TICK);
}

contract Clam {
    using SafeCast for int256;
    using Position for mapping (bytes32 => Position.Info);
    using Position for Position.Info;
    using Tick for mapping (int24 => Tick.Info);

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint128 public immutable maxLiquidityPerTick;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        bool unlocked;
    }

    Slot0 public slot0;
    uint128 public liquidity;
    mapping (int24 => Tick.Info) public ticks;
    mapping (bytes32 => Position.Info) public positions;

    modifier lock {
        require(slot0.unlocked, "locked");
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    constructor(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    function initialize(uint160 sqrtPriceX96) external {
        require(slot0.sqrtPriceX96 == 0, "Already initialized");

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        slot0 = Slot0 ({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            unlocked: true
        });
    }

    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick) private returns (Position.Info storage position) {
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = 0; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = 0; // SLOAD for gas optimization

        //TODO fees
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                maxLiquidityPerTick
            );
            
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                true,
                maxLiquidityPerTick
            );

            // if (flippedLower) {
            //     tickBitmap.flipTick(tickLower, tickSpacing);
            // }
            // if (flippedUpper) {
            //     tickBitmap.flipTick(tickUpper, tickSpacing);
            // }
        }

        // (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks
        //     .getFeeGrowthInside(
        //     tickLower,
        //     tickUpper,
        //     tick,
        //     _feeGrowthGlobal0X128,
        //     _feeGrowthGlobal1X128
        // );

        position.update(
            liquidityDelta, 0, 0
        );

        // Liquidity decreased and tick was flipped = liquidity after is 0
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    struct ModifyPostionParams{
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPostionParams memory params) private returns(Position.Info storage position, int256 amount0, int256 amount1) {
        
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0;

        position = _updatePosition(params.owner, params.tickUpper, params.tickLower, params.liquidityDelta, _slot0.tick);

        if (params.liquidityDelta > 0) {
            if (_slot0.tick > params.tickLower) {
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), 
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick > params.tickUpper){
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96, 
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), 
                    _slot0.sqrtPriceX96, 
                    params.liquidityDelta
                );

                liquidity = params.liquidityDelta < 0
                    ? liquidity - uint128(-params.liquidityDelta)
                    : liquidity + uint128(params.liquidityDelta);
            } else {
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), 
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }

    }

    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount) external lock returns(uint256 amount0, uint256 amount1) {
        require(amount > 0, "Invalid amount");

        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPostionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(amount)).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        if (amount0 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }

        if (amount1 > 0) {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        }
    }

    function collect(address recipient,int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested) 
        external lock returns (uint128 amount0, uint128 amount1) 
    {
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // min(amount owed, amount request)
        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(token0).transfer(recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(token1).transfer(recipient, amount1);
        }
    }

    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external lock returns(uint256 amount0, uint256 amount1){
        (Position.Info memory position, int256 amount0Int, int256 amount1Int) = _modifyPosition(ModifyPostionParams({
            owner: msg.sender,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(uint256(amount)).toInt128()
            })
        );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }
    }
}
