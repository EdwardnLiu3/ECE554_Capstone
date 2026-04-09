// Execution tracker keeps track of our live quotes in the market.
// Just compares our live quotes against executions that happen in the market, sends that information to inventory tracker and also to order generator. 
module execution_tracker #(
    parameter int ORDER_ID_LEN = 32,
    parameter int PRICE_LEN = 32,
    parameter int QUANTITY_LEN = 16,
    parameter int MARKET_QUANTITY_LEN = 32
) (
    input  logic                            i_clk,
    input  logic                            i_rst_n,
    // Current quote outputs from Order_Generator.
    input  logic                            i_order_valid,
    input  logic [ORDER_ID_LEN-1:0]         i_order_id_buy,
    input  logic [ORDER_ID_LEN-1:0]         i_order_id_sell,
    input  logic [PRICE_LEN-1:0]            i_order_price_buy,
    input  logic [PRICE_LEN-1:0]            i_order_price_sell,
    input  logic [QUANTITY_LEN-1:0]         i_order_quantity_buy,
    input  logic [QUANTITY_LEN-1:0]         i_order_quantity_sell,
    // Hopefully can come from orderbooks? Will be easier than from parser
    // Side convention here: 0 = buy trade, 1 = sell trade.
    input  logic                            i_market_exec_valid,
    input  logic                            i_market_exec_side,
    input  logic [PRICE_LEN-1:0]            i_market_exec_price,
    input  logic [MARKET_QUANTITY_LEN-1:0]  i_market_exec_quantity,
    // Fill pulse sent to inventory tracker / quote control logic.
    output logic                            o_exec_valid,
    output logic                            o_exec_side,       // 0 = our bid filled, 1 = our ask filled
    output logic [PRICE_LEN-1:0]            o_exec_price,
    output logic [QUANTITY_LEN-1:0]         o_exec_quantity,
    output logic [ORDER_ID_LEN-1:0]         o_exec_order_id,
    // Current live quote state fed back to order generator.
    output logic                            o_live_bid_active,
    output logic                            o_live_ask_active,
    output logic [ORDER_ID_LEN-1:0]         o_live_bid_order_id,
    output logic [ORDER_ID_LEN-1:0]         o_live_ask_order_id
);
// may need to change logic in here to ensure executions take priority over updating quotes. For example, if we have a live quote and then get an execution that fills it, we want to make sure we process that execution and send the fill information to inventory tracker before we update our live quote state with the new quote from order generator. Otherwise


// We only have 1 live bid and 1 live ask for now since order generator is only built to have one quote per side right now.
logic                    bid_vld_r, bid_vld_n;
logic                    ask_vld_r, ask_vld_n;
logic [ORDER_ID_LEN-1:0] bid_id_r, bid_id_n;
logic [ORDER_ID_LEN-1:0] ask_id_r, ask_id_n;
logic [PRICE_LEN-1:0]    bid_px_r, bid_px_n;
logic [PRICE_LEN-1:0]    ask_px_r, ask_px_n;
logic [QUANTITY_LEN-1:0] bid_qty_r, bid_qty_n;
logic [QUANTITY_LEN-1:0] ask_qty_r, ask_qty_n;
// next values for fill pulse stuff
logic                    exec_vld_n;
logic                    exec_side_n;
logic [PRICE_LEN-1:0]    exec_px_n;
logic [QUANTITY_LEN-1:0] exec_qty_n;
logic [ORDER_ID_LEN-1:0] exec_id_n;

always_comb begin
    logic [QUANTITY_LEN-1:0] trade_qty;
    // hold 
    bid_vld_n = bid_vld_r;
    ask_vld_n = ask_vld_r;
    bid_id_n  = bid_id_r;
    ask_id_n  = ask_id_r;
    bid_px_n  = bid_px_r;
    ask_px_n  = ask_px_r;
    bid_qty_n = bid_qty_r;
    ask_qty_n = ask_qty_r;
    // default to no execution pulse
    exec_vld_n  = 1'b0;
    exec_side_n = 1'b0;
    exec_px_n   = '0;
    exec_qty_n  = '0;
    exec_id_n   = '0;
    // We only have one quote per side so we just store those dont need to do anything else for now
    if (i_order_valid) begin
        bid_vld_n = 1'b1;
        bid_id_n  = i_order_id_buy;
        bid_px_n  = i_order_price_buy;
        bid_qty_n = i_order_quantity_buy;
        ask_vld_n = 1'b1;
        ask_id_n  = i_order_id_sell;
        ask_px_n  = i_order_price_sell;
        ask_qty_n = i_order_quantity_sell;
    end

    // compare market executions against our live quotes, market sell can hit our bid narket buy can lift our ask
    trade_qty = i_market_exec_quantity[QUANTITY_LEN-1:0];
    if (i_market_exec_valid && trade_qty != '0) begin
        if (i_market_exec_side) begin
            // sell trade can fill our live bid
            if (bid_vld_n && bid_qty_n != '0 && i_market_exec_price <= bid_px_n) begin
                exec_vld_n  = 1'b1;
                exec_side_n = 1'b0;
                exec_px_n   = bid_px_n;
                exec_qty_n  = (trade_qty < bid_qty_n) ? trade_qty : bid_qty_n;
                exec_id_n   = bid_id_n;

                if (exec_qty_n == bid_qty_n) begin
                    bid_vld_n = 1'b0;
                    bid_qty_n = '0;
                end
                else begin
                    bid_qty_n = bid_qty_n - exec_qty_n;
                end
            end
        end
        else begin
            // buy trade can fill our live ask
            if (ask_vld_n && ask_qty_n != '0 && i_market_exec_price >= ask_px_n) begin
                exec_vld_n  = 1'b1;
                exec_side_n = 1'b1;
                exec_px_n   = ask_px_n;
                exec_qty_n  = (trade_qty < ask_qty_n) ? trade_qty : ask_qty_n;
                exec_id_n   = ask_id_n;

                if (exec_qty_n == ask_qty_n) begin
                    ask_vld_n = 1'b0;
                    ask_qty_n = '0;
                end
                else begin
                    ask_qty_n = ask_qty_n - exec_qty_n;
                end
            end
        end
    end
end

//flops for outputs 
always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        bid_vld_r <= 1'b0;
        ask_vld_r <= 1'b0;
        bid_id_r  <= '0;
        ask_id_r  <= '0;
        bid_px_r  <= '0;
        ask_px_r  <= '0;
        bid_qty_r <= '0;
        ask_qty_r <= '0;
        o_exec_valid    <= 1'b0;
        o_exec_side     <= 1'b0;
        o_exec_price    <= '0;
        o_exec_quantity <= '0;
        o_exec_order_id <= '0;
    end
    else begin
        bid_vld_r <= bid_vld_n;
        ask_vld_r <= ask_vld_n;
        bid_id_r  <= bid_id_n;
        ask_id_r  <= ask_id_n;
        bid_px_r  <= bid_px_n;
        ask_px_r  <= ask_px_n;
        bid_qty_r <= bid_qty_n;
        ask_qty_r <= ask_qty_n;
        o_exec_valid    <= exec_vld_n;
        o_exec_side     <= exec_side_n;
        o_exec_price    <= exec_px_n;
        o_exec_quantity <= exec_qty_n;
        o_exec_order_id <= exec_id_n;
    end
end
always_comb begin
    o_live_bid_active   = bid_vld_r;
    o_live_ask_active   = ask_vld_r;
    o_live_bid_order_id = bid_id_r;
    o_live_ask_order_id = ask_id_r;
end

endmodule
