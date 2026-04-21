module parser
#(parameter ORDERID_LEN  = 16, parameter QUANTITY_LEN = 12, parameter PRICE_LEN    = 16, parameter STOCK_LEN    = 16)
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
    output  [STOCK_LEN-1:0]             o_stock_id,
    output  [47:0]                      o_timestamp
);


reg [ORDERID_LEN-1:0] order_id_ff;
reg [QUANTITY_LEN-1:0] quantity_ff;
reg side_ff;
reg [PRICE_LEN-1:0] price_ff;
reg [1:0] action_ff;
reg valid_ff;
reg [STOCK_LEN-1:0] stock_id_ff;
reg [47:0] timestamp_ff;


assign o_order_id = order_id_ff;
assign o_quantity = quantity_ff;
assign o_side = side_ff;
assign o_price = price_ff;
assign o_action = action_ff;
assign o_valid = valid_ff;
assign o_stock_id = stock_id_ff;
assign o_timestamp = timestamp_ff;

always_ff @(posedge i_clk, negedge i_rst_n) begin
    if(!i_rst_n) begin
        order_id_ff <= '0;
        quantity_ff <= '0;
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= '0;
        valid_ff <= '0;
        stock_id_ff <= '0;
        timestamp_ff <= '0;
    end
    else if(i_payload[7:0] == 8'b01000001) begin //add
        order_id_ff <= i_payload[151:144]; // byte 18: LSB of 8-byte big-endian order ref number
        quantity_ff <= {i_payload[167:160], i_payload[175:168], i_payload[183:176], i_payload[191:184]}; // byte-swap bytes 20-23
        side_ff <= i_payload[159:152] == 8'b01000010 ? 1'b0 : 1'b1;
        price_ff <= {i_payload[263:256], i_payload[271:264], i_payload[279:272], i_payload[287:280]}; // byte-swap bytes 32-35
        action_ff <= 2'b00;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
        timestamp_ff <= i_payload[87:40];
    end
    else if(i_payload[7:0] == 8'b01011000) begin //cancel
        order_id_ff <= i_payload[151:144]; // byte 18: LSB of 8-byte big-endian order ref number
        quantity_ff <= {i_payload[159:152], i_payload[167:160], i_payload[175:168], i_payload[183:176]}; // byte-swap bytes 19-22
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= 2'b01;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
        timestamp_ff <= i_payload[87:40];
    end
    else if(i_payload[7:0] == 8'b01000100) begin //delete
        order_id_ff <= i_payload[151:144]; // byte 18: LSB of 8-byte big-endian order ref number
        quantity_ff <= '0;
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= 2'b11;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
        timestamp_ff <= i_payload[87:40];
    end
    else if(i_payload[7:0] ==  8'b01000101) begin //execute
        order_id_ff <= i_payload[151:144]; // byte 18: LSB of 8-byte big-endian order ref number
        quantity_ff <= {i_payload[159:152], i_payload[167:160], i_payload[175:168], i_payload[183:176]}; // byte-swap bytes 19-22
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= 2'b10;
        valid_ff <= i_valid;
        stock_id_ff <= i_payload[23:8];
        timestamp_ff <= i_payload[87:40];
    end
    else begin
        order_id_ff <= '0;
        quantity_ff <= '0;
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= '0;
        valid_ff <= 1'b0;
        stock_id_ff <= '0;
        timestamp_ff <= '0;
    end
end 

endmodule