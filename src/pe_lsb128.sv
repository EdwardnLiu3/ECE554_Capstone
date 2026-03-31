module pe_lsb128(
    input [127:0]   i_data,
    output          o_found,
    output [6:0]    o_idx
);

always_comb begin
    o_found = 1'b0;
    o_idx   = 7'd0;

    for (int i = 0; i < 128; i++) begin
        if (i_data[i]) begin
            o_found = 1'b1;
            o_idx   = i[6:0];
            break;
        end
    end
end

endmodule