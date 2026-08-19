`timescale 1ns / 1ps
// fifo_queue.sv - parameterized synchronous valid/ready FIFO (FWFT).
// Used for command staging, trade, report and ack queues.

module fifo_queue #(
    parameter int DATA_W = 8,
    parameter int DEPTH  = 16          // must be a power of two
) (
    input  logic clk,
    input  logic rst_n,

    // push side
    input  logic [DATA_W-1:0] s_data,
    input  logic              s_valid,
    output logic              s_ready,

    // pop side
    output logic [DATA_W-1:0] m_data,
    output logic              m_valid,
    input  logic              m_ready,

    output logic [$clog2(DEPTH+1)-1:0] count,
    output logic full,
    output logic empty
);

  localparam int CNT_W = $clog2(DEPTH + 1);

  logic [DATA_W-1:0] mem [0:DEPTH-1];
  logic [$clog2(DEPTH)-1:0] wr_ptr, rd_ptr;
  logic [CNT_W-1:0] cnt;

  logic push;
  logic pop;

  assign push      = s_valid && s_ready;
  assign pop       = m_valid && m_ready;
  assign s_ready   = !full;
  assign m_valid   = !empty;
  assign m_data    = mem[rd_ptr];
  assign full      = (cnt == CNT_W'(DEPTH));
  assign empty     = (cnt == '0);
  assign count     = cnt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      cnt    <= '0;
    end else begin
      if (push && pop) begin
        mem[wr_ptr] <= s_data;
        wr_ptr      <= wr_ptr + 1'b1;
        rd_ptr      <= rd_ptr + 1'b1;
      end else if (push) begin
        mem[wr_ptr] <= s_data;
        wr_ptr      <= wr_ptr + 1'b1;
        cnt         <= cnt + 1'b1;
      end else if (pop) begin
        rd_ptr      <= rd_ptr + 1'b1;
        cnt         <= cnt - 1'b1;
      end
    end
  end

endmodule
