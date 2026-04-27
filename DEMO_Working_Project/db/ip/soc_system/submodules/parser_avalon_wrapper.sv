import ob_pkg::*;
module parser_avalon_wrapper #(
    parameter int MARKET_PAYLOAD_LEN = 288,
    parameter int OUCH_PAYLOAD_LEN   = 752,
    parameter int SYMBOL_LEN         = 64,
    parameter int POSITION_LEN       = 16,
    parameter int PNL_LEN            = 64,
    parameter int STOCK_LEN          = 16,
    parameter int MARKET_QTY_LEN     = 32,
    parameter int BOOK_BASE_PRICE    = 32'd2_200_000,
    parameter logic [SYMBOL_LEN-1:0] DEFAULT_SYMBOL = {"A","M","Z","N"," "," "," "," "},
    parameter logic [TOT_QUATITY_LEN-1:0] DEFAULT_BID_QTY = 16'd5,
    parameter logic [TOT_QUATITY_LEN-1:0] DEFAULT_ASK_QTY = 16'd5
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
    localparam int BOOK_PRICE_DIVISOR = (PRICE_LEN <= 16) ? 100 : 1;
    // Avalon write-side control registers.
    logic [MARKET_PAYLOAD_LEN-1:0] market_payload_reg;
    logic                          market_valid_pulse;
    logic                          market_valid_pulse_d1;
    logic                          soft_rst_n;
    logic                          combined_rst_n;
    logic [SYMBOL_LEN-1:0]         symbol_reg;
    logic [TOT_QUATITY_LEN-1:0]    bid_quote_qty_reg;
    logic [TOT_QUATITY_LEN-1:0]    ask_quote_qty_reg;
    logic                          trading_enable_reg;
    logic                          kill_switch_reg;
    logic                          price_band_enable_reg;
    logic                          pnl_check_enable_reg;
    logic [47:0]                   sw_order_time_reg;

    // HFT outputs.
    logic [STOCK_LEN-1:0]          stock_id;
    logic [FULL_PRICE_LEN-1:0]     best_bid_price;
    logic [FULL_PRICE_LEN-1:0]     best_ask_price;
    logic                          best_bid_valid;
    logic                          best_ask_valid;
    logic [FULL_PRICE_LEN-1:0]     trading_bid_price;
    logic [FULL_PRICE_LEN-1:0]     trading_ask_price;
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
    logic [FULL_PRICE_LEN-1:0]     exec_price;
    logic [TOT_QUATITY_LEN-1:0]    exec_quantity;
    logic [ORDERID_LEN-1:0]       exec_order_id;
    logic signed [POSITION_LEN-1:0] position;
    logic signed [PNL_LEN-1:0]     day_pnl;
    logic [TOT_QUATITY_LEN-1:0]    live_bid_qty;
    logic [TOT_QUATITY_LEN-1:0]    live_ask_qty;

    // One-cycle debug signals exported by the HFT top.
    logic [63:0]                   debug_parser_order_id;
    logic [31:0]                   debug_parser_quantity;
    logic                          debug_parser_side;
    logic [31:0]                   debug_parser_price;
    logic [1:0]                    debug_parser_action;
    logic                          debug_parser_valid;
    logic [STOCK_LEN-1:0]          debug_parser_stock_id;
    logic [47:0]                   debug_parser_timestamp;
    logic [ORDERID_LEN-1:0] debug_ob_in_order_id;
    logic [PRICE_LEN-1:0]          debug_ob_in_price;
    logic [QUANTITY_LEN-1:0] debug_ob_in_quantity;
    logic [1:0]                    debug_ob_in_action;
    logic                          debug_ob_in_valid;
    logic                          debug_ob_in_side;
    logic [1:0]                    debug_ob_event_action;
    logic [PRICE_LEN-1:0]          debug_ob_event_price;
    logic [QUANTITY_LEN-1:0] debug_ob_event_quantity;
    logic                          debug_ob_event_valid;
    logic                          debug_ob_event_side;
    logic [TOT_QUATITY_LEN-1:0] debug_best_bid_quantity;
    logic [TOT_QUATITY_LEN-1:0] debug_best_ask_quantity;

    // Latched debug / status registers so software does not miss pulses.
    logic [OUCH_PAYLOAD_LEN-1:0]   last_order_payload;
    logic                          last_order_payload_valid;
    logic                          last_exec_valid;
    logic                          last_exec_side;
    logic [FULL_PRICE_LEN-1:0]     last_exec_price;
    logic [TOT_QUATITY_LEN-1:0]       last_exec_quantity;
    logic [ORDERID_LEN-1:0]       last_exec_order_id;
    logic                          last_bid_reject_valid;
    logic [3:0]                    last_bid_reject_reason;
    logic                          last_ask_reject_valid;
    logic [3:0]                    last_ask_reject_reason;
    logic [31:0]                   order_payload_count;
    logic [31:0]                   exec_count;
    logic [31:0]                   bid_reject_count;
    logic [31:0]                   ask_reject_count;
    logic [5:0]                    debug_select_reg;
    logic [63:0]                   last_parser_order_id;
    logic [31:0]                   last_parser_quantity;
    logic                          last_parser_side;
    logic [31:0]                   last_parser_price;
    logic [1:0]                    last_parser_action;
    logic                          last_parser_valid;
    logic [STOCK_LEN-1:0]          last_parser_stock_id;
    logic [47:0]                   last_parser_timestamp;
    logic [ORDERID_LEN-1:0]        last_ob_in_order_id;
    logic [PRICE_LEN-1:0]          last_ob_in_price;
    logic [QUANTITY_LEN-1:0]       last_ob_in_quantity;
    logic [1:0]                    last_ob_in_action;
    logic                          last_ob_in_valid;
    logic                          last_ob_in_side;
    logic [1:0]                    last_ob_event_action;
    logic [PRICE_LEN-1:0]          last_ob_event_price;
    logic [QUANTITY_LEN-1:0] last_ob_event_quantity;
    logic                          last_ob_event_valid;
    logic                          last_ob_event_side;

    logic [FULL_PRICE_LEN-1:0]     mark_price;
    logic                          mark_price_valid;
    logic signed [PNL_LEN-1:0]     mtm_total_pnl;
    logic signed [PNL_LEN-1:0]     inventory_value;

    logic [PRICE_LEN-1:0]           parser_price_book;
    logic [QUANTITY_LEN-1:0]        parser_quantity_book;
    logic [63:0]                    parser_order_id;
    logic [31:0]                    parser_quantity;
    logic                           parser_side;
    logic [31:0]                    parser_price;
    logic [1:0]                     parser_action;
    logic                           parser_valid;
    logic [STOCK_LEN-1:0]           parser_stock_id;
    logic [47:0]                    parser_timestamp;

    function automatic signed [PNL_LEN-1:0] calc_total_pnl(
        input signed [PNL_LEN-1:0] day_pnl_in,
        input signed [POSITION_LEN-1:0] position_in,
        input logic [FULL_PRICE_LEN-1:0] mark_price_in
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


    function automatic [PRICE_LEN-1:0] scale_price_to_book(
        input logic [31:0] raw_price
    );
        integer scaled_price;
        begin
            scaled_price = raw_price / BOOK_PRICE_DIVISOR;
            if (scaled_price < 0)
                scale_price_to_book = '0;
            else if (scaled_price > ((1 << PRICE_LEN) - 1))
                scale_price_to_book = {PRICE_LEN{1'b1}};
            else
                scale_price_to_book = scaled_price[PRICE_LEN-1:0];
        end
    endfunction

    function automatic [QUANTITY_LEN-1:0] clamp_quantity_to_book(
        input logic [31:0] raw_quantity
    );
        begin
            if (raw_quantity > ((1 << QUANTITY_LEN) - 1))
                clamp_quantity_to_book = {QUANTITY_LEN{1'b1}};
            else
                clamp_quantity_to_book = raw_quantity[QUANTITY_LEN-1:0];
        end
    endfunction
        
    parser ps(
        .i_clk(clk),
        .i_rst_n(combined_rst_n),
        .i_payload(market_payload_reg),
        .i_valid(market_valid_pulse),
        .o_order_id(parser_order_id),
        .o_quantity(parser_quantity),
        .o_side(parser_side),
        .o_price(parser_price),
        .o_action(parser_action),
        .o_valid(parser_valid),
        .o_stock_id(parser_stock_id),
        .o_timestamp(parser_timestamp)
    );

    assign parser_price_book   = scale_price_to_book(parser_price);
    assign parser_quantity_book = clamp_quantity_to_book(parser_quantity);

    hft_single_stock_top #(
        .MARKET_PAYLOAD_LEN (MARKET_PAYLOAD_LEN),
        .OUCH_PAYLOAD_LEN   (OUCH_PAYLOAD_LEN),
        .SYMBOL_LEN         (SYMBOL_LEN),
        .POSITION_LEN       (POSITION_LEN),
        .PNL_LEN            (PNL_LEN),
        .STOCK_LEN          (STOCK_LEN),
        .MARKET_QTY_LEN     (MARKET_QTY_LEN),
        .BOOK_BASE_PRICE    (BOOK_BASE_PRICE)
    ) dut (
        .i_clk               (clk),
        .i_rst_n             (combined_rst_n),
        .i_order_id          (parser_order_id[ORDERID_LEN-1:0]),
        .i_quantity          (parser_quantity_book),
        .i_side              (parser_side),
        .i_price             (parser_price_book),
        .i_action            (parser_action),
        .i_valid             (parser_valid && parser_stock_id == STOCK_LEN'(1)),
        .i_stock_id          (parser_stock_id),
        .i_timestamp         (parser_timestamp),
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
        .o_live_ask_qty      (live_ask_qty),
        .o_debug_parser_order_id(debug_parser_order_id),
        .o_debug_parser_quantity(debug_parser_quantity),
        .o_debug_parser_side (debug_parser_side),
        .o_debug_parser_price(debug_parser_price),
        .o_debug_parser_action(debug_parser_action),
        .o_debug_parser_valid(debug_parser_valid),
        .o_debug_parser_stock_id(debug_parser_stock_id),
        .o_debug_parser_timestamp(debug_parser_timestamp),
        .o_debug_ob_in_order_id(debug_ob_in_order_id),
        .o_debug_ob_in_price(debug_ob_in_price),
        .o_debug_ob_in_quantity(debug_ob_in_quantity),
        .o_debug_ob_in_action(debug_ob_in_action),
        .o_debug_ob_in_valid(debug_ob_in_valid),
        .o_debug_ob_in_side(debug_ob_in_side),
        .o_debug_ob_event_action(debug_ob_event_action),
        .o_debug_ob_event_price(debug_ob_event_price),
        .o_debug_ob_event_quantity(debug_ob_event_quantity),
        .o_debug_ob_event_valid(debug_ob_event_valid),
        .o_debug_ob_event_side(debug_ob_event_side),
        .o_debug_best_bid_quantity(debug_best_bid_quantity),
        .o_debug_best_ask_quantity(debug_best_ask_quantity)
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
    //   63    : debug selector for read address 63
    //
    // Reads:
    //   0-16  : writeback / current config
    //   17-31 : live HFT state, P/L, counts
    //   32-55 : latched last OUCH payload words
    //   56-62 : latched last execution / reject details
    //   63    : selected latched parser/orderbook debug data
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            market_payload_reg      <= '0;
            market_valid_pulse      <= 1'b0;
            market_valid_pulse_d1   <= 1'b0;
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
            debug_select_reg        <= '0;
            last_parser_order_id    <= '0;
            last_parser_quantity    <= '0;
            last_parser_side        <= 1'b0;
            last_parser_price       <= '0;
            last_parser_action      <= '0;
            last_parser_valid       <= 1'b0;
            last_parser_stock_id    <= '0;
            last_parser_timestamp   <= '0;
            last_ob_in_order_id     <= '0;
            last_ob_in_price        <= '0;
            last_ob_in_quantity     <= '0;
            last_ob_in_action       <= '0;
            last_ob_in_valid        <= 1'b0;
            last_ob_in_side         <= 1'b0;
            last_ob_event_action    <= '0;
            last_ob_event_price     <= '0;
            last_ob_event_quantity  <= '0;
            last_ob_event_valid     <= 1'b0;
            last_ob_event_side      <= 1'b0;
        end else begin
            market_valid_pulse_d1 <= market_valid_pulse;
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
                    6'd12: bid_quote_qty_reg            <= avs_writedata[TOT_QUATITY_LEN-1:0];
                    6'd13: ask_quote_qty_reg            <= avs_writedata[TOT_QUATITY_LEN-1:0];
                    6'd14: begin
                        trading_enable_reg    <= avs_writedata[0];
                        kill_switch_reg       <= avs_writedata[1];
                        price_band_enable_reg <= avs_writedata[2];
                        pnl_check_enable_reg  <= avs_writedata[3];
                    end
                    6'd15: sw_order_time_reg[31:0]      <= avs_writedata;
                    6'd16: sw_order_time_reg[47:32]     <= avs_writedata[15:0];
                    6'd22: soft_rst_n                   <= 1'b0;
                    6'd63: debug_select_reg             <= avs_writedata[5:0];
                    default: begin end
                endcase
            end

            if (market_valid_pulse_d1) begin
                last_parser_order_id  <= parser_order_id;
                last_parser_quantity  <= parser_quantity;
                last_parser_side      <= parser_side;
                last_parser_price     <= parser_price;
                last_parser_action    <= parser_action;
                last_parser_valid     <= parser_valid;
                last_parser_stock_id  <= parser_stock_id;
                last_parser_timestamp <= parser_timestamp;
                last_ob_in_order_id   <= debug_ob_in_order_id;
                last_ob_in_price      <= debug_ob_in_price;
                last_ob_in_quantity   <= debug_ob_in_quantity;
                last_ob_in_action     <= debug_ob_in_action;
                last_ob_in_valid      <= debug_ob_in_valid;
                last_ob_in_side       <= debug_ob_in_side;
            end

            if (debug_ob_event_valid) begin
                last_ob_event_action   <= debug_ob_event_action;
                last_ob_event_price    <= debug_ob_event_price;
                last_ob_event_quantity <= debug_ob_event_quantity;
                last_ob_event_valid    <= 1'b1;
                last_ob_event_side     <= debug_ob_event_side;
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
                6'd12: avs_readdata = {{(32-TOT_QUATITY_LEN){1'b0}}, bid_quote_qty_reg};
                6'd13: avs_readdata = {{(32-TOT_QUATITY_LEN){1'b0}}, ask_quote_qty_reg};
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
                6'd63: begin
                    case (debug_select_reg)
                        6'd0:  avs_readdata = BOOK_BASE_PRICE;
                        6'd1:  avs_readdata = last_parser_order_id[31:0];
                        6'd2:  avs_readdata = last_parser_order_id[63:32];
                        6'd3:  avs_readdata = last_parser_quantity;
                        6'd4:  avs_readdata = last_parser_price;
                        6'd5:  avs_readdata = {27'd0, last_parser_action, last_parser_side, last_parser_valid};
                        6'd6:  avs_readdata = {{(32-STOCK_LEN){1'b0}}, last_parser_stock_id};
                        6'd7:  avs_readdata = last_parser_timestamp[31:0];
                        6'd8:  avs_readdata = {16'd0, last_parser_timestamp[47:32]};
                        6'd9:  avs_readdata = {{(32-ORDERID_LEN){1'b0}}, last_ob_in_order_id};
                        6'd10: avs_readdata = {{(32-PRICE_LEN){1'b0}}, last_ob_in_price};
                        6'd11: avs_readdata = {{(32-QUANTITY_LEN){1'b0}}, last_ob_in_quantity};
                        6'd12: avs_readdata = {27'd0, last_ob_in_action, last_ob_in_side, last_ob_in_valid};
                        6'd13: avs_readdata = {{(32-PRICE_LEN){1'b0}}, last_ob_event_price};
                        6'd14: avs_readdata = {{(32-QUANTITY_LEN){1'b0}}, last_ob_event_quantity};
                        6'd15: avs_readdata = {27'd0, last_ob_event_action, last_ob_event_side, last_ob_event_valid};
                        6'd16: avs_readdata = {{(32-TOT_QUATITY_LEN){1'b0}}, debug_best_bid_quantity};
                        6'd17: avs_readdata = {{(32-TOT_QUATITY_LEN){1'b0}}, debug_best_ask_quantity};
                        6'd18: avs_readdata = order_payload_count;
                        6'd19: avs_readdata = exec_count;
                        default: avs_readdata = 32'h0;
                    endcase
                end
                default: avs_readdata = 32'h0;
            endcase
        end
    end

endmodule
