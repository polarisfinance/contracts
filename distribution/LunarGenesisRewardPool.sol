// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// Note that this pool has no minter key of LUNAR (rewards).
// Instead, the governance will call LUNAR distributeReward method and send reward to this pool at the beginning.
contract LunarGenesisRewardPool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. LUNAR to distribute.
        uint256 lastRewardTime; // Last time that LUNAR distribution occurs.
        uint256 accLunarPerShare; // Accumulated LUNAR per share, times 1e18. See below.
        bool isStarted; // if lastRewardBlock has passed
        uint256 daoFee;
    }

    IERC20 public lunar;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when LUNAR mining starts.
    uint256 public poolStartTime;

    // The time when LUNAR mining ends.
    uint256 public poolEndTime;

    address public daoAddress;
    // TESTNET
    // uint256 public lunarPerSecond = 3.0555555e18; // 11000 LUNAR / (1h * 60min * 60s)
    // uint256 public runningTime = 24 hours; // 1 hours
    // uint256 public constant TOTAL_REWARDS = 11000e18;
    // END TESTNET

    // MAINNET
    uint256 public lunarPerSecond = 0.0081018519e18; // 700 LUNAR / (24h * 60min * 60s)
    uint256 public runningTime = 1 days; // 1 days
    uint256 public constant TOTAL_REWARDS = 700e18;
    // END MAINNET

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _lunar,
        uint256 _poolStartTime,
        address _daoAddress
    ) public {
        require(block.timestamp < _poolStartTime, "late");
        if (_lunar != address(0)) lunar = IERC20(_lunar);
        daoAddress = _daoAddress;
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "LunarGenesisPool: caller is not the operator");
        _;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "LunarGenesisPool: existing pool?");
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime,
        uint _daoFee
    ) public onlyOperator {
        require(_daoFee <= 100, "fee can not be above 1%");
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted =
        (_lastRewardTime <= poolStartTime) ||
        (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
            token : _token,
            allocPoint : _allocPoint,
            lastRewardTime : _lastRewardTime,
            accLunarPerShare : 0,
            isStarted : _isStarted,
            daoFee: _daoFee
            }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's LUNAR allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(lunarPerSecond);
            return poolEndTime.sub(_fromTime).mul(lunarPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(lunarPerSecond);
            return _toTime.sub(_fromTime).mul(lunarPerSecond);
        }
    }

    // View function to see pending LUNAR on frontend.
    function pendingLUNAR(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accLunarPerShare = pool.accLunarPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _lunarReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accLunarPerShare = accLunarPerShare.add(_lunarReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accLunarPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _lunarReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accLunarPerShare = pool.accLunarPerShare.add(_lunarReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accLunarPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeLunarTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            if (pool.daoFee > 0) {
                uint256 _fee = _amount.mul(pool.daoFee).div(10000);
                pool.token.safeTransfer(daoAddress, _fee);
                user.amount = user.amount.add(_amount.sub(_fee));
            }
            else {
                user.amount = user.amount.add(_amount);
            }
            
        }
        user.rewardDebt = user.amount.mul(pool.accLunarPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accLunarPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeLunarTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accLunarPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe LUNAR transfer function, just in case if rounding error causes pool to not have enough LUNARs.
    function safeLunarTransfer(address _to, uint256 _amount) internal {
        uint256 _lunarBalance = lunar.balanceOf(address(this));
        if (_lunarBalance > 0) {
            if (_amount > _lunarBalance) {
                lunar.safeTransfer(_to, _lunarBalance);
            } else {
                lunar.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.timestamp < poolEndTime + 90 days) {
            // do not allow to drain core token (LUNAR or lps) if less than 90 days after pool ends
            require(_token != lunar, "lunar");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }

    function setDaoFee(uint256 _pid, uint _fee) external onlyOperator {
        require(_fee <= 100, "fee can not be above 1%");
        PoolInfo storage pool = poolInfo[_pid];
        pool.daoFee = _fee;
    }
}
