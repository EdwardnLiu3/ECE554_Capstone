module tl_top
    import ob_pkg::*;
(
    input  logic                 i_clk,
    input  logic                 i_rst_n,
    input  logic [PRICE_LEN-1:0] i_best_bid,
    input  logic [PRICE_LEN-1:0] i_best_ask,
    input  logic [47:0]          i_order_time,
    input  logic                 i_price_valid,
    input  logic                 i_trade_valid,
    input  logic                 i_trade_side,   // 0 = buy, 1 = sell
    input  logic [15:0]          i_trade_qty,
    input  logic [15:0]          i_base_bid_qty,
    input  logic [15:0]          i_base_ask_qty,

    output logic [PRICE_LEN-1:0] o_bid_price,
    output logic [PRICE_LEN-1:0] o_ask_price,
    output logic [15:0]          o_bid_quantity,
    output logic [15:0]          o_ask_quantity,
    // output logic                 o_order_type,// AS always quotes both sides
    output logic                 o_valid
);

    localparam [15:0] GAMMA_Q016  = 16'h199A;   // Q0.16  = 0.1000
    localparam [15:0] GAMMA_Q88   = 16'h001A;   // Q8.8   = 0.1016 (26/256)
    localparam [15:0] K_Q88       = 16'h0180;   // Q8.8   = 1.5    (384/256)
    localparam [15:0] EWMA_LAMBDA = 16'hFAE1;   // Q0.16  = 0.9800 (64225/65536)
    localparam [31:0] MARKET_DUR_DIV = 32'd357_055_664;   // (close - open) in ns >> 16 = 23,400,000,000,000 / 65,536

    logic [PRICE_LEN-1:0] mid_price;
    logic [PRICE_LEN:0]   mid_price_sum;
    assign mid_price_sum = {1'b0, i_best_bid} + {1'b0, i_best_ask};
    assign mid_price = mid_price_sum[PRICE_LEN:1];

    logic [47:0] T_sub_t;   // ns

    tl_time tl_time_inst (
        .clk        (i_clk),
        .rst_n      (i_rst_n),
        .order_time (i_order_time),
        .T_sub_t    (T_sub_t)
    );

    logic [47:0] sigma_sq;   // Q32.16
    logic        sigma_valid;

    volatility_ewma vol_inst (
        .clk         (i_clk),
        .rst_n       (i_rst_n),
        .lambda      (EWMA_LAMBDA),
        .price_valid (i_price_valid),
        .mid_price   (mid_price),
        .sigma_out   (sigma_sq),
        .sigma_valid (sigma_valid)
    );

    logic signed [15:0] q;

    inventory inv_inst (
        .clk        (i_clk),
        .rst_n      (i_rst_n),
        .buy_valid  (i_trade_valid & ~i_trade_side),
        .sell_valid (i_trade_valid &  i_trade_side),
        .qty        (i_trade_qty),
        .q          (q)
    );

    logic [31:0] time_frac;   // Q16.16
    logic        div_t_done, div_t_err;

    divider_q16 #(.WIDTH(32), .FRAC_BITS(16)) div_t_inst (
        .clk      (i_clk),
        .rst      (~i_rst_n),
        .start    (i_price_valid),
        .dividend (T_sub_t[47:16]),
        .divisor  (MARKET_DUR_DIV),
        .quotient (time_frac),
        .done     (div_t_done),
        .error    (div_t_err)
    );

    logic rst_n_prev;
    logic startup_pulse;
    always_ff @(posedge i_clk) begin
        if (!i_rst_n)
            rst_n_prev <= 1'b0;
        else
            rst_n_prev <= i_rst_n;
    end
    assign startup_pulse = i_rst_n & ~rst_n_prev;

    logic [15:0] gamma_k_ratio;   // Q8.8
    logic        div_gk_done, div_gk_err;

    divider_q16 #(.WIDTH(16), .FRAC_BITS(8)) div_gk_inst (
        .clk      (i_clk),
        .rst      (~i_rst_n),
        .start    (startup_pulse),
        .dividend (GAMMA_Q88),
        .divisor  (K_Q88),
        .quotient (gamma_k_ratio),
        .done     (div_gk_done),
        .error    (div_gk_err)
    );

    logic [15:0] one_plus_ratio;   // Q8.8
    logic [15:0] ln_result;        // Q8.8
    logic        ln_valid;

    assign one_plus_ratio = gamma_k_ratio + 16'h0100;

    ln_calc #(.INT_BITS(8), .FRAC_BITS(8)) ln_inst (
        .x_in   (one_plus_ratio),
        .ln_out (ln_result),
        .valid  (ln_valid)
    );

    logic [15:0] spread_price_Q88;   // Q8.8
    logic        div_sp_done, div_sp_err;
    logic [15:0] spread_price;
    logic        spread_ready;

    divider_q16 #(.WIDTH(16), .FRAC_BITS(8)) div_sp_inst (
        .clk      (i_clk),
        .rst      (~i_rst_n),
        .start    (div_gk_done & ln_valid & ~div_gk_err),
        .dividend (ln_result),
        .divisor  (GAMMA_Q88),
        .quotient (spread_price_Q88),
        .done     (div_sp_done),
        .error    (div_sp_err)
    );

    always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
            spread_price <= '0;
            spread_ready <= 1'b0;
        end else if (div_sp_done && !div_sp_err) begin
            spread_price <= spread_price_Q88;
            spread_ready <= 1'b1;
        end
    end

    logic [31:0]        gamma_sigma;        // Q16.16  stage 1
    logic [31:0]        gamma_sigma_time;   // Q16.16  stage 2
    logic signed [47:0] inv_skew_full;      //         stage 3
    logic signed [PRICE_LEN:0] reservation;      //     stage 4
    logic signed [PRICE_LEN:0] reservation_next; //     stage 4 comb result
    logic [PRICE_LEN-1:0]      market_spread_ticks;
    logic [PRICE_LEN-1:0]      model_spread_ticks;
    logic [PRICE_LEN-1:0]      bid_offset_ticks;
    logic [PRICE_LEN-1:0]      ask_offset_ticks;
    logic signed [PRICE_LEN:0] bid_price_next;
    logic signed [PRICE_LEN:0] ask_price_next;
    logic [PRICE_LEN-1:0]      bid_requote_delta;
    logic [PRICE_LEN-1:0]      ask_requote_delta;
    logic                      quote_changed;
    logic                      publish_quote;
    logic                      refresh_quote_pending;
    logic [PRICE_LEN-1:0]      last_published_bid_price;
    logic [PRICE_LEN-1:0]      last_published_ask_price;
    logic s1_valid, s2_valid, s3_valid;
    logic [PRICE_LEN-1:0] s1_mid, s2_mid, s3_mid;

    // Stage 1: γ · σ²
    always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
            gamma_sigma <= '0;
            s1_valid    <= 1'b0;
            s1_mid      <= '0;
        end else begin
            gamma_sigma <= (GAMMA_Q016 * sigma_sq) >> 16;   // Q16.16
            s1_valid    <= div_t_done && !div_t_err && spread_ready;
            s1_mid      <= mid_price;
        end
    end

    // Stage 2: γ · σ² · T_frac
    always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
            gamma_sigma_time <= '0;
            s2_valid         <= 1'b0;
            s2_mid           <= '0;
        end else begin
            gamma_sigma_time <= (gamma_sigma * time_frac) >> 16;   // Q16.16
            s2_valid         <= s1_valid;
            s2_mid           <= s1_mid;
        end
    end

    // Stage 3: q · γ · σ² · T_frac
    always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
            inv_skew_full <= '0;
            s3_valid      <= 1'b0;
            s3_mid        <= '0;
        end else begin
            inv_skew_full <= $signed({{16{q[15]}}, q}) * $signed({1'b0, gamma_sigma_time});
            s3_valid      <= s2_valid;
            s3_mid        <= s2_mid;
        end
    end

    // Stage 4: reservation = mid - inv_skew
    logic [7:0] model_spread_ticks_u8;
    logic signed [16:0] q_ext;
    logic [16:0] q_abs;
    logic [7:0] passive_buffer_ticks_u8;
    logic [7:0] inventory_widen_ticks_u8;
    logic [7:0] bid_inventory_widen_ticks_u8;
    logic [7:0] ask_inventory_widen_ticks_u8;
    logic [3:0] inventory_size_skew_u4;
    logic [7:0] inventory_price_skew_ticks_u8;
    logic [15:0] bid_quantity_next;
    logic [15:0] ask_quantity_next;
    always_comb begin
        q_ext = {q[15], q};
        if (q_ext < 0)
            q_abs = -q_ext;
        else
            q_abs = q_ext;

        // Convert the model spread to whole ticks with rounding instead of truncation.
        model_spread_ticks_u8 = spread_price[15:8] + {7'b0, spread_price[7]};
        if (spread_ready && (model_spread_ticks_u8 == 8'd0))
            model_spread_ticks_u8 = 8'd1;
        if (spread_ready)
            passive_buffer_ticks_u8 = model_spread_ticks_u8;
        else
            passive_buffer_ticks_u8 = 8'd1;

        // Back off gradually as inventory grows to avoid leaning into risk.
        if (q_abs >= 17'd128)
            inventory_widen_ticks_u8 = 8'd4;
        else if (q_abs >= 17'd96)
            inventory_widen_ticks_u8 = 8'd3;
        else if (q_abs >= 17'd64)
            inventory_widen_ticks_u8 = 8'd2;
        else if (q_abs >= 17'd32)
            inventory_widen_ticks_u8 = 8'd1;
        else
            inventory_widen_ticks_u8 = 8'd0;

        bid_inventory_widen_ticks_u8 = 8'd0;
        ask_inventory_widen_ticks_u8 = 8'd0;
        if (q_ext > 0)
            bid_inventory_widen_ticks_u8 = inventory_widen_ticks_u8;
        else if (q_ext < 0)
            ask_inventory_widen_ticks_u8 = inventory_widen_ticks_u8;

        if (q_abs >= 17'd128)
            inventory_size_skew_u4 = 4'd4;
        else if (q_abs >= 17'd96)
            inventory_size_skew_u4 = 4'd3;
        else if (q_abs >= 17'd64)
            inventory_size_skew_u4 = 4'd2;
        else if (q_abs >= 17'd24)
            inventory_size_skew_u4 = 4'd1;
        else
            inventory_size_skew_u4 = 4'd0;

        if (q_abs >= 17'd128)
            inventory_price_skew_ticks_u8 = 8'd3;
        else if (q_abs >= 17'd96)
            inventory_price_skew_ticks_u8 = 8'd2;
        else if (q_abs >= 17'd48)
            inventory_price_skew_ticks_u8 = 8'd1;
        else
            inventory_price_skew_ticks_u8 = 8'd0;

        bid_offset_ticks = (market_spread_ticks >> 1)
                         + {{(PRICE_LEN-8){1'b0}}, passive_buffer_ticks_u8}
                         + {{(PRICE_LEN-8){1'b0}}, bid_inventory_widen_ticks_u8};
        ask_offset_ticks = (market_spread_ticks - (market_spread_ticks >> 1))
                         + {{(PRICE_LEN-8){1'b0}}, passive_buffer_ticks_u8}
                         + {{(PRICE_LEN-8){1'b0}}, ask_inventory_widen_ticks_u8};
        if (q_ext > 0) begin
            bid_offset_ticks = bid_offset_ticks
                             + {{(PRICE_LEN-8){1'b0}}, inventory_price_skew_ticks_u8};
            if (ask_offset_ticks > {{(PRICE_LEN-8){1'b0}}, inventory_price_skew_ticks_u8})
                ask_offset_ticks = ask_offset_ticks
                                 - {{(PRICE_LEN-8){1'b0}}, inventory_price_skew_ticks_u8};
            else
                ask_offset_ticks = {{(PRICE_LEN-1){1'b0}}, 1'b1};
        end
        else if (q_ext < 0) begin
            ask_offset_ticks = ask_offset_ticks
                             + {{(PRICE_LEN-8){1'b0}}, inventory_price_skew_ticks_u8};
            if (bid_offset_ticks > {{(PRICE_LEN-8){1'b0}}, inventory_price_skew_ticks_u8})
                bid_offset_ticks = bid_offset_ticks
                                 - {{(PRICE_LEN-8){1'b0}}, inventory_price_skew_ticks_u8};
            else
                bid_offset_ticks = {{(PRICE_LEN-1){1'b0}}, 1'b1};
        end

        bid_quantity_next = i_base_bid_qty;
        ask_quantity_next = i_base_ask_qty;
        if (q_ext > 0) begin
            ask_quantity_next = i_base_ask_qty + {{12{1'b0}}, inventory_size_skew_u4};
            if (i_base_bid_qty > {{12{1'b0}}, inventory_size_skew_u4})
                bid_quantity_next = i_base_bid_qty - {{12{1'b0}}, inventory_size_skew_u4};
            else
                bid_quantity_next = 16'd1;
        end
        else if (q_ext < 0) begin
            bid_quantity_next = i_base_bid_qty + {{12{1'b0}}, inventory_size_skew_u4};
            if (i_base_ask_qty > {{12{1'b0}}, inventory_size_skew_u4})
                ask_quantity_next = i_base_ask_qty - {{12{1'b0}}, inventory_size_skew_u4};
            else
                ask_quantity_next = 16'd1;
        end
    end
    assign model_spread_ticks = {{(PRICE_LEN-8){1'b0}}, model_spread_ticks_u8};
    assign market_spread_ticks = (i_best_ask > i_best_bid) ? (i_best_ask - i_best_bid)
                                                           : {{(PRICE_LEN-1){1'b0}}, 1'b1};
    assign reservation_next = $signed({1'b0, s3_mid})
                            - $signed({{(PRICE_LEN-16){inv_skew_full[32]}}, inv_skew_full[32:16]});
    assign bid_price_next = reservation_next - $signed({1'b0, bid_offset_ticks});
    assign ask_price_next = reservation_next + $signed({1'b0, ask_offset_ticks});
    assign bid_requote_delta = (bid_price_next[PRICE_LEN-1:0] >= last_published_bid_price)
                             ? (bid_price_next[PRICE_LEN-1:0] - last_published_bid_price)
                             : (last_published_bid_price - bid_price_next[PRICE_LEN-1:0]);
    assign ask_requote_delta = (ask_price_next[PRICE_LEN-1:0] >= last_published_ask_price)
                             ? (ask_price_next[PRICE_LEN-1:0] - last_published_ask_price)
                             : (last_published_ask_price - ask_price_next[PRICE_LEN-1:0]);
    assign quote_changed = (bid_requote_delta >= 32'd2)
                        || (ask_requote_delta >= 32'd2);
    assign publish_quote = s3_valid
                        && (((last_published_bid_price == '0) && (last_published_ask_price == '0))
                         || refresh_quote_pending
                         || quote_changed);

    always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
            reservation  <= '0;
            o_bid_price  <= '0;
            o_ask_price  <= '0;
            o_bid_quantity <= 16'd1;
            o_ask_quantity <= 16'd1;
            o_valid      <= 1'b0;
            refresh_quote_pending <= 1'b0;
            last_published_bid_price <= '0;
            last_published_ask_price <= '0;
        end else begin
            reservation  <= reservation_next;
            o_valid      <= publish_quote;
            if (i_trade_valid)
                refresh_quote_pending <= 1'b1;
            if (publish_quote)
                refresh_quote_pending <= 1'b0;
            if (s3_valid) begin
                o_bid_price  <= bid_price_next[PRICE_LEN-1:0];
                o_ask_price  <= ask_price_next[PRICE_LEN-1:0];
                o_bid_quantity <= bid_quantity_next;
                o_ask_quantity <= ask_quantity_next;
            end
            if (publish_quote) begin
                last_published_bid_price <= bid_price_next[PRICE_LEN-1:0];
                last_published_ask_price <= ask_price_next[PRICE_LEN-1:0];
            end

            // AS always quotes both sides — buy/sell decision is made by the market
            // if ($signed(reservation) > $signed({1'b0, s3_mid}))
            //     o_order_type <= 2'b01;
            // else if ($signed(reservation) < $signed({1'b0, s3_mid}))
            //     o_order_type <= 2'b10;
            // else
            //     o_order_type <= 2'b11;
        end
    end

endmodule

