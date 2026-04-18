module inventory (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        buy_valid,
    input  logic        sell_valid,
    input  logic [15:0] qty,
    output logic signed [15:0] q
);

    always_ff @(posedge clk) begin
        if (!rst_n)
            q <= '0;
        else if (buy_valid)
            q <= q + qty;
        else if (sell_valid)
            q <= q - qty;
    end

endmodule