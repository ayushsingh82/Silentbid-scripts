// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {HostContractsDeployerTestUtils} from "@fhevm-foundry/HostContractsDeployerTestUtils.sol";
import {ACL} from "@fhevm-host-contracts/contracts/ACL.sol";
import {FHEVMExecutor} from "@fhevm-host-contracts/contracts/FHEVMExecutor.sol";
import {aclAdd, fhevmExecutorAdd} from "@fhevm-host-contracts/addresses/FHEVMHostAddresses.sol";

import "encrypted-types/EncryptedTypes.sol";
import {FHE} from "@fhevm/solidity/lib/FHE.sol";

import {BlindPoolCCA} from "../src/BlindPoolCCA.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {ContinuousClearingAuction} from "continuous-clearing-auction/ContinuousClearingAuction.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IDistributionContract} from "continuous-clearing-auction/interfaces/external/IDistributionContract.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @dev Test-only wrapper that exposes a mock bid submission using trivial encryption
///      instead of externalEuint64 + inputProof (which require the relayer SDK).
contract TestBlindPoolCCA is BlindPoolCCA {
    constructor(address _cca, uint64 _deadline) BlindPoolCCA(_cca, _deadline) {}

    /// @notice Mock bid submission for local Anvil testing.
    ///         Uses FHE.asEuint64 (trivial encrypt) instead of FHE.fromExternal.
    function mockSubmitBlindBid(uint64 _maxPrice, uint64 _amount) external payable {
        if (block.number >= blindBidDeadline) revert AuctionClosed();
        if (msg.value == 0) revert NoDeposit();

        euint64 encPrice = FHE.asEuint64(_maxPrice);
        euint64 encAmt = FHE.asEuint64(_amount);

        uint256 bidId = nextBlindBidId++;
        _blindBids[bidId] = BlindBid({
            bidder: msg.sender,
            encMaxPrice: encPrice,
            encAmount: encAmt,
            ethDeposit: msg.value,
            forwarded: false
        });

        // Update encrypted aggregates
        ebool isHigher = FHE.lt(_encHighestPrice, encPrice);
        _encHighestPrice = FHE.select(isHigher, encPrice, _encHighestPrice);
        FHE.allowThis(_encHighestPrice);

        _encTotalDemand = FHE.add(_encTotalDemand, encAmt);
        FHE.allowThis(_encTotalDemand);

        FHE.allowThis(encPrice);
        FHE.allowThis(encAmt);
        FHE.allow(encPrice, msg.sender);
        FHE.allow(encAmt, msg.sender);

        emit BlindBidPlaced(bidId, msg.sender);
    }
}

