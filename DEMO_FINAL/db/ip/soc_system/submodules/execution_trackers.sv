// Execution tracker keeps track of our live quotes in the market.
// It compares live quotes against market executions, then sends fill
// information to the inventory tracker and quote-control logic.
module execution_trackers #(
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
    // Sent back to order generator. When active is high, queue is full and
    // order generator should replace the oldest quote.
    output logic                            o_live_bid_active,
    output logic                            o_live_ask_active,
    output logic [ORDER_ID_LEN-1:0]         o_live_bid_order_id,
    output logic [ORDER_ID_LEN-1:0]         o_live_ask_order_id,
    // Total live amount of stock on each side. Sent to risk manager.
    output logic [QUANTITY_LEN-1:0]         o_live_bid_qty,
    output logic [QUANTITY_LEN-1:0]         o_live_ask_qty
);

localparam int IDX_LEN = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
localparam int COUNT_LEN = $clog2(FIFO_DEPTH + 1);

logic [COUNT_LEN-1:0]      bid_count_r;
logic [COUNT_LEN-1:0]      bid_count_n;
logic [COUNT_LEN-1:0]      ask_count_r;
logic [COUNT_LEN-1:0]      ask_count_n;

logic [ORDER_ID_LEN-1:0]   bid_id_r  [0:FIFO_DEPTH-1];
logic [ORDER_ID_LEN-1:0]   bid_id_n  [0:FIFO_DEPTH-1];
logic [ORDER_ID_LEN-1:0]   ask_id_r  [0:FIFO_DEPTH-1];
logic [ORDER_ID_LEN-1:0]   ask_id_n  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]      bid_px_r  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]      bid_px_n  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]      ask_px_r  [0:FIFO_DEPTH-1];
logic [PRICE_LEN-1:0]      ask_px_n  [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]   bid_qty_r [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]   bid_qty_n [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]   ask_qty_r [0:FIFO_DEPTH-1];
logic [QUANTITY_LEN-1:0]   ask_qty_n [0:FIFO_DEPTH-1];

logic                    exec_vld_n;
logic                    exec_side_n;
logic [PRICE_LEN-1:0]    exec_px_n;
logic [QUANTITY_LEN-1:0] exec_qty_n;
logic [ORDER_ID_LEN-1:0] exec_id_n;

