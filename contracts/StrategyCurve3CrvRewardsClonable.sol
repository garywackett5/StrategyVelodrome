// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/curve.sol";
import "./interfaces/yearn.sol";
import {IUniswapV2Router02} from "./interfaces/uniswap.sol";
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

interface IUniV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

abstract contract StrategyCurveBase is BaseStrategy {
    using Address for address;

    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.

    // curve infrastructure contracts
    ICurveStrategyProxy public proxy; // Below we set it to Yearn's Updated v4 StrategyProxy
    address public gauge; // Curve gauge contract, most are tokenized, held by Yearn's voter

    // keepCRV stuff
    uint256 public keepCRV; // the percentage of CRV we re-lock for boost (in basis points)
    address public constant voter = 0xF147b8125d2ef93FB6965Db97D6746952a133934; // Yearn's veCRV voter
    uint256 internal constant FEE_DENOMINATOR = 10000; // this means all of our fee values are in basis points

    // Swap stuff
    address internal constant sushiswap =
        0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F; // we use this to sell our bonus token

    IERC20 internal constant crv =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 internal constant weth =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint256 public creditThreshold; // amount of credit in underlying tokens that will automatically trigger a harvest
    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    string internal stratName;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) public BaseStrategy(_vault) {}

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    ///@notice How much want we have staked in Curve's gauge
    function stakedBalance() public view returns (uint256) {
        return proxy.balanceOf(gauge);
    }

    ///@notice Balance of want sitting in our strategy
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(stakedBalance());
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // Send all of our LP tokens to the proxy and deposit to the gauge if we have any
        uint256 _toInvest = balanceOfWant();
        if (_toInvest > 0) {
            want.safeTransfer(address(proxy), _toInvest);
            proxy.deposit(gauge, address(want));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBal = balanceOfWant();
        if (_amountNeeded > _wantBal) {
            // check if we have enough free funds to cover the withdrawal
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                proxy.withdraw(
                    gauge,
                    address(want),
                    Math.min(_stakedBal, _amountNeeded.sub(_wantBal))
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBal);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    // fire sale, get rid of it all!
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            // don't bother withdrawing zero
            proxy.withdraw(gauge, address(want), _stakedBal);
        }
        return balanceOfWant();
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Use to update Yearn's StrategyProxy contract as needed in case of upgrades.
    function setProxy(address _proxy) external onlyGovernance {
        proxy = ICurveStrategyProxy(_proxy);
    }

    // Set the amount of CRV to be locked in Yearn's veCRV voter from each harvest. Default is 10%.
    function setKeepCRV(uint256 _keepCRV) external onlyVaultManagers {
        require(_keepCRV <= 10_000);
        keepCRV = _keepCRV;
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyVaultManagers
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }
}

