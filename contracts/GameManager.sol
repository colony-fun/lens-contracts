// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IDependencies.sol";
import "./interfaces/IGameManager.sol";
import "./interfaces/IOwnable.sol";
import "./interfaces/Uniswap/ISwapRouter02.sol";
import "./interfaces/Uniswap/INonfungiblePositionManager.sol";
import "./interfaces/Uniswap/IQuoterV2.sol";
import "./interfaces/Uniswap/IUniswapV3Factory.sol";
import "./interfaces/Uniswap/IUniswapV3Pool.sol";
import "./interfaces/IToken.sol";
import "./interfaces/ITotalData.sol";

struct LandData {
    uint256 fixedEarnings;
    uint64 lastTokenCheckout;
    uint8 level; // 1 - 11
    uint64 lastUpgradeTime;
}

struct RoundData {
    uint256 round;
    uint256 roundStartBlock;
    uint256 roundStartTime;
    uint64 presaleDuration;
    uint64 landsDuration;
    uint64 avatarsDuration;
    uint64 claimLockedDuration;
    uint256 landPrice;
    uint256 avatarPrice;
    uint256 avatarAttackCooldown;
    uint256 landUpgradeCooldown;
    uint256 claimCooldown;
    uint256 prizePool;
    uint16 initialTokenPriceBips;
    bool isFinished;
    uint256 nextRoundStartsAt;
    address nextDependenciesAddress;
    bool isMainnet;
}

struct AppData {
    uint256 round;
    uint256 roundDuration;
    uint256 landPrice;
    uint256 avatarPrice;
    string roundStage; // "presale", "lands", "avatars", "claimLocked", "finalizing", "finished" // 0 - presale, 1 - lands, 2 - avatars, 3 - claimLocked, 4 - finalizing, 5 - finished
    uint256 nextStageAt;
    uint256 avatarsUnlockAt;
    uint256 landsStartAt;
    uint256 claimLockAt;
    uint256 roundEndsAt;
    uint256 avatarAttackCooldown;
    uint256 landUpgradeCooldown;
    uint256 claimCooldown;
    uint256 nextRoundStartsAt;
    address nextDependenciesAddress;
    uint64 claimLockedDuration;
}

