`timescale 1ns/1ps

module volatility_ewma_tb;

    localparam logic [15:0] LAMBDA_01 = 16'd6554;   // ~0.1 in Q0.16

    logic        clk;
    logic        rst_n;
    logic [15:0] lambda;
    logic        price_valid;
    logic [15:0] mid_price;
    logic [47:0] sigma_out;
    logic        sigma_valid;

    volatility_ewma dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .lambda      (lambda),
        .price_valid (price_valid),
        .mid_price   (mid_price),
        .sigma_out   (sigma_out),
        .sigma_valid (sigma_valid)
    );

    initial clk = 0;
    always #2.5 clk = ~clk;

    int pass_count;
    int fail_count;

    function automatic real to_real(input logic [47:0] val);
        return real'(val) / real'(1 << 16);
    endfunction

    task automatic send_price(input logic [15:0] p);
        @(negedge clk);
        mid_price   = p;
        price_valid = 1'b1;
        @(posedge clk); #1;
        price_valid = 1'b0;
    endtask

    task automatic check(input string label, input logic cond);
        if (cond) begin
            $display("  PASS: %s", label);
            pass_count++;
        end else begin
            $display("  FAIL: %s  sigma=%.6f (raw=%0d)  valid=%0b",
                     label, to_real(sigma_out), sigma_out, sigma_valid);
            fail_count++;
        end
    endtask

    task automatic do_reset();
        rst_n       = 1'b0;
        price_valid = 1'b0;
        mid_price   = '0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;
    endtask

    //TEsts
    // Hand-calculated: sigma^2 = lambda*sigma^2 + (1-lambda)*delta^2
    // lambda = 0.1, (1-lambda) = 0.9

    initial begin
        pass_count = 0;
        fail_count = 0;
        lambda = LAMBDA_01;

        //Ts 1: RESET ----
        $display("\n--- TEST 1: RESET ---");
        do_reset();
        check("sigma_out == 0 after reset",  sigma_out   == 48'd0);
        check("sigma_valid == 0 after reset", sigma_valid == 1'b0);

        // ---- TEST 2: Step up so sigma = 90.0 ----
        // 100, 100, 110: delta=10, delta^2=100, sigma = 0.1*0 + 0.9*100 = 90.0
        $display("\n--- TEST 2: STEP UP (100,100,110) ---");
        do_reset();
        send_price(16'd100);
        send_price(16'd100);
        send_price(16'd110);
        begin
            real hw, expected, diff;
            expected = 90.0;
            hw = to_real(sigma_out);
            diff = hw - expected;
            if (diff < 0.0) diff = -diff;
            $display("  Expected: %.4f  Got: %.4f  Diff: %.6f", expected, hw, diff);
            check("sigma ~ 90.0 (within 0.01)", diff < 0.01);
        end

        // ---- TEST 3: Decay so sigma = 9.0 ----
        // 100, 110, 110: sigma after (100,110)=90, then delta=0, sigma = 0.1*90 + 0.9*0 = 9.0
        $display("\n--- TEST 3: DECAY (100,110,110) ---");
        do_reset();
        send_price(16'd100);
        send_price(16'd110);
        send_price(16'd110);
        begin
            real hw, expected, diff;
            expected = 9.0;
            hw = to_real(sigma_out);
            diff = hw - expected;
            if (diff < 0.0) diff = -diff;
            $display("  Expected: %.4f  Got: %.4f  Diff: %.6f", expected, hw, diff);
            check("sigma ~ 9.0 (within 0.01)", diff < 0.01);
        end

        // ---- TEST 4: Single price so sigma_valid stays 0 ----
        $display("\n--- TEST 4: SINGLE PRICE ---");
        do_reset();
        send_price(16'd100);
        $display("  sigma_valid = %0b  (Expected: 0)", sigma_valid);
        check("sigma_valid == 0 after one sample", sigma_valid == 1'b0);
        check("sigma_out == 0 after one sample",   sigma_out   == 48'd0);

    end

endmodule
