// Simple inventory tracker for one stock.
// When one of our quotes fills, execution tracker sends a one-cycle pulse
// with side, price, and quantity. We keep running inventory position and
// day cash P/L for use by risk management and trading logic (maybe)
module inventory_tracker #(
    parameter int PRICE_LEN = 32,
    parameter int QUANTITY_LEN = 16,
    parameter int POSITION_LEN = 16,
    parameter int PNL_LEN = 64,
    parameter logic signed [POSITION_LEN-1:0] STARTING_POSITION = 16'sd0
) (
    input  logic                            i_clk,
    input  logic                            i_rst_n,
    // Fill from execution tracker
    input  logic                            i_exec_valid,
    input  logic                            i_exec_side,      // 0 = buy fill, 1 = sell fill
    input  logic [PRICE_LEN-1:0]            i_exec_price,
    input  logic [QUANTITY_LEN-1:0]         i_exec_quantity,
    // Best current mark price used for mark-to-market inventory valuation
    input  logic [PRICE_LEN-1:0]            i_mark_price,
    // Current position and day cash Profit/loss
    output logic signed [POSITION_LEN-1:0]  o_position,
    output logic signed [PNL_LEN-1:0]       o_day_pnl,
    output logic signed [PNL_LEN-1:0]       o_total_pnl
);

localparam int MARK_PRICE_LEN = PRICE_LEN + 1;
localparam int MTM_LEN        = MARK_PRICE_LEN + POSITION_LEN + 1;

logic signed [POSITION_LEN-1:0] position_reg;
logic signed [PNL_LEN-1:0]      day_pnl_reg;
logic signed [POSITION_LEN:0]   qty_signed;
logic signed [PNL_LEN-1:0]      exec_notional_pnl;
logic [PRICE_LEN-1:0]           mark_price_reg;
logic signed [POSITION_LEN:0]   position_ext;
logic signed [MARK_PRICE_LEN-1:0] mark_price_ext;
logic signed [MTM_LEN-1:0]      inventory_value;
logic signed [PNL_LEN-1:0]      total_pnl_comb;

// notional meaning we care about the cash value of the fill, not just the shares. For example, a buy fill of 100 shares at $10 has a notional of $1000, which is what we care about for P/L calculations.
// Quantity and fill notional widened to signed values for the math
assign qty_signed = $signed({1'b0, i_exec_quantity});
assign exec_notional_pnl = $signed(i_exec_price * i_exec_quantity);
assign position_ext = $signed(position_reg);
assign mark_price_ext = $signed({1'b0, mark_price_reg});
assign inventory_value = position_ext * mark_price_ext;
assign total_pnl_comb = day_pnl_reg
                      + $signed({{(PNL_LEN-MTM_LEN){inventory_value[MTM_LEN-1]}}, inventory_value});

always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        position_reg <= STARTING_POSITION;
        day_pnl_reg  <= '0;
        mark_price_reg <= '0;
    end
    else begin
        if (i_mark_price != '0)
            mark_price_reg <= i_mark_price;

        if (i_exec_valid) begin
            if (!i_exec_side) begin
                // Buy fill: add shares, spend cash.
                position_reg <= position_reg + qty_signed[POSITION_LEN-1:0];
                day_pnl_reg  <= day_pnl_reg - exec_notional_pnl;
            end
            else begin
                // Sell fill: remove shares, receive cash.
                position_reg <= position_reg - qty_signed[POSITION_LEN-1:0];
                day_pnl_reg  <= day_pnl_reg + exec_notional_pnl;
            end
        end
    end
end

assign o_position = position_reg;
assign o_day_pnl  = day_pnl_reg;
assign o_total_pnl = total_pnl_comb;

endmodule
