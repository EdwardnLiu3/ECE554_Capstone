import ob_pkg::*;
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
    logic         soft_rst_n;   // software-controlled reset (active low, 1-cycle pulse)
    logic         combined_rst_n;

    // Parser Outputs
    logic [ORDERID_LEN-1:0] o_order_id;  // 10 bits (ob_pkg::ORDERID_LEN)
    logic [31:0] o_quantity;
    logic        o_side;
    logic [31:0] o_price;
    logic [1:0]  o_action;
    logic        o_valid;
    logic [15:0] o_stock_id;

    // Orderbook Outputs
    logic [PRICE_LEN-1:0]       ob_bid_best_price;
    logic [TOT_QUATITY_LEN-1:0] ob_bid_best_quant;
    logic [PRICE_LEN-1:0]       ob_ask_best_price;
    logic [TOT_QUATITY_LEN-1:0] ob_ask_best_quant;
    logic                       ob_bid_best_valid;
    logic                       ob_ask_best_valid;
    logic [1:0]                 ob_action;
    logic [PRICE_LEN-1:0]       ob_price;
    logic [QUANTITY_LEN-1:0]    ob_quantity;
    logic                       ob_valid;
    logic                       ob_side;

    // Instantiate the parser
    parser #(
        .ORDERID_LEN(ORDERID_LEN),
        .QUANTITY_LEN(32),
        .PRICE_LEN(32),
        .STOCK_LEN(16)
    ) parser_inst (
        .i_clk(clk),
        .i_rst_n(combined_rst_n),
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

    // Instantiate the orderbook (parser outputs feed directly into orderbook)
    orderbook ob_inst (
        .i_clk(clk),
        .i_rst_n(combined_rst_n),
        .i_order_id(o_order_id),
        .i_side(o_side),
        .i_price(o_price),
        .i_quantity(o_quantity),
        .i_action(o_action),
        .i_valid(o_valid),
        .o_bid_best_price(ob_bid_best_price),
        .o_bid_best_quant(ob_bid_best_quant),
        .o_ask_best_price(ob_ask_best_price),
        .o_ask_best_quant(ob_ask_best_quant),
        .o_bid_best_valid(ob_bid_best_valid),
        .o_ask_best_valid(ob_ask_best_valid),
        .o_action(ob_action),
        .o_price(ob_price),
        .o_quantity(ob_quantity),
        .o_valid(ob_valid),
        .o_side(ob_side)
    );

    // No wait states needed
    assign avs_waitrequest = 1'b0;
    assign combined_rst_n = reset_n & soft_rst_n;

    // Write Logic
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            i_payload   <= '0;
            i_valid     <= 1'b0;
            soft_rst_n  <= 1'b1;
        end else begin
            // Default: deassert pulses each cycle
            i_valid    <= 1'b0;
            soft_rst_n <= 1'b1;

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
                    6'd22: soft_rst_n         <= 1'b0; // Pulse soft reset low
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

                // Parser outputs (addr 10-14, unchanged for software compat)
                6'd10: avs_readdata = {22'd0, o_order_id};  // 10-bit order_id zero-padded
                6'd11: avs_readdata = 32'd0;                // was order_id[63:32], now unused
                6'd12: avs_readdata = o_quantity;
                6'd13: avs_readdata = o_price;
                6'd14: avs_readdata = {12'd0, o_valid, o_side, o_action, o_stock_id};

                // Orderbook outputs (addr 15-21)
                6'd15: avs_readdata = ob_bid_best_price;
                6'd16: avs_readdata = ob_bid_best_quant[31:0];
                6'd17: avs_readdata = ob_bid_best_quant[63:32];
                6'd18: avs_readdata = ob_ask_best_price;
                6'd19: avs_readdata = ob_ask_best_quant[31:0];
                6'd20: avs_readdata = ob_ask_best_quant[63:32];
                6'd21: avs_readdata = {30'd0, ob_ask_best_valid, ob_bid_best_valid};

                // Orderbook pipeline inputs/outputs for debug (addr 23-27)
                6'd23: avs_readdata = {22'd0, o_order_id};   // OB input: order_id (same as parser output)
                6'd24: avs_readdata = o_price;               // OB input: price
                6'd25: avs_readdata = o_quantity;            // OB input: quantity
                6'd26: avs_readdata = {29'd0, o_valid, o_side, o_action[0]}; // OB input: valid/side/action
                6'd27: avs_readdata = {30'd0, o_action};     // OB input: action full 2 bits

                // Orderbook pipeline outputs (addr 28-31)
                6'd28: avs_readdata = {30'd0, ob_side, ob_valid};
                6'd29: avs_readdata = {30'd0, ob_action};
                6'd30: avs_readdata = ob_price;
                6'd31: avs_readdata = ob_quantity;
            endcase
        end
    end

endmodule
