module parser_avalon_wrapper (
    input clk,
    input reset_n,
    
    // Avalon-MM Slave Interface
    input  [5:0]  avs_address,
    input         avs_read,
    output logic [31:0] avs_readdata,
    input         avs_write,
    input  [31:0] avs_writedata,
    output logic  avs_waitrequest
);

    // Internal Registers for Parser Input
    logic [287:0] i_payload;
    logic         i_valid;
    
    // Parser Outputs
    logic [63:0] o_order_id;
    logic [31:0] o_quantity;
    logic        o_side;
    logic [31:0] o_price;
    logic [1:0]  o_action;
    logic        o_valid;
    logic [15:0] o_stock_id;

    // Instantiate the original parser
    parser #(
        .ORDERID_LEN(64),
        .QUANTITY_LEN(32),
        .PRICE_LEN(32),
        .STOCK_LEN(16)
    ) parser_inst (
        .i_clk(clk),
        .i_rst_n(reset_n),
        .i_payload(i_payload),
        .i_valid(i_valid),
        .o_order_id(o_order_id),
        .o_quantity(o_quantity),
        .o_side(o_side),
        .o_price(o_price),
        .o_action(o_action),
        .o_valid(o_valid),
        .o_stock_id(o_stock_id)
    );

    // No wait states needed
    assign avs_waitrequest = 1'b0;

    // Write Logic
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            i_payload <= '0;
            i_valid   <= 1'b0;
        end else begin
            // Default i_valid to low (pulse generator)
            i_valid <= 1'b0;

            if (avs_write) begin
                case (avs_address)
                    6'd0: i_payload[31:0]     <= avs_writedata;
                    6'd1: i_payload[63:32]    <= avs_writedata;
                    6'd2: i_payload[95:64]    <= avs_writedata;
                    6'd3: i_payload[127:96]   <= avs_writedata;
                    6'd4: i_payload[159:128]  <= avs_writedata;
                    6'd5: i_payload[191:160]  <= avs_writedata;
                    6'd6: i_payload[223:192]  <= avs_writedata;
                    6'd7: i_payload[255:224]  <= avs_writedata;
                    6'd8: i_payload[287:256]  <= avs_writedata;
                    6'd9: i_valid             <= 1'b1; // Pulse valid high
                endcase
            end
        end
    end

    // Read Logic
    always_comb begin
        avs_readdata = 32'h0; // Default read
        if (avs_read) begin
            case (avs_address)
                // Read back payload (for debug)
                6'd0: avs_readdata = i_payload[31:0];
                6'd1: avs_readdata = i_payload[63:32];
                6'd2: avs_readdata = i_payload[95:64];
                6'd3: avs_readdata = i_payload[127:96];
                6'd4: avs_readdata = i_payload[159:128];
                6'd5: avs_readdata = i_payload[191:160];
                6'd6: avs_readdata = i_payload[223:192];
                6'd7: avs_readdata = i_payload[255:224];
                6'd8: avs_readdata = i_payload[287:256];
                
                // Read parser outputs
                6'd10: avs_readdata = o_order_id[31:0];
                6'd11: avs_readdata = o_order_id[63:32];
                6'd12: avs_readdata = o_quantity;
                6'd13: avs_readdata = o_price;
                6'd14: avs_readdata = {12'd0, o_valid, o_side, o_action, o_stock_id};
            endcase
        end
    end

endmodule
