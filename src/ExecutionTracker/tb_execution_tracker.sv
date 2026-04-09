`timescale 1ns/1ps
// Simple testbench for verifying the execution tracker module.
// This checks reset, enter payload handling, fills on crossing trades,
// no fills on non-crossing trades, and replace behavior.
module tb_execution_trackers;

    localparam int ORDER_ID_LEN = 32;
    localparam int PRICE_LEN = 32;
    localparam int QUANTITY_LEN = 16;
    localparam int MARKET_QUANTITY_LEN = 32;
    logic clk;
    logic rst_n;
    logic order_valid;
    logic [ORDER_ID_LEN-1:0] order_id_buy;
    logic market_exec_valid;
    logic market_exec_side;
    logic [PRICE_LEN-1:0] market_exec_price;
    logic [MARKET_QUANTITY_LEN-1:0] market_exec_quantity;
    logic exec_valid;
    logic exec_side;
    logic [PRICE_LEN-1:0] exec_price;
    logic [QUANTITY_LEN-1:0] exec_quantity;
    logic [ORDER_ID_LEN-1:0] exec_order_id;
    logic live_bid_active;
    logic live_ask_active;
    logic [ORDER_ID_LEN-1:0] live_bid_order_id;
    logic [ORDER_ID_LEN-1:0] live_ask_order_id;
    logic [ORDER_ID_LEN-1:0] order_id_sell;
    logic [PRICE_LEN-1:0] order_price_buy;
    logic [PRICE_LEN-1:0] order_price_sell;
    logic [QUANTITY_LEN-1:0] order_quantity_buy;
    logic [QUANTITY_LEN-1:0] order_quantity_sell;

    execution_trackers #(
        .ORDER_ID_LEN(ORDER_ID_LEN),
        .PRICE_LEN(PRICE_LEN),
        .QUANTITY_LEN(QUANTITY_LEN),
        .MARKET_QUANTITY_LEN(MARKET_QUANTITY_LEN)
    ) idut (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_order_valid(order_valid),
        .i_order_id_buy(order_id_buy),
        .i_order_id_sell(order_id_sell),
        .i_order_price_buy(order_price_buy),
        .i_order_price_sell(order_price_sell),
        .i_order_quantity_buy(order_quantity_buy),
        .i_order_quantity_sell(order_quantity_sell),
        .i_market_exec_valid(market_exec_valid),
        .i_market_exec_side(market_exec_side),
        .i_market_exec_price(market_exec_price),
        .i_market_exec_quantity(market_exec_quantity),
        .o_exec_valid(exec_valid),
        .o_exec_side(exec_side),
        .o_exec_price(exec_price),
        .o_exec_quantity(exec_quantity),
        .o_exec_order_id(exec_order_id),
        .o_live_bid_active(live_bid_active),
        .o_live_ask_active(live_ask_active),
        .o_live_bid_order_id(live_bid_order_id),
        .o_live_ask_order_id(live_ask_order_id)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // reset stuff
    task automatic clear_inputs;
        begin
            order_valid         = 1'b0;
            order_id_buy        = '0;
            order_id_sell       = '0;
            order_price_buy     = '0;
            order_price_sell    = '0;
            order_quantity_buy  = '0;
            order_quantity_sell = '0;
            market_exec_valid    = 1'b0;
            market_exec_side     = 1'b0;
            market_exec_price    = '0;
            market_exec_quantity = '0;
        end
    endtask

    // order update task that sends an enter payload with given bid and ask details, then clears it on the next cycle
    task automatic send_order_update(
        input [ORDER_ID_LEN-1:0] bid_id,
        input [PRICE_LEN-1:0] bid_price,
        input [QUANTITY_LEN-1:0] bid_qty,
        input [ORDER_ID_LEN-1:0] ask_id,
        input [PRICE_LEN-1:0] ask_price,
        input [QUANTITY_LEN-1:0] ask_qty
    );
        begin
            @(negedge clk);
            order_valid         = 1'b1;
            order_id_buy        = bid_id;
            order_id_sell       = ask_id;
            order_price_buy     = bid_price;
            order_price_sell    = ask_price;
            order_quantity_buy  = bid_qty;
            order_quantity_sell = ask_qty;
            @(posedge clk);
            #1;
            @(negedge clk);
            order_valid         = 1'b0;
            order_id_buy        = '0;
            order_id_sell       = '0;
            order_price_buy     = '0;
            order_price_sell    = '0;
            order_quantity_buy  = '0;
            order_quantity_sell = '0;
        end
    endtask

    // Send a direct market execution event from the order-book side.
    task automatic send_market_trade(
        input bit side,
        input [PRICE_LEN-1:0] price,
        input [MARKET_QUANTITY_LEN-1:0] quantity
    );
        begin
            @(negedge clk);
            market_exec_valid    = 1'b1;
            market_exec_side     = side;
            market_exec_price    = price;
            market_exec_quantity = quantity;
            @(posedge clk);
            #1;
            @(negedge clk);
            market_exec_valid    = 1'b0;
            market_exec_side     = 1'b0;
            market_exec_price    = '0;
            market_exec_quantity = '0;
        end
    endtask

    initial begin
        rst_n = 1'b1;
        clear_inputs();
        // Test 1: Reset should clear fill outputs and live quote totals.
        $display("Test 1: reset behavior");
        @(negedge clk);
        rst_n = 1'b0;
        clear_inputs();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (exec_valid !== 1'b0)       $fatal(1, "Test 1 failed: reset should clear exec_valid");
        if (live_bid_active !== 1'b0)  $fatal(1, "Test 1 failed: reset should clear live bid state");
        if (live_ask_active !== 1'b0)  $fatal(1, "Test 1 failed: reset should clear live ask state");
        $display("PASS");
        // Test 2: Enter payload should add one live bid and one live ask.
        $display("Test 2: enter payload adds live quotes");
        send_order_update(32'd10, 32'd100, 16'd50,
                          32'd11, 32'd110, 16'd40);
        if (live_bid_active !== 1'b1)         $fatal(1, "Test 2 failed: bid should be active");
        if (live_bid_order_id !== 32'd10)     $fatal(1, "Test 2 failed: bid order id wrong");
        if (live_ask_active !== 1'b1)         $fatal(1, "Test 2 failed: ask should be active");
        if (live_ask_order_id !== 32'd11)     $fatal(1, "Test 2 failed: ask order id wrong");
        $display("PASS");

        // Test 3: Sell trade that crosses our bid should fill our bid.
        // Bid at 100 gets hit by market sell at 99.
        $display("Test 3: crossing sell trade fills our bid");
        send_market_trade(1'b1, 32'd99, 32'd20);
        if (exec_valid !== 1'b1)          $fatal(1, "Test 3 failed: crossing sell should raise exec_valid");
        if (exec_side !== 1'b0)           $fatal(1, "Test 3 failed: crossing sell should fill bid side");
        if (exec_price !== 32'd100)       $fatal(1, "Test 3 failed: crossing sell fill price wrong");
        if (exec_quantity !== 16'd20)     $fatal(1, "Test 3 failed: crossing sell fill quantity wrong");
        if (exec_order_id !== 32'd10)     $fatal(1, "Test 3 failed: crossing sell order id wrong");
        if (live_bid_active !== 1'b1)     $fatal(1, "Test 3 failed: partial bid fill should keep bid active");
        if (live_bid_order_id !== 32'd10) $fatal(1, "Test 3 failed: partial bid fill should keep same bid id");
        $display("PASS");



        // Test 4: Buy trade that crosses our ask should fill our ask.
        // Ask at 110 gets lifted by market buy at 111.
        $display("Test 4: crossing buy trade fills our ask");
        send_market_trade(1'b0, 32'd111, 32'd15);
        if (exec_valid !== 1'b1)          $fatal(1, "Test 4 failed: crossing buy should raise exec_valid");
        if (exec_side !== 1'b1)           $fatal(1, "Test 4 failed: crossing buy should fill ask side");
        if (exec_price !== 32'd110)       $fatal(1, "Test 4 failed: crossing buy fill price wrong");
        if (exec_quantity !== 16'd15)     $fatal(1, "Test 4 failed: crossing buy fill quantity wrong");
        if (exec_order_id !== 32'd11)     $fatal(1, "Test 4 failed: crossing buy order id wrong");
        if (live_ask_active !== 1'b1)     $fatal(1, "Test 4 failed: partial ask fill should keep ask active");
        if (live_ask_order_id !== 32'd11) $fatal(1, "Test 4 failed: partial ask fill should keep same ask id");
        $display("PASS");

        // Test 5: Reset again, then non-crossing trades should not fill.
        $display("Test 5: non-crossing trades do not fill");
        @(negedge clk);
        rst_n = 1'b0;
        clear_inputs();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        send_order_update(32'd20, 32'd100, 16'd50,
                          32'd21, 32'd110, 16'd40);

        send_market_trade(1'b1, 32'd101, 32'd10);
        if (exec_valid !== 1'b0)          $fatal(1, "Test 5 failed: sell above our bid should not fill");
        if (live_bid_active !== 1'b1)     $fatal(1, "Test 5 failed: non-crossing sell should keep bid active");
        if (live_bid_order_id !== 32'd20) $fatal(1, "Test 5 failed: non-crossing sell should keep same bid id");
        send_market_trade(1'b0, 32'd109, 32'd10);
        if (exec_valid !== 1'b0)          $fatal(1, "Test 5 failed: buy below our ask should not fill");
        if (live_ask_active !== 1'b1)     $fatal(1, "Test 5 failed: non-crossing buy should keep ask active");
        if (live_ask_order_id !== 32'd21) $fatal(1, "Test 5 failed: non-crossing buy should keep same ask id");
        $display("PASS");

        // Test 6: Replace payload should remove old quote behavior and
        // only use the replacement prices and ids.
        $display("Test 6: replace payload updates live quotes correctly");
        send_order_update(32'd30, 32'd98, 16'd50,
                          32'd31, 32'd112, 16'd40);
        if (live_bid_active !== 1'b1)     $fatal(1, "Test 6 failed: replacement bid should be active");
        if (live_bid_order_id !== 32'd30) $fatal(1, "Test 6 failed: replacement bid id wrong");
        if (live_ask_active !== 1'b1)     $fatal(1, "Test 6 failed: replacement ask should be active");
        if (live_ask_order_id !== 32'd31) $fatal(1, "Test 6 failed: replacement ask id wrong");

        // Old bid was 100, new bid is 98. A sell at 99 should not fill now.
        send_market_trade(1'b1, 32'd99, 32'd10);
        if (exec_valid !== 1'b0)          $fatal(1, "Test 6 failed: sell crossing old bid but not new bid should not fill");
        // Sell at 98 should now fill the replacement bid.
        send_market_trade(1'b1, 32'd98, 32'd10);
        if (exec_valid !== 1'b1)          $fatal(1, "Test 6 failed: replacement bid cross should raise exec_valid");
        if (exec_side !== 1'b0)           $fatal(1, "Test 6 failed: replacement bid fill side wrong");
        if (exec_price !== 32'd98)        $fatal(1, "Test 6 failed: replacement bid fill price wrong");
        if (exec_quantity !== 16'd10)     $fatal(1, "Test 6 failed: replacement bid fill quantity wrong");
        if (exec_order_id !== 32'd30)     $fatal(1, "Test 6 failed: replacement bid fill order id wrong");
        if (live_bid_active !== 1'b1)     $fatal(1, "Test 6 failed: partial replacement bid fill should keep bid active");
        if (live_bid_order_id !== 32'd30) $fatal(1, "Test 6 failed: partial replacement bid fill should keep same bid id");
        // Old ask was 110, new ask is 112. A buy at 111 should not fill now.
        send_market_trade(1'b0, 32'd111, 32'd10);
        if (exec_valid !== 1'b0)          $fatal(1, "Test 6 failed: buy crossing old ask but not new ask should not fill");
        // Buy at 112 should now fill the replacement ask.
        send_market_trade(1'b0, 32'd112, 32'd10);
        if (exec_valid !== 1'b1)          $fatal(1, "Test 6 failed: replacement ask cross should raise exec_valid");
        if (exec_side !== 1'b1)           $fatal(1, "Test 6 failed: replacement ask fill side wrong");
        if (exec_price !== 32'd112)       $fatal(1, "Test 6 failed: replacement ask fill price wrong");
        if (exec_quantity !== 16'd10)     $fatal(1, "Test 6 failed: replacement ask fill quantity wrong");
        if (exec_order_id !== 32'd31)     $fatal(1, "Test 6 failed: replacement ask fill order id wrong");
        if (live_ask_active !== 1'b1)     $fatal(1, "Test 6 failed: partial replacement ask fill should keep ask active");
        if (live_ask_order_id !== 32'd31) $fatal(1, "Test 6 failed: partial replacement ask fill should keep same ask id");
        $display("PASS");

        // Test 7: Another direct sell execution should still keep the
        // remaining bid quote live after a partial fill.
        $display("Test 7: direct market execution keeps remaining bid quote live");
        @(negedge clk);
        rst_n = 1'b0;
        clear_inputs();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        send_order_update(32'd40, 32'd103, 16'd30,
                          32'd41, 32'd115, 16'd20);
        send_market_trade(1'b1, 32'd103, 32'd15);

        if (exec_valid !== 1'b1)          $fatal(1, "Test 7 failed: direct market execute should raise exec_valid");
        if (exec_side !== 1'b0)           $fatal(1, "Test 7 failed: direct market execute should fill bid side");
        if (exec_price !== 32'd103)       $fatal(1, "Test 7 failed: direct market execute should use our bid price");
        if (exec_quantity !== 16'd15)     $fatal(1, "Test 7 failed: direct market execute quantity wrong");
        if (exec_order_id !== 32'd40)     $fatal(1, "Test 7 failed: direct market execute quote id wrong");
        if (live_bid_active !== 1'b1)     $fatal(1, "Test 7 failed: direct market execute should keep remaining bid active");
        if (live_bid_order_id !== 32'd40) $fatal(1, "Test 7 failed: direct market execute should keep same bid id");
        $display("PASS");

        $display("");
        $display("YAHOO ALL TESTS PASSED");
        $finish;
    end

endmodule
