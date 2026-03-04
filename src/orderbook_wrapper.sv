////////////////////////////////////////////////////
// 
// This module get the information from parsing
// module and output the current state of the stock
//
////////////////////////////////////////////////////
module orderbook_wrapper(
    input i_clk,
    input i_rst_n,
    input [ORDERID_LEN-1:0] i_order_id,
    input i_side,
    input [PRICE_LEN-1 : 0] i_price,
    input [QUATITY_LEN-1 : 0] i_quantity,
    input [1:0] i_action,
    input i_valid,
    output [PRICE_LEN-1 : 0] o_bid_best_price,
    output [QUATITY_LEN-1 : 0] o_total_bid,
    output [PRICE_LEN-1 : 0] o_ask_best_price,
    output [QUATITY_LEN-1 : 0] o_total_ask,
);

logic bid_side, ask_side;
logic add, cancel, execute;
logic p_add_bid, p_add_ask;
assign add = i_action == 2'b00;
assign cancel = i_action = 2'b01;
assign execute = i_action = 2'b10;
assign bid_side = i_side == 0;
assign ask_side = i_side == 1;

// this module track the price and quantity of every existing orderid
ob_opb bid_opb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_add(add),
    .i_valid(i_valid),
    .i_price(i_price),
    .o_add(p_add_bid),
    .o_price(),
    .o_valid(),
    .o_quantity()
); 

ob_opb ask_opb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_order_id(i_order_id),
    .i_quantity(i_quantity),
    .i_add(p_add_bid),
    .i_valid(i_valid),
    .i_price(i_price),
    .o_add(p_add),
    .o_price(),
    .o_valid(),
    .o_quantity()
); 

// this module track the quantity of each price
ob_flb flb(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_price(),
    .i_quantity(),
    .i_add(p_add),
    .i_valid(),
    .o_valid(),
    .o_best_bid(),
    .o_best_ask()
);

endmodule
