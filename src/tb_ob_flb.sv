`timescale 1ns/1ps
import ob_pkg::*;
module tb_ob_flb;

    logic i_clk;
    logic i_rst_n;
    logic [QUANTITY_LEN-1:0] i_quantity;
    logic [1:0] i_action;
    logic i_valid;
    logic [PRICE_LEN-1:0] i_price;
    

    ob_flb dut(
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),
        .i_quantity(i_quantity),
        .i_action(i_action),
        .i_valid(i_valid),
        .i_price(i_price),
        .i_side(1'b1),
        .o_valid(),
        .o_action(),
        .o_current_price(),
        .o_current_quant(),
        .o_best_price(),
        .o_best_price_quant(),
        .o_total_quant()
    );



    // Clock
    initial begin
        i_clk = 0;
        forever #5 i_clk = ~i_clk;
    end

    // Task: send operation in one cycle
    task automatic send_op(
        input logic [1:0]              action,
        input logic [QUANTITY_LEN-1:0] quantity,
        input logic [PRICE_LEN-1:0]    price
    );
    begin
        @(posedge i_clk);
        i_quantity <= quantity;
        i_action   <= action;
        i_price    <= price;
        i_valid    <= 1;
    end
    endtask


    initial begin
        // init
        i_rst_n    = 0;
        i_valid    = 0;
        i_quantity = 0;
        i_action   = 0;
        i_price    = 0;

        repeat(5) @(posedge i_clk);
        i_rst_n = 1;

        // send operations every cycle

        send_op(ADD, 10, 100);

        send_op(ADD, 100, 100);
        send_op(CANCEL, 30, 100);
        send_op(EXECUTE, 10, 100);
        send_op(ADD, 20, 100);
        @(posedge i_clk) i_valid = 0;

        repeat(10) @(posedge i_clk);

        $finish;
    end

endmodule