`timescale 1ns / 1ps
import lob_pkg::*;
// matcher.sv - functional (non-pipelined) matcher with an aggressive-ADD
// bypass and a defensive crossed-book drain FSM.
//
// The matcher executes the same price-time priority algorithm as the Python
// reference OrderBook.match_orders(): while the best bid >= best ask, consume
// the two heads, emit one trade at the passive head's price, update the book,
// and loop.  Fully-filled heads are freed and their hash entries cleared.
//
// All memory control (re/we/addr/wdata) is combinational from the FSM state;
// the FSM registers only state transitions and the latched data.  BRAM reads
// are synchronous: data is valid in the state AFTER the one that samples.
// Bid/ask levels use independent memories and the order pool is true dual-port,
// so the defensive drain fetches both levels in parallel, then both FIFO heads
// in parallel: two BRAM read beats instead of four serialized beats.
//
// For a fast-path ADD, the incoming order remains in registers while the FSM
// consumes passive heads.  A non-zero remainder is returned to the top for
// enqueue; a fully-filled incoming order never occupies a pool slot.
//
// This functional FSM is intentionally NOT the final S1-S5 pipeline yet.

module matcher #(
    parameter int MAX_ORDERS       = 8192,
    parameter int ADDR_W           = 13,
    parameter int NUM_PRICE_LEVELS = 4096,
    parameter int LEVEL_IDX_W      = 12
) (
    input  logic clk,
    input  logic rst_n,

    // drain trigger from the top
    input  cmd_t              s_cmd,
    input  logic              s_cmd_valid,
    input  logic              s_fast_path,
    output logic              s_cmd_ready,

    // matched trade output
    output trade_t            m_trade,
    output logic              m_trade_valid,
    input  logic              m_trade_ready,

    // 1-cycle done pulse after a drain completes
    output logic              m_match_done,
    output logic [31:0]       m_remainder_qty,
    output logic              m_busy,

    // ---------- order memory port A ----------
    output logic [ADDR_W-1:0] pool_addr,
    output logic              pool_we,
    output logic              pool_re,
    output order_rec_t        pool_wdata,
    input  order_rec_t        pool_rdata,

    // Second order-pool read port.  The order manager is idle while the
    // matcher owns the pool, so its physical port B can fetch the ask head.
    output logic [ADDR_W-1:0] pool_b_addr,
    output logic              pool_b_re,
    input  order_rec_t        pool_b_rdata,

    output logic              free_push,
    output logic [ADDR_W-1:0] free_push_slot,

    // ---------- price level (bid / ask) ----------
    output logic [LEVEL_IDX_W-1:0] bid_level_addr,
    output logic              bid_level_we,
    output logic              bid_level_re,
    output level_rec_t        bid_level_wdata,
    input  level_rec_t        bid_level_rdata,

    output logic [LEVEL_IDX_W-1:0] ask_level_addr,
    output logic              ask_level_we,
    output logic              ask_level_re,
    output level_rec_t        ask_level_wdata,
    input  level_rec_t        ask_level_rdata,

    // ---------- best price encoder ----------
    input  logic [LEVEL_IDX_W-1:0] best_bid,
    input  logic              best_bid_valid,
    input  logic [LEVEL_IDX_W-1:0] best_ask,
    input  logic              best_ask_valid,
    input  logic              refresh_busy,

    output logic              bpe_clear_valid,
    output side_t             bpe_clear_side,
    output logic [LEVEL_IDX_W-1:0] bpe_clear_idx,

    // ---------- hash (matcher: delete only) ----------
    output logic [63:0]       mat_hash_id,
    output logic              mat_hash_valid,
    input  logic              mat_hash_busy,
    input  logic              mat_hash_done
);

  typedef enum logic [4:0] {
    M_IDLE,
    M_CHECK,
    M_LEVELS,        // sample bid and ask level reads in parallel
    M_ORDERS,        // consume levels; sample both head reads in parallel
    M_TRADE,         // consume both heads; emit trade
    M_UPD_BID,
    M_HASH_BID_REQ,
    M_HASH_BID_WAIT,
    M_UPD_ASK,
    M_HASH_ASK_REQ,
    M_HASH_ASK_WAIT,
    F_CHECK,
    F_LEVEL,
    F_HEAD,
    F_TRADE,
    F_UPDATE,
    F_HASH_REQ,
    F_HASH_WAIT,
    M_DONE
  } mstate_t;

  mstate_t state;

  level_rec_t    bid_level_q, ask_level_q;
  order_rec_t    bid_order_q, ask_order_q;
  trade_t        trade_q;
  logic [31:0]   trade_qty_q;
  logic          bid_filled_q, ask_filled_q;
  logic          bid_level_empties_q, ask_level_empties_q;

  logic [31:0]   bid_qty_after, ask_qty_after;

  // Fast-path context.  The aggressive ADD never enters the pool; only its
  // unfilled quantity is carried through the loop and eventually returned to
  // the top for a conventional enqueue.
  cmd_t          fast_cmd_q;
  logic [31:0]   fast_rem_q, fast_trade_qty_q;
  level_rec_t    fast_level_q;
  order_rec_t    fast_order_q;
  logic          fast_passive_filled_q, fast_level_empties_q;
  logic [LEVEL_IDX_W-1:0] fast_passive_idx;
  logic          fast_crosses;

  always_comb begin
    fast_passive_idx = (fast_cmd_q.side == BUY) ? best_ask : best_bid;
    fast_crosses = (fast_cmd_q.side == BUY) ?
        (best_ask_valid && fast_cmd_q.level_idx >= best_ask) :
        (best_bid_valid && fast_cmd_q.level_idx <= best_bid);
  end

  // ---------------- combinational helpers ----------------
  always_comb begin
    bid_qty_after = bid_order_q.quantity - trade_qty_q;
    ask_qty_after = ask_order_q.quantity - trade_qty_q;
  end

  // ---------------- combinational memory control ----------------
  // reads sample in the state listed, data valid in the next state
  assign bid_level_re = (state == M_LEVELS) ||
                        (state == F_LEVEL && fast_cmd_q.side == SELL);
  assign ask_level_re = (state == M_LEVELS) ||
                        (state == F_LEVEL && fast_cmd_q.side == BUY);
  assign bid_level_addr = (state == F_LEVEL || state == F_UPDATE) ?
                          fast_passive_idx : best_bid;
  assign ask_level_addr = (state == F_LEVEL || state == F_UPDATE) ?
                          fast_passive_idx : best_ask;

  assign pool_re   = (state == M_ORDERS) || (state == F_HEAD);
  assign pool_b_re = (state == M_ORDERS);
  assign pool_b_addr = (state == M_ORDERS) ? ask_level_rdata.head_ptr : '0;

  always_comb begin
    case (state)
      M_ORDERS:              pool_addr = bid_level_rdata.head_ptr;
      M_UPD_BID:             pool_addr = bid_level_q.head_ptr;
      M_UPD_ASK:             pool_addr = ask_level_q.head_ptr;
      F_HEAD:                pool_addr = (fast_cmd_q.side == BUY) ?
                                          ask_level_rdata.head_ptr :
                                          bid_level_rdata.head_ptr;
      F_UPDATE:              pool_addr = fast_level_q.head_ptr;
      default:              pool_addr = '0;
    endcase
  end

  // pool writes (partial fills) + free/hash/bpe clears, combinational
  always_comb begin
    pool_we    = 1'b0;
    pool_wdata = '0;
    if (state == M_UPD_BID && !bid_filled_q) begin
      pool_we        = 1'b1;
      pool_wdata     = bid_order_q;
      pool_wdata.quantity = bid_qty_after;
    end
    if (state == M_UPD_ASK && !ask_filled_q) begin
      pool_we        = 1'b1;
      pool_wdata     = ask_order_q;
      pool_wdata.quantity = ask_qty_after;
    end
    if (state == F_UPDATE && !fast_passive_filled_q) begin
      pool_we             = 1'b1;
      pool_wdata          = fast_order_q;
      pool_wdata.quantity = fast_order_q.quantity - fast_trade_qty_q;
    end
  end

  always_comb begin
    bid_level_we    = (state == M_UPD_BID);
    bid_level_wdata = '0;
    if (state == M_UPD_BID) begin
      if (bid_filled_q) begin
        bid_level_wdata.head_ptr  = bid_order_q.next_ptr;
        bid_level_wdata.tail_ptr  = (bid_order_q.next_ptr == '0) ? '0 :
                                     bid_level_q.tail_ptr;
      end else begin
        bid_level_wdata.head_ptr  = bid_level_q.head_ptr;
        bid_level_wdata.tail_ptr  = bid_level_q.tail_ptr;
      end
      bid_level_wdata.total_qty = bid_level_q.total_qty - trade_qty_q;
    end
    if (state == F_UPDATE && fast_cmd_q.side == SELL) begin
      bid_level_we = 1'b1;
      bid_level_wdata.head_ptr = fast_passive_filled_q ?
                                 fast_order_q.next_ptr : fast_level_q.head_ptr;
      bid_level_wdata.tail_ptr = fast_passive_filled_q &&
                                 fast_order_q.next_ptr == '0 ?
                                 '0 : fast_level_q.tail_ptr;
      bid_level_wdata.total_qty = fast_level_q.total_qty -
                                  fast_trade_qty_q[15:0];
    end

    ask_level_we    = (state == M_UPD_ASK);
    ask_level_wdata = '0;
    if (state == M_UPD_ASK) begin
      if (ask_filled_q) begin
        ask_level_wdata.head_ptr  = ask_order_q.next_ptr;
        ask_level_wdata.tail_ptr  = (ask_order_q.next_ptr == '0) ? '0 :
                                     ask_level_q.tail_ptr;
      end else begin
        ask_level_wdata.head_ptr  = ask_level_q.head_ptr;
        ask_level_wdata.tail_ptr  = ask_level_q.tail_ptr;
      end
      ask_level_wdata.total_qty = ask_level_q.total_qty - trade_qty_q;
    end
    if (state == F_UPDATE && fast_cmd_q.side == BUY) begin
      ask_level_we = 1'b1;
      ask_level_wdata.head_ptr = fast_passive_filled_q ?
                                 fast_order_q.next_ptr : fast_level_q.head_ptr;
      ask_level_wdata.tail_ptr = fast_passive_filled_q &&
                                 fast_order_q.next_ptr == '0 ?
                                 '0 : fast_level_q.tail_ptr;
      ask_level_wdata.total_qty = fast_level_q.total_qty -
                                  fast_trade_qty_q[15:0];
    end
  end

  // occupancy clears + hash deletes + slot frees for fully-filled heads
  always_comb begin
    bpe_clear_valid = 1'b0;
    bpe_clear_side  = BUY;
    bpe_clear_idx   = '0;
    free_push       = 1'b0;
    free_push_slot  = '0;
    mat_hash_valid  = 1'b0;
    mat_hash_id     = '0;

    if (state == M_UPD_BID && bid_filled_q) begin
      free_push      = 1'b1;
      free_push_slot = bid_level_q.head_ptr;
      if (bid_level_empties_q) begin
        bpe_clear_valid = 1'b1;
        bpe_clear_side  = BUY;
        bpe_clear_idx   = best_bid;
      end
    end
    if (state == M_UPD_ASK && ask_filled_q) begin
      free_push      = 1'b1;
      free_push_slot = ask_level_q.head_ptr;
      if (ask_level_empties_q) begin
        bpe_clear_valid = 1'b1;
        bpe_clear_side  = SELL;
        bpe_clear_idx   = best_ask;
      end
    end
    if (state == M_HASH_BID_REQ) begin
      mat_hash_valid = 1'b1;
      mat_hash_id    = bid_order_q.order_id;
    end
    if (state == M_HASH_ASK_REQ) begin
      mat_hash_valid = 1'b1;
      mat_hash_id    = ask_order_q.order_id;
    end
    if (state == F_UPDATE && fast_passive_filled_q) begin
      free_push      = 1'b1;
      free_push_slot = fast_level_q.head_ptr;
      if (fast_level_empties_q) begin
        bpe_clear_valid = 1'b1;
        bpe_clear_side  = side_t'((fast_cmd_q.side == BUY) ? SELL : BUY);
        bpe_clear_idx   = fast_passive_idx;
      end
    end
    if (state == F_HASH_REQ) begin
      mat_hash_valid = 1'b1;
      mat_hash_id    = fast_order_q.order_id;
    end
  end

  // Register the complete trade before presenting it to the downstream FIFO.
  // This removes the BRAM-output -> timestamp compare -> FIFO-input path.
  assign m_trade = trade_q;

  // ---------------- FSM ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state         <= M_IDLE;
      bid_level_q   <= '0;
      ask_level_q   <= '0;
      bid_order_q   <= '0;
      ask_order_q   <= '0;
      trade_q       <= '0;
      trade_qty_q   <= '0;
      bid_filled_q  <= 1'b0;
      ask_filled_q  <= 1'b0;
      bid_level_empties_q <= 1'b0;
      ask_level_empties_q <= 1'b0;
      m_trade_valid <= 1'b0;
      m_match_done  <= 1'b0;
      m_remainder_qty <= '0;
      fast_cmd_q    <= '0;
      fast_rem_q    <= '0;
      fast_trade_qty_q <= '0;
      fast_level_q  <= '0;
      fast_order_q  <= '0;
      fast_passive_filled_q <= 1'b0;
      fast_level_empties_q <= 1'b0;
    end else begin
      m_trade_valid <= 1'b0;
      m_match_done  <= 1'b0;

      case (state)
        M_IDLE: begin
          if (s_cmd_valid) begin
            if (s_fast_path) begin
              fast_cmd_q <= s_cmd;
              fast_rem_q <= s_cmd.quantity;
              state      <= F_CHECK;
            end else begin
              state <= M_CHECK;
            end
          end
        end

        F_CHECK: begin
          if (refresh_busy) begin
            state <= F_CHECK;
          end else if (fast_rem_q != '0 && fast_crosses) begin
            state <= F_LEVEL;
          end else begin
            m_remainder_qty <= fast_rem_q;
            state <= M_DONE;
          end
        end

        // Read the passive best level, then its FIFO head.  These are kept as
        // distinct states to match the synchronous BRAM interfaces.
        F_LEVEL: state <= F_HEAD;

        F_HEAD: begin
          fast_level_q <= (fast_cmd_q.side == BUY) ? ask_level_rdata
                                                   : bid_level_rdata;
          state <= F_TRADE;
        end

        F_TRADE: begin
          fast_order_q <= pool_rdata;
          fast_trade_qty_q <= (fast_rem_q < pool_rdata.quantity) ?
                              fast_rem_q : pool_rdata.quantity;
          fast_passive_filled_q <= (pool_rdata.quantity <= fast_rem_q);
          fast_level_empties_q <= (pool_rdata.quantity <= fast_rem_q) &&
                                  (pool_rdata.next_ptr == '0);
          trade_q.buy_order_id <= (fast_cmd_q.side == BUY) ?
                                  fast_cmd_q.order_id : pool_rdata.order_id;
          trade_q.sell_order_id <= (fast_cmd_q.side == SELL) ?
                                   fast_cmd_q.order_id : pool_rdata.order_id;
          trade_q.price <= {16'b0, pool_rdata.price_q};
          trade_q.quantity <= (fast_rem_q < pool_rdata.quantity) ?
                              fast_rem_q : pool_rdata.quantity;
          trade_q.timestamp_ns <= (fast_cmd_q.timestamp_ns >=
                                   pool_rdata.timestamp_ns) ?
                                   fast_cmd_q.timestamp_ns :
                                   pool_rdata.timestamp_ns;
          m_trade_valid <= 1'b1;
          if (m_trade_ready) state <= F_UPDATE;
        end

        F_UPDATE: begin
          fast_rem_q <= fast_rem_q - fast_trade_qty_q;
          state <= fast_passive_filled_q ? F_HASH_REQ : F_CHECK;
        end

        F_HASH_REQ: state <= F_HASH_WAIT;

        F_HASH_WAIT: begin
          if (mat_hash_done) state <= F_CHECK;
        end

        M_CHECK: begin
          // wait for any best-price refresh to settle
          if (refresh_busy) begin
            state <= M_CHECK;
          end else if (best_bid_valid && best_ask_valid &&
                       (best_bid >= best_ask)) begin
            state <= M_LEVELS;
          end else begin
            state <= M_DONE;
          end
        end

        // Beat 1: both independent level BRAMs sample their best-price rows.
        M_LEVELS: begin
          state <= M_ORDERS;
        end

        // Beat 2: consume both level rows and use both physical pool ports to
        // sample the bid and ask FIFO heads in the same cycle.
        M_ORDERS: begin
          bid_level_q <= bid_level_rdata;
          ask_level_q <= ask_level_rdata;
          state       <= M_TRADE;
        end

        // Consume both heads, compute and emit the trade.  pool_rdata is the
        // bid head and pool_b_rdata is the ask head arriving this cycle.
        // for the M_UPD_BID / M_UPD_ASK book updates.
        M_TRADE: begin
          bid_order_q <= pool_rdata;
          ask_order_q <= pool_b_rdata;
          trade_q.buy_order_id  <= pool_rdata.order_id;
          trade_q.sell_order_id <= pool_b_rdata.order_id;
          trade_q.price <=
              (pool_rdata.timestamp_ns <= pool_b_rdata.timestamp_ns) ?
              {16'b0, pool_rdata.price_q} : {16'b0, pool_b_rdata.price_q};
          trade_q.quantity <=
              (pool_rdata.quantity < pool_b_rdata.quantity) ?
              pool_rdata.quantity : pool_b_rdata.quantity;
          trade_q.timestamp_ns <=
              (pool_rdata.timestamp_ns >= pool_b_rdata.timestamp_ns) ?
              pool_rdata.timestamp_ns : pool_b_rdata.timestamp_ns;
          trade_qty_q <= (pool_rdata.quantity < pool_b_rdata.quantity) ?
                         pool_rdata.quantity : pool_b_rdata.quantity;
          bid_filled_q <= (pool_rdata.quantity <= pool_b_rdata.quantity);
          ask_filled_q <= (pool_b_rdata.quantity <= pool_rdata.quantity);
          bid_level_empties_q <=
              (pool_rdata.quantity <= pool_b_rdata.quantity) &&
              (pool_rdata.next_ptr == '0);
          ask_level_empties_q <=
              (pool_b_rdata.quantity <= pool_rdata.quantity) &&
              (pool_b_rdata.next_ptr == '0);
          m_trade_valid <= 1'b1;
          if (m_trade_ready) state <= M_UPD_BID;
        end

        M_UPD_BID: begin
          state <= bid_filled_q ? M_HASH_BID_REQ : M_UPD_ASK;
        end

        M_HASH_BID_REQ: begin
          state <= M_HASH_BID_WAIT;
        end

        M_HASH_BID_WAIT: begin
          if (mat_hash_done) state <= M_UPD_ASK;
        end

        M_UPD_ASK: begin
          state <= ask_filled_q ? M_HASH_ASK_REQ : M_CHECK;
        end

        M_HASH_ASK_REQ: begin
          state <= M_HASH_ASK_WAIT;
        end

        M_HASH_ASK_WAIT: begin
          if (mat_hash_done) state <= M_CHECK;
        end

        M_DONE: begin
          m_match_done <= 1'b1;
          state        <= M_IDLE;
        end
      endcase
    end
  end

  assign s_cmd_ready = (state == M_IDLE);
  assign m_busy      = (state != M_IDLE);

endmodule
