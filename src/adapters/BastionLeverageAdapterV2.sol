// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title BastionLeverageAdapter V3.1 (Fixes)
 * @notice Adaptador de Estrategia para MetaMorpho V2 en Base.
 */

// --- LIBRERÍAS MATEMÁTICAS CORREGIDAS ---

library Math {
    // Multiplicar y dividir estándar (Redondeo hacia abajo / Floor)
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; 
            uint256 prod1; 
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0);
                assembly { result := div(prod0, denominator) }
                return result;
            }
            require(denominator > prod1);
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
                prod0 := mul(prod0, twos)
                result := mul(prod0, prod1)
            }
            return result;
        }
    }

    // Multiplicar y dividir con Redondeo hacia ARRIBA (Ceil)
    // Vital para calcular deuda (siempre debemos asumir la deuda más alta posible por seguridad)
    function mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        result = mulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) > 0) {
            result += 1;
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        require(token.approve(spender, value), "SafeERC20: approve failed");
    }
}

// --- INTERFACES DE PROTOCOLO ---

interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }
    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }
    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data) external;
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver) external;
    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data) external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function accrueInterest(MarketParams memory marketParams) external;
    function position(bytes32 id, address user) external view returns (Position memory);
    function market(bytes32 id) external view returns (Market memory);
}

interface ISlipstreamRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IOracle {
    function price() external view returns (uint256);
}

// --- CONTRATO PRINCIPAL ---

