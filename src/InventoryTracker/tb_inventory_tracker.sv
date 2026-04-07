`timescale 1ns/1ps
// Simple testbench for verifying the inventory tracker module. 
// This verifies that the inventory tracker correctly updates position and P/L based on incoming execution reports, and that it initializes correctly on reset.
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
    ) dut (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_exec_valid(exec_valid),
        .i_exec_side(exec_side),
        .i_exec_price(exec_price),
        .i_exec_quantity(exec_quantity),
        .o_position(position),
        .o_day_pnl(day_pnl)
    );

    // Simple free-running clock.
    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic check(
        input bit condition,
        input string message
    );
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("PASS: %s", message);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %s", message);
            end
        end
    endtask

    task automatic clear_exec;
        begin
            exec_valid = 1'b0;
            exec_side = 1'b0;
            exec_price = '0;
            exec_quantity = '0;
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            clear_exec();

            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;

            check(position == 16'sd100, "reset loads starting position");
            check(day_pnl == 64'sd0, "reset clears day pnl");
        end
    endtask

    task automatic send_fill(
        input logic side,
        input logic [PRICE_LEN-1:0] price,
        input logic [QUANTITY_LEN-1:0] quantity
    );
        begin
            @(negedge clk);
            exec_valid = 1'b1;
            exec_side = side;
            exec_price = price;
            exec_quantity = quantity;

            @(posedge clk);
            #1;

            @(negedge clk);
            clear_exec();
        end
    endtask

    task automatic expect_state(
        input logic signed [POSITION_LEN-1:0] expected_position,
        input logic signed [PNL_LEN-1:0] expected_pnl,
        input string label
    );
        begin
            check(position == expected_position, {label, " position matches"});
            check(day_pnl == expected_pnl, {label, " pnl matches"});
        end
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;
        rst_n = 1'b1;
        clear_exec();

        reset_dut();

        // Buy 10 shares at $5.00. Position increases, cash P/L decreases $50.00.
        send_fill(1'b0, 32'd500, 16'd10);
        expect_state(16'sd110, -64'sd5000, "after buy fill");

        // Sell 20 shares at $6.00. Position decreases, cash P/L increases $120.00.
        send_fill(1'b1, 32'd600, 16'd20);
        expect_state(16'sd90, 64'sd7000, "after sell fill");

        // Invalid/no-fill cycle should not change anything.
        repeat (2) @(posedge clk);
        #1;
        expect_state(16'sd90, 64'sd7000, "after idle cycles");

        // Sell enough to go short. This is allowed; risk manager can limit it.
        send_fill(1'b1, 32'd700, 16'd100);
        expect_state(-16'sd10, 64'sd77000, "after sell into short position");

        // Buy 5 shares at $6.50. Position moves back toward flat.
        send_fill(1'b0, 32'd650, 16'd5);
        expect_state(-16'sd5, 64'sd73750, "after buy while short");

        $display("");
        $display("============================================================");
        $display("Inventory tracker test summary");
        $display("  PASS = %0d", pass_count);
        $display("  FAIL = %0d", fail_count);
        $display("============================================================");

        if (fail_count == 0) begin
            $display("All inventory-tracker checks passed.");
        end else begin
            $fatal(1, "Inventory-tracker testbench failed with %0d failing checks.", fail_count);
        end

        $finish;
    end

endmodule
