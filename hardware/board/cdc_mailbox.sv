`timescale 1ns / 1ps

// Single-entry multi-cycle-path mailbox. The source holds data stable from
// request toggle until the destination acknowledges it.
module cdc_mailbox #(
    parameter int WIDTH = 256
) (
    input  logic             s_clk,
    input  logic             s_rst_n,
    input  logic [WIDTH-1:0] s_data,
    input  logic             s_valid,
    output logic             s_ready,

    input  logic             d_clk,
    input  logic             d_rst_n,
    output logic [WIDTH-1:0] d_data,
    output logic             d_valid,
    input  logic             d_ready
);

  logic [WIDTH-1:0] data_hold;
  logic req_toggle;
  logic ack_toggle;
  (* ASYNC_REG = "TRUE" *) logic [1:0] req_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync;

  assign s_ready = (ack_sync[1] == req_toggle);

  always_ff @(posedge s_clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      data_hold  <= '0;
      req_toggle <= 1'b0;
      ack_sync   <= '0;
    end else begin
      ack_sync <= {ack_sync[0], ack_toggle};
      if (s_valid && s_ready) begin
        data_hold  <= s_data;
        req_toggle <= ~req_toggle;
      end
    end
  end

  always_ff @(posedge d_clk or negedge d_rst_n) begin
    if (!d_rst_n) begin
      req_sync   <= '0;
      ack_toggle <= 1'b0;
      d_data     <= '0;
      d_valid    <= 1'b0;
    end else begin
      req_sync <= {req_sync[0], req_toggle};
      d_valid  <= 1'b0;
      if ((req_sync[1] != ack_toggle) && d_ready) begin
        d_data     <= data_hold;
        d_valid    <= 1'b1;
        ack_toggle <= req_sync[1];
      end
    end
  end

endmodule
