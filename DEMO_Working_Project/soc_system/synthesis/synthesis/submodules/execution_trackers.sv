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
localparam int AGE_LEN = 32;

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
logic [AGE_LEN-1:0]           bid_age_r [0:FIFO_DEPTH-1];
logic [AGE_LEN-1:0]           bid_age_n [0:FIFO_DEPTH-1];
logic [AGE_LEN-1:0]           ask_age_r [0:FIFO_DEPTH-1];
logic [AGE_LEN-1:0]           ask_age_n [0:FIFO_DEPTH-1];
logic [AGE_LEN-1:0]           bid_next_age_r;
logic [AGE_LEN-1:0]           bid_next_age_n;
logic [AGE_LEN-1:0]           ask_next_age_r;
logic [AGE_LEN-1:0]           ask_next_age_n;

// Next values for fill pulse outputs.
logic                    exec_vld_n;
logic                    exec_side_n;
logic [PRICE_LEN-1:0]    exec_px_n;
logic [QUANTITY_LEN-1:0] exec_qty_n;
logic [ORDER_ID_LEN-1:0] exec_id_n;

always_comb begin
    integer i;
    integer bid_count;
    integer ask_count;
    logic [QUANTITY_LEN-1:0] trade_qty;
    logic [QUANTITY_LEN-1:0] fill_qty;
    logic bid_match_found;
    logic ask_match_found;
    logic bid_free_found;
    logic ask_free_found;
    logic bid_oldest_found;
    logic ask_oldest_found;
    logic [IDX_LEN-1:0] bid_match_idx;
    logic [IDX_LEN-1:0] ask_match_idx;
    logic [IDX_LEN-1:0] bid_free_idx;
    logic [IDX_LEN-1:0] ask_free_idx;
    logic [IDX_LEN-1:0] bid_insert_idx;
    logic [IDX_LEN-1:0] ask_insert_idx;
    logic [IDX_LEN-1:0] bid_oldest_idx;
    logic [IDX_LEN-1:0] ask_oldest_idx;
    logic [AGE_LEN-1:0] bid_match_age;
    logic [AGE_LEN-1:0] ask_match_age;
    logic [AGE_LEN-1:0] bid_oldest_age;
    logic [AGE_LEN-1:0] ask_oldest_age;

    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        bid_vld_n[i] = bid_vld_r[i];
        ask_vld_n[i] = ask_vld_r[i];
        bid_id_n[i]  = bid_id_r[i];
        ask_id_n[i]  = ask_id_r[i];
        bid_px_n[i]  = bid_px_r[i];
        ask_px_n[i]  = ask_px_r[i];
        bid_qty_n[i] = bid_qty_r[i];
        ask_qty_n[i] = ask_qty_r[i];
        bid_age_n[i] = bid_age_r[i];
        ask_age_n[i] = ask_age_r[i];
    end

    bid_next_age_n = bid_next_age_r;
    ask_next_age_n = ask_next_age_r;

    exec_vld_n  = 1'b0;
    exec_side_n = 1'b0;
    exec_px_n   = '0;
    exec_qty_n  = '0;
    exec_id_n   = '0;

    trade_qty = i_market_exec_quantity[QUANTITY_LEN-1:0];

    // Find the oldest live quote that can be filled by this market execution.
    bid_match_found = 1'b0;
    ask_match_found = 1'b0;
    bid_match_idx   = '0;
    ask_match_idx   = '0;
    bid_match_age   = {AGE_LEN{1'b1}};
    ask_match_age   = {AGE_LEN{1'b1}};

    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        if (bid_vld_r[i] && bid_qty_r[i] != '0 && i_market_exec_price <= bid_px_r[i]) begin
            if (!bid_match_found || bid_age_r[i] < bid_match_age) begin
                bid_match_found = 1'b1;
                bid_match_idx   = i[IDX_LEN-1:0];
                bid_match_age   = bid_age_r[i];
            end
        end
        if (ask_vld_r[i] && ask_qty_r[i] != '0 && i_market_exec_price >= ask_px_r[i]) begin
            if (!ask_match_found || ask_age_r[i] < ask_match_age) begin
                ask_match_found = 1'b1;
                ask_match_idx   = i[IDX_LEN-1:0];
                ask_match_age   = ask_age_r[i];
            end
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
                bid_vld_n[bid_match_idx] = 1'b0;
                bid_id_n[bid_match_idx]  = '0;
                bid_px_n[bid_match_idx]  = '0;
                bid_qty_n[bid_match_idx] = '0;
                bid_age_n[bid_match_idx] = '0;
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
                ask_vld_n[ask_match_idx] = 1'b0;
                ask_id_n[ask_match_idx]  = '0;
                ask_px_n[ask_match_idx]  = '0;
                ask_qty_n[ask_match_idx] = '0;
                ask_age_n[ask_match_idx] = '0;
            end
            else begin
                ask_qty_n[ask_match_idx] = ask_qty_r[ask_match_idx] - fill_qty;
            end
        end
    end

    // Do quote updates after fill handling, matching the old packed-FIFO behavior.
    if (i_order_valid && i_order_quantity_buy != '0) begin
        bid_count        = 0;
        bid_free_found   = 1'b0;
        bid_free_idx     = '0;
        bid_oldest_found = 1'b0;
        bid_oldest_idx   = '0;
        bid_oldest_age   = {AGE_LEN{1'b1}};

        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            if (bid_vld_n[i]) begin
                bid_count = bid_count + 1;
                if (!bid_oldest_found || bid_age_n[i] < bid_oldest_age) begin
                    bid_oldest_found = 1'b1;
                    bid_oldest_idx   = i[IDX_LEN-1:0];
                    bid_oldest_age   = bid_age_n[i];
                end
            end
            else if (!bid_free_found) begin
                bid_free_found = 1'b1;
                bid_free_idx   = i[IDX_LEN-1:0];
            end
        end

        bid_insert_idx = (bid_count < FIFO_DEPTH && bid_free_found) ? bid_free_idx : bid_oldest_idx;
        bid_vld_n[bid_insert_idx] = 1'b1;
        bid_id_n[bid_insert_idx]  = i_order_id_buy;
        bid_px_n[bid_insert_idx]  = i_order_price_buy;
        bid_qty_n[bid_insert_idx] = i_order_quantity_buy;
        bid_age_n[bid_insert_idx] = bid_next_age_r;
        bid_next_age_n = bid_next_age_r + 1'b1;
    end

    if (i_order_valid && i_order_quantity_sell != '0) begin
        ask_count        = 0;
        ask_free_found   = 1'b0;
        ask_free_idx     = '0;
        ask_oldest_found = 1'b0;
        ask_oldest_idx   = '0;
        ask_oldest_age   = {AGE_LEN{1'b1}};

        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            if (ask_vld_n[i]) begin
                ask_count = ask_count + 1;
                if (!ask_oldest_found || ask_age_n[i] < ask_oldest_age) begin
                    ask_oldest_found = 1'b1;
                    ask_oldest_idx   = i[IDX_LEN-1:0];
                    ask_oldest_age   = ask_age_n[i];
                end
            end
            else if (!ask_free_found) begin
                ask_free_found = 1'b1;
                ask_free_idx   = i[IDX_LEN-1:0];
            end
        end

        ask_insert_idx = (ask_count < FIFO_DEPTH && ask_free_found) ? ask_free_idx : ask_oldest_idx;
        ask_vld_n[ask_insert_idx] = 1'b1;
        ask_id_n[ask_insert_idx]  = i_order_id_sell;
        ask_px_n[ask_insert_idx]  = i_order_price_sell;
        ask_qty_n[ask_insert_idx] = i_order_quantity_sell;
        ask_age_n[ask_insert_idx] = ask_next_age_r;
        ask_next_age_n = ask_next_age_r + 1'b1;
    end
end

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
            bid_age_r[i] <= '0;
            ask_age_r[i] <= '0;
        end
        bid_next_age_r <= '0;
        ask_next_age_r <= '0;
        o_exec_valid   <= 1'b0;
        o_exec_side    <= 1'b0;
        o_exec_price   <= '0;
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
            bid_age_r[i] <= bid_age_n[i];
            ask_age_r[i] <= ask_age_n[i];
        end
        bid_next_age_r  <= bid_next_age_n;
        ask_next_age_r  <= ask_next_age_n;
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
    logic bid_oldest_found;
    logic ask_oldest_found;
    logic [IDX_LEN-1:0] bid_oldest_idx;
    logic [IDX_LEN-1:0] ask_oldest_idx;
    logic [AGE_LEN-1:0] bid_oldest_age;
    logic [AGE_LEN-1:0] ask_oldest_age;
    logic [QUANTITY_LEN-1:0] bid_total;
    logic [QUANTITY_LEN-1:0] ask_total;

    bid_count = 0;
    ask_count = 0;
    bid_total = '0;
    ask_total = '0;
    bid_oldest_found = 1'b0;
    ask_oldest_found = 1'b0;
    bid_oldest_idx   = '0;
    ask_oldest_idx   = '0;
    bid_oldest_age   = {AGE_LEN{1'b1}};
    ask_oldest_age   = {AGE_LEN{1'b1}};

    for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
        if (bid_vld_r[i]) begin
            bid_count = bid_count + 1;
            bid_total = bid_total + bid_qty_r[i];
            if (!bid_oldest_found || bid_age_r[i] < bid_oldest_age) begin
                bid_oldest_found = 1'b1;
                bid_oldest_idx   = i[IDX_LEN-1:0];
                bid_oldest_age   = bid_age_r[i];
            end
        end
        if (ask_vld_r[i]) begin
            ask_count = ask_count + 1;
            ask_total = ask_total + ask_qty_r[i];
            if (!ask_oldest_found || ask_age_r[i] < ask_oldest_age) begin
                ask_oldest_found = 1'b1;
                ask_oldest_idx   = i[IDX_LEN-1:0];
                ask_oldest_age   = ask_age_r[i];
            end
        end
    end

    o_live_bid_active   = (bid_count == FIFO_DEPTH);
    o_live_ask_active   = (ask_count == FIFO_DEPTH);
    o_live_bid_order_id = bid_oldest_found ? bid_id_r[bid_oldest_idx] : '0;
    o_live_ask_order_id = ask_oldest_found ? ask_id_r[ask_oldest_idx] : '0;
    o_live_bid_qty      = bid_total;
    o_live_ask_qty      = ask_total;
end

endmodule
