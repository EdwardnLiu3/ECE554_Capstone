module divider_q16 #(
    parameter WIDTH     = 32,
    parameter FRAC_BITS = 16
)(
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [WIDTH-1:0] dividend,
    input  logic [WIDTH-1:0] divisor,
    output logic [WIDTH-1:0] quotient,
    output logic done,
    output logic error
);

    localparam DWIDTH = 2 * WIDTH;  // 64

    logic [DWIDTH-1:0] numerator;
    logic [DWIDTH-1:0] divisor_ext;
    logic [DWIDTH-1:0] remainder;
    logic [DWIDTH-1:0] quotient_reg;
    logic [$clog2(DWIDTH)+1:0]  count;
    logic busy;

    // Combinational signals for current step
    logic [DWIDTH-1:0]  remainder_shifted;
    logic [DWIDTH-1:0]  remainder_sub;
    logic               sub_ge;

    always_comb begin
        remainder_shifted=(remainder << 1) | ((numerator >> (DWIDTH-1 -count)) & 1);
        remainder_sub=remainder_shifted - divisor_ext;
        sub_ge = (remainder_shifted >= divisor_ext) ? 1'b1 : 1'b0;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            numerator <= '0;
            divisor_ext <= '0;
            remainder <= '0;
            quotient_reg <= '0;
            count <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;

        end else begin
            done  <= 1'b0;
            error <= 1'b0;

            if (start && !busy) begin
                if (divisor == '0) begin
                    error <= 1'b1;
                    done  <= 1'b1;
                end else begin
                    numerator    <= {{WIDTH{1'b0}}, dividend} << FRAC_BITS;
                    divisor_ext  <= {{WIDTH{1'b0}}, divisor};
                    quotient_reg <= '0;
                    remainder    <= '0;
                    count        <= '0;
                    busy         <= 1'b1;
                end
            end else if (busy) begin
                if (count < DWIDTH) begin
                    if (sub_ge) begin
                        remainder <= remainder_sub;
                        quotient_reg[DWIDTH-1-count]<= 1'b1;
                    end else begin
                        remainder <= remainder_shifted;
                        quotient_reg[DWIDTH-1-count] <= 1'b0;
                    end
                    count <= count + 1;
                end else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

    // Quotient is in bits WIDTH-1:0 of quotient_reg
    assign quotient = quotient_reg[WIDTH-1:0];

endmodule