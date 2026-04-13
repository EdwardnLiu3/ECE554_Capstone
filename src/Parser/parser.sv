module parser 
#(parameter ORDERID_LEN  = 64, parameter QUANTITY_LEN = 32, parameter PRICE_LEN    = 32, parameter STOCK_LEN    = 16)
(
    input                               i_clk,
    input                               i_rst_n,
    input   [287:0]                     i_payload,
    input                               i_valid,
    output  [ORDERID_LEN-1:0]           o_order_id,
    output  [QUANTITY_LEN-1:0]          o_quantity,
    output                              o_side,
    output  [PRICE_LEN-1:0]             o_price,
    output  [1:0]                       o_action,
    output                              o_valid,
    output  [STOCK_LEN-1:0]             o_stock_id
);


reg [ORDERID_LEN-1:0] order_id_ff;
reg [QUANTITY_LEN-1:0] quantity_ff;
reg side_ff;
reg [PRICE_LEN-1:0] price_ff;
reg [1:0] action_ff;
reg valid_ff;
reg [STOCK_LEN-1:0] stock_id_ff;


assign o_order_id = order_id_ff;
assign o_quantity = quantity_ff;
assign o_side = side_ff;
assign o_price = price_ff;
assign o_action = action_ff;
assign o_valid = valid_ff;
assign o_stock_id = stock_id_ff;

always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        order_id_ff <= '0;
        quantity_ff <= '0; 
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= '0;
        valid_ff <= '0;
        stock_id_ff <= '0;       
    end
    else if(i_payload[7:0] == 8'b01000001) begin //add
        order_id_ff <= i_payload[97:88];
        quantity_ff <= i_payload[191:160];
        side_ff <= i_payload[159:152] == 8'b01000010 ? 1'b0 : 1'b1;
        price_ff <= i_payload[287:256];
        action_ff <= 2'b00;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
    end
    else if(i_payload[7:0] == 8'b01011000) begin //cancel
        order_id_ff <= i_payload[97:88];
        quantity_ff <= i_payload[183:152];
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= 2'b01;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
    end
    else if(i_payload[7:0] == 8'b01000100) begin //delete
        order_id_ff <= i_payload[97:88];
        quantity_ff <= '0;
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= 2'b11;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
    end
    else if(i_payload[7:0] ==  8'b01000101) begin //execute
        order_id_ff <= i_payload[97:88];
        quantity_ff <= i_payload[183:152];
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= 2'b10;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
    end
    else begin
        order_id_ff <= '0;
        quantity_ff <= '0;
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= '0;
        valid_ff <= 1'b0;
        stock_id_ff <= '0;
    end
end 

endmodule