always_comb begin
    integer i;
    logic [QUANTITY_LEN-1:0] trade_qty;
    logic [QUANTITY_LEN-1:0] fill_qty;
    logic bid_match_found;
    logic ask_match_found;
    logic [IDX_LEN-1:0] bid_match_idx;
    logic [IDX_LEN-1:0] ask_match_idx;

    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        bid_id_n[i]  = bid_id_r[i];
        ask_id_n[i]  = ask_id_r[i];
        bid_px_n[i]  = bid_px_r[i];
        ask_px_n[i]  = ask_px_r[i];
        bid_qty_n[i] = bid_qty_r[i];
        ask_qty_n[i] = ask_qty_r[i];
    end

    bid_count_n = bid_count_r;
    ask_count_n = ask_count_r;

    exec_vld_n  = 1'b0;
    exec_side_n = 1'b0;
    exec_px_n   = '0;
    exec_qty_n  = '0;
    exec_id_n   = '0;

    trade_qty = i_market_exec_quantity[QUANTITY_LEN-1:0];

    // Find the first FIFO entry, oldest-to-newest, that this market execution can fill.
    bid_match_found = 1'b0;
    ask_match_found = 1'b0;
    bid_match_idx   = '0;
    ask_match_idx   = '0;

    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        if (!bid_match_found && (i < bid_count_r) && (bid_qty_r[i] != '0) &&
            (i_market_exec_price < bid_px_r[i])) begin
            bid_match_found = 1'b1;
            bid_match_idx   = i[IDX_LEN-1:0];
        end

        if (!ask_match_found && (i < ask_count_r) && (ask_qty_r[i] != '0) &&
            (i_market_exec_price > ask_px_r[i])) begin
            ask_match_found = 1'b1;
            ask_match_idx   = i[IDX_LEN-1:0];
        end
    end

    if (i_market_exec_valid && trade_qty != '0) begin
        if (i_market_exec_side && bid_match_found) begin
            // A sell trade can fill our live bids.
            fill_qty    = (trade_qty < bid_qty_r[bid_match_idx]) ? trade_qty : bid_qty_r[bid_match_idx];
            exec_vld_n  = 1'b1;
            exec_side_n = 1'b0;
            exec_px_n   = bid_px_r[bid_match_idx];
            exec_qty_n  = fill_qty;
            exec_id_n   = bid_id_r[bid_match_idx];

            if (fill_qty == bid_qty_r[bid_match_idx]) begin
                for (i = 0; i < FIFO_DEPTH - 1; i = i + 1) begin
                    if ((i >= bid_match_idx) && (i < bid_count_r - 1'b1)) begin
                        bid_id_n[i]  = bid_id_r[i + 1];
                        bid_px_n[i]  = bid_px_r[i + 1];
                        bid_qty_n[i] = bid_qty_r[i + 1];
                    end
                end
                bid_id_n[bid_count_r - 1'b1]  = '0;
                bid_px_n[bid_count_r - 1'b1]  = '0;
                bid_qty_n[bid_count_r - 1'b1] = '0;
                bid_count_n = bid_count_r - 1'b1;
            end
            else begin
                bid_qty_n[bid_match_idx] = bid_qty_r[bid_match_idx] - fill_qty;
            end
        end
        else if (!i_market_exec_side && ask_match_found) begin
            // A buy trade can fill our live asks.
            fill_qty    = (trade_qty < ask_qty_r[ask_match_idx]) ? trade_qty : ask_qty_r[ask_match_idx];
            exec_vld_n  = 1'b1;
            exec_side_n = 1'b1;
            exec_px_n   = ask_px_r[ask_match_idx];
            exec_qty_n  = fill_qty;
            exec_id_n   = ask_id_r[ask_match_idx];

            if (fill_qty == ask_qty_r[ask_match_idx]) begin
                for (i = 0; i < FIFO_DEPTH - 1; i = i + 1) begin
                    if ((i >= ask_match_idx) && (i < ask_count_r - 1'b1)) begin
                        ask_id_n[i]  = ask_id_r[i + 1];
                        ask_px_n[i]  = ask_px_r[i + 1];
                        ask_qty_n[i] = ask_qty_r[i + 1];
                    end
                end
                ask_id_n[ask_count_r - 1'b1]  = '0;
                ask_px_n[ask_count_r - 1'b1]  = '0;
                ask_qty_n[ask_count_r - 1'b1] = '0;
                ask_count_n = ask_count_r - 1'b1;
            end
            else begin
                ask_qty_n[ask_match_idx] = ask_qty_r[ask_match_idx] - fill_qty;
            end
        end
    end

    // Quote updates happen after fill handling, matching the existing software model.
    if (i_order_valid && i_order_quantity_buy != '0) begin
        if (bid_count_n == FIFO_DEPTH[COUNT_LEN-1:0]) begin
            for (i = 0; i < FIFO_DEPTH - 1; i = i + 1) begin
                bid_id_n[i]  = bid_id_n[i + 1];
                bid_px_n[i]  = bid_px_n[i + 1];
                bid_qty_n[i] = bid_qty_n[i + 1];
            end
            bid_id_n[FIFO_DEPTH-1]  = i_order_id_buy;
            bid_px_n[FIFO_DEPTH-1]  = i_order_price_buy;
            bid_qty_n[FIFO_DEPTH-1] = i_order_quantity_buy;
        end
        else begin
            bid_id_n[bid_count_n]  = i_order_id_buy;
            bid_px_n[bid_count_n]  = i_order_price_buy;
            bid_qty_n[bid_count_n] = i_order_quantity_buy;
            bid_count_n = bid_count_n + 1'b1;
        end
    end

    if (i_order_valid && i_order_quantity_sell != '0) begin
        if (ask_count_n == FIFO_DEPTH[COUNT_LEN-1:0]) begin
            for (i = 0; i < FIFO_DEPTH - 1; i = i + 1) begin
                ask_id_n[i]  = ask_id_n[i + 1];
                ask_px_n[i]  = ask_px_n[i + 1];
                ask_qty_n[i] = ask_qty_n[i + 1];
            end
            ask_id_n[FIFO_DEPTH-1]  = i_order_id_sell;
            ask_px_n[FIFO_DEPTH-1]  = i_order_price_sell;
            ask_qty_n[FIFO_DEPTH-1] = i_order_quantity_sell;
        end
        else begin
            ask_id_n[ask_count_n]  = i_order_id_sell;
            ask_px_n[ask_count_n]  = i_order_price_sell;
            ask_qty_n[ask_count_n] = i_order_quantity_sell;
            ask_count_n = ask_count_n + 1'b1;
        end
    end
end

always_ff @(posedge i_clk, negedge i_rst_n) begin
    integer i;
    if (!i_rst_n) begin
        bid_count_r <= '0;
        ask_count_r <= '0;
        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
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
        bid_count_r <= bid_count_n;
        ask_count_r <= ask_count_n;
        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
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
    logic [QUANTITY_LEN-1:0] bid_total;
    logic [QUANTITY_LEN-1:0] ask_total;

    bid_total = '0;
    ask_total = '0;

    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        if (i < bid_count_r)
            bid_total = bid_total + bid_qty_r[i];
        if (i < ask_count_r)
            ask_total = ask_total + ask_qty_r[i];
    end

    o_live_bid_active   = (bid_count_r == FIFO_DEPTH[COUNT_LEN-1:0]);
    o_live_ask_active   = (ask_count_r == FIFO_DEPTH[COUNT_LEN-1:0]);
    o_live_bid_order_id = (bid_count_r != '0) ? bid_id_r[0] : '0;
    o_live_ask_order_id = (ask_count_r != '0) ? ask_id_r[0] : '0;
    o_live_bid_qty      = bid_total;
    o_live_ask_qty      = ask_total;
end

endmodule
