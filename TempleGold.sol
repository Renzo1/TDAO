pragma solidity ^0.8.20;
// SPDX-License-Identifier: AGPL-3.0-or-later
// Temple (templegold/TempleGold.sol)


import { Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppReceiver.sol";
import { CommonEventsAndErrors } from "contracts/common/CommonEventsAndErrors.sol";
import { IOFT, OFTCore } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";
import { ITempleGold } from "contracts/interfaces/templegold/ITempleGold.sol";
import { IDaiGoldAuction } from "contracts/interfaces/templegold/IDaiGoldAuction.sol";
import { OFT } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ITempleGoldStaking}  from "contracts/interfaces/templegold/ITempleGoldStaking.sol";
import { MessagingReceipt, MessagingFee } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import { OFTMsgCodec } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import { SendParam, OFTReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import { TempleMath } from "contracts/common/TempleMath.sol";

/**
 * @title Temple Gold 
 * @notice Temple Gold is a non-transferrable ERC20 token with LayerZero integration for cross-chain transfer for holders.
 * On mint, Temple Gold is distributed to DaiGoldAuction, Staking contracts and team multisig using distribution share parameters percentages set at `DistributionParams`. 
 * Users can get Temple Gold by staking Temple for Temple Gold rewards on the staking contract or in auctions.
 * Holders can transfer their Temple Gold to same holder address across chains.
 * The intended owner of Temple Gold is the TempleGoldAdmin contract for admin functions. 
 * This is done to avoid manually importing lz contracts and overriding `Ownable` with `TempleElevatedAccess`
 */
 contract TempleGold is ITempleGold, OFT {
    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;

    /// @notice These addresses are mutable to allow change/upgrade.
    /// @notice Staking contract
    ITempleGoldStaking public override staking;
    /// @notice Escrow auction contract
    IDaiGoldAuction public override escrow;
    /// @notice Multisig gnosis address
    address public override teamGnosis;

    /// @notice Last block timestamp Temple Gold was minted
    uint32 public override lastMintTimestamp;

    //// @notice Distribution as a percentage of 100
    uint256 public constant DISTRIBUTION_DIVISOR = 100 ether;
    /// @notice 1B max supply
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether; // 1B
    /// @notice Minimum Temple Gold minted per call to mint
    uint256 public constant MINIMUM_MINT = 10_000 ether;

    /// @notice Mint chain id
    uint256 private immutable _mintChainId;

    /// @notice Total distribtued to track total supply
    uint256 private _totalDistributed;

    /// @notice Whitelisted addresses for transferrability
    mapping(address => bool) public override authorized;
    /// @notice Distribution parameters. Minted share percentages for staking, escrow and gnosis. Adds up to 100%
    DistributionParams private distributionParams;
    /// @notice Vesting factor determines rate of mint
    // This represents the fraction of MAX_SUPPLY to mint every second
    // if set to `1 second/ 3 years`, MAX_SUPPLY will be minted in 3 years. It is possible but unlikely vesting factor is changed in future
    VestingFactor private vestingFactor;

    constructor(
        InitArgs memory _initArgs
    ) OFT(_initArgs.name, _initArgs.symbol, _initArgs.layerZeroEndpoint, _initArgs.executor) Ownable(_initArgs.executor){
       _mintChainId = _initArgs.mintChainId;
    }

    /**
     * @notice Set staking proxy contract address
     * @param _staking Staking proxy contract
     */
    function setStaking(address _staking) external override onlyOwner {
        if (_staking == address(0)) { revert CommonEventsAndErrors.InvalidAddress(); }
        staking = ITempleGoldStaking(_staking);
        emit StakingSet(_staking);
    }

    /**
     * @notice Set auctions escrow contract address
     * @param _escrow Auctions escrow contract address
     */
    function setEscrow(address _escrow) external override onlyOwner {
        if (_escrow == address(0)) { revert CommonEventsAndErrors.InvalidAddress(); }
        escrow = IDaiGoldAuction(_escrow);
        emit EscrowSet(_escrow);
    }

    /**
     * @notice Set team gnosis address
     * @param _gnosis Team gnosis address
     */
    function setTeamGnosis(address _gnosis) external override onlyOwner {
        if (_gnosis == address(0)) { revert CommonEventsAndErrors.InvalidAddress(); }
        teamGnosis = _gnosis;
        emit TeamGnosisSet(_gnosis);
    }

    /**
     * @notice Whitelist an address to allow transfer of Temple Gold to or from
     * @param _contract Contract address to whitelist
     * @param _whitelist Boolean whitelist state
     */
    function authorizeContract(address _contract, bool _whitelist) external override onlyOwner {
        if (_contract == address(0)) { revert CommonEventsAndErrors.InvalidAddress(); }
        authorized[_contract] = _whitelist;
        emit ContractAuthorizationSet(_contract, _whitelist);
    } 

    /**
     * @notice Set distribution percentages of newly minted Temple Gold
     * @param _params Distribution parameters
     */
    function setDistributionParams(DistributionParams calldata _params) external override onlyOwner {
        if (_params.staking + _params.gnosis + _params.escrow != DISTRIBUTION_DIVISOR) { revert ITempleGold.InvalidTotalShare(); }
        distributionParams = _params;
        emit DistributionParamsSet(_params.staking, _params.escrow, _params.gnosis);
    }

    /**
     * @notice Set vesting factor
     * @param _factor Vesting factor
     */
    function setVestingFactor(VestingFactor calldata _factor) external override onlyOwner {
        if (_factor.numerator == 0 || _factor.denominator == 0) { revert CommonEventsAndErrors.ExpectedNonZero(); }
        if (_factor.numerator > _factor.denominator) { revert CommonEventsAndErrors.InvalidParam(); }
        vestingFactor = _factor;
        /// @dev initialize
        if (lastMintTimestamp == 0) { lastMintTimestamp = uint32(block.timestamp); }
        emit VestingFactorSet(_factor.numerator, _factor.denominator);
    }
    
    /**
     * @notice Mint new tokens to be distributed. Open to call from any address
     * Enforces minimum mint amount and uses vesting factor to calculate mint token amount.
     * Minting is only possible on source chain Arbitrum
     */
    function mint() external override onlyArbitrum {
        VestingFactor memory vestingFactorCache = vestingFactor;
        DistributionParams storage distributionParamsCache = distributionParams;
        if (vestingFactorCache.numerator == 0) { revert ITempleGold.MissingParameter(); }

        uint256 mintAmount = _getMintAmount(vestingFactorCache);
        /// @dev no op silently
        if (!_canDistribute(mintAmount)) { return; }

        lastMintTimestamp = uint32(block.timestamp);

        _distribute(distributionParamsCache, mintAmount);
    }

    /**
     * @notice Get vesting factor
     * @return Vesting factor
     */
    function getVestingFactor() external override view returns (VestingFactor memory) {
        return vestingFactor;
    }

    /**
     * @notice Get distribution parameters
     * @return Distribution parametersr
     */
    function getDistributionParameters() external override view returns (DistributionParams memory) {
        return distributionParams;
    }

    /**
     * @notice Check if TGOLD can be distributed
     * @return True if can distribtue
     */
    function canDistribute() external view returns (bool) {
        VestingFactor memory vestingFactorCache = vestingFactor;
        return _canDistribute(vestingFactorCache);
    }

    function _canDistribute(VestingFactor memory vestingFactorCache) private view returns (bool) {
        uint256 mintAmount = _getMintAmount(vestingFactorCache);
        return _canDistribute(mintAmount);
    }

    function _canDistribute(uint256 mintAmount) private view returns (bool) {
        return mintAmount != 0 && _totalDistributed + mintAmount == MAX_SUPPLY ? true : mintAmount >= MINIMUM_MINT;
    }

    /**
     * @notice Get circulating supply on this chain
     * @dev When this function is called on source chain (arbitrum), you get the real circulating supply across chains
     * @return Circulating supply
     */
    function circulatingSupply() public override view returns (uint256) {
        return _totalDistributed;
    }

    /**
     * @notice Get amount of TGLD tokens that will mint if `mint()` called
     * @return Mint amount
     */
    function getMintAmount() external override view returns (uint256) {
        VestingFactor memory vestingFactorCache = vestingFactor;
        return _getMintAmount(vestingFactorCache);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal override {
        /// can only transfer to or from whitelisted addreess
        /// @dev skip check on mint and burn. function `send` checks from == to
        if (from != address(0) && to != address(0)) {
            if (!authorized[from] && !authorized[to]) { revert ITempleGold.NonTransferrable(from, to); }
        }
        super._update(from, to, value);
    }

    function _distribute(DistributionParams storage params, uint256 mintAmount) private {
        uint256 stakingAmount = TempleMath.mulDivRound(params.staking, mintAmount, DISTRIBUTION_DIVISOR, false);
        if (stakingAmount > 0) {
            _mint(address(staking), stakingAmount);
            staking.notifyDistribution(stakingAmount);
        }

        uint256 escrowAmount = TempleMath.mulDivRound(params.escrow, mintAmount, DISTRIBUTION_DIVISOR, false);
        if (escrowAmount > 0) {
            _mint(address(escrow), escrowAmount);
            escrow.notifyDistribution(escrowAmount);
        }

        uint256 gnosisAmount = mintAmount - stakingAmount - escrowAmount;
        if (gnosisAmount > 0) {
            _mint(teamGnosis, gnosisAmount);
            /// @notice no requirement to notify gnosis because no action has to be taken
        }
        _totalDistributed += mintAmount;
        emit Distributed(stakingAmount, escrowAmount, gnosisAmount, block.timestamp);
    }

    function _getMintAmount(VestingFactor memory vestingFactorCache) private view returns (uint256 mintAmount) {
        uint32 _lastMintTimestamp = lastMintTimestamp;
        uint256 totalSupplyCache = _totalDistributed;
        /// @dev if vesting factor is not set, return 0. `_lastMintTimestamp` is set when vesting factor is set
        if (_lastMintTimestamp == 0) { return 0; }
        mintAmount = TempleMath.mulDivRound((block.timestamp - _lastMintTimestamp) * (MAX_SUPPLY), vestingFactorCache.numerator, vestingFactorCache.denominator, false);
       
        if (totalSupplyCache + mintAmount > MAX_SUPPLY) {
            unchecked {
                mintAmount = MAX_SUPPLY - totalSupplyCache;
            }
        }
    }

    /// @notice Overriden OFT functions

    /**
     * @dev Executes the send operation.
     * @param _sendParam The parameters for the send operation.
     * @param _fee The calculated fee for the send() operation.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     * @param _refundAddress The address to receive any excess funds.
     * @return msgReceipt The receipt for the send operation.
     * @return oftReceipt The OFT receipt information.
     *
     * @dev MessagingReceipt: LayerZero msg receipt
     *  - guid: The unique identifier for the sent message.
     *  - nonce: The nonce of the sent message.
     *  - fee: The LayerZero fee incurred for the message.
     * @dev overriden to check user only transfers cross-chain
     * Not using super.send() because virtual overwritten function is external and not internal/public
     */
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable virtual override(IOFT, OFTCore) returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        if (_sendParam.composeMsg.length > 0) { revert CannotCompose(); }
        /// cast bytes32 to address
        address _to = _sendParam.to.bytes32ToAddress();
        /// @dev user can cross-chain transfer to self
        if (msg.sender != _to) { revert ITempleGold.NonTransferrable(msg.sender, _to); }

        // @dev Applies the token transfers regarding this send() operation.
        // - amountSentLD is the amount in local decimals that was ACTUALLY sent/debited from the sender.
        // - amountReceivedLD is the amount in local decimals that will be received/credited to the recipient on the remote OFT instance.
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debit(
            msg.sender,
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        // @dev Builds the options and OFT message to quote in the endpoint.
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);

        // @dev Sends the message to the LayerZero endpoint and returns the LayerZero msg receipt.
        msgReceipt = _lzSend(_sendParam.dstEid, message, options, _fee, _refundAddress);
        // @dev Formulate the OFT receipt.
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    /**
     * @dev Internal function to handle the receive on the LayerZero endpoint.
     * @param _origin The origin information.
     *  - srcEid: The source chain endpoint ID.
     *  - sender: The sender address from the src chain.
     *  - nonce: The nonce of the LayerZero message.
     * @param _guid The unique identifier for the received LayerZero message.
     * @param _message The encoded message.
     * @dev _executor The address of the executor.
     * @dev _extraData Additional data.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/, // @dev unused in the default implementation.
        bytes calldata /*_extraData*/ // @dev unused in the default implementation.
    ) internal virtual override {
        // @dev The src sending chain doesnt know the address length on this chain (potentially non-evm)
        // Thus everything is bytes32() encoded in flight.
        address toAddress = _message.sendTo().bytes32ToAddress();
        // @dev Credit the amountLD to the recipient and return the ACTUAL amount the recipient received in local decimals
        uint256 amountReceivedLD = _credit(toAddress, _toLD(_message.amountSD()), _origin.srcEid);

        /// @dev Disallow further execution on destination by ignoring composed message
        if (_message.isComposed()) { revert CannotCompose(); }

        emit OFTReceived(_guid, _origin.srcEid, toAddress, amountReceivedLD);
    }

    modifier onlyArbitrum() {
        if (block.chainid != _mintChainId) { revert WrongChain(); }
        _;
    }
 }