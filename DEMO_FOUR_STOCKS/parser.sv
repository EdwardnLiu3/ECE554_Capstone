module parser
#(
    parameter ORDERID_LEN = 64,
    parameter QUANTITY_LEN = 32,
    parameter PRICE_LEN = 32,
    parameter STOCK_LEN = 16
) (
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

logic [ORDERID_LEN-1:0]   order_id_ff;
logic [QUANTITY_LEN-1:0]  quantity_ff;
logic                     side_ff;
logic [PRICE_LEN-1:0]     price_ff;
logic [1:0]               action_ff;
logic                     valid_ff;
logic [STOCK_LEN-1:0]     stock_id_ff;
logic [47:0]              timestamp_ff;

function automatic [15:0] get_be16(input logic [287:0] payload, input int unsigned byte_idx);
    get_be16 = {
        payload[(byte_idx + 0) * 8 +: 8],
        payload[(byte_idx + 1) * 8 +: 8]
    };
endfunction

function automatic [31:0] get_be32(input logic [287:0] payload, input int unsigned byte_idx);
    get_be32 = {
        payload[(byte_idx + 0) * 8 +: 8],
        payload[(byte_idx + 1) * 8 +: 8],
        payload[(byte_idx + 2) * 8 +: 8],
        payload[(byte_idx + 3) * 8 +: 8]
    };
endfunction

function automatic [47:0] get_be48(input logic [287:0] payload, input int unsigned byte_idx);
    get_be48 = {
        payload[(byte_idx + 0) * 8 +: 8],
        payload[(byte_idx + 1) * 8 +: 8],
        payload[(byte_idx + 2) * 8 +: 8],
        payload[(byte_idx + 3) * 8 +: 8],
        payload[(byte_idx + 4) * 8 +: 8],
        payload[(byte_idx + 5) * 8 +: 8]
    };
endfunction

function automatic [63:0] get_be64(input logic [287:0] payload, input int unsigned byte_idx);
    get_be64 = {
        payload[(byte_idx + 0) * 8 +: 8],
        payload[(byte_idx + 1) * 8 +: 8],
        payload[(byte_idx + 2) * 8 +: 8],
        payload[(byte_idx + 3) * 8 +: 8],
        payload[(byte_idx + 4) * 8 +: 8],
        payload[(byte_idx + 5) * 8 +: 8],
        payload[(byte_idx + 6) * 8 +: 8],
        payload[(byte_idx + 7) * 8 +: 8]
    };
endfunction

assign o_order_id = order_id_ff;
assign o_quantity = quantity_ff;
assign o_side = side_ff;
assign o_price = price_ff;
assign o_action = action_ff;
assign o_valid = valid_ff;
assign o_stock_id = stock_id_ff;
assign o_timestamp = timestamp_ff;

always_ff @(posedge i_clk, negedge i_rst_n) begin
    if (!i_rst_n) begin
        order_id_ff <= '0;
        quantity_ff <= '0;
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= '0;
        valid_ff <= 1'b0;
        stock_id_ff <= '0;
        timestamp_ff <= '0;
    end else begin
        order_id_ff <= '0;
        quantity_ff <= '0;
        side_ff <= '0;
        price_ff <= '0;
        action_ff <= '0;
        valid_ff <= 1'b0;
        stock_id_ff <= '0;
        timestamp_ff <= '0;

        case (i_payload[7:0])
            8'h41: begin
                order_id_ff <= get_be64(i_payload, 11);
                quantity_ff <= get_be32(i_payload, 20);
                side_ff <= (i_payload[159:152] == 8'h53);
                price_ff <= get_be32(i_payload, 32);
                action_ff <= 2'b00;
                valid_ff <= i_valid;
                stock_id_ff <= get_be16(i_payload, 1);
                timestamp_ff <= get_be48(i_payload, 5);
            end
            8'h58: begin
                order_id_ff <= get_be64(i_payload, 11);
                quantity_ff <= get_be32(i_payload, 19);
                side_ff <= 1'b0;
                price_ff <= '0;
                action_ff <= 2'b01;
                valid_ff <= i_valid;
                stock_id_ff <= get_be16(i_payload, 1);
                timestamp_ff <= get_be48(i_payload, 5);
            end
            8'h44: begin
                order_id_ff <= get_be64(i_payload, 11);
                quantity_ff <= '0;
                side_ff <= 1'b0;
                price_ff <= '0;
                action_ff <= 2'b11;
                valid_ff <= i_valid;
                stock_id_ff <= get_be16(i_payload, 1);
                timestamp_ff <= get_be48(i_payload, 5);
            end
            8'h45: begin
                order_id_ff <= get_be64(i_payload, 11);
                quantity_ff <= get_be32(i_payload, 19);
                side_ff <= 1'b0;
                price_ff <= '0;
                action_ff <= 2'b10;
                valid_ff <= i_valid;
                stock_id_ff <= get_be16(i_payload, 1);
                timestamp_ff <= get_be48(i_payload, 5);
            end
            default: begin
            end
        endcase
    end
end

endmodule
