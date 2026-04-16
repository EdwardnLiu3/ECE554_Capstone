`timescale 1ns/1ps
// This was working on mine before, have not updated it for any file changes. 
module tb_hft_single_stock_top_lobster;

    localparam int MARKET_PAYLOAD_LEN = 288;
    localparam int OUCH_PAYLOAD_LEN   = 752;
    localparam int PRICE_LEN          = 32;
    localparam int QUANTITY_LEN       = 16;
    localparam int ORDER_ID_LEN       = 32;
    localparam int POSITION_LEN       = 16;
    localparam int PNL_LEN            = 64;
    localparam int STOCK_LEN          = 16;
    localparam int MAX_ROWS_TO_READ   = 40000;
    localparam int MAX_SUPPORTED_SEND = 40000;
    localparam [STOCK_LEN-1:0] STOCK_ID = 16'h0001;
    localparam [63:0] SYMBOL_AMZN = {"A","M","Z","N"," "," "," "," "};

    logic                           clk;
    logic                           rst_n;
    logic [MARKET_PAYLOAD_LEN-1:0]  market_payload;
    logic                           market_valid;
    logic [47:0]                    order_time;
    logic [63:0]                    symbol;
    logic [QUANTITY_LEN-1:0]        bid_quote_quantity;
    logic [QUANTITY_LEN-1:0]        ask_quote_quantity;
    logic                           trading_enable;
    logic                           kill_switch;
    logic                           price_band_enable;
    logic                           pnl_check_enable;

    logic [STOCK_LEN-1:0]           stock_id;
    logic [PRICE_LEN-1:0]           best_bid_price;
    logic [PRICE_LEN-1:0]           best_ask_price;
    logic                           best_bid_valid;
    logic                           best_ask_valid;
    logic [PRICE_LEN-1:0]           trading_bid_price;
    logic [PRICE_LEN-1:0]           trading_ask_price;
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
    logic [PRICE_LEN-1:0]           exec_price;
    logic [QUANTITY_LEN-1:0]        exec_quantity;
    logic [ORDER_ID_LEN-1:0]        exec_order_id;
    logic signed [POSITION_LEN-1:0] position;
    logic signed [PNL_LEN-1:0]      day_pnl;
    logic [QUANTITY_LEN-1:0]        live_bid_qty;
    logic [QUANTITY_LEN-1:0]        live_ask_qty;

    integer                         csv_file;
    integer                         trading_csv_file;
    integer                         row_count;
    integer                         sent_count;
    integer                         scan_items;
    string                          line;
    real                            ts_seconds;
    integer                         msg_type;
    integer                         raw_order_id;
    integer                         shares;
    integer                         price;
    integer                         direction;
    longint unsigned                order_time_ns;
    integer                         quote_payload_count;
    integer                         exec_count;
    integer                         bid_fill_count;
    integer                         ask_fill_count;
    integer                         bid_reject_count;
    integer                         ask_reject_count;
    integer                         reject_reason_count [0:15];

    integer                         raw_to_mapped_oid [integer];
    integer                         next_mapped_oid;

    hft_single_stock_top dut (
        .i_clk               (clk),
        .i_rst_n             (rst_n),
        .i_market_payload    (market_payload),
        .i_market_valid      (market_valid),
        .i_order_time        (order_time),
        .i_symbol            (symbol),
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
        input [31:0] price_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h41;
        p[23:8]    = stock_id_in;
        p[151:88]  = order_id_in;
        p[159:152] = is_sell ? 8'h53 : 8'h42;
        p[191:160] = quantity_in;
        p[287:256] = price_in;
        return p;
    endfunction

    function automatic [287:0] build_cancel_payload(
        input [15:0] stock_id_in,
        input [63:0] order_id_in,
        input [31:0] quantity_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h58;
        p[23:8]    = stock_id_in;
        p[151:88]  = order_id_in;
        p[183:152] = quantity_in;
        return p;
    endfunction

    function automatic [287:0] build_delete_payload(
        input [15:0] stock_id_in,
        input [63:0] order_id_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h44;
        p[23:8]    = stock_id_in;
        p[151:88]  = order_id_in;
        return p;
    endfunction

    function automatic [287:0] build_execute_payload(
        input [15:0] stock_id_in,
        input [63:0] order_id_in,
        input [31:0] quantity_in
    );
        logic [287:0] p;
        p = '0;
        p[7:0]     = 8'h45;
        p[23:8]    = stock_id_in;
        p[151:88]  = order_id_in;
        p[183:152] = quantity_in;
        return p;
    endfunction

    function automatic integer get_mapped_order_id(
        input integer lobster_order_id,
        input integer lobster_msg_type
    );
        begin
            if (lobster_msg_type == 1) begin
                if (!raw_to_mapped_oid.exists(lobster_order_id)) begin
                    raw_to_mapped_oid[lobster_order_id] = next_mapped_oid;
                    next_mapped_oid = next_mapped_oid + 1;
                end
                return raw_to_mapped_oid[lobster_order_id];
            end
            else begin
                if (raw_to_mapped_oid.exists(lobster_order_id))
                    return raw_to_mapped_oid[lobster_order_id];
                else
                    return 0;
            end
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
            $display("[%0t] sent row: %s", $time, row_desc);
            repeat (2) @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (order_payload_valid) begin
            quote_payload_count = quote_payload_count + 1;
            $display("[%0t] quote payload valid | bid(id=%0d px=%0d qty=%0d) ask(id=%0d px=%0d qty=%0d) type=%0h/%0h",
                $time,
                dut.og_new_order_num_buy,
                dut.og_price_buy,
                dut.og_quantity_buy,
                dut.og_new_order_num_sell,
                dut.og_price_sell,
                dut.og_quantity_sell,
                order_payload[751:744],
                order_payload[375:368]
            );
        end

        if (trading_valid) begin
            $fdisplay(trading_csv_file, "%0t,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                $time,
                trading_bid_price,
                trading_ask_price,
                trading_order_type,
                best_bid_price,
                best_ask_price,
                position,
                day_pnl,
                stock_id
            );
        end

        if (exec_valid) begin
            exec_count = exec_count + 1;
            if (exec_side)
                ask_fill_count = ask_fill_count + 1;
            else
                bid_fill_count = bid_fill_count + 1;
            $display("[%0t] OUR FILL | side=%s order_id=%0d price=%0d qty=%0d | pos=%0d pnl=%0d",
                $time,
                exec_side ? "ASK" : "BID",
                exec_order_id,
                exec_price,
                exec_quantity,
                position,
                day_pnl
            );
        end

        if (bid_reject_valid || ask_reject_valid) begin
            if (bid_reject_valid) begin
                bid_reject_count = bid_reject_count + 1;
                reject_reason_count[bid_reject_reason] = reject_reason_count[bid_reject_reason] + 1;
            end
            if (ask_reject_valid) begin
                ask_reject_count = ask_reject_count + 1;
                reject_reason_count[ask_reject_reason] = reject_reason_count[ask_reject_reason] + 1;
            end
            $display("[%0t] risk reject | bid_reject=%0b reason=%0d ask_reject=%0b reason=%0d",
                $time,
                bid_reject_valid,
                bid_reject_reason,
                ask_reject_valid,
                ask_reject_reason
            );
        end
    end

    initial begin
        integer reason_idx;
        rst_n             = 1'b0;
        market_payload    = '0;
        market_valid      = 1'b0;
        order_time        = '0;
        symbol            = SYMBOL_AMZN;
        bid_quote_quantity= 16'd1;
        ask_quote_quantity= 16'd1;
        trading_enable    = 1'b1;
        kill_switch       = 1'b0;
        price_band_enable = 1'b1;
        pnl_check_enable  = 1'b1;
        row_count         = 0;
        sent_count        = 0;
        next_mapped_oid   = 1;
        quote_payload_count = 0;
        exec_count          = 0;
        bid_fill_count      = 0;
        ask_fill_count      = 0;
        bid_reject_count    = 0;
        ask_reject_count    = 0;
        for (reason_idx = 0; reason_idx < 16; reason_idx = reason_idx + 1)
            reject_reason_count[reason_idx] = 0;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        csv_file = $fopen("ITCH_Translator/LOBSTER_SampleFile_AMZN_2012-06-21_1/AMZN_2012-06-21_34200000_57600000_message_1.csv", "r");
        if (csv_file == 0) begin
            $fatal(1, "Could not open LOBSTER CSV file");
        end
        trading_csv_file = $fopen("trading_logic_quotes.csv", "w");
        if (trading_csv_file == 0) begin
            $fatal(1, "Could not open trading logic quotes CSV output file");
        end
        $fdisplay(trading_csv_file, "sim_time_ns,trading_bid_price,trading_ask_price,trading_order_type,best_bid_price,best_ask_price,position,day_pnl,stock_id");

        $display("=== HFT Single Stock LOBSTER Replay ===");
        $display("Reading first %0d rows, sending up to %0d supported rows", MAX_ROWS_TO_READ, MAX_SUPPORTED_SEND);

        while (!$feof(csv_file) && row_count < MAX_ROWS_TO_READ && sent_count < MAX_SUPPORTED_SEND) begin
            line = "";
            void'($fgets(line, csv_file));
            if (line.len() == 0)
                continue;

            row_count = row_count + 1;
            scan_items = $sscanf(line, "%f,%d,%d,%d,%d,%d",
                                 ts_seconds, msg_type, raw_order_id, shares, price, direction);
            if (scan_items != 6) begin
                $display("Skipping row %0d: could not parse -> %s", row_count, line);
                continue;
            end

            order_time_ns = longint'(ts_seconds * 1.0e9);

            case (msg_type)
                1: begin
                    sent_count = sent_count + 1;
                    drive_payload(
                        build_add_payload(
                            STOCK_ID,
                            get_mapped_order_id(raw_order_id, msg_type),
                            (direction == -1),
                            shares[31:0],
                            price[31:0]
                        ),
                        order_time_ns[47:0],
                        $sformatf("LOBSTER row %0d ADD raw_id=%0d map_id=%0d side=%0d qty=%0d px=%0d",
                                  row_count, raw_order_id, get_mapped_order_id(raw_order_id, msg_type), direction, shares, price)
                    );
                end
                2: begin
                    if (get_mapped_order_id(raw_order_id, msg_type) != 0) begin
                        sent_count = sent_count + 1;
                        drive_payload(
                            build_cancel_payload(
                                STOCK_ID,
                                get_mapped_order_id(raw_order_id, msg_type),
                                shares[31:0]
                            ),
                            order_time_ns[47:0],
                            $sformatf("LOBSTER row %0d CANCEL raw_id=%0d map_id=%0d qty=%0d",
                                      row_count, raw_order_id, get_mapped_order_id(raw_order_id, msg_type), shares)
                        );
                    end
                    else begin
                        $display("Skipping row %0d CANCEL: raw order id %0d not mapped yet", row_count, raw_order_id);
                    end
                end
                3: begin
                    if (get_mapped_order_id(raw_order_id, msg_type) != 0) begin
                        sent_count = sent_count + 1;
                        drive_payload(
                            build_delete_payload(
                                STOCK_ID,
                                get_mapped_order_id(raw_order_id, msg_type)
                            ),
                            order_time_ns[47:0],
                            $sformatf("LOBSTER row %0d DELETE raw_id=%0d map_id=%0d",
                                      row_count, raw_order_id, get_mapped_order_id(raw_order_id, msg_type))
                        );
                    end
                    else begin
                        $display("Skipping row %0d DELETE: raw order id %0d not mapped yet", row_count, raw_order_id);
                    end
                end
                4: begin
                    if (get_mapped_order_id(raw_order_id, msg_type) != 0) begin
                        sent_count = sent_count + 1;
                        drive_payload(
                            build_execute_payload(
                                STOCK_ID,
                                get_mapped_order_id(raw_order_id, msg_type),
                                shares[31:0]
                            ),
                            order_time_ns[47:0],
                            $sformatf("LOBSTER row %0d EXECUTE raw_id=%0d map_id=%0d qty=%0d px=%0d",
                                      row_count, raw_order_id, get_mapped_order_id(raw_order_id, msg_type), shares, price)
                        );
                    end
                    else begin
                        $display("Skipping row %0d EXECUTE: raw order id %0d not mapped yet", row_count, raw_order_id);
                    end
                end
                default: begin
                    $display("Skipping row %0d unsupported LOBSTER type %0d", row_count, msg_type);
                end
            endcase
        end

        $fclose(csv_file);

        repeat (80) @(posedge clk);
        $fclose(trading_csv_file);
        $display("=== Replay Done ===");
        $display("Final position=%0d pnl=%0d live_bid_qty=%0d live_ask_qty=%0d best_bid=%0d best_ask=%0d",
            position, day_pnl, live_bid_qty, live_ask_qty, best_bid_price, best_ask_price);
        $display("Summary: quote_payloads=%0d executions=%0d bid_fills=%0d ask_fills=%0d",
            quote_payload_count, exec_count, bid_fill_count, ask_fill_count);
        $display("Summary: bid_rejects=%0d ask_rejects=%0d total_rejects=%0d",
            bid_reject_count, ask_reject_count, bid_reject_count + ask_reject_count);
        for (reason_idx = 0; reason_idx < 16; reason_idx = reason_idx + 1) begin
            if (reject_reason_count[reason_idx] != 0)
                $display("Reject reason %0d count=%0d", reason_idx, reject_reason_count[reason_idx]);
        end
        $finish;
    end

endmodule
