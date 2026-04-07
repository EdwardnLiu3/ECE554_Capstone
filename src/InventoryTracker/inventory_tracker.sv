// simple inventory track for each single stock, this module will get information from execution tracker: when on of our quotes fills, 
//we get a pulse with the side, price, and quantity of the fill. We will keep a running total of our inventory position and day cash P/L for this stock. 
// This gets used by both risk management and trading logic. Inventory tracking will also be done in software, we will need to verify same results. 
module inventory_tracker #(
    parameter int PRICE_LEN = 32,
    parameter int QUANTITY_LEN = 16,
    parameter int POSITION_LEN = 16,
    parameter int PNL_LEN = 64,
    parameter logic signed [POSITION_LEN-1:0] STARTING_POSITION = 16'sd100
) (
    input  logic                            i_clk,
    input  logic                            i_rst_n,

    // One-cycle pulse from the execution tracker when one of our quotes fills.
    input  logic                            i_exec_valid,
    input  logic                            i_exec_side,      // 0 = bid/buy fill, 1 = ask/sell fill
    input  logic [PRICE_LEN-1:0]            i_exec_price,     // cents per share
    input  logic [QUANTITY_LEN-1:0]         i_exec_quantity,  // shares filled

    // Current inventory and day cash P/L for this stock.
    output logic signed [POSITION_LEN-1:0]  o_position,
    output logic signed [PNL_LEN-1:0]       o_day_pnl
);

// Cash P/L convention:
//   buy fill  -> spend cash, so P/L decreases by price * quantity
//   sell fill -> receive cash, so P/L increases by price * quantity
// This is meant to be simple and since for hft we worry about profits from quick trading back and forth, 
// we are only tracking cash P?L right now as this is simpler and more relevant for our use case. 
// If we want to do realized and unrealized P/L tracking we can add that later, but it will require more complexity around tracking the cost basis of inventory and marking to market.

logic signed [POSITION_LEN-1:0] position_reg, position_next;
logic signed [PNL_LEN-1:0] day_pnl_reg, day_pnl_next;
logic [PRICE_LEN+QUANTITY_LEN-1:0] exec_notional;

// Helper function to convert quantity to position change, handling potential width differences.
function automatic logic signed [POSITION_LEN-1:0] qty_to_position(
    input logic [QUANTITY_LEN-1:0] qty
);
    logic [POSITION_LEN-1:0] tmp;
    begin
        tmp = '0;
        for (int i = 0; i < POSITION_LEN && i < QUANTITY_LEN; i++) begin
            tmp[i] = qty[i];
        end
        qty_to_position = $signed(tmp);
    end
endfunction

// Helper function to convert notional value to P/L, handling potential width differences.
function automatic logic signed [PNL_LEN-1:0] notional_to_pnl(
    input logic [PRICE_LEN+QUANTITY_LEN-1:0] notional
);
    logic [PNL_LEN-1:0] tmp;
    begin
        tmp = '0;
        for (int i = 0; i < PNL_LEN && i < (PRICE_LEN+QUANTITY_LEN); i++) begin
            tmp[i] = notional[i];
        end
        notional_to_pnl = $signed(tmp);
    end
endfunction

// Combinational logic to calculate next position and P/L based on current state and incoming execution.
always_comb begin
    position_next = position_reg;
    day_pnl_next = day_pnl_reg;
    exec_notional = i_exec_price * i_exec_quantity;

    if (i_exec_valid) begin
        if (!i_exec_side) begin
            // Buy fill: inventory increases and cash P/L decreases.
            position_next = position_reg + qty_to_position(i_exec_quantity);
            day_pnl_next = day_pnl_reg - notional_to_pnl(exec_notional);
        end else begin
            // Sell fill: inventory decreases and cash P/L increases.
            position_next = position_reg - qty_to_position(i_exec_quantity);
            day_pnl_next = day_pnl_reg + notional_to_pnl(exec_notional);
        end
    end
end

// Just a reset handling flop
always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        position_reg <= STARTING_POSITION;
        day_pnl_reg <= '0;
    end else begin
        position_reg <= position_next;
        day_pnl_reg <= day_pnl_next;
    end
end

// outputs are just the current state of our position and P/L registers
assign o_position = position_reg;
assign o_day_pnl = day_pnl_reg;

endmodule