contract GameManager is Initializable, PausableUpgradeable, UUPSUpgradeable, IGameManager {
    using SafeERC20 for IERC20;

    IDependencies public d;

    uint256 public constant maxTokenId = 21000;
    uint256 public constant claimGracePeriod = 5 minutes;

    RoundData public roundData;

    bool internal locked;
    ISwapRouter02 constant swapRouter = ISwapRouter02(0x6ddD32cd941041D8b61df213B9f515A7D288Dc13);
    IUniswapV3Factory constant factory = IUniswapV3Factory(0xe0704DB90bcAA1eAFc00E958FF815Ab7aa11Ef47);
    INonfungiblePositionManager constant positionManager =
        INonfungiblePositionManager(0xC5d0CAaE8aa00032F6DA993A69Ffa6ff80b5F031);
    IQuoterV2 constant quoter = IQuoterV2(0x1eEA2B790Dc527c5a4cd3d4f3ae8A2DDB65B2af1);
    ITotalData public constant totalData = ITotalData(address(0x32A31b0bc5C46A8Bc66968016FDc42560CDEa882));
    address constant wgho = address(0x6bDc36E20D267Ff0dd6097799f82e78907105e2F);
    address constant dev = address(0x0000000000000000000000000000000000000000);
    address constant prevRoundLands = address(0x0000000000000000000000000000000000000000);
    uint24 public constant POOL_FEE = 3_000;
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    mapping(uint256 => LandData) private landData;
    mapping(uint256 => uint64) public avatarLastAttackTime;
    mapping(address => bool) public freeAvatars;
    mapping(address => uint256) public lastClaimAt;
    mapping(address => bool) prevRoundFreeLandMinted;

    uint256 public avatarsBought;
    uint256 public fullPriceLandsBought;
    uint256 public halfPriceLandsBought;
    uint256 public freeLandsBought;

    uint256 public liquidityPositionId;

    event Airdrop(address indexed receiver, uint256 indexed tokenId);
    event MintLand(address indexed receiver, uint256 indexed tokenId, bool free, bool discount);

    event LandUpgrade(uint256 tokenId, address indexed owner, uint8 level);
    event ClaimEarned(uint256 amount, address indexed owner);
    event AvatarMinted(uint256 tokenId, address indexed owner, bool free);

    event AttackFinished(
        address attacker, address defender, uint256 landId, uint256 avatarId, bool win, uint256 winAmount
    );

    modifier onlyOwner() {
        require(msg.sender == d.owner(), "Only owner");
        _;
    }

    modifier onlyDev() {
        require(!roundData.isMainnet, "Only dev on testnet");
        require(msg.sender == dev, "Only dev");
        _;
    }

    modifier onlyLandOwner(uint256 tokenId) {
        require(IOwnable(address(d.lands())).ownerOf(tokenId) == msg.sender, "You aren't the land owner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "reentrancy guard");
        locked = true;
        _;
        locked = false;
    }

    function setDependencies(IDependencies _d) external onlyOwner {
        d = _d;
    }

    function initialize(IDependencies _d) public initializer {
        d = _d;
        __Pausable_init();
        __UUPSUpgradeable_init();
    }

    function startRound(RoundData memory _roundData, uint256 ethAmount, uint256 tokenAmount)
        external
        payable
        onlyOwner
    {
        require(msg.value == ethAmount, "Invalid eth amount");
        require(!_isRoundStarted(), "Round already started");
        require(address(d.token()) != address(0), "Token not deployed yet");

        roundData = _roundData;
        roundData.roundStartTime = block.timestamp;
        roundData.roundStartBlock = block.number;

        _provideLiquidity(ethAmount, roundData.initialTokenPriceBips);

        d.token().pause();
    }

    function _provideLiquidity(uint256 ghoAmount, uint16 priceBips) internal {
        require(priceBips > 0, "Invalid price");

        address tokenAddress = address(d.token());
        uint256 tokenAmount = (uint256(ghoAmount) * 10000) / priceBips;
        d.token().mint(address(this), tokenAmount);

        if (d.token().allowance(address(this), address(positionManager)) < tokenAmount) {
            d.token().approve(address(positionManager), type(uint256).max);
        }

        address token0 = tokenAddress < wgho ? tokenAddress : wgho;
        address token1 = tokenAddress < wgho ? wgho : tokenAddress;

        uint160 sqrtPriceX96 = _computeInitialSqrtPrice(priceBips, token0 == wgho);
        positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);

        address pool = factory.getPool(token0, token1, POOL_FEE);
        require(pool != address(0), "Pool not found");

        (, int24 currentTick, int24 tickSpacing) = _getPoolState(pool);

        int24 baseTick = _nearestUsableTick(currentTick, tickSpacing);

        int256 baseTickInt = int256(baseTick);
        int256 tickSpacingInt = int256(tickSpacing);
        int256 minTickBoundInt = int256(_nearestUsableTick(MIN_TICK, tickSpacing));
        int256 maxTickBoundInt = int256(_nearestUsableTick(MAX_TICK, tickSpacing));

        int256 tickLowerInt = baseTickInt - tickSpacingInt * 2;
        int256 tickUpperInt = baseTickInt + tickSpacingInt * 2;

        if (tickLowerInt < minTickBoundInt) {
            tickLowerInt = minTickBoundInt;
        }
        if (tickUpperInt > maxTickBoundInt) {
            tickUpperInt = maxTickBoundInt;
        }

        if (tickUpperInt <= tickLowerInt) {
            if (tickLowerInt + tickSpacingInt <= maxTickBoundInt) {
                tickUpperInt = tickLowerInt + tickSpacingInt;
            } else {
                tickLowerInt = tickUpperInt - tickSpacingInt;
            }
        }

        if (tickLowerInt < minTickBoundInt) {
            tickLowerInt = minTickBoundInt;
        }
        if (tickUpperInt > maxTickBoundInt) {
            tickUpperInt = maxTickBoundInt;
        }

        require(tickUpperInt > tickLowerInt, "Invalid tick bounds");
        require(tickLowerInt >= int256(MIN_TICK) && tickUpperInt <= int256(MAX_TICK), "Tick out of range");

        int24 tickLower = int24(tickLowerInt);
        int24 tickUpper = int24(tickUpperInt);

        uint256 amount0Desired = token0 == tokenAddress ? tokenAmount : ghoAmount;
        uint256 amount1Desired = token1 == tokenAddress ? tokenAmount : ghoAmount;

        uint256 amount0Min = _applySlippage(amount0Desired, 50);
        uint256 amount1Min = _applySlippage(amount1Desired, 50);

        uint256 nativeAmountDesired = token0 == wgho ? amount0Desired : amount1Desired;

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: block.timestamp + 20 minutes
        });

        (uint256 tokenId,, uint256 amount0Used, uint256 amount1Used) =
            positionManager.mint{value: nativeAmountDesired}(params);
        positionManager.refundETH();
        liquidityPositionId = tokenId;

        uint256 tokensUsed = tokenAddress == token0 ? amount0Used : amount1Used;
        if (tokenAmount > tokensUsed) {
            d.token().burn(address(this), tokenAmount - tokensUsed);
        }
    }

    function _isRoundStarted() internal view returns (bool) {
        return roundData.roundStartTime > 0;
    }

    function finishRound(uint256 _nextRoundStartsAt) external onlyOwner {
        roundData.isFinished = true;
        roundData.nextRoundStartsAt = _nextRoundStartsAt;
    }

    // 0 - presale, 1 - lands, 2 - avatars, 3 - claimLocked, 4 - finalizing, 5 - finished
    function setStage(uint256 _stage, bool _isFinishingSoon) external onlyDev {
        require(_stage >= 0 && _stage <= 5, "Invalid stage");
        require(_isRoundStarted(), "Round not started");

        if (_stage == 4) {
            roundData.isFinished = false;
            roundData.nextRoundStartsAt = block.timestamp + 1 days;
            roundData.nextDependenciesAddress = address(0);
            roundData.roundStartTime = block.timestamp - roundData.presaleDuration - roundData.landsDuration
                - roundData.avatarsDuration - roundData.claimLockedDuration;
            return;
        }

        if (_stage == 5) {
            roundData.isFinished = true;
            roundData.nextRoundStartsAt = block.timestamp + 1 days;
            roundData.nextDependenciesAddress = address(0);
            roundData.roundStartTime = block.timestamp - roundData.presaleDuration - roundData.landsDuration
                - roundData.avatarsDuration - roundData.claimLockedDuration;
            return;
        }

        roundData.isFinished = false;
        roundData.nextRoundStartsAt = block.timestamp + 9 days;
        roundData.nextDependenciesAddress = address(0);

        uint256 roundDataPresaleDuration = roundData.presaleDuration;
        uint256 roundDataLandsDuration = roundData.landsDuration;
        uint256 roundDataAvatarsDuration = roundData.avatarsDuration;
        uint256 roundDataClaimLockedDuration = roundData.claimLockedDuration;

        if (_stage == 0) {
            // Presale stage
            if (_isFinishingSoon) {
                // Set roundStartTime so presale ends in 20 seconds
                roundData.roundStartTime = block.timestamp - roundDataPresaleDuration + 20;
            } else {
                // Set roundStartTime to the middle of presale
                roundData.roundStartTime = block.timestamp - (roundDataPresaleDuration / 2);
            }
            return;
        }

        if (_stage == 1) {
            // Lands stage
            if (_isFinishingSoon) {
                // Set roundStartTime so lands ends in 20 seconds
                roundData.roundStartTime = block.timestamp - roundDataPresaleDuration - roundDataLandsDuration + 20;
            } else {
                // Set roundStartTime to the middle of lands
                roundData.roundStartTime = block.timestamp - roundDataPresaleDuration - (roundDataLandsDuration / 2);
            }
            return;
        }

        if (_stage == 2) {
            // Avatars stage
            if (_isFinishingSoon) {
                // Set roundStartTime so avatars ends in 20 seconds
                roundData.roundStartTime =
                    block.timestamp - roundDataPresaleDuration - roundDataLandsDuration - roundDataAvatarsDuration + 20;
            } else {
                // Set roundStartTime to the middle of avatars
                roundData.roundStartTime =
                    block.timestamp - roundDataPresaleDuration - roundDataLandsDuration - (roundDataAvatarsDuration / 2);
            }
            return;
        }

        if (_stage == 3) {
            // Claim locked stage
            if (_isFinishingSoon) {
                // Set roundStartTime so claimLocked ends in 20 seconds
                roundData.roundStartTime = block.timestamp - roundDataPresaleDuration - roundDataLandsDuration
                    - roundDataAvatarsDuration - roundDataClaimLockedDuration + 20;
            } else {
                // Set roundStartTime to the middle of claimLocked
                roundData.roundStartTime = block.timestamp - roundDataPresaleDuration - roundDataLandsDuration
                    - roundDataAvatarsDuration - (roundDataClaimLockedDuration / 2);
            }
            return;
        }
    }

    // 0 - presale, 1 - lands, 2 - avatars, 3 - claimLocked, 4 - finalizing, 5 - finishedƒ
    function _roundStage() internal view returns (uint8) {
        if (roundData.isFinished) {
            return 5; // finished
        }

        // Calculate the current stage as a string based on roundStartTime and durations
        uint256 nowTime = block.timestamp;
        uint256 t = roundData.roundStartTime;
        if (nowTime < t + roundData.presaleDuration) {
            return 0; // presale
        }
        t += roundData.presaleDuration;
        if (nowTime < t + roundData.landsDuration) {
            return 1; // lands
        }
        t += roundData.landsDuration;
        if (nowTime < t + roundData.avatarsDuration) {
            return 2; // avatars
        }
        t += roundData.avatarsDuration;
        if (nowTime < t + roundData.claimLockedDuration) {
            return 3; // claimLocked
        }
        return 4; // finalizing
    }

    function _roundStageString() internal view returns (string memory) {
        uint8 calculatedStage = _roundStage();
        if (calculatedStage == 0) {
            return "presale";
        } else if (calculatedStage == 1) {
            return "lands";
        } else if (calculatedStage == 2) {
            return "avatars";
        } else if (calculatedStage == 3) {
            return "claimLocked";
        }

        if (roundData.isFinished) {
            return "finished";
        }

        return "finalizing";
    }

    function getNextStageAt() internal view returns (uint256) {
        uint8 calculatedStage = _roundStage();

        if (calculatedStage == 0) {
            return roundData.roundStartTime + roundData.presaleDuration;
        } else if (calculatedStage == 1) {
            return roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration;
        } else if (calculatedStage == 2) {
            return roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration
                + roundData.avatarsDuration;
        } else if (calculatedStage == 3) {
            return roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration
                + roundData.avatarsDuration + roundData.claimLockedDuration;
        }
        return 0;
    }

    function getAppData() external view returns (AppData memory) {
        AppData memory appData = AppData({
            round: roundData.round,
            roundDuration: roundData.presaleDuration + roundData.landsDuration + roundData.avatarsDuration
                + roundData.claimLockedDuration,
            landPrice: roundData.landPrice,
            avatarPrice: roundData.avatarPrice,
            roundStage: _roundStageString(),
            nextStageAt: getNextStageAt(),
            avatarAttackCooldown: roundData.avatarAttackCooldown,
            landUpgradeCooldown: roundData.landUpgradeCooldown,
            claimCooldown: roundData.claimCooldown,
            nextRoundStartsAt: roundData.nextRoundStartsAt,
            nextDependenciesAddress: roundData.nextDependenciesAddress,
            avatarsUnlockAt: roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration,
            landsStartAt: roundData.roundStartTime + roundData.presaleDuration,
            claimLockAt: roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration
                + roundData.avatarsDuration,
            roundEndsAt: roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration
                + roundData.avatarsDuration + roundData.claimLockedDuration,
            claimLockedDuration: roundData.claimLockedDuration
        });

        return appData;
    }

    function _mintLand(address _address, uint256 tokenId) private {
        require(tokenId > 0 && tokenId <= maxTokenId, "Token id out of bounds");
        if (_roundStage() == 0) {
            landData[tokenId].lastTokenCheckout = uint64(roundData.roundStartTime + roundData.presaleDuration);
        } else {
            landData[tokenId].lastTokenCheckout = uint64(block.timestamp);
        }

        landData[tokenId].level = 1;
        d.lands().mint(_address, tokenId);
    }

    function buyLand(uint256 tokenId) public payable nonReentrant whenNotPaused {
        bool isDiscountApplicable = _roundStage() == 0;

        uint256 finalPrice = isDiscountApplicable ? roundData.landPrice * 5 / 10 : roundData.landPrice;

        require(msg.value == finalPrice, "Invalid eth amount");

        // 33% to the team and 80% of the rest 67% = 53.6 is prize, so total = 33 + 53.6 = 86.6%
        (bool success,) = payable(address(d.multisig())).call{value: (finalPrice * 866) / 1000}("");
        require(success, "ETH transfer failed");

        roundData.prizePool = roundData.prizePool + finalPrice * 536 / 1000;

        // rest = 100 - 86.6 = 13.4% is to liquidity
        _addLiquidity(finalPrice);

        _mintLand(msg.sender, tokenId);

        if (isDiscountApplicable) {
            halfPriceLandsBought++;
        } else {
            fullPriceLandsBought++;
        }

        emit MintLand(msg.sender, tokenId, false, isDiscountApplicable);
    }

    function mintFreeLand(uint256 tokenId) external nonReentrant whenNotPaused {
        require(canMintFreeLand(msg.sender), "Can not mint free land");

        _mintLand(msg.sender, tokenId);

        freeLandsBought++;

        if (isPrevRoundLandOwner(msg.sender)) {
            prevRoundFreeLandMinted[msg.sender] = true;
        } else {
            totalData.setFreeLandMinted(msg.sender);
        }

        emit MintLand(msg.sender, tokenId, true, false);
    }

    function isPrevRoundLandOwner(address _address) private view returns (bool) {
        return IERC721Enumerable(prevRoundLands).balanceOf(_address) > 0;
    }

    function canMintFreeLand(address _address) public view returns (bool) {
        if (isPrevRoundLandOwner(_address) && !prevRoundFreeLandMinted[_address]) {
            return true;
        }

        if (prevRoundFreeLandMinted[_address]) {
            return false;
        }

        if (!totalData.whitelisted(_address)) {
            return false;
        }

        if (totalData.freeLandMinted(_address)) {
            return false;
        }

        return true;
    }

    function airdrop(address receiver, uint256 tokenId) external whenNotPaused onlyOwner {
        _mintLand(receiver, tokenId);
        emit Airdrop(receiver, tokenId);
    }

    function getEarned(uint256 tokenId) public view returns (uint256) {
        if (_roundStage() == 0) {
            return 0;
        }

        uint256 roundFinishedAt = roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration
            + roundData.avatarsDuration + roundData.claimLockedDuration;

        uint256 untilTime = roundData.isFinished ? roundFinishedAt : block.timestamp;

        // If accrual window ends before or at last checkout, only fixed earnings remain
        if (untilTime <= landData[tokenId].lastTokenCheckout) {
            return landData[tokenId].fixedEarnings;
        }

        return (getEarningSpeed(tokenId) * (untilTime - landData[tokenId].lastTokenCheckout) * 10 ** 18)
            / (24 * 60 * 60) + landData[tokenId].fixedEarnings;
    }

    function getEarningSpeed(uint256 tokenId) public view returns (uint256) {
        if (_roundStage() == 0) {
            return 0;
        }

        uint8 level = landData[tokenId].level;
        if (level == 1) return 1;
        if (level == 2) return 2;
        if (level == 3) return 3;
        if (level == 4) return 5;
        if (level == 5) return 8;
        if (level == 6) return 13;
        if (level == 7) return 21;
        if (level == 8) return 34;
        if (level == 9) return 55;
        if (level == 10) return 89;
        return 0;
    }

    function _getUpgradeCost(uint256 newLevel) internal pure returns (uint256) {
        if (newLevel == 2) return 2;
        if (newLevel == 3) return 4;
        if (newLevel == 4) return 8;
        if (newLevel == 5) return 16;
        if (newLevel == 6) return 25;
        if (newLevel == 7) return 36;
        if (newLevel == 8) return 49;
        if (newLevel == 9) return 64;
        return 128;
    }

    function getEarningData(uint256[] memory tokenIds) external view returns (uint256, uint256) {
        uint256 earned = 0;
        uint256 speed = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            earned = earned + getEarned(tokenIds[i]);
            speed = speed + getEarningSpeed(tokenIds[i]);
        }

        if (
            roundData.roundStartTime + roundData.presaleDuration + roundData.landsDuration + roundData.avatarsDuration
                + roundData.claimLockedDuration < block.timestamp
        ) {
            return (earned, 0);
        }

        return (earned, speed);
    }

    function fixEarnings(uint256 tokenId) private {
        landData[tokenId].fixedEarnings = getEarned(tokenId);
        landData[tokenId].lastTokenCheckout = uint64(block.timestamp);
    }

    function upgradeLand(uint256 tokenId) public onlyLandOwner(tokenId) whenNotPaused {
        require(_roundStage() != 0, "Upgrade is not enabled");

        require(
            block.timestamp - landData[tokenId].lastUpgradeTime >= roundData.landUpgradeCooldown, "Cooldown not passed"
        );

        uint8 level = landData[tokenId].level;
        require(level < 10, "Land is already at max level");
        fixEarnings(tokenId);
        landData[tokenId].level = level + 1;
        landData[tokenId].lastUpgradeTime = uint64(block.timestamp);
        uint256 cost = _getUpgradeCost(level + 1);
        d.token().burn(msg.sender, cost * 1 ether);
        emit LandUpgrade(tokenId, msg.sender, level + 1);
    }

    function _isClaimEnabled() internal view returns (bool) {
        return _roundStage() != 0 && _roundStage() != 3;
    }

    function claimEarned(uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        require(_isClaimEnabled(), "Claim is not enabled");
        uint256 timeSinceLastClaim = block.timestamp - lastClaimAt[msg.sender];
        require(
            timeSinceLastClaim >= roundData.claimCooldown || timeSinceLastClaim <= claimGracePeriod,
            "Cooldown not passed"
        );
        // Update lastClaimAt only if full cooldown has passed to ensure the grace window does not reset
        if (timeSinceLastClaim >= roundData.claimCooldown) {
            lastClaimAt[msg.sender] = uint64(block.timestamp);
        }
        ILands mc = d.lands();
        uint256 earned = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(msg.sender == IOwnable(address(mc)).ownerOf(tokenIds[i]));
            earned = earned + getEarned(tokenIds[i]);
            landData[tokenIds[i]].fixedEarnings = 0;
            landData[tokenIds[i]].lastTokenCheckout = uint64(block.timestamp);
        }
        d.token().mint(msg.sender, earned);

        emit ClaimEarned(earned, msg.sender);
    }

    function getAttributesMany(uint256[] calldata tokenIds) external view returns (AttributeData[] memory) {
        AttributeData[] memory result = new AttributeData[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            result[i] = AttributeData(
                getEarningSpeed(tokenId), getEarned(tokenId), landData[tokenId].level, landData[tokenId].lastUpgradeTime
            );
        }
        return result;
    }

    // -- AVATARS --

    function isAvatarsEnabled() internal view returns (bool) {
        return _roundStage() != 0 && _roundStage() != 1 && !roundData.isFinished;
    }

    function buyAvatar() external payable nonReentrant whenNotPaused {
        require(isAvatarsEnabled(), "Avatar buy is not enabled");
        require(msg.value == roundData.avatarPrice, "Invalid eth amount");

        // 50% to the team and 50% in prize pool, no liquidity or buyback
        (bool success,) = payable(address(d.multisig())).call{value: roundData.avatarPrice}("");
        require(success, "ETH transfer failed");

        roundData.prizePool = roundData.prizePool + roundData.avatarPrice * 50 / 100;

        // rest 50% from 67% = 33.5% is to buyback
        // buyBackToken();
        uint256 avatarId = d.avatars().mint(msg.sender);

        avatarsBought++;
        emit AvatarMinted(avatarId, msg.sender, false);
    }

    function mintFreeAvatar() external nonReentrant whenNotPaused {
        require(canMintFreeAvatar(msg.sender), "Can not mint free avatar");

        uint256 avatarId = d.avatars().mint(msg.sender);
        totalData.setFreeAvatarMinted(msg.sender);
        emit AvatarMinted(avatarId, msg.sender, true);
    }

    function canMintFreeAvatar(address _address) public pure returns (bool) {
        return false;
    }

    function getAttackWinShare() public view returns (uint256) {
        uint256 avatarsCount = IERC721Enumerable(address(d.avatars())).balanceOf(msg.sender);
        if (avatarsCount == 0) {
            return 0;
        }

        uint256 tokenBalance = d.token().balanceOf(msg.sender);
        uint256 perAvatar = tokenBalance / avatarsCount; // floor division (tokens have 18 decimals)

        if (perAvatar < 2 ether) return 10;
        if (perAvatar < 3 ether) return 20;
        if (perAvatar < 5 ether) return 30;
        if (perAvatar < 8 ether) return 40;
        if (perAvatar < 13 ether) return 50;
        if (perAvatar < 21 ether) return 60;
        if (perAvatar < 34 ether) return 70;
        if (perAvatar < 55 ether) return 80;
        if (perAvatar < 89 ether) return 90;
        return 100;
    }

    function getRaidReward(uint256 landId) external view returns (uint256) {
        uint256 earned = getEarned(landId);
        uint256 winShare = getAttackWinShare();
        return earned * winShare / 100;
    }

    function attackLand(uint256 landId) external whenNotPaused {
        require(isAvatarsEnabled(), "Attack is not enabled");

        require(
            landId > 0 && landId <= maxTokenId && ERC721Upgradeable(address(d.lands())).ownerOf(landId) != address(0),
            "Land does not exist"
        );

        uint256 avatarId = getAvailableAvatar();
        if (avatarId == 0) {
            revert("No available avatar");
        }

        avatarLastAttackTime[avatarId] = uint64(block.timestamp);

        fixEarnings(landId);

        uint256 earned = getEarned(landId);

        uint256 winAmount = earned * getAttackWinShare() / 100;

        address defender = IOwnable(address(d.lands())).ownerOf(landId);

        landData[landId].fixedEarnings = earned - winAmount;
        d.token().mint(msg.sender, winAmount);

        emit AttackFinished(msg.sender, defender, landId, avatarId, true, winAmount);
    }

    function getAttacksInfo() external view returns (uint64 attacksCount, uint64 nextAttackTime) {
        // Returns all avatar tokenIds and their last attack time for msg.sender
        IAvatars avatars = d.avatars();
        uint64 availableAttacks = 0;
        uint64 earliestAttackTime = 0;

        uint256 balance = IERC721Enumerable(address(avatars)).balanceOf(msg.sender);

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = IERC721Enumerable(address(avatars)).tokenOfOwnerByIndex(msg.sender, i);
            uint64 lastAttackTime = avatarLastAttackTime[tokenId];
            if (lastAttackTime + roundData.avatarAttackCooldown < block.timestamp) {
                availableAttacks++;
            } else {
                if (earliestAttackTime == 0 || lastAttackTime < earliestAttackTime) {
                    earliestAttackTime = lastAttackTime;
                }
            }
        }

        if (availableAttacks > 0) {
            return (availableAttacks, 0);
        }

        return (0, uint64(earliestAttackTime + roundData.avatarAttackCooldown));
    }

    function getClaimInfo() external view returns (bool claimAvailable, uint256 nextClaimAt) {
        uint256 timeSinceLastClaim = block.timestamp - lastClaimAt[msg.sender];
        claimAvailable = timeSinceLastClaim >= roundData.claimCooldown || timeSinceLastClaim <= claimGracePeriod;
        if (claimAvailable) {
            return (true, 0);
        }
        nextClaimAt = lastClaimAt[msg.sender] + roundData.claimCooldown;
    }

    function getAvailableAvatar() public view returns (uint256) {
        IAvatars avatars = d.avatars();
        uint256 balance = IERC721Enumerable(address(avatars)).balanceOf(msg.sender);
        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = IERC721Enumerable(address(avatars)).tokenOfOwnerByIndex(msg.sender, i);
            if (avatarLastAttackTime[tokenId] + roundData.avatarAttackCooldown < block.timestamp) {
                return tokenId;
            }
        }
        return 0;
    }

    // - helpers
    function plotsOwnersPaginate(uint256 _from, uint256 _to) external view returns (address[] memory) {
        ILands lands = d.lands();
        uint256 tokenCount = IERC721Enumerable(address(lands)).totalSupply();
        if (tokenCount <= _from || _from > _to || tokenCount == 0) {
            return new address[](0);
        }

        uint256 to = (_to > tokenCount - 1) ? tokenCount - 1 : _to;

        address[] memory owners = new address[](to - _from + 1);
        for (uint256 i = _from; i <= to; i++) {
            uint256 tokenId = IERC721Enumerable(address(lands)).tokenByIndex(i);
            owners[i - _from] = IERC721(address(lands)).ownerOf(tokenId);
        }
        return owners;
    }

    function avatarsOwnersPaginate(uint256 _from, uint256 _to) external view returns (address[] memory) {
        IAvatars avatars = d.avatars();
        uint256 tokenCount = IERC721Enumerable(address(avatars)).totalSupply();
        if (tokenCount <= _from || _from > _to || tokenCount == 0) {
            return new address[](0);
        }

        uint256 to = (_to > tokenCount - 1) ? tokenCount - 1 : _to;
        address[] memory owners = new address[](to - _from + 1);
        for (uint256 i = _from; i <= to; i++) {
            uint256 tokenId = IERC721Enumerable(address(avatars)).tokenByIndex(i);
            owners[i - _from] = IERC721(address(avatars)).ownerOf(tokenId);
        }
        return owners;
    }

    function tokenBalancesBatch(address[] calldata _addresses)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        uint256 addressesCount = _addresses.length;
        uint256[] memory balances = new uint256[](addressesCount);
        for (uint256 i = 0; i < addressesCount; i++) {
            balances[i] = d.token().balanceOf(_addresses[i]);
        }

        return (_addresses, balances);
    }

    function finalBalancesBatch(address[] calldata _addresses)
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        uint256 addressesCount = _addresses.length;
        uint256[] memory balances = new uint256[](addressesCount);
        for (uint256 i = 0; i < addressesCount; i++) {
            balances[i] = d.token().balanceOf(_addresses[i]);

            IERC721Enumerable landsEnumerable = IERC721Enumerable(address(d.lands()));

            uint256 earnedByLand = 0;
            uint256 landsCount = landsEnumerable.balanceOf(_addresses[i]);
            for (uint256 j = 0; j < landsCount; j++) {
                uint256 tokenId = landsEnumerable.tokenOfOwnerByIndex(_addresses[i], j);
                earnedByLand += getEarned(tokenId);
            }
            balances[i] += earnedByLand;
        }

        return (_addresses, balances);
    }

    function saleData() external view returns (bool allowed, uint256 minted, uint256 limit) {
        allowed = true;
        minted = IERC721Enumerable(address(d.lands())).totalSupply();
        limit = maxTokenId;
    }

    function withdrawToken(address _tokenContract, address _whereTo) external onlyOwner {
        IERC20 tokenContract = IERC20(_tokenContract);
        tokenContract.safeTransfer(_whereTo, tokenContract.balanceOf(address(this)));
    }

    function withdrawETH(address _whereTo) external onlyOwner {
        (bool success,) = payable(_whereTo).call{value: address(this).balance}("");
        require(success, "ETH withdrawal failed");
    }

    function mintToken(address _address, uint256 amount) external onlyOwner {
        d.token().mint(_address, amount);
    }

    function _addLiquidity(uint256 finalPrice) private {
        if (d.token().paused()) {
            d.token().unpause();
        }

        // 13.4%
        uint256 ghoToPut = (finalPrice * 134) / 1000;
        _provideLiquidity(ghoToPut, roundData.initialTokenPriceBips);

        if (_roundStage() == 0) {
            d.token().pause();
        }
    }

    function buyBackToken() private {
        // 33.5%
        uint256 ethAmount = (roundData.avatarPrice * 335) / 1000;

        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: wgho,
            tokenOut: address(d.token()),
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: ethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactInputSingle{value: ethAmount}(params);
        swapRouter.refundETH();

        // Burn all received tokens
        d.token().burn(address(this), d.token().balanceOf(address(this)));
    }

    function getWldToTokenAmount(uint256 ethAmount) public view returns (uint256) {
        return _quoteExactInputSingle(wgho, address(d.token()), ethAmount);
    }

    function getTokenToWldAmount(uint256 tokenAmount) public view returns (uint256) {
        return _quoteExactInputSingle(address(d.token()), wgho, tokenAmount);
    }

    function _quoteExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (amountIn == 0) {
            return 0;
        }

        bytes memory data = abi.encodeWithSelector(
            IQuoterV2.quoteExactInputSingle.selector,
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                amountIn: amountIn,
                sqrtPriceLimitX96: 0
            })
        );

        (bool success, bytes memory result) = address(quoter).staticcall(data);
        if (!success || result.length == 0) {
            return 0;
        }

        return abi.decode(result, (uint256));
    }

    function _getPoolState(address poolAddress)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, int24 tickSpacing)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (sqrtPriceX96, tick,,,,,) = pool.slot0();
        tickSpacing = pool.tickSpacing();
        require(tickSpacing > 0, "Invalid tick spacing");
        require(sqrtPriceX96 != 0, "Pool not initialized");
    }

    function _nearestUsableTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        require(tickSpacing != 0, "Tick spacing zero");
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed -= 1;
        }
        return compressed * tickSpacing;
    }

    function _applySlippage(uint256 amount, uint256 slippageBips) internal pure returns (uint256) {
        if (amount == 0 || slippageBips == 0) {
            return amount;
        }
        uint256 maxBips = 10_000;
        require(slippageBips < maxBips, "Invalid slippage");
        return (amount * (maxBips - slippageBips)) / maxBips;
    }

    function _computeInitialSqrtPrice(uint16 priceBips, bool token0IsWgho) internal pure returns (uint160) {
        uint256 price = (uint256(priceBips) * 1e18) / 10000;
        require(price > 0, "Invalid price");

        if (!token0IsWgho) {
            price = (1e36) / price;
        }

        uint256 numerator = (price * (uint256(1) << 192)) / 1e18;
        uint256 sqrtPrice = _sqrt(numerator);
        require(sqrtPrice > 0 && sqrtPrice <= type(uint160).max, "sqrt overflow");
        return uint160(sqrtPrice);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) {
            return 0;
        }
        uint256 x = y / 2 + 1;
        z = y;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    function unpauseToken() external onlyOwner {
        if (d.token().paused()) {
            d.token().unpause();
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function setRoundStartTime(uint256 _roundStartTime) external onlyOwner {
        roundData.roundStartTime = _roundStartTime;
    }

    function setLandPrice(uint256 _landPrice) external onlyOwner {
        roundData.landPrice = _landPrice;
    }

    receive() external payable {}
}
