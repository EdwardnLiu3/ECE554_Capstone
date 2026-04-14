// Execution tracker keeps track of our live quotes in the market.
// Just compares our live quotes against executions that happen in the market, sends that information to inventory tracker and also to order generator. 
module execution_tracker #(
    parameter int ORDER_ID_LEN = 32,
    parameter int PRICE_LEN = 32,
    parameter int QUANTITY_LEN = 16,
    parameter int MARKET_QUANTITY_LEN = 32,
    parameter int FIFO_DEPTH = 10
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
    // Fill pulse sent to inventory tracker / quote control logic
    output logic                            o_exec_valid,
    output logic                            o_exec_side,       // 0 = our bid filled, 1 = our ask filled
    output logic [PRICE_LEN-1:0]            o_exec_price,
    output logic [QUANTITY_LEN-1:0]         o_exec_quantity,
    output logic [ORDER_ID_LEN-1:0]         o_exec_order_id,
    // Sent back to order generator. When active is high, queue is full and
    // order generator should replace the oldest quote in the fifo.
    output logic                            o_live_bid_active,
    output logic                            o_live_ask_active,
    output logic [ORDER_ID_LEN-1:0]         o_live_bid_order_id,
    output logic [ORDER_ID_LEN-1:0]         o_live_ask_order_id,
    // Total live amount of stock on each side. Sent to risk manager.
    output logic [QUANTITY_LEN-1:0]         o_live_bid_qty,
    output logic [QUANTITY_LEN-1:0]         o_live_ask_qty
);

// Keeping 10 quotes per side in a small fifo. index 0 is the oldest quote whioch gets checked first and replaced first
logic                         bid_vld_r [0:FIFO_DEPTH-1];
logic                         bid_vld_n [0:FIFO_DEPTH-1];
logic                         ask_vld_r [0:FIFO_DEPTH-1];
logic                         ask_vld_n [0:FIFO_DEPTH-1];
logic [ORDER_ID_LEN-1:0]      bid_id_r  [0:FIFO_DEPTH-1];
logic [ORDER_ID_LEN-1:0]      bid_id_n  [0:FIFO_DEPTH-1];
logic [ORDER_ID_LEN-1:0]      ask_id_r  [0:FIFO_DEPTH-1];
logic [ORDER_ID_LEN-1:0]      ask_id_n  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]         bid_px_r  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]         bid_px_n  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]         ask_px_r  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]         ask_px_n  [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]      bid_qty_r [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]      bid_qty_n [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]      ask_qty_r [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]      ask_qty_n [0:FIFO_DEPTH-1];
// next values for fill pulse stuff
logic                    exec_vld_n;
logic                    exec_side_n;
logic [PRICE_LEN-1:0]    exec_px_n;
logic [QUANTITY_LEN-1:0] exec_qty_n;
logic [ORDER_ID_LEN-1:0] exec_id_n;

