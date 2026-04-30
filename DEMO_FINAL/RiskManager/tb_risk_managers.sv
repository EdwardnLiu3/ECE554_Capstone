`timescale 1ns/1ps
// Simple testbench for verifying the risk manager module.
// Checks valid quotes, position limit rejects, quote size rejects,
// price band reject, daily loss reject, disabled trading reject,
// and exposure reject.
module tb_risk_managers;

    //params the same as in risk manager, verifies reasoning for rejects is gooda
    localparam [3:0] REJECT_NONE       = 4'd0;
    localparam [3:0] REJECT_DISABLED   = 4'd1;
    localparam [3:0] REJECT_MAX_LONG   = 4'd2;
    localparam [3:0] REJECT_MAX_SHORT  = 4'd3;
    localparam [3:0] REJECT_QUOTE_SIZE = 4'd4;
    localparam [3:0] REJECT_PRICE_BAND = 4'd5;
    localparam [3:0] REJECT_DAILY_LOSS = 4'd7;
    localparam [3:0] REJECT_EXPOSURE   = 4'd8;
    logic               clk;
    logic               rst_n;
    logic               trading_enable;
    logic               kill_switch;
    logic               price_band_enable;
    logic               pnl_check_enable;
    logic signed [15:0] inventory_position;
    logic signed [63:0] day_pnl;
    logic signed [63:0] total_pnl;
    logic [15:0]        live_bid_qty;
    logic [15:0]        live_ask_qty;
    logic               quote_valid;
    logic               quote_side;
    logic [31:0]        quote_price;
    logic [15:0]        quote_quantity;
    logic [31:0]        reference_price;
    logic               out_quote_valid;
    logic               out_quote_side;
    logic [31:0]        out_quote_price;
    logic [15:0]        out_quote_quantity;
    logic               reject_valid;
    logic [3:0]         reject_reason;

    risk_managers idut (
        .i_clk(clk),
        .i_rst_n(rst_n),
        .i_trading_enable(trading_enable),
        .i_kill_switch(kill_switch),
        .i_price_band_enable(price_band_enable),
        .i_pnl_check_enable(pnl_check_enable),
        .i_inventory_position(inventory_position),
        .i_day_pnl(day_pnl),
        .i_total_pnl(total_pnl),
        .i_live_bid_qty(live_bid_qty),
        .i_live_ask_qty(live_ask_qty),
        .i_quote_valid(quote_valid),
        .i_quote_side(quote_side),
        .i_quote_price(quote_price),
        .i_quote_quantity(quote_quantity),
        .i_reference_price(reference_price),
        .o_quote_valid(out_quote_valid),
        .o_quote_side(out_quote_side),
        .o_quote_price(out_quote_price),
        .o_quote_quantity(out_quote_quantity),
        .o_reject_valid(reject_valid),
        .o_reject_reason(reject_reason)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;
    // reset tasks which saves time
    task automatic clear_inputs;
        begin
            quote_valid         = 1'b0;
            quote_side          = 1'b0;
            quote_price         = '0;
            quote_quantity      = '0;
            inventory_position  = '0;
            day_pnl             = '0;
            total_pnl           = '0;
            live_bid_qty        = '0;
            live_ask_qty        = '0;
            reference_price     = 32'd100;
            trading_enable      = 1'b1;
            kill_switch         = 1'b0;
            price_band_enable   = 1'b0;
            pnl_check_enable    = 1'b1;
        end
    endtask


    initial begin
        rst_n = 1'b1;
        clear_inputs();

        // Test 1
        $display("Test 1: reset behavior");
        @(negedge clk);
        rst_n = 1'b0;
        clear_inputs();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0) $fatal(1, "Test 1 failed: reset should clear out_quote_valid");
        if (reject_valid !== 1'b0)    $fatal(1, "Test 1 failed: reset should clear reject_valid");
        if (reject_reason !== REJECT_NONE) $fatal(1, "Test 1 failed: reset should clear reject_reason");
        $display("PASS");

        // Test  2
        $display("Test 2: valid bid quote passes");
        @(negedge clk);
        quote_valid      = 1'b1;
        quote_side       = 1'b0;
        quote_price      = 32'd100;
        quote_quantity   = 16'd20;
        reference_price  = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b1)      $fatal(1, "Test 2 failed: valid quote should pass");
        if (reject_valid !== 1'b0)         $fatal(1, "Test 2 failed: valid quote should not reject");
        if (out_quote_side !== 1'b0)       $fatal(1, "Test 2 failed: side wrong");
        if (out_quote_price !== 32'd100)   $fatal(1, "Test 2 failed: price wrong");
        if (out_quote_quantity !== 16'd20) $fatal(1, "Test 2 failed: quantity wrong");
        $display("PASS");

        // Test 2b
        $display("Test 2b: rapid repeat quote is throttled without a hard reject");
        @(negedge clk);
        quote_valid      = 1'b1;
        quote_side       = 1'b0;
        quote_price      = 32'd100;
        quote_quantity   = 16'd20;
        reference_price  = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 2b failed: repeat quote should be throttled");
        if (reject_valid !== 1'b0)         $fatal(1, "Test 2b failed: repeat quote throttle should not hard reject");
        $display("PASS");
        @(negedge clk);
        clear_inputs();
        // Test 3
        $display("Test 3: max long reject");
        @(negedge clk);
        inventory_position = 16'sd1480;
        quote_valid        = 1'b1;
        quote_side         = 1'b0;
        quote_price        = 32'd100;
        quote_quantity     = 16'd30;
        reference_price    = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 3 failed: max long should block quote");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 3 failed: max long should reject");
        if (reject_reason !== REJECT_MAX_LONG) $fatal(1, "Test 3 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        // Test 4
        $display("Test 4: max short reject");
        @(negedge clk);
        inventory_position = -16'sd1480;
        quote_valid        = 1'b1;
        quote_side         = 1'b1;
        quote_price        = 32'd100;
        quote_quantity     = 16'd30;
        reference_price    = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 4 failed: max short should block quote");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 4 failed: max short should reject");
        if (reject_reason !== REJECT_MAX_SHORT) $fatal(1, "Test 4 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        // Test 5
        $display("Test 5: oversized quote reject");
        @(negedge clk);
        quote_valid      = 1'b1;
        quote_side       = 1'b0;
        quote_price      = 32'd100;
        quote_quantity   = 16'd520;
        reference_price  = 32'd100;
        @(posedge clk);
        #1;

        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 5 failed: oversized quote should block");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 5 failed: oversized quote should reject");
        if (reject_reason !== REJECT_QUOTE_SIZE) $fatal(1, "Test 5 failed: wrong reject reason");

        $display("PASS");
    
        @(negedge clk);

        clear_inputs();

        // Test 6
        $display("Test 6: zero quantity reject");
        @(negedge clk);
        quote_valid      = 1'b1;
        quote_side       = 1'b0;
        quote_price      = 32'd100;
        quote_quantity   = 16'd0;
        reference_price  = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 6 failed: zero quantity should block");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 6 failed: zero quantity should reject");
        if (reject_reason !== REJECT_QUOTE_SIZE) $fatal(1, "Test 6 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        // test 7
        $display("Test 7: price band reject");
        @(negedge clk);
        price_band_enable = 1'b1;
        quote_valid       = 1'b1;
        quote_side        = 1'b0;
        quote_price       = 32'd5000;
        quote_quantity    = 16'd10;
        reference_price   = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 7 failed: price band should block");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 7 failed: price band should reject");
        if (reject_reason !== REJECT_PRICE_BAND) $fatal(1, "Test 7 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        // test 8
        $display("Test 8: marked-to-market daily loss reject");
        @(negedge clk);
        day_pnl         = 64'sd1000000;
        total_pnl       = -64'sd25000000;
        quote_valid     = 1'b1;
        quote_side      = 1'b0;
        quote_price     = 32'd100;
        quote_quantity  = 16'd10;
        reference_price = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 8 failed: daily loss should block");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 8 failed: daily loss should reject");
        if (reject_reason !== REJECT_DAILY_LOSS) $fatal(1, "Test 8 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        //Test 9
        $display("Test 9: kill switch reject");
        @(negedge clk);
        kill_switch     = 1'b1;
        quote_valid     = 1'b1;
        quote_side      = 1'b0;
        quote_price     = 32'd100;
        quote_quantity  = 16'd10;
        reference_price = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 9 failed: kill switch should block");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 9 failed: kill switch should reject");
        if (reject_reason !== REJECT_DISABLED) $fatal(1, "Test 9 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        //Test 10
        $display("Test 10: trading disabled reject");
        @(negedge clk);
        trading_enable  = 1'b0;
        quote_valid     = 1'b1;
        quote_side      = 1'b1;
        quote_price     = 32'd100;
        quote_quantity  = 16'd10;
        reference_price = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 10 failed: trading disabled should block");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 10 failed: trading disabled should reject");
        if (reject_reason !== REJECT_DISABLED) $fatal(1, "Test 10 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        // Test 11
        $display("Test 11: exposure reject");
        @(negedge clk);
        inventory_position = 16'sd1400;
        quote_valid        = 1'b1;
        quote_side         = 1'b0;
        quote_price        = 32'd400000;
        quote_quantity     = 16'd100;
        reference_price    = 32'd400000;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 11 failed: exposure should block");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 11 failed: exposure should reject");
        if (reject_reason !== REJECT_EXPOSURE) $fatal(1, "Test 11 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();


        //should be good if we make it here. 
        $display("Test 12: live bid quantity pushes max long");
        @(negedge clk);
        inventory_position = 16'sd1450;
        live_bid_qty       = 16'd30;
        quote_valid        = 1'b1;
        quote_side         = 1'b0;
        quote_price        = 32'd100;
        quote_quantity     = 16'd50;
        reference_price    = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 12 failed: live bid quantity should count toward max long");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 12 failed: live bid quantity should reject");
        if (reject_reason !== REJECT_MAX_LONG) $fatal(1, "Test 12 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        $display("Test 13: live ask quantity pushes max short");
        @(negedge clk);
        inventory_position = -16'sd1450;
        live_ask_qty       = 16'd30;
        quote_valid        = 1'b1;
        quote_side         = 1'b1;
        quote_price        = 32'd100;
        quote_quantity     = 16'd50;
        reference_price    = 32'd100;
        @(posedge clk);
        #1;
        if (out_quote_valid !== 1'b0)      $fatal(1, "Test 13 failed: live ask quantity should count toward max short");
        if (reject_valid !== 1'b1)         $fatal(1, "Test 13 failed: live ask quantity should reject");
        if (reject_reason !== REJECT_MAX_SHORT) $fatal(1, "Test 13 failed: wrong reject reason");
        $display("PASS");
        @(negedge clk);
        clear_inputs();

        //should be good if we make it here. 
        $display("");
        $display("YAHOO ALL TESTS PASSED");
        $finish;
    end
endmodule
