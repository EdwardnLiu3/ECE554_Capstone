module parser_tb;

    localparam ORDERID_LEN  = 64;
    localparam QUANTITY_LEN = 32;
    localparam PRICE_LEN    = 32;
    localparam STOCK_LEN    = 16;

    localparam CLK_PERIOD   = 10; // ns

    logic                       clk;
    logic                       rst_n;
    logic [287:0]               payload;
    logic                       valid;

    logic [ORDERID_LEN-1:0]     o_order_id;
    logic [QUANTITY_LEN-1:0]    o_quantity;
    logic                       o_side;
    logic [PRICE_LEN-1:0]       o_price;
    logic [1:0]                 o_action;
    logic                       o_valid;
    logic [STOCK_LEN-1:0]       o_stock_id;

    parser #(
        .ORDERID_LEN  (ORDERID_LEN),
        .QUANTITY_LEN (QUANTITY_LEN),
        .PRICE_LEN    (PRICE_LEN),
        .STOCK_LEN    (STOCK_LEN)
    ) dut (
        .i_clk      (clk),
        .i_rst_n    (rst_n),
        .i_payload  (payload),
        .i_valid    (valid),
        .o_order_id (o_order_id),
        .o_quantity (o_quantity),
        .o_side     (o_side),
        .o_price    (o_price),
        .o_action   (o_action),
        .o_valid    (o_valid),
        .o_stock_id (o_stock_id)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task automatic send_msg(
        input [287:0] pkt,
        input string  msg_name
    );
        @(negedge clk);
        payload = pkt;
        valid   = 1'b1;
        @(posedge clk); #1; // outputs registered on this edge
        $display("[%0t] %s | valid=%b action=%02b order_id=%016h qty=%08h side=%b price=%08h stock=%04h",
                 $time, msg_name,
                 o_valid, o_action, o_order_id,
                 o_quantity, o_side, o_price, o_stock_id);
        @(negedge clk);
        valid = 1'b0;
        payload = '0;
    endtask

    function automatic [287:0] build_add(
        input [15:0]  stock_id,
        input [63:0]  order_id,
        input         is_sell,     // 0 = Buy, 1 = Sell
        input [31:0]  quantity,
        input [31:0]  price
    );
        logic [287:0] p = '0;
        p[7:0]     = 8'h41;                          // 'A'
        p[23:8]    = stock_id;
        p[151:88]  = order_id;
        p[159:152] = is_sell ? 8'h53 : 8'h42;        // 'S' or 'B'
        p[191:160] = quantity;
        p[287:256] = price;
        return p;
    endfunction

    function automatic [287:0] build_cancel(
        input [15:0]  stock_id,
        input [63:0]  order_id,
        input [31:0]  quantity
    );
        logic [287:0] p = '0;
        p[7:0]     = 8'h58;                          // 'X'
        p[23:8]    = stock_id;
        p[151:88]  = order_id;
        p[183:152] = quantity;
        return p;
    endfunction

    function automatic [287:0] build_delete(
        input [15:0]  stock_id,
        input [63:0]  order_id
    );
        logic [287:0] p = '0;
        p[7:0]     = 8'h44;                          // 'D'
        p[23:8]    = stock_id;
        p[151:88]  = order_id;
        return p;
    endfunction

    function automatic [287:0] build_execute(
        input [15:0]  stock_id,
        input [63:0]  order_id,
        input [31:0]  quantity
    );
        logic [287:0] p = '0;
        p[7:0]     = 8'h45;                          // 'E'
        p[23:8]    = stock_id;
        p[151:88]  = order_id;
        p[183:152] = quantity;
        return p;
    endfunction

    initial begin
        // Reset
        rst_n   = 1'b0;
        payload = '0;
        valid   = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        $display("=== ITCH Parser Testbench ===");

        // --- Add Order (x2) ---
        send_msg(build_add(16'hABCD, 64'h0000_0000_0000_0001, 0, 32'd100,  32'd15000), "ADD    #1 (Buy )");
        send_msg(build_add(16'hDEAD, 64'h0000_0000_0000_0002, 1, 32'd200,  32'd32000), "ADD    #2 (Sell)");

        // --- Cancel Order (x2) ---
        send_msg(build_cancel(16'hABCD, 64'h0000_0000_0000_0001, 32'd50),  "CANCEL #1");
        send_msg(build_cancel(16'hDEAD, 64'h0000_0000_0000_0002, 32'd200), "CANCEL #2");

        // --- Delete Order (x2) ---
        send_msg(build_delete(16'hABCD, 64'h0000_0000_0000_0003), "DELETE #1");
        send_msg(build_delete(16'hDEAD, 64'h0000_0000_0000_0004), "DELETE #2");

        // --- Execute Order (x2) ---
        send_msg(build_execute(16'hABCD, 64'h0000_0000_0000_0005, 32'd75),  "EXECUTE#1");
        send_msg(build_execute(16'hDEAD, 64'h0000_0000_0000_0006, 32'd150), "EXECUTE#2");

        $display("=== Done ===");
        repeat(4) @(posedge clk);
        $finish;
    end

endmodule
