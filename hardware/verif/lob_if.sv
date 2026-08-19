`timescale 1ns / 1ps
import lob_pkg::*;

// ============================================================================
// lob_if.sv: SystemVerilog Virtual Interface for LOB UVM Testbench
// ============================================================================
interface lob_if (input logic clk);
  logic              rst_n;

  // 1. Ingress Order Command Channel (256-bit UDP payload stream)
  logic [255:0]      s_payload;
  logic              s_payload_valid;
  logic              s_payload_ready;

  // 2. Egress Matched Trade Stream
  trade_t            m_trade;
  logic              m_trade_valid;
  logic              m_trade_ready;

  // 3. Egress 32-Byte EXECUTE Report Stream
  logic [255:0]      m_report;
  logic              m_report_valid;
  logic              m_report_ready;

  // 4. Egress 32-Byte Command Ack Stream
  ack_t              m_ack;
  logic              m_ack_valid;
  logic              m_ack_ready;

  // 5. Sideband Live Book Status
  logic [31:0]       status_best_bid;
  logic [31:0]       status_best_ask;
  logic [ADDR_W-1:0] status_num_orders;

  // --------------------------------------------------------------------------
  // Driver Clocking Block (Synchronous stimulus drive with setup/hold skew)
  // --------------------------------------------------------------------------
  clocking drv_cb @(posedge clk);
    default input #1ns output #1ns;
    output s_payload, s_payload_valid;
    input  s_payload_ready;
    output m_trade_ready, m_report_ready, m_ack_ready;
  endclocking

  // --------------------------------------------------------------------------
  // Monitor Clocking Block (Synchronous passive sampling)
  // --------------------------------------------------------------------------
  clocking mon_cb @(posedge clk);
    default input #1ns output #1ns;
    input  s_payload, s_payload_valid, s_payload_ready;
    input  m_trade, m_trade_valid, m_trade_ready;
    input  m_report, m_report_valid, m_report_ready;
    input  m_ack, m_ack_valid, m_ack_ready;
    input  status_best_bid, status_best_ask, status_num_orders;
  endclocking

endinterface
