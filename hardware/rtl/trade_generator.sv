`timescale 1ns / 1ps
import lob_pkg::*;
// trade_generator.sv - buffers matched/external trades, emits them as trade
// records and as 32-byte EXECUTE_ORDER messages (reports), and buffers acks.
//
// Report policy (matches the Python reference and the wire protocol):
//   * matched trade (both counterparties known): two reports (buyer, then
//     seller), flags = 0
//   * external fill (one counterparty id = 0): one report, flags = FLAG_EXTERNAL
// The report seq counter starts at 1 and increments per report.
//
// m_trade is a monitor pass-through of the incoming trade stream (the
// scoreboard always accepts); the report generator has its own buffering.

module trade_generator #(
    parameter int ADDR_W = 13
) (
    input  logic clk,
    input  logic rst_n,

    // trade in (matcher matched fills / manager external fills, muxed by top)
    input  trade_t            s_trade,
    input  logic              s_trade_valid,
    output logic              s_trade_ready,

    // ack in (manager acks / top-composed acks)
    input  ack_t              s_ack,
    input  logic              s_ack_valid,
    output logic              s_ack_ready,

    // trade out (scoreboard monitor)
    output trade_t            m_trade,
    output logic              m_trade_valid,
    input  logic              m_trade_ready,

    // 32-byte EXECUTE report out
    output logic [255:0]      m_report,
    output logic              m_report_valid,
    input  logic              m_report_ready,

    // ack out
    output ack_t              m_ack,
    output logic              m_ack_valid,
    input  logic              m_ack_ready
);

  // ---------------- trade monitor pass-through ----------------
  assign m_trade       = s_trade;

  // ---------------- FIFOs ----------------
  logic rep_push, rep_ready;
  logic [255:0] rep_data;

  logic [255:0] t_fifo_data;
  logic t_fifo_valid;
  logic t_pop;
  logic trade_fifo_ready;

  // the trade FIFO word is exactly a trade_t (256 bits)
  trade_t t_fifo_trade;
  assign t_fifo_trade = trade_t'(t_fifo_data);

  // trade FIFO for the report generator (scoreboard side never pops)
  fifo_queue #(.DATA_W(256), .DEPTH(64)) u_trade_fifo (
      .clk(clk), .rst_n(rst_n),
      .s_data(s_trade), .s_valid(s_trade_valid && m_trade_ready),
      .s_ready(trade_fifo_ready),
      .m_data(t_fifo_data), .m_valid(t_fifo_valid), .m_ready(t_pop),
      .count(), .full(), .empty()
  );

  // A trade is accepted atomically by both consumers: the monitor output and
  // the report-generation FIFO. This preserves valid/ready semantics under
  // backpressure on either branch.
  assign s_trade_ready = trade_fifo_ready && m_trade_ready;
  assign m_trade_valid = s_trade_valid && trade_fifo_ready;

  fifo_queue #(.DATA_W($bits(ack_t)), .DEPTH(64)) u_ack_fifo (
      .clk(clk), .rst_n(rst_n),
      .s_data(s_ack), .s_valid(s_ack_valid), .s_ready(s_ack_ready),
      .m_data(m_ack), .m_valid(m_ack_valid), .m_ready(m_ack_ready),
      .count(), .full(), .empty()
  );

  fifo_queue #(.DATA_W(256), .DEPTH(64)) u_rep_fifo (
      .clk(clk), .rst_n(rst_n),
      .s_data(rep_data), .s_valid(rep_push), .s_ready(rep_ready),
      .m_data(m_report), .m_valid(m_report_valid), .m_ready(m_report_ready),
      .count(), .full(), .empty()
  );

  // ---------------- report generation ----------------
  typedef enum logic [1:0] { R_IDLE, R_BUYER, R_SELLER } rstate_t;

  rstate_t rstate;
  trade_t  t_q;
  logic [31:0] rep_seq;

  assign t_pop = (rstate == R_IDLE) && t_fifo_valid;

  function automatic logic [255:0] make_report(input logic [7:0] side,
                                               input logic [7:0] flags,
                                               input logic [31:0] seq,
                                               input logic [63:0] oid,
                                               input logic [31:0] price,
                                               input logic [31:0] qty,
                                               input logic [63:0] ts);
    logic [255:0] r;
    r[255:248] = VERSION;
    r[247:240] = 8'h04;                      // EXECUTE_ORDER
    r[239:232] = side;
    r[231:224] = flags;
    r[223:192] = seq;
    r[191:128] = oid;
    r[127:96]  = price;
    r[95:64]   = qty;
    r[63:0]    = ts;
    return r;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rstate  <= R_IDLE;
      t_q     <= '0;
      rep_seq <= 32'd1;
      rep_data<= '0;
      rep_push<= 1'b0;
    end else begin
      rep_push <= 1'b0;
      case (rstate)
        R_IDLE: begin
          if (t_pop) begin
            t_q   <= t_fifo_trade;     // latch the trade from the FIFO front
            if (t_fifo_trade.buy_order_id != '0 && t_fifo_trade.sell_order_id != '0) begin
              rstate <= R_BUYER;
            end else begin
              rstate <= R_SELLER;      // single report (external)
            end
          end
        end

        R_BUYER: begin
          rep_data <= make_report(8'h00, 8'h00, rep_seq, t_q.buy_order_id,
                                  t_q.price, t_q.quantity, t_q.timestamp_ns);
          rep_push <= 1'b1;
          if (rep_ready) begin
            rep_seq <= rep_seq + 1'b1;
            rstate  <= R_SELLER;
          end
        end

        R_SELLER: begin
          if (t_q.buy_order_id != '0 && t_q.sell_order_id != '0) begin
            rep_data <= make_report(8'h01, 8'h00, rep_seq, t_q.sell_order_id,
                                    t_q.price, t_q.quantity, t_q.timestamp_ns);
          end else begin
            rep_data <= make_report((t_q.buy_order_id != '0) ? 8'h00 : 8'h01,
                                    FLAG_EXTERNAL, rep_seq,
                                    (t_q.buy_order_id != '0) ? t_q.buy_order_id
                                                             : t_q.sell_order_id,
                                    t_q.price, t_q.quantity, t_q.timestamp_ns);
          end
          rep_push <= 1'b1;
          if (rep_ready) begin
            rep_seq <= rep_seq + 1'b1;
            rstate  <= R_IDLE;
          end
        end
      endcase
    end
  end

endmodule
