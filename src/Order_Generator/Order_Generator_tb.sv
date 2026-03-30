module Order_Generator_tb;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam ORDER_ID_LEN = 32;
    localparam QUANTITY_LEN = 32;
    localparam PRICE_LEN    = 64;
    localparam SYMBOL_LEN   = 64;
    localparam CLK_PERIOD   = 10;

    // OUCH field widths
    localparam ENTER_MSG_LEN   = 376;
    localparam REPLACE_MSG_LEN = 320; 

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    logic                       clk, rst_n;
    logic [SYMBOL_LEN-1:0]      i_symbol;
    logic [ORDER_ID_LEN-1:0]    i_old_order_num_buy;
    logic [ORDER_ID_LEN-1:0]    i_old_order_num_sell;
    logic                       i_old_order_executed_buy;
    logic                       i_old_order_executed_sell;
    logic [SYMBOL_LEN-1:0]      i_old_symbol_buy;
    logic [SYMBOL_LEN-1:0]      i_old_symbol_sell;
    logic [PRICE_LEN-1:0]       i_price_buy;
    logic [PRICE_LEN-1:0]       i_price_sell;
    logic [QUANTITY_LEN-1:0]    i_quantity_buy;
    logic [QUANTITY_LEN-1:0]    i_quantity_sell;
    logic                       i_valid_buy;
    logic                       i_valid_sell;

    logic [QUANTITY_LEN-1:0]    o_quantity_buy;
    logic [QUANTITY_LEN-1:0]    o_quantity_sell;
    logic [PRICE_LEN-1:0]       o_price_buy;
    logic [PRICE_LEN-1:0]       o_price_sell;
    logic [ORDER_ID_LEN-1:0]    o_new_order_num_buy;
    logic [ORDER_ID_LEN-1:0]    o_new_order_num_sell;
    logic [751:0]               o_payload;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    Order_Generator #(
        .ORDER_ID_LEN (ORDER_ID_LEN),
        .QUANTITY_LEN (QUANTITY_LEN),
        .PRICE_LEN    (PRICE_LEN),
        .SYMBOL_LEN   (SYMBOL_LEN)
    ) dut (
        .i_clk                    (clk),
        .i_rst_n                  (rst_n),
        .i_symbol                 (i_symbol),
        .i_old_order_num_buy      (i_old_order_num_buy),
        .i_old_order_num_sell     (i_old_order_num_sell),
        .i_old_order_executed_buy (i_old_order_executed_buy),
        .i_old_order_executed_sell(i_old_order_executed_sell),
        .i_old_symbol_buy         (i_old_symbol_buy),
        .i_old_symbol_sell        (i_old_symbol_sell),
        .i_price_buy              (i_price_buy),
        .i_price_sell             (i_price_sell),
        .i_quantity_buy           (i_quantity_buy),
        .i_quantity_sell          (i_quantity_sell),
        .i_valid_buy              (i_valid_buy),
        .i_valid_sell             (i_valid_sell),
        .o_quantity_buy           (o_quantity_buy),
        .o_quantity_sell          (o_quantity_sell),
        .o_price_buy              (o_price_buy),
        .o_price_sell             (o_price_sell),
        .o_new_order_num_buy      (o_new_order_num_buy),
        .o_new_order_num_sell     (o_new_order_num_sell),
        .o_payload                (o_payload)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Decode and print an Enter Order message given its 376-bit slice
    task automatic print_enter(input [375:0] msg, input string side_label);
        logic [7:0]  msg_type;
        logic [31:0] ref_num;
        logic [7:0]  side;
        logic [31:0] qty;
        logic [63:0] symbol;
        logic [63:0] price;
        begin
            msg_type = msg[375:368];
            ref_num  = msg[367:336];
            side     = msg[335:328];
            qty      = msg[327:296];
            symbol   = msg[295:232];
            price    = msg[231:168];
            $display("    [OUCH Enter Order] Type=0x%02X (%s) | RefNum=0x%08X | Side=%s | Qty=%0d | Symbol=0x%016X | Price=0x%016X",
                     msg_type, side_label,
                     ref_num,
                     (side == 8'h42) ? "Buy (B)" : "Sell(S)",
                     qty, symbol, price);
        end
    endtask

    // Decode and print a Replace Order message given its 320-bit slice
    task automatic print_replace(input [319:0] msg, input string side_label);
        logic [7:0]  msg_type;
        logic [31:0] orig_ref;
        logic [31:0] new_ref;
        logic [31:0] qty;
        logic [63:0] price;
        begin
            msg_type = msg[319:312];
            orig_ref = msg[311:280];
            new_ref  = msg[279:248];
            qty      = msg[247:216];
            price    = msg[215:152];
            $display("    [OUCH Replace Order] Type=0x%02X (%s) | OrigRef=0x%08X | NewRef=0x%08X | Qty=%0d | Price=0x%016X",
                     msg_type, side_label,
                     orig_ref, new_ref, qty, price);
        end
    endtask

    // Print the full payload by inspecting each half's message type byte
    task automatic print_payload(input string scenario);
        logic [7:0] buy_type, sell_type;
        begin
            buy_type  = o_payload[751:744];  // MSB of upper half
            sell_type = o_payload[375:368];  // MSB of lower half

            $display("  -- Scalar outputs: buy_order_num=0x%08X  sell_order_num=0x%08X  price_buy=0x%016X  price_sell=0x%016X  qty_buy=%0d  qty_sell=%0d",
                     o_new_order_num_buy, o_new_order_num_sell,
                     o_price_buy, o_price_sell,
                     o_quantity_buy, o_quantity_sell);

            // BUY side (upper 376 bits) — always Enter or Replace
            if (buy_type == 8'h4F)
                print_enter(o_payload[751:376], "BUY ");
            else if (buy_type == 8'h55)
                print_replace(o_payload[751:432], "BUY ");  // 320b slice from top
            else
                $display("    [BUY ] Unknown type 0x%02X", buy_type);

            // SELL side
            if (sell_type == 8'h4F)
                print_enter(o_payload[375:0], "SELL");
            else if (sell_type == 8'h55)
                print_replace(o_payload[319:0], "SELL");   // 320b slice from bottom
            else
                $display("    [SELL] Unknown type 0x%02X", sell_type);
        end
    endtask

    task automatic run_scenario(
        input string  label,
        input         valid_buy,
        input         exec_buy,
        input         valid_sell,
        input         exec_sell,
        input [31:0]  old_ref_buy,
        input [31:0]  old_ref_sell,
        input [63:0]  price_buy,
        input [63:0]  price_sell,
        input [63:0]  symbol
    );
        @(negedge clk);
        i_valid_buy               = valid_buy;
        i_old_order_executed_buy  = exec_buy;
        i_valid_sell              = valid_sell;
        i_old_order_executed_sell = exec_sell;
        i_old_order_num_buy       = old_ref_buy;
        i_old_order_num_sell      = old_ref_sell;
        i_price_buy               = price_buy;
        i_price_sell              = price_sell;
        i_symbol                  = symbol;
        i_quantity_buy            = 32'd100;
        i_quantity_sell           = 32'd100;
        @(posedge clk); #1;
        $display("[%0t] SCENARIO: %s", $time, label);
        print_payload(label);
        $display("");
    endtask

    initial begin
        // Idle / reset state
        rst_n                     = 1'b0;
        i_valid_buy               = 0;
        i_valid_sell              = 0;
        i_old_order_executed_buy  = 0;
        i_old_order_executed_sell = 0;
        i_old_order_num_buy       = '0;
        i_old_order_num_sell      = '0;
        i_price_buy               = '0;
        i_price_sell              = '0;
        i_symbol                  = '0;
        i_quantity_buy            = '0;
        i_quantity_sell           = '0;
        i_old_symbol_buy          = '0;
        i_old_symbol_sell         = '0;

        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        $display("=========================================================");
        $display(" Order_Generator Testbench — OUCH Payload Decode");
        $display("=========================================================\n");

        // --- Scenario 1: Both New -------------------------------------------
        // Condition: (!valid_buy || exec_buy) && (!valid_sell || exec_sell)
        // Drive:     valid_buy=0, valid_sell=0  (cleanest way to trigger it)
        run_scenario(
            "BOTH NEW  (valid_buy=0, valid_sell=0)",
            /*valid_buy*/  1'b0, /*exec_buy*/  1'bx,
            /*valid_sell*/ 1'b0, /*exec_sell*/ 1'bx,
            /*old_ref_buy*/  32'hDEAD_0001, /*old_ref_sell*/ 32'hDEAD_0002,
            /*price_buy*/    64'h0000_0000_0000_4E20,   // 20000
            /*price_sell*/   64'h0000_0000_0000_5208,   // 21000
            /*symbol*/       64'h4150504C2020_2020      // "APPL    "
        );

        // Alternate trigger: both executed
        run_scenario(
            "BOTH NEW  (valid_buy=1 exec_buy=1, valid_sell=1 exec_sell=1)",
            /*valid_buy*/  1'b1, /*exec_buy*/  1'b1,
            /*valid_sell*/ 1'b1, /*exec_sell*/ 1'b1,
            32'hAAAA_0001, 32'hAAAA_0002,
            64'h0000_0000_0000_4E20,
            64'h0000_0000_0000_5208,
            64'h4D53465420202020    // "MSFT    "
        );

        // --- Scenario 2: New Buy / Old Sell ---------------------------------
        // Condition: (!valid_buy || exec_buy) && (valid_sell && !exec_sell)
        // Drive:     valid_buy=0, valid_sell=1, exec_sell=0
        run_scenario(
            "NEW BUY / OLD SELL  (valid_buy=0, valid_sell=1, exec_sell=0)",
            1'b0, 1'bx,
            1'b1, 1'b0,
            32'hBEEF_0001, 32'hBEEF_0002,
            64'h0000_0000_0000_61A8,   // 25000
            64'h0000_0000_0000_6590,   // 26000
            64'h474F4F47202020_20      // "GOOG    "
        );

        // Alternate trigger: valid_buy=1 but exec_buy=1 (treated as no live order)
        run_scenario(
            "NEW BUY / OLD SELL  (valid_buy=1 exec_buy=1, valid_sell=1 exec_sell=0)",
            1'b1, 1'b1,
            1'b1, 1'b0,
            32'hBEEF_0003, 32'hBEEF_0004,
            64'h0000_0000_0000_61A8,
            64'h0000_0000_0000_6590,
            64'h4E564441_20202020     // "NVDA    "
        );

        // --- Scenario 3: Old Buy / New Sell ---------------------------------
        // Condition: (valid_buy && !exec_buy) && (!valid_sell || exec_sell)
        // Drive:     valid_buy=1, exec_buy=0, valid_sell=0
        run_scenario(
            "OLD BUY / NEW SELL  (valid_buy=1 exec_buy=0, valid_sell=0)",
            1'b1, 1'b0,
            1'b0, 1'bx,
            32'hCAFE_0001, 32'hCAFE_0002,
            64'h0000_0000_0000_7530,   // 30000
            64'h0000_0000_0000_7918,   // 31000
            64'h414D5A4E_20202020      // "AMZN    "
        );

        // Alternate trigger: valid_sell=1 but exec_sell=1
        run_scenario(
            "OLD BUY / NEW SELL  (valid_buy=1 exec_buy=0, valid_sell=1 exec_sell=1)",
            1'b1, 1'b0,
            1'b1, 1'b1,
            32'hCAFE_0003, 32'hCAFE_0004,
            64'h0000_0000_0000_7530,
            64'h0000_0000_0000_7918,
            64'h4D455441_20202020      // "META    "
        );

        // --- Scenario 4: Both Old -------------------------------------------
        // Condition: (valid_buy && !exec_buy) && (valid_sell && !exec_sell)
        // Drive:     valid_buy=1, exec_buy=0, valid_sell=1, exec_sell=0
        run_scenario(
            "BOTH OLD  (valid_buy=1 exec_buy=0, valid_sell=1 exec_sell=0)",
            1'b1, 1'b0,
            1'b1, 1'b0,
            32'hF00D_0001, 32'hF00D_0002,
            64'h0000_0000_0000_9C40,   // 40000
            64'h0000_0000_0000_A028,   // 41000
            64'h54534C41_20202020      // "TSLA    "
        );

        run_scenario(
            "BOTH OLD  (valid_buy=1 exec_buy=0, valid_sell=1 exec_sell=0) #2",
            1'b1, 1'b0,
            1'b1, 1'b0,
            32'hF00D_0003, 32'hF00D_0004,
            64'h0000_0000_0000_C350,   // 50000
            64'h0000_0000_0000_C738,   // 51000
            64'h5350595F_20202020      // "SPY_    "
        );

        $display("=========================================================");
        $display(" Done.");
        $display("=========================================================");
        repeat(4) @(posedge clk);
        $finish;
    end

endmodule
