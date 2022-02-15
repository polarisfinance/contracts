// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IMasonry.sol";

/*
    ____        __           _         _______
   / __ \____  / /___ ______(_)____   / ____(_)___  ____ _____  ________
  / /_/ / __ \/ / __ `/ ___/ / ___/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \
 / ____/ /_/ / / /_/ / /  / (__  )  / __/ / / / / / /_/ / / / / /__/  __/
/_/    \____/_/\__,_/_/  /_/____/  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/

    https://polarisfinance.io
*/
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
    address[] public excludedFromTotalSupply = [
        address(0x7afd06811120462e86dbd41554445928C7AFBCAD), // polarGenesisPool
        address(0x5749c1374cc9DE28B94cf054dEb303D4cA3464bF) // new polarRewardPool
    ];

    // core components
    address public polar;
    address public pbond;
    address public spolar;

    address public masonry;
    address public polarOracle;

    // price
    uint256 public polarPriceOne;
    uint256 public polarPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of POLAR price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochpolarPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra POLAR during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 polarAmount, uint256 bondAmount);
    event Boughpbonds(address indexed from, uint256 polarAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event MasonryFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getpolarPrice() > polarPriceCeiling) ? 0 : getpolarCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(polar).operator() == address(this) &&
                IBasisAsset(pbond).operator() == address(this) &&
                IBasisAsset(spolar).operator() == address(this) &&
                Operator(masonry).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getpolarPrice() public view returns (uint256 polarPrice) {
        try IOracle(polarOracle).consult(polar, 1e18) returns (uint144 price) {
            return uint256(price/1e6);
        } catch {
            revert("Treasury: failed to consult POLAR price from the oracle");
        }
    }

    function getpolarUpdatedPrice() public view returns (uint256 _polarPrice) {
        try IOracle(polarOracle).twap(polar, 1e18) returns (uint144 price) {
            return uint256(price/1e6);
        } catch {
            revert("Treasury: failed to consult POLAR price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnablepolarLeft() public view returns (uint256 _burnablepolarLeft) {
        uint256 _polarPrice = getpolarPrice();
        if (_polarPrice <= polarPriceOne) {
            uint256 _polarSupply = getpolarCirculatingSupply();
            uint256 _bondMaxSupply = _polarSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(pbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnablepolar = _maxMintableBond.mul(_polarPrice).div(1e18);
                _burnablepolarLeft = Math.min(epochSupplyContractionLeft, _maxBurnablepolar);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _polarPrice = getpolarPrice();
        if (_polarPrice > polarPriceCeiling) {
            uint256 _totalpolar = IERC20(polar).balanceOf(address(this));
            uint256 _rate = gepbondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalpolar.mul(1e18).div(_rate);
            }
        }
    }

    function gepbondDiscountRate() public view returns (uint256 _rate) {
        uint256 _polarPrice = getpolarPrice();
        if (_polarPrice <= polarPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = polarPriceOne;
            } else {
                uint256 _bondAmount = polarPriceOne.mul(1e18).div(_polarPrice); // to burn 1 POLAR
                uint256 _discountAmount = _bondAmount.sub(polarPriceOne).mul(discountPercent).div(10000);
                _rate = polarPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function gepbondPremiumRate() public view returns (uint256 _rate) {
        uint256 _polarPrice = getpolarPrice();
        if (_polarPrice > polarPriceCeiling) {
            uint256 _polarPricePremiumThreshold = polarPriceOne.mul(premiumThreshold).div(100);
            if (_polarPrice >= _polarPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _polarPrice.sub(polarPriceOne).mul(premiumPercent).div(10000);
                _rate = polarPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = polarPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _polar,
        address _pbond,
        address _spolar,
        address _polarOracle,
        address _masonry,
        uint256 _startTime
    ) public notInitialized {
        polar = _polar;
        pbond = _pbond;
        spolar = _spolar;
        polarOracle = _polarOracle;
        masonry = _masonry;
        startTime = _startTime;

        polarPriceOne = 1e18;
        polarPriceCeiling = polarPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0e18, 500000e18, 1000000e18, 1500000e18, 2000000e18, 5000000e18, 10000000e18, 20000000e18, 50000000e18];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for masonry
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn POLAR and mint pbond)
        maxDebtRatioPercent = 3500; // Upto 35% supply of pbond to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 28;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(polar).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setMasonry(address _masonry) external onlyOperator {
        masonry = _masonry;
    }

    function setpolarOracle(address _polarOracle) external onlyOperator {
        polarOracle = _polarOracle;
    }

    function setpolarPriceCeiling(uint256 _polarPriceCeiling) external onlyOperator {
        require(_polarPriceCeiling >= polarPriceOne && _polarPriceCeiling <= polarPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        polarPriceCeiling = _polarPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function sepbondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= polarPriceCeiling, "_premiumThreshold exceeds polarPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updatepolarPrice() internal {
        try IOracle(polarOracle).update() {} catch {}
    }

    function getpolarCirculatingSupply() public view returns (uint256) {
        IERC20 polarErc20 = IERC20(polar);
        uint256 totalSupply = polarErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(polarErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _polarAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_polarAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 polarPrice = getpolarPrice();
        require(polarPrice == targetPrice, "Treasury: POLAR price moved");
        require(
            polarPrice < polarPriceOne, // price < $1
            "Treasury: polarPrice not eligible for bond purchase"
        );

        require(_polarAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = gepbondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _polarAmount.mul(_rate).div(1e18);
        uint256 polarSupply = getpolarCirculatingSupply();
        uint256 newBondSupply = IERC20(pbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= polarSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(polar).burnFrom(msg.sender, _polarAmount);
        IBasisAsset(pbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_polarAmount);
        _updatepolarPrice();

        emit Boughpbonds(msg.sender, _polarAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 polarPrice = getpolarPrice();
        require(polarPrice == targetPrice, "Treasury: POLAR price moved");
        require(
            polarPrice > polarPriceCeiling, // price > $1.01
            "Treasury: polarPrice not eligible for bond purchase"
        );

        uint256 _rate = gepbondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _polarAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(polar).balanceOf(address(this)) >= _polarAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _polarAmount));

        IBasisAsset(pbond).burnFrom(msg.sender, _bondAmount);
        IERC20(polar).safeTransfer(msg.sender, _polarAmount);

        _updatepolarPrice();

        emit RedeemedBonds(msg.sender, _polarAmount, _bondAmount);
    }

    function _sendToMasonry(uint256 _amount) internal {
        IBasisAsset(polar).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(polar).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(polar).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(polar).safeApprove(masonry, 0);
        IERC20(polar).safeApprove(masonry, _amount);
        IMasonry(masonry).allocateSeigniorage(_amount);
        emit MasonryFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _polarSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_polarSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updatepolarPrice();
        previousEpochpolarPrice = getpolarPrice();
        uint256 polarSupply = getpolarCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToMasonry(polarSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochpolarPrice > polarPriceCeiling) {
                // Expansion ($POLAR Price > 1 $FTM): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(pbond).totalSupply();
                uint256 _percentage = previousEpochpolarPrice.sub(polarPriceOne);
                uint256 _savedForBond;
                uint256 _savedForMasonry;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(polarSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForMasonry = polarSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = polarSupply.mul(_percentage).div(1e18);
                    _savedForMasonry = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForMasonry);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForMasonry > 0) {
                    _sendToMasonry(_savedForMasonry);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(polar).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(polar), "polar");
        require(address(_token) != address(pbond), "bond");
        require(address(_token) != address(spolar), "share");
        _token.safeTransfer(_to, _amount);
    }

    function masonrySetOperator(address _operator) external onlyOperator {
        IMasonry(masonry).setOperator(_operator);
    }

    function masonrySetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IMasonry(masonry).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function masonryAllocateSeigniorage(uint256 amount) external onlyOperator {
        IMasonry(masonry).allocateSeigniorage(amount);
    }

    function masonryGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IMasonry(masonry).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
