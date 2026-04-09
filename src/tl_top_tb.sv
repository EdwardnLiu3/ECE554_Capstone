`timescale 1ns/1ps

module tl_top_tb;
    import ob_pkg::*;

    localparam CLK_PERIOD = 10;

    // $224.00 scaled x100 = 22400
    localparam [PRICE_LEN-1:0] BID      = 16'd22398;
    localparam [PRICE_LEN-1:0] ASK      = 16'd22402;
    localparam [PRICE_LEN-1:0] MID      = 16'd22400;
    localparam [47:0]          MID_DAY   = 48'd45_900_000_000_000;  // 12:45 PM
    localparam [47:0]          NEAR_CLOSE = 48'd57_000_000_000_000;  // 3:50 PM (10 min to close)

    logic                 i_clk, i_rst_n;
    logic [PRICE_LEN-1:0] i_best_bid, i_best_ask;
    logic [47:0]          i_order_time;
    logic                 i_price_valid;
    logic                 i_trade_valid;
    logic [15:0]          i_trade_qty;
    logic                 i_trade_side;
    logic [PRICE_LEN-1:0] o_bid_price, o_ask_price;
    logic [1:0]           o_order_type;
    logic                 o_valid;

    tl_top dut (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_best_bid   (i_best_bid),
        .i_best_ask   (i_best_ask),
        .i_order_time (i_order_time),
        .i_price_valid(i_price_valid),
        .i_trade_valid(i_trade_valid),
        .i_trade_qty  (i_trade_qty),
        .i_trade_side (i_trade_side),
        .o_bid_price  (o_bid_price),
        .o_ask_price  (o_ask_price),
        .o_order_type (o_order_type),
        .o_valid      (o_valid)
    );

    initial i_clk = 0;
    always #(CLK_PERIOD/2) i_clk = ~i_clk;

    // Send a price update then poll for o_valid (captures outputs when ready)
    task automatic send_and_capture(
        input  [PRICE_LEN-1:0] bid, ask,
        input  [47:0]          t,
        output [PRICE_LEN-1:0] out_bid, out_ask,
        output [1:0]           out_type,
        output                 timed_out
    );
        @(posedge i_clk);
        i_best_bid    <= bid;
        i_best_ask    <= ask;
        i_order_time  <= t;
        i_price_valid <= 1;
        @(posedge i_clk);
        i_price_valid <= 0;

        timed_out = 1;
        for (int i = 0; i < 300; i++) begin
            @(posedge i_clk);
            if (o_valid) begin
                out_bid   = o_bid_price;
                out_ask   = o_ask_price;
                out_type  = o_order_type;
                timed_out = 0;
                break;
            end
        end
    endtask

    task automatic send_trade(input [15:0] qty, input side);
        @(posedge i_clk);
        i_trade_qty   <= qty;
        i_trade_side  <= side;
        i_trade_valid <= 1;
        @(posedge i_clk);
        i_trade_valid <= 0;
    endtask

    logic [PRICE_LEN-1:0] bid_out, ask_out;
    logic [1:0]           type_out;
    logic                 timeout;

    // Reservation = (bid_out + ask_out) / 2
    logic [PRICE_LEN:0] reservation;
    assign reservation = (bid_out + ask_out) >> 1;

    initial begin
        logic [PRICE_LEN:0]   reservation_q0;
        logic [PRICE_LEN-1:0] bid_q0_out;
        logic [PRICE_LEN-1:0] ask_q0_out;
        logic [PRICE_LEN:0]   spread_q0;
        logic [PRICE_LEN:0]   reservation_q50;
        logic [PRICE_LEN:0]   spread_q50;
        logic [PRICE_LEN:0]   reservation_q_neg;
        logic [PRICE_LEN:0]   reservation_midday;
        logic [PRICE_LEN:0]   reservation_nearclose;

        i_best_bid    = '0;
        i_best_ask    = '0;
        i_order_time  = '0;
        i_price_valid = 0;
        i_trade_valid = 0;
        i_trade_qty   = '0;
        i_trade_side  = 0;
        i_rst_n       = 0;

        repeat(5) @(posedge i_clk);
        i_rst_n = 1;
        repeat(150) @(posedge i_clk);

        // Warm-up volatility
        for (int w = 0; w < 50; w++) begin
            if (w % 2 == 0)
                send_and_capture(16'd22396, 16'd22400, MID_DAY, bid_out, ask_out, type_out, timeout);
            else
                send_and_capture(16'd22400, 16'd22404, MID_DAY, bid_out, ask_out, type_out, timeout);
        end

        // Test 1: Mid price computation
        // Input bid=22398, ask=22402 so mid = (22398+22402)/2 = 22400
        // When q=0 reservation should equal mid
        $display("\n--- Test 1: Mid price = (bid + ask) / 2 ---");
        $display("Input: bid=%0d  ask=%0d  expected mid=%0d", BID, ASK, MID);

        send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out, type_out, timeout);

        if (timeout) begin
            $display("FAIL: timed out");
        end else begin
            $display("Output: bid=%0d  ask=%0d  implied reservation=%0d",
                     bid_out, ask_out, (bid_out + ask_out) >> 1);
            if (((bid_out + ask_out) >> 1) == MID)
                $display("PASS: reservation = mid = %0d", MID);
            else
                $display("FAIL: reservation = %0d, expected %0d",
                         (bid_out + ask_out) >> 1, MID);
        end

        // Test 2: q=0 reservation equals mid
        // r = mid - q*gamma*sigma^2*(T-t), q=0 so r = mid exactly
        $display("\n--- Test 2: q=0, reservation should equal mid ---");

        send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out, type_out, timeout);

        if (timeout) begin
            $display("FAIL: timed out");
        end else begin
            reservation_q0 = (bid_out + ask_out) >> 1;
            $display("q=0  reservation=%0d  mid=%0d", reservation_q0, MID);
            if (reservation_q0 == MID)
                $display("PASS: reservation = mid when q=0");
            else
                $display("FAIL: reservation %0d != mid %0d", reservation_q0, MID);
        end

        // Test 3: q>0 shifts reservation below mid
        // r = mid - q*gamma*sigma^2*(T-t), q=50 so now should be r < mid (~22375 expected)
        $display("\n--- Test 3: q=50 (long), reservation should shift below mid ---");

        bid_q0_out = bid_out;
        ask_q0_out = ask_out;
        spread_q0  = ask_q0_out - bid_q0_out;

        send_trade(16'd50, 1'b0);
        send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out, type_out, timeout);

        if (timeout) begin
            $display("FAIL: timed out");
        end else begin
            reservation_q50    = (bid_out + ask_out) >> 1;
            spread_q50 = ask_out - bid_out;
            $display("q=50  reservation=%0d  mid=%0d", reservation_q50, MID);

            if (reservation_q50 < MID)
                $display("PASS: reservation shifted below mid (long inventory)");
            else
                $display("FAIL: reservation %0d not below mid %0d", reservation_q50, MID);

            // Test 4: Make sure spread stays constant regardless of inventory
            // spread = (1/gamma)*ln(1+gamma/k) and has no q term
            $display("\n--- Test 4: Spread = ask-bid is constant across inventory levels ---");
            $display("Spread q=0:  %0d ticks ($%0d.%02d)",
                     spread_q0,  spread_q0/100, spread_q0%100);
            $display("Spread q=50: %0d ticks ($%0d.%02d)",
                     spread_q50, spread_q50/100, spread_q50%100);

            if (spread_q0 == spread_q50)
                $display("PASS: spread unchanged by inventory");
            else
                $display("FAIL: spread changed from %0d to %0d", spread_q0, spread_q50);
        end

        // Test 5: Short inventory (q<0) by selling shares and shifts reservation above mid
        // r = mid - q*gamma*sigma^2*(T-t), when we go negative: r > mid
        $display("\n--- Test 5: q=-50 (short), reservation should shift above mid ---");

        send_trade(16'd100, 1'b1);
        send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out, type_out, timeout);

        if (timeout) begin
            $display("FAIL: timed out");
        end else begin
            reservation_q_neg = (bid_out + ask_out) >> 1;
            $display("q=-50  reservation=%0d  mid=%0d", reservation_q_neg, MID);
            if (reservation_q_neg > MID)
                $display("PASS: reservation shifted above mid (short inventory)");
            else
                $display("FAIL: reservation %0d not above mid %0d", reservation_q_neg, MID);
        end

        // Test 6: Time-of-day effect the skew shrinks as T-t grows closer to 0
        $display("\n--- Test 6: Time-of-day effect, skew shrinks near close ---");
        send_trade(16'd50, 1'b0);
        send_trade(16'd50, 1'b0);
        //Check at mid-day
        send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out, type_out, timeout);
        if (timeout) begin
            $display("FAIL (mid-day): timed out");
        end else begin
            reservation_midday = (bid_out + ask_out) >> 1;
            $display("Mid-day   reservation=%0d  mid=%0d  skew=%0d",
                     reservation_midday, MID, MID - reservation_midday);
        end

        // Capture near close since we have a smaller T-t we should have a smaller skew
        send_and_capture(BID, ASK, NEAR_CLOSE, bid_out, ask_out, type_out, timeout);
        if (timeout) begin
            $display("FAIL (near close): timed out");
        end else begin
            reservation_nearclose = (bid_out + ask_out) >> 1;
            $display("Near-close reservation=%0d  mid=%0d  skew=%0d",
                     reservation_nearclose, MID, MID - reservation_nearclose);

            if ((MID - reservation_nearclose) < (MID - reservation_midday))
                $display("PASS: skew smaller near close than mid-day");
            else
                $display("FAIL: skew did not shrink near close");
        end

        $display("\n--- Simulation complete ---");
        $stop;
    end

endmodule
