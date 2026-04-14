// Risk manager module, takes in potential quotes from trading logic and checks them against various risk rules before 
// allowing them to go order generator to be sent to the exchange. This acts as a final firewall to prevent bad
// quotes from reaching the exchange and stops from losing too much money or taking on too much risk. 
module risk_manager (
    input  logic               i_clk,
    input  logic               i_rst_n,
    // basic kill switchs and check enables, we may not use but added just in case. Can just assign to 1 or 0 for now. 
    input  logic               i_trading_enable,
    input  logic               i_kill_switch,
    input  logic               i_price_band_enable,
    input  logic               i_pnl_check_enable,
    // Comes from inventory so we now how much stock we have and how much money we lost or made on day. 
    input  logic signed [15:0] i_inventory_position,
    input  logic signed [63:0] i_day_pnl,
    // Comes from execution tracker so we know how much stock is already sitting in the market on each side.
    input  logic [15:0]        i_live_bid_qty,
    input  logic [15:0]        i_live_ask_qty,
    // From trading logic, the ask or bid quote that we want to attempt to send to exhange. 
    input  logic               i_quote_valid,
    input  logic               i_quote_side,       // 0 = bid, 1 = ask
    input  logic [31:0]        i_quote_price,
    input  logic [15:0]        i_quote_quantity,
    input  logic [31:0]        i_reference_price, //midpoint should be from trading logic
    // Outputs that go to order generator if quote is gonna make money. 
    output logic               o_quote_valid,
    output logic               o_quote_side,
    output logic [31:0]        o_quote_price,
    output logic [15:0]        o_quote_quantity,
    // information for if quote is rejected, for debug and verification purposes.
    output logic               o_reject_valid,
    output logic [3:0]         o_reject_reason
    // I think I want to add an output that will send to order generator, that would kill our market quotes,
    // so like if that signal is high, it would send out a cancel for our quotes if it is not filled. 
);

// IF we change order_gen & execution tracker to have 2 or more ask and bid quotes out at once, then we will need to add
// changes to this and more checks for risk manager to verify, espcially that our quotes in market & new quote will not 
// exceed our current inventory position of the stock. Also will be others to change but that is optimization problem i guess

// Most of these can be changed if need but set to basic values for now. 
localparam signed [15:0] MAX_LONG_POSITION      = 16'sd200;
localparam signed [15:0] MAX_SHORT_POSITION     = 16'sd200;
localparam        [15:0] MAX_QUOTE_QTY          = 16'd100;
localparam        [31:0] MAX_PRICE_DELTA        = 32'd10;
localparam signed [63:0]  MAX_DAILY_LOSS        = 64'sd500000;
localparam [48:0] MAX_NOTIONAL_EXPOSURE         = 49'd10000;
localparam int RISK_POS_LEN   = 17;  // one bit wider than 16-bit position/qty
localparam int NOTIONAL_LEN   = 49;  // 32-bit price * 17-bit position
// Reject reason codes for debug stuff
localparam [3:0] REJECT_NONE        = 4'd0;
localparam [3:0] REJECT_DISABLED    = 4'd1;
localparam [3:0] REJECT_MAX_LONG    = 4'd2;
localparam [3:0] REJECT_MAX_SHORT   = 4'd3;
localparam [3:0] REJECT_QUOTE_SIZE  = 4'd4;
localparam [3:0] REJECT_PRICE_BAND  = 4'd5;
localparam [3:0] REJECT_DAILY_LOSS  = 4'd7;
localparam [3:0] REJECT_EXPOSURE    = 4'd8;

// internal wires
logic        quote_vld_n;
logic        quote_side_n;
logic [31:0] quote_px_n;
logic [15:0] quote_qty_n;
logic        rej_vld_n;
logic [3:0]  rej_reason_n;
logic good_quote;
logic signed [RISK_POS_LEN-1:0] short_lim_ext;
logic signed [RISK_POS_LEN-1:0] qty_ext;
logic signed [RISK_POS_LEN-1:0] long_pos_n;
logic signed [RISK_POS_LEN-1:0] short_pos_n;
logic signed [RISK_POS_LEN-1:0] inv_ext;
logic signed [RISK_POS_LEN-1:0] live_bid_qty_ext;
logic signed [RISK_POS_LEN-1:0] live_ask_qty_ext;
logic signed [RISK_POS_LEN-1:0] long_lim_ext;
logic [31:0] px_diff;
logic [RISK_POS_LEN-1:0] long_abs;
logic [RISK_POS_LEN-1:0] short_abs;
logic [RISK_POS_LEN-1:0] worst_pos;
logic bad_disable;
logic bad_loss;
logic bad_size;
logic bad_price;
logic bad_long;
logic bad_short;
logic bad_exposure;
logic [NOTIONAL_LEN-1:0] proj_notional;

