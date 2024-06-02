// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Farm distributes the ERC20 rewards based on staked LP to each user.
//
// Cloned from https://github.com/SashimiProject/sashimiswap/blob/master/contracts/MasterChef.sol
// Modified by LTO Network to work for non-mintable ERC20.

contract FarmingC2N is Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of ERC20s
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accERC20PerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accERC20PerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;             // Address of LP token contract.
        uint256 allocPoint;         // How many allocation points assigned to this pool. ERC20s to distribute per block.
        uint256 lastRewardTimestamp;    // Last timstamp that ERC20s distribution occurs.
        uint256 accERC20PerShare;   // Accumulated ERC20s per share, times 1e36.
        uint256 totalDeposits; // Total amount of tokens deposited at the moment (staked)
    }


    // Address of the ERC20 Token contract.
    //代表ERC20奖励代币的合约地址
    IERC20 public erc20;
    // The total amount of ERC20 that's paid out as reward.
    //已经支付的奖励总额。
    uint256 public paidOut;
    // ERC20 tokens rewarded per second.
    //每秒产生的ERC20代币奖励数量
    uint256 public rewardPerSecond;
    // Total rewards added to farm
    //总的奖励额。
    uint256 public totalRewards;
    // Info of each pool.
    //所有矿池的数组
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    //记录每个用户在每个矿池中的信息
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    //    //所有矿池的分配点总和
    uint256 public totalAllocPoint;
    //奖励开始和结束的时间戳
    // The timestamp when farming starts.
    uint256 public startTimestamp;
    // The timestamp when farming ends.
    uint256 public endTimestamp;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    /**
    1. 编写合约的构造函数：
  - 初始化ERC20代币地址、奖励生成速率和起始时间戳。
   */

    constructor(IERC20 _erc20, uint256 _rewardPerSecond, uint256 _startTimestamp) public {
        erc20 = _erc20;
        rewardPerSecond = _rewardPerSecond;
        startTimestamp = _startTimestamp;
        endTimestamp = _startTimestamp;
    }

    // Number of LP pools
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }
    /**
    合约的所有者或授权用户可以通过此函数向合约注入ERC20代币，以延长奖励分发时间。
需求：
1. 确保合约在当前时间点仍可接收资金，即未超过奖励结束时间
2. 从调用者账户向合约账户安全转移指定数量的ERC20代币
3.  根据注入的资金量和每秒奖励数量，计算并延长奖励发放的结束时间
4.  更新合约记录的总奖励量
 */
    // Fund the farm, increase the end block
    function fund(uint256 _amount) public {
        require(block.timestamp < endTimestamp, "fund: too late, the farm is closed");
        erc20.safeTransferFrom(address(msg.sender), address(this), _amount);
        endTimestamp += _amount.div(rewardPerSecond);
        totalRewards = totalRewards.add(_amount);
    }

    /**
    2. 实现添加新的LP池子的功能（add函数）：
  - 按照poolInfo的结构，添加一个pool，并指定是否需要批量update合约资金信息
  - 注意判断lastRewardTimestamp逻辑，如果大于startTimestamp，则为当前块高时间，否则还未开始发放奖励，设置为startTimestamp
  - 学习权限管理，确保只有合约拥有者可以添加池子。
     */
    // Add a new lp to the pool. Can only be called by the owner.
    // DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTimestamp = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardTimestamp : lastRewardTimestamp,
        accERC20PerShare : 0,
        totalDeposits : 0
        }));
    }

    // Update the given pool's ERC20 allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // View function to see deposited LP for a user.
    function deposited(uint256 _pid, address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        return user.amount;
    }

    // View function to see pending ERC20s for a user.
    function pending(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accERC20PerShare = pool.accERC20PerShare;

        uint256 lpSupply = pool.totalDeposits;

        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;
            uint256 timestampToCompare = pool.lastRewardTimestamp < endTimestamp ? pool.lastRewardTimestamp : endTimestamp;
            uint256 nrOfSeconds = lastTimestamp.sub(timestampToCompare);
            uint256 erc20Reward = nrOfSeconds.mul(rewardPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accERC20PerShare = accERC20PerShare.add(erc20Reward.mul(1e36).div(lpSupply));
        }
        return user.amount.mul(accERC20PerShare).div(1e36).sub(user.rewardDebt);
    }

    // View function for total reward the farm has yet to pay out.
    function totalPending() external view returns (uint256) {
        if (block.timestamp <= startTimestamp) {
            return 0;
        }

        uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;
        return rewardPerSecond.mul(lastTimestamp - startTimestamp).sub(paidOut);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /**
    编写更新单个池子奖励的函数（updatePool）：
- 理解如何计算每个池子的累计ERC20代币每股份额。
- 需求说明: 该函数主要功能是确保矿池的奖励数据是最新的，并根据最新数据更新矿池的状态，需要实现以下功能：
  1. 更新矿池的奖励变量
  updatePool需要针对指定的矿池ID更新矿池中的关键奖励变量，确保其反映了最新的奖励情况。这包括：
  - 更新最后奖励时间戳： 如果池子还未结束，将矿池的lastRewardTimestamp更新为当前时间戳，以确保奖励的计算与时间同步，否则lastRewardTimestamp = endTimestamp
  - 计算新增的奖励：根据从上次奖励时间到现在的时间差，结合矿池的分配点数和全局的每秒奖励率，计算此期间应该新增的ERC20奖励量。
  2. 累加每股累积奖励
  根据新计算出的奖励量，更新矿池的accERC20PerShare（每股累积ERC20奖励）：
  - 奖励分配：将新增的奖励量按照矿池中当前LP代币的总量（totalDeposits）进行分配，计算出每份LP代币所能获得的奖励，并更新accERC20PerShare。
  3. 确保时间和奖励的正确性
  处理边界条件，确保在计算奖励时，各种时间点和奖励量的处理是合理和正确的：
  - 时间边界处理：如果当前时间已经超过了奖励分配的结束时间（endTimestamp），则需要相应调整逻辑以防止奖励超发。
  - LP代币总量检查：如果矿池中没有LP代币（totalDeposits为0），则不进行奖励计算，直接更新时间戳。
     */
    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;

        if (lastTimestamp <= pool.lastRewardTimestamp) {
            return;
        }
        uint256 lpSupply = pool.totalDeposits;

        if (lpSupply == 0) {
            pool.lastRewardTimestamp = lastTimestamp;
            return;
        }

        uint256 nrOfSeconds = lastTimestamp.sub(pool.lastRewardTimestamp);
        uint256 erc20Reward = nrOfSeconds.mul(rewardPerSecond).mul(pool.allocPoint).div(totalAllocPoint);

        pool.accERC20PerShare = pool.accERC20PerShare.add(erc20Reward.mul(1e36).div(lpSupply));
        pool.lastRewardTimestamp = block.timestamp;
    }

    // Deposit LP tokens to Farm for ERC20 allocation.
    /**
    - Deposit: 函数允许用户将LP代币存入指定的矿池，以参与ERC20代币的分配。
      - 更新矿池奖励数据：调用updatePool函数，保证矿池数据是最新的，确保奖励计算的正确性。
      - 计算并发放挂起的奖励：如果用户已有存款，则计算用户从上次存款后到现在的挂起奖励，并通过erc20Transfer发放这些奖励。
      - 接收用户存款：通过safeTransferFrom函数，从用户账户安全地转移LP代币到合约地址。
      - 更新用户存款数据：更新用户在该矿池的存款总额和奖励债务，为下次奖励计算做准备。
      - 记录事件：发出Deposit事件，记录此次存款操作的详细信息。
     */
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pendingAmount = user.amount.mul(pool.accERC20PerShare).div(1e36).sub(user.rewardDebt);
            erc20Transfer(msg.sender, pendingAmount);
        }

        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        pool.totalDeposits = pool.totalDeposits.add(_amount);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accERC20PerShare).div(1e36);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from Farm.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: can't withdraw more than deposit");
        updatePool(_pid);

        uint256 pendingAmount = user.amount.mul(pool.accERC20PerShare).div(1e36).sub(user.rewardDebt);

        erc20Transfer(msg.sender, pendingAmount);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accERC20PerShare).div(1e36);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        pool.totalDeposits = pool.totalDeposits.sub(_amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        pool.totalDeposits = pool.totalDeposits.sub(user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Transfer ERC20 and update the required ERC20 to payout all rewards
    function erc20Transfer(address _to, uint256 _amount) internal {
        erc20.transfer(_to, _amount);
        paidOut += _amount;
    }
}
