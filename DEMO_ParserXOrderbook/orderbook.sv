////////////////////////////////////////////////////
// 
// This module get the information from parsing
// module and output the current state of the stock
//
////////////////////////////////////////////////////
import ob_pkg::*;
module orderbook(
    input                           i_clk,
    input                           i_rst_n,
    input [ORDERID_LEN-1:0]         i_order_id,
    input                           i_side,
    input [PRICE_LEN-1:0]           i_price,
    input [QUANTITY_LEN-1:0]        i_quantity,
    input [1:0]                     i_action,
    input                           i_valid,
    output [PRICE_LEN-1:0]          o_bid_best_price,
    output [TOT_QUATITY_LEN-1:0]    o_bid_best_quant,
    output [PRICE_LEN-1:0]          o_ask_best_price,
    output [TOT_QUATITY_LEN-1:0]    o_ask_best_quant,
    output                          o_bid_best_valid,
    output                          o_ask_best_valid,
    output [1:0]                    o_action,
    output [PRICE_LEN-1:0]          o_price,
    output [QUANTITY_LEN-1:0]       o_quantity,
    output                          o_valid
);

logic bid_side, ask_side;
logic [1:0] p_action_bid, p_action_ask, o_action_ask, o_action_bid;
logic [PRICE_LEN-1 : 0] p_price_bid, p_price_ask, o_price_ask, o_price_bid;
logic [QUANTITY_LEN-1:0] p_quantity_bid, p_quantity_ask, o_quant_ask, o_quant_bid;
logic p_valid_bid, p_valid_ask, o_valid_ask, o_valid_bid;

assign bid_side = i_side == 0;
assign ask_side = i_side == 1;

// this module track the price and quantity of every existing orderid
ob_opb bid_opb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_action(i_action),
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
    .i_action(i_action),
    .i_valid(i_valid && ask_side),
    .i_price(i_price),
    .o_action(p_action_ask),
    .o_price(p_price_ask),
    .o_valid(p_valid_ask),
    .o_quantity(p_quantity_ask)
); 

// this module track the quantity of each price
ob_flb_bid bid_flb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_price(p_price_bid),
    .i_quantity(p_quantity_bid),
    .i_action(p_action_bid),
    .i_valid(p_valid_bid),
    .o_valid(o_valid_bid),
    .o_action(o_action_bid),
    .o_current_price(o_price_bid),
    .o_current_quant(o_quant_bid),
    .o_best_price(o_bid_best_price),
    .o_best_price_quant(o_bid_best_quant),
    .o_best_valid(o_bid_best_valid)
);

ob_flb_ask ask_flb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_quantity(p_quantity_ask),
    .i_action(p_action_ask),
    .i_valid(p_valid_ask),
    .i_price(p_price_ask),
    .o_valid(o_valid_ask),
    .o_action(o_action_ask),
    .o_current_price(o_price_ask),
    .o_current_quant(o_quant_ask),
    .o_best_price(o_ask_best_price),
    .o_best_price_quant(o_ask_best_quant),
    .o_best_valid(o_ask_best_valid)
);

assign o_valid = o_valid_ask || o_valid_bid;
assign o_action = o_valid_ask ? o_action_ask : o_action_bid;
assign o_price = o_valid_ask ? o_price_ask : o_price_bid;
assign o_quantity = o_valid_ask ? o_quant_ask : o_quant_bid;

endmodule
