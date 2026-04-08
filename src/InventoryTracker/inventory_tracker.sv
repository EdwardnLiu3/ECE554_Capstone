// Simple inventory tracker for one stock.
// When one of our quotes fills, execution tracker sends a one-cycle pulse
// with side, price, and quantity. We keep running inventory position and
// day cash P/L for use by risk management and trading logic (maybe)
module inventory_tracker #(
    parameter int PRICE_LEN = 32,
    parameter int QUANTITY_LEN = 16,
    parameter int POSITION_LEN = 16,
    parameter int PNL_LEN = 64,
    parameter logic signed [POSITION_LEN-1:0] STARTING_POSITION = 16'sd100
) (
    input  logic                            i_clk,
    input  logic                            i_rst_n,
    // Fill from execution tracker
    input  logic                            i_exec_valid,
    input  logic                            i_exec_side,      // 0 = buy fill, 1 = sell fill
    input  logic [PRICE_LEN-1:0]            i_exec_price,
    input  logic [QUANTITY_LEN-1:0]         i_exec_quantity,
    // Current position and day cash Profit/loss
    output logic signed [POSITION_LEN-1:0]  o_position,
    output logic signed [PNL_LEN-1:0]       o_day_pnl
);

logic signed [POSITION_LEN-1:0] position_reg;
logic signed [PNL_LEN-1:0]      day_pnl_reg;
logic signed [POSITION_LEN:0]   qty_signed;
logic signed [PNL_LEN-1:0]      exec_notional_pnl;

// notional meaning we care about the cash value of the fill, not just the shares. For example, a buy fill of 100 shares at $10 has a notional of $1000, which is what we care about for P/L calculations.
// Quantity and fill notional widened to signed values for the math
assign qty_signed = $signed({1'b0, i_exec_quantity});
assign exec_notional_pnl = $signed(i_exec_price * i_exec_quantity);

always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        position_reg <= STARTING_POSITION;
        day_pnl_reg  <= '0;
    end
    else if (i_exec_valid) begin
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

assign o_position = position_reg;
assign o_day_pnl  = day_pnl_reg;

endmodule