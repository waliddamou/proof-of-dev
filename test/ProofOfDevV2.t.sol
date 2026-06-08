// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProofOfDevV2} from "../contracts/ProofOfDevV2.sol";

/**
 * @title ProofOfDevV2 test suite
 * @notice Covers: valid mint/update/burn, every revert path, access control,
 *         soulbound enforcement, replay protection, and signature edge cases
 *         (bad signer, wrong length, EIP-2 malleability).
 *
 * Run: forge test -vvv
 */
contract ProofOfDevV2Test is Test {
    ProofOfDevV2 internal pod;

    // Trusted off-chain signer (the server). Tests sign vouchers with SIGNER_PK.
    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant WRONG_PK = 0xB0B;
    address internal signer;

    address internal owner = address(this);
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);
    address internal relayer = address(0xCAFE);

    string internal constant BASE_URI = "https://proof-of-dev.example/api/token";

    bytes32 internal constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(address wallet,uint256 score,uint256 contractCount,uint256 verifiedContractCount,bool hasENS,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // Re-declared events for vm.expectEmit matching.
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Minted(address indexed to, uint256 indexed tokenId, uint256 score);
    event ScoreUpdated(uint256 indexed tokenId, uint256 oldScore, uint256 newScore);
    event Locked(uint256 tokenId);
    event MetadataUpdate(uint256 _tokenId);
    event SignerUpdated(address indexed previousSigner, address indexed newSigner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        vm.warp(10_000); // give room for deadline math
        pod = new ProofOfDevV2(BASE_URI, signer);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    function _voucher(address wallet, uint256 nonce)
        internal
        view
        returns (ProofOfDevV2.Voucher memory)
    {
        return ProofOfDevV2.Voucher({
            wallet: wallet,
            score: 42,
            contractCount: 5,
            verifiedContractCount: 3,
            hasENS: true,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @dev Computed locally (matches the contract) so signing makes NO external
    ///      call — otherwise that call would be wrongly consumed by vm.expectRevert.
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Proof of Dev")),
                keccak256(bytes("2")),
                block.chainid,
                address(pod)
            )
        );
    }

    function _digest(ProofOfDevV2.Voucher memory v) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                VOUCHER_TYPEHASH,
                v.wallet,
                v.score,
                v.contractCount,
                v.verifiedContractCount,
                v.hasENS,
                v.nonce,
                v.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _sign(ProofOfDevV2.Voucher memory v, uint256 pk) internal view returns (bytes memory) {
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(pk, _digest(v));
        return abi.encodePacked(r, s, sv);
    }

    function _signMalleable(ProofOfDevV2.Voucher memory v, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(pk, _digest(v));
        uint256 s2 = SECP256K1_N - uint256(s); // flip to the upper half (high-s)
        uint8 v2 = sv == 27 ? 28 : 27;
        return abi.encodePacked(r, bytes32(s2), v2);
    }

    function _mintAlice() internal returns (uint256 tokenId) {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        tokenId = pod.mint(v, _sign(v, SIGNER_PK));
    }

    // ─── Initial state ───────────────────────────────────────────────────────────

    function test_InitialState() public view {
        assertEq(pod.name(), "Proof of Dev");
        assertEq(pod.symbol(), "POD");
        assertEq(pod.owner(), owner);
        assertEq(pod.signer(), signer);
        assertEq(pod.paused(), false);
        assertEq(pod.totalSupply(), 0);
        assertTrue(pod.DOMAIN_SEPARATOR() != bytes32(0));
        // The test's locally-computed domain separator must match the contract's.
        assertEq(pod.DOMAIN_SEPARATOR(), _domainSeparator());
    }

    function test_Constructor_RevertWhen_ZeroSigner() public {
        vm.expectRevert(ProofOfDevV2.ZeroAddress.selector);
        new ProofOfDevV2(BASE_URI, address(0));
    }

    // ─── Mint: happy path ────────────────────────────────────────────────────────

    function test_Mint_Success() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 1);
        vm.expectEmit(false, false, false, true);
        emit Locked(1);
        vm.expectEmit(true, true, false, true);
        emit Minted(alice, 1, 42);

        uint256 tokenId = pod.mint(v, _sign(v, SIGNER_PK));

        assertEq(tokenId, 1);
        assertEq(pod.ownerOf(1), alice);
        assertEq(pod.balanceOf(alice), 1);
        assertEq(pod.getTokenByAddress(alice), 1);
        assertEq(pod.totalSupply(), 1);
        assertEq(pod.nonces(alice), 1);
        assertTrue(pod.locked(1));

        ProofOfDevV2.DevMetadata memory m = pod.getMetadata(1);
        assertEq(m.score, 42);
        assertEq(m.contractCount, 5);
        assertEq(m.verifiedContractCount, 3);
        assertTrue(m.hasENS);
        assertEq(m.mintedAt, block.timestamp);
        assertEq(m.updatedAt, block.timestamp);
    }

    function test_Mint_RelayerCanSubmitForWallet() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        bytes memory sig = _sign(v, SIGNER_PK);

        vm.prank(relayer); // a different account submits the tx
        pod.mint(v, sig);

        // Token still belongs to the voucher's wallet, not the relayer.
        assertEq(pod.ownerOf(1), alice);
        assertEq(pod.balanceOf(relayer), 0);
    }

    function test_TokenURI_Format() public {
        _mintAlice();
        assertEq(pod.tokenURI(1), string(abi.encodePacked(BASE_URI, "/1")));
    }

    // ─── Mint: revert paths ──────────────────────────────────────────────────────

    function test_Mint_RevertWhen_WrongSigner() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        vm.expectRevert(ProofOfDevV2.InvalidSignature.selector);
        pod.mint(v, _sign(v, WRONG_PK));
    }

    function test_Mint_RevertWhen_Expired() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        v.deadline = block.timestamp; // valid only up to and including now
        bytes memory sig = _sign(v, SIGNER_PK);
        vm.warp(block.timestamp + 1); // now strictly past the deadline
        vm.expectRevert(ProofOfDevV2.VoucherExpired.selector);
        pod.mint(v, sig);
    }

    function test_Mint_RevertWhen_WrongNonce() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 1); // expected is 0
        vm.expectRevert(abi.encodeWithSelector(ProofOfDevV2.InvalidNonce.selector, 0, 1));
        pod.mint(v, _sign(v, SIGNER_PK));
    }

    function test_Mint_RevertWhen_ReplaySameVoucher() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        bytes memory sig = _sign(v, SIGNER_PK);
        pod.mint(v, sig);
        // Nonce is now 1, so the same (nonce-0) voucher fails the nonce check.
        vm.expectRevert(abi.encodeWithSelector(ProofOfDevV2.InvalidNonce.selector, 1, 0));
        pod.mint(v, sig);
    }

    function test_Mint_RevertWhen_AlreadyMinted() public {
        _mintAlice();
        // A fresh, correctly-nonced voucher still fails because a token exists.
        ProofOfDevV2.Voucher memory v = _voucher(alice, 1);
        vm.expectRevert(ProofOfDevV2.AlreadyMinted.selector);
        pod.mint(v, _sign(v, SIGNER_PK));
    }

    function test_Mint_RevertWhen_Paused() public {
        pod.pause();
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        vm.expectRevert(ProofOfDevV2.EnforcedPause.selector);
        pod.mint(v, _sign(v, SIGNER_PK));
    }

    function test_Mint_RevertWhen_ScoreOutOfRange() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        v.score = pod.MAX_SCORE() + 1;
        vm.expectRevert(ProofOfDevV2.ValueOutOfRange.selector);
        pod.mint(v, _sign(v, SIGNER_PK));
    }

    function test_Mint_RevertWhen_CountOutOfRange() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        v.contractCount = pod.MAX_COUNT() + 1;
        vm.expectRevert(ProofOfDevV2.ValueOutOfRange.selector);
        pod.mint(v, _sign(v, SIGNER_PK));
    }

    function test_Mint_RevertWhen_ZeroWallet() public {
        ProofOfDevV2.Voucher memory v = _voucher(address(0), 0);
        vm.expectRevert(ProofOfDevV2.ZeroAddress.selector);
        pod.mint(v, _sign(v, SIGNER_PK));
    }

    function test_Mint_RevertWhen_BadSignatureLength() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        bytes memory badSig = hex"deadbeef"; // not 65 bytes
        vm.expectRevert(ProofOfDevV2.InvalidSignature.selector);
        pod.mint(v, badSig);
    }

    function test_Mint_RevertWhen_MalleableHighS() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        bytes memory malleable = _signMalleable(v, SIGNER_PK);
        vm.expectRevert(ProofOfDevV2.InvalidSignature.selector);
        pod.mint(v, malleable);
    }

    function test_Mint_RevertWhen_TamperedData() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        bytes memory sig = _sign(v, SIGNER_PK);
        v.score = 99999; // change data after signing → signature no longer matches
        vm.expectRevert(ProofOfDevV2.InvalidSignature.selector);
        pod.mint(v, sig);
    }

    // ─── updateScore ─────────────────────────────────────────────────────────────

    function test_UpdateScore_Success() public {
        _mintAlice();

        ProofOfDevV2.Voucher memory v = _voucher(alice, 1);
        v.score = 77;
        v.contractCount = 9;

        vm.expectEmit(true, false, false, true);
        emit ScoreUpdated(1, 42, 77);
        vm.expectEmit(false, false, false, true);
        emit MetadataUpdate(1);

        pod.updateScore(v, _sign(v, SIGNER_PK));

        ProofOfDevV2.DevMetadata memory m = pod.getMetadata(1);
        assertEq(m.score, 77);
        assertEq(m.contractCount, 9);
        assertEq(pod.nonces(alice), 2);
    }

    function test_UpdateScore_RevertWhen_NoToken() public {
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        vm.expectRevert(ProofOfDevV2.TokenDoesNotExist.selector);
        pod.updateScore(v, _sign(v, SIGNER_PK));
    }

    function test_UpdateScore_RevertWhen_ReplayOldVoucher() public {
        _mintAlice();
        ProofOfDevV2.Voucher memory v = _voucher(alice, 1);
        bytes memory sig = _sign(v, SIGNER_PK);
        pod.updateScore(v, sig); // nonce → 2
        vm.expectRevert(abi.encodeWithSelector(ProofOfDevV2.InvalidNonce.selector, 2, 1));
        pod.updateScore(v, sig);
    }

    // ─── Burn ────────────────────────────────────────────────────────────────────

    function test_Burn_Success_AndCanRemint() public {
        _mintAlice();

        vm.expectEmit(true, true, true, false);
        emit Transfer(alice, address(0), 1);
        vm.prank(alice);
        pod.burn(1);

        assertEq(pod.balanceOf(alice), 0);
        assertEq(pod.getTokenByAddress(alice), 0);
        vm.expectRevert(ProofOfDevV2.TokenDoesNotExist.selector);
        pod.ownerOf(1);

        // Nonce stayed at 1 (mint consumed it); re-mint must use nonce 1.
        ProofOfDevV2.Voucher memory v = _voucher(alice, 1);
        uint256 newId = pod.mint(v, _sign(v, SIGNER_PK));
        assertEq(newId, 2);
        assertEq(pod.ownerOf(2), alice);
    }

    function test_Burn_RevertWhen_NotTokenOwner() public {
        _mintAlice();
        vm.prank(bob);
        vm.expectRevert(ProofOfDevV2.NotTokenOwner.selector);
        pod.burn(1);
    }

    function test_Burn_RevertWhen_Nonexistent() public {
        vm.prank(alice);
        vm.expectRevert(ProofOfDevV2.TokenDoesNotExist.selector);
        pod.burn(999);
    }

    // ─── Soulbound enforcement ───────────────────────────────────────────────────

    function test_Soulbound_TransfersRevert() public {
        _mintAlice();
        vm.startPrank(alice);

        vm.expectRevert(ProofOfDevV2.Soulbound.selector);
        pod.transferFrom(alice, bob, 1);

        vm.expectRevert(ProofOfDevV2.Soulbound.selector);
        pod.safeTransferFrom(alice, bob, 1);

        vm.expectRevert(ProofOfDevV2.Soulbound.selector);
        pod.safeTransferFrom(alice, bob, 1, "");

        vm.expectRevert(ProofOfDevV2.Soulbound.selector);
        pod.approve(bob, 1);

        vm.expectRevert(ProofOfDevV2.Soulbound.selector);
        pod.setApprovalForAll(bob, true);

        vm.stopPrank();
    }

    // ─── ERC-5192 / ERC-165 ──────────────────────────────────────────────────────

    function test_Locked_RevertWhen_Nonexistent() public {
        vm.expectRevert(ProofOfDevV2.TokenDoesNotExist.selector);
        pod.locked(1);
    }

    function test_SupportsInterface() public view {
        assertTrue(pod.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(pod.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(pod.supportsInterface(0x5b5e139f)); // ERC-721Metadata
        assertTrue(pod.supportsInterface(0xb45a3c0e)); // ERC-5192
        assertTrue(pod.supportsInterface(0x49064906)); // ERC-4906
        assertFalse(pod.supportsInterface(0xffffffff));
        assertFalse(pod.supportsInterface(0x12345678));
    }

    // ─── Access control: signer ──────────────────────────────────────────────────

    function test_SetSigner_Success() public {
        address newSigner = vm.addr(0xC0FFEE);
        vm.expectEmit(true, true, false, false);
        emit SignerUpdated(signer, newSigner);
        pod.setSigner(newSigner);
        assertEq(pod.signer(), newSigner);
    }

    function test_SetSigner_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ProofOfDevV2.NotOwner.selector);
        pod.setSigner(alice);
    }

    function test_SetSigner_RevertWhen_Zero() public {
        vm.expectRevert(ProofOfDevV2.ZeroAddress.selector);
        pod.setSigner(address(0));
    }

    function test_NewSignerCanAuthorizeMint() public {
        uint256 newPk = 0xC0FFEE;
        pod.setSigner(vm.addr(newPk));
        ProofOfDevV2.Voucher memory v = _voucher(alice, 0);
        pod.mint(v, _sign(v, newPk));
        assertEq(pod.ownerOf(1), alice);
    }

    // ─── Access control: base URI ────────────────────────────────────────────────

    function test_SetBaseURI_Success() public {
        _mintAlice();
        pod.setBaseURI("https://new.example/t");
        assertEq(pod.tokenURI(1), "https://new.example/t/1");
    }

    function test_SetBaseURI_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ProofOfDevV2.NotOwner.selector);
        pod.setBaseURI("x");
    }

    // ─── Access control: pause ───────────────────────────────────────────────────

    function test_Pause_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ProofOfDevV2.NotOwner.selector);
        pod.pause();
    }

    function test_Pause_RevertWhen_AlreadyPaused() public {
        pod.pause();
        vm.expectRevert(ProofOfDevV2.EnforcedPause.selector);
        pod.pause();
    }

    function test_Unpause_RevertWhen_NotPaused() public {
        vm.expectRevert(ProofOfDevV2.ExpectedPause.selector);
        pod.unpause();
    }

    function test_PauseThenUnpause_AllowsMint() public {
        pod.pause();
        pod.unpause();
        _mintAlice();
        assertEq(pod.ownerOf(1), alice);
    }

    // ─── Access control: Ownable2Step ────────────────────────────────────────────

    function test_TransferOwnership_TwoStep() public {
        pod.transferOwnership(alice);
        assertEq(pod.pendingOwner(), alice);
        assertEq(pod.owner(), owner); // not yet transferred

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        pod.acceptOwnership();

        assertEq(pod.owner(), alice);
        assertEq(pod.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ProofOfDevV2.NotOwner.selector);
        pod.transferOwnership(alice);
    }

    function test_AcceptOwnership_RevertWhen_NotPending() public {
        pod.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ProofOfDevV2.NotPendingOwner.selector);
        pod.acceptOwnership();
    }

    function test_OldOwnerLosesRights_AfterHandoff() public {
        pod.transferOwnership(alice);
        vm.prank(alice);
        pod.acceptOwnership();

        // Previous owner (this contract) can no longer administer.
        vm.expectRevert(ProofOfDevV2.NotOwner.selector);
        pod.pause();
    }

    function test_TransferOwnership_RevertWhen_Zero() public {
        vm.expectRevert(ProofOfDevV2.ZeroAddress.selector);
        pod.transferOwnership(address(0));
    }

    // ─── Misc reads ──────────────────────────────────────────────────────────────

    function test_BalanceOf_RevertWhen_Zero() public {
        vm.expectRevert(ProofOfDevV2.ZeroAddress.selector);
        pod.balanceOf(address(0));
    }

    function test_GetMetadata_RevertWhen_Nonexistent() public {
        vm.expectRevert(ProofOfDevV2.TokenDoesNotExist.selector);
        pod.getMetadata(1);
    }

    // ─── Fuzz: any valid voucher from the signer mints correctly ─────────────────

    function testFuzz_Mint_ValidVoucher(
        uint96 score,
        uint96 cc,
        uint96 vcc,
        bool hasENS
    ) public {
        score = uint96(bound(score, 0, pod.MAX_SCORE()));
        cc = uint96(bound(cc, 0, pod.MAX_COUNT()));
        vcc = uint96(bound(vcc, 0, pod.MAX_COUNT()));

        ProofOfDevV2.Voucher memory v = ProofOfDevV2.Voucher({
            wallet: alice,
            score: score,
            contractCount: cc,
            verifiedContractCount: vcc,
            hasENS: hasENS,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        pod.mint(v, _sign(v, SIGNER_PK));
        ProofOfDevV2.DevMetadata memory m = pod.getMetadata(1);
        assertEq(m.score, score);
        assertEq(m.contractCount, cc);
        assertEq(m.verifiedContractCount, vcc);
        assertEq(m.hasENS, hasENS);
    }
}
