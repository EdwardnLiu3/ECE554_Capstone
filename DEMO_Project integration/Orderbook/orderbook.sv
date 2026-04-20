////////////////////////////////////////////////////
// 
// This module get the information from parsing
// module and output the current state of the stock
//
////////////////////////////////////////////////////
import ob_pkg::*;
module orderbook #(parameter int BASE_PRICE = 0)(
    input                           i_clk,
    input                           i_rst_n,
    input [ORDERID_LEN-1:0]         i_order_id,
    input                           i_side,
    input [PRICE_LEN-1:0]           i_price,
    input [QUANTITY_LEN-1:0]        i_quantity,
    input [1:0]                     i_action,
    input                           i_valid,
    input  [47:0]                   i_timestamp,
    output [PRICE_LEN-1:0]          o_bid_best_price,
    output [TOT_QUATITY_LEN-1:0]    o_bid_best_quant,
    output [PRICE_LEN-1:0]          o_ask_best_price,
    output [TOT_QUATITY_LEN-1:0]    o_ask_best_quant,
    output                          o_bid_best_valid,
    output                          o_ask_best_valid,
    output [1:0]                    o_action,
    output [PRICE_LEN-1:0]          o_price,
    output [QUANTITY_LEN-1:0]       o_quantity,
    output                          o_valid,
    output                          o_side,
    output  [47:0]                  o_timestamp
);

logic bid_side, ask_side, p_side;
logic [1:0] p_action, p_action_ask, o_action_ask, o_action_bid;
logic [PRICE_LEN-1 : 0] p_price, p_price_ask, o_price_ask, o_price_bid;
logic [QUANTITY_LEN-1:0] p_quantity, p_quantity_ask, o_quant_ask, o_quant_bid;
logic p_valid, o_valid_ask, o_valid_bid;

logic [47:0] timestamp1, timestamp2, timestamp3, timestamp4, timestamp5, timestamp6, timestamp7;

assign bid_side = p_side == 0;
assign ask_side = p_side == 1;

// this module track the price and quantity of every existing orderid
ob_opb bid_opb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_action(i_action),
    .i_valid(i_valid),
    .i_price(i_price),
    .i_side(i_side),
    .o_action(p_action),
    .o_price(p_price),
    .o_valid(p_valid),
    .o_quantity(p_quantity),
    .o_side(p_side)
); 


// this module track the quantity of each price
ob_flb_bid #(.BASE_PRICE(BASE_PRICE)) bid_flb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_price(p_price),
    .i_quantity(p_quantity),
    .i_action(p_action),
    .i_valid(p_valid && bid_side),
    .o_valid(o_valid_bid),
    .o_action(o_action_bid),
    .o_current_price(o_price_bid),
    .o_current_quant(o_quant_bid),
    .o_best_price(o_bid_best_price),
    .o_best_price_quant(o_bid_best_quant),
    .o_best_valid(o_bid_best_valid)
);

ob_flb_ask #(.BASE_PRICE(BASE_PRICE)) ask_flb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_quantity(p_quantity),
    .i_action(p_action),
    .i_valid(p_valid && ask_side),
    .i_price(p_price),
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
assign o_side = o_valid_ask;

always_ff @(posedge i_clk) begin
    if(!i_rst_n) begin
        timestamp1 <= '0;
        timestamp2 <= '0;
        timestamp3 <= '0;
        timestamp4 <= '0;
        timestamp5 <= '0;
        timestamp6 <= '0;
        timestamp7 <= '0;
    end else begin
        timestamp1 <= i_timestamp;
        timestamp2 <= timestamp1;
        timestamp3 <= timestamp2;
        timestamp4 <= timestamp3;
        timestamp5 <= timestamp4;
        timestamp6 <= timestamp5;
        timestamp7 <= timestamp6;
    end
end

assign o_timestamp = timestamp7;

endmodule
