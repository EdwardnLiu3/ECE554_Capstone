`timescale 1ns/1ps
// Simple testbench for verifying the execution tracker module.
// This now checks the 10 deep fifo behavior on both sides.
module tb_execution_trackers;

    localparam int ORDER_ID_LEN = 32;
    localparam int PRICE_LEN = 32;
    localparam int QUANTITY_LEN = 16;
    localparam int MARKET_QUANTITY_LEN = 32;
    localparam int FIFO_DEPTH = 10;
    logic clk;
    logic rst_n;
    logic order_valid;
    logic [ORDER_ID_LEN-1:0] order_id_buy;
    logic [ORDER_ID_LEN-1:0] order_id_sell;
    logic [PRICE_LEN-1:0] order_price_buy;
    logic [PRICE_LEN-1:0] order_price_sell;
    logic [QUANTITY_LEN-1:0] order_quantity_buy;
    logic [QUANTITY_LEN-1:0] order_quantity_sell;
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
    logic [QUANTITY_LEN-1:0] live_bid_qty;
    logic [QUANTITY_LEN-1:0] live_ask_qty;

    execution_trackers #(
        .ORDER_ID_LEN(ORDER_ID_LEN),
        .PRICE_LEN(PRICE_LEN),
        .QUANTITY_LEN(QUANTITY_LEN),
        .MARKET_QUANTITY_LEN(MARKET_QUANTITY_LEN),
        .FIFO_DEPTH(FIFO_DEPTH)
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
        .o_live_ask_order_id(live_ask_order_id),
        .o_live_bid_qty(live_bid_qty),
        .o_live_ask_qty(live_ask_qty)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

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
        integer i;
        rst_n = 1'b1;
        clear_inputs();

        $display("Test 1: reset behavior");
        @(negedge clk);
        rst_n = 1'b0;
        clear_inputs();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (exec_valid !== 1'b0)         $fatal(1, "Test 1 failed: reset should clear exec_valid");
        if (live_bid_qty !== 16'd0)      $fatal(1, "Test 1 failed: reset should clear bid total");
        if (live_ask_qty !== 16'd0)      $fatal(1, "Test 1 failed: reset should clear ask total");
        if (live_bid_active !== 1'b0)    $fatal(1, "Test 1 failed: reset should clear bid replace active");
        if (live_ask_active !== 1'b0)    $fatal(1, "Test 1 failed: reset should clear ask replace active");
        $display("PASS");

        $display("Test 2: first quote update adds first fifo entry");
        send_order_update(32'd10, 32'd100, 16'd10,
                          32'd11, 32'd110, 16'd10);
        if (live_bid_qty !== 16'd10)         $fatal(1, "Test 2 failed: first bid total wrong");
        if (live_ask_qty !== 16'd10)         $fatal(1, "Test 2 failed: first ask total wrong");
        if (live_bid_active !== 1'b0)        $fatal(1, "Test 2 failed: fifo not full yet on bid");
        if (live_ask_active !== 1'b0)        $fatal(1, "Test 2 failed: fifo not full yet on ask");
        if (live_bid_order_id !== 32'd10)    $fatal(1, "Test 2 failed: oldest bid id wrong");
        if (live_ask_order_id !== 32'd11)    $fatal(1, "Test 2 failed: oldest ask id wrong");
        $display("PASS");

        $display("Test 3: tenth quote update fills fifo and oldest quote is ready to replace");
        for (i = 2; i <= FIFO_DEPTH; i = i + 1) begin
            send_order_update(ORDER_ID_LEN'(i*10), PRICE_LEN'(101 - i), 16'd10,
                              ORDER_ID_LEN'(i*10 + 1), PRICE_LEN'(109 + i), 16'd10);
        end
        if (live_bid_qty !== 16'd100)        $fatal(1, "Test 3 failed: bid total after ten quotes wrong");
        if (live_ask_qty !== 16'd100)        $fatal(1, "Test 3 failed: ask total after ten quotes wrong");
        if (live_bid_active !== 1'b1)        $fatal(1, "Test 3 failed: bid fifo should now be full");
        if (live_ask_active !== 1'b1)        $fatal(1, "Test 3 failed: ask fifo should now be full");
        if (live_bid_order_id !== 32'd10)    $fatal(1, "Test 3 failed: oldest bid id should still be first quote");
        if (live_ask_order_id !== 32'd11)    $fatal(1, "Test 3 failed: oldest ask id should still be first quote");
        $display("PASS");

        $display("Test 4: oldest bid is checked first and partial fill keeps it at head");
        send_market_trade(1'b1, 32'd100, 32'd4);
        if (exec_valid !== 1'b1)             $fatal(1, "Test 4 failed: crossing sell should raise exec_valid");
        if (exec_side !== 1'b0)              $fatal(1, "Test 4 failed: should fill bid side");
        if (exec_price !== 32'd100)          $fatal(1, "Test 4 failed: should fill oldest bid price first");
        if (exec_quantity !== 16'd4)         $fatal(1, "Test 4 failed: partial fill quantity wrong");
        if (exec_order_id !== 32'd10)        $fatal(1, "Test 4 failed: should fill oldest bid id first");
        if (live_bid_qty !== 16'd96)         $fatal(1, "Test 4 failed: bid total after partial fill wrong");
        if (live_bid_order_id !== 32'd10)    $fatal(1, "Test 4 failed: partial fill should keep same oldest bid id");
        if (live_bid_active !== 1'b1)        $fatal(1, "Test 4 failed: bid fifo is still full after partial fill");
        $display("PASS");

        $display("Test 5: full fill removes oldest bid and next quote becomes head");
        send_market_trade(1'b1, 32'd100, 32'd6);
        if (exec_valid !== 1'b1)             $fatal(1, "Test 5 failed: full fill should raise exec_valid");
        if (exec_order_id !== 32'd10)        $fatal(1, "Test 5 failed: should still fill oldest bid id");
        if (exec_quantity !== 16'd6)         $fatal(1, "Test 5 failed: full fill quantity wrong");
        if (live_bid_qty !== 16'd90)         $fatal(1, "Test 5 failed: bid total after full fill wrong");
        if (live_bid_order_id !== 32'd20)    $fatal(1, "Test 5 failed: next oldest bid should become head");
        if (live_bid_active !== 1'b0)        $fatal(1, "Test 5 failed: bid fifo now has nine quotes so replace should not be active");
        $display("PASS");

        $display("Test 6: new quote appends when fifo has room and replaces oldest when full");
        send_order_update(32'd110, 32'd90, 16'd10,
                          32'd111, 32'd120, 16'd10);
        if (live_bid_qty !== 16'd100)        $fatal(1, "Test 6 failed: bid total after append wrong");
        if (live_ask_qty !== 16'd100)        $fatal(1, "Test 6 failed: ask total after replace wrong");
        if (live_bid_order_id !== 32'd20)    $fatal(1, "Test 6 failed: bid head should stay on old second quote");
        if (live_ask_order_id !== 32'd21)    $fatal(1, "Test 6 failed: ask head should move after replace");
        if (live_bid_active !== 1'b1)        $fatal(1, "Test 6 failed: bid fifo should be full again");
        if (live_ask_active !== 1'b1)        $fatal(1, "Test 6 failed: ask fifo should stay full");
        $display("PASS");

        $display("Test 7: same-cycle fill happens before fifo update");
        @(negedge clk);
        order_valid         = 1'b1;
        order_id_buy        = 32'd120;
        order_id_sell       = 32'd121;
        order_price_buy     = 32'd89;
        order_price_sell    = 32'd121;
        order_quantity_buy  = 16'd10;
        order_quantity_sell = 16'd10;
        market_exec_valid    = 1'b1;
        market_exec_side     = 1'b1;
        market_exec_price    = 32'd99;
        market_exec_quantity = 32'd10;
        @(posedge clk);
        #1;
        if (exec_valid !== 1'b1)             $fatal(1, "Test 7 failed: same-cycle fill should raise exec_valid");
        if (exec_order_id !== 32'd20)        $fatal(1, "Test 7 failed: same-cycle fill should use old head bid id");
        if (exec_price !== 32'd99)           $fatal(1, "Test 7 failed: same-cycle fill should use old head bid price");
        if (live_bid_order_id !== 32'd30)    $fatal(1, "Test 7 failed: next oldest bid should become head after fill and replace");
        if (live_bid_qty !== 16'd100)        $fatal(1, "Test 7 failed: bid total should stay full after same-cycle fill and append");
        @(negedge clk);
        clear_inputs();
        $display("PASS");

        $display("");
        $display("YAHOO ALL TESTS PASSED");
        $finish;
    end

endmodule
