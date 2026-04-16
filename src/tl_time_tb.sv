`timescale 1ns/1ps

module tl_time_tb;

    localparam [47:0] TOTAL_TIME_NS = 48'd57_600_000_000_000; // 4:00 PM
    localparam [47:0] OPEN_TIME_NS  = 48'd34_200_000_000_000; // 9:30 AM
    localparam [47:0] MID_DAY_NS    = 48'd45_900_000_000_000; // 12:45 PM
    localparam [47:0] NEAR_CLOSE_NS = 48'd57_000_000_000_000; // 3:50 PM

    logic        clk;
    logic        rst_n;
    logic [47:0] order_time;
    logic [47:0] T_sub_t;

    tl_time dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .order_time (order_time),
        .T_sub_t    (T_sub_t)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    int pass_count;
    int fail_count;

    task automatic check(input string label, input logic cond);
        if (cond) begin
            $display("  PASS: %s", label);
            pass_count++;
        end else begin
            $display("  FAIL: %s  order_time=%0d  T_sub_t=%0d",
                     label, order_time, T_sub_t);
            fail_count++;
        end
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;
        rst_n = 1'b1;

        // TEST 1: T_sub_t = total_time - order_time at certain times
        $display("\n--- Test 1: Correct subtraction at key times ---");
        order_time = OPEN_TIME_NS;
        #1;
        check("at open", T_sub_t == TOTAL_TIME_NS - OPEN_TIME_NS);

        order_time = MID_DAY_NS;
        #1;
        check("at mid-day",T_sub_t == TOTAL_TIME_NS - MID_DAY_NS);

        order_time = NEAR_CLOSE_NS;
        #1;
        check("at near-close",T_sub_t == TOTAL_TIME_NS - NEAR_CLOSE_NS);

        order_time = TOTAL_TIME_NS;
        #1;
        check("at close",T_sub_t == 48'd0);

        // TEST 2: later time results in smaller T_sub_t
        $display("\n--- Test 2: Monotonicity ---");
        begin
            logic [47:0] t_open, t_mid, t_close;

            order_time = OPEN_TIME_NS;
            #1;
            t_open = T_sub_t;

            order_time = MID_DAY_NS;
            #1;
            t_mid = T_sub_t;

            order_time = NEAR_CLOSE_NS;
            #1;
            t_close = T_sub_t;

            check("open > mid > near-close", t_open > t_mid && t_mid > t_close);
        end

        // TEST 3: Boundary — order_time past market close
        // $display("\n--- Test 3: Past-close value ---");
        // order_time = TOTAL_TIME_NS + 48'd1;
        // #1;
        //Technically if someone inputted an order past market close it'd mess up the algorithm


        $stop;
    end

endmodule
