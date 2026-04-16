`timescale 1ns/1ps

module tl_top_tb;
    import ob_pkg::*;

    localparam CLK_PERIOD = 10;

    // $224.00 scaled x100 = 22400
    localparam [PRICE_LEN-1:0] BID        = 16'd22398;//223.98
    localparam [PRICE_LEN-1:0] ASK        = 16'd22402;//224.02
    localparam [PRICE_LEN-1:0] MID        = 16'd22400;
    localparam [47:0]          MARKET_OPEN  = 48'd34_200_000_000_000;//9:30 AM
    localparam [47:0]          MID_DAY      = 48'd45_900_000_000_000;//12:45 PM
    localparam [47:0]          AFTERNOON    = 48'd50_400_000_000_000;//2:00 PM
    localparam [47:0]          NEAR_CLOSE   = 48'd57_000_000_000_000;//3:50 PM
    localparam [15:0] GAMMA_Q88   = 16'h001A;
    localparam [15:0] K_Q88       = 16'h0180;

    logic                 i_clk, i_rst_n;
    logic [PRICE_LEN-1:0] i_best_bid, i_best_ask;
    logic [47:0]          i_order_time;
    logic                 i_price_valid;
    logic                 i_trade_valid;
    logic                 i_trade_side;
    logic [15:0]          i_trade_qty;
    logic [PRICE_LEN-1:0] o_bid_price, o_ask_price;
    logic                 o_valid;

    integer pass_count;
    integer fail_count;

    tl_top dut (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_best_bid   (i_best_bid),
        .i_best_ask   (i_best_ask),
        .i_order_time (i_order_time),
        .i_price_valid(i_price_valid),
        .i_trade_valid(i_trade_valid),
        .i_trade_side (i_trade_side),
        .i_trade_qty  (i_trade_qty),
        .o_bid_price  (o_bid_price),
        .o_ask_price  (o_ask_price),
        .o_valid      (o_valid)
    );

    initial i_clk = 0;
    always #(CLK_PERIOD/2) i_clk = ~i_clk;

    task automatic check(input logic cond, input string name);
        if (cond) begin
            $display("  PASS | %s", name);
            pass_count++;
        end else begin
            $display("  FAIL | %s", name);
            fail_count++;
        end
    endtask

    task automatic send_and_capture(
        input  [PRICE_LEN-1:0] bid, ask,
        input  [47:0]          t,
        output [PRICE_LEN-1:0] out_bid, out_ask
    );
        @(posedge i_clk);
        i_best_bid    <= bid;
        i_best_ask    <= ask;
        i_order_time  <= t;
        i_price_valid <= 1;
        @(posedge i_clk);
        i_price_valid <= 0;

        for (int i = 0; i < 300; i++) begin
            @(posedge i_clk);
            if (o_valid) begin
                out_bid = o_bid_price;
                out_ask = o_ask_price;
                break;
            end
        end
    endtask

    task automatic send_trade(input [15:0] qty, input side);
        @(posedge i_clk);
        i_trade_side  <= side;
        i_trade_qty   <= qty;
        i_trade_valid <= 1;
        @(posedge i_clk);
        i_trade_valid <= 0;
    endtask

    task automatic do_reset();
        i_rst_n       = 0;
        i_price_valid = 0;
        i_trade_valid = 0;
        i_trade_qty   = 16'd0;
        i_best_bid    = '0;
        i_best_ask    = '0;
        i_order_time  = '0;
        i_trade_side  = 0;
        repeat(5) @(posedge i_clk);
        i_rst_n = 1;
        repeat(150) @(posedge i_clk);   // wait for startup div_gk and div_sp
    endtask

    task automatic warmup_volatility(
        input [PRICE_LEN-1:0] bid_lo, ask_lo,
        input [PRICE_LEN-1:0] bid_hi, ask_hi,
        input [47:0]          t,
        input int             n
    );
        logic [PRICE_LEN-1:0] b, a;
        for (int w = 0; w < n; w++) begin
            if (w % 2 == 0)
                send_and_capture(bid_lo, ask_lo, t, b, a);
            else
                send_and_capture(bid_hi, ask_hi, t, b, a);
        end
    endtask

    // Shared output captures
    logic [PRICE_LEN-1:0] bid_out, ask_out;

    initial begin
        pass_count = 0;
        fail_count = 0;

        do_reset();
        warmup_volatility(16'd22396, 16'd22400, 16'd22400, 16'd22404, MID_DAY, 50);

        // Mid price = (bid + ask) / 2
        $display("\n--- Test 1: Mid price computation ---");
        send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
        check(((BID + ASK) >> 1) == dut.mid_price,
              $sformatf("mid=%0d  expected=%0d", (BID + ASK)>>1, dut.mid_price));

        // q=0 reservation = mid
        $display("\n--- Test 2: q=0 reservation equals/close to mid ---");
        send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
        check(((BID + ASK) >> 1) == dut.reservation,
              $sformatf("mid=%0d  reservation=%0d", (BID + ASK)>>1, dut.reservation));

        // Calculating spread within margin of actual spread
        $display("\n--- Test 3: Bid/ask spread ---");
        begin
            real real_spread;
            real spread_converted;
            real diff;

            real_spread = ((1/0.1016) * $ln(1+(0.1016/1.5)));
            spread_converted = (real'(dut.spread_price)/256);
            diff = (real_spread - spread_converted);

            $display("  reservation=%0d  bid=%0d  ask=%0d  real_spread=%0f  DUT spread=%0f diff=%0f",
                     dut.reservation, bid_out, ask_out, real_spread, spread_converted, diff);
            check((diff <= 0.05 && diff >= -0.05),
                  "DUT spread within 0.05 of calculated spread");
        end

        //Long inventory q=50 so reservation should be below mid
        $display("\n--- Test 4: q=50 (long), reservation < mid ---");
        begin
            logic [15:0] spread_snap_q0;
            real spread_q0, spread_q50;

            spread_snap_q0 = dut.spread_price;
            spread_q0 = real'(spread_snap_q0) / 256.0;

            send_trade(50, 1'b0);   // buy 50 so q = +50
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);

            spread_q50 = real'(dut.spread_price) / 256.0;

            $display("  reservation=%0d  mid=%0d  q=%0d", dut.reservation, MID, dut.q);
            check(dut.reservation < MID, "reservation < mid when long");

            //Spread is constant across different inventory levels
            $display("\n--- Test 5: Spread constant across inventory levels ---");
            $display("  spread q=0: %.4f  spread q=50: %.4f", spread_q0, spread_q50);
            check(dut.spread_price == spread_snap_q0, "spread unchanged by inventory");
        end

        // Short inventory q=-50 means reservation should be above mid
        $display("\n--- Test 6: q=-50 (short), reservation > mid ---");
        begin
            send_trade(100, 1'b1);  // sell 100 so net q = -50
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);

            $display("  reservation=%0d  mid=%0d  q=%0d", dut.reservation, MID, dut.q);
            check(dut.reservation > MID, "reservation > mid when short");
        end

        // Skew  increases with q
        // Uses dut.inv_skew_full directly (q * gamma * sigma^2 * T_frac)
        $display("\n--- Test 7: Skew monotonic with |q| ---");
        begin
            logic signed [16:0] skew10, skew50, skew100;

            // Reset inventory from previous test from q=0
            send_trade(50, 1'b0);   // buy 50 so q=0
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out); //settle

            send_trade(10, 1'b0);   // buy 10 so q=10
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
            skew10 = $signed(dut.inv_skew_full[32:16]);

            send_trade(40, 1'b0);   // buy 40 so q=50
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
            skew50 = $signed(dut.inv_skew_full[32:16]);

            send_trade(50, 1'b0);   // buy 50 so q=100
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
            skew100 = $signed(dut.inv_skew_full[32:16]);

            $display("  inv_skew q=10:%0d  q=50:%0d  q=100:%0d", skew10, skew50, skew100);
            check(skew10 < skew50,  "skew(q=10) < skew(q=50)");
            check(skew50 < skew100, "skew(q=50) < skew(q=100)");
        end

        // Time-of-day the skew shrinks as market approaches close
        // Uses dut.inv_skew_full directly and q is still +100 from test 7
        $display("\n--- Test 8: Skew shrinks as market approaches close ---");
        begin
            logic signed [16:0] skew_open, skew_mid, skew_aft, skew_cls;

            send_and_capture(BID, ASK, MARKET_OPEN, bid_out, ask_out);
            skew_open = $signed(dut.inv_skew_full[32:16]);

            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
            skew_mid = $signed(dut.inv_skew_full[32:16]);

            send_and_capture(BID, ASK, AFTERNOON, bid_out, ask_out);
            skew_aft = $signed(dut.inv_skew_full[32:16]);

            send_and_capture(BID, ASK, NEAR_CLOSE, bid_out, ask_out);
            skew_cls = $signed(dut.inv_skew_full[32:16]);

            $display("  inv_skew: open=%0d  midday=%0d  afternoon=%0d  close=%0d",
                     skew_open, skew_mid, skew_aft, skew_cls);
            check(skew_open >= skew_mid,  "skew at open >= midday");
            check(skew_mid >= skew_aft,  "skew at midday >= afternoon");
            check(skew_aft >= skew_cls,  "skew at afternoon >= near-close");
        end

        // Reset clears inventory — after reset q=0, so reservation=mid
        // q is currently +100 from test 7
        $display("\n--- Test 9: Reset clears inventory state ---");
        begin
            // Build up large inventory
            send_trade(200, 1'b0);  // buy 200
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
            $display("  pre-reset  reservation=%0d  mid=%0d  q=%0d", dut.reservation, MID, dut.q);
            check(dut.reservation < MID, "large q causes downward skew before reset");

            // Full reset and re-warm up volatility
            do_reset();
            warmup_volatility(16'd22396, 16'd22400, 16'd22400, 16'd22404, MID_DAY, 50);

            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
            $display("  post-reset reservation=%0d  mid=%0d  q=%0d", dut.reservation, MID, dut.q);
            check(dut.reservation == MID, "reservation = mid after reset (q=0)");
        end

        // Volatility changes: higher vol should mean larger skew
        $display("\n--- Test 10: Higher volatility increases skew magnitude ---");
        begin
            logic signed [16:0] skew_lo, skew_hi;
            logic [47:0] sigma_lo, sigma_hi;

            // Low volatility: price oscillates +-1 tick
            do_reset();
            warmup_volatility(16'd22399, 16'd22401, 16'd22401, 16'd22403, MID_DAY, 50);
            send_trade(50, 1'b0);   // q=50
            send_and_capture(BID, ASK, MID_DAY, bid_out, ask_out);
            skew_lo  = $signed(dut.inv_skew_full[32:16]);
            sigma_lo = dut.sigma_sq;

            //High volatility: price oscillates +-50 ticks
            do_reset();
            warmup_volatility(16'd22350, 16'd22354, 16'd22450, 16'd22454, MID_DAY, 50);
            send_trade(50, 1'b0);   // same q=50
            send_and_capture(16'd22348, 16'd22452, MID_DAY, bid_out, ask_out);
            skew_hi  = $signed(dut.inv_skew_full[32:16]);
            sigma_hi = dut.sigma_sq;

            $display("  inv_skew low-vol=%0d  high-vol=%0d  sigma_lo=%0d  sigma_hi=%0d",skew_lo, skew_hi, sigma_lo, sigma_hi);
            check(skew_hi > skew_lo, "higher volatility produces larger inventory skew");
        end

        // SUMMARY
        $display("\n=================================================================");
        $display("  PASS: %0d / %0d", pass_count, pass_count + fail_count);
        $display("  FAIL: %0d / %0d", fail_count, pass_count + fail_count);
        $display("=================================================================");
        $stop;
    end

    initial begin
        #5000000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
