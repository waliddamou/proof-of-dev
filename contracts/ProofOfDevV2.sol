// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ProofOfDevV2
 * @notice Soulbound (non-transferable) ERC-721 representing a developer's on-chain
 *         reputation score — with the score CRYPTOGRAPHICALLY VOUCHED by a trusted
 *         off-chain signer.
 *
 * @dev    Security model (fixes the critical self-attestation flaw of V1):
 *         The off-chain service computes the score and signs an EIP-712 "voucher"
 *         binding (wallet, score, contractCount, verifiedContractCount, hasENS,
 *         nonce, deadline). This contract verifies that signature against a
 *         configured `signer` before minting. A user therefore CANNOT fabricate a
 *         score — they cannot forge the signer's signature.
 *
 *         Standards & features:
 *           - ERC-721 metadata (name/symbol/tokenURI) + ERC-165.
 *           - ERC-5192 "Minimal Soulbound" — locked() + Locked event + interface id.
 *           - ERC-4906 metadata-update events so explorers refresh on score updates.
 *           - Ownable2Step admin (safe ownership handoff).
 *           - Pausable circuit breaker.
 *           - Per-wallet nonces → replay protection + re-scoring (updateScore).
 *           - Burn (by token owner) → frees the wallet to re-mint.
 *           - Custom errors (cheaper than require strings).
 *
 *         No external dependencies — EIP-712 domain separation and ECDSA recovery
 *         are implemented inline so the file compiles in Remix or with plain solc.
 */
