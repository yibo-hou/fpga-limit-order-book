`timescale 1ns / 1ps

module ethernet_crc32 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        init,
    input  logic        data_valid,
    input  logic [7:0]  data,
    output logic [31:0] crc_state,
    output logic [31:0] crc_next
);

function automatic logic [31:0] update_crc32;
    input logic [31:0] crc_in;
    input logic [7:0]  data_in;
    logic [31:0] crc;
    integer i;
    begin
        crc = crc_in;
        for (i = 0; i < 8; i = i + 1) begin
            if (crc[0] ^ data_in[i])
                crc = (crc >> 1) ^ 32'hedb8_8320;
            else
                crc = crc >> 1;
        end
        update_crc32 = crc;
    end
endfunction

always_comb crc_next = update_crc32(crc_state, data);

always_ff @(posedge clk) begin
    if (!rst_n || init)
        crc_state <= 32'hffff_ffff;
    else if (data_valid)
        crc_state <= crc_next;
end

endmodule
