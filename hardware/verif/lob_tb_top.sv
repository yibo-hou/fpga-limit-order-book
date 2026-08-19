`timescale 1ns / 1ps

import uvm_pkg::*;
`include "uvm_macros.svh"
import lob_pkg::*;
import lob_uvm_pkg::*;
import lob_tests_pkg::*;

// ============================================================================
// lob_tb_top.sv: Top-Level UVM Testbench Module
// ============================================================================
module lob_tb_top;

  // 1. Core Clock Generation (125 MHz: period 8ns = 4ns high, 4ns low)
  logic clk;
  initial clk = 0;
  always #4 clk = ~clk;

  // 2. Instantiate Physical Interface Bundle
  lob_if intf (clk);

  // 3. Reset Generation
  initial begin
    intf.rst_n = 1'b0;
    #40;
    intf.rst_n = 1'b1;
  end

  // 4. Instantiate Device Under Test (DUT)
  lob_engine_top #(
      .ADDR_W          (13),
      .NUM_PRICE_LEVELS(4096),
      .LEVEL_IDX_W     (12),
      .HASH_BUCKETS    (16384)
  ) u_dut (
      .clk              (clk),
      .rst_n            (intf.rst_n),

      // Ingress Command Stream
      .s_payload        (intf.s_payload),
      .s_payload_valid  (intf.s_payload_valid),
      .s_payload_ready  (intf.s_payload_ready),

      // Egress Matched Trade Stream
      .m_trade          (intf.m_trade),
      .m_trade_valid    (intf.m_trade_valid),
      .m_trade_ready    (intf.m_trade_ready),

      // Egress 32-Byte EXECUTE Reports
      .m_report         (intf.m_report),
      .m_report_valid   (intf.m_report_valid),
      .m_report_ready   (intf.m_report_ready),

      // Egress 32-Byte Command Acks
      .m_ack            (intf.m_ack),
      .m_ack_valid      (intf.m_ack_valid),
      .m_ack_ready      (intf.m_ack_ready),

      // Sideband Status Outputs
      .status_best_bid  (intf.status_best_bid),
      .status_best_ask  (intf.status_best_ask),
      .status_num_orders(intf.status_num_orders)
  );

  // 5. Register Interface to UVM Config DB and Start Simulation
  initial begin
    uvm_config_db#(virtual lob_if)::set(null, "*", "vif", intf);
    run_test("lob_smoke_test");
  end

  // 6. Optional Waveform Dump
  initial begin
    $dumpfile("lob_uvm_wave.vcd");
    $dumpvars(0, lob_tb_top);
  end

endmodule
