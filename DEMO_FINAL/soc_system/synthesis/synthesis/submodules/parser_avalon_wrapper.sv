module parser_avalon_wrapper #(
    parameter int MARKET_PAYLOAD_LEN = 288,
    parameter int OUCH_PAYLOAD_LEN   = 752,
    parameter int SYMBOL_LEN         = 64,
    parameter int ORDER_ID_LEN       = 32,
    parameter int PRICE_LEN          = 32,
    parameter int QUANTITY_LEN       = 16,
    parameter int POSITION_LEN       = 16,
    parameter int PNL_LEN            = 64,
    parameter int STOCK_LEN          = 16,
    parameter int MARKET_QTY_LEN     = 32,
    parameter int BOOK_BASE_PRICE    = 32'd2_200_000,
    parameter logic [SYMBOL_LEN-1:0] DEFAULT_SYMBOL = {"A","M","Z","N"," "," "," "," "},
    parameter logic [QUANTITY_LEN-1:0] DEFAULT_BID_QTY = 16'd5,
    parameter logic [QUANTITY_LEN-1:0] DEFAULT_ASK_QTY = 16'd5
) (
    input  logic        clk,
    input  logic        reset_n,
    input  logic [5:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,
    output logic        avs_waitrequest
);

    localparam int OUCH_WORDS = (OUCH_PAYLOAD_LEN + 31) / 32;

    // Avalon write-side control registers.
    logic [MARKET_PAYLOAD_LEN-1:0] market_payload_reg;
    logic                          market_valid_pulse;
    logic                          soft_rst_n;
    logic                          combined_rst_n;
    logic [SYMBOL_LEN-1:0]         symbol_reg;
    logic [QUANTITY_LEN-1:0]       bid_quote_qty_reg;
    logic [QUANTITY_LEN-1:0]       ask_quote_qty_reg;
    logic                          trading_enable_reg;
    logic                          kill_switch_reg;
    logic                          price_band_enable_reg;
    logic                          pnl_check_enable_reg;
    logic [47:0]                   sw_order_time_reg;

    // HFT outputs.
    logic [STOCK_LEN-1:0]          stock_id;
    logic [PRICE_LEN-1:0]          best_bid_price;
    logic [PRICE_LEN-1:0]          best_ask_price;
    logic                          best_bid_valid;
    logic                          best_ask_valid;
    logic [PRICE_LEN-1:0]          trading_bid_price;
    logic [PRICE_LEN-1:0]          trading_ask_price;
    logic [1:0]                    trading_order_type;
    logic                          trading_valid;
    logic                          bid_reject_valid;
    logic [3:0]                    bid_reject_reason;
    logic                          ask_reject_valid;
    logic [3:0]                    ask_reject_reason;
    logic                          order_payload_valid;
    logic [OUCH_PAYLOAD_LEN-1:0]   order_payload;
    logic                          exec_valid;
    logic                          exec_side;
    logic [PRICE_LEN-1:0]          exec_price;
    logic [QUANTITY_LEN-1:0]       exec_quantity;
    logic [ORDER_ID_LEN-1:0]       exec_order_id;
    logic signed [POSITION_LEN-1:0] position;
    logic signed [PNL_LEN-1:0]     day_pnl;
    logic [QUANTITY_LEN-1:0]       live_bid_qty;
    logic [QUANTITY_LEN-1:0]       live_ask_qty;

    // Latched debug / status registers so software does not miss pulses.
    logic [OUCH_PAYLOAD_LEN-1:0]   last_order_payload;
    logic                          last_order_payload_valid;
    logic                          last_exec_valid;
    logic                          last_exec_side;
    logic [PRICE_LEN-1:0]          last_exec_price;
    logic [QUANTITY_LEN-1:0]       last_exec_quantity;
    logic [ORDER_ID_LEN-1:0]       last_exec_order_id;
    logic                          last_bid_reject_valid;
    logic [3:0]                    last_bid_reject_reason;
    logic                          last_ask_reject_valid;
    logic [3:0]                    last_ask_reject_reason;
    logic [31:0]                   order_payload_count;
    logic [31:0]                   exec_count;
    logic [31:0]                   bid_reject_count;
    logic [31:0]                   ask_reject_count;

    logic [PRICE_LEN-1:0]          mark_price;
    logic                          mark_price_valid;
    logic signed [PNL_LEN-1:0]     mtm_total_pnl;
    logic signed [PNL_LEN-1:0]     inventory_value;

    function automatic signed [PNL_LEN-1:0] calc_total_pnl(
        input signed [PNL_LEN-1:0] day_pnl_in,
        input signed [POSITION_LEN-1:0] position_in,
        input logic [PRICE_LEN-1:0] mark_price_in
    );
        logic signed [PNL_LEN-1:0] inventory_mark_value;
        begin
            inventory_mark_value = $signed(position_in) * $signed({1'b0, mark_price_in});
            calc_total_pnl = day_pnl_in + inventory_mark_value;
        end
    endfunction

    assign avs_waitrequest = 1'b0;
    assign combined_rst_n = reset_n & soft_rst_n;

    always_comb begin
        mark_price = '0;
        mark_price_valid = 1'b0;
        if (best_bid_valid && best_ask_valid) begin
            mark_price = ({1'b0, best_bid_price} + {1'b0, best_ask_price}) >> 1;
            mark_price_valid = 1'b1;
        end else if (best_bid_valid) begin
            mark_price = best_bid_price;
            mark_price_valid = 1'b1;
        end else if (best_ask_valid) begin
            mark_price = best_ask_price;
            mark_price_valid = 1'b1;
        end
    end

    always_comb begin
        if (mark_price_valid)
            mtm_total_pnl = calc_total_pnl(day_pnl, position, mark_price);
        else
            mtm_total_pnl = day_pnl;
    end

    assign inventory_value = mtm_total_pnl - day_pnl;

    hft_single_stock_top #(
        .MARKET_PAYLOAD_LEN (MARKET_PAYLOAD_LEN),
        .OUCH_PAYLOAD_LEN   (OUCH_PAYLOAD_LEN),
        .SYMBOL_LEN         (SYMBOL_LEN),
        .ORDER_ID_LEN       (ORDER_ID_LEN),
        .PRICE_LEN          (PRICE_LEN),
        .QUANTITY_LEN       (QUANTITY_LEN),
        .POSITION_LEN       (POSITION_LEN),
        .PNL_LEN            (PNL_LEN),
        .STOCK_LEN          (STOCK_LEN),
        .MARKET_QTY_LEN     (MARKET_QTY_LEN),
        .BOOK_BASE_PRICE    (BOOK_BASE_PRICE)
    ) dut (
        .i_clk               (clk),
        .i_rst_n             (combined_rst_n),
        .i_market_payload    (market_payload_reg),
        .i_market_valid      (market_valid_pulse),
        .i_order_time        (sw_order_time_reg),
        .i_symbol            (symbol_reg),
        .i_bid_quote_quantity(bid_quote_qty_reg),
        .i_ask_quote_quantity(ask_quote_qty_reg),
        .i_trading_enable    (trading_enable_reg),
        .i_kill_switch       (kill_switch_reg),
        .i_price_band_enable (price_band_enable_reg),
        .i_pnl_check_enable  (pnl_check_enable_reg),
        .o_stock_id          (stock_id),
        .o_best_bid_price    (best_bid_price),
        .o_best_ask_price    (best_ask_price),
        .o_best_bid_valid    (best_bid_valid),
        .o_best_ask_valid    (best_ask_valid),
        .o_trading_bid_price (trading_bid_price),
        .o_trading_ask_price (trading_ask_price),
        .o_trading_order_type(trading_order_type),
        .o_trading_valid     (trading_valid),
        .o_bid_reject_valid  (bid_reject_valid),
        .o_bid_reject_reason (bid_reject_reason),
        .o_ask_reject_valid  (ask_reject_valid),
        .o_ask_reject_reason (ask_reject_reason),
        .o_order_payload_valid(order_payload_valid),
        .o_order_payload     (order_payload),
        .o_exec_valid        (exec_valid),
        .o_exec_side         (exec_side),
        .o_exec_price        (exec_price),
        .o_exec_quantity     (exec_quantity),
        .o_exec_order_id     (exec_order_id),
        .o_position          (position),
        .o_day_pnl           (day_pnl),
        .o_live_bid_qty      (live_bid_qty),
        .o_live_ask_qty      (live_ask_qty)
    );

    // Register map summary:
    // Writes:
    //   0-8   : market payload words [31:0] .. [287:256]
    //   9     : pulse market_valid
    //   10-11 : symbol low/high
    //   12    : bid quote quantity
    //   13    : ask quote quantity
    //   14    : controls [0]=trading_en [1]=kill [2]=price_band_en [3]=pnl_check_en
    //   15-16 : software order time low/high16
    //   22    : pulse soft reset low for one cycle
    //
    // Reads:
    //   0-16  : writeback / current config
    //   17-31 : live HFT state, P/L, counts
    //   32-55 : latched last OUCH payload words
    //   56-63 : latched last execution / reject details
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            market_payload_reg      <= '0;
            market_valid_pulse      <= 1'b0;
            soft_rst_n              <= 1'b1;
            symbol_reg              <= DEFAULT_SYMBOL;
            bid_quote_qty_reg       <= DEFAULT_BID_QTY;
            ask_quote_qty_reg       <= DEFAULT_ASK_QTY;
            trading_enable_reg      <= 1'b1;
            kill_switch_reg         <= 1'b0;
            price_band_enable_reg   <= 1'b1;
            pnl_check_enable_reg    <= 1'b1;
            sw_order_time_reg       <= '0;
            last_order_payload      <= '0;
            last_order_payload_valid <= 1'b0;
            last_exec_valid         <= 1'b0;
            last_exec_side          <= 1'b0;
            last_exec_price         <= '0;
            last_exec_quantity      <= '0;
            last_exec_order_id      <= '0;
            last_bid_reject_valid   <= 1'b0;
            last_bid_reject_reason  <= '0;
            last_ask_reject_valid   <= 1'b0;
            last_ask_reject_reason  <= '0;
            order_payload_count     <= '0;
            exec_count              <= '0;
            bid_reject_count        <= '0;
            ask_reject_count        <= '0;
        end else begin
            market_valid_pulse <= 1'b0;
            soft_rst_n         <= 1'b1;

            if (avs_write) begin
                case (avs_address)
                    6'd0:  market_payload_reg[31:0]     <= avs_writedata;
                    6'd1:  market_payload_reg[63:32]    <= avs_writedata;
                    6'd2:  market_payload_reg[95:64]    <= avs_writedata;
                    6'd3:  market_payload_reg[127:96]   <= avs_writedata;
                    6'd4:  market_payload_reg[159:128]  <= avs_writedata;
                    6'd5:  market_payload_reg[191:160]  <= avs_writedata;
                    6'd6:  market_payload_reg[223:192]  <= avs_writedata;
                    6'd7:  market_payload_reg[255:224]  <= avs_writedata;
                    6'd8:  market_payload_reg[287:256]  <= avs_writedata[31:0];
                    6'd9:  market_valid_pulse           <= 1'b1;
                    6'd10: symbol_reg[31:0]             <= avs_writedata;
                    6'd11: symbol_reg[63:32]            <= avs_writedata;
                    6'd12: bid_quote_qty_reg            <= avs_writedata[QUANTITY_LEN-1:0];
                    6'd13: ask_quote_qty_reg            <= avs_writedata[QUANTITY_LEN-1:0];
                    6'd14: begin
                        trading_enable_reg    <= avs_writedata[0];
                        kill_switch_reg       <= avs_writedata[1];
                        price_band_enable_reg <= avs_writedata[2];
                        pnl_check_enable_reg  <= avs_writedata[3];
                    end
                    6'd15: sw_order_time_reg[31:0]      <= avs_writedata;
                    6'd16: sw_order_time_reg[47:32]     <= avs_writedata[15:0];
                    6'd22: soft_rst_n                   <= 1'b0;
                    default: begin end
                endcase
            end

            if (order_payload_valid) begin
                last_order_payload       <= order_payload;
                last_order_payload_valid <= 1'b1;
                order_payload_count      <= order_payload_count + 32'd1;
            end

            if (exec_valid) begin
                last_exec_valid     <= 1'b1;
                last_exec_side      <= exec_side;
                last_exec_price     <= exec_price;
                last_exec_quantity  <= exec_quantity;
                last_exec_order_id  <= exec_order_id;
                exec_count          <= exec_count + 32'd1;
            end

            if (bid_reject_valid) begin
                last_bid_reject_valid  <= 1'b1;
                last_bid_reject_reason <= bid_reject_reason;
                bid_reject_count       <= bid_reject_count + 32'd1;
            end

            if (ask_reject_valid) begin
                last_ask_reject_valid  <= 1'b1;
                last_ask_reject_reason <= ask_reject_reason;
                ask_reject_count       <= ask_reject_count + 32'd1;
            end
        end
    end

    always_comb begin
        avs_readdata = 32'h0;
        if (avs_read) begin
            case (avs_address)
                6'd0:  avs_readdata = market_payload_reg[31:0];
                6'd1:  avs_readdata = market_payload_reg[63:32];
                6'd2:  avs_readdata = market_payload_reg[95:64];
                6'd3:  avs_readdata = market_payload_reg[127:96];
                6'd4:  avs_readdata = market_payload_reg[159:128];
                6'd5:  avs_readdata = market_payload_reg[191:160];
                6'd6:  avs_readdata = market_payload_reg[223:192];
                6'd7:  avs_readdata = market_payload_reg[255:224];
                6'd8:  avs_readdata = market_payload_reg[287:256];
                6'd9:  avs_readdata = {31'd0, market_valid_pulse};
                6'd10: avs_readdata = symbol_reg[31:0];
                6'd11: avs_readdata = symbol_reg[63:32];
                6'd12: avs_readdata = {{(32-QUANTITY_LEN){1'b0}}, bid_quote_qty_reg};
                6'd13: avs_readdata = {{(32-QUANTITY_LEN){1'b0}}, ask_quote_qty_reg};
                6'd14: avs_readdata = {28'd0, pnl_check_enable_reg, price_band_enable_reg, kill_switch_reg, trading_enable_reg};
                6'd15: avs_readdata = sw_order_time_reg[31:0];
                6'd16: avs_readdata = {16'd0, sw_order_time_reg[47:32]};
                6'd17: avs_readdata = best_bid_price;
                6'd18: avs_readdata = best_ask_price;
                6'd19: avs_readdata = {16'd0, stock_id,
                                       ask_reject_reason, bid_reject_reason,
                                       ask_reject_valid, bid_reject_valid,
                                       exec_valid, order_payload_valid,
                                       trading_valid, best_ask_valid, best_bid_valid};
                6'd20: avs_readdata = trading_bid_price;
                6'd21: avs_readdata = trading_ask_price;
                6'd22: avs_readdata = mark_price;
                6'd23: avs_readdata = {{(32-POSITION_LEN){position[POSITION_LEN-1]}}, position};
                6'd24: avs_readdata = day_pnl[31:0];
                6'd25: avs_readdata = day_pnl[63:32];
                6'd26: avs_readdata = mtm_total_pnl[31:0];
                6'd27: avs_readdata = mtm_total_pnl[63:32];
                6'd28: avs_readdata = inventory_value[31:0];
                6'd29: avs_readdata = inventory_value[63:32];
                6'd30: avs_readdata = {live_ask_qty, live_bid_qty};
                6'd31: avs_readdata = exec_price;
                6'd32: avs_readdata = last_order_payload[31:0];
                6'd33: avs_readdata = last_order_payload[63:32];
                6'd34: avs_readdata = last_order_payload[95:64];
                6'd35: avs_readdata = last_order_payload[127:96];
                6'd36: avs_readdata = last_order_payload[159:128];
                6'd37: avs_readdata = last_order_payload[191:160];
                6'd38: avs_readdata = last_order_payload[223:192];
                6'd39: avs_readdata = last_order_payload[255:224];
                6'd40: avs_readdata = last_order_payload[287:256];
                6'd41: avs_readdata = last_order_payload[319:288];
                6'd42: avs_readdata = last_order_payload[351:320];
                6'd43: avs_readdata = last_order_payload[383:352];
                6'd44: avs_readdata = last_order_payload[415:384];
                6'd45: avs_readdata = last_order_payload[447:416];
                6'd46: avs_readdata = last_order_payload[479:448];
                6'd47: avs_readdata = last_order_payload[511:480];
                6'd48: avs_readdata = last_order_payload[543:512];
                6'd49: avs_readdata = last_order_payload[575:544];
                6'd50: avs_readdata = last_order_payload[607:576];
                6'd51: avs_readdata = last_order_payload[639:608];
                6'd52: avs_readdata = last_order_payload[671:640];
                6'd53: avs_readdata = last_order_payload[703:672];
                6'd54: avs_readdata = last_order_payload[735:704];
                6'd55: avs_readdata = {16'd0, last_order_payload[751:736]};
                6'd56: avs_readdata = {14'd0, last_order_payload_valid, last_exec_valid, last_exec_side, last_exec_quantity};
                6'd57: avs_readdata = last_exec_order_id;
                6'd58: avs_readdata = order_payload_count;
                6'd59: avs_readdata = exec_count;
                6'd60: avs_readdata = bid_reject_count;
                6'd61: avs_readdata = ask_reject_count;
                6'd62: avs_readdata = {22'd0,
                                       last_ask_reject_valid, last_bid_reject_valid,
                                       last_ask_reject_reason, last_bid_reject_reason};
                6'd63: avs_readdata = BOOK_BASE_PRICE;
                default: avs_readdata = 32'h0;
            endcase
        end
    end

endmodule
