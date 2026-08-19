`timescale 1ns / 1ps

module phy_reset_ctrl #(
    parameter integer CLK_HZ        = 50_000_000,
    parameter integer RESET_HOLD_MS = 10
) (
    input  logic clk,
    input  logic rst_n,
    output logic phy_rst_n,
    output logic phy_ready
);

localparam integer HOLD_CYCLES = (CLK_HZ / 1000) * RESET_HOLD_MS;
localparam integer CNT_WIDTH   = (HOLD_CYCLES <= 1) ? 1 : $clog2(HOLD_CYCLES + 1);

logic [CNT_WIDTH-1:0] count;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        count     <= '0;
        phy_rst_n <= 1'b0;
        phy_ready <= 1'b0;
    end else if (!phy_ready) begin
        if (count == HOLD_CYCLES - 1) begin
            phy_rst_n <= 1'b1;
            phy_ready <= 1'b1;
        end else begin
            count <= count + 1'b1;
        end
    end
end

endmodule
