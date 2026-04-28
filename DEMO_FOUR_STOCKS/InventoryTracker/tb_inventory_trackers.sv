`timescale 1ns/1ps
// Simple testbench for verifying the inventory tracker module.
// Checks reset, buy fills, sell fills, idle cycles, short positions,
// buying while short, and reset after activity.
module tb_inventory_tracker;

    localparam int PRICE_LEN = 32;
    localparam int QUANTITY_LEN = 16;
    localparam int POSITION_LEN = 16;
    localparam int PNL_LEN = 64;

    logic clk;
    logic rst_n;
    logic exec_valid;
    logic exec_side;
    logic [PRICE_LEN-1:0] exec_price;
    logic [QUANTITY_LEN-1:0] exec_quantity;
    logic [PRICE_LEN-1:0] mark_price;
    logic signed [POSITION_LEN-1:0] position;
    logic signed [PNL_LEN-1:0] day_pnl;
    logic signed [PNL_LEN-1:0] total_pnl;

    inventory_tracker #(
        .PRICE_LEN(PRICE_LEN),
        .QUANTITY_LEN(QUANTITY_LEN),
        .POSITION_LEN(POSITION_LEN),
        .PNL_LEN(PNL_LEN),
        .STARTING_POSITION(16'sd0)
    ) idut (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_exec_valid(exec_valid),
        .i_exec_side(exec_side),
        .i_exec_price(exec_price),
        .i_exec_quantity(exec_quantity),
        .i_mark_price(mark_price),
        .o_position(position),
        .o_day_pnl(day_pnl),
        .o_total_pnl(total_pnl)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic clear_exec;
        begin
            exec_valid    = 1'b0;
            exec_side     = 1'b0;
            exec_price    = '0;
            exec_quantity = '0;
        end
    endtask

    initial begin
        rst_n = 1'b1;
        mark_price = 32'd500;
        clear_exec();

        // test 1
        $display("Test 1: reset behavior");
        @(negedge clk);
        rst_n = 1'b0;
        clear_exec();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (position !== 16'sd0) $fatal(1, "Test 1 failed: reset should load starting position");
        if (day_pnl !== 64'sd0)  $fatal(1, "Test 1 failed: reset should clear day pnl");
        if (total_pnl !== 64'sd0) $fatal(1, "Test 1 failed: reset should clear total pnl");
        $display("PASS");

        //test2
        $display("Test 2: buy fill updates position and pnl");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b0;
        exec_price    = 32'd500;
        exec_quantity = 16'd10;
        mark_price    = 32'd550;
        @(posedge clk);
        #1;
        if (position !== 16'sd10)     $fatal(1, "Test 2 failed: buy fill should update position");
        if (day_pnl !== -64'sd5000)   $fatal(1, "Test 2 failed: buy fill should update pnl");
        if (total_pnl !== 64'sd500)   $fatal(1, "Test 2 failed: buy fill should update marked pnl");
        $display("PASS");
        @(negedge clk);
        clear_exec();

        // Test 3
        $display("Test 3: sell fill updates position and pnl");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b1;
        exec_price    = 32'd600;
        exec_quantity = 16'd20;
        mark_price    = 32'd550;
        @(posedge clk);
        #1;

        if (position !== -16'sd10)    $fatal(1, "Test 3 failed: sell fill should update position");
        if (day_pnl !== 64'sd7000)    $fatal(1, "Test 3 failed: sell fill should update pnl");
        if (total_pnl !== 64'sd1500)  $fatal(1, "Test 3 failed: sell fill should update marked pnl");
        $display("PASS");
        @(negedge clk);
        clear_exec();

        // Test 4
        $display("Test 4: idle cycles do not change state");
        repeat (2) @(posedge clk);
        #1;
        if (position !== -16'sd10)    $fatal(1, "Test 4 failed: idle cycles should keep position the same");
        if (day_pnl !== 64'sd7000)    $fatal(1, "Test 4 failed: idle cycles should keep pnl the same");
        if (total_pnl !== 64'sd1500)  $fatal(1, "Test 4 failed: idle cycles should keep total pnl the same");
        $display("PASS");

        // Test 5
        $display("Test 5: sell fill can move inventory short");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b1;
        exec_price    = 32'd700;
        exec_quantity = 16'd100;
        mark_price    = 32'd650;
        @(posedge clk);
        #1;
        if (position !== -16'sd110)   $fatal(1, "Test 5 failed: sell fill should move position short");
        if (day_pnl !== 64'sd77000)   $fatal(1, "Test 5 failed: sell fill into short should update pnl");
        if (total_pnl !== 64'sd5500)  $fatal(1, "Test 5 failed: marked pnl should include short inventory");
        $display("PASS");
        @(negedge clk);
        clear_exec();

        // Test 6
        $display("Test 6: buy fill while short updates correctly");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b0;
        exec_price    = 32'd650;
        exec_quantity = 16'd5;
        mark_price    = 32'd640;
        @(posedge clk);
        #1;
        if (position !== -16'sd105)   $fatal(1, "Test 6 failed: buy while short should update position");
        if (day_pnl !== 64'sd73750)   $fatal(1, "Test 6 failed: buy while short should update pnl");
        if (total_pnl !== 64'sd6550)  $fatal(1, "Test 6 failed: marked pnl should update with new mark");
        $display("PASS");
        @(negedge clk);
        clear_exec();

        // Test 7
        $display("Test 7: mark price update changes total pnl without a fill");
        @(negedge clk);
        mark_price = 32'd600;
        @(posedge clk);
        #1;
        if (position !== -16'sd105)   $fatal(1, "Test 7 failed: mark-only cycle should not change position");
        if (day_pnl !== 64'sd73750)   $fatal(1, "Test 7 failed: mark-only cycle should not change day pnl");
        if (total_pnl !== 64'sd10750) $fatal(1, "Test 7 failed: mark-only cycle should update total pnl");
        $display("PASS");

        //test 8
        $display("Test 8: reset after activity restores initial state");
        @(negedge clk);
        rst_n = 1'b0;
        clear_exec();
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (position !== 16'sd0) $fatal(1, "Test 8 failed: second reset should restore starting position");
        if (day_pnl !== 64'sd0)  $fatal(1, "Test 8 failed: second reset should clear day pnl");
        if (total_pnl !== 64'sd0) $fatal(1, "Test 8 failed: second reset should clear total pnl");
        $display("PASS");

        $display("");
        $display("YAHOO ALL TESTS PASSED");
        $finish;
    end

endmodule
