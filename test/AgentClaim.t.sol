// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentIDBook} from "../src/AgentIDBook.sol";
import {AgentClaim, IAgentIDBook} from "../src/AgentClaim.sol";

contract AgentClaimTest is Test {
    AgentIDBook book;
    AgentClaim token;

    uint256 constant ALICE_PK = 0xA11CE;
    uint256 constant BOB_PK = 0xB0B;
    address alice;
    address bob;

    function setUp() public {
        book = new AgentIDBook();
        token = new AgentClaim(IAgentIDBook(address(book)));
        alice = vm.addr(ALICE_PK);
        bob = vm.addr(BOB_PK);
    }

    function _bind(uint256 pk, address who, string memory handle) internal {
        bytes32 id = book.idOfHandle(handle);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = book.bindDigest(id, who, handle, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        book.bind(id, who, handle, deadline, abi.encodePacked(r, s, v));
    }

    function testClaimRequiresAnAgentId() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentClaim.NotAnAgent.selector, alice));
        token.claim();
    }

    function testBoundAgentCanClaimOnce() public {
        _bind(ALICE_PK, alice, "alice");

        vm.prank(alice);
        uint256 got = token.claim();
        assertEq(got, token.CLAIM_AMOUNT());
        assertEq(token.balanceOf(alice), 10_000e18);
        assertEq(token.claimedCount(), 1);
        assertTrue(token.hasClaimed(alice));
        assertEq(token.remaining(), token.SUPPLY() - 10_000e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentClaim.AlreadyClaimed.selector, alice));
        token.claim();
    }

    function testClaimIsPerAddressNotPerHandle() public {
        _bind(ALICE_PK, alice, "alice");
        vm.prank(alice);
        token.claim();

        // unbinding and rebinding a new name does not buy a second allocation
        vm.prank(alice);
        book.unbind();
        _bind(ALICE_PK, alice, "alice2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentClaim.AlreadyClaimed.selector, alice));
        token.claim();
    }

    function testUnboundAddressCannotClaim() public {
        _bind(ALICE_PK, alice, "alice");
        vm.prank(alice);
        book.unbind();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentClaim.NotAnAgent.selector, alice));
        token.claim();
    }

    function testTransferAndApprovePath() public {
        _bind(ALICE_PK, alice, "alice");
        vm.prank(alice);
        token.claim();

        vm.prank(alice);
        assertTrue(token.transfer(bob, 4_000e18));
        assertEq(token.balanceOf(bob), 4_000e18);
        assertEq(token.balanceOf(alice), 6_000e18);

        vm.prank(alice);
        token.approve(bob, 1_500e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 1_500e18));
        assertEq(token.balanceOf(bob), 5_500e18);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert(AgentClaim.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1);
    }

    function testTwoAgentsGetTwoAllocations() public {
        _bind(ALICE_PK, alice, "alice");
        _bind(BOB_PK, bob, "bob");

        vm.prank(alice);
        token.claim();
        vm.prank(bob);
        token.claim();

        assertEq(token.claimedCount(), 2);
        assertEq(token.remaining(), token.SUPPLY() - 20_000e18);
    }

    function testCannotConstructWithZeroBook() public {
        vm.expectRevert(AgentClaim.ZeroAddress.selector);
        new AgentClaim(IAgentIDBook(address(0)));
    }
}