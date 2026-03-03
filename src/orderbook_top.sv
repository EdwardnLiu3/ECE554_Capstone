module orderbook_top(
    input i_clk,
    input i_rst_n,
    input [ORDERID_LEN-1:0] i_order_id,
    input i_side,
    input [PRICE_LEN-1 : 0] i_price,
    input [QUATITY_LEN-1 : 0] i_quantity,
    input [1:0] i_action,
    input i_valid,
    output [PRICE_LEN-1 : 0] o_bid_max,
    output [PRICE_LEN-1 : 0] o_ask_min
);

endmodule
