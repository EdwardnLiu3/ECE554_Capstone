`timescale 1ns/1ps
import ob_pkg::*;
module tb_orderbook();
    logic                           i_clk;
    logic                           i_rst_n;
    logic [ORDERID_LEN-1:0]         i_order_id;
    logic                           i_side;
    logic [PRICE_LEN-1:0]           i_price;
    logic [QUANTITY_LEN-1:0]        i_quantity;
    logic [1:0]                     i_action;
    logic                           i_valid;
    logic [PRICE_LEN-1:0]          o_bid_best_price;
    logic [TOT_QUATITY_LEN-1:0]    o_bid_best_quant;
    logic [PRICE_LEN-1:0]          o_ask_best_price;
    logic [TOT_QUATITY_LEN-1:0]    o_ask_best_quant;
    logic                          o_bid_best_valid;
    logic                          o_ask_best_valid;
    logic [1:0]                    o_action;
    logic [PRICE_LEN-1:0]          o_price;
    logic [QUANTITY_LEN-1:0]       o_quantity;
    logic                          o_valid;
    logic                          o_side;

    orderbook #(.BASE_PRICE(22000)) iDUT(
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),
        .i_order_id(i_order_id),
        .i_side(i_side),
        .i_price(i_price),
        .i_quantity(i_quantity),
        .i_action(i_action),
        .i_valid(i_valid),
        .o_bid_best_price(o_bid_best_price),
        .o_bid_best_quant(o_bid_best_quant),
        .o_ask_best_price(o_ask_best_price),
        .o_ask_best_quant(o_ask_best_quant),
        .o_bid_best_valid(o_bid_best_valid),
        .o_ask_best_valid(o_ask_best_valid),
        .o_action(o_action),
        .o_price(o_price),
        .o_quantity(o_quantity),
        .o_valid(o_valid),
        .o_side(o_side)
    );

    // Clock
    initial begin
        i_clk = 0;
        forever #5 i_clk = ~i_clk;
    end

    // Task: send operation in one cycle
    task automatic send_op(
        input logic                    side,
        input logic [ORDERID_LEN-1:0]  order_id,
        input logic [1:0]              action,
        input logic [PRICE_LEN-1:0]    price,
        input logic [QUANTITY_LEN-1:0] quantity
    );
    begin
        @(posedge i_clk);
        i_side     <= side;
        i_order_id <= order_id;
        i_action   <= action;
        i_price    <= price;
        i_quantity <= quantity;
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

        send_op(BID, 0, ADD, 22382, 21); 
        send_op(BID, 0, EXECUTE, 22382, 21); 
        send_op(ASK, 1, ADD, 22399, 100);
        send_op(ASK, 1, EXECUTE, 22399, 90);
        send_op(ASK, 2, ADD, 22399, 50);

        send_op(ASK, 1, EXECUTE, 22399, 10);
        send_op(ASK, 2, EXECUTE, 22399, 50);
        send_op(ASK, 3, ADD, 22400, 100);
        send_op(ASK, 3, EXECUTE, 22400, 100);
        send_op(ASK, 4, ADD, 22400, 100);
        
        send_op(ASK, 4, EXECUTE, 22400, 100);
        send_op(ASK, 5, ADD, 22400, 100);
        send_op(ASK, 6, ADD, 22395, 100);
        send_op(ASK, 6, EXECUTE, 22395, 100);
        send_op(ASK, 7, ADD, 22395, 75);
        send_op(ASK, 7, ADD, 22386, 100);
        @(posedge i_clk) i_valid = 0;
        repeat(30) @(posedge i_clk);
        $stop;

    end


endmodule