// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract NewFarmingC2N is Ownable {
    //引用安全库
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    //定义用户结构体
    struct UserInfo {
        //用户质押的代币数量
        uint256 amount;
        //用户的奖励负债
        uint256 rewardDebt;
    }
    //质押池信息
    struct PoolInfo {
        IERC20 lpToken; //池中代币地址
        uint256 allocPoint; //分配给该池的奖励比例
        uint256 lastRewardTimestamp; //上次奖励分配的时间戳
        uint256 accERC20PerShare; //每份lp代币对应的累计erc20奖励数量
        uint256 totalDeposits; //所有用户质押到池中的总量,用来计算每个用户的奖励比例
    }

    IERC20 public erc20; //erc20代币合约地址
    uint256 public paidOut; //已经支付过的所有奖励
    uint256 public rewardPerSecond; //每秒产生的erc20代币奖励的奖励数量
    //总的奖励额。
    uint256 public totalRewards;
    //所有矿池的数组
    PoolInfo[] public poolInfo;
    //记录每个用户在每个矿池中的信息
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    //所有矿池的分配点总和
    uint256 public totalAllocPoint;
    //奖励开始和结束的时间戳
    uint256 public startTimestamp;
    uint256 public endTimestamp;

    /**
        事件
    */
    //1.转入lp代币
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

        /**
    1. 编写合约的构造函数：
  - 初始化ERC20代币地址、奖励生成速率和起始时间戳。
   */
   constructor (IERC20 _erc20, uint256 _rewardPerSecond, uint256 _startTimestamp) public {
        erc20 = _erc20;
        rewardPerSecond = _rewardPerSecond;
        startTimestamp = _startTimestamp;
        endTimestamp = _startTimestamp;
   }

   //池子长度
    function poolLength() external view returns (uint256){
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
    function fund(uint256 _amount) public {
        require(block.timestamp < endTimestamp,"time out");
        erc20.safeTransferFrom(address(msg.sender), address(this), _amount);
        endTimestamp += _amount.div(rewardPerSecond);
        totalRewards = totalRewards.add(_amount);
    }
    /**
        2. 实现添加新的LP池子的功能（add函数）：奖励分配比例,lp代币,是否需要更新合约资金
        - 按照poolInfo的结构，添加一个pool，并指定是否需要批量update合约资金信息
        - 注意判断lastRewardTimestamp逻辑，如果大于startTimestamp，则为当前块高时间，否则还未开始发放奖励，设置为startTimestamp
        - 学习权限管理，确保只有合约拥有者可以添加池子。
    */
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            //需要更新合约资金
            massUpdatePools();
        }
        //更新上次奖励分配的时间戳
        uint256 lastRewardTimestamp = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;
        //维护奖励分配比例
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardTimestamp : lastRewardTimestamp,
            accERC20PerShare : 0,
            totalDeposits : 0
        }));
    }
    //更新指定池的分配点数,指定池是指定池在数组中的索引
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner{
        if (_withUpdate) {
            massUpdatePools();
        }
        //先去掉旧的再加上新的,实现更新
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        //更新指定池的分配点数
        poolInfo[_pid].allocPoint = _allocPoint;
    }
    //查看用户在指定池中的质押数量
    function deposited(uint256 _pid, address _user) external view returns(uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        return user.amount;
    }
    //查看用户在指定池中待领取的奖励数量。
    function pending(uint256 _pid, address _user) external view returns (uint256) {
        //指定池
        PoolInfo storage pool =  poolInfo[_pid];
        //池子总质押量
        uint256 lpSupply = pool.totalDeposits;
        uint256 accERC20PerShare = pool.accERC20PerShare;
        //用户
        UserInfo storage user = userInfo[_pid][_user];
        if(block.timestamp > pool.lastRewardTimestamp && lpSupply != 0){
            //最新时间
            uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;
            //最新变动时间
            uint256 timestampToCompare = pool.lastRewardTimestamp < endTimestamp ? pool.lastRewardTimestamp : endTimestamp;
            //时间差
            uint256 nrOfSeconds = lastTimestamp.sub(timestampToCompare);
            //时间差收益
            uint256 erc20Reward = nrOfSeconds.mul(rewardPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            //更新最新每秒收益
            accERC20PerShare = accERC20PerShare.add(erc20Reward.mul(1e36).div(lpSupply));
        }
        return user.amount.mul(accERC20PerShare).div(1e36).sub(user.rewardDebt);
    }
    //    //查看合约中尚未支付的奖励总量。
    function totalPending() external view returns (uint256) {
        if(block.timestamp <= startTimestamp){
            //还没开始
            return 0;
        }
        //最新时间
        uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;
        //每秒代币奖励*总时间 - 已支付
        return rewardPerSecond.mul(lastTimestamp - startTimestamp).sub(paidOut);
    }

    //更新合约资金
    function massUpdatePools()public{
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }
    //更新池中变量
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
    function updatePool(uint256 _pid) public {
        //当前矿池,使用storage ,可直接操作状态变量,不用copy到内存中,避免数据拷贝,效率更高,减少gas消耗
        PoolInfo storage pool = poolInfo[_pid];
        //最后更新时间
        uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;
        if (lastTimestamp <= pool.lastRewardTimestamp){
            //无效操作
            return;
        }
        //所有用户质押的总量
        uint256 lpSupply = pool.totalDeposits;
        if(lpSupply == 0){ 
            pool.lastRewardTimestamp = lastTimestamp;
            return;
        }
        //上次和这次的时间差
        uint256 nrOfSeconds = lastTimestamp.sub(pool.lastRewardTimestamp);
        //(时间差*每秒奖励*(分配点数/总分配点数) = 新增的ERC20奖励量
        uint256 erc20Reward = nrOfSeconds.mul(rewardPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
        //此时每份lp代币对应的累计erc20奖励数量 每份奖励 = 原每份奖励 + (新增的erc20奖励量*1e36)扩容取整/总质押量
        pool.accERC20PerShare = pool.accERC20PerShare.add(erc20Reward.mul(1e36).div(lpSupply));
        //更新最新的分配时间
        pool.lastRewardTimestamp = block.timestamp;
    }
    //用户向合约存入 LP 代币，质押以获取奖励
    /**
        - Deposit: 函数允许用户将LP代币存入指定的矿池，以参与ERC20代币的分配。
      - 更新矿池奖励数据：调用updatePool函数，保证矿池数据是最新的，确保奖励计算的正确性。
      - 计算并发放挂起的奖励：如果用户已有存款，则计算用户从上次存款后到现在的挂起奖励，并通过erc20Transfer发放这些奖励。
      - 接收用户存款：通过safeTransferFrom函数，从用户账户安全地转移LP代币到合约地址。
      - 更新用户存款数据：更新用户在该矿池的存款总额和奖励债务，为下次奖励计算做准备。
      - 记录事件：发出Deposit事件，记录此次存款操作的详细信息。
    */
    function deposit(uint256 _pid, uint256 _amount) public {
        //指定矿池
        PoolInfo storage pool = poolInfo[_pid];
        //当前用户信息
        UserInfo storage user =  userInfo[_pid][msg.sender];
        //更新池子
        updatePool(_pid);
        //把erc20转出去,并把lp代币转进来
        if(user.amount > 0){
            //账户数量*每份奖励数/1e36单位 - 奖励负债 = 计算并发放挂起的奖励
            uint256 pendingAmount =  user.amount.mul(pool.accERC20PerShare).div(1e36).sub(user.rewardDebt);
            erc20Transfer(msg.sender,pendingAmount);
        }
        //把lp代币转进来
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        //池中的总代币量
        pool.totalDeposits = pool.totalDeposits.add(_amount);

        //更新用户数据
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accERC20PerShare).div(1e36);
        //事件
        emit Deposit(msg.sender,_pid,_amount);
    }

    /**
    - Withdraw
      - 更新矿池奖励数据：调用updatePool函数更新矿池的奖励变量，确保奖励的准确性。
      - 计算并发放挂起的奖励：计算用户应得的挂起奖励，并通过erc20Transfer将奖励发放给用户。
      - 提取LP代币：安全地将用户请求的LP代币数量从合约转移到用户账户。
      - 更新用户存款数据：更新用户的存款总额和奖励债务，准确记录用户的新状态。
      - 记录事件：发出Withdraw事件，记录此次提款操作的详细信息。
     */
    function withdraw(uint256 _pid, uint256 _amount) public {
        //指定池
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        //校验余额
        require(user.amount >= _amount,"amount not enough");
        //更新池数据
        updatePool(_pid);
        //待处理余额
        uint256 pendingAmount = user.amount.mul(pool.accERC20PerShare).div(1e36);
        //转账
        erc20Transfer(msg.sender, pendingAmount);
        //处理账号余额
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accERC20PerShare).div(1e36);
        pool.lpToken.safeTransfer(address(msg.sender),_amount);
        pool.totalDeposits = pool.totalDeposits.sub(_amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }
    //让用户在紧急情况下提取他们的LP代币，但不获取奖励
    function emergencyWithdraw(uint256 _pid) public {
        //指定池
        PoolInfo storage pool = poolInfo[_pid];
        //指定用户
        UserInfo storage user = userInfo[_pid][msg.sender];
        //转移lp代币
        pool.lpToken.safeTransfer(address(msg.sender),user.amount);
        //处理变量
        pool.totalDeposits = pool.totalDeposits.sub(user.amount);
        //触发事件
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        //处理用户信息
        user.amount = 0;
        user.rewardDebt = 0;

    }
    //转移 ERC20 奖励并更新已支付的奖励总量
    function erc20Transfer(address _to, uint256 _amount) internal {
        erc20.transfer(_to, _amount);
        paidOut += _amount;
    }
}
