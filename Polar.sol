// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./lib/SafeMath8.sol";
import "./owner/Operator.sol";
import "./interfaces/IOracle.sol";

/*
    ____        __           _         _______
   / __ \____  / /___ ______(_)____   / ____(_)___  ____ _____  ________
  / /_/ / __ \/ / __ `/ ___/ / ___/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \
 / ____/ /_/ / / /_/ / /  / (__  )  / __/ / / / / / /_/ / / / / /__/  __/
/_/    \____/_/\__,_/_/  /_/____/  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/

    https://polarisfinance.io
*/
contract Polar is ERC20Burnable, Operator {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    // Initial distribution for the first 24h genesis pools
    uint256 public constant INITIAL_GENESIS_POOL_DISTRIBUTION = 4000e18;
    // Initial distribution for the day 2-10 Polar-NEAR LP -> Polar pool
    uint256 public constant INITIAL_POLAR_POOL_DISTRIBUTION = 9000e18;
    // Distribution for airdrops wallet
    uint256 public constant INITIAL_AIRDROP_WALLET_DISTRIBUTION = 1000e18;

    // Have the rewards been distributed to the pools
    bool public rewardPoolDistributed = false;

    // Address of the Oracle
    address public polarOracle;

    /**
     * @notice Constructs the POLAR ERC-20 contract.
     */
    constructor() public ERC20("POLAR", "POLAR") {
        // Mints 1 POLAR to contract creator for initial pool setup
        _mint(msg.sender, 1e18);
    }

    function _getPolarPrice() internal view returns (uint256 _polarPrice) {
        try IOracle(polarOracle).consult(address(this), 1e18) returns (uint144 _price) {
            return uint256(_price);
        } catch {
            revert("Polar: failed to fetch POLAR price from Oracle");
        }
    }

    function setPolarOracle(address _polarOracle) public onlyOperator {
        require(_polarOracle != address(0), "oracle address cannot be 0 address");
        polarOracle = _polarOracle;
    }

    /**
     * @notice Operator mints POLAR to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of POLAR to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
            _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _genesisPool,
        address _polarPool,
        address _airdropWallet
    ) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_genesisPool != address(0), "!_genesisPool");
        require(_polarPool != address(0), "!_polarPool");
        require(_airdropWallet != address(0), "!_airdropWallet");
        rewardPoolDistributed = true;
        _mint(_genesisPool, INITIAL_GENESIS_POOL_DISTRIBUTION);
        _mint(_polarPool, INITIAL_POLAR_POOL_DISTRIBUTION);
        _mint(_airdropWallet, INITIAL_AIRDROP_WALLET_DISTRIBUTION);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}