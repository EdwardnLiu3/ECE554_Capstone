module tl_top
    import ob_pkg::*;
#(
    parameter [15:0] Q_BASE         = 16'd5,    // least quantity willing to trade
    parameter [15:0] Q_LIMIT        = 16'd50,   // max quantity willing to trade
    parameter        QTY_SKEW_SHIFT = 1        
)(
    input  logic                 i_clk,
    input  logic                 i_rst_n,
    input  logic [PRICE_LEN-1:0] i_best_bid,
    input  logic [PRICE_LEN-1:0] i_best_ask,
    input  logic [47:0]          i_order_time,
    input  logic                 i_price_valid,
    input  logic                 i_trade_valid,
    input  logic                 i_trade_side,   // 0 = buy, 1 = sell
    input  logic [15:0]          i_trade_qty,

    output logic [PRICE_LEN-1:0] o_bid_price,
    output logic [PRICE_LEN-1:0] o_ask_price,
    output logic [15:0]          o_bid_qty,
    output logic [15:0]          o_ask_qty,
    // output logic                 o_order_type,// AS always quotes both sides
    output logic                 o_valid
);

    localparam [15:0] GAMMA_Q016  = 16'h199A;   // Q0.16  = 0.1000
    localparam [15:0] GAMMA_Q88   = 16'h001A;   // Q8.8   = 0.1016 (26/256)
    localparam [15:0] K_Q88       = 16'h0180;   // Q8.8   = 1.5    (384/256)
    localparam [15:0] EWMA_LAMBDA = 16'hFAE1;   // Q0.16  = 0.9800 (64225/65536)
    localparam [31:0] MARKET_DUR_DIV = 32'd357_055_664;   // (close - open) in ns >> 16 = 23,400,000,000,000 / 65,536

    logic [PRICE_LEN-1:0] mid_price;
    assign mid_price = (i_best_bid + i_best_ask) >> 1;

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
        .dividend (T_sub_t[47:16]), //32 integer bits of Q32.16
        .divisor  (MARKET_DUR_DIV),
        .quotient (time_frac),
        .done     (div_t_done),
        .error    (div_t_err)
    );

    logic rst_n_prev;
    logic startup_pulse;
    always_ff @(posedge i_clk) rst_n_prev <= i_rst_n;
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

    logic [31:0]        gamma_sigma;       // Q16.16  stage 1
    logic [31:0]        gamma_sigma_time;   // Q16.16  stage 2
    logic signed [47:0] inv_skew_full;      //         stage 3
    logic signed [16:0] reservation;        //         stage 4
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
            inv_skew_full <= $signed({{16{q[15]}}, q}) * $signed({1'b0, gamma_sigma_time}); //Q48.16
            s3_valid      <= s2_valid;
            s3_mid        <= s2_mid;
        end
    end

    // Stage 4: reservation = mid - inv_skew, quantity skew
    logic [7:0] spread_cents;
    assign spread_cents = (spread_price * 8'd100) >> 8;   // Q8.8 integer part

    logic signed [15:0] inv_skew_qty; 
    logic signed [16:0] bid_qty_raw;
    logic signed [16:0] ask_qty_raw;

    assign inv_skew_qty = $signed(inv_skew_full[31:16]) >>> QTY_SKEW_SHIFT; //shift if want to change effectiveness since using price skew
    assign bid_qty_raw  = $signed({1'b0, Q_BASE}) - $signed(inv_skew_qty);
    assign ask_qty_raw  = $signed({1'b0, Q_BASE}) + $signed(inv_skew_qty);

    always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
            o_bid_price  <= '0;
            o_ask_price  <= '0;
            o_bid_qty    <= '0;
            o_ask_qty    <= '0;
            o_valid      <= 1'b0;
        end else begin
            reservation  = $signed({1'b0, s3_mid}) - $signed(inv_skew_full[31:16]);
            o_valid      <= s3_valid;
            o_bid_price  <= reservation[PRICE_LEN-1:0] - spread_cents;
            o_ask_price  <= reservation[PRICE_LEN-1:0] + spread_cents;

            o_bid_qty    <= (bid_qty_raw[16]) ? 16'd0 : (bid_qty_raw[15:0] > Q_LIMIT) ? Q_LIMIT : bid_qty_raw[15:0];
            o_ask_qty    <= (ask_qty_raw[16]) ? 16'd0 : (ask_qty_raw[15:0] > Q_LIMIT) ? Q_LIMIT :ask_qty_raw[15:0];
        end
    end

endmodule
