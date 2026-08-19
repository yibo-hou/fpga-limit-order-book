`timescale 1ns / 1ps
import lob_pkg::*;

module lob_davinci_pro_top #(
    parameter logic [47:0] LOCAL_MAC = 48'h00_0a_35_01_02_03,
    parameter logic [31:0] LOCAL_IP  = 32'hc0a8_010a,
    parameter logic [31:0] HOST_IP   = 32'hc0a8_0164,
    parameter logic [15:0] LOB_PORT  = 16'd5001,
    parameter logic [15:0] HOST_PORT = 16'd5000
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    output logic [3:0] led,

    output logic       eth_rst_n,
    input  wire        eth_rxc_0,
    input  wire [3:0]  eth_rxd_0,
    input  wire        eth_rx_ctl_0,
    output wire        eth_txc_0,
    output wire [3:0]  eth_txd_0,
    output wire        eth_tx_ctl_0,
    output logic       eth_mdc,
    inout  wire        eth_mdio
);
  wire clk_50m;
  wire clk_125m;
  wire clk_200m;
  logic mmcm_locked;
  logic rst_50_n;
  logic rst_125_n;
  logic rst_200_n;
  logic rx_rst_n;

  lob_clock_gen u_clkgen (
      .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
      .clk_50m(clk_50m), .clk_125m(clk_125m), .clk_200m(clk_200m),
      .locked(mmcm_locked)
  );

  reset_sync u_rst50 (
      .clk(clk_50m), .async_rst_n(sys_rst_n),
      .release_enable_async(mmcm_locked), .rst_n(rst_50_n));
  reset_sync u_rst125 (
      .clk(clk_125m), .async_rst_n(sys_rst_n),
      .release_enable_async(mmcm_locked), .rst_n(rst_125_n));
  reset_sync u_rst200 (
      .clk(clk_200m), .async_rst_n(sys_rst_n),
      .release_enable_async(mmcm_locked), .rst_n(rst_200_n));

  // ------------------------------------------------------------------ PHY
  logic phy_ready;
  logic mdio_start, mdio_read, mdio_busy, mdio_done;
  logic [4:0] mdio_phy_addr, mdio_reg_addr;
  logic [15:0] mdio_wr_data, mdio_rd_data;
  logic mdio_i, mdio_o, mdio_oe;
  (* ASYNC_REG = "TRUE" *) logic [1:0] mdio_i_sync;
  logic phy_found, phy_link_up, phy_full_duplex, phy_tx_enable;
  (* ASYNC_REG = "TRUE" *) logic [1:0] phy_found_125_ff;
  (* ASYNC_REG = "TRUE" *) logic [1:0] phy_link_125_ff;
  (* ASYNC_REG = "TRUE" *) logic [1:0] phy_tx_enable_125_ff;
  logic [4:0] detected_phy_addr;
  logic [31:0] phy_id;
  logic [15:0] phy_status;
  logic [1:0] phy_speed_code;

  phy_reset_ctrl #(.CLK_HZ(50_000_000), .RESET_HOLD_MS(10)) u_phy_reset (
      .clk(clk_50m), .rst_n(rst_50_n),
      .phy_rst_n(eth_rst_n), .phy_ready(phy_ready));

  IOBUF u_mdio_iobuf (
      .I(mdio_o), .T(!mdio_oe), .O(mdio_i), .IO(eth_mdio));

  always_ff @(posedge clk_50m or negedge rst_50_n) begin
    if (!rst_50_n) mdio_i_sync <= 2'b11;
    else           mdio_i_sync <= {mdio_i_sync[0], mdio_i};
  end

  mdio_master #(.MDC_DIV(10)) u_mdio (
      .clk(clk_50m), .rst_n(rst_50_n),
      .start(mdio_start), .op_read(mdio_read),
      .phy_addr(mdio_phy_addr), .reg_addr(mdio_reg_addr),
      .wr_data(mdio_wr_data), .rd_data(mdio_rd_data),
      .busy(mdio_busy), .done(mdio_done), .mdc(eth_mdc),
      .mdio_i(mdio_i_sync[1]), .mdio_o(mdio_o), .mdio_oe(mdio_oe));

  yt8511_ctrl #(
      .CLK_HZ(50_000_000), .PREFERRED_PHY_ADDR(5'd1),
      .STARTUP_WAIT_MS(20), .POLL_INTERVAL_MS(100),
      .ENABLE_RX_DELAY(1'b0)
  ) u_phy_ctrl (
      .clk(clk_50m), .rst_n(rst_50_n), .phy_ready(phy_ready),
      .mdio_start(mdio_start), .mdio_read(mdio_read),
      .mdio_phy_addr(mdio_phy_addr), .mdio_reg_addr(mdio_reg_addr),
      .mdio_wr_data(mdio_wr_data), .mdio_rd_data(mdio_rd_data),
      .mdio_busy(mdio_busy), .mdio_done(mdio_done),
      .phy_found(phy_found), .detected_phy_addr(detected_phy_addr),
      .phy_id(phy_id), .phy_status(phy_status), .link_up(phy_link_up),
      .full_duplex(phy_full_duplex), .speed_code(phy_speed_code),
      .tx_enable(phy_tx_enable));

  always_ff @(posedge clk_125m or negedge rst_125_n) begin
    if (!rst_125_n) begin
      phy_found_125_ff     <= '0;
      phy_link_125_ff      <= '0;
      phy_tx_enable_125_ff <= '0;
    end else begin
      phy_found_125_ff     <= {phy_found_125_ff[0], phy_found};
      phy_link_125_ff      <= {phy_link_125_ff[0], phy_link_up};
      phy_tx_enable_125_ff <= {phy_tx_enable_125_ff[0], phy_tx_enable};
    end
  end

  // -------------------------------------------------------------- RGMII RX
  wire rx_clk;
  wire idelay_ready;
  logic [7:0] rx_data;
  logic rx_valid, rx_error;

  reset_sync u_rx_reset (
      .clk(rx_clk), .async_rst_n(sys_rst_n),
      .release_enable_async(mmcm_locked && idelay_ready), .rst_n(rx_rst_n));

  rgmii_rx u_rgmii_rx (
      .rgmii_rxc(eth_rxc_0), .ref_clk_200m(clk_200m),
      .idelay_rst_n(rst_200_n), .rst_n(rx_rst_n),
      .rgmii_rxd(eth_rxd_0), .rgmii_rx_ctl(eth_rx_ctl_0),
      .rx_clk(rx_clk), .idelay_ready(idelay_ready),
      .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error));

  logic [7:0] udp_rx_data;
  logic udp_rx_valid, udp_rx_start, udp_rx_last;
  logic [15:0] udp_rx_length;
  logic [31:0] udp_source_ip;
  logic [15:0] udp_source_port;
  logic arp_request, arp_reply;
  logic [47:0] arp_sender_mac;
  logic [31:0] arp_sender_ip;
  logic frame_seen, frame_drop, udp_packet_seen;

  eth_ipv4_udp_rx #(
      .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP), .UDP_PORT(LOB_PORT)
  ) u_eth_rx (
      .clk(rx_clk), .rst_n(rx_rst_n),
      .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error),
      .payload_data(udp_rx_data), .payload_valid(udp_rx_valid),
      .payload_start(udp_rx_start), .payload_last(udp_rx_last),
      .payload_length(udp_rx_length), .udp_source_ip(udp_source_ip),
      .udp_source_port(udp_source_port), .arp_request(arp_request),
      .arp_reply(arp_reply), .arp_sender_mac(arp_sender_mac),
      .arp_sender_ip(arp_sender_ip), .frame_seen(frame_seen),
      .frame_drop(frame_drop), .udp_packet_seen(udp_packet_seen));

  // ----------------------------------------------------------- RX -> core
  logic [303:0] rx_message;
  logic rx_message_valid, rx_message_ready, rx_packet_drop;
  logic [303:0] core_message;
  logic core_message_valid;
  logic lob_payload_ready;

  udp_order_ingress u_ingress (
      .clk(rx_clk), .rst_n(rx_rst_n),
      .payload_data(udp_rx_data), .payload_valid(udp_rx_valid),
      .payload_start(udp_rx_start), .payload_last(udp_rx_last),
      .payload_length(udp_rx_length), .source_ip(udp_source_ip),
      .source_port(udp_source_port), .message_data(rx_message),
      .message_valid(rx_message_valid), .message_ready(rx_message_ready),
      .packet_drop(rx_packet_drop));

  cdc_mailbox #(.WIDTH(304)) u_order_mailbox (
      .s_clk(rx_clk), .s_rst_n(rx_rst_n),
      .s_data(rx_message), .s_valid(rx_message_valid), .s_ready(rx_message_ready),
      .d_clk(clk_125m), .d_rst_n(rst_125_n),
      .d_data(core_message), .d_valid(core_message_valid),
      .d_ready(lob_payload_ready));

  // --------------------------------------------------------------- LOB core
  trade_t lob_trade;
  logic lob_trade_valid;
  logic [255:0] lob_report;
  logic lob_report_valid, lob_report_ready;
  ack_t lob_ack;
  logic lob_ack_valid, lob_ack_ready;
  logic [31:0] status_best_bid, status_best_ask;
  logic [ADDR_W-1:0] status_num_orders;

  lob_engine_top u_lob (
      .clk(clk_125m), .rst_n(rst_125_n),
      .s_payload(core_message[255:0]),
      .s_payload_valid(core_message_valid),
      .s_payload_ready(lob_payload_ready),
      .m_trade(lob_trade), .m_trade_valid(lob_trade_valid),
      .m_trade_ready(1'b1),
      .m_report(lob_report), .m_report_valid(lob_report_valid),
      .m_report_ready(lob_report_ready),
      .m_ack(lob_ack), .m_ack_valid(lob_ack_valid),
      .m_ack_ready(lob_ack_ready),
      .status_best_bid(status_best_bid), .status_best_ask(status_best_ask),
      .status_num_orders(status_num_orders));

  // --------------------------------------------------------- ARP CDC/cache
  logic [80:0] arp_event_rx, arp_event_tx;
  logic arp_event_valid_rx, arp_event_ready_rx;
  logic arp_event_valid_tx, arp_event_ready_tx;
  logic [47:0] host_mac_q;

  assign arp_event_rx       = {arp_request, arp_sender_mac, arp_sender_ip};
  assign arp_event_valid_rx = arp_request || arp_reply;

  cdc_mailbox #(.WIDTH(81)) u_arp_mailbox (
      .s_clk(rx_clk), .s_rst_n(rx_rst_n),
      .s_data(arp_event_rx), .s_valid(arp_event_valid_rx),
      .s_ready(arp_event_ready_rx),
      .d_clk(clk_125m), .d_rst_n(rst_125_n),
      .d_data(arp_event_tx), .d_valid(arp_event_valid_tx),
      .d_ready(arp_event_ready_tx));

  // -------------------------------------------------------------- UDP/ARP TX
  logic udp_start_valid, udp_start_ready_raw, udp_start_ready;
  logic [15:0] udp_payload_length;
  logic [7:0] udp_payload_data;
  logic udp_payload_valid, udp_payload_ready, udp_payload_last;
  logic udp_tx_busy, udp_tx_error;
  logic [7:0] udp_tx_data;
  logic udp_tx_valid;
  logic arp_tx_ready, arp_tx_busy;
  logic [7:0] arp_tx_data;
  logic arp_tx_valid;

  lob_udp_egress u_egress (
      .clk(clk_125m), .rst_n(rst_125_n),
      .report_data(lob_report), .report_valid(lob_report_valid),
      .report_ready(lob_report_ready), .ack_data(lob_ack),
      .ack_valid(lob_ack_valid), .ack_ready(lob_ack_ready),
      .packet_start_valid(udp_start_valid),
      .packet_start_ready(udp_start_ready),
      .payload_length(udp_payload_length), .payload_data(udp_payload_data),
      .payload_valid(udp_payload_valid), .payload_ready(udp_payload_ready),
      .payload_last(udp_payload_last));

  assign udp_start_ready = udp_start_ready_raw && !arp_tx_busy &&
                           !arp_event_valid_tx && phy_tx_enable_125_ff[1];

  udp_ipv4_eth_tx #(
      .SRC_MAC(LOCAL_MAC), .SRC_IP(LOCAL_IP), .DST_IP(HOST_IP),
      .SRC_PORT(LOB_PORT), .DST_PORT(HOST_PORT)
  ) u_udp_tx (
      .clk(clk_125m), .rst_n(rst_125_n), .dst_mac(host_mac_q),
      .packet_start_valid(udp_start_valid && !arp_tx_busy &&
                          !arp_event_valid_tx && phy_tx_enable_125_ff[1]),
      .packet_start_ready(udp_start_ready_raw),
      .payload_length(udp_payload_length), .busy(udp_tx_busy),
      .payload_data(udp_payload_data), .payload_valid(udp_payload_valid),
      .payload_ready(udp_payload_ready), .payload_last(udp_payload_last),
      .payload_error(udp_tx_error), .tx_data(udp_tx_data),
      .tx_valid(udp_tx_valid), .packet_start(), .packet_end());

  assign arp_event_ready_tx = !arp_event_tx[80] ||
                              (arp_tx_ready && !udp_tx_busy &&
                               phy_tx_enable_125_ff[1]);

  arp_reply_tx #(.LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP)) u_arp_reply (
      .clk(clk_125m), .rst_n(rst_125_n),
      .request_valid(arp_event_valid_tx && arp_event_tx[80] && !udp_tx_busy &&
                     phy_tx_enable_125_ff[1]),
      .request_ready(arp_tx_ready), .requester_mac(arp_event_tx[79:32]),
      .requester_ip(arp_event_tx[31:0]), .busy(arp_tx_busy),
      .tx_data(arp_tx_data), .tx_valid(arp_tx_valid),
      .packet_start(), .packet_end());

  always_ff @(posedge clk_125m or negedge rst_125_n) begin
    if (!rst_125_n)
      host_mac_q <= 48'hff_ff_ff_ff_ff_ff;
    else if (arp_event_valid_tx)
      host_mac_q <= arp_event_tx[79:32];
  end

  logic [7:0] mac_tx_data;
  logic mac_tx_valid;
  assign mac_tx_data  = arp_tx_busy ? arp_tx_data  : udp_tx_data;
  assign mac_tx_valid = arp_tx_busy ? arp_tx_valid : udp_tx_valid;

  rgmii_tx u_rgmii_tx (
      .clk_125m(clk_125m), .rst_n(rst_125_n),
      .tx_data(mac_tx_data), .tx_valid(mac_tx_valid),
      .rgmii_txc(eth_txc_0), .rgmii_txd(eth_txd_0),
      .rgmii_tx_ctl(eth_tx_ctl_0));

  // -------------------------------------------------------------- indicators
  logic rx_activity;
  logic drop_seen;
  logic [15:0] dbg_rx_frame_count;
  logic [15:0] dbg_rx_udp_count;
  logic [15:0] dbg_rx_message_count;
  logic [15:0] dbg_rx_frame_drop_count;
  logic [15:0] dbg_rx_packet_drop_count;
  logic [15:0] dbg_rx_error_count;
  (* mark_debug = "true" *) logic [95:0] rx_debug_bus;

  always_ff @(posedge rx_clk or negedge rx_rst_n) begin
    if (!rx_rst_n) begin
      rx_activity <= 1'b0;
      drop_seen   <= 1'b0;
      dbg_rx_frame_count       <= '0;
      dbg_rx_udp_count         <= '0;
      dbg_rx_message_count     <= '0;
      dbg_rx_frame_drop_count  <= '0;
      dbg_rx_packet_drop_count <= '0;
      dbg_rx_error_count       <= '0;
    end else begin
      if (udp_packet_seen) rx_activity <= ~rx_activity;
      if (rx_packet_drop || frame_drop) drop_seen <= 1'b1;
      if (frame_seen)                       dbg_rx_frame_count <= dbg_rx_frame_count + 1'b1;
      if (udp_packet_seen)                  dbg_rx_udp_count <= dbg_rx_udp_count + 1'b1;
      if (rx_message_valid && rx_message_ready)
                                             dbg_rx_message_count <= dbg_rx_message_count + 1'b1;
      if (frame_drop)                       dbg_rx_frame_drop_count <= dbg_rx_frame_drop_count + 1'b1;
      if (rx_packet_drop)                   dbg_rx_packet_drop_count <= dbg_rx_packet_drop_count + 1'b1;
      if (rx_valid && rx_error)             dbg_rx_error_count <= dbg_rx_error_count + 1'b1;
    end
  end

  assign rx_debug_bus = {
      dbg_rx_error_count, dbg_rx_packet_drop_count,
      dbg_rx_frame_drop_count, dbg_rx_message_count,
      dbg_rx_udp_count, dbg_rx_frame_count
  };

  // Board-verification instrumentation.  The latency is measured in 125 MHz
  // core clocks from payload acceptance to the first trade-valid cycle.
  logic [31:0] dbg_core_cycle;
  logic [31:0] dbg_cmd_accept_cycle;
  logic [15:0] dbg_core_cmd_count;
  logic [15:0] dbg_core_trade_count;
  logic [15:0] dbg_core_ack_count;
  logic [15:0] dbg_tx_packet_count;
  logic [15:0] dbg_tx_error_count;
  logic [15:0] dbg_first_trade_latency;
  logic dbg_command_active, dbg_first_trade_seen;
  (* mark_debug = "true" *) logic [127:0] core_debug_bus;

  always_ff @(posedge clk_125m or negedge rst_125_n) begin
    if (!rst_125_n) begin
      dbg_core_cycle         <= '0;
      dbg_cmd_accept_cycle   <= '0;
      dbg_core_cmd_count     <= '0;
      dbg_core_trade_count   <= '0;
      dbg_core_ack_count     <= '0;
      dbg_tx_packet_count    <= '0;
      dbg_tx_error_count     <= '0;
      dbg_first_trade_latency<= '0;
      dbg_command_active     <= 1'b0;
      dbg_first_trade_seen   <= 1'b0;
    end else begin
      dbg_core_cycle <= dbg_core_cycle + 1'b1;
      if (core_message_valid && lob_payload_ready) begin
        dbg_cmd_accept_cycle <= dbg_core_cycle;
        dbg_core_cmd_count   <= dbg_core_cmd_count + 1'b1;
        dbg_command_active   <= 1'b1;
        dbg_first_trade_seen <= 1'b0;
      end
      if (lob_trade_valid) begin
        dbg_core_trade_count <= dbg_core_trade_count + 1'b1;
        if (dbg_command_active && !dbg_first_trade_seen) begin
          dbg_first_trade_latency <= dbg_core_cycle - dbg_cmd_accept_cycle;
          dbg_first_trade_seen <= 1'b1;
        end
      end
      if (lob_ack_valid && lob_ack_ready) begin
        dbg_core_ack_count <= dbg_core_ack_count + 1'b1;
        dbg_command_active <= 1'b0;
      end
      if (udp_start_valid && udp_start_ready)
        dbg_tx_packet_count <= dbg_tx_packet_count + 1'b1;
      if (udp_tx_error)
        dbg_tx_error_count <= dbg_tx_error_count + 1'b1;
    end
  end

  assign core_debug_bus = {
      dbg_first_trade_latency,
      dbg_tx_error_count,
      dbg_tx_packet_count,
      dbg_core_ack_count,
      dbg_core_trade_count,
      dbg_core_cmd_count,
      dbg_command_active,
      dbg_first_trade_seen,
      core_message_valid,
      lob_payload_ready,
      lob_trade_valid,
      lob_ack_valid,
      udp_start_valid,
      udp_start_ready,
      24'b0
  };

  always_comb begin
    led[0] = phy_found_125_ff[1];
    led[1] = phy_link_125_ff[1];
    led[2] = rx_activity;
    led[3] = drop_seen || udp_tx_error;
  end

endmodule
