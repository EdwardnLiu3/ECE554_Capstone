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
    logic signed [POSITION_LEN-1:0] position;
    logic signed [PNL_LEN-1:0] day_pnl;

    integer pass_count;
    integer fail_count;

    inventory_tracker #(
        .PRICE_LEN(PRICE_LEN),
        .QUANTITY_LEN(QUANTITY_LEN),
        .POSITION_LEN(POSITION_LEN),
        .PNL_LEN(PNL_LEN),
        .STARTING_POSITION(16'sd100)
    ) idut (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_exec_valid(exec_valid),
        .i_exec_side(exec_side),
        .i_exec_price(exec_price),
        .i_exec_quantity(exec_quantity),
        .o_position(position),
        .o_day_pnl(day_pnl)
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
        pass_count = 0;
        fail_count = 0;
        rst_n = 1'b1;
        clear_exec();

        // Test 1: Reset should load starting position and clear day pnl.
        $display("Test 1: reset behavior");
        @(negedge clk);
        rst_n = 1'b0;
        clear_exec();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (position == 16'sd100) begin
            $display("PASS: reset loads starting position");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: reset loads starting position");
            fail_count = fail_count + 1;
        end
        if (day_pnl == 64'sd0) begin
            $display("PASS: reset clears day pnl");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: reset clears day pnl");
            fail_count = fail_count + 1;
        end

        // Test 2: Buy 10 shares at 500 cents.
        // Position should go from 100 to 110.
        // Cash pnl should go from 0 to -5000.
        $display("Test 2: buy fill updates position and pnl");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b0;
        exec_price    = 32'd500;
        exec_quantity = 16'd10;
        @(posedge clk);
        #1;
        if (position == 16'sd110) begin
            $display("PASS: buy fill updates position");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: buy fill updates position");
            fail_count = fail_count + 1;
        end
        if (day_pnl == -64'sd5000) begin
            $display("PASS: buy fill updates pnl");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: buy fill updates pnl");
            fail_count = fail_count + 1;
        end
        @(negedge clk);
        clear_exec();

        // Test 3: Sell 20 shares at 600 cents.
        // Position should go from 110 to 90.
        // Cash pnl should go from -5000 to 7000.
        $display("Test 3: sell fill updates position and pnl");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b1;
        exec_price    = 32'd600;
        exec_quantity = 16'd20;
        @(posedge clk);
        #1;
        if (position == 16'sd90) begin
            $display("PASS: sell fill updates position");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: sell fill updates position");
            fail_count = fail_count + 1;
        end
        if (day_pnl == 64'sd7000) begin
            $display("PASS: sell fill updates pnl");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: sell fill updates pnl");
            fail_count = fail_count + 1;
        end
        @(negedge clk);
        clear_exec();

        // Test 4: No fill for a couple cycles should not change state.
        $display("Test 4: idle cycles do not change state");
        repeat (2) @(posedge clk);
        #1;
        if (position == 16'sd90) begin
            $display("PASS: idle cycles keep position the same");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: idle cycles keep position the same");
            fail_count = fail_count + 1;
        end
        if (day_pnl == 64'sd7000) begin
            $display("PASS: idle cycles keep pnl the same");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: idle cycles keep pnl the same");
            fail_count = fail_count + 1;
        end

        // Test 5: Sell 100 shares at 700 cents.
        // This should move us short from 90 to -10.
        // Cash pnl should increase from 7000 to 77000.
        $display("Test 5: sell fill can move inventory short");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b1;
        exec_price    = 32'd700;
        exec_quantity = 16'd100;
        @(posedge clk);
        #1;
        if (position == -16'sd10) begin
            $display("PASS: sell fill moves position short");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: sell fill moves position short");
            fail_count = fail_count + 1;
        end
        if (day_pnl == 64'sd77000) begin
            $display("PASS: sell fill into short updates pnl");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: sell fill into short updates pnl");
            fail_count = fail_count + 1;
        end
        @(negedge clk);
        clear_exec();

        // Test 6: Buy 5 shares at 650 cents while short.
        // Position should go from -10 to -5.
        // Cash pnl should go from 77000 to 73750.
        $display("Test 6: buy fill while short updates correctly");
        @(negedge clk);
        exec_valid    = 1'b1;
        exec_side     = 1'b0;
        exec_price    = 32'd650;
        exec_quantity = 16'd5;
        @(posedge clk);
        #1;
        if (position == -16'sd5) begin
            $display("PASS: buy while short updates position");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: buy while short updates position");
            fail_count = fail_count + 1;
        end
        if (day_pnl == 64'sd73750) begin
            $display("PASS: buy while short updates pnl");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: buy while short updates pnl");
            fail_count = fail_count + 1;
        end
        @(negedge clk);
        clear_exec();

        // Test 7: Reset again after activity.
        // Should return to starting position and zero pnl.
        $display("Test 7: reset after activity restores initial state");
        @(negedge clk);
        rst_n = 1'b0;
        clear_exec();
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (position == 16'sd100) begin
            $display("PASS: second reset restores starting position");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: second reset restores starting position");
            fail_count = fail_count + 1;
        end
        if (day_pnl == 64'sd0) begin
            $display("PASS: second reset clears day pnl");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: second reset clears day pnl");
            fail_count = fail_count + 1;
        end


        $display("");
        $display("Inventory tracker test summary");
        $display("  PASS = %0d", pass_count);
        $display("  FAIL = %0d", fail_count);
        if (fail_count == 0) begin
            $display("All inventory tracker checks passed.");
        end else begin
            $fatal(1, "Inventory tracker testbench failed with %0d failing checks.", fail_count);
        end
        $finish;
    end

endmodule