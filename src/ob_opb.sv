module ob_opb opb(
    input logic i_clk,
    input logic i_rst_n,
    input logic [ORDERID_LEN-1:0] i_order_id,
    input logic [QUATITY_LEN-1 : 0] i_quantity,
    input logic i_add,
    input logic i_valid,
    input logic [PRICE_LEN-1 : 0] i_price,
    output logic [PRICE_LEN-1 : 0] o_price,
    output logic o_valid
); 

endmodule