`timescale 1ns / 1ps
import lob_pkg::*;
// price_level.sv - price level table (one per side).
// Synchronous BRAM indexed by level index, holding head/tail pointers and
// total quantity for each price level.  head_ptr==0 means the level is empty.

module price_level #(
    parameter int NUM_LEVELS = 4096,
    parameter int ADDR_W     = 12
) (
    input  logic              clk,
    input  logic [ADDR_W-1:0] addr,
    input  logic              we,
    input  logic              re,
    input  level_rec_t        wdata,
    output level_rec_t        rdata
);

  localparam int LEVEL_W = $bits(level_rec_t);
  logic [LEVEL_W-1:0] mem [0:NUM_LEVELS-1];

  // Zero-initialize so empty levels read head_ptr==0.  (In the FPGA this
  // maps to BRAM INIT or a reset-clearing FSM; here it is an initial block.)
  initial begin
    for (int i = 0; i < NUM_LEVELS; i++) begin
      mem[i] = '0;
    end
  end

  always_ff @(posedge clk) begin
    if (we) mem[addr] <= wdata;
    if (re) rdata     <= level_rec_t'(mem[addr]);
  end

endmodule
