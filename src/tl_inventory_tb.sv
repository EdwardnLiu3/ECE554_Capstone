`timescale 1ns/1ps

module tb_inventory;

    logic        clk;
    logic        rst_n;
    logic        buy_valid;
    logic        sell_valid;
    logic [15:0] qty;
    logic signed [15:0] q;

    int pass_count;
    int fail_count;

    inventory dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .buy_valid  (buy_valid),
        .sell_valid (sell_valid),
        .qty        (qty),
        .q          (q)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task automatic do_buy(input logic [15:0] amount);
        @(negedge clk);
        buy_valid  = 1;
        sell_valid = 0;
        qty = amount;
        @(negedge clk);
        buy_valid = 0;
    endtask

    task automatic do_sell(input logic [15:0] amount);
        @(negedge clk);
        sell_valid = 1;
        buy_valid  = 0;
        qty = amount;
        @(negedge clk);
        sell_valid = 0;
    endtask

    task automatic check_q(input logic signed [15:0] expected, input string label);
        @(negedge clk);
        if (q === expected) begin
            $display("  PASS: %s — q=%0d", label, q);
            pass_count++;
        end else begin
            $display("  FAIL: %s — expected=%0d  got=%0d", label, expected, q);
            fail_count++;
        end
    endtask

    task automatic do_reset();
        rst_n = 0;
        buy_valid = 0;
        sell_valid = 0;
        qty = 0;
        repeat(2) @(negedge clk);
        rst_n = 1;
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;

        // TEST 1: Reset
        $display("\n--- Test 1: Reset ---");
        do_reset();
        check_q(0, "q=0 after reset");

        // TEST 2: Buy and sell
        $display("\n--- Test 2: Buy and sell ---");
        do_buy(16'd10);
        check_q(16'sd10, "buy 10 and q=10");
        do_sell(16'd4);
        check_q(16'sd6, "sell 4 and q=6");

        // TEST 3: Going negative
        $display("\n--- Test 3: Short position ---");
        do_sell(16'd20);
        check_q(-16'sd14, "sell 20 and q=-14");

    end

endmodule
