`timescale 1ns/1ps

module divider_q16_tb;

    localparam WIDTH      = 32;
    localparam FRAC_BITS  = 16;
    localparam CLK_PERIOD = 5;

    logic             clk;
    logic             rst;
    logic             start;
    logic [WIDTH-1:0] dividend;
    logic [WIDTH-1:0] divisor;
    logic [WIDTH-1:0] quotient;
    logic             done;
    logic             error;

    // Global clock counter - NEW
    integer global_cycle_count;

    divider_q16 #(
        .WIDTH     (WIDTH),
        .FRAC_BITS (FRAC_BITS)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .start    (start),
        .dividend (dividend),
        .divisor  (divisor),
        .quotient (quotient),
        .done     (done),
        .error    (error)
    );

    // Clock
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Increment global counter every cycle - NEW
    initial global_cycle_count = 0;
    always @(posedge clk) global_cycle_count++;

    // Simple task - now tracks start/end cycles - UPDATED
    task automatic run_test(
        input logic [WIDTH-1:0] div_end,
        input logic [WIDTH-1:0] div_or,
        input string            name
    );
        integer start_cycle;
        integer end_cycle;
        integer latency;
        integer timeout_count;

        timeout_count = 0;

        @(posedge clk);
        dividend    <= div_end;
        divisor     <= div_or;
        start       <= 1'b1;
        start_cycle  = global_cycle_count;  // record start - NEW

        @(posedge clk);
        start <= 1'b0;

        // Wait for done
        while (done !== 1'b1) begin
            @(posedge clk);
            timeout_count++;
            if (timeout_count > 200) begin
                $display("TIMEOUT | %s | started at cycle %0d",
                         name, start_cycle);
                return;
            end
        end

        // Record end cycle - NEW
        end_cycle = global_cycle_count;
        latency   = end_cycle - start_cycle;

        $display("TEST: %-25s | dividend_raw=%0d | divisor_raw=%0d | quotient_raw=%0d | decoded=%f | start=%0d | end=%0d | latency=%0d cycles | %0dns",
            name,
            div_end,
            div_or,
            quotient,
            real'(quotient) / real'(2**FRAC_BITS),
            start_cycle,
            end_cycle,
            latency,
            latency * CLK_PERIOD
        );

        repeat(4) @(posedge clk);
    endtask

    initial begin
        $dumpfile("divider_q16.vcd");
        $dumpvars(0, divider_q16_tb);

        rst   = 1'b1;
        start = 1'b0;
        repeat(4) @(posedge clk);
        rst = 1'b0;
        repeat(2) @(posedge clk);

        $display("--- Raw encoding check ---");
        $display("  4.0   in Q16.16 = %0d (expect 262144)",  32'(int'(4.0   * 2**FRAC_BITS)));
        $display("  2.0   in Q16.16 = %0d (expect 131072)",  32'(int'(2.0   * 2**FRAC_BITS)));
        $display("  0.1   in Q16.16 = %0d (expect 6553)",    32'(int'(0.1   * 2**FRAC_BITS)));
        $display("  1.5   in Q16.16 = %0d (expect 98304)",   32'(int'(1.5   * 2**FRAC_BITS)));
        $display("  2.0   result    = %0d (expect 131072)",  32'(int'(2.0   * 2**FRAC_BITS)));
        $display("  0.5   result    = %0d (expect 32768)",   32'(int'(0.5   * 2**FRAC_BITS)));
        $display("");

        $display("--- Division Tests ---");
        run_test(32'd262144, 32'd131072, "4.0/2.0=2.0");
        run_test(32'd65536,  32'd131072, "1.0/2.0=0.5");
        run_test(32'd6553,   32'd98304,  "0.1/1.5=0.0667");

        // Total summary - NEW
        $display("\n--- Summary ---");
        $display("  total cycles elapsed: %0d", global_cycle_count);
        $display("  total time:           %0dns",
                 global_cycle_count * CLK_PERIOD);

        $display("--- Done ---");
        $finish;
    end

    initial begin
        #500000;
        $display("WATCHDOG TIMEOUT at cycle %0d", global_cycle_count);
        $finish;
    end

endmodule