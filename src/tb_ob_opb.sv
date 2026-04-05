`timescale 1ns/1ps
import ob_pkg::*;

module tb_ob_opb;

    // Inputs
    logic i_clk;
    logic i_rst_n;
    logic [ORDERID_LEN-1:0]  i_order_id;
    logic [QUANTITY_LEN-1:0] i_quantity;
    logic [1:0]              i_action;
    logic                    i_valid;
    logic [PRICE_LEN-1:0]    i_price;

    // Outputs
    logic                    o_action;
    logic [PRICE_LEN-1:0]    o_price;
    logic                    o_valid;
    logic [QUANTITY_LEN-1:0] o_quantity;

    // DUT
    ob_opb iDUT (
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),
        .i_order_id(i_order_id),
        .i_quantity(i_quantity),
        .i_action(i_action),
        .i_valid(i_valid),
        .i_price(i_price),
        .o_action(o_action),
        .o_price(o_price),
        .o_valid(o_valid),
        .o_quantity(o_quantity)
    );

    // Clock
    initial begin
        i_clk = 0;
        forever #5 i_clk = ~i_clk;
    end

    // Task: send operation in one cycle
    task automatic send_op(
        input logic [ORDERID_LEN-1:0]  order_id,
        input logic [QUANTITY_LEN-1:0] quantity,
        input logic [1:0]              action,
        input logic [PRICE_LEN-1:0]    price
    );
    begin
        @(posedge i_clk);
        i_order_id <= order_id;
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
        i_order_id = 0;
        i_quantity = 0;
        i_action   = 0;
        i_price    = 0;

        repeat(5) @(posedge i_clk);
        i_rst_n = 1;

        // send operations every cycle

        // ADD order 5
        send_op(5, 100, 2'b00, 250);

        // ADD order 6
        send_op(6, 200, 2'b00, 150);

        // EXECUTE order 5
        send_op(5, 99, 2'b10, 0);

        // EXECUTE order 5
        send_op(5, 1, 2'b01, 0);

        // CANCEL order 6
        send_op(6, 50, 2'b01, 0);


        // ADD new order
        send_op(2, 150, 2'b00, 100);
        // DELETE order 5
        send_op(6, 0, 2'b11, 0);

        repeat(10) @(posedge i_clk);

        $finish;
    end

endmodule