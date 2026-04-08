module fetch #(
    parameter DEPTHA=8,
    parameter DATA_WIDTH=64
)(  input logic clk,
    input logic rst_n,
    input logic request,
    output logic done,
    output logic [71:0] curr_data
);

logic [3:0] count;
logic idle_s, wait_s, fetch_s, done_s;
logic valid, req;
logic [DATA_WIDTH-1:0] MEM [0:DEPTHA];
logic [7:0]a0,a1,a2,a3,a4,a5,a6,a7,b0;
logic [5:0] index;
logic [DATA_WIDTH-1:0]data_out;
typedef enum logic[1:0] {IDLE, WAIT, FETCH, DONE} state_e;
state_e state, next_state;

assign idle_s = state == IDLE;
assign wait_s = state == WAIT;
assign fetch_s = state == FETCH;
assign done_s = state == DONE;

assign curr_data = {b0, a7, a6, a5, a4, a3, a2, a1, a0};

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) state <= IDLE;
    else      state <= next_state;
end

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n)  count <= 0;
    else if(fetch_s) begin
        count<= count + 1;
        MEM[count] <= data_out;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) index <= 6'd63;
    else if(done_s) begin
        index <= index - 6'd8;
        a0 <= MEM[0][index-:8];
        a1 <= MEM[1][index-:8];
        a2 <= MEM[2][index-:8];
        a3 <= MEM[3][index-:8];
        a4 <= MEM[4][index-:8];
        a5 <= MEM[5][index-:8];
        a6 <= MEM[6][index-:8];
        a7 <= MEM[7][index-:8];
        b0 <= MEM[8][index-:8];
    end else 
        index <= 6'd63;
end

always_comb begin
    done = 0;
    next_state = state;
    case(state)
        default: begin
            req = 0;
            if(request) begin
                next_state = WAIT;
                req = 1;
            end
        end
        WAIT: begin
            req = 1;
            if(valid) begin
                next_state = FETCH;
                req = 0;
            end
        end
        FETCH: begin
            if(count == DEPTHA) begin
                next_state = DONE;
                req = 0;
                done = 1;
            end else begin
                next_state = WAIT;
                req = 1;
            end
        end
        DONE: begin
            req = 0;
            done = 1;
            if(index == 6'd7) begin
                next_state = IDLE;
            end
        end

    endcase
end

mem_wrapper mw(
    .clk(clk), 
    .reset_n(rst_n), 
    .address(count), 
    .read(req), 
    .readdata(data_out),
    .readdatavalid(valid),
    .waitrequest());


    
endmodule