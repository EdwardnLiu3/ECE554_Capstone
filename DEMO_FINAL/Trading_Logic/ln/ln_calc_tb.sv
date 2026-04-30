module ln_calc_tb;

    logic [15:0]        x_in;
    logic signed [15:0] ln_out;
    logic               valid;

    ln_calc dut (
        .x_in   (x_in),
        .ln_out (ln_out),
        .valid  (valid)
    );

    // Convert unsigned Q8.8 → real
    function automatic real q8_8_to_real(input logic [15:0] fp);
        return real'(fp) / 256.0;
    endfunction

    // Convert signed Q8.8 → real
    function automatic real sq8_8_to_real(input logic signed [15:0] fp);
        return real'(fp) / 256.0;
    endfunction

    // Convert real → unsigned Q8.8
    function automatic logic [15:0] real_to_q8_8(input real r);
        return 16'(int'(r * 256.0 + 0.5));
    endfunction

    // Natural log (Taylor / standard)
    `define NATURAL_LN(x) $ln(x)

    real    x_real, ln_ideal, ln_got, err_real;
    integer ulp_err, max_ulp_err;
    integer pass_cnt, fail_cnt;
    integer i;

    initial begin
        $display("=============================================================");
        $display(" ln_calc Testbench  (Q8.8 fixed-point, LUT-based)");
        $display("  Input  format: unsigned Q8.8 [15:0]");
        $display("  Output format: signed   Q8.8 [15:0]");
        $display("  Tolerance    : <= 2 ULP  (1 ULP = 1/256 ≈ 0.0039)");
        $display("=============================================================");
        $display("");
        $display(" %-10s  %-8s  %-10s  %-10s  %-6s  %s",
                 "x (hex)", "x (real)", "ln ideal", "ln got", "ULP err", "PASS?");
        $display(" %s", {60{"-"}});

        max_ulp_err = 0;
        pass_cnt    = 0;
        fail_cnt    = 0;

        // ---- Hand-picked key values ----------------------------------------
        begin : key_values
            // 0x0001=0.003906, 0x0040=0.25, 0x0080=0.5, 0x00C0=0.75,
            // 0x0100=1.0, 0x0140=1.25, 0x0180=1.5, 0x01C0=1.75,
            // 0x0200=2.0, 0x0400=4.0, 0x02B8≈e, 0xFF00=255.0
            integer test_vals [0:11];
            test_vals[0]  = 16'h0001;
            test_vals[1]  = 16'h0040;
            test_vals[2]  = 16'h0080;
            test_vals[3]  = 16'h00C0;
            test_vals[4]  = 16'h0100;
            test_vals[5]  = 16'h0140;
            test_vals[6]  = 16'h0180;
            test_vals[7]  = 16'h01C0;
            test_vals[8]  = 16'h0200;
            test_vals[9]  = 16'h0400;
            test_vals[10] = 16'h02B8;  // e ≈ 2.71875 → ln ≈ 1.0
            test_vals[11] = 16'hFF00;  // 255.0

            for (i = 0; i < 12; i++) begin
                x_in   = test_vals[i][15:0];
                #1;
                x_real  = q8_8_to_real(x_in);
                ln_ideal = `NATURAL_LN(x_real);
                ln_got   = sq8_8_to_real(ln_out);
                err_real = ln_ideal - ln_got;
                if (err_real < 0.0) err_real = -err_real;
                ulp_err  = int'(err_real * 256.0 + 0.5);

                if (ulp_err > max_ulp_err) max_ulp_err = ulp_err;

                if (ulp_err <= 2) begin
                    pass_cnt++;
                    $display(" 0x%04h  %8.5f  %10.6f  %10.6f  %6d  PASS",
                             x_in, x_real, ln_ideal, ln_got, ulp_err);
                end else begin
                    fail_cnt++;
                    $display(" 0x%04h  %8.5f  %10.6f  %10.6f  %6d  FAIL <<<",
                             x_in, x_real, ln_ideal, ln_got, ulp_err);
                end
            end
        end

        $display(" %s", {60{"-"}});

        // ---- Sweep all 256 possible integer values (step = 1.0) -----------
        $display("\n Sweeping x = 1..255 (integer steps)...");
        begin : integer_sweep
            integer sweep_max_ulp;
            sweep_max_ulp = 0;
            for (i = 1; i <= 255; i++) begin
                x_in = 16'(i * 256);   // Q8.8 of integer i
                #1;
                x_real   = q8_8_to_real(x_in);
                ln_ideal = `NATURAL_LN(x_real);
                ln_got   = sq8_8_to_real(ln_out);
                err_real = ln_ideal - ln_got;
                if (err_real < 0.0) err_real = -err_real;
                ulp_err  = int'(err_real * 256.0 + 0.5);
                if (ulp_err > sweep_max_ulp) sweep_max_ulp = ulp_err;
                if (ulp_err <= 2) pass_cnt++;
                else begin
                    fail_cnt++;
                    $display(" FAIL: x=0x%04h (%0d)  ideal=%f  got=%f  ulp=%0d",
                             x_in, i, ln_ideal, ln_got, ulp_err);
                end
            end
            $display(" Integer sweep done.  Max ULP error = %0d", sweep_max_ulp);
            if (sweep_max_ulp > max_ulp_err) max_ulp_err = sweep_max_ulp;
        end

        // ---- Sweep fractional values 0.25 to 4.0 (step = 1/256) -----------
        $display("\n Sweeping x = 0x0040..0x0400 (fine-grained)...");
        begin : frac_sweep
            integer sweep_max_ulp;
            sweep_max_ulp = 0;
            for (i = 16'h0040; i <= 16'h0400; i++) begin
                x_in = 16'(i);
                #1;
                x_real   = q8_8_to_real(x_in);
                ln_ideal = `NATURAL_LN(x_real);
                ln_got   = sq8_8_to_real(ln_out);
                err_real = ln_ideal - ln_got;
                if (err_real < 0.0) err_real = -err_real;
                ulp_err  = int'(err_real * 256.0 + 0.5);
                if (ulp_err > sweep_max_ulp) sweep_max_ulp = ulp_err;
                if (ulp_err <= 2) pass_cnt++;
                else begin
                    fail_cnt++;
                    $display(" FAIL: x=0x%04h (%f)  ideal=%f  got=%f  ulp=%0d",
                             x_in, x_real, ln_ideal, ln_got, ulp_err);
                end
            end
            $display(" Fine-grained sweep done.  Max ULP error = %0d", sweep_max_ulp);
            if (sweep_max_ulp > max_ulp_err) max_ulp_err = sweep_max_ulp;
        end

        // ---- x=0 must mark invalid -----------------------------------------
        x_in = 16'h0000;
        #1;
        if (!valid) begin
            $display("\n x=0 correctly flagged invalid.  PASS");
            pass_cnt++;
        end else begin
            $display("\n x=0 NOT flagged invalid!  FAIL");
            fail_cnt++;
        end

        // ---- Summary -------------------------------------------------------
        $display("");
        $display("=============================================================");
        $display(" RESULTS");
        $display("   PASS : %0d", pass_cnt);
        $display("   FAIL : %0d", fail_cnt);
        $display("   Max ULP error overall : %0d", max_ulp_err);
        $display("   (1 ULP = 1/256 ≈ 0.0039)");
        if (fail_cnt == 0)
            $display("   *** ALL TESTS PASSED ***");
        else
            $display("   *** %0d TEST(S) FAILED ***", fail_cnt);
        $display("=============================================================");

        $finish;
    end

endmodule
