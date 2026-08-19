`timescale 1ns / 1ps
import lob_pkg::*;
// lob_engine_top.sv - top level of the LOB engine.
//
// 32-byte payload in -> message_decoder -> command FIFO -> controller ->
// order_manager (book mutations) / matcher (crossed-book drain) -> trades,
// 32-byte EXECUTE reports and acks out.
//
// Serialized execution: one command is driven to completion (including any
// drain) before the next is released from the command FIFO.

module lob_engine_top #(
    parameter int MAX_ORDERS       = 8192,
    parameter int ADDR_W           = 13,
    parameter int NUM_PRICE_LEVELS = 4096,
    parameter int LEVEL_IDX_W      = 12,
    parameter int HASH_BUCKETS     = 16384,
    parameter int BUCKET_ADDR_W    = 14,
    // Disable when ADD order IDs are not guaranteed unique by the ingress;
    // the normal enqueue path performs the authoritative hash duplicate check.
    parameter bit FAST_PATH_ENABLE = 1'b1
) (
    input  logic clk,
    input  logic rst_n,

    // 32-byte payload in (byte 0 = MSB)
    input  logic [255:0] s_payload,
    input  logic        s_payload_valid,
    output logic        s_payload_ready,

    // trade record out
    output trade_t      m_trade,
    output logic        m_trade_valid,
    input  logic        m_trade_ready,

    // 32-byte EXECUTE report out
    output logic [255:0] m_report,
    output logic        m_report_valid,
    input  logic        m_report_ready,

    // ack out
    output ack_t        m_ack,
    output logic        m_ack_valid,
    input  logic        m_ack_ready,

    // status
    output logic [31:0] status_best_bid,
    output logic [31:0] status_best_ask,
    output logic [ADDR_W-1:0] status_num_orders
);

  // ======================================================================
  //  declarations (before any instance)
  // ======================================================================

  // decoder / cmd fifo
  msg_t  dec_msg;
  logic  dec_msg_valid, dec_msg_ready, dec_bad_version;
  cmd_t  cmd_wire;
  logic  cmd_fifo_valid, cmd_fifo_ready;
  cmd_t  cmd_fifo_data;

  // book state
  logic [LEVEL_IDX_W-1:0] best_bid, best_ask;
  logic best_bid_valid, best_ask_valid, refresh_busy, bpe_init_done;
  logic [ADDR_W-1:0] num_orders;

  // controller
  typedef enum logic [3:0] {
    C_IDLE, C_VALIDATE, C_FAST, C_ENQ, C_MGR, C_MODIFY, C_DRAIN, C_QUERY,
    C_SETTLE, C_ACK
  } cstate_t;
  cstate_t state, state_d;
  cmd_t  cmd_q;
  ack_t  ack_q;
  logic  ack_from_mgr;
  logic  enq_start, mgr_start, mat_start, query_start;
  logic  fast_cross;

  // controller -> submodule start pulses / status
  logic mgr_enq_valid, mgr_s_cmd_valid, mgr_query_valid, mgr_m_ack_ready;
  logic mat_s_cmd_valid;
  logic tg_ack_valid, u_tgen_s_ack_ready;

  // matcher signals
  logic u_mat_m_trade_valid, u_mat_m_trade_ready, u_mat_m_match_done, u_mat_busy;
  logic [31:0] u_mat_remainder_qty;
  trade_t u_mat_m_trade;
  logic [ADDR_W-1:0] mat_pool_addr, mat_pool_b_addr, mat_free_push_slot;
  logic mat_pool_we, mat_pool_re, mat_pool_b_re, mat_free_push;
  order_rec_t mat_pool_wdata;
  logic [LEVEL_IDX_W-1:0] mat_bid_lvl_addr, mat_ask_lvl_addr;
  logic mat_bid_lvl_we, mat_bid_lvl_re, mat_ask_lvl_we, mat_ask_lvl_re;
  level_rec_t mat_bid_lvl_wdata, mat_ask_lvl_wdata;
  logic mat_bpe_clear_valid;
  side_t mat_bpe_clear_side;
  logic [LEVEL_IDX_W-1:0] mat_bpe_clear_idx;
  logic [63:0] mat_hash_id;
  logic mat_hash_valid, mat_hash_busy, mat_hash_done;

  // manager signals
  logic u_mgr_m_trade_valid, u_mgr_m_trade_ready, u_mgr_m_ack_valid, u_mgr_busy;
  logic u_mgr_enq_done, u_mgr_moved_valid, u_mgr_query_done, u_mgr_query_live;
  ack_status_t u_mgr_enq_status;
  ack_t u_mgr_m_ack;
  trade_t u_mgr_m_trade;
  logic [31:0] u_mgr_query_qty;
  logic [ADDR_W-1:0] mgr_pool_addr, mgr_free_push_slot, mgr_hash_slot;
  logic mgr_pool_we, mgr_pool_re, mgr_free_alloc, mgr_free_push;
  order_rec_t mgr_pool_wdata;
  logic [LEVEL_IDX_W-1:0] mgr_bid_lvl_addr, mgr_ask_lvl_addr, mgr_bpe_set_idx, mgr_bpe_clear_idx;
  logic mgr_bid_lvl_we, mgr_bid_lvl_re, mgr_ask_lvl_we, mgr_ask_lvl_re;
  level_rec_t mgr_bid_lvl_wdata, mgr_ask_lvl_wdata;
  logic mgr_bpe_set_valid, mgr_bpe_clear_valid;
  side_t mgr_bpe_set_side, mgr_bpe_clear_side;
  logic [1:0] mgr_hash_op;
  logic [63:0] mgr_hash_id;
  logic mgr_hash_valid, mgr_hash_busy, mgr_hash_done, mgr_hash_hit, mgr_hash_miss;
  logic [ADDR_W-1:0] mgr_hash_hit_slot;

  // order memory
  order_rec_t pool_rdata_a, pool_rdata_b;
  logic [ADDR_W-1:0] free_slot_b;
  logic free_empty_b, pool_init_done;

  // price level busses
  logic [LEVEL_IDX_W-1:0] bid_lvl_addr, ask_lvl_addr;
  logic bid_lvl_we, bid_lvl_re, ask_lvl_we, ask_lvl_re;
  level_rec_t bid_lvl_wdata, ask_lvl_wdata, bid_lvl_rdata, ask_lvl_rdata;

  // best price encoder busses
  logic bpe_set_valid, bpe_clear_valid;
  side_t bpe_set_side, bpe_clear_side;
  logic [LEVEL_IDX_W-1:0] bpe_set_idx, bpe_clear_idx;

  // trade generator mux
  logic tg_s_trade_valid, tg_s_trade_ready;
  trade_t tg_s_trade;

  // ======================================================================
  //  start pulses
  // ======================================================================
  assign enq_start   = (state == C_ENQ   && state_d != C_ENQ);
  assign mgr_start   = ((state == C_MGR || state == C_MODIFY) &&
                        state_d != C_MGR && state_d != C_MODIFY);
  assign mat_start   = ((state == C_DRAIN || state == C_FAST) &&
                        state_d != C_DRAIN && state_d != C_FAST);
  assign query_start = (state == C_QUERY && state_d != C_QUERY);

  assign mgr_enq_valid   = enq_start;
  assign mgr_s_cmd_valid = mgr_start;
  assign mgr_query_valid = query_start;
  assign mat_s_cmd_valid = mat_start;

  assign tg_ack_valid = (state == C_ACK);
  assign mgr_m_ack_ready = ack_from_mgr ? u_tgen_s_ack_ready : 1'b0;

  // A crossing ADD can be consumed directly against the passive book.  Keep
  // one free slot as an admission condition so a remainder can always fall
  // back to the normal enqueue path without changing the existing FULL
  // rejection semantics.
  assign fast_cross = FAST_PATH_ENABLE && (cmd_q.msg_type == ADD) &&
                      !refresh_busy &&
                      !free_empty_b &&
                      ((cmd_q.side == BUY && best_ask_valid &&
                        cmd_q.level_idx >= best_ask) ||
                       (cmd_q.side == SELL && best_bid_valid &&
                        cmd_q.level_idx <= best_bid));

  // ======================================================================
  //  decoder / command fifo
  // ======================================================================
  message_decoder u_dec (
      .clk(clk), .rst_n(rst_n),
      .s_payload(s_payload), .s_payload_valid(s_payload_valid),
      .s_payload_ready(s_payload_ready),
      .m_msg(dec_msg), .m_msg_valid(dec_msg_valid), .m_msg_ready(dec_msg_ready),
      .m_bad_version(dec_bad_version)
  );

  always_comb begin
    cmd_wire.msg_type     = dec_msg.msg_type;
    cmd_wire.side         = dec_msg.side;
    cmd_wire.seq_num      = dec_msg.seq_num;
    cmd_wire.order_id     = dec_msg.order_id;
    cmd_wire.price        = dec_msg.price;
    cmd_wire.quantity     = dec_msg.quantity;
    cmd_wire.timestamp_ns = dec_msg.timestamp_ns;
    cmd_wire.level_idx    = lob_pkg::price_to_level_idx(dec_msg.price);
  end

  fifo_queue #(.DATA_W($bits(cmd_t)), .DEPTH(8)) u_cmd_fifo (
      .clk(clk), .rst_n(rst_n),
      .s_data(cmd_wire), .s_valid(dec_msg_valid), .s_ready(dec_msg_ready),
      .m_data(cmd_fifo_data), .m_valid(cmd_fifo_valid), .m_ready(cmd_fifo_ready),
      .count(), .full(), .empty()
  );

  assign cmd_fifo_ready = (state == C_IDLE) && cmd_fifo_valid;

  // ======================================================================
  //  controller FSM
  // ======================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= C_IDLE;
      state_d      <= C_IDLE;
      cmd_q        <= '0;
      ack_q        <= '0;
      ack_from_mgr <= 1'b0;
    end else begin
      state_d <= state;
      case (state)
        C_IDLE: begin
          if (cmd_fifo_valid) begin
            cmd_q <= cmd_fifo_data;
            state <= C_VALIDATE;
          end
        end

        C_VALIDATE: begin
          if (!pool_init_done || !bpe_init_done) begin
            state <= C_VALIDATE;
          end else if (!(cmd_q.msg_type == ADD || cmd_q.msg_type == CANCEL ||
                cmd_q.msg_type == MODIFY || cmd_q.msg_type == EXECUTE) ||
              !(cmd_q.side == BUY || cmd_q.side == SELL) ||
              ((cmd_q.msg_type == ADD || cmd_q.msg_type == MODIFY) &&
               (cmd_q.quantity == '0 ||
                !lob_pkg::price_in_range(cmd_q.price)))) begin
            ack_q.status        <= ACK_REJECT_BAD_FIELD;
            ack_q.order_id      <= cmd_q.order_id;
            ack_q.remaining_qty <= '0;
            ack_q.best_bid      <= best_bid_valid ? {20'b0, best_bid} : '0;
            ack_q.best_ask      <= best_ask_valid ? {20'b0, best_ask} : '0;
            ack_q.num_orders    <= num_orders;
            ack_from_mgr        <= 1'b0;
            state <= C_ACK;
          end else begin
            case (cmd_q.msg_type)
              ADD:     state <= fast_cross ? C_FAST : C_ENQ;
              CANCEL,
              EXECUTE: state <= C_MGR;
              MODIFY:  state <= C_MODIFY;
              default: state <= C_IDLE;
            endcase
          end
        end

        C_FAST: begin
          if (u_mat_m_match_done) begin
            if (u_mat_remainder_qty != '0) begin
              // Only the unfilled tail becomes a resting order.  It retains
              // the original order id, price and arrival timestamp.
              cmd_q.quantity <= u_mat_remainder_qty;
              state <= C_ENQ;
            end else begin
              ack_q.status        <= ACK_OK;
              ack_q.order_id      <= cmd_q.order_id;
              ack_q.remaining_qty <= '0;
              ack_q.best_bid      <= best_bid_valid ? {20'b0, best_bid} : '0;
              ack_q.best_ask      <= best_ask_valid ? {20'b0, best_ask} : '0;
              ack_q.num_orders    <= num_orders;
              ack_from_mgr        <= 1'b0;
              state <= C_SETTLE;
            end
          end
        end

        C_ENQ: begin
          if (u_mgr_enq_done) begin
            if (u_mgr_enq_status != ACK_OK) begin
              ack_q.status        <= u_mgr_enq_status;
              ack_q.order_id      <= cmd_q.order_id;
              ack_q.remaining_qty <= '0;
              ack_q.best_bid      <= best_bid_valid ? {20'b0, best_bid} : '0;
              ack_q.best_ask      <= best_ask_valid ? {20'b0, best_ask} : '0;
              ack_q.num_orders    <= num_orders;
              ack_from_mgr        <= 1'b0;
              state <= C_ACK;
            end else begin
              state <= C_DRAIN;
            end
          end
        end

        C_MGR: begin
          if (u_mgr_m_ack_valid) begin
            ack_q <= u_mgr_m_ack;
            ack_from_mgr <= 1'b1;
            state <= C_SETTLE;
          end
        end

        C_MODIFY: begin
          if (u_mgr_m_ack_valid) begin
            ack_q <= u_mgr_m_ack;
            ack_from_mgr <= 1'b1;
            state <= C_SETTLE;
          end else if (u_mgr_moved_valid) begin
            state <= C_DRAIN;
          end
        end

        C_DRAIN: begin
          if (u_mat_m_match_done) begin
            state <= C_QUERY;
          end
        end

        C_QUERY: begin
          if (u_mgr_query_done) begin
            ack_q.status        <= ACK_OK;
            ack_q.order_id      <= cmd_q.order_id;
            ack_q.remaining_qty <= u_mgr_query_live ? u_mgr_query_qty : '0;
            ack_q.best_bid      <= best_bid_valid ? {20'b0, best_bid} : '0;
            ack_q.best_ask      <= best_ask_valid ? {20'b0, best_ask} : '0;
            ack_q.num_orders    <= num_orders;
            ack_from_mgr        <= 1'b0;
            state <= C_ACK;
          end
        end

        C_SETTLE: begin
          if (!refresh_busy) begin
            ack_q.best_bid   <= best_bid_valid ? {20'b0, best_bid} : '0;
            ack_q.best_ask   <= best_ask_valid ? {20'b0, best_ask} : '0;
            ack_q.num_orders <= num_orders;
            state <= C_ACK;
          end
        end

        C_ACK: begin
          if (u_tgen_s_ack_ready) begin
            ack_from_mgr <= 1'b0;
            state <= C_IDLE;
          end
        end

        default: state <= C_IDLE;
      endcase
    end
  end

  // ======================================================================
  //  trade generator
  // ======================================================================
  assign tg_s_trade_valid = u_mat_m_trade_valid || u_mgr_m_trade_valid;
  assign tg_s_trade       = u_mat_m_trade_valid ? u_mat_m_trade : u_mgr_m_trade;
  assign u_mat_m_trade_ready = tg_s_trade_ready;
  assign u_mgr_m_trade_ready = tg_s_trade_ready;

  trade_generator #(.ADDR_W(ADDR_W)) u_tgen (
      .clk(clk), .rst_n(rst_n),
      .s_trade(tg_s_trade), .s_trade_valid(tg_s_trade_valid),
      .s_trade_ready(tg_s_trade_ready),
      .s_ack(ack_q), .s_ack_valid(tg_ack_valid), .s_ack_ready(u_tgen_s_ack_ready),
      .m_trade(m_trade), .m_trade_valid(m_trade_valid), .m_trade_ready(m_trade_ready),
      .m_report(m_report), .m_report_valid(m_report_valid), .m_report_ready(m_report_ready),
      .m_ack(m_ack), .m_ack_valid(m_ack_valid), .m_ack_ready(m_ack_ready)
  );

  // ======================================================================
  //  matcher
  // ======================================================================
  matcher #(.MAX_ORDERS(MAX_ORDERS), .ADDR_W(ADDR_W),
            .NUM_PRICE_LEVELS(NUM_PRICE_LEVELS), .LEVEL_IDX_W(LEVEL_IDX_W)) u_mat (
      .clk(clk), .rst_n(rst_n),
      .s_cmd(cmd_q), .s_cmd_valid(mat_s_cmd_valid),
      .s_fast_path(state == C_FAST), .s_cmd_ready(),
      .m_trade(u_mat_m_trade), .m_trade_valid(u_mat_m_trade_valid),
      .m_trade_ready(u_mat_m_trade_ready),
      .m_match_done(u_mat_m_match_done),
      .m_remainder_qty(u_mat_remainder_qty), .m_busy(u_mat_busy),
      .pool_addr(mat_pool_addr), .pool_we(mat_pool_we), .pool_re(mat_pool_re),
      .pool_wdata(mat_pool_wdata), .pool_rdata(pool_rdata_a),
      .pool_b_addr(mat_pool_b_addr), .pool_b_re(mat_pool_b_re),
      .pool_b_rdata(pool_rdata_b),
      .free_push(mat_free_push), .free_push_slot(mat_free_push_slot),
      .bid_level_addr(mat_bid_lvl_addr), .bid_level_we(mat_bid_lvl_we),
      .bid_level_re(mat_bid_lvl_re), .bid_level_wdata(mat_bid_lvl_wdata),
      .bid_level_rdata(bid_lvl_rdata),
      .ask_level_addr(mat_ask_lvl_addr), .ask_level_we(mat_ask_lvl_we),
      .ask_level_re(mat_ask_lvl_re), .ask_level_wdata(mat_ask_lvl_wdata),
      .ask_level_rdata(ask_lvl_rdata),
      .best_bid(best_bid), .best_bid_valid(best_bid_valid),
      .best_ask(best_ask), .best_ask_valid(best_ask_valid),
      .refresh_busy(refresh_busy),
      .bpe_clear_valid(mat_bpe_clear_valid), .bpe_clear_side(mat_bpe_clear_side),
      .bpe_clear_idx(mat_bpe_clear_idx),
      .mat_hash_id(mat_hash_id), .mat_hash_valid(mat_hash_valid),
      .mat_hash_busy(mat_hash_busy), .mat_hash_done(mat_hash_done)
  );

  // ======================================================================
  //  order manager
  // ======================================================================
  order_manager #(.MAX_ORDERS(MAX_ORDERS), .ADDR_W(ADDR_W),
                  .NUM_PRICE_LEVELS(NUM_PRICE_LEVELS), .LEVEL_IDX_W(LEVEL_IDX_W)) u_mgr (
      .clk(clk), .rst_n(rst_n),
      .s_cmd(cmd_q), .s_cmd_valid(mgr_s_cmd_valid), .s_cmd_ready(),
      .enq_cmd(cmd_q), .enq_valid(mgr_enq_valid), .enq_ready(),
      .enq_done(u_mgr_enq_done), .enq_status(u_mgr_enq_status),
      .moved_valid(u_mgr_moved_valid),
      .query_valid(mgr_query_valid), .query_id(cmd_q.order_id),
      .query_done(u_mgr_query_done), .query_live(u_mgr_query_live),
      .query_qty(u_mgr_query_qty),
      .m_trade(u_mgr_m_trade), .m_trade_valid(u_mgr_m_trade_valid),
      .m_trade_ready(u_mgr_m_trade_ready),
      .m_ack(u_mgr_m_ack), .m_ack_valid(u_mgr_m_ack_valid),
      .m_ack_ready(mgr_m_ack_ready), .m_busy(u_mgr_busy),
      .status_best_bid(best_bid), .status_best_bid_valid(best_bid_valid),
      .status_best_ask(best_ask), .status_best_ask_valid(best_ask_valid),
      .status_num_orders(num_orders),
      .pool_addr(mgr_pool_addr), .pool_we(mgr_pool_we), .pool_re(mgr_pool_re),
      .pool_wdata(mgr_pool_wdata), .pool_rdata(pool_rdata_b),
      .free_alloc(mgr_free_alloc), .free_slot(free_slot_b),
      .free_empty(free_empty_b), .pool_ready(pool_init_done),
      .free_push(mgr_free_push),
      .free_push_slot(mgr_free_push_slot),
      .bid_level_addr(mgr_bid_lvl_addr), .bid_level_we(mgr_bid_lvl_we),
      .bid_level_re(mgr_bid_lvl_re), .bid_level_wdata(mgr_bid_lvl_wdata),
      .bid_level_rdata(bid_lvl_rdata),
      .ask_level_addr(mgr_ask_lvl_addr), .ask_level_we(mgr_ask_lvl_we),
      .ask_level_re(mgr_ask_lvl_re), .ask_level_wdata(mgr_ask_lvl_wdata),
      .ask_level_rdata(ask_lvl_rdata),
      .hash_op(mgr_hash_op), .hash_id(mgr_hash_id), .hash_slot(mgr_hash_slot),
      .hash_valid(mgr_hash_valid), .hash_busy(mgr_hash_busy),
      .hash_done(mgr_hash_done), .hash_hit(mgr_hash_hit), .hash_miss(mgr_hash_miss),
      .hash_hit_slot(mgr_hash_hit_slot),
      .bpe_set_valid(mgr_bpe_set_valid), .bpe_set_side(mgr_bpe_set_side),
      .bpe_set_idx(mgr_bpe_set_idx),
      .bpe_clear_valid(mgr_bpe_clear_valid), .bpe_clear_side(mgr_bpe_clear_side),
      .bpe_clear_idx(mgr_bpe_clear_idx)
  );

  // ======================================================================
  //  order memory
  // ======================================================================
  order_memory #(.MAX_ORDERS(MAX_ORDERS), .ADDR_W(ADDR_W)) u_pool (
      .clk(clk), .rst_n(rst_n),
      .addr_a(mat_pool_addr), .we_a(mat_pool_we), .re_a(mat_pool_re),
      .wdata_a(mat_pool_wdata), .rdata_a(pool_rdata_a),
      .free_alloc_a(1'b0), .free_slot_a(), .free_empty_a(),
      .free_push_a(mat_free_push), .free_push_slot_a(mat_free_push_slot),
      .addr_b(u_mat_busy ? mat_pool_b_addr : mgr_pool_addr),
      .we_b(u_mat_busy ? 1'b0 : mgr_pool_we),
      .re_b(u_mat_busy ? mat_pool_b_re : mgr_pool_re),
      .wdata_b(mgr_pool_wdata), .rdata_b(pool_rdata_b),
      .free_alloc_b(u_mat_busy ? 1'b0 : mgr_free_alloc),
      .free_slot_b(free_slot_b),
      .free_empty_b(free_empty_b), .free_push_b(mgr_free_push),
      .free_push_slot_b(mgr_free_push_slot),
      .num_orders(num_orders), .init_done(pool_init_done)
  );

  // ======================================================================
  //  price level tables
  // ======================================================================
  assign bid_lvl_addr  = u_mat_busy ? mat_bid_lvl_addr : mgr_bid_lvl_addr;
  assign bid_lvl_we    = u_mat_busy ? mat_bid_lvl_we   : mgr_bid_lvl_we;
  assign bid_lvl_re    = u_mat_busy ? mat_bid_lvl_re   : mgr_bid_lvl_re;
  assign bid_lvl_wdata = u_mat_busy ? mat_bid_lvl_wdata: mgr_bid_lvl_wdata;

  assign ask_lvl_addr  = u_mat_busy ? mat_ask_lvl_addr : mgr_ask_lvl_addr;
  assign ask_lvl_we    = u_mat_busy ? mat_ask_lvl_we   : mgr_ask_lvl_we;
  assign ask_lvl_re    = u_mat_busy ? mat_ask_lvl_re   : mgr_ask_lvl_re;
  assign ask_lvl_wdata = u_mat_busy ? mat_ask_lvl_wdata: mgr_ask_lvl_wdata;

  price_level #(.NUM_LEVELS(NUM_PRICE_LEVELS), .ADDR_W(LEVEL_IDX_W)) u_lvl_bid (
      .clk(clk), .addr(bid_lvl_addr), .we(bid_lvl_we), .re(bid_lvl_re),
      .wdata(bid_lvl_wdata), .rdata(bid_lvl_rdata)
  );

  price_level #(.NUM_LEVELS(NUM_PRICE_LEVELS), .ADDR_W(LEVEL_IDX_W)) u_lvl_ask (
      .clk(clk), .addr(ask_lvl_addr), .we(ask_lvl_we), .re(ask_lvl_re),
      .wdata(ask_lvl_wdata), .rdata(ask_lvl_rdata)
  );

  // ======================================================================
  //  best price encoder
  // ======================================================================
  assign bpe_set_valid  = mgr_bpe_set_valid;
  assign bpe_set_side   = mgr_bpe_set_side;
  assign bpe_set_idx    = mgr_bpe_set_idx;
  assign bpe_clear_valid = u_mat_busy ? mat_bpe_clear_valid : mgr_bpe_clear_valid;
  assign bpe_clear_side  = side_t'(u_mat_busy ? mat_bpe_clear_side : mgr_bpe_clear_side);
  assign bpe_clear_idx   = u_mat_busy ? mat_bpe_clear_idx   : mgr_bpe_clear_idx;

  best_price_encoder #(.NUM_PRICE_LEVELS(NUM_PRICE_LEVELS), .LEVEL_IDX_W(LEVEL_IDX_W)) u_bpe (
      .clk(clk), .rst_n(rst_n),
      .set_valid(bpe_set_valid), .set_side(bpe_set_side), .set_idx(bpe_set_idx),
      .clear_valid(bpe_clear_valid), .clear_side(bpe_clear_side), .clear_idx(bpe_clear_idx),
      .best_bid(best_bid), .best_bid_valid(best_bid_valid),
      .best_ask(best_ask), .best_ask_valid(best_ask_valid),
      .refresh_busy(refresh_busy), .init_done(bpe_init_done)
  );

  // ======================================================================
  //  order id table
  // ======================================================================
  order_id_table #(.BUCKETS(HASH_BUCKETS), .WAYS(4),
                   .MAX_SET_PROBE(8), .ADDR_W(ADDR_W)) u_hash (
      .clk(clk), .rst_n(rst_n),
      .mgr_op(mgr_hash_op), .mgr_id(mgr_hash_id), .mgr_slot(mgr_hash_slot),
      .mgr_valid(mgr_hash_valid), .mgr_busy(mgr_hash_busy), .mgr_done(mgr_hash_done),
      .mgr_hit(mgr_hash_hit), .mgr_miss(mgr_hash_miss), .mgr_hit_slot(mgr_hash_hit_slot),
      .mat_id(mat_hash_id), .mat_valid(mat_hash_valid), .mat_busy(mat_hash_busy),
      .mat_done(mat_hash_done)
  );

  // ======================================================================
  //  status
  // ======================================================================
  assign status_best_bid  = best_bid_valid ? {20'b0, best_bid} : '0;
  assign status_best_ask  = best_ask_valid ? {20'b0, best_ask} : '0;
  assign status_num_orders= num_orders;

endmodule
