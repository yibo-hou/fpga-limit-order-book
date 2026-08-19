`timescale 1ns / 1ps
import lob_pkg::*;

module tb_lob_engine_smoke;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [255:0] s_payload;
  logic s_payload_valid, s_payload_ready;
  trade_t m_trade;
  logic m_trade_valid;
  logic [255:0] m_report;
  logic m_report_valid;
  ack_t m_ack;
  logic m_ack_valid;
  logic [31:0] status_best_bid, status_best_ask;
  logic [ADDR_W-1:0] status_num_orders;

  lob_engine_top dut (
      .clk(clk), .rst_n(rst_n),
      .s_payload(s_payload), .s_payload_valid(s_payload_valid),
      .s_payload_ready(s_payload_ready),
      .m_trade(m_trade), .m_trade_valid(m_trade_valid), .m_trade_ready(1'b1),
      .m_report(m_report), .m_report_valid(m_report_valid), .m_report_ready(1'b1),
      .m_ack(m_ack), .m_ack_valid(m_ack_valid), .m_ack_ready(1'b1),
      .status_best_bid(status_best_bid), .status_best_ask(status_best_ask),
      .status_num_orders(status_num_orders)
  );

  function automatic logic [255:0] add_msg(
      input logic side, input logic [31:0] seq_num,
      input logic [63:0] order_id, input logic [31:0] price,
      input logic [31:0] quantity, input logic [63:0] timestamp_ns);
    logic [255:0] payload;
    payload[255:248] = 8'h01;
    payload[247:240] = 8'h01;
    payload[239:232] = {7'b0, side};
    payload[231:224] = 8'h00;
    payload[223:192] = seq_num;
    payload[191:128] = order_id;
    payload[127:96]  = price;
    payload[95:64]   = quantity;
    payload[63:0]    = timestamp_ns;
    return payload;
  endfunction

  task automatic send(input logic [255:0] payload);
    s_payload       <= payload;
    s_payload_valid <= 1'b1;
    do @(posedge clk); while (!s_payload_ready);
    s_payload_valid <= 1'b0;
  endtask

  integer ack_count = 0;
  integer trade_count = 0;
  always @(posedge clk) begin
    if (m_ack_valid) ack_count <= ack_count + 1;
    if (m_trade_valid) begin
      trade_count <= trade_count + 1;
      if ($isunknown(m_trade))
        $fatal(1, "trade contains X: %h", m_trade);
      if (m_trade.buy_order_id != 64'd1 ||
          m_trade.sell_order_id != 64'd2 ||
          m_trade.price != 32'd1000 || m_trade.quantity != 32'd20)
        $fatal(1, "unexpected trade: %h", m_trade);
    end
  end

  initial begin
    s_payload = '0;
    s_payload_valid = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    // The order-pool free-list initializes one entry per cycle.
    repeat (1030) @(posedge clk);
    send(add_msg(BUY, 32'd1, 64'd1, 32'd1000, 32'd50, 64'd1));
    wait (ack_count == 1);
    send(add_msg(SELL, 32'd2, 64'd2, 32'd1000, 32'd20, 64'd2));

    fork
      begin
        wait (ack_count == 2);
        repeat (10) @(posedge clk);
        if (trade_count != 1) $fatal(1, "expected one trade, got %0d", trade_count);
        if (status_best_bid != 32'd1000 || status_best_ask != 32'd0 ||
            status_num_orders != ADDR_W'(1))
          $fatal(1, "unexpected status bid=%0d ask=%0d orders=%0d",
                 status_best_bid, status_best_ask, status_num_orders);
        // The top price level (4095) is valid and must not collide with an
        // out-of-range sentinel.
        send(add_msg(SELL, 32'd3, 64'd3, 32'd4095, 32'd7, 64'd3));
        wait (ack_count == 3);
        if (status_best_ask != 32'd4095 || status_num_orders != ADDR_W'(2))
          $fatal(1, "4095 boundary rejected or mis-indexed");
        $display("PASS: crossing and price-boundary smoke test");
        $finish;
      end
      begin
        repeat (20000) @(posedge clk);
        $fatal(1, "timeout: acks=%0d trades=%0d", ack_count, trade_count);
      end
    join_any
  end
endmodule
