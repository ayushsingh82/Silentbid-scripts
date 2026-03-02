// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
/// @notice Privacy wrapper for Uniswap CCA that keeps bid details offchain.
///         Users submit blind bids with onchain ETH escrow plus an offchain
///         commitment; a trusted offchain workflow (e.g., Chainlink CRE) later
///         forwards cleared bids to the real CCA contract for settlement.
contract BlindPoolCCA {
    // ═══════════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════════

    address public admin;

    /// @notice The real Uniswap CCA this wrapper forwards revealed bids to
    ICCA public cca;

    /// @notice Block number after which no more blind bids are accepted
    uint64 public blindBidDeadline;

    /// @notice Total number of blind bids submitted
    uint256 public nextBlindBidId;

    /// @notice A single sealed bid
    struct BlindBid {
        address bidder;
        uint256 ethDeposit; // ETH held in escrow (covers worst-case bid)
        bool forwarded; // Whether this bid has been forwarded to the CCA
        bytes32 bidCommitment; // Offchain commitment to bid details (maxPrice, amount, flags, etc.)
    }

    /// @notice blindBidId → BlindBid
    mapping(uint256 => BlindBid) internal _blindBids;

    /// @notice blindBidId → real CCA bidId (set after forwarding)
    mapping(uint256 => uint256) public ccaBidIds;

    // ═══════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event BlindBidPlaced(uint256 indexed blindBidId, address indexed bidder, bytes32 bidCommitment);
    event BidForwarded(uint256 indexed blindBidId, uint256 indexed ccaBidId);
    event EthRefunded(uint256 indexed blindBidId, address indexed bidder, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════════

    error AuctionClosed();
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
    }

    // ═══════════════════════════════════════════════════════════════════
    //                     PHASE 1: BLIND BIDDING
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Submit a sealed bid.
    /// @dev    msg.value is the ETH escrow — it must cover the worst-case bid.
    ///         The actual amount used when forwarding to CCA can be ≤ msg.value;
    ///         excess is refunded at settlement.
    /// @param _bidCommitment Offchain commitment to bid details (hash of maxPrice, amount, flags, etc.)
    function submitBlindBid(bytes32 _bidCommitment) external payable {
        if (block.number >= blindBidDeadline) revert AuctionClosed();
        if (msg.value == 0) revert NoDeposit();

        // Store the blind bid
        uint256 bidId = nextBlindBidId++;
        _blindBids[bidId] = BlindBid({
            bidder: msg.sender,
            ethDeposit: msg.value,
            forwarded: false,
            bidCommitment: _bidCommitment
        });

        emit BlindBidPlaced(bidId, msg.sender, _bidCommitment);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                 FORWARD TO REAL CCA (CRE-DRIVEN)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Forward a single cleared bid to the real Uniswap CCA.
    /// @dev    Intended to be called by an offchain workflow (e.g., CRE) that
    ///         has validated the bid commitment and chosen the final amount.
    /// @param _blindBidId        The blind bid index
    /// @param _clearMaxPrice     Max price (Q96)
    /// @param _clearAmount       Final amount (wei)
    /// @param _owner             Owner address for the CCA bid (usually bidder)
    /// @param _hookData          Optional hook data for CCA
    function forwardBidToCCA(
        uint256 _blindBidId,
        uint256 _clearMaxPrice,
        uint128 _clearAmount,
        address _owner,
        bytes calldata _hookData
    ) external {
        if (msg.sender != admin) revert OnlyAdmin();

        BlindBid storage bb = _blindBids[_blindBidId];
        if (bb.forwarded) revert AlreadyForwarded();

        bb.forwarded = true;

        // Determine actual ETH to send (capped by deposit)
        uint256 bidEth = uint256(_clearAmount);
        uint256 toSend = bidEth <= bb.ethDeposit ? bidEth : bb.ethDeposit;

        // Forward to the real CCA
        uint256 ccaBidId = cca.submitBid{value: toSend}(
            _clearMaxPrice, // maxPrice (Q96)
            _clearAmount, // amount
            _owner, // owner in CCA
            _hookData // optional hook data
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

    /// @notice Batch-forward cleared bids to the CCA.
    ///         Gas-intensive — call in chunks if needed.
    /// @param _blindBidIds    Array of blind bid IDs to forward
    /// @param _clearMaxPrices Array of decrypted max prices
    /// @param _clearAmounts   Array of final amounts
    /// @param _owners         Array of owners for CCA bids
    /// @param _hookData       Array of hook data blobs
    function forwardBidsToCCA(
        uint256[] calldata _blindBidIds,
        uint256[] calldata _clearMaxPrices,
        uint128[] calldata _clearAmounts,
        address[] calldata _owners,
        bytes[] calldata _hookData
    ) external {
        require(
            _blindBidIds.length == _clearMaxPrices.length
                && _blindBidIds.length == _clearAmounts.length
                && _blindBidIds.length == _owners.length
                && _blindBidIds.length == _hookData.length,
            "Array length mismatch"
        );

        for (uint256 i = 0; i < _blindBidIds.length; i++) {
            // Use this. to allow the function to handle its own reverts
            this.forwardBidToCCA(_blindBidIds[i], _clearMaxPrices[i], _clearAmounts[i], _owners[i], _hookData[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          VIEWS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Get public info for a blind bid (no sensitive amounts)
    function getBlindBidInfo(uint256 _blindBidId)
        external
        view
        returns (address bidder, uint256 ethDeposit, bool forwarded, bytes32 bidCommitment)
    {
        BlindBid storage bb = _blindBids[_blindBidId];
        return (bb.bidder, bb.ethDeposit, bb.forwarded, bb.bidCommitment);
    }

    /// @notice Allow contract to receive ETH (for CCA refunds)
    receive() external payable {}
}