contract StrategyCurve3CrvRewardsClonable is StrategyCurveBase {
    /* ========== STATE VARIABLES ========== */
    // these will likely change across different wants.

    // Curve stuff
    address public curve; ///@notice This is our curve pool specific to this vault
    ICurveFi internal constant zapContract =
        ICurveFi(0xA79828DF1850E8a3A3064576f380D90aECDD3359); // this is used for depositing to all 3Crv metapools

    ICurveFi internal constant crveth =
        ICurveFi(0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511); // use curve's new CRV-ETH crypto pool to sell our CRV

    // we use these to deposit to our curve pool
    address public targetStable; ///@notice This is the stablecoin we are using to take profits and deposit into 3Crv.
    address internal constant uniswapv3 =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    IERC20 internal constant usdt =
        IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 internal constant usdc =
        IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal constant dai =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    uint24 public uniStableFee; // this is equal to 0.05%, can change this later if a different path becomes more optimal

    // rewards token info. we can have more than 1 reward token but this is rare, so we don't include this in the template
    IERC20 public rewardsToken;
    bool public hasRewards;
    address[] internal rewardsPath;

    // check for cloning
    bool internal isOriginal = true;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        address _gauge,
        address _curvePool,
        string memory _name
    ) public StrategyCurveBase(_vault) {
        _initializeStrat(_gauge, _curvePool, _name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // we use this to clone our original strategy to other vaults
    function cloneCurve3CrvRewards(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _gauge,
        address _curvePool,
        string memory _name
    ) external returns (address newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategyCurve3CrvRewardsClonable(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _gauge,
            _curvePool,
            _name
        );

        emit Cloned(newStrategy);
    }

    // this will only be called by the clone function above
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _gauge,
        address _curvePool,
        string memory _name
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_gauge, _curvePool, _name);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(
        address _gauge,
        address _curvePool,
        string memory _name
    ) internal {
        // make sure that we haven't initialized this before
        require(address(curve) == address(0)); // already initialized.

        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 100 days; // 100 days in seconds
        minReportDelay = 21 days; // 21 days in seconds
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // health.ychad.eth
        creditThreshold = 1e6 * 1e18;
        keepCRV = 1000; // default of 10%

        // these are our standard approvals. want = Curve LP token
        want.approve(address(proxy), type(uint256).max);
        crv.approve(address(crveth), type(uint256).max);
        weth.approve(uniswapv3, type(uint256).max);

        // this is the pool specific to this vault, but we only use it as an address
        curve = address(_curvePool);

        // need to set our proxy when cloning since it's not a constant
        proxy = ICurveStrategyProxy(0xA420A63BbEFfbda3B147d0585F1852C358e2C152);

        // set our curve gauge contract
        gauge = address(_gauge);

        // set our strategy's name
        stratName = _name;

        // these are our approvals and path specific to this contract
        dai.approve(address(zapContract), type(uint256).max);
        usdt.safeApprove(address(zapContract), type(uint256).max); // USDT requires safeApprove(), funky token
        usdc.approve(address(zapContract), type(uint256).max);

        // start with usdt
        targetStable = address(usdt);

        // set our uniswap pool fees
        uniStableFee = 500;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // if we have anything in the gauge, then harvest CRV from the gauge
        uint256 _stakedBal = stakedBalance();
        uint256 _crvBalance = crv.balanceOf(address(this));
        if (_stakedBal > 0) {
            proxy.harvest(gauge);
            _crvBalance = crv.balanceOf(address(this));
            // if we claimed any CRV, then sell it
            if (_crvBalance > 0) {
                // keep some of our CRV to increase our boost
                uint256 _sendToVoter =
                    _crvBalance.mul(keepCRV).div(FEE_DENOMINATOR);
                if (_sendToVoter > 0) {
                    crv.safeTransfer(voter, _sendToVoter);
                }
                _crvBalance -= _sendToVoter;
            }
        }

        if (hasRewards) {
            proxy.claimRewards(gauge, address(rewardsToken));
            uint256 _rewardsBalance = rewardsToken.balanceOf(address(this));
            if (_rewardsBalance > 0) {
                _sellRewards(_rewardsBalance);
            }
        }

        // do this even if we don't have any CRV, in case we have WETH
        _sell(_crvBalance);

        // check for balances of tokens to deposit
        uint256 _daiBalance = dai.balanceOf(address(this));
        uint256 _usdcBalance = usdc.balanceOf(address(this));
        uint256 _usdtBalance = usdt.balanceOf(address(this));

        // deposit our balance to Curve if we have any
        if (_daiBalance > 0 || _usdcBalance > 0 || _usdtBalance > 0) {
            zapContract.add_liquidity(
                curve,
                [0, _daiBalance, _usdcBalance, _usdtBalance],
                0
            );
        }

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            if (_stakedBal > 0) {
                // don't bother withdrawing if we don't have staked funds
                proxy.withdraw(
                    gauge,
                    address(want),
                    Math.min(_stakedBal, _debtOutstanding)
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets.sub(debt);
            uint256 _wantBal = balanceOfWant();
            if (_profit.add(_debtPayment) > _wantBal) {
                // this should only be hit following donations to strategy
                liquidateAllPositions();
            }
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt.sub(assets);
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            proxy.withdraw(gauge, address(want), _stakedBal);
        }
        crv.safeTransfer(_newStrategy, crv.balanceOf(address(this)));
    }

    // Sells our harvested CRV into the selected output, then WETH -> stables together with any WETH from rewards on UniV3
    function _sell(uint256 _crvAmount) internal {
        if (_crvAmount > 1e17) {
            // don't want to swap dust or we might revert
            crveth.exchange(1, 0, _crvAmount, 0, false);
        }

        uint256 _wethBalance = weth.balanceOf(address(this));
        if (_wethBalance > 1e15) {
            // don't want to swap dust or we might revert
            IUniV3(uniswapv3).exactInput(
                IUniV3.ExactInputParams(
                    abi.encodePacked(
                        address(weth),
                        uint24(uniStableFee),
                        address(targetStable)
                    ),
                    address(this),
                    block.timestamp,
                    _wethBalance,
                    uint256(1)
                )
            );
        }
    }

    // Sells our harvested reward token into the selected output.
    function _sellRewards(uint256 _amount) internal {
        IUniswapV2Router02(sushiswap).swapExactTokensForTokens(
            _amount,
            uint256(0),
            rewardsPath,
            address(this),
            block.timestamp
        );
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we hit our minDelay, but only if our gas price is acceptable
        if (block.timestamp.sub(params.lastReport) > minReportDelay) {
            return true;
        }

        // harvest our credit if it's above our threshold
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    // convert our keeper's eth cost into want, we don't need this anymore since we don't use baseStrategy harvestTrigger
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {}

    // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    ///@notice Set optimal token to sell harvested funds for depositing to Curve.
    function setOptimal(uint256 _optimal) external onlyVaultManagers {
        if (_optimal == 0) {
            targetStable = address(dai);
        } else if (_optimal == 1) {
            targetStable = address(usdc);
        } else if (_optimal == 2) {
            targetStable = address(usdt);
        } else {
            revert("incorrect token");
        }
    }

    ///@notice Use to add, update or remove reward token
    function updateRewards(bool _hasRewards, address _rewardsToken)
        external
        onlyGovernance
    {
        // if we already have a rewards token, get rid of it
        if (address(rewardsToken) != address(0)) {
            rewardsToken.approve(sushiswap, uint256(0));
        }
        if (_hasRewards == false) {
            hasRewards = false;
            rewardsToken = IERC20(address(0));
        } else {
            // approve, setup our path, and turn on rewards
            rewardsToken = IERC20(_rewardsToken);
            rewardsToken.approve(sushiswap, type(uint256).max);
            rewardsPath = [address(rewardsToken), address(weth)];
            hasRewards = true;
        }
    }

    ///@notice Credit threshold is in want token, and will trigger a harvest if strategy credit is above this amount.
    function setCreditThreshold(uint256 _creditThreshold)
        external
        onlyVaultManagers
    {
        creditThreshold = _creditThreshold;
    }

    ///@notice Set the fee pool we'd like to swap through on UniV3 (1% = 10_000)
    function setUniFees(uint24 _stableFee) external onlyVaultManagers {
        uniStableFee = _stableFee;
    }
}
