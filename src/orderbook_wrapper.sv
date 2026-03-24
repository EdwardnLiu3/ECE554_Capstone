////////////////////////////////////////////////////
// 
// This module get the information from parsing
// module and output the current state of the stock
//
////////////////////////////////////////////////////
import ob_pkg::*;
module orderbook_wrapper(
    input                           i_clk,
    input                           i_rst_n,
    input [ORDERID_LEN-1:0]         i_order_id,
    input                           i_side,
    input [PRICE_LEN-1:0]           i_price,
    input [QUANTITY_LEN-1:0]        i_quantity,
    input [1:0]                     i_action,
    input                           i_valid,
    output [PRICE_LEN-1:0]          o_bid_best_price,
    output [TOT_QUATITY_LEN-1:0]    o_total_bid,
    output [PRICE_LEN-1:0]          o_ask_best_price,
    output [TOT_QUATITY_LEN-1:0]    o_total_ask
);

logic bid_side, ask_side;
logic [1:0] p_action_bid, p_action_ask;
logic [PRICE_LEN-1 : 0] p_price_bid, p_price_ask;
logic [QUANTITY_LEN-1:0] p_quantity_bid, p_quantity_ask;
logic p_valid_bid, p_valid_ask;

assign bid_side = i_side == 0;
assign ask_side = i_side == 1;

// this module track the price and quantity of every existing orderid
ob_opb bid_opb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_action(add),
    .i_valid(i_valid && bid_side),
    .i_price(i_price),
    .o_action(p_action_bid),
    .o_price(p_price_bid),
    .o_valid(p_valid_bid),
    .o_quantity(p_quantity_bid)
); 

ob_opb ask_opb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_action(add),
    .i_valid(i_valid && ask_side),
    .i_price(i_price),
    .o_action(p_action_ask),
    .o_price(p_price_ask),
    .o_valid(p_valid_ask),
    .o_quantity(p_quantity_ask)
); 

// this module track the quantity of each price
ob_flb bid_flb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_price(p_price_bid),
    .i_quantity(p_quantity_bid),
    .i_action(p_action_bid),
    .i_valid(p_valid_bid),
    .i_side(1'b1),
    .o_valid(),
    .o_action(),
    .o_current_price(),
    .o_current_quant(),
    .o_best_price(),
    .o_best_price_quant(),
    .o_total_quant()
);

ob_flb ask_flb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_price(p_price_ask),
    .i_quantity(p_quantity_ask),
    .i_action(p_action_ask),
    .i_valid(p_valid_ask),
    .i_side(1'b0),
    .o_valid(),
    .o_action(),
    .o_current_price(),
    .o_current_quant(),
    .o_best_price(),
    .o_best_price_quant(),
    .o_total_quant()
);

endmodule
