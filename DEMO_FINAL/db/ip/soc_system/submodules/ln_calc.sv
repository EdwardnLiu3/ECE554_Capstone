module ln_calc #(
    parameter INT_BITS  = 8,                    // integer bits
    parameter FRAC_BITS = 8,                    // fractional bits
    parameter WIDTH     = INT_BITS + FRAC_BITS  // total = 16
)(
    input  logic [WIDTH-1:0]        x_in,   // unsigned Q8.8 input  (x > 0)
    output logic signed [WIDTH-1:0] ln_out, // signed   Q8.8 output
    output logic                    valid   // 1 = result is valid
);

    // -------------------------------------------------------------------------
    //  LN(2) in Q8.8:  0.693147 × 256 = 177.45  →  177
    // -------------------------------------------------------------------------
    // Q8.9: 0.693147×512 = 354.89 → 355 (error 0.054 ULP/n vs 0.445 ULP/n for Q8.8)
    localparam signed [9:0] LN2_FP9 = 10'sd355;

    logic [7:0] ln_lut [0:255];

    initial begin
        // i=0..15
        {ln_lut[0],  ln_lut[1],  ln_lut[2],  ln_lut[3],
         ln_lut[4],  ln_lut[5],  ln_lut[6],  ln_lut[7],
         ln_lut[8],  ln_lut[9],  ln_lut[10], ln_lut[11],
         ln_lut[12], ln_lut[13], ln_lut[14], ln_lut[15]}
          = {8'd0,  8'd1,  8'd2,  8'd3,  8'd4,  8'd5,  8'd6,  8'd7,
             8'd8,  8'd9,  8'd10, 8'd11, 8'd12, 8'd13, 8'd14, 8'd15};
        // i=16..31
        {ln_lut[16], ln_lut[17], ln_lut[18], ln_lut[19],
         ln_lut[20], ln_lut[21], ln_lut[22], ln_lut[23],
         ln_lut[24], ln_lut[25], ln_lut[26], ln_lut[27],
         ln_lut[28], ln_lut[29], ln_lut[30], ln_lut[31]}
          = {8'd16, 8'd16, 8'd17, 8'd18, 8'd19, 8'd20, 8'd21, 8'd22,
             8'd23, 8'd24, 8'd25, 8'd26, 8'd27, 8'd27, 8'd28, 8'd29};
        // i=32..47
        {ln_lut[32], ln_lut[33], ln_lut[34], ln_lut[35],
         ln_lut[36], ln_lut[37], ln_lut[38], ln_lut[39],
         ln_lut[40], ln_lut[41], ln_lut[42], ln_lut[43],
         ln_lut[44], ln_lut[45], ln_lut[46], ln_lut[47]}
          = {8'd30, 8'd31, 8'd32, 8'd33, 8'd34, 8'd35, 8'd35, 8'd36,
             8'd37, 8'd38, 8'd39, 8'd40, 8'd41, 8'd41, 8'd42, 8'd43};
        // i=48..63
        {ln_lut[48], ln_lut[49], ln_lut[50], ln_lut[51],
         ln_lut[52], ln_lut[53], ln_lut[54], ln_lut[55],
         ln_lut[56], ln_lut[57], ln_lut[58], ln_lut[59],
         ln_lut[60], ln_lut[61], ln_lut[62], ln_lut[63]}
          = {8'd44, 8'd45, 8'd46, 8'd47, 8'd47, 8'd48, 8'd49, 8'd50,
             8'd51, 8'd51, 8'd52, 8'd53, 8'd54, 8'd55, 8'd56, 8'd56};
        // i=64..79
        {ln_lut[64], ln_lut[65], ln_lut[66], ln_lut[67],
         ln_lut[68], ln_lut[69], ln_lut[70], ln_lut[71],
         ln_lut[72], ln_lut[73], ln_lut[74], ln_lut[75],
         ln_lut[76], ln_lut[77], ln_lut[78], ln_lut[79]}
          = {8'd57, 8'd58, 8'd59, 8'd60, 8'd60, 8'd61, 8'd62, 8'd63,
             8'd63, 8'd64, 8'd65, 8'd66, 8'd67, 8'd67, 8'd68, 8'd69};
        // i=80..95
        {ln_lut[80], ln_lut[81], ln_lut[82], ln_lut[83],
         ln_lut[84], ln_lut[85], ln_lut[86], ln_lut[87],
         ln_lut[88], ln_lut[89], ln_lut[90], ln_lut[91],
         ln_lut[92], ln_lut[93], ln_lut[94], ln_lut[95]}
          = {8'd70, 8'd70, 8'd71, 8'd72, 8'd73, 8'd73, 8'd74, 8'd75,
             8'd76, 8'd76, 8'd77, 8'd78, 8'd79, 8'd79, 8'd80, 8'd81};
        // i=96..111
        {ln_lut[96],  ln_lut[97],  ln_lut[98],  ln_lut[99],
         ln_lut[100], ln_lut[101], ln_lut[102], ln_lut[103],
         ln_lut[104], ln_lut[105], ln_lut[106], ln_lut[107],
         ln_lut[108], ln_lut[109], ln_lut[110], ln_lut[111]}
          = {8'd82, 8'd82, 8'd83, 8'd84, 8'd84, 8'd85, 8'd86, 8'd87,
             8'd87, 8'd88, 8'd89, 8'd89, 8'd90, 8'd91, 8'd92, 8'd92};
        // i=112..127
        {ln_lut[112], ln_lut[113], ln_lut[114], ln_lut[115],
         ln_lut[116], ln_lut[117], ln_lut[118], ln_lut[119],
         ln_lut[120], ln_lut[121], ln_lut[122], ln_lut[123],
         ln_lut[124], ln_lut[125], ln_lut[126], ln_lut[127]}
          = {8'd93, 8'd94, 8'd94, 8'd95, 8'd96, 8'd96, 8'd97, 8'd98,
             8'd98, 8'd99, 8'd100,8'd100,8'd101,8'd102,8'd102,8'd103};
        // i=128..143
        {ln_lut[128], ln_lut[129], ln_lut[130], ln_lut[131],
         ln_lut[132], ln_lut[133], ln_lut[134], ln_lut[135],
         ln_lut[136], ln_lut[137], ln_lut[138], ln_lut[139],
         ln_lut[140], ln_lut[141], ln_lut[142], ln_lut[143]}
          = {8'd104,8'd104,8'd105,8'd106,8'd106,8'd107,8'd108,8'd108,
             8'd109,8'd110,8'd110,8'd111,8'd112,8'd112,8'd113,8'd114};
        // i=144..159
        {ln_lut[144], ln_lut[145], ln_lut[146], ln_lut[147],
         ln_lut[148], ln_lut[149], ln_lut[150], ln_lut[151],
         ln_lut[152], ln_lut[153], ln_lut[154], ln_lut[155],
         ln_lut[156], ln_lut[157], ln_lut[158], ln_lut[159]}
          = {8'd114,8'd115,8'd116,8'd116,8'd117,8'd117,8'd118,8'd119,
             8'd119,8'd120,8'd121,8'd121,8'd122,8'd122,8'd123,8'd124};
        // i=160..175
        {ln_lut[160], ln_lut[161], ln_lut[162], ln_lut[163],
         ln_lut[164], ln_lut[165], ln_lut[166], ln_lut[167],
         ln_lut[168], ln_lut[169], ln_lut[170], ln_lut[171],
         ln_lut[172], ln_lut[173], ln_lut[174], ln_lut[175]}
          = {8'd124,8'd125,8'd126,8'd126,8'd127,8'd127,8'd128,8'd129,
             8'd129,8'd130,8'd130,8'd131,8'd132,8'd132,8'd133,8'd133};
        // i=176..191
        {ln_lut[176], ln_lut[177], ln_lut[178], ln_lut[179],
         ln_lut[180], ln_lut[181], ln_lut[182], ln_lut[183],
         ln_lut[184], ln_lut[185], ln_lut[186], ln_lut[187],
         ln_lut[188], ln_lut[189], ln_lut[190], ln_lut[191]}
          = {8'd134,8'd135,8'd135,8'd136,8'd136,8'd137,8'd137,8'd138,
             8'd139,8'd139,8'd140,8'd140,8'd141,8'd142,8'd142,8'd143};
        // i=192..207
        {ln_lut[192], ln_lut[193], ln_lut[194], ln_lut[195],
         ln_lut[196], ln_lut[197], ln_lut[198], ln_lut[199],
         ln_lut[200], ln_lut[201], ln_lut[202], ln_lut[203],
         ln_lut[204], ln_lut[205], ln_lut[206], ln_lut[207]}
          = {8'd143,8'd144,8'd144,8'd145,8'd146,8'd146,8'd147,8'd147,
             8'd148,8'd148,8'd149,8'd149,8'd150,8'd151,8'd151,8'd152};
        // i=208..223
        {ln_lut[208], ln_lut[209], ln_lut[210], ln_lut[211],
         ln_lut[212], ln_lut[213], ln_lut[214], ln_lut[215],
         ln_lut[216], ln_lut[217], ln_lut[218], ln_lut[219],
         ln_lut[220], ln_lut[221], ln_lut[222], ln_lut[223]}
          = {8'd152,8'd153,8'd153,8'd154,8'd154,8'd155,8'd156,8'd156,
             8'd157,8'd157,8'd158,8'd158,8'd159,8'd159,8'd160,8'd160};
        // i=224..239
        {ln_lut[224], ln_lut[225], ln_lut[226], ln_lut[227],
         ln_lut[228], ln_lut[229], ln_lut[230], ln_lut[231],
         ln_lut[232], ln_lut[233], ln_lut[234], ln_lut[235],
         ln_lut[236], ln_lut[237], ln_lut[238], ln_lut[239]}
          = {8'd161,8'd161,8'd162,8'd163,8'd163,8'd164,8'd164,8'd165,
             8'd165,8'd166,8'd166,8'd167,8'd167,8'd168,8'd168,8'd169};
        // i=240..255
        {ln_lut[240], ln_lut[241], ln_lut[242], ln_lut[243],
         ln_lut[244], ln_lut[245], ln_lut[246], ln_lut[247],
         ln_lut[248], ln_lut[249], ln_lut[250], ln_lut[251],
         ln_lut[252], ln_lut[253], ln_lut[254], ln_lut[255]}
          = {8'd169,8'd170,8'd170,8'd171,8'd171,8'd172,8'd172,8'd173,
             8'd173,8'd174,8'd174,8'd175,8'd175,8'd176,8'd176,8'd177};
    end

    logic [3:0] msb_pos;

    always_comb begin
        msb_pos = 4'd0;
        for (int i = 0; i < WIDTH; i++) begin
            if (x_in[i]) msb_pos = 4'(i);
        end
    end

    logic signed [4:0] n;
    assign n = $signed({1'b0, msb_pos}) - 5'sd8;   // signed(msb_pos) - FRAC_BITS

    logic [WIDTH-1:0] x_norm;   // normalised  (leading 1 at bit FRAC_BITS)

    always_comb begin
        if (msb_pos >= FRAC_BITS[3:0])
            x_norm = x_in >> (msb_pos - FRAC_BITS[3:0]);
        else
            x_norm = x_in << (FRAC_BITS[3:0] - msb_pos);
    end

    logic [FRAC_BITS-1:0] lut_idx;
    assign lut_idx = x_norm[FRAC_BITS-1:0];    // bits [7:0] of m

    logic [7:0] lut_val;
    assign lut_val = ln_lut[lut_idx];

    logic signed [15:0] n_ln2_q9;
    assign n_ln2_q9 = $signed({{11{n[4]}}, n}) * $signed({6'b0, LN2_FP9});

    // Convert lut_val from Q8.8 → Q8.9 (left-shift 1)
    logic signed [15:0] lut_q9;
    assign lut_q9 = $signed({8'b0, lut_val, 1'b0});

    // Sum in Q8.9, then round-right-shift back to Q8.8
    logic signed [15:0] sum_q9;
    assign sum_q9 = n_ln2_q9 + lut_q9;

    // Rounded divide-by-2 (add 0.5 before truncation)
    assign ln_out = (sum_q9 + 16'sd1) >>> 1;

    //  Valid flag: undefined for x = 0  (ln(0) = -∞)
    assign valid = (x_in != '0);

endmodule
