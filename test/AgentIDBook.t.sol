// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentIDBook} from "../src/AgentIDBook.sol";

contract AgentIDBookTest is Test {
    AgentIDBook book;

    uint256 constant ALICE_PK = 0xA11CE;
    uint256 constant BOB_PK = 0xB0B;
    address alice;
    address bob;

    function setUp() public {
        book = new AgentIDBook();
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);
    }

    function _sign(uint256 pk, bytes32 id, address owner, string memory handle, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = book.bindDigest(id, owner, handle, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function testBindBySignatureAndResolve() public {
        string memory handle = "baguslupamakan";
        bytes32 id = book.idOfHandle(handle);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ALICE_PK, id, alice, handle, deadline);

        // a relayer nobody trusts submits it
        vm.prank(address(0xBEEF));
        book.bind(id, alice, handle, deadline, sig);

        assertEq(book.resolve(id), alice);
        assertEq(book.resolveHandle(handle), alice);
        assertEq(book.handleOf(alice), handle);
        assertTrue(book.isAgent(alice));
        assertEq(book.agentCount(), 1);
    }

    function testCannotBindWithSomeoneElsesSignature() public {
        string memory handle = "victim";
        bytes32 id = book.idOfHandle(handle);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ALICE_PK, id, alice, handle, deadline);

        // bob tries to take alice's handle using her signature, claiming he is the owner:
        // the digest names bob, so the recovered signer is neither alice nor bob
        vm.expectRevert();
        book.bind(id, bob, handle, deadline, sig);
    }

    function testHandleMustMatchId() public {
        bytes32 id = book.idOfHandle("alice");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ALICE_PK, id, alice, "alice", deadline);

        vm.expectRevert(
            abi.encodeWithSelector(AgentIDBook.HandleMismatch.selector, id, book.idOfHandle("bob"))
        );
        book.bind(id, alice, "bob", deadline, sig);
    }

    function testOneAgentIdPerAddress() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 first = book.idOfHandle("alice");
        bytes memory s1 = _sign(ALICE_PK, first, alice, "alice", deadline);
        book.bind(first, alice, "alice", deadline, s1);

        bytes32 second = book.idOfHandle("alice2");
        bytes memory s2 = _sign(ALICE_PK, second, alice, "alice2", deadline);
        vm.expectRevert(abi.encodeWithSelector(AgentIDBook.AlreadyBound.selector, alice));
        book.bind(second, alice, "alice2", deadline, s2);
    }

    function testHandleCannotBeStolenOnceBound() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 id = book.idOfHandle("satoshi");
        bytes memory s1 = _sign(ALICE_PK, id, alice, "satoshi", deadline);
        book.bind(id, alice, "satoshi", deadline, s1);

        // bob signs the same handle for his own address: the id is already alice's
        bytes memory s2 = _sign(BOB_PK, id, bob, "satoshi", deadline);
        vm.expectRevert(abi.encodeWithSelector(AgentIDBook.HandleTaken.selector, id, alice));
        book.bind(id, bob, "satoshi", deadline, s2);
    }

    function testExpiredSignatureRejected() public {
        string memory handle = "late";
        bytes32 id = book.idOfHandle(handle);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sign(ALICE_PK, id, alice, handle, deadline);

        vm.expectRevert(AgentIDBook.Expired.selector);
        book.bind(id, alice, handle, deadline, sig);
    }

    function testGarbageSignatureRejected() public {
        string memory handle = "junk";
        bytes32 id = book.idOfHandle(handle);
        bytes memory sig = new bytes(65);
        vm.expectRevert();
        book.bind(id, alice, handle, block.timestamp + 1 hours, sig);
    }

    function testUnbindFreesTheAddressAndTheHandle() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 id = book.idOfHandle("temp");
        bytes memory sig = _sign(ALICE_PK, id, alice, "temp", deadline);
        book.bind(id, alice, "temp", deadline, sig);

        vm.prank(alice);
        book.unbind();

        assertEq(book.resolve(id), address(0));
        assertFalse(book.isAgent(alice));
        assertEq(book.idOf(alice), bytes32(0));

        // and alice can bind a new one afterwards
        bytes32 id2 = book.idOfHandle("temp2");
        bytes memory sig2 = _sign(ALICE_PK, id2, alice, "temp2", deadline);
        book.bind(id2, alice, "temp2", deadline, sig2);
        assertEq(book.resolve(id2), alice);
    }

    function testSignatureDoesNotCarryToAnotherChainOrContract() public {
        string memory handle = "crosschain";
        bytes32 id = book.idOfHandle(handle);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ALICE_PK, id, alice, handle, deadline);

        AgentIDBook other = new AgentIDBook();
        bytes32 otherDigest = other.bindDigest(id, alice, handle, deadline);
        assertTrue(otherDigest != book.bindDigest(id, alice, handle, deadline));

        vm.expectRevert();
        other.bind(id, alice, handle, deadline, sig);
    }
}