always_comb begin
    // default to no quote and no reject each cycle
    quote_vld_n      = 1'b0;
    quote_side_n     = i_quote_side;
    quote_px_n       = i_quote_price;
    quote_qty_n      = i_quote_quantity;
    rej_vld_n        = 1'b0;
    rej_reason_n     = REJECT_NONE;
    good_quote       = 1'b0;
    // sign stuff so math works correctly 
    inv_ext       = $signed({i_inventory_position[15], i_inventory_position});
    long_lim_ext  = $signed({MAX_LONG_POSITION[15], MAX_LONG_POSITION});
    short_lim_ext = $signed({MAX_SHORT_POSITION[15], MAX_SHORT_POSITION});
    live_bid_qty_ext = $signed({1'b0, i_live_bid_qty});
    live_ask_qty_ext = $signed({1'b0, i_live_ask_qty});
    qty_ext       = $signed({1'b0, i_quote_quantity});
    // We now care about our current inventory plus all stock we already have
    // resting in the market on each side, plus this new quote we want to add.
    long_pos_n  = inv_ext + live_bid_qty_ext;
    short_pos_n = inv_ext - live_ask_qty_ext;

    if (i_quote_valid) begin
        if (!i_quote_side)
            long_pos_n = inv_ext + live_bid_qty_ext + qty_ext;
        else
            short_pos_n = inv_ext - live_ask_qty_ext - qty_ext;
    end
    // gets absolute distance from quote and midpoint for price band check
    if (i_quote_price >= i_reference_price)
        px_diff = i_quote_price - i_reference_price;
    else
        px_diff = i_reference_price - i_quote_price;
    // Absolute position magnitudez
    if (long_pos_n < 0)
        long_abs = -long_pos_n;
    else
        long_abs = long_pos_n;
    if (short_pos_n < 0)
        short_abs = -short_pos_n;
    else
        short_abs = short_pos_n;
    if (long_abs >= short_abs)
        worst_pos = long_abs;
    else
        worst_pos = short_abs;

    proj_notional = worst_pos * i_reference_price;
    // Rule and stuff. Not all used right now but added for future expansion if we wanna. 
    bad_disable  = !i_trading_enable || i_kill_switch;
    bad_loss     = i_pnl_check_enable && (i_day_pnl <= -MAX_DAILY_LOSS);
    bad_size     = (i_quote_quantity == 16'd0) || (i_quote_quantity > MAX_QUOTE_QTY);
    bad_price    = i_price_band_enable && (px_diff > MAX_PRICE_DELTA);
    bad_long     = (long_pos_n > long_lim_ext);
    bad_short    = (short_pos_n < -short_lim_ext);
    bad_exposure = (proj_notional > MAX_NOTIONAL_EXPOSURE);

    // check rules in priority order, asign reasons for these as well for debug verifications. 
    if (i_quote_valid) begin
        if (bad_disable) begin
            rej_vld_n    = 1'b1;
            rej_reason_n = REJECT_DISABLED;
        end
        else if (bad_loss) begin
            rej_vld_n    = 1'b1;
            rej_reason_n = REJECT_DAILY_LOSS;
        end
        else if (bad_size) begin
            rej_vld_n    = 1'b1;
            rej_reason_n = REJECT_QUOTE_SIZE;
        end
        else if (bad_price) begin
            rej_vld_n    = 1'b1;
            rej_reason_n = REJECT_PRICE_BAND;
        end
        else if (bad_long) begin
            rej_vld_n    = 1'b1;
            rej_reason_n = REJECT_MAX_LONG;
        end
        else if (bad_short) begin
            rej_vld_n    = 1'b1;
            rej_reason_n = REJECT_MAX_SHORT;
        end
        else if (bad_exposure) begin
            rej_vld_n    = 1'b1;
            rej_reason_n = REJECT_EXPOSURE;
        end
        else begin
            // quote is good to go to market
            good_quote    = 1'b1;
            quote_vld_n   = 1'b1;
            quote_side_n  = i_quote_side;
            quote_px_n    = i_quote_price;
            quote_qty_n   = i_quote_quantity;
        end
    end
end
// Flops for outputs.
always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        o_quote_valid        <= 1'b0;
        o_quote_side         <= 1'b0;
        o_quote_price        <= '0;
        o_quote_quantity     <= '0;
        o_reject_valid       <= 1'b0;
        o_reject_reason      <= REJECT_NONE;
    end
    else begin
        o_quote_valid        <= quote_vld_n;
        o_quote_side         <= quote_side_n;
        o_quote_price        <= quote_px_n;
        o_quote_quantity     <= quote_qty_n;
        o_reject_valid       <= rej_vld_n;
        o_reject_reason      <= rej_reason_n;
    end
end
endmodule