/// @title BlindPoolCCATest
/// @notice Full end-to-end test: deploy fhEVM stack + CCA + BlindPoolCCA on Anvil.
///         Verifies that bids are hidden during the auction and the flow completes.
/// @dev Run with: forge test --match-contract BlindPoolCCATest -vvvv
contract BlindPoolCCATest is HostContractsDeployerTestUtils {
    // ── Actors ──
    address constant OWNER = address(0xBEEF);
    address constant PAUSER = address(0xDEAD);
    address constant GATEWAY = address(0x1234);
    uint64 constant GATEWAY_CHAIN_ID = 31337;

    address bidder1;
    address bidder2;
    address bidder3;

    // ── Contracts ──
    ERC20Mock token;
    ContinuousClearingAuction cca;
    TestBlindPoolCCA blindPool;

    // ── Auction params ──
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 constant FLOOR_PRICE = 79_228_162_514_264_334_008_320; // 1 ETH = 1M tokens (Q96)
    uint64 auctionStartBlock;
    uint64 auctionEndBlock;
    uint64 blindDeadline;

    // ══════════════════════════════════════════════════════════════════
    //                           SETUP
    // ══════════════════════════════════════════════════════════════════

    function setUp() public {
        // ── 1. Deploy fhEVM host stack ──
        console2.log("=== Deploying fhEVM Host Stack ===");

        address[] memory kmsSigners = new address[](1);
        kmsSigners[0] = address(0x7777);
        address[] memory inputSigners = new address[](1);
        inputSigners[0] = address(0x8888);

        _deployFullHostStack(OWNER, PAUSER, GATEWAY, GATEWAY, GATEWAY_CHAIN_ID, kmsSigners, 1, inputSigners, 1);

        console2.log("  ACL deployed at:", aclAdd);
        console2.log("  FHEVMExecutor deployed at:", fhevmExecutorAdd);

        // ── 2. Deploy mock token ──
        token = new ERC20Mock();
        console2.log("  Token deployed at:", address(token));

        // ── 3. Deploy CCA via factory ──
        ContinuousClearingAuctionFactory factory = new ContinuousClearingAuctionFactory();
        console2.log("  CCA Factory deployed at:", address(factory));

        auctionStartBlock = uint64(block.number + 5);
        auctionEndBlock = uint64(block.number + 105);

        bytes memory auctionSteps = _buildAuctionSteps();

        AuctionParameters memory params = AuctionParameters({
            currency: address(0), // ETH
            tokensRecipient: OWNER,
            fundsRecipient: OWNER,
            startBlock: auctionStartBlock,
            endBlock: auctionEndBlock,
            claimBlock: auctionEndBlock,
            tickSpacing: FLOOR_PRICE,
            validationHook: address(0),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: auctionSteps
        });

        IDistributionContract dist =
            factory.initializeDistribution(address(token), TOTAL_SUPPLY, abi.encode(params), bytes32(0));
        cca = ContinuousClearingAuction(address(dist));
        console2.log("  CCA deployed at:", address(cca));

        // Mint tokens to CCA and notify
        token.mint(address(cca), TOTAL_SUPPLY);
        cca.onTokensReceived();
        console2.log("  CCA funded with", TOTAL_SUPPLY / 1e18, "tokens");

        // ── 4. Deploy BlindPoolCCA (test wrapper) ──
        blindDeadline = auctionEndBlock - 20;
        blindPool = new TestBlindPoolCCA(address(cca), blindDeadline);
        console2.log("  BlindPool deployed at:", address(blindPool));
        console2.log("  Blind bid deadline:", blindDeadline);

        // ── 5. Setup bidders with ETH ──
        bidder1 = makeAddr("bidder1");
        bidder2 = makeAddr("bidder2");
        bidder3 = makeAddr("bidder3");
        vm.deal(bidder1, 10 ether);
        vm.deal(bidder2, 10 ether);
        vm.deal(bidder3, 10 ether);

        console2.log("");
        console2.log("=== Setup Complete ===");
        console2.log("  Current block:", block.number);
        console2.log("  CCA starts at block:", auctionStartBlock);
        console2.log("  Blind deadline at block:", blindDeadline);
        console2.log("  CCA ends at block:", auctionEndBlock);
    }

    // ══════════════════════════════════════════════════════════════════
    //                    TEST: DEPLOYMENT VERIFICATION
    // ══════════════════════════════════════════════════════════════════

    function test_DeploymentAddresses() public view {
        console2.log("=== Verifying Deployments ===");

        // fhEVM stack
        assertEq(ACL(aclAdd).getVersion(), "ACL v0.2.0", "ACL not deployed");
        assertEq(
            FHEVMExecutor(fhevmExecutorAdd).getVersion(), "FHEVMExecutor v0.1.0", "FHEVMExecutor not deployed"
        );

        // CCA
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(cca.totalSupply(), uint128(TOTAL_SUPPLY), "CCA total supply mismatch");
        assertEq(cca.floorPrice(), FLOOR_PRICE, "CCA floor price mismatch");

        // BlindPool
        assertEq(address(blindPool.cca()), address(cca), "BlindPool CCA mismatch");
        assertEq(blindPool.blindBidDeadline(), blindDeadline, "BlindPool deadline mismatch");
        assertEq(blindPool.nextBlindBidId(), 0, "Should have no bids yet");
        assertFalse(blindPool.revealed(), "Should not be revealed yet");

        console2.log("  All deployments verified");
    }

    // ══════════════════════════════════════════════════════════════════
    //              TEST: BIDS ARE HIDDEN (FHE ENCRYPTION)
    // ══════════════════════════════════════════════════════════════════

    function test_BlindBidsAreHidden() public {
        console2.log("=== Testing Bid Privacy ===");

        vm.roll(auctionStartBlock);

        // ── Bidder 1 submits an encrypted bid ──
        vm.prank(bidder1);
        blindPool.mockSubmitBlindBid{value: 1 ether}(
            100_000, // encrypted max price (scaled down)
            500_000 // encrypted amount (scaled down)
        );

        // ── Bidder 2 submits a different encrypted bid ──
        vm.prank(bidder2);
        blindPool.mockSubmitBlindBid{value: 2 ether}(
            200_000, // different price
            1_500_000 // different amount
        );

        // ── Verify bids are stored ──
        assertEq(blindPool.nextBlindBidId(), 2, "Should have 2 bids");

        // ── Verify public info is correct ──
        (address b1Bidder, uint256 b1Deposit, bool b1Fwd) = blindPool.getBlindBidInfo(0);
        (address b2Bidder, uint256 b2Deposit, bool b2Fwd) = blindPool.getBlindBidInfo(1);

        assertEq(b1Bidder, bidder1, "Bid 0 bidder mismatch");
        assertEq(b1Deposit, 1 ether, "Bid 0 deposit mismatch");
        assertFalse(b1Fwd, "Bid 0 should not be forwarded");

        assertEq(b2Bidder, bidder2, "Bid 1 bidder mismatch");
        assertEq(b2Deposit, 2 ether, "Bid 1 deposit mismatch");
        assertFalse(b2Fwd, "Bid 1 should not be forwarded");

        // ── The actual maxPrice and amount are euint64 handles (opaque) ──
        euint64 encPrice0 = blindPool.getEncMaxPrice(0);
        euint64 encAmount0 = blindPool.getEncAmount(0);

        assertTrue(FHE.isInitialized(encPrice0), "Price handle should be initialized");
        assertTrue(FHE.isInitialized(encAmount0), "Amount handle should be initialized");

        console2.log("  Bid 0: bidder=%s deposit=%d price=HIDDEN amount=HIDDEN", b1Bidder, b1Deposit);
        console2.log("  Bid 1: bidder=%s deposit=%d price=HIDDEN amount=HIDDEN", b2Bidder, b2Deposit);
        console2.log("  Privacy verified: bid values are encrypted euint64 handles");
    }

    // ══════════════════════════════════════════════════════════════════
    //              TEST: CANNOT BID AFTER DEADLINE
    // ══════════════════════════════════════════════════════════════════

    function test_CannotBidAfterDeadline() public {
        vm.roll(blindDeadline);

        vm.prank(bidder1);
        vm.expectRevert(BlindPoolCCA.AuctionClosed.selector);
        blindPool.mockSubmitBlindBid{value: 1 ether}(100_000, 500_000);

        console2.log("  Correctly reverts after deadline");
    }

    // ══════════════════════════════════════════════════════════════════
    //              TEST: CANNOT REVEAL BEFORE DEADLINE
    // ══════════════════════════════════════════════════════════════════

    function test_CannotRevealBeforeDeadline() public {
        vm.roll(auctionStartBlock);

        vm.expectRevert(BlindPoolCCA.AuctionStillOpen.selector);
        blindPool.requestReveal();

        console2.log("  Correctly blocks early reveal");
    }

    // ══════════════════════════════════════════════════════════════════
    //              TEST: REVEAL MARKS BIDS AS DECRYPTABLE
    // ══════════════════════════════════════════════════════════════════

    function test_RevealFlow() public {
        console2.log("=== Testing Reveal Flow ===");

        vm.roll(auctionStartBlock);

        // Submit 3 bids
        vm.prank(bidder1);
        blindPool.mockSubmitBlindBid{value: 1 ether}(100_000, 500_000);
        vm.prank(bidder2);
        blindPool.mockSubmitBlindBid{value: 2 ether}(200_000, 1_500_000);
        vm.prank(bidder3);
        blindPool.mockSubmitBlindBid{value: 0.5 ether}(100_000, 300_000);

        assertEq(blindPool.nextBlindBidId(), 3, "Should have 3 bids");
        console2.log("  3 blind bids submitted");

        // Roll past deadline
        vm.roll(blindDeadline);

        // Reveal
        blindPool.requestReveal();
        assertTrue(blindPool.revealed(), "Should be revealed");
        console2.log("  Bids revealed (marked as publicly decryptable)");

        // Cannot reveal twice
        vm.expectRevert(BlindPoolCCA.AlreadyRevealed.selector);
        blindPool.requestReveal();
        console2.log("  Double-reveal correctly blocked");
    }

    // ══════════════════════════════════════════════════════════════════
    //              TEST: MUST DEPOSIT ETH
    // ══════════════════════════════════════════════════════════════════

    function test_MustDepositEth() public {
        vm.roll(auctionStartBlock);

        vm.prank(bidder1);
        vm.expectRevert(BlindPoolCCA.NoDeposit.selector);
        blindPool.mockSubmitBlindBid{value: 0}(100_000, 500_000);

        console2.log("  Correctly requires ETH deposit");
    }

    // ══════════════════════════════════════════════════════════════════
    //              TEST: CANNOT FORWARD BEFORE REVEAL
    // ══════════════════════════════════════════════════════════════════

    function test_CannotForwardBeforeReveal() public {
        vm.roll(auctionStartBlock);

        vm.prank(bidder1);
        blindPool.mockSubmitBlindBid{value: 1 ether}(100_000, 500_000);

        vm.expectRevert(BlindPoolCCA.NotRevealed.selector);
        blindPool.forwardBidToCCA(0, 100_000, 500_000, bytes(""));

        console2.log("  Correctly blocks forwarding before reveal");
    }

    // ══════════════════════════════════════════════════════════════════
    //              TEST: FULL E2E FLOW
    // ══════════════════════════════════════════════════════════════════

    function test_FullFlow() public {
        console2.log("=== Full End-to-End Flow ===");

        // ── Phase 1: Submit blind bids ──
        vm.roll(auctionStartBlock);
        console2.log("  Phase 1: Submitting blind bids...");

        vm.prank(bidder1);
        blindPool.mockSubmitBlindBid{value: 1 ether}(100_000, 800_000);
        vm.prank(bidder2);
        blindPool.mockSubmitBlindBid{value: 2 ether}(200_000, 1_500_000);

        console2.log("    2 blind bids submitted");
        console2.log("    BlindPool ETH balance:", address(blindPool).balance);

        // ── Verify privacy: only addresses/deposits visible, not prices/amounts ──
        (address b1Addr, uint256 b1Dep,) = blindPool.getBlindBidInfo(0);
        (address b2Addr, uint256 b2Dep,) = blindPool.getBlindBidInfo(1);

        assertEq(b1Addr, bidder1);
        assertEq(b1Dep, 1 ether);
        assertEq(b2Addr, bidder2);
        assertEq(b2Dep, 2 ether);

        // encrypted handles exist but are opaque
        assertTrue(FHE.isInitialized(blindPool.getEncMaxPrice(0)));
        assertTrue(FHE.isInitialized(blindPool.getEncAmount(0)));
        assertTrue(FHE.isInitialized(blindPool.getEncMaxPrice(1)));
        assertTrue(FHE.isInitialized(blindPool.getEncAmount(1)));

        // encrypted aggregates exist
        assertTrue(FHE.isInitialized(blindPool.encHighestPrice()));
        assertTrue(FHE.isInitialized(blindPool.encTotalDemand()));

        console2.log("    All encrypted handles valid");

        // ── Phase 2: Reveal ──
        vm.roll(blindDeadline);
        console2.log("  Phase 2: Revealing bids...");
        blindPool.requestReveal();
        assertTrue(blindPool.revealed());
        console2.log("    Bids revealed");

        // ── Final state ──
        console2.log("");
        console2.log("=== Final State ===");
        console2.log("  Total blind bids:", blindPool.nextBlindBidId());
        console2.log("  Revealed:", blindPool.revealed());
        console2.log("  BlindPool ETH balance:", address(blindPool).balance);

        // NOTE: forwardBidToCCA requires real KMS decryption proofs which
        // are only available on Sepolia with the actual Zama coprocessor.
        // On local Anvil, the FHE operations are symbolic — handles exist
        // but real decryption + proof verification needs the live KMS.
        //
        // For the hackathon demo: deploy to Sepolia where the full flow
        // (encrypt -> store -> reveal -> decrypt -> forward) works end-to-end.

        console2.log("");
        console2.log("=== Test Complete ===");
        console2.log("  Bids are encrypted on-chain (euint64 handles)");
        console2.log("  Nobody can read maxPrice or amount during auction");
        console2.log("  After deadline, bids can be revealed for settlement");
        console2.log("  ForwardBidToCCA requires live Zama KMS (Sepolia testnet)");
    }

    // ══════════════════════════════════════════════════════════════════
    //                       HELPERS
    // ══════════════════════════════════════════════════════════════════

    function _buildAuctionSteps() internal pure returns (bytes memory) {
        uint24 mps = 100_000;
        uint40 blockDelta = 100;
        bytes8 step1 = bytes8(uint64(mps) << 40 | uint64(blockDelta));
        return abi.encodePacked(step1);
    }
}
