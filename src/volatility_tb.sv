`timescale 1ns/1ps

module volatility_ewma_tb;

    // lambda = 0.1 so round(0.1 * 2^16) = 6554
    localparam logic [15:0] LAMBDA_01 = 16'd6554;
    // lambda = 0.5  so 32768
    localparam logic [15:0] LAMBDA_05 = 16'd32768;
    // lambda = 0.9  so 58982
    localparam logic [15:0] LAMBDA_09 = 16'd58982;

    logic        clk;
    logic        rst_n;
    logic [15:0] lambda;
    logic        price_valid;
    logic [15:0] mid_price;
    logic [47:0] sigma_out;
    logic        sigma_valid;

    volatility_ewma dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .lambda        (lambda),
        .price_valid  (price_valid),
        .mid_price    (mid_price),
        .sigma_out   (sigma_out),
        .sigma_valid (sigma_valid)
    );

    initial clk = 0;
    always #2.5 clk = ~clk;

    int pass_count;
    int fail_count;

    // Convert Q32.16 fixed-point to real for display
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
            $display("  FAIL: %s  sigma2=%.6f  valid=%0b",
                     label, to_real(sigma_out), sigma_valid);
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
    initial begin
        pass_count = 0;
        fail_count = 0;
        lambda = LAMBDA_01;

        $display("\n--- TEST 1: RESET ---");
        do_reset();
        check("sigma_out == 0 after reset",   sigma_out   == '0);
        check("sigma_valid == 0 after reset",  sigma_valid == 1'b0);

        $display("\n--- TEST 2: CONSTANT PRICE WITH NO DELTA---");
        do_reset();
        repeat(20) send_price(16'd1000);
        check("sigma_valid asserted",         sigma_valid == 1'b1);
        check("sigma == 0 because of flat price",    sigma_out   == '0);

        $display("\n--- TEST 3: INCREASE THEN FLAT ---");
        do_reset();
        repeat(5) send_price(16'd1000);
        send_price(16'd1010);
        begin
            real s2;
            @(posedge clk); #1;
            s2 = to_real(sigma_out);
            $display("  sigma2 after step  = %.4f  (expect ~10.0)", s2);
            check("sigma2 > 0 after step", sigma_out > 0);
        end
        repeat(30) send_price(16'd1010);
        begin
            real s2;
            @(posedge clk); #1;
            s2 = to_real(sigma_out);
            $display("  sigma2 after decay = %.4f  (expect < 1.0)", s2);
            check("sigma2 decays after flat", sigma_out < (1 << 16));
        end

        $display("\n--- TEST 4: ALTERNATING ±1 TICK (alpha=0.1) ---");
        do_reset();
        lambda = LAMBDA_01;
        begin
            logic [15:0] p;
            real s2;
            p = 16'd1000;
            repeat(200) begin
                send_price(p);
                p = (p == 16'd1000) ? 16'd1001 : 16'd1000;
            end
            @(posedge clk); #1;
            s2 = to_real(sigma_out);
            $display("  sigma = %.6f  (expect ~1.0)", s2);
            check("sigma converges near 1.0", s2 > 0.90 && s2 < 1.10);
        end

        $display("\n--- TEST 5: PRICE INCREASE ---");
        do_reset();
        lambda = LAMBDA_01;
        begin
            logic [15:0] p;
            real s2;
            p = 16'd500;
            repeat(200) begin
                send_price(p);
                p = p + 1'b1;
            end
            @(posedge clk); #1;
            s2 = to_real(sigma_out);
            $display("  sigma = %.6f  (expect ~1.0)", s2);
            check("sigma ~1.0 for unit increasing", s2 > 0.90 && s2 < 1.10);
        end

        $display("\n--- TEST 6: VALID GATING ---");
        do_reset();
        lambda = LAMBDA_01;
        repeat(5)  send_price(16'd1000);
        send_price(16'd1010);
        repeat(5)  send_price(16'd1010);
        begin
            logic [47:0] snap;
            @(posedge clk); #1;
            snap = sigma_out;
            repeat(10) @(posedge clk);
            check("sigma2 frozen when price_valid=0", sigma_out == snap);
        end

        $stop();
    end

endmodule