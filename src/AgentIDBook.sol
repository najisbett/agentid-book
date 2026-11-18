// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AgentIDBook
 * @notice An on-chain book for Binance Wallet Agent IDs (name.ai).
 *
 * Agent ID resolution lives off-chain today: `baguslupamakan.ai` maps to an EOA
 * in Binance's backend, and no contract can read that. This book turns a name.ai
 * handle into an on-chain identity any dApp can gate on.
 *
 * A holder proves the handle is theirs by signing an EIP-712 message with the same
 * EOA the Agent ID resolves to. Anyone may submit that signature (a relayer pays
 * the gas), so binding costs the holder nothing. One Agent ID per address, one
 * address per Agent ID.
 */
contract AgentIDBook {
    struct Entry {
        address owner;
        uint64 boundAt;
        string handle;
    }

    bytes32 private constant BIND_TYPEHASH =
        keccak256("Bind(bytes32 id,address owner,string handle,uint256 deadline)");

    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(bytes32 => Entry) private _byId;
    mapping(address => bytes32) public idOf;
    address[] private _agents;

    event Bound(bytes32 indexed id, address indexed owner, string handle);
    event Unbound(bytes32 indexed id, address indexed owner);

    error AlreadyBound(address owner);
    error Expired();
    error EmptyHandle();
    error HandleTaken(bytes32 id, address owner);
    error BadSignature(address recovered, address expected);
    error HandleMismatch(bytes32 given, bytes32 expected);
    error NotBound(address owner);
    error ZeroAddress();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AgentIDBook"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice keccak256 of a lowercased name.ai handle, e.g. "baguslupamakan".
    function idOfHandle(string memory handle) public pure returns (bytes32) {
        return keccak256(bytes(handle));
    }

    function bindDigest(bytes32 id, address owner, string memory handle, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(BIND_TYPEHASH, id, owner, keccak256(bytes(handle)), deadline))
            )
        );
    }

    /**
     * @notice Bind a name.ai handle to the address that signed for it.
     * @dev Permissionless: a relayer submits and pays the gas.
     */
    function bind(bytes32 id, address owner, string calldata handle, uint256 deadline, bytes calldata signature)
        external
    {
        if (owner == address(0)) revert ZeroAddress();
        if (bytes(handle).length == 0) revert EmptyHandle();
        if (block.timestamp > deadline) revert Expired();
        if (id != idOfHandle(handle)) revert HandleMismatch(id, idOfHandle(handle));
        if (idOf[owner] != bytes32(0)) revert AlreadyBound(owner);

        Entry storage existing = _byId[id];
        if (existing.owner != address(0) && existing.owner != owner) revert HandleTaken(id, existing.owner);

        bytes32 digest = bindDigest(id, owner, handle, deadline);
        address recovered = _recover(digest, signature);
        if (recovered != owner) revert BadSignature(recovered, owner);

        if (existing.owner == address(0)) {
            _agents.push(owner);
        }
        _byId[id] = Entry({owner: owner, boundAt: uint64(block.timestamp), handle: handle});
        idOf[owner] = id;

        emit Bound(id, owner, handle);
    }

    function unbind() external {
        bytes32 id = idOf[msg.sender];
        if (id == bytes32(0)) revert NotBound(msg.sender);
        delete _byId[id];
        delete idOf[msg.sender];
        emit Unbound(id, msg.sender);
    }

    function resolve(bytes32 id) external view returns (address) {
        return _byId[id].owner;
    }

    function resolveHandle(string calldata handle) external view returns (address) {
        return _byId[idOfHandle(handle)].owner;
    }

    function handleOf(address owner) external view returns (string memory) {
        return _byId[idOf[owner]].handle;
    }

    function isAgent(address owner) external view returns (bool) {
        return idOf[owner] != bytes32(0);
    }

    function agentCount() external view returns (uint256) {
        return _agents.length;
    }

    function agentAt(uint256 index) external view returns (address) {
        return _agents[index];
    }

    function entryOf(bytes32 id) external view returns (address owner, uint64 boundAt, string memory handle) {
        Entry storage e = _byId[id];
        return (e.owner, e.boundAt, e.handle);
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}