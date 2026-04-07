`timescale 1ns/1ps

module tb_inventory;

    logic        clk;
    logic        rst_n;
    logic        buy_valid;
    logic        sell_valid;
    logic [15:0] qty;
    logic signed [15:0] q;

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

    task do_buy(input logic [15:0] amount);
        @(negedge clk);
        buy_valid= 1;
        sell_valid = 0;
        qty = amount;
        @(negedge clk);
        buy_valid = 0;
    endtask

    task do_sell(input logic [15:0] amount);
        @(negedge clk);
        sell_valid = 1;
        buy_valid = 0;
        qty = amount;
        @(negedge clk);
        sell_valid = 0;
    endtask

    task check_q(input logic signed [15:0] expected, input string label);
        @(negedge clk);
        if (q !== expected)
            $display("FAIL [%s]: expected q=%0d, got q=%0d", label, expected, q);
        else
            $display("PASS [%s]: q=%0d", label, q);
    endtask

    initial begin
        buy_valid = 0;
        sell_valid = 0;
        qty = 0;
        rst_n = 0;
        repeat(2) @(negedge clk);
        rst_n = 1;

        check_q(0, "reset");
        do_buy(10);
        check_q(10, "buy 10");
        do_sell(4);
        check_q(6, "sell 4");

        do_sell(20);
        check_q(-14, "sell 20 -> short");

        @(negedge clk);
        buy_valid  = 0;
        sell_valid = 0;
        qty        = 999;
        check_q(-14, "no change when neither valid");

        $display("Testbench complete.");
        $finish;
    end

endmodule