contract BastionLeverageAdapterV2 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Configuración Inmutable (Base Mainnet) ---
    // DIRECCIONES CORREGIDAS (CHECKSUMMED)
    address private constant USDC_ADDR = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant CETES_ADDR = 0x834df4C1d8f51Be24322E39e4766697BE015512F;
    address private constant MORPHO_ADDR = 0xBBBBbBbBBb9CCeDA807e879c5916221aeFE240c6;
    address private constant ROUTER_ADDR = 0xBe6D883033060f3D413037808743c39959644605;
    
    // IRM Default: AdaptiveCurveIRM
    address private constant IRM_ADDR = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC; 
    // LLTV 86% (18 decimales)
    uint256 private constant LLTV = 860000000000000000; 

    IERC20 public immutable USDC;
    IERC20 public immutable CETES;
    IMorpho public immutable MORPHO;
    ISlipstreamRouter public immutable ROUTER;
    
    address public immutable VAULT;
    bytes32 public immutable MARKET_ID;
    IMorpho.MarketParams public marketParams;

    // --- Parámetros de Estrategia ---
    int24 public constant TICK_SPACING = 10; // Usamos el pool de $100k
    uint256 constant WAD = 1e18;
    uint256 constant ORACLE_PRICE_SCALE = 1e36;
    
    // Gestión de Riesgo
    uint256 constant TARGET_LTV = 0.80e18; // 80%
    uint256 constant MAX_SLIPPAGE = 0.005e18; // 0.5%
    uint256 constant DUST_THRESHOLD = 1e4; // 0.01 USDC

    // --- Errores ---
    error OnlyVault();
    error SlippageExceeded();
    error AmountZero();

    // --- Eventos ---
    event Leveraged(uint256 assetsIn, uint256 collateralAdded);
    event Deleveraged(uint256 assetsReturned);

    modifier onlyVault() {
        require(msg.sender == VAULT, "Bastion: Only Vault");
        _;
    }

    constructor(address _vault, address _oracle) {
        require(_vault != address(0), "Invalid Vault");
        require(_oracle != address(0), "Invalid Oracle");

        VAULT = _vault;
        
        // Reconstruimos los parámetros del mercado
        marketParams = IMorpho.MarketParams({
            loanToken: USDC_ADDR,
            collateralToken: CETES_ADDR,
            oracle: _oracle,
            irm: IRM_ADDR,
            lltv: LLTV
        });
        
        MARKET_ID = keccak256(abi.encode(marketParams));

        USDC = IERC20(USDC_ADDR);
        CETES = IERC20(CETES_ADDR);
        MORPHO = IMorpho(MORPHO_ADDR);
        ROUTER = ISlipstreamRouter(ROUTER_ADDR);

        // Aprobaciones Infinitas
        USDC.safeApprove(ROUTER_ADDR, type(uint256).max);
        CETES.safeApprove(ROUTER_ADDR, type(uint256).max);
        USDC.safeApprove(MORPHO_ADDR, type(uint256).max);
        CETES.safeApprove(MORPHO_ADDR, type(uint256).max);
    }

    // --- MetaMorpho View Interface ---

    function asset() external pure returns (address) { return USDC_ADDR; }
    function name() external pure returns (string memory) { return "Bastion CETES Alpha"; }
    
    function adapterId() external view returns (bytes32) {
        return keccak256(abi.encode("bastion.v3", address(this)));
    }

    function totalAssets() external view returns (uint256) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, address(this));
        
        if (pos.collateral == 0 && pos.borrowShares == 0) return 0;

        IMorpho.Market memory marketData = MORPHO.market(MARKET_ID);
        
        uint256 borrowIndex = marketData.totalBorrowAssets == 0 
            ? 1e18 
            : Math.mulDiv(marketData.totalBorrowAssets, WAD, marketData.totalBorrowShares);
            
        // CAMBIO: Usamos mulDivUp para asegurar que no subestimamos la deuda
        uint256 debtAssets = Math.mulDivUp(uint256(pos.borrowShares), borrowIndex, WAD);

        uint256 oraclePrice = IOracle(marketParams.oracle).price();
        uint256 collateralValue = Math.mulDiv(uint256(pos.collateral), oraclePrice, ORACLE_PRICE_SCALE);

        if (debtAssets >= collateralValue) return 0;
        return collateralValue - debtAssets;
    }

    // --- ENTRADA ---

    function supply(uint256 assets, address, bytes calldata) external onlyVault {
        if (assets == 0) revert AmountZero();

        USDC.safeTransferFrom(VAULT, address(this), assets);
        MORPHO.accrueInterest(marketParams);

        uint256 currentUsdc = assets;
        uint256 totalCollateralAdded;

        // Loop Fijo
        for (uint256 i = 0; i < 3; i++) {
            if (currentUsdc < DUST_THRESHOLD) break;

            uint256 cetesBought = _swapUsdcToCetes(currentUsdc);
            totalCollateralAdded += cetesBought;

            MORPHO.supplyCollateral(marketParams, cetesBought, address(this), hex"");

            if (i < 2) { 
                uint256 borrowable = _calculateBorrowableAmount();
                if (borrowable > DUST_THRESHOLD) {
                    (uint256 borrowed, ) = MORPHO.borrow(marketParams, borrowable, 0, address(this), address(this));
                    currentUsdc = borrowed;
                } else {
                    currentUsdc = 0;
                }
            }
        }
        emit Leveraged(assets, totalCollateralAdded);
    }

    // --- SALIDA ---

    function withdraw(uint256 assets, address receiver, bytes calldata) external onlyVault {
        if (assets == 0) revert AmountZero();
        
        uint256 currentBalance = USDC.balanceOf(address(this));
        if (currentBalance >= assets) {
            USDC.safeTransfer(receiver, assets);
            return;
        }

        MORPHO.accrueInterest(marketParams);

        // Loop de Desapalancamiento
        for (uint256 i = 0; i < 5; i++) {
            uint256 needed = assets > USDC.balanceOf(address(this)) 
                ? assets - USDC.balanceOf(address(this)) 
                : 0;
            if (needed < DUST_THRESHOLD) break;

            uint256 maxCollateral = _calculateMaxSafeWithdraw();
            if (maxCollateral == 0) break; 

            MORPHO.withdrawCollateral(marketParams, maxCollateral, address(this), address(this));
            uint256 usdcObtained = _swapCetesToUsdc(maxCollateral);

            IMorpho.Position memory pos = MORPHO.position(MARKET_ID, address(this));
            if (pos.borrowShares > 0) {
                IMorpho.Market memory marketData = MORPHO.market(MARKET_ID);
                uint256 borrowIndex = Math.mulDiv(marketData.totalBorrowAssets, WAD, marketData.totalBorrowShares);
                
                // CAMBIO: Usamos mulDivUp para pagar con seguridad
                uint256 totalDebt = Math.mulDivUp(uint256(pos.borrowShares), borrowIndex, WAD);
                
                uint256 repayAmount = Math.min(usdcObtained, totalDebt);
                if (repayAmount > 0) {
                     MORPHO.repay(marketParams, repayAmount, 0, address(this), hex"");
                }
            }
        }

        uint256 finalBalance = USDC.balanceOf(address(this));
        uint256 transferAmount = Math.min(finalBalance, assets);
        
        if (transferAmount > 0) {
            USDC.safeTransfer(receiver, transferAmount);
        }
        emit Deleveraged(transferAmount);
    }

    // --- HELPERS ---

    function _calculateBorrowableAmount() internal view returns (uint256) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, address(this));
        IMorpho.Market memory marketData = MORPHO.market(MARKET_ID);
        
        uint256 oraclePrice = IOracle(marketParams.oracle).price();
        uint256 collateralValue = Math.mulDiv(uint256(pos.collateral), oraclePrice, ORACLE_PRICE_SCALE);
        
        uint256 maxDebt = Math.mulDiv(collateralValue, TARGET_LTV, WAD);
        
        uint256 borrowIndex = Math.mulDiv(marketData.totalBorrowAssets, WAD, marketData.totalBorrowShares);
        // CAMBIO: Math.Rounding.Ceil reemplazado por mulDivUp
        uint256 currentDebt = Math.mulDivUp(uint256(pos.borrowShares), borrowIndex, WAD);

        if (maxDebt > currentDebt) {
            return maxDebt - currentDebt;
        }
        return 0;
    }

    function _calculateMaxSafeWithdraw() internal view returns (uint256) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, address(this));
        if (pos.collateral == 0) return 0;

        IMorpho.Market memory marketData = MORPHO.market(MARKET_ID);
        uint256 borrowIndex = Math.mulDiv(marketData.totalBorrowAssets, WAD, marketData.totalBorrowShares);
        // CAMBIO: mulDivUp
        uint256 currentDebt = Math.mulDivUp(uint256(pos.borrowShares), borrowIndex, WAD);

        if (currentDebt == 0) return pos.collateral;

        uint256 oraclePrice = IOracle(marketParams.oracle).price();
        uint256 safetyLtv = 0.85e18; 

        uint256 minCollateralValue = Math.mulDiv(currentDebt, WAD, safetyLtv);
        uint256 currentCollateralValue = Math.mulDiv(uint256(pos.collateral), oraclePrice, ORACLE_PRICE_SCALE);

        if (currentCollateralValue <= minCollateralValue) return 0;

        uint256 excessValue = currentCollateralValue - minCollateralValue;
        return Math.mulDiv(excessValue, ORACLE_PRICE_SCALE, oraclePrice);
    }

    function _swapUsdcToCetes(uint256 amountIn) internal returns (uint256) {
        uint256 oraclePrice = IOracle(marketParams.oracle).price(); 
        uint256 expectedOut = Math.mulDiv(amountIn, ORACLE_PRICE_SCALE, oraclePrice);
        uint256 minOut = Math.mulDiv(expectedOut, WAD - MAX_SLIPPAGE, WAD);

        ISlipstreamRouter.ExactInputSingleParams memory params = ISlipstreamRouter.ExactInputSingleParams({
            tokenIn: address(USDC),
            tokenOut: address(CETES),
            tickSpacing: TICK_SPACING,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });

        return ROUTER.exactInputSingle(params);
    }

    function _swapCetesToUsdc(uint256 amountIn) internal returns (uint256) {
        uint256 oraclePrice = IOracle(marketParams.oracle).price();
        uint256 expectedOut = Math.mulDiv(amountIn, oraclePrice, ORACLE_PRICE_SCALE);
        uint256 minOut = Math.mulDiv(expectedOut, WAD - MAX_SLIPPAGE, WAD);

        ISlipstreamRouter.ExactInputSingleParams memory params = ISlipstreamRouter.ExactInputSingleParams({
            tokenIn: address(CETES),
            tokenOut: address(USDC),
            tickSpacing: TICK_SPACING,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });

        return ROUTER.exactInputSingle(params);
    }
}