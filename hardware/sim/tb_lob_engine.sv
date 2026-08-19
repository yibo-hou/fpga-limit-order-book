`timescale 1ns / 1ps
import lob_pkg::*;
// tb_lob_engine.sv - bare testbench (no UVM) that drives a stimulus file of
// 32-byte messages into lob_engine_top and records trades, reports, acks and
// the final book status.  A Python harness compares the trace against the
// golden reference model.
//
// Usage: iverilog -g2012 ... tb_lob_engine.sv ; vvp
// Reads   stimulus.hex      (one 256-bit hex word per 32-byte message)
// Writes  out_trades.txt    (buy sell price qty ts)
//         out_reports.txt   (256-bit hex EXECUTE reports)
//         out_acks.txt      (status order_id remaining best_bid best_ask num_orders)
//         out_status.txt    (best_bid best_ask num_orders)

module tb_lob_engine;

  localparam int MAX_MSGS  = 16384;
  localparam int MAX_ORDERS= 8192;      // usable slots = MAX_ORDERS-1
  localparam int ADDR_W    = 13;        // must match lob_pkg::ADDR_W
  localparam int NUM_PRICE_LEVELS = 4096;
  localparam int LEVEL_IDX_W      = 12;
  localparam int HASH_BUCKETS     = 16384;
  localparam int BUCKET_ADDR_W    = 14;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;                 // 100 MHz

  // DUT signals
  logic [255:0] s_payload;
  logic        s_payload_valid, s_payload_ready;
  trade_t      m_trade;
  logic        m_trade_valid, m_trade_ready;
  logic [255:0] m_report;
  logic        m_report_valid, m_report_ready;
  ack_t        m_ack;
  logic        m_ack_valid, m_ack_ready;
  logic [31:0] status_best_bid, status_best_ask;
  logic [ADDR_W-1:0] status_num_orders;

  lob_engine_top #(.MAX_ORDERS(MAX_ORDERS), .ADDR_W(ADDR_W),
                   .NUM_PRICE_LEVELS(NUM_PRICE_LEVELS), .LEVEL_IDX_W(LEVEL_IDX_W),
                   .HASH_BUCKETS(HASH_BUCKETS), .BUCKET_ADDR_W(BUCKET_ADDR_W)) dut (
      .clk(clk), .rst_n(rst_n),
      .s_payload(s_payload), .s_payload_valid(s_payload_valid),
      .s_payload_ready(s_payload_ready),
      .m_trade(m_trade), .m_trade_valid(m_trade_valid), .m_trade_ready(m_trade_ready),
      .m_report(m_report), .m_report_valid(m_report_valid), .m_report_ready(m_report_ready),
      .m_ack(m_ack), .m_ack_valid(m_ack_valid), .m_ack_ready(m_ack_ready),
      .status_best_bid(status_best_bid), .status_best_ask(status_best_ask),
      .status_num_orders(status_num_orders)
  );

  // always accept outputs
  assign m_trade_ready  = 1'b1;
  assign m_report_ready = 1'b1;
  assign m_ack_ready    = 1'b1;

  // ---------------- stimulus memory ----------------
  logic [255:0] stim [0:MAX_MSGS-1];
  integer stim_len;
  integer idx;
  integer ack_cnt, trade_cnt, rep_cnt, cycle_cnt;
  integer ft, fa, fr, fst;
  integer i;
  integer done_flag;

  // ---------------- load stimulus ----------------
  initial begin
    $readmemh("stimulus.hex", stim);
    stim_len = 0;
    for (i = 0; i < MAX_MSGS; i = i + 1) begin
      if (^stim[i] === 1'bx) begin
        i = MAX_MSGS;                    // stop scanning (no break in iverilog)
      end else begin
        stim_len = stim_len + 1;
      end
    end
    $display("INFO: loaded %0d stimulus messages", stim_len);
  end

  // ---------------- reset + completion wait ----------------
  initial begin
    ft = $fopen("out_trades.txt", "w");
    fa = $fopen("out_acks.txt", "w");
    fr = $fopen("out_reports.txt", "w");
    fst = $fopen("out_status.txt", "w");
    cycle_cnt = 0;

    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    done_flag = 0;
    while (!done_flag) begin
      @(posedge clk);
      cycle_cnt = cycle_cnt + 1;
      if (idx >= stim_len && ack_cnt >= stim_len) begin
        repeat (50) @(posedge clk);      // let reports drain
        done_flag = 1;
      end
      if (cycle_cnt > 2000000) begin
        $display("WARNING: timeout after %0d cycles (fed=%0d acked=%0d)",
                 cycle_cnt, idx, ack_cnt);
        done_flag = 1;
      end
    end

    $fdisplay(fst, "%0d %0d %0d", status_best_bid, status_best_ask,
              status_num_orders);
    $fclose(ft);
    $fclose(fa);
    $fclose(fr);
    $fclose(fst);

    $display("INFO: done. trades=%0d reports=%0d acks=%0d cycles=%0d",
             trade_cnt, rep_cnt, ack_cnt, cycle_cnt);
    $finish;
  end

  // ---------------- stimulus driver ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_payload       <= '0;
      s_payload_valid <= 1'b0;
      idx             <= 0;
    end else begin
      if (s_payload_valid && s_payload_ready) begin
        idx <= idx + 1;
      end
      if (idx < stim_len) begin
        s_payload       <= stim[idx];
        s_payload_valid <= 1'b1;
      end else begin
        s_payload_valid <= 1'b0;
      end
    end
  end

  // ---------------- trace capture ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      trade_cnt <= 0;
      rep_cnt   <= 0;
      ack_cnt   <= 0;
    end else begin
      if (m_trade_valid && m_trade_ready) begin
        $fdisplay(ft, "%0d %0d %0d %0d %0d",
                  m_trade.buy_order_id, m_trade.sell_order_id, m_trade.price,
                  m_trade.quantity, m_trade.timestamp_ns);
        trade_cnt <= trade_cnt + 1;
      end
      if (m_report_valid && m_report_ready) begin
        $fdisplay(fr, "%064x", m_report);
        rep_cnt <= rep_cnt + 1;
      end
      if (m_ack_valid && m_ack_ready) begin
        $fdisplay(fa, "%0d %0d %0d %0d %0d %0d",
                  m_ack.status, m_ack.order_id, m_ack.remaining_qty,
                  m_ack.best_bid, m_ack.best_ask, m_ack.num_orders);
        ack_cnt <= ack_cnt + 1;
      end
    end
  end

endmodule
