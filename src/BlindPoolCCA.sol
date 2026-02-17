// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "encrypted-types/EncryptedTypes.sol";
import {FHE} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title IContinuousClearingAuction (minimal interface for forwarding bids)
interface ICCA {
    function submitBid(uint256 maxPrice, uint128 amount, address owner, bytes calldata hookData)
        external
        payable
        returns (uint256 bidId);

    function exitBid(uint256 bidId) external;
    function claimTokens(uint256 bidId) external;
    function endBlock() external view returns (uint64);
    function startBlock() external view returns (uint64);
    function floorPrice() external view returns (uint256);
    function tickSpacing() external view returns (uint256);
    function clearingPrice() external view returns (uint256);
    function token() external view returns (address);
    function totalSupply() external view returns (uint128);
}

/// @title BlindPoolCCA
/// @notice Privacy wrapper for Uniswap CCA using Zama fhEVM. Bids are encrypted
///         on-chain during the auction and only revealed after the auction closes.
///         Revealed bids are then forwarded to the real CCA contract for settlement.
/// @dev Inherits ZamaEthereumConfig to auto-configure the Zama coprocessor on Sepolia.
contract BlindPoolCCA is ZamaEthereumConfig {
    // ═══════════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════════

    address public admin;

    /// @notice The real Uniswap CCA this wrapper forwards revealed bids to
    ICCA public cca;

    /// @notice Block number after which no more blind bids are accepted
    uint64 public blindBidDeadline;

    /// @notice Whether bids have been marked for public decryption
    bool public revealed;

    /// @notice Total number of blind bids submitted
    uint256 public nextBlindBidId;

    /// @notice A single sealed bid
    struct BlindBid {
        address bidder;
        euint64 encMaxPrice; // Encrypted max price (Q96 scaled to fit uint64)
        euint64 encAmount; // Encrypted bid amount in wei
        uint256 ethDeposit; // Actual ETH held in escrow (covers worst-case bid)
        bool forwarded; // Whether this bid has been forwarded to the CCA
    }

    /// @notice blindBidId → BlindBid
    mapping(uint256 => BlindBid) internal _blindBids;

    /// @notice blindBidId → real CCA bidId (set after forwarding)
    mapping(uint256 => uint256) public ccaBidIds;

    // ── Encrypted aggregates (for privacy-preserving stats on the UI) ──
    euint64 internal _encHighestPrice;
    euint64 internal _encTotalDemand;

    // ═══════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event BlindBidPlaced(uint256 indexed blindBidId, address indexed bidder);
    event BidsRevealed(uint256 totalBids);
    event BidForwarded(uint256 indexed blindBidId, uint256 indexed ccaBidId);
    event EthRefunded(uint256 indexed blindBidId, address indexed bidder, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════════

    error AuctionStillOpen();
    error AuctionClosed();
    error NotRevealed();
    error AlreadyRevealed();
    error AlreadyForwarded();
    error OnlyAdmin();
    error NoDeposit();

    // ═══════════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════

    /// @param _cca Address of the deployed Uniswap CCA auction contract
    /// @param _blindBidDeadline Block number after which blind bidding closes.
    ///        Should be BEFORE the real CCA's endBlock so forwarded bids land in time.
    constructor(address _cca, uint64 _blindBidDeadline) {
        admin = msg.sender;
        cca = ICCA(_cca);
        blindBidDeadline = _blindBidDeadline;

        // Initialize encrypted aggregates to zero
        _encHighestPrice = FHE.asEuint64(0);
        FHE.allowThis(_encHighestPrice);

        _encTotalDemand = FHE.asEuint64(0);
        FHE.allowThis(_encTotalDemand);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     PHASE 1: BLIND BIDDING
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Submit a sealed bid. Both maxPrice and amount are encrypted
    ///         so no one (including validators) can read them until reveal.
    /// @dev    msg.value is the ETH escrow — it must cover the worst-case bid.
    ///         The actual encrypted amount can be ≤ msg.value; excess is refunded
    ///         at settlement.
    /// @param _encMaxPrice  Encrypted max price from relayer SDK
    /// @param _encAmount    Encrypted bid amount from relayer SDK
    /// @param _inputProof   ZK proof of plaintext knowledge (from relayer SDK .encrypt())
    function submitBlindBid(
        externalEuint64 _encMaxPrice,
        externalEuint64 _encAmount,
        bytes calldata _inputProof
    ) external payable {
        if (block.number >= blindBidDeadline) revert AuctionClosed();
        if (msg.value == 0) revert NoDeposit();

        // Verify & internalize encrypted inputs
        euint64 encPrice = FHE.fromExternal(_encMaxPrice, _inputProof);
        euint64 encAmt = FHE.fromExternal(_encAmount, _inputProof);

        // Store the blind bid
        uint256 bidId = nextBlindBidId++;
        _blindBids[bidId] = BlindBid({
            bidder: msg.sender,
            encMaxPrice: encPrice,
            encAmount: encAmt,
            ethDeposit: msg.value,
            forwarded: false
        });

        // ── Update encrypted aggregates ──
        // Track the highest encrypted price seen
        ebool isHigher = FHE.lt(_encHighestPrice, encPrice);
        _encHighestPrice = FHE.select(isHigher, encPrice, _encHighestPrice);
        FHE.allowThis(_encHighestPrice);

        // Track total encrypted demand
        _encTotalDemand = FHE.add(_encTotalDemand, encAmt);
        FHE.allowThis(_encTotalDemand);

        // ── ACL permissions ──
        // Contract can operate on these in future transactions
        FHE.allowThis(encPrice);
        FHE.allowThis(encAmt);
        // Bidder can view their own encrypted bid via re-encryption
        FHE.allow(encPrice, msg.sender);
        FHE.allow(encAmt, msg.sender);

        emit BlindBidPlaced(bidId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     PHASE 2: REVEAL
    // ═══════════════════════════════════════════════════════════════════

    /// @notice After the blind bid deadline, mark all encrypted bids as
    ///         publicly decryptable. Anyone can call this.
    /// @dev    Once called, the Zama KMS will allow public decryption of
    ///         every bid's encMaxPrice and encAmount via the relayer SDK.
    function requestReveal() external {
        if (block.number < blindBidDeadline) revert AuctionStillOpen();
        if (revealed) revert AlreadyRevealed();

        revealed = true;

        for (uint256 i = 0; i < nextBlindBidId; i++) {
            FHE.makePubliclyDecryptable(_blindBids[i].encMaxPrice);
            FHE.makePubliclyDecryptable(_blindBids[i].encAmount);
        }

        // Also reveal the aggregates (optional, for transparency)
        FHE.makePubliclyDecryptable(_encHighestPrice);
        FHE.makePubliclyDecryptable(_encTotalDemand);

        emit BidsRevealed(nextBlindBidId);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                 PHASE 3: FORWARD TO REAL CCA
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Forward a single decrypted bid to the real Uniswap CCA.
    ///         Anyone with the KMS decryption proof can call this.
    /// @param _blindBidId        The blind bid index
    /// @param _clearMaxPrice     Decrypted max price (Q96 uint64)
    /// @param _clearAmount       Decrypted amount (wei uint64)
    /// @param _decryptionProof   KMS proof covering both values
    function forwardBidToCCA(
        uint256 _blindBidId,
        uint64 _clearMaxPrice,
        uint64 _clearAmount,
        bytes calldata _decryptionProof
    ) external {
        if (!revealed) revert NotRevealed();

        BlindBid storage bb = _blindBids[_blindBidId];
        if (bb.forwarded) revert AlreadyForwarded();

        // ── Verify KMS proof: decrypted values match ciphertexts ──
        bytes32[] memory handles = new bytes32[](2);
        handles[0] = FHE.toBytes32(bb.encMaxPrice);
        handles[1] = FHE.toBytes32(bb.encAmount);

        bytes memory encodedClear = abi.encode(_clearMaxPrice, _clearAmount);
        FHE.checkSignatures(handles, encodedClear, _decryptionProof);

        bb.forwarded = true;

        // Determine actual ETH to send (capped by deposit)
        uint256 bidEth = uint256(_clearAmount);
        uint256 toSend = bidEth <= bb.ethDeposit ? bidEth : bb.ethDeposit;

        // Forward to the real CCA
        uint256 ccaBidId = cca.submitBid{value: toSend}(
            uint256(_clearMaxPrice), // maxPrice (Q96)
            uint128(_clearAmount), // amount
            bb.bidder, // original bidder remains the owner
            bytes("") // no hook data
        );

        ccaBidIds[_blindBidId] = ccaBidId;

        // Refund excess ETH deposit back to bidder
        uint256 excess = bb.ethDeposit - toSend;
        if (excess > 0) {
            (bool ok,) = bb.bidder.call{value: excess}("");
            require(ok, "Refund failed");
            emit EthRefunded(_blindBidId, bb.bidder, excess);
        }

        emit BidForwarded(_blindBidId, ccaBidId);
    }

    /// @notice Batch-forward all revealed bids to the CCA.
    ///         Gas-intensive — call in chunks if needed.
    /// @param _blindBidIds    Array of blind bid IDs to forward
    /// @param _clearMaxPrices Array of decrypted max prices
    /// @param _clearAmounts   Array of decrypted amounts
    /// @param _decryptionProofs Array of KMS proofs (one per bid)
    function forwardBidsToCCA(
        uint256[] calldata _blindBidIds,
        uint64[] calldata _clearMaxPrices,
        uint64[] calldata _clearAmounts,
        bytes[] calldata _decryptionProofs
    ) external {
        require(
            _blindBidIds.length == _clearMaxPrices.length && _blindBidIds.length == _clearAmounts.length
                && _blindBidIds.length == _decryptionProofs.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < _blindBidIds.length; i++) {
            // Use this. to allow the function to handle its own reverts
            this.forwardBidToCCA(_blindBidIds[i], _clearMaxPrices[i], _clearAmounts[i], _decryptionProofs[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          VIEWS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Get the bidder address and ETH deposit for a blind bid (public info)
    function getBlindBidInfo(uint256 _blindBidId) external view returns (address bidder, uint256 ethDeposit, bool forwarded) {
        BlindBid storage bb = _blindBids[_blindBidId];
        return (bb.bidder, bb.ethDeposit, bb.forwarded);
    }

    /// @notice Get the encrypted handle for a blind bid's maxPrice (for re-encryption)
    function getEncMaxPrice(uint256 _blindBidId) external view returns (euint64) {
        return _blindBids[_blindBidId].encMaxPrice;
    }

    /// @notice Get the encrypted handle for a blind bid's amount (for re-encryption)
    function getEncAmount(uint256 _blindBidId) external view returns (euint64) {
        return _blindBids[_blindBidId].encAmount;
    }

    /// @notice Encrypted highest price seen across all bids
    function encHighestPrice() external view returns (euint64) {
        return _encHighestPrice;
    }

    /// @notice Encrypted total demand across all bids
    function encTotalDemand() external view returns (euint64) {
        return _encTotalDemand;
    }

    /// @notice Allow contract to receive ETH (for CCA refunds)
    receive() external payable {}
}
