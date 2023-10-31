// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Merge is IERC721, ERC165, IERC721Metadata, Ownable {
    error Merge__InvalidMsgSender();
    error Merge__Frozen();
    error Merge__MustHoldBySameOwner();
    error Merge__NotTokenOwner();
    error Merge__SameTokenId();
    error Merge__ClassOutOfRange();
    error Merge__MassOutOfRange();
    error Merge__NonExistentToken();
    error Merge__CannotTransferToZeroAddress();
    error Merge__CannotTransferBlacklistedAddress();
    error Merge__CannotApproveToCurrentOwner();
    error Merge__CallerIsNotOwnerNorApprovedForAll();
    error Merge__CallerIsNotOwnerNorApproved();
    error Merge__CannotApproveToMsgSender();
    error Merge__MintingFinalized();

    bool private s_frozen;
    bool private s_mintingFinalized;
    uint256 private s_alphaMass;
    uint256 private s_alphaId;
    uint256 private s_totalSupply;
    uint256 private s_massTotal;
    uint256 private s_nextMintId;
    address private s_omnibus;

    string private constant NAME = "merge.";
    string private constant SYMBOL = "m";
    uint256 private constant CLASS_MULTIPLIER = 100 * 1000 * 1000;
    uint256 private constant MIN_MASS_INCL = 1;
    uint256 private constant MAX_MASS_EXCL = CLASS_MULTIPLIER - 1;
    uint256 private constant MIN_CLASS_INCL = 1;
    uint256 private constant MAX_CLASS_INCL = 4;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    mapping(address => bool) private s_whitelistAddress;
    mapping(address => bool) private s_blacklistAddress;
    mapping(address => uint256) private s_balance;
    // mass => value
    mapping(uint256 tokenId => uint256 value) private s_value;
    // token ID to all quantity merged into it
    mapping(uint256 => uint256) private s_mergeCount;
    mapping(uint256 tokenId => address owner) private s_owner;
    mapping(address owner => uint256 tokenId) private s_token;
    mapping(address => mapping(address => bool)) private s_operatorApprovals;
    mapping(uint256 => address) private s_tokenApprovals;

    event AlphaMassUpdated(uint256 indexed tokenId, uint256 alphaMass);
    event MassUpdated(uint256 indexed tokenIdBurned, uint256 indexed tokenIdPersist, uint256 mass);

    modifier onlyValidWhitelist() {
        if (!s_whitelistAddress[msg.sender]) {
            revert Merge__InvalidMsgSender();
        }
        _;
    }

    modifier notFrozen() {
        if (s_frozen) {
            revert Merge__Frozen();
        }
        _;
    }

    constructor(address omnibus) Ownable(msg.sender) {
        s_nextMintId = 1;
        s_omnibus = omnibus;
        s_blacklistAddress[address(this)] = true;
    }

    function merge(uint256 tokenIdReceiver, uint256 tokenIdSender)
        external
        onlyValidWhitelist
        notFrozen
        returns (uint256 tokenIdDead)
    {
        address owner = ownerOf(tokenIdReceiver);
        if (owner != ownerOf(tokenIdSender)) {
            revert Merge__MustHoldBySameOwner();
        }
        if (owner != msg.sender) {
            revert Merge__NotTokenOwner();
        }

        // owners are same, so decrement their balance as we are merging
        s_balance[owner] -= 1;

        tokenIdDead = _merge(tokenIdReceiver, tokenIdSender);

        // clear ownership of dead token
        delete s_owner[tokenIdDead];

        emit Transfer(owner, address(0), tokenIdDead);
    }

    function mint(uint256[] calldata values) external onlyOwner {
        if (s_mintingFinalized) {
            revert Merge__MintingFinalized();
        }

        uint256 index = s_nextMintId;
        uint256 alphaId = s_alphaId;
        uint256 alphaMass = s_alphaMass;
        address omnibus = s_omnibus;

        // initialize accumulators and counters
        uint256 massAdded;
        uint256 newlyMintedCount;
        uint256 valueIx;

        while (valueIx < values.length) {
            if (_isSentinelMass(values[valueIx])) {
                // skip - dont mint
            } else {
                newlyMintedCount++;
                s_value[index] = values[valueIx];
                s_owner[index] = omnibus;
            }
        }
    }

    function burn(uint256 tokenId) public notFrozen {
        (address owner, bool isApprovedOrOwner) = _isApprovedOrOwner(msg.sender, tokenId);
        if (!isApprovedOrOwner) {
            revert Merge__CallerIsNotOwnerNorApproved();
        }

        _burnNoEmitTransfer(owner, tokenId);

        emit Transfer(owner, address(0), tokenId);
    }

    function approve(address to, uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        if (to == owner) {
            revert Merge__CannotApproveToCurrentOwner();
        }
        if (msg.sender != owner || !isApprovedForAll(owner, msg.sender)) {
            revert Merge__CallerIsNotOwnerNorApprovedForAll();
        }
        _approve(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public {
        if (operator == msg.sender) {
            revert Merge__CannotApproveToMsgSender();
        }
        s_operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function finalize() external onlyOwner {
        thaw();
        s_mintingFinalized = true;
    }

    function freeze() external onlyOwner {
        if (s_mintingFinalized) {
            revert Merge__MintingFinalized();
        }
        s_frozen = true;
    }

    function thaw() public onlyOwner {
        s_frozen = false;
    }

    function _merge(uint256 tokenIdReceiver, uint256 tokenIdSender) internal returns (uint256 tokenIdDead) {
        if (tokenIdReceiver == tokenIdSender) {
            revert Merge__SameTokenId();
        }

        uint256 massReceiver = decodeMass(s_value[tokenIdReceiver]);
        uint256 massSender = decodeMass(s_value[tokenIdSender]);

        uint256 massSmall = massReceiver;
        uint256 massLarge = massSender;

        uint256 tokenIdSmall = tokenIdReceiver;
        uint256 tokenIdLarge = tokenIdSender;

        if (massReceiver >= massSender) {
            massSmall = massSender;
            massLarge = massReceiver;

            tokenIdSmall = tokenIdSender;
            tokenIdLarge = tokenIdReceiver;
        }

        s_value[tokenIdLarge] += massSmall;

        uint256 combinedMass = massLarge + massSmall;

        if (combinedMass > s_alphaMass) {
            s_alphaId = tokenIdLarge;
            s_alphaMass = combinedMass;
            emit AlphaMassUpdated(s_alphaId, s_alphaMass);
        }

        s_mergeCount[tokenIdLarge]++;
        delete s_value[tokenIdSmall];

        s_totalSupply--;
        emit MassUpdated(tokenIdSmall, tokenIdLarge, combinedMass);

        return tokenIdSmall;
    }

    function _transfer(address from, address to, uint256 tokenId) internal notFrozen {
        if (to == address(0)) {
            revert Merge__CannotTransferToZeroAddress();
        }
        if (s_blacklistAddress[to]) {
            revert Merge__CannotTransferBlacklistedAddress();
        }

        // if transferring to `DEAD` then `_transfer` is interpreted as a burn
        if (to == DEAD) {
            _burnNoEmitTransfer(from, tokenId);

            emit Transfer(from, DEAD, tokenId);
            emit Transfer(DEAD, address(0), tokenId);
        } else {
            // clear prior approvals
            _approve(from, address(0), tokenId);

            // in all cases we first wish to log the transfer
            // no merging later can deny the fact that `from` transferred to `to`
            emit Transfer(from, to, tokenId);

            if (from == to) {
                return;
            }

            // if all addresses were whitelisted, then transfer would be like any other ERC-721
            // _balances[from] -= 1;
            // _balances[to] += 1;
            // _owners[tokenId] = to;

            // _balances (1) and _owners (2) are the main mappings to update
            // for non-whitelisted addresses there is also the _tokens (3) mapping
            //
            // Our updates will be
            //   - 1a: decrement balance of `from`
            //   - 1b: update balance of `to` (not guaranteed to increase)
            //   - 2: assign ownership of `tokenId`
            //   - 3a: assign unique token of `to`
            //   - 3b: unassign unique token of `from`

            bool fromIsWhitelisted = isWhitelisted(from);
            bool toIsWhitelisted = isWhitelisted(to);

            if (fromIsWhitelisted) {
                s_balance[from] -= 1;
            } else {
                // for non-whitelisted addresses, we have the invariant that
                //   _balances[a] <= 1
                // we known that `from` was the owner so the only possible state is
                //   _balances[from] == 1
                // to save an SLOAD, we can assign a balance of 0 (or delete)
                delete s_balance[from];
            }

            if (toIsWhitelisted) {
                // from the reasoning:
                // > if all addresses were whitelisted, then transfer would be like any other ERC-721
                s_balance[to] += 1;
            } else if (s_token[to] == 0) {
                // for non-whitelisted addresses, we have the invariant that
                //   _balances[a] <= 1
                // if _tokens[to] == 0 then _balances[to] == 0
                // to save an SLOAD, we can assign a balance of 1
                s_balance[to] = 1;
            } else {
                // for non-whitelisted addresses, we have the invariant that
                //   _balances[a] <= 1
                // if _tokens[to] != 0 then _balance[to] == 1
                // to preserve the invariant, we have nothing to do (the balance is already 1)
            }

            if (toIsWhitelisted) {
                // PART 2: update _owners
                // assign ownership of token
                //   the classic implementation would be
                //   _owners[tokenId] = to;
                //
                // from the reasoning:
                // > if all addresses were whitelisted, then transfer would be like any other ERC-721
                s_owner[tokenId] = to;
            } else {
                // label current and sent token with respect to address `to`
                uint256 currentTokenId = s_token[to];

                if (currentTokenId == 0) {
                    // PART 2: update _owners
                    // assign ownership of token
                    s_owner[tokenId] = to;

                    // PART 3a
                    // assign unique token of `to`
                    s_token[to] = tokenId;
                } else {
                    uint256 sentTokenId = tokenId;

                    // compute token merge, returning the dead token
                    uint256 deadTokenId = _merge(currentTokenId, sentTokenId);

                    // logically, the token has already been transferred to `to`
                    // so log the burning of the dead token id as originating ‘from’ `to`
                    emit Transfer(to, address(0), deadTokenId);

                    // thus inferring the alive token
                    uint256 aliveTokenId = currentTokenId;
                    if (currentTokenId == deadTokenId) {
                        aliveTokenId = sentTokenId;
                    }

                    // PART 2 continued:
                    // and ownership of dead token is deleted
                    delete s_owner[deadTokenId];

                    // if received token surplanted the current token
                    if (currentTokenId != aliveTokenId) {
                        // PART 2 continued:
                        // to takes ownership of alive token
                        s_owner[aliveTokenId] = to;

                        // PART 3a
                        // assign unique token of `to`
                        s_token[to] = aliveTokenId;
                    }
                }
            }

            // PART 3b:
            // unassign unique token of `from`
            //
            // _tokens is only defined for non-whitelisted addresses
            if (!fromIsWhitelisted) {
                delete s_token[from];
            }
        }
    }

    function _approve(address owner, address to, uint256 tokenId) internal {
        s_tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function _burnNoEmitTransfer(address owner, uint256 tokenId) internal {
        _approve(owner, address(0), tokenId);

        s_massTotal -= decodeMass(s_value[tokenId]);

        delete s_value[tokenId];
        delete s_owner[tokenId];
        delete s_token[owner];

        s_totalSupply -= 1;
        s_balance[owner] -= 1;

        emit MassUpdated(tokenId, 0, 0);
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return s_operatorApprovals[owner][operator];
    }

    function decodeClassAndMass(uint256 value) public pure returns (uint256, uint256) {
        uint256 class = decodeClass(value);
        uint256 mass = value % CLASS_MULTIPLIER;
        ensureValidMass(mass);
    }

    function decodeClass(uint256 value) public pure returns (uint256 class) {
        class = value / CLASS_MULTIPLIER;
        ensureValidClass(class);
    }

    function decodeMass(uint256 value) public pure returns (uint256 mass) {
        mass = value % CLASS_MULTIPLIER;
        ensureValidMass(mass);
    }

    function ensureValidClass(uint256 class) private pure {
        if (MIN_CLASS_INCL > class || class > MAX_CLASS_INCL) {
            revert Merge__ClassOutOfRange();
        }
    }

    function ensureValidMass(uint256 mass) private pure {
        if (MIN_MASS_INCL > mass || mass >= MAX_MASS_EXCL) {
            revert Merge__MassOutOfRange();
        }
    }

    function name() public view returns (string memory) {
        return NAME;
    }

    function symbol() public view returns (string memory) {
        return SYMBOL;
    }

    function totalSupply() public view returns (uint256) {
        return s_totalSupply;
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = s_owner[tokenId];
        if (owner == address(0)) {
            revert Merge__NonExistentToken();
        }
    }

    function isWhitelisted(address addr) public view returns (bool) {
        return s_whitelistAddress[addr];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Metadata).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId)
        internal
        view
        returns (address owner, bool isApprovedOrOwner)
    {
        owner = s_owner[tokenId];
        if (owner == address(0)) {
            revert Merge__NonExistentToken();
        }
        isApprovedOrOwner =
            (spender == owner || s_tokenApprovals[tokenId] == spender || isApprovedForAll(owner, spender));
    }

    function _isSentinelMass(uint256 value) private pure returns (bool) {
        return (value % CLASS_MULTIPLIER) == MAX_MASS_EXCL;
    }
}