contract ProofOfDevV2 {
    // ─── Types ───────────────────────────────────────────────────────────────────

    struct DevMetadata {
        uint256 score;
        uint256 contractCount;
        uint256 verifiedContractCount;
        bool hasENS;
        uint256 mintedAt;
        uint256 updatedAt;
    }

    /// @notice An off-chain signed authorization to mint/update a profile.
    struct Voucher {
        address wallet;                // subject of the reputation (token recipient)
        uint256 score;
        uint256 contractCount;
        uint256 verifiedContractCount;
        bool hasENS;
        uint256 nonce;                 // must equal nonces[wallet]
        uint256 deadline;              // unix time after which the voucher is invalid
    }

    // ─── Events ──────────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Minted(address indexed to, uint256 indexed tokenId, uint256 score);
    event ScoreUpdated(uint256 indexed tokenId, uint256 oldScore, uint256 newScore);

    // ERC-5192
    event Locked(uint256 tokenId);

    // ERC-4906 (metadata refresh)
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    // Admin
    event SignerUpdated(address indexed previousSigner, address indexed newSigner);
    event BaseURIUpdated(string newBaseURI);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    // ─── Errors ──────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error AlreadyMinted();
    error TokenDoesNotExist();
    error NotTokenOwner();
    error Soulbound();
    error EnforcedPause();
    error ExpectedPause();
    error VoucherExpired();
    error InvalidNonce(uint256 expected, uint256 provided);
    error InvalidSignature();
    error ValueOutOfRange();

    // ─── Constants ───────────────────────────────────────────────────────────────

    string public constant name = "Proof of Dev";
    string public constant symbol = "POD";

    uint256 public constant MAX_SCORE = 100_000;
    uint256 public constant MAX_COUNT = 100_000;

    // EIP-712
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _VOUCHER_TYPEHASH =
        keccak256(
            "Voucher(address wallet,uint256 score,uint256 contractCount,uint256 verifiedContractCount,bool hasENS,uint256 nonce,uint256 deadline)"
        );

    // ─── Storage ─────────────────────────────────────────────────────────────────

    uint256 private _nextTokenId = 1;

    mapping(uint256 => address) private _owners;       // tokenId → owner
    mapping(address => uint256) private _tokens;       // owner → tokenId (0 = none)
    mapping(uint256 => DevMetadata) private _metadata; // tokenId → metadata
    mapping(address => uint256) public nonces;         // wallet → next expected nonce

    string private _baseTokenURI;

    address public owner;
    address public pendingOwner;
    address public signer;            // the trusted off-chain voucher signer
    bool public paused;

    // Cached EIP-712 domain separator (recomputed if chainId changes, e.g. a fork)
    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;

    // ─── Constructor ─────────────────────────────────────────────────────────────

    constructor(string memory baseTokenURI, address signer_) {
        if (signer_ == address(0)) revert ZeroAddress();
        _baseTokenURI = baseTokenURI;
        owner = msg.sender;
        signer = signer_;

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();

        emit OwnershipTransferred(address(0), msg.sender);
        emit SignerUpdated(address(0), signer_);
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    // ─── Mint / update (signature-gated) ─────────────────────────────────────────

    /**
     * @notice Mint a soulbound Proof-of-Dev token using a server-signed voucher.
     * @dev    Anyone may submit (e.g. a relayer); the token always goes to
     *         `voucher.wallet`. Each wallet can hold only one token at a time.
     */
    function mint(Voucher calldata voucher, bytes calldata signature)
        external
        whenNotPaused
        returns (uint256 tokenId)
    {
        _validateVoucher(voucher, signature);
        if (_tokens[voucher.wallet] != 0) revert AlreadyMinted();

        nonces[voucher.wallet] += 1;

        tokenId = _nextTokenId++;
        _owners[tokenId] = voucher.wallet;
        _tokens[voucher.wallet] = tokenId;
        _metadata[tokenId] = DevMetadata({
            score: voucher.score,
            contractCount: voucher.contractCount,
            verifiedContractCount: voucher.verifiedContractCount,
            hasENS: voucher.hasENS,
            mintedAt: block.timestamp,
            updatedAt: block.timestamp
        });

        emit Transfer(address(0), voucher.wallet, tokenId);
        emit Locked(tokenId); // ERC-5192: soulbound from birth
        emit Minted(voucher.wallet, tokenId, voucher.score);
    }

    /**
     * @notice Refresh an existing profile with a newer server-signed voucher.
     * @dev    Re-scoring path. Consumes a fresh nonce (old vouchers can't replay).
     */
    function updateScore(Voucher calldata voucher, bytes calldata signature)
        external
        whenNotPaused
    {
        _validateVoucher(voucher, signature);
        uint256 tokenId = _tokens[voucher.wallet];
        if (tokenId == 0) revert TokenDoesNotExist();

        nonces[voucher.wallet] += 1;

        DevMetadata storage m = _metadata[tokenId];
        uint256 oldScore = m.score;
        m.score = voucher.score;
        m.contractCount = voucher.contractCount;
        m.verifiedContractCount = voucher.verifiedContractCount;
        m.hasENS = voucher.hasENS;
        m.updatedAt = block.timestamp;

        emit ScoreUpdated(tokenId, oldScore, voucher.score);
        emit MetadataUpdate(tokenId); // ERC-4906: tell explorers to refresh
    }

    /**
     * @notice Burn your own token (the only allowed "transfer" besides minting).
     * @dev    Frees the wallet to mint again later; the nonce keeps incrementing.
     */
    function burn(uint256 tokenId) external {
        address tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
        if (tokenOwner != msg.sender) revert NotTokenOwner();

        delete _owners[tokenId];
        delete _tokens[tokenOwner];
        delete _metadata[tokenId];

        emit Transfer(tokenOwner, address(0), tokenId);
    }

    // ─── Voucher validation ──────────────────────────────────────────────────────

    function _validateVoucher(Voucher calldata voucher, bytes calldata signature) private view {
        if (voucher.wallet == address(0)) revert ZeroAddress();
        if (block.timestamp > voucher.deadline) revert VoucherExpired();
        if (voucher.nonce != nonces[voucher.wallet]) {
            revert InvalidNonce(nonces[voucher.wallet], voucher.nonce);
        }
        if (voucher.score > MAX_SCORE) revert ValueOutOfRange();
        if (voucher.contractCount > MAX_COUNT || voucher.verifiedContractCount > MAX_COUNT) {
            revert ValueOutOfRange();
        }

        bytes32 structHash = keccak256(
            abi.encode(
                _VOUCHER_TYPEHASH,
                voucher.wallet,
                voucher.score,
                voucher.contractCount,
                voucher.verifiedContractCount,
                voucher.hasENS,
                voucher.nonce,
                voucher.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));

        address recovered = _recover(digest, signature);
        if (recovered != signer) revert InvalidSignature();
    }

    // ─── EIP-712 helpers ─────────────────────────────────────────────────────────

    /// @notice The current EIP-712 domain separator (recomputed on fork/chainId change).
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function _domainSeparator() private view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _cachedDomainSeparator;
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes("2")), // version
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev ECDSA recovery with EIP-2 low-s + valid-v enforcement (anti-malleability).
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        // Reject the upper half of the curve order to prevent signature malleability.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }
        if (v != 27 && v != 28) revert InvalidSignature();

        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert InvalidSignature();
        return recovered;
    }

    // ─── ERC-721 (read) ──────────────────────────────────────────────────────────

    function balanceOf(address account) external view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _tokens[account] != 0 ? 1 : 0;
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address tokenOwner = _owners[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
        return tokenOwner;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return string(abi.encodePacked(_baseTokenURI, "/", _toString(tokenId)));
    }

    function getMetadata(uint256 tokenId) external view returns (DevMetadata memory) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return _metadata[tokenId];
    }

    function getTokenByAddress(address account) external view returns (uint256) {
        return _tokens[account];
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    // ─── ERC-5192 (soulbound) ────────────────────────────────────────────────────

    /// @notice All tokens are permanently locked. Reverts for non-existent tokens.
    function locked(uint256 tokenId) external view returns (bool) {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist();
        return true;
    }

    // ─── ERC-165 ─────────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC-165
            interfaceId == 0x80ac58cd || // ERC-721
            interfaceId == 0x5b5e139f || // ERC-721Metadata
            interfaceId == 0xb45a3c0e || // ERC-5192 (soulbound)
            interfaceId == 0x49064906;   // ERC-4906 (metadata update)
    }

    // ─── Soulbound: block all transfer/approval entrypoints ──────────────────────

    function transferFrom(address, address, uint256) external pure { revert Soulbound(); }
    function safeTransferFrom(address, address, uint256) external pure { revert Soulbound(); }
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure { revert Soulbound(); }
    function approve(address, uint256) external pure { revert Soulbound(); }
    function setApprovalForAll(address, bool) external pure { revert Soulbound(); }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }

    // ─── Admin ───────────────────────────────────────────────────────────────────

    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerUpdated(signer, newSigner);
        signer = newSigner;
    }

    function setBaseURI(string calldata baseTokenURI) external onlyOwner {
        _baseTokenURI = baseTokenURI;
        emit BaseURIUpdated(baseTokenURI);
        uint256 last = _nextTokenId - 1;
        if (last >= 1) emit BatchMetadataUpdate(1, last); // refresh all tokens
    }

    function pause() external onlyOwner {
        if (paused) revert EnforcedPause();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert ExpectedPause();
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ─── Ownable2Step ────────────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ─── Utilities ───────────────────────────────────────────────────────────────

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