always_comb begin
    integer i;
    integer j;
    integer bid_count;
    integer ask_count;
    logic [QUANTITY_LEN-1:0] trade_qty;
    logic [QUANTITY_LEN-1:0] fill_qty;
    logic done_fill;

    // hold
    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        bid_vld_n[i] = bid_vld_r[i];
        ask_vld_n[i] = ask_vld_r[i];
        bid_id_n[i]  = bid_id_r[i];
        ask_id_n[i]  = ask_id_r[i];
        bid_px_n[i]  = bid_px_r[i];
        ask_px_n[i]  = ask_px_r[i];
        bid_qty_n[i] = bid_qty_r[i];
        ask_qty_n[i] = ask_qty_r[i];
    end
    // default to no execution pulse
    exec_vld_n  = 1'b0;
    exec_side_n = 1'b0;
    exec_px_n   = '0;
    exec_qty_n  = '0;
    exec_id_n   = '0;
    // compare market executions against our live quotes, oldest quotes checked first
    trade_qty = i_market_exec_quantity[QUANTITY_LEN-1:0];
    if (i_market_exec_valid && trade_qty != '0) begin
        if (i_market_exec_side) begin
            // sell trade can fill our live bids
            done_fill = 1'b0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                if (!done_fill && bid_vld_n[i] && bid_qty_n[i] != '0 && i_market_exec_price <= bid_px_n[i]) begin
                    fill_qty    = (trade_qty < bid_qty_n[i]) ? trade_qty : bid_qty_n[i];
                    exec_vld_n  = 1'b1;
                    exec_side_n = 1'b0;
                    exec_px_n   = bid_px_n[i];
                    exec_qty_n  = fill_qty;
                    exec_id_n   = bid_id_n[i];

                    if (fill_qty == bid_qty_n[i]) begin
                        for (j = i; j < FIFO_DEPTH-1; j = j + 1) begin
                            bid_vld_n[j] = bid_vld_n[j+1];
                            bid_id_n[j]  = bid_id_n[j+1];
                            bid_px_n[j]  = bid_px_n[j+1];
                            bid_qty_n[j] = bid_qty_n[j+1];
                        end
                        bid_vld_n[FIFO_DEPTH-1] = 1'b0;
                        bid_id_n[FIFO_DEPTH-1]  = '0;
                        bid_px_n[FIFO_DEPTH-1]  = '0;
                        bid_qty_n[FIFO_DEPTH-1] = '0;
                    end
                    else begin
                        bid_qty_n[i] = bid_qty_n[i] - fill_qty;
                    end
                    done_fill = 1'b1;
                end
            end
        end
        else begin
            // buy trade can fill our live asks
            done_fill = 1'b0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                if (!done_fill && ask_vld_n[i] && ask_qty_n[i] != '0 && i_market_exec_price >= ask_px_n[i]) begin
                    fill_qty    = (trade_qty < ask_qty_n[i]) ? trade_qty : ask_qty_n[i];
                    exec_vld_n  = 1'b1;
                    exec_side_n = 1'b1;
                    exec_px_n   = ask_px_n[i];
                    exec_qty_n  = fill_qty;
                    exec_id_n   = ask_id_n[i];
                    if (fill_qty == ask_qty_n[i]) begin
                        for (j = i; j < FIFO_DEPTH-1; j = j + 1) begin
                            ask_vld_n[j] = ask_vld_n[j+1];
                            ask_id_n[j]  = ask_id_n[j+1];
                            ask_px_n[j]  = ask_px_n[j+1];
                            ask_qty_n[j] = ask_qty_n[j+1];
                        end
                        ask_vld_n[FIFO_DEPTH-1] = 1'b0;
                        ask_id_n[FIFO_DEPTH-1]  = '0;
                        ask_px_n[FIFO_DEPTH-1]  = '0;
                        ask_qty_n[FIFO_DEPTH-1] = '0;
                    end
                    else begin
                        ask_qty_n[i] = ask_qty_n[i] - fill_qty;
                    end
                    done_fill = 1'b1;
                end
            end
        end
    end

    // Do the quote update after the fill check so the old live quote gets updated if a fill and a replace happen in the same cycle.
    if (i_order_valid) begin
        if (i_order_quantity_buy != '0) begin
            bid_count = 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                if (bid_vld_n[i])
                    bid_count = bid_count + 1;
            end
            if (bid_count < FIFO_DEPTH) begin
                bid_vld_n[bid_count] = 1'b1;
                bid_id_n[bid_count]  = i_order_id_buy;
                bid_px_n[bid_count]  = i_order_price_buy;
                bid_qty_n[bid_count] = i_order_quantity_buy;
            end
            else begin
                for (i = 0; i < FIFO_DEPTH-1; i = i + 1) begin
                    bid_vld_n[i] = bid_vld_n[i+1];
                    bid_id_n[i]  = bid_id_n[i+1];
                    bid_px_n[i]  = bid_px_n[i+1];
                    bid_qty_n[i] = bid_qty_n[i+1];
                end
                bid_vld_n[FIFO_DEPTH-1] = 1'b1;
                bid_id_n[FIFO_DEPTH-1]  = i_order_id_buy;
                bid_px_n[FIFO_DEPTH-1]  = i_order_price_buy;
                bid_qty_n[FIFO_DEPTH-1] = i_order_quantity_buy;
            end
        end
        if (i_order_quantity_sell != '0) begin
            ask_count = 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                if (ask_vld_n[i])
                    ask_count = ask_count + 1;
            end

            if (ask_count < FIFO_DEPTH) begin
                ask_vld_n[ask_count] = 1'b1;
                ask_id_n[ask_count]  = i_order_id_sell;
                ask_px_n[ask_count]  = i_order_price_sell;
                ask_qty_n[ask_count] = i_order_quantity_sell;
            end
            else begin
                for (i = 0; i < FIFO_DEPTH-1; i = i + 1) begin
                    ask_vld_n[i] = ask_vld_n[i+1];
                    ask_id_n[i]  = ask_id_n[i+1];
                    ask_px_n[i]  = ask_px_n[i+1];
                    ask_qty_n[i] = ask_qty_n[i+1];
                end
                ask_vld_n[FIFO_DEPTH-1] = 1'b1;
                ask_id_n[FIFO_DEPTH-1]  = i_order_id_sell;
                ask_px_n[FIFO_DEPTH-1]  = i_order_price_sell;
                ask_qty_n[FIFO_DEPTH-1] = i_order_quantity_sell;
            end
        end
    end
end

//flops for outputs & updates to live quote fifo
always_ff @(posedge i_clk, negedge i_rst_n) begin
    integer i;
    if (!i_rst_n) begin
        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            bid_vld_r[i] <= 1'b0;
            ask_vld_r[i] <= 1'b0;
            bid_id_r[i]  <= '0;
            ask_id_r[i]  <= '0;
            bid_px_r[i]  <= '0;
            ask_px_r[i]  <= '0;
            bid_qty_r[i] <= '0;
            ask_qty_r[i] <= '0;
        end
        o_exec_valid    <= 1'b0;
        o_exec_side     <= 1'b0;
        o_exec_price    <= '0;
        o_exec_quantity <= '0;
        o_exec_order_id <= '0;
    end
    else begin
        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            bid_vld_r[i] <= bid_vld_n[i];
            ask_vld_r[i] <= ask_vld_n[i];
            bid_id_r[i]  <= bid_id_n[i];
            ask_id_r[i]  <= ask_id_n[i];
            bid_px_r[i]  <= bid_px_n[i];
            ask_px_r[i]  <= ask_px_n[i];
            bid_qty_r[i] <= bid_qty_n[i];
            ask_qty_r[i] <= ask_qty_n[i];
        end
        o_exec_valid    <= exec_vld_n;
        o_exec_side     <= exec_side_n;
        o_exec_price    <= exec_px_n;
        o_exec_quantity <= exec_qty_n;
        o_exec_order_id <= exec_id_n;
    end
end

always_comb begin
    integer i;
    integer bid_count;
    integer ask_count;
    logic [QUANTITY_LEN-1:0] bid_total;
    logic [QUANTITY_LEN-1:0] ask_total;
    bid_count = 0;
    ask_count = 0;
    bid_total = '0;
    ask_total = '0;

    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        if (bid_vld_r[i]) begin
            bid_count = bid_count + 1;
            bid_total = bid_total + bid_qty_r[i];
        end
        if (ask_vld_r[i]) begin
            ask_count = ask_count + 1;
            ask_total = ask_total + ask_qty_r[i];
        end
    end

    // These go back to order generator. If fifo is full then the oldest quote is ready to be replaced. If not full then order generator should keep
    // adding new quotes until we reach the depth. Also, if fifo is only partially full, quote stays active and will still be replaced. 
    o_live_bid_active   = (bid_count == FIFO_DEPTH) && bid_vld_r[0];
    o_live_ask_active   = (ask_count == FIFO_DEPTH) && ask_vld_r[0];
    o_live_bid_order_id = bid_vld_r[0] ? bid_id_r[0] : '0;
    o_live_ask_order_id = ask_vld_r[0] ? ask_id_r[0] : '0;
    o_live_bid_qty      = bid_total;
    o_live_ask_qty      = ask_total;
end

endmodule
