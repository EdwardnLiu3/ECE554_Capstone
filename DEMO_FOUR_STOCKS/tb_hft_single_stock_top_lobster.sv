`timescale 1ns/1ps
import ob_pkg::*;
module tb_hft_single_stock_top_lobster;
    
    localparam int MARKET_PAYLOAD_LEN = 288;
    localparam int OUCH_PAYLOAD_LEN   = 752;
    localparam int POSITION_LEN       = 16;
    localparam int PNL_LEN            = 64;
    localparam int STOCK_LEN          = 16;
    localparam bit VERBOSE_LOGS       = 1'b0;
    localparam int PROGRESS_ROWS      = 50000;
    localparam int NUM_STOCKS         = 4;
    localparam int BOOK_PRICE_DIVISOR = (PRICE_LEN <= 16) ? 100 : 1;
    localparam int MAX_REPLAY_ROWS    = 238534;
    localparam int AAPL_BOOK_BASE_PRICE = 32'd5_820_000;
    localparam int AMZN_BOOK_BASE_PRICE = 32'd2_220_000;
    localparam int INTC_BOOK_BASE_PRICE = 32'd265_000;
    localparam int MSFT_BOOK_BASE_PRICE = 32'd303_000;
    localparam string LOBSTER_MESSAGE_CSV =
        "ITCH_Translator/LOBSTER_SampleFile_AMZN_2012-06-21_1/four_stock_style_hour_message_clean_merged.csv";

    logic                           clk;
    logic                           rst_n;
    logic [MARKET_PAYLOAD_LEN-1:0]  market_payload;
    logic                           market_valid;
    logic [47:0]                    order_time;
    logic [63:0]                    symbol;
    logic [TOT_QUATITY_LEN-1:0]     bid_quote_quantity;
    logic [TOT_QUATITY_LEN-1:0]     ask_quote_quantity;
    logic                           trading_enable;
    logic                           kill_switch;
    logic                           price_band_enable;
    logic                           pnl_check_enable;

    logic [STOCK_LEN-1:0]           stock_id_i;
    logic [STOCK_LEN-1:0]           stock_id;
    logic [FULL_PRICE_LEN-1:0]      best_bid_price;
    logic [FULL_PRICE_LEN-1:0]      best_ask_price;
    logic                           best_bid_valid;
    logic                           best_ask_valid;
    logic [FULL_PRICE_LEN-1:0]      trading_bid_price;
    logic [FULL_PRICE_LEN-1:0]      trading_ask_price;
    logic [1:0]                     trading_order_type;
    logic                           trading_valid;
    logic                           bid_reject_valid;
    logic [3:0]                     bid_reject_reason;
    logic                           ask_reject_valid;
    logic [3:0]                     ask_reject_reason;
    logic                           order_payload_valid;
    logic [OUCH_PAYLOAD_LEN-1:0]    order_payload;
    logic                           exec_valid;
    logic                           exec_side;
    logic [FULL_PRICE_LEN-1:0]      exec_price;
    logic [TOT_QUATITY_LEN-1:0]     exec_quantity;
    logic [ORDERID_LEN-1:0]         exec_order_id;
    logic signed [POSITION_LEN-1:0] position;
    logic signed [PNL_LEN-1:0]      day_pnl;
    logic [TOT_QUATITY_LEN-1:0]     live_bid_qty;
    logic [TOT_QUATITY_LEN-1:0]     live_ask_qty;
    logic [FULL_PRICE_LEN-1:0]      tb_mark_price;
    logic                           tb_mark_price_valid;
    longint signed                  tb_total_pnl;
    logic [PRICE_LEN-1:0]           parser_price_book;
    logic [QUANTITY_LEN-1:0]        parser_quantity_book;
    logic [63:0]                    parser_order_id;
    logic [31:0]                    parser_quantity;
    logic                           parser_side;
    logic [31:0]                    parser_price;
    logic [1:0]                     parser_action;
    logic                           parser_valid;
    logic [STOCK_LEN-1:0]           parser_stock_id;
    logic [47:0]                    parser_timestamp;
    
    integer                         csv_file;
    integer                         trading_csv_file;
    integer                         row_count;
    integer                         sent_count;
    integer                         scan_items;
    string                          line;
    real                            ts_seconds;
    integer                         msg_type;
    integer                         raw_order_id;
    integer                         mapped_order_id;
    integer                         shares;
    integer                         price;
    integer                         direction;
    longint unsigned                order_time_ns;
    integer                         quote_payload_count_by_stock [1:NUM_STOCKS];
    integer                         exec_count_by_stock [1:NUM_STOCKS];
    integer                         bid_fill_count_by_stock [1:NUM_STOCKS];
    integer                         ask_fill_count_by_stock [1:NUM_STOCKS];
    integer                         bid_reject_count_by_stock [1:NUM_STOCKS];
    integer                         ask_reject_count_by_stock [1:NUM_STOCKS];
    integer                         reject_reason_count_by_stock [1:NUM_STOCKS][0:15];

    integer                         raw_to_mapped_oid [longint unsigned];
    integer                         raw_remaining_qty [longint unsigned];
    integer                         next_mapped_oid [1:NUM_STOCKS];
    integer                         free_mapped_oid [1:NUM_STOCKS][$];
    localparam int MAX_MAPPED_ORDER_ID = (1 << ORDERID_LEN) - 1;

    function automatic [PRICE_LEN-1:0] scale_price_to_book(
        input logic [31:0] raw_price
    );
        integer scaled_price;
        begin
            scaled_price = raw_price / BOOK_PRICE_DIVISOR;
            if (scaled_price < 0)
                scale_price_to_book = '0;
            else if (scaled_price > ((1 << PRICE_LEN) - 1))
                scale_price_to_book = {PRICE_LEN{1'b1}};
            else
                scale_price_to_book = scaled_price[PRICE_LEN-1:0];
        end
    endfunction

    function automatic [QUANTITY_LEN-1:0] clamp_quantity_to_book(
        input logic [31:0] raw_quantity
    );
        begin
            if (raw_quantity > ((1 << QUANTITY_LEN) - 1))
                clamp_quantity_to_book = {QUANTITY_LEN{1'b1}};
            else
                clamp_quantity_to_book = raw_quantity[QUANTITY_LEN-1:0];
        end
    endfunction
        
    parser ps(
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_payload(market_payload),
        .i_valid(market_valid),
        .o_order_id(parser_order_id),
        .o_quantity(parser_quantity),
        .o_side(parser_side),
        .o_price(parser_price),
        .o_action(parser_action),
        .o_valid(parser_valid),
        .o_stock_id(parser_stock_id),
        .o_timestamp(parser_timestamp)
    );

    assign parser_price_book   = scale_price_to_book(parser_price);
    assign parser_quantity_book = clamp_quantity_to_book(parser_quantity);

    hft_multi_stock_top #(
        .AAPL_BOOK_BASE_PRICE(AAPL_BOOK_BASE_PRICE),
        .AMZN_BOOK_BASE_PRICE(AMZN_BOOK_BASE_PRICE),
        .INTC_BOOK_BASE_PRICE(INTC_BOOK_BASE_PRICE),
        .MSFT_BOOK_BASE_PRICE(MSFT_BOOK_BASE_PRICE)
    ) dut (
        .i_clk               (clk),
        .i_rst_n             (rst_n),
        .i_order_id          (parser_order_id[ORDERID_LEN-1:0]),
        .i_quantity          (parser_quantity_book),
        .i_side              (parser_side),
        .i_price             (parser_price_book),
        .i_action            (parser_action),
        .i_valid             (parser_valid),
        .i_stock_id          (parser_stock_id),
        .i_timestamp         (parser_timestamp),

        .i_bid_quote_quantity(bid_quote_quantity),
        .i_ask_quote_quantity(ask_quote_quantity),
        .i_trading_enable    (trading_enable),
        .i_kill_switch       (kill_switch),
        .i_price_band_enable (price_band_enable),
        .i_pnl_check_enable  (pnl_check_enable),
        .o_stock_id          (stock_id),
        .o_best_bid_price    (best_bid_price),
        .o_best_ask_price    (best_ask_price),
        .o_best_bid_valid    (best_bid_valid),
        .o_best_ask_valid    (best_ask_valid),
        .o_trading_bid_price (trading_bid_price),
        .o_trading_ask_price (trading_ask_price),
        .o_trading_order_type(trading_order_type),
        .o_trading_valid     (trading_valid),
        .o_bid_reject_valid  (bid_reject_valid),
        .o_bid_reject_reason (bid_reject_reason),
        .o_ask_reject_valid  (ask_reject_valid),
        .o_ask_reject_reason (ask_reject_reason),
        .o_order_payload_valid(order_payload_valid),
        .o_order_payload     (order_payload),
        .o_exec_valid        (exec_valid),
        .o_exec_side         (exec_side),
        .o_exec_price        (exec_price),
        .o_exec_quantity     (exec_quantity),
        .o_exec_order_id     (exec_order_id),
        .o_position          (position),
        .o_day_pnl           (day_pnl),
        .o_live_bid_qty      (live_bid_qty),
        .o_live_ask_qty      (live_ask_qty)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic [287:0] build_add_payload(
        input [15:0] stock_id_in,
        input [63:0] order_id_in,
        input bit    is_sell,
        input [31:0] quantity_in,
        input [31:0] price_in,
        input [47:0] timestamp_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h41;                  // byte 0: message type
        p[15:8]    = stock_id_in[15:8];      // bytes 1-2: stock locate
        p[23:16]   = stock_id_in[7:0];
        p[47:40]   = timestamp_in[47:40];    // bytes 5-10: timestamp
        p[55:48]   = timestamp_in[39:32];
        p[63:56]   = timestamp_in[31:24];
        p[71:64]   = timestamp_in[23:16];
        p[79:72]   = timestamp_in[15:8];
        p[87:80]   = timestamp_in[7:0];
        p[95:88]   = order_id_in[63:56];     // bytes 11-18: order ref
        p[103:96]  = order_id_in[55:48];
        p[111:104] = order_id_in[47:40];
        p[119:112] = order_id_in[39:32];
        p[127:120] = order_id_in[31:24];
        p[135:128] = order_id_in[23:16];
        p[143:136] = order_id_in[15:8];
        p[151:144] = order_id_in[7:0];
        p[159:152] = is_sell ? 8'h53 : 8'h42; // byte 19: side
        p[167:160] = quantity_in[31:24];     // bytes 20-23: quantity
        p[175:168] = quantity_in[23:16];
        p[183:176] = quantity_in[15:8];
        p[191:184] = quantity_in[7:0];
        p[263:256] = price_in[31:24];        // bytes 32-35: price
        p[271:264] = price_in[23:16];
        p[279:272] = price_in[15:8];
        p[287:280] = price_in[7:0];
        return p;
    endfunction

    function automatic [287:0] build_cancel_payload(
        input [15:0] stock_id_in,
        input [63:0] order_id_in,
        input bit    is_sell,
        input [31:0] quantity_in,
        input [31:0] price_in,
        input [47:0] timestamp_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h58;
        p[15:8]    = stock_id_in[15:8];
        p[23:16]   = stock_id_in[7:0];
        p[47:40]   = timestamp_in[47:40];
        p[55:48]   = timestamp_in[39:32];
        p[63:56]   = timestamp_in[31:24];
        p[71:64]   = timestamp_in[23:16];
        p[79:72]   = timestamp_in[15:8];
        p[87:80]   = timestamp_in[7:0];
        p[95:88]   = order_id_in[63:56];
        p[103:96]  = order_id_in[55:48];
        p[111:104] = order_id_in[47:40];
        p[119:112] = order_id_in[39:32];
        p[127:120] = order_id_in[31:24];
        p[135:128] = order_id_in[23:16];
        p[143:136] = order_id_in[15:8];
        p[151:144] = order_id_in[7:0];
        p[159:152] = quantity_in[31:24];     // bytes 19-22: canceled shares
        p[167:160] = quantity_in[23:16];
        p[175:168] = quantity_in[15:8];
        p[183:176] = quantity_in[7:0];
        return p;
    endfunction

    function automatic [287:0] build_delete_payload(
        input [15:0] stock_id_in,
        input [63:0] order_id_in,
        input bit    is_sell,
        input [31:0] quantity_in,
        input [31:0] price_in,
        input [47:0] timestamp_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h44;
        p[15:8]    = stock_id_in[15:8];
        p[23:16]   = stock_id_in[7:0];
        p[47:40]   = timestamp_in[47:40];
        p[55:48]   = timestamp_in[39:32];
        p[63:56]   = timestamp_in[31:24];
        p[71:64]   = timestamp_in[23:16];
        p[79:72]   = timestamp_in[15:8];
        p[87:80]   = timestamp_in[7:0];
        p[95:88]   = order_id_in[63:56];
        p[103:96]  = order_id_in[55:48];
        p[111:104] = order_id_in[47:40];
        p[119:112] = order_id_in[39:32];
        p[127:120] = order_id_in[31:24];
        p[135:128] = order_id_in[23:16];
        p[143:136] = order_id_in[15:8];
        p[151:144] = order_id_in[7:0];
        return p;
    endfunction

    function automatic [287:0] build_execute_payload(
        input [15:0] stock_id_in,
        input [63:0] order_id_in,
        input bit    is_sell,
        input [31:0] quantity_in,
        input [31:0] price_in,
        input [47:0] timestamp_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h45;
        p[15:8]    = stock_id_in[15:8];
        p[23:16]   = stock_id_in[7:0];
        p[47:40]   = timestamp_in[47:40];
        p[55:48]   = timestamp_in[39:32];
        p[63:56]   = timestamp_in[31:24];
        p[71:64]   = timestamp_in[23:16];
        p[79:72]   = timestamp_in[15:8];
        p[87:80]   = timestamp_in[7:0];
        p[95:88]   = order_id_in[63:56];
        p[103:96]  = order_id_in[55:48];
        p[111:104] = order_id_in[47:40];
        p[119:112] = order_id_in[39:32];
        p[127:120] = order_id_in[31:24];
        p[135:128] = order_id_in[23:16];
        p[143:136] = order_id_in[15:8];
        p[151:144] = order_id_in[7:0];
        p[159:152] = quantity_in[31:24];     // bytes 19-22: executed shares
        p[167:160] = quantity_in[23:16];
        p[175:168] = quantity_in[15:8];
        p[183:176] = quantity_in[7:0];
        return p;
    endfunction

    function automatic longint unsigned order_key(
        input integer stock_id_in,
        input integer lobster_order_id
    );
        begin
            order_key = ({32'd0, stock_id_in[31:0]} << 32)
                      |  {32'd0, lobster_order_id[31:0]};
        end
    endfunction

    function automatic integer get_mapped_order_id(
        input integer stock_id_in,
        input integer lobster_order_id,
        input integer lobster_msg_type,
        input integer lobster_quantity
    );
        longint unsigned key;
        integer mapped_id;
        integer next_qty;
        begin
            key = order_key(stock_id_in, lobster_order_id);
            if (lobster_msg_type == 1) begin
                if (!raw_to_mapped_oid.exists(key)) begin
                    if (free_mapped_oid[stock_id_in].size() > 0) begin
                        raw_to_mapped_oid[key] = free_mapped_oid[stock_id_in].pop_back();
                    end
                    else begin
                        if (next_mapped_oid[stock_id_in] > MAX_MAPPED_ORDER_ID)
                            $fatal(1, "Mapped order-id pool exhausted for stock_id=%0d (max=%0d)", stock_id_in, MAX_MAPPED_ORDER_ID);
                        raw_to_mapped_oid[key] = next_mapped_oid[stock_id_in];
                        next_mapped_oid[stock_id_in] = next_mapped_oid[stock_id_in] + 1;
                    end
                end
                raw_remaining_qty[key] = lobster_quantity;
                return raw_to_mapped_oid[key];
            end

            if (!raw_to_mapped_oid.exists(key))
                return 0;

            mapped_id = raw_to_mapped_oid[key];
            if (lobster_msg_type == 2 || lobster_msg_type == 4) begin
                if (raw_remaining_qty.exists(key))
                    next_qty = raw_remaining_qty[key] - lobster_quantity;
                else
                    next_qty = 0;

                if (next_qty <= 0) begin
                    raw_remaining_qty.delete(key);
                    raw_to_mapped_oid.delete(key);
                    free_mapped_oid[stock_id_in].push_back(mapped_id);
                end
                else begin
                    raw_remaining_qty[key] = next_qty;
                end
            end
            else if (lobster_msg_type == 3) begin
                raw_remaining_qty.delete(key);
                raw_to_mapped_oid.delete(key);
                free_mapped_oid[stock_id_in].push_back(mapped_id);
            end
            return mapped_id;
        end
    endfunction

    task automatic drive_payload(
        input [287:0] payload_in,
        input [47:0] order_time_in,
        input string row_desc
    );
        begin
            @(negedge clk);
            market_payload = payload_in;
            market_valid   = 1'b1;
            order_time     = order_time_in;
            @(negedge clk);
            market_valid   = 1'b0;
            market_payload = '0;
            if (VERBOSE_LOGS)
                $display("[%0t] sent row: %s", $time, row_desc);
            repeat (2) @(posedge clk);
        end
    endtask

    function automatic [FULL_PRICE_LEN-1:0] calc_mark_price_local(
        input logic [FULL_PRICE_LEN-1:0] best_bid_in,
        input logic [FULL_PRICE_LEN-1:0] best_ask_in,
        input logic                      bid_valid_in,
        input logic                      ask_valid_in
    );
        begin
            if (bid_valid_in && ask_valid_in)
                calc_mark_price_local = (best_bid_in + best_ask_in) >> 1;
            else if (bid_valid_in)
                calc_mark_price_local = best_bid_in;
            else if (ask_valid_in)
                calc_mark_price_local = best_ask_in;
            else
                calc_mark_price_local = '0;
        end
    endfunction

    task automatic print_stock_summary(input integer stock_idx);
        string name;
        logic [FULL_PRICE_LEN-1:0] best_bid_local;
        logic [FULL_PRICE_LEN-1:0] best_ask_local;
        logic                      best_bid_valid_local;
        logic                      best_ask_valid_local;
        logic [FULL_PRICE_LEN-1:0] trading_bid_local;
        logic [FULL_PRICE_LEN-1:0] trading_ask_local;
        logic signed [POSITION_LEN-1:0] position_local;
        logic signed [PNL_LEN-1:0] day_pnl_local;
        logic [TOT_QUATITY_LEN-1:0] live_bid_qty_local;
        logic [TOT_QUATITY_LEN-1:0] live_ask_qty_local;
        longint signed total_pnl_local;
        longint signed inventory_value_local;
        logic [FULL_PRICE_LEN-1:0] mark_price_local;
        begin
            name = "UNKNOWN";
            best_bid_local = '0;
            best_ask_local = '0;
            best_bid_valid_local = 1'b0;
            best_ask_valid_local = 1'b0;
            trading_bid_local = '0;
            trading_ask_local = '0;
            position_local = '0;
            day_pnl_local = '0;
            live_bid_qty_local = '0;
            live_ask_qty_local = '0;

            case (stock_idx)
                1: begin
                    name = "AAPL";
                    best_bid_local = dut.best_bid_price_1;
                    best_ask_local = dut.best_ask_price_1;
                    best_bid_valid_local = dut.best_bid_valid_1;
                    best_ask_valid_local = dut.best_ask_valid_1;
                    trading_bid_local = dut.trading_bid_price_1;
                    trading_ask_local = dut.trading_ask_price_1;
                    position_local = dut.position_1;
                    day_pnl_local = dut.day_pnl_1;
                    live_bid_qty_local = dut.live_bid_qty_1;
                    live_ask_qty_local = dut.live_ask_qty_1;
                end
                2: begin
                    name = "AMZN";
                    best_bid_local = dut.best_bid_price_2;
                    best_ask_local = dut.best_ask_price_2;
                    best_bid_valid_local = dut.best_bid_valid_2;
                    best_ask_valid_local = dut.best_ask_valid_2;
                    trading_bid_local = dut.trading_bid_price_2;
                    trading_ask_local = dut.trading_ask_price_2;
                    position_local = dut.position_2;
                    day_pnl_local = dut.day_pnl_2;
                    live_bid_qty_local = dut.live_bid_qty_2;
                    live_ask_qty_local = dut.live_ask_qty_2;
                end
                3: begin
                    name = "INTC";
                    best_bid_local = dut.best_bid_price_3;
                    best_ask_local = dut.best_ask_price_3;
                    best_bid_valid_local = dut.best_bid_valid_3;
                    best_ask_valid_local = dut.best_ask_valid_3;
                    trading_bid_local = dut.trading_bid_price_3;
                    trading_ask_local = dut.trading_ask_price_3;
                    position_local = dut.position_3;
                    day_pnl_local = dut.day_pnl_3;
                    live_bid_qty_local = dut.live_bid_qty_3;
                    live_ask_qty_local = dut.live_ask_qty_3;
                end
                4: begin
                    name = "MSFT";
                    best_bid_local = dut.best_bid_price_4;
                    best_ask_local = dut.best_ask_price_4;
                    best_bid_valid_local = dut.best_bid_valid_4;
                    best_ask_valid_local = dut.best_ask_valid_4;
                    trading_bid_local = dut.trading_bid_price_4;
                    trading_ask_local = dut.trading_ask_price_4;
                    position_local = dut.position_4;
                    day_pnl_local = dut.day_pnl_4;
                    live_bid_qty_local = dut.live_bid_qty_4;
                    live_ask_qty_local = dut.live_ask_qty_4;
                end
                default: begin
                end
            endcase

            mark_price_local = calc_mark_price_local(
                best_bid_local,
                best_ask_local,
                best_bid_valid_local,
                best_ask_valid_local
            );
            total_pnl_local = calc_total_pnl(day_pnl_local, position_local, mark_price_local);
            inventory_value_local = total_pnl_local - day_pnl_local;

            $display("--- %s (stock_id=%0d) ---", name, stock_idx);
            $display("position=%0d realized_pnl=%0d mtm_total_pnl=%0d inventory_value=%0d",
                position_local, day_pnl_local, total_pnl_local, inventory_value_local);
            $display("best_bid=%0d valid=%0b best_ask=%0d valid=%0b mark_price=%0d",
                best_bid_local, best_bid_valid_local, best_ask_local, best_ask_valid_local, mark_price_local);
            $display("trading_bid=%0d trading_ask=%0d live_bid_qty=%0d live_ask_qty=%0d",
                trading_bid_local, trading_ask_local, live_bid_qty_local, live_ask_qty_local);
            $display("quote_payloads=%0d executions=%0d bid_fills=%0d ask_fills=%0d bid_rejects=%0d ask_rejects=%0d",
                quote_payload_count_by_stock[stock_idx],
                exec_count_by_stock[stock_idx],
                bid_fill_count_by_stock[stock_idx],
                ask_fill_count_by_stock[stock_idx],
                bid_reject_count_by_stock[stock_idx],
                ask_reject_count_by_stock[stock_idx]);
        end
    endtask

    function automatic longint signed calc_total_pnl(
        input logic signed [PNL_LEN-1:0] realized_pnl_in,
        input logic signed [POSITION_LEN-1:0] position_in,
        input logic [FULL_PRICE_LEN-1:0] mark_price_in
    );
        longint signed realized_pnl_long;
        longint signed position_long;
        longint signed mark_price_long;
        begin
            realized_pnl_long = realized_pnl_in;
            position_long = position_in;
            mark_price_long = mark_price_in;
            calc_total_pnl = realized_pnl_long + (position_long * mark_price_long);
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_mark_price <= '0;
            tb_mark_price_valid <= 1'b0;
        end
        else begin
            if (best_bid_valid && best_ask_valid) begin
                tb_mark_price <= (best_bid_price + best_ask_price) >> 1;
                tb_mark_price_valid <= 1'b1;
            end
            else if (best_bid_valid) begin
                tb_mark_price <= best_bid_price;
                tb_mark_price_valid <= 1'b1;
            end
            else if (best_ask_valid) begin
                tb_mark_price <= best_ask_price;
                tb_mark_price_valid <= 1'b1;
            end
        end
    end

    always_comb begin
        if (tb_mark_price_valid)
            tb_total_pnl = calc_total_pnl(day_pnl, position, tb_mark_price);
        else
            tb_total_pnl = day_pnl;
    end

    always @(posedge clk) begin
        if (dut.order_payload_valid_1) begin
            quote_payload_count_by_stock[1] = quote_payload_count_by_stock[1] + 1;
            if (VERBOSE_LOGS)
                $display("[%0t] AAPL quote payload valid", $time);
        end
        if (dut.order_payload_valid_2) begin
            quote_payload_count_by_stock[2] = quote_payload_count_by_stock[2] + 1;
            if (VERBOSE_LOGS)
                $display("[%0t] AMZN quote payload valid", $time);
        end
        if (dut.order_payload_valid_3) begin
            quote_payload_count_by_stock[3] = quote_payload_count_by_stock[3] + 1;
            if (VERBOSE_LOGS)
                $display("[%0t] INTC quote payload valid", $time);
        end
        if (dut.order_payload_valid_4) begin
            quote_payload_count_by_stock[4] = quote_payload_count_by_stock[4] + 1;
            if (VERBOSE_LOGS)
                $display("[%0t] MSFT quote payload valid", $time);
        end

        if (dut.exec_valid_1) begin
            exec_count_by_stock[1] = exec_count_by_stock[1] + 1;
            if (dut.exec_side_1)
                ask_fill_count_by_stock[1] = ask_fill_count_by_stock[1] + 1;
            else
                bid_fill_count_by_stock[1] = bid_fill_count_by_stock[1] + 1;
        end
        if (dut.exec_valid_2) begin
            exec_count_by_stock[2] = exec_count_by_stock[2] + 1;
            if (dut.exec_side_2)
                ask_fill_count_by_stock[2] = ask_fill_count_by_stock[2] + 1;
            else
                bid_fill_count_by_stock[2] = bid_fill_count_by_stock[2] + 1;
        end
        if (dut.exec_valid_3) begin
            exec_count_by_stock[3] = exec_count_by_stock[3] + 1;
            if (dut.exec_side_3)
                ask_fill_count_by_stock[3] = ask_fill_count_by_stock[3] + 1;
            else
                bid_fill_count_by_stock[3] = bid_fill_count_by_stock[3] + 1;
        end
        if (dut.exec_valid_4) begin
            exec_count_by_stock[4] = exec_count_by_stock[4] + 1;
            if (dut.exec_side_4)
                ask_fill_count_by_stock[4] = ask_fill_count_by_stock[4] + 1;
            else
                bid_fill_count_by_stock[4] = bid_fill_count_by_stock[4] + 1;
        end

        if (dut.bid_reject_valid_1) begin
            bid_reject_count_by_stock[1] = bid_reject_count_by_stock[1] + 1;
            reject_reason_count_by_stock[1][dut.bid_reject_reason_1] = reject_reason_count_by_stock[1][dut.bid_reject_reason_1] + 1;
        end
        if (dut.ask_reject_valid_1) begin
            ask_reject_count_by_stock[1] = ask_reject_count_by_stock[1] + 1;
            reject_reason_count_by_stock[1][dut.ask_reject_reason_1] = reject_reason_count_by_stock[1][dut.ask_reject_reason_1] + 1;
        end
        if (dut.bid_reject_valid_2) begin
            bid_reject_count_by_stock[2] = bid_reject_count_by_stock[2] + 1;
            reject_reason_count_by_stock[2][dut.bid_reject_reason_2] = reject_reason_count_by_stock[2][dut.bid_reject_reason_2] + 1;
        end
        if (dut.ask_reject_valid_2) begin
            ask_reject_count_by_stock[2] = ask_reject_count_by_stock[2] + 1;
            reject_reason_count_by_stock[2][dut.ask_reject_reason_2] = reject_reason_count_by_stock[2][dut.ask_reject_reason_2] + 1;
        end
        if (dut.bid_reject_valid_3) begin
            bid_reject_count_by_stock[3] = bid_reject_count_by_stock[3] + 1;
            reject_reason_count_by_stock[3][dut.bid_reject_reason_3] = reject_reason_count_by_stock[3][dut.bid_reject_reason_3] + 1;
        end
        if (dut.ask_reject_valid_3) begin
            ask_reject_count_by_stock[3] = ask_reject_count_by_stock[3] + 1;
            reject_reason_count_by_stock[3][dut.ask_reject_reason_3] = reject_reason_count_by_stock[3][dut.ask_reject_reason_3] + 1;
        end
        if (dut.bid_reject_valid_4) begin
            bid_reject_count_by_stock[4] = bid_reject_count_by_stock[4] + 1;
            reject_reason_count_by_stock[4][dut.bid_reject_reason_4] = reject_reason_count_by_stock[4][dut.bid_reject_reason_4] + 1;
        end
        if (dut.ask_reject_valid_4) begin
            ask_reject_count_by_stock[4] = ask_reject_count_by_stock[4] + 1;
            reject_reason_count_by_stock[4][dut.ask_reject_reason_4] = reject_reason_count_by_stock[4][dut.ask_reject_reason_4] + 1;
        end
    end

    initial begin
        integer reason_idx;
        integer stock_idx;
        rst_n             = 1'b0;
        market_payload    = '0;
        market_valid      = 1'b0;
        order_time        = '0;
        symbol            = '0;
        bid_quote_quantity= 16'd5;
        ask_quote_quantity= 16'd5;
        trading_enable    = 1'b1;
        kill_switch       = 1'b0;
        price_band_enable = 1'b1;
        pnl_check_enable  = 1'b1;
        row_count         = 0;
        sent_count        = 0;
        for (stock_idx = 1; stock_idx <= NUM_STOCKS; stock_idx = stock_idx + 1) begin
            next_mapped_oid[stock_idx] = 1;
            quote_payload_count_by_stock[stock_idx] = 0;
            exec_count_by_stock[stock_idx] = 0;
            bid_fill_count_by_stock[stock_idx] = 0;
            ask_fill_count_by_stock[stock_idx] = 0;
            bid_reject_count_by_stock[stock_idx] = 0;
            ask_reject_count_by_stock[stock_idx] = 0;
            for (reason_idx = 0; reason_idx < 16; reason_idx = reason_idx + 1)
                reject_reason_count_by_stock[stock_idx][reason_idx] = 0;
        end

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        csv_file = $fopen(LOBSTER_MESSAGE_CSV, "r");
        if (csv_file == 0) begin
            $fatal(1, "Could not open LOBSTER CSV file");
        end
        // trading_csv_file = $fopen("trading_logic_quotes.csv", "w");
        // if (trading_csv_file == 0) begin
        //     $fatal(1, "Could not open trading logic quotes CSV output file");
        // end
        // $fdisplay(trading_csv_file, "sim_time_ns,trading_bid_price,trading_ask_price,trading_order_type,best_bid_price,best_ask_price,position,day_pnl,stock_id");

        $display("=== HFT Four-Stock LOBSTER Replay ===");
        $display("Streaming merged four-stock file: %s", LOBSTER_MESSAGE_CSV);
        $display("Row limit for this run: %0d", MAX_REPLAY_ROWS);

        while (!$feof(csv_file)) begin
            line = "";
            void'($fgets(line, csv_file));
            if (line.len() == 0)
                continue;

            row_count = row_count + 1;
            if ((MAX_REPLAY_ROWS > 0) && (row_count > MAX_REPLAY_ROWS)) begin
                $display("[info] Reached row limit %0d, stopping replay early for this run.", MAX_REPLAY_ROWS);
                break;
            end
            scan_items = $sscanf(line, "%f,%d,%d,%d,%d,%d,%d",
                                 ts_seconds, msg_type, raw_order_id, shares, price, direction, stock_id_i);
            if (scan_items != 7) begin
                $display("Skipping row %0d: could not parse -> %s", row_count, line);
                continue;
            end

            if ((PROGRESS_ROWS > 0) && ((row_count % PROGRESS_ROWS) == 0))
                $display("[progress] rows_read=%0d messages_sent=%0d last_stock_id=%0d", row_count, sent_count, stock_id_i);

            order_time_ns = longint'(ts_seconds * 1.0e9);

            case (msg_type)
                1: begin
                    mapped_order_id = get_mapped_order_id(stock_id_i, raw_order_id, msg_type, shares);
                    sent_count = sent_count + 1;
                    drive_payload(
                        build_add_payload(
                            stock_id_i,
                            mapped_order_id,
                            (direction == -1),
                            shares[31:0],
                            price[31:0],
                            order_time_ns[47:0]
                        ),
                        order_time_ns[47:0],
                        $sformatf("LOBSTER row %0d ADD stock_id=%0d raw_id=%0d map_id=%0d side=%0d qty=%0d px=%0d",
                                  row_count, stock_id_i, raw_order_id, mapped_order_id, direction, shares, price)
                    );
                end
                2: begin
                    mapped_order_id = get_mapped_order_id(stock_id_i, raw_order_id, msg_type, shares);
                    if (mapped_order_id != 0) begin
                        sent_count = sent_count + 1;
                        drive_payload(
                        build_cancel_payload(
                            stock_id_i,
                            mapped_order_id,
                            (direction == -1),
                            shares[31:0],
                            price[31:0],
                            order_time_ns[47:0]
                        ),
                            order_time_ns[47:0],
                            $sformatf("LOBSTER row %0d CANCEL stock_id=%0d raw_id=%0d map_id=%0d qty=%0d",
                                      row_count, stock_id_i, raw_order_id, mapped_order_id, shares)
                        );
                    end
                    else begin
                        if (VERBOSE_LOGS)
                            $display("Skipping row %0d CANCEL: stock_id=%0d raw order id %0d not mapped yet", row_count, stock_id_i, raw_order_id);
                    end
                end
                3: begin
                    mapped_order_id = get_mapped_order_id(stock_id_i, raw_order_id, msg_type, shares);
                    if (mapped_order_id != 0) begin
                        sent_count = sent_count + 1;
                        drive_payload(
                            build_delete_payload(
                                stock_id_i,
                                mapped_order_id,
                                (direction == -1),
                                shares[31:0],
                                price[31:0],
                                order_time_ns[47:0]
                            ),
                            order_time_ns[47:0],
                            $sformatf("LOBSTER row %0d DELETE stock_id=%0d raw_id=%0d map_id=%0d",
                                      row_count, stock_id_i, raw_order_id, mapped_order_id)
                        );
                    end
                    else begin
                        if (VERBOSE_LOGS)
                            $display("Skipping row %0d DELETE: stock_id=%0d raw order id %0d not mapped yet", row_count, stock_id_i, raw_order_id);
                    end
                end
                4: begin
                    mapped_order_id = get_mapped_order_id(stock_id_i, raw_order_id, msg_type, shares);
                    if (mapped_order_id != 0) begin
                        sent_count = sent_count + 1;
                        drive_payload(
                            build_execute_payload(
                                stock_id_i,
                                mapped_order_id,
                                (direction == -1),
                                shares[31:0],
                                price[31:0],
                                order_time_ns[47:0]
                            ),
                            order_time_ns[47:0],
                            $sformatf("LOBSTER row %0d EXECUTE stock_id=%0d raw_id=%0d map_id=%0d qty=%0d px=%0d",
                                      row_count, stock_id_i, raw_order_id, mapped_order_id, shares, price)
                        );
                    end
                    else begin
                        if (VERBOSE_LOGS)
                            $display("Skipping row %0d EXECUTE: stock_id=%0d raw order id %0d not mapped yet", row_count, stock_id_i, raw_order_id);
                    end
                end
                default: begin
                    if (VERBOSE_LOGS)
                        $display("Skipping row %0d unsupported LOBSTER type %0d", row_count, msg_type);
                end
            endcase
        end

        $fclose(csv_file);

        repeat (80) @(posedge clk);
        // $fclose(trading_csv_file);
        $display("=== Replay Done ===");
        $display("Rows read=%0d messages sent=%0d", row_count, sent_count);
        for (stock_idx = 1; stock_idx <= NUM_STOCKS; stock_idx = stock_idx + 1) begin
            print_stock_summary(stock_idx);
            for (reason_idx = 0; reason_idx < 16; reason_idx = reason_idx + 1) begin
                if (reject_reason_count_by_stock[stock_idx][reason_idx] != 0)
                    $display("stock_id=%0d reject_reason=%0d count=%0d",
                        stock_idx, reason_idx, reject_reason_count_by_stock[stock_idx][reason_idx]);
            end
        end
        $finish;
    end

endmodule
