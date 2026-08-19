`timescale 1ns / 1ps
import lob_pkg::*;
// order_manager.sv - book keeper: enqueue (ADD), CANCEL, MODIFY, EXECUTE
// (external fill) and QUERY.  Owns all hash-table traffic and the free list
// allocation; the matcher only consumes (frees) fully-filled heads.
//
// All memory control (re/we/addr/wdata) is combinational from the FSM state;
// the FSM registers only state transitions and the latched data.  BRAM reads
// are synchronous: data is valid in the state AFTER the one that samples.

module order_manager #(
    parameter int MAX_ORDERS       = 8192,
    parameter int ADDR_W           = 13,
    parameter int NUM_PRICE_LEVELS = 4096,
    parameter int LEVEL_IDX_W      = 12
) (
    input  logic clk,
    input  logic rst_n,

    // command from top (CANCEL / MODIFY / EXECUTE)
    input  cmd_t              s_cmd,
    input  logic              s_cmd_valid,
    output logic              s_cmd_ready,

    // enqueue request from top (ADD)
    input  cmd_t              enq_cmd,
    input  logic              enq_valid,
    output logic              enq_ready,
    output logic              enq_done,
    output ack_status_t       enq_status,

    // MODIFY price change completed -> top should run the matcher drain
    output logic              moved_valid,

    // query (top asks live qty of an order for ack composition)
    input  logic              query_valid,
    input  logic [63:0]       query_id,
    output logic              query_done,
    output logic              query_live,
    output logic [31:0]       query_qty,

    // trade out (external fills)
    output trade_t            m_trade,
    output logic              m_trade_valid,
    input  logic              m_trade_ready,

    // ack out (for ops this module completes: CANCEL / MODIFY-qty / EXECUTE)
    output ack_t              m_ack,
    output logic              m_ack_valid,
    input  logic              m_ack_ready,

    output logic              m_busy,

    // ---------- book state (status inputs for ack composition) ----------
    input  logic [LEVEL_IDX_W-1:0] status_best_bid,
    input  logic              status_best_bid_valid,
    input  logic [LEVEL_IDX_W-1:0] status_best_ask,
    input  logic              status_best_ask_valid,
    input  logic [ADDR_W-1:0] status_num_orders,

    // ---------- order memory port B ----------
    output logic [ADDR_W-1:0] pool_addr,
    output logic              pool_we,
    output logic              pool_re,
    output order_rec_t        pool_wdata,
    input  order_rec_t        pool_rdata,

    output logic              free_alloc,
    input  logic [ADDR_W-1:0] free_slot,
    input  logic              free_empty,
    input  logic              pool_ready,
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

    // ---------- hash (manager port: lookup / insert / delete) ----------
    output logic [1:0]        hash_op,
    output logic [63:0]       hash_id,
    output logic [ADDR_W-1:0] hash_slot,
    output logic              hash_valid,
    input  logic              hash_busy,
    input  logic              hash_done,
    input  logic              hash_hit,
    input  logic              hash_miss,
    input  logic [ADDR_W-1:0] hash_hit_slot,

    // ---------- best price encoder ----------
    output logic              bpe_set_valid,
    output side_t             bpe_set_side,
    output logic [LEVEL_IDX_W-1:0] bpe_set_idx,
    output logic              bpe_clear_valid,
    output side_t             bpe_clear_side,
    output logic [LEVEL_IDX_W-1:0] bpe_clear_idx
);

  typedef enum logic [5:0] {
    MGR_IDLE,
    // enqueue (ADD)
    ENQ_GET_SLOT, ENQ_SLOT, ENQ_HASH, ENQ_WAIT_HASH, ENQ_ROLLBACK,
    ENQ_LVL_REQ, ENQ_LVL, ENQ_WR_EMPTY, ENQ_TAIL, ENQ_TAIL2, ENQ_DONE,
    // lookup then order/level read
    LU_START, LU_WAIT, LU_HIT, ORD_LATCH, LVL_LATCH, CAN_BEGIN,
    // splice
    SP_NEXT, SP_WR_NEXT, SP_WR_NEXT2, DEL_HASH, DEL_WAIT, DEL_COMMIT,
    // cancel finish
    CAN_ACK, CAN_ACK_ERR,
    // modify
    MOD_QTY_WR, MOD_ACK,
    // modify price-change reinsert
    RE_LVL, RE_LVL2, RE_WR_EMPTY, RE_TAIL, RE_TAIL2,
    // execute
    EX_PARTIAL, EX_TRADE, EX_ACK, EX_ACK_ERR
  } mgr_state_t;

  typedef enum logic [2:0] {
    OP_ENQ, OP_CANCEL, OP_MODIFY, OP_EXECUTE, OP_QUERY
  } mgr_op_t;

  mgr_state_t state;
  mgr_state_t prev_state;  // debug
  mgr_op_t    op_q;
  cmd_t       cmd_q;

  logic [ADDR_W-1:0]   slot_q;
  order_rec_t          order_q;
  level_rec_t          level_q;       // level of order_q
  level_rec_t          new_level_q;   // new level during reinsert
  order_rec_t          prev_order_q, next_order_q;
  logic [ADDR_W-1:0]   new_head_q, new_tail_q;
  logic [15:0]         new_qty_q;
  logic [63:0]         q_id_q;
  logic                full_fill;

  // ---------------- level access mux (combinational) ----------------
  logic [LEVEL_IDX_W-1:0] lvl_addr;
  logic               lvl_we, lvl_re;
  level_rec_t         lvl_wdata;
  level_rec_t         lvl_rdata;

  // which side's level the current operation touches
  logic is_order_side;
  always_comb begin
    is_order_side = 1'b0;
    case (state)
      ORD_LATCH:            is_order_side = (pool_rdata.side == SELL);
      LVL_LATCH, CAN_BEGIN, SP_NEXT, SP_WR_NEXT, SP_WR_NEXT2,
      MOD_QTY_WR, EX_PARTIAL: is_order_side = (order_q.side == SELL);
      ENQ_LVL_REQ, ENQ_LVL, ENQ_WR_EMPTY, ENQ_TAIL, ENQ_TAIL2,
      RE_LVL, RE_LVL2, RE_WR_EMPTY, RE_TAIL, RE_TAIL2:
                                  is_order_side = (cmd_q.side == SELL);
      default:              is_order_side = 1'b0;
    endcase
  end

  always_comb begin
    bid_level_addr  = lvl_addr;
    ask_level_addr  = lvl_addr;
    bid_level_we    = lvl_we && !is_order_side;
    ask_level_we    = lvl_we &&  is_order_side;
    bid_level_re    = lvl_re && !is_order_side;
    ask_level_re    = lvl_re &&  is_order_side;
    bid_level_wdata = lvl_wdata;
    ask_level_wdata = lvl_wdata;
    lvl_rdata       = is_order_side ? ask_level_rdata : bid_level_rdata;
  end

  // ---------------- handshakes ----------------
  assign s_cmd_ready = (state == MGR_IDLE) && !enq_valid && !query_valid;
  assign enq_ready   = (state == MGR_IDLE) && !s_cmd_valid && !query_valid;
  assign m_busy      = (state != MGR_IDLE);

  // trade composition for external fills (combinational)
  trade_t ex_trade;
  always_comb begin
    ex_trade.buy_order_id  = (order_q.side == BUY)  ? order_q.order_id : '0;
    ex_trade.sell_order_id = (order_q.side == SELL) ? order_q.order_id : '0;
    ex_trade.price         = {16'b0, order_q.price_q};
    ex_trade.quantity      = cmd_q.quantity;
    ex_trade.timestamp_ns  = cmd_q.timestamp_ns;
  end

  // ---------------- ack composition helper ----------------
  function automatic ack_t ack_make(ack_status_t st, logic [63:0] oid,
                                    logic [31:0] rem);
    ack_t a;
    a.status        = st;
    a.order_id      = oid;
    a.remaining_qty = rem;
    a.best_bid      = status_best_bid_valid ? {20'b0, status_best_bid} : '0;
    a.best_ask      = status_best_ask_valid ? {20'b0, status_best_ask} : '0;
    a.num_orders    = status_num_orders;
    return a;
  endfunction

  // ---------------- combinational level control ----------------
  always_comb begin
    lvl_re   = 1'b0;
    lvl_we   = 1'b0;
    lvl_addr = '0;
    lvl_wdata = '0;

    // reads sample in these states; data valid in the next state
    if (state == ENQ_LVL_REQ || state == RE_LVL) begin
      lvl_re   = 1'b1;
      lvl_addr = cmd_q.level_idx;
    end
    if (state == ORD_LATCH) begin
      lvl_re   = 1'b1;
      lvl_addr = pool_rdata.price_q;
    end

    // writes
    case (state)
      SP_WR_NEXT: begin
        lvl_we    = 1'b1;
        lvl_addr  = order_q.price_q;
        lvl_wdata.head_ptr  = new_head_q;
        lvl_wdata.tail_ptr  = new_tail_q;
        lvl_wdata.total_qty = new_qty_q;
      end
      MOD_QTY_WR: begin
        lvl_we    = 1'b1;
        lvl_addr  = order_q.price_q;
        lvl_wdata.head_ptr  = level_q.head_ptr;
        lvl_wdata.tail_ptr  = level_q.tail_ptr;
        lvl_wdata.total_qty = level_q.total_qty + cmd_q.quantity[15:0] -
                              order_q.quantity[15:0];
      end
      RE_WR_EMPTY, ENQ_WR_EMPTY: begin
        lvl_we    = 1'b1;
        lvl_addr  = cmd_q.level_idx;
        lvl_wdata.head_ptr  = slot_q;
        lvl_wdata.tail_ptr  = slot_q;
        lvl_wdata.total_qty = cmd_q.quantity[15:0];
      end
      RE_TAIL2, ENQ_TAIL2: begin
        lvl_we    = 1'b1;
        lvl_addr  = cmd_q.level_idx;
        lvl_wdata.head_ptr  = (state == RE_TAIL2) ? new_level_q.head_ptr
                                                  : level_q.head_ptr;
        lvl_wdata.tail_ptr  = slot_q;
        lvl_wdata.total_qty = (state == RE_TAIL2) ? new_level_q.total_qty
                                                  : level_q.total_qty;
        lvl_wdata.total_qty = lvl_wdata.total_qty + cmd_q.quantity[15:0];
      end
      EX_PARTIAL: begin
        lvl_we    = 1'b1;
        lvl_addr  = order_q.price_q;
        lvl_wdata.head_ptr  = level_q.head_ptr;
        lvl_wdata.tail_ptr  = level_q.tail_ptr;
        lvl_wdata.total_qty = level_q.total_qty - cmd_q.quantity[15:0];
      end
      default: ;
    endcase
  end

  // ---------------- combinational pool control ----------------
  always_comb begin
    pool_re = 1'b0;
    if (state == LU_HIT ||
        (state == CAN_BEGIN && (order_q.prev_ptr != '0 ||
                                order_q.next_ptr != '0)) ||
        (state == SP_NEXT && order_q.next_ptr != '0) ||
        (state == RE_LVL2 && lvl_rdata.head_ptr != '0) ||
        (state == ENQ_LVL && lvl_rdata.head_ptr != '0)) begin
      pool_re = 1'b1;
    end

    case (state)
      LU_HIT:     pool_addr = slot_q;
      CAN_BEGIN:  pool_addr = (order_q.prev_ptr != '0) ? order_q.prev_ptr
                                                       : order_q.next_ptr;
      SP_NEXT:    pool_addr = order_q.next_ptr;
      SP_WR_NEXT: pool_addr = order_q.prev_ptr;
      SP_WR_NEXT2:pool_addr = order_q.next_ptr;
      RE_LVL2:    pool_addr = lvl_rdata.tail_ptr;
      RE_TAIL:    pool_addr = new_level_q.tail_ptr;
      RE_TAIL2, RE_LVL, MOD_QTY_WR, EX_PARTIAL,
      ENQ_WR_EMPTY, ENQ_TAIL2: pool_addr = slot_q;
      ENQ_LVL:    pool_addr = lvl_rdata.tail_ptr;
      ENQ_TAIL:   pool_addr = level_q.tail_ptr;
      default:    pool_addr = '0;
    endcase

    pool_we = 1'b0;
    pool_wdata = '0;
    case (state)
      SP_WR_NEXT: begin
        if (order_q.prev_ptr != '0) begin
          pool_we    = 1'b1;
          pool_wdata = prev_order_q;
          pool_wdata.next_ptr = order_q.next_ptr;
        end
      end
      SP_WR_NEXT2: begin
        if (order_q.next_ptr != '0) begin
          pool_we    = 1'b1;
          pool_wdata = next_order_q;
          pool_wdata.prev_ptr = order_q.prev_ptr;
        end
      end
      MOD_QTY_WR: begin
        pool_we    = 1'b1;
        pool_wdata = order_q;
        pool_wdata.quantity = cmd_q.quantity;
      end
      RE_TAIL, ENQ_TAIL: begin
        pool_we    = 1'b1;
        pool_wdata = pool_rdata;            // the old tail order
        pool_wdata.next_ptr = slot_q;
      end
      RE_LVL, RE_TAIL2, ENQ_WR_EMPTY, ENQ_TAIL2: begin
        pool_we        = 1'b1;
        pool_wdata.valid        = 1'b1;
        pool_wdata.side         = cmd_q.side;
        pool_wdata.price_q      = cmd_q.level_idx;
        pool_wdata.quantity     = cmd_q.quantity;
        pool_wdata.timestamp_ns = cmd_q.timestamp_ns;
        pool_wdata.order_id     = cmd_q.order_id;
        pool_wdata.next_ptr     = '0;
        if (state == RE_TAIL2)      pool_wdata.prev_ptr = new_level_q.tail_ptr;
        else if (state == ENQ_TAIL2) pool_wdata.prev_ptr = level_q.tail_ptr;
        else                         pool_wdata.prev_ptr = '0;
      end
      EX_PARTIAL: begin
        pool_we    = 1'b1;
        pool_wdata = order_q;
        pool_wdata.quantity = order_q.quantity - cmd_q.quantity;
      end
      default: ;
    endcase
  end

  // ---------------- combinational free list / hash / bpe ----------------
  assign free_alloc      = (state == ENQ_GET_SLOT) && !free_empty;
  assign free_push       = (state == ENQ_ROLLBACK) ||
                           (state == DEL_COMMIT);
  assign free_push_slot  = slot_q;

  assign hash_valid = (state == LU_START) ||
                      (state == ENQ_HASH) ||
                      (state == DEL_HASH);
  assign hash_op = (state == ENQ_HASH) ? 2'd1 :           // INSERT
                   (state == LU_START) ? 2'd0 : 2'd2;     // LOOKUP / DELETE
  assign hash_id = (state == LU_START) ? ((op_q == OP_QUERY) ? q_id_q
                                                             : cmd_q.order_id) :
                   (state == ENQ_HASH) ? cmd_q.order_id : order_q.order_id;
  assign hash_slot = slot_q;

  assign bpe_set_valid = (state == RE_WR_EMPTY) || (state == ENQ_WR_EMPTY);
  assign bpe_set_side  = cmd_q.side;
  assign bpe_set_idx   = cmd_q.level_idx;
  assign bpe_clear_valid = (state == SP_WR_NEXT) && (new_qty_q == '0);
  assign bpe_clear_side  = side_t'(is_order_side);   // 0 = BUY, 1 = SELL
  assign bpe_clear_idx   = order_q.price_q;

  // ---------------- FSM ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= MGR_IDLE;
      prev_state   <= MGR_IDLE;
      op_q         <= OP_ENQ;
      cmd_q        <= '0;
      slot_q       <= '0;
      order_q      <= '0;
      level_q      <= '0;
      new_level_q  <= '0;
      prev_order_q <= '0;
      next_order_q <= '0;
      new_head_q   <= '0;
      new_tail_q   <= '0;
      new_qty_q    <= '0;
      q_id_q       <= '0;
      full_fill    <= 1'b0;
      enq_done     <= 1'b0;
      enq_status   <= ACK_OK;
      moved_valid  <= 1'b0;
      query_done   <= 1'b0;
      query_live   <= 1'b0;
      query_qty    <= '0;
      m_trade_valid<= 1'b0;
      m_ack_valid  <= 1'b0;
      m_ack        <= '0;
    end else begin
      prev_state   <= state;
      enq_done     <= 1'b0;
      moved_valid  <= 1'b0;
      query_done   <= 1'b0;
      m_trade_valid<= 1'b0;
      m_ack_valid  <= 1'b0;

      case (state)
        MGR_IDLE: begin
          if (query_valid) begin
            op_q   <= OP_QUERY;
            q_id_q <= query_id;
            state  <= LU_START;
          end else if (s_cmd_valid) begin
            cmd_q <= s_cmd;
            case (s_cmd.msg_type)
              CANCEL:  op_q <= OP_CANCEL;
              MODIFY:  op_q <= OP_MODIFY;
              EXECUTE: op_q <= OP_EXECUTE;
              default: op_q <= OP_CANCEL;
            endcase
            state <= LU_START;
          end else if (enq_valid) begin
            cmd_q <= enq_cmd;
            op_q  <= OP_ENQ;
            state <= ENQ_GET_SLOT;
          end
        end

        LU_START: state <= LU_WAIT;

        LU_WAIT: begin
          if (hash_done) begin
            if (hash_miss) begin
              if (op_q == OP_QUERY) begin
                query_done <= 1'b1;
                query_live <= 1'b0;
                query_qty  <= '0;
                state      <= MGR_IDLE;
              end else begin
                m_ack_valid <= 1'b1;
                m_ack <= ack_make(ACK_REJECT_NOT_LIVE, cmd_q.order_id, '0);
                state <= CAN_ACK_ERR;
              end
            end else begin
              slot_q <= hash_hit_slot;
              state  <= LU_HIT;
            end
          end
        end

        // order read samples here (pool_rdata valid during ORD_LATCH)
        LU_HIT: state <= ORD_LATCH;

        // level read samples here (lvl_rdata valid during LVL_LATCH)
        ORD_LATCH: begin
          order_q <= pool_rdata;
          if (op_q == OP_QUERY) begin
            query_done <= 1'b1;
            query_live <= 1'b1;
            query_qty  <= pool_rdata.quantity;
            state      <= MGR_IDLE;
          end else begin
            state <= LVL_LATCH;
          end
        end

        LVL_LATCH: begin
          level_q <= lvl_rdata;
          if (op_q == OP_MODIFY &&
              (!lob_pkg::price_in_range(cmd_q.price) ||
               cmd_q.quantity == '0)) begin
            m_ack_valid <= 1'b1;
            m_ack <= ack_make(ACK_REJECT_BAD_FIELD, cmd_q.order_id, '0);
            state <= CAN_ACK_ERR;
          end else if (op_q == OP_EXECUTE &&
                       (cmd_q.quantity == '0 ||
                        cmd_q.quantity > order_q.quantity)) begin
            m_ack_valid <= 1'b1;
            m_ack <= ack_make(ACK_REJECT_BAD_FIELD, cmd_q.order_id,
                              order_q.quantity);
            state <= EX_ACK_ERR;
          end else begin
            case (op_q)
              OP_CANCEL: state <= CAN_BEGIN;
              OP_MODIFY: begin
                if (cmd_q.level_idx == order_q.price_q) state <= MOD_QTY_WR;
                else                                     state <= CAN_BEGIN;
              end
              OP_EXECUTE: begin
                full_fill <= (cmd_q.quantity == order_q.quantity);
                if (cmd_q.quantity == order_q.quantity) state <= CAN_BEGIN;
                else                                     state <= EX_PARTIAL;
              end
              default: state <= MGR_IDLE;
            endcase
          end
        end

        // compute splice params; prev/next pool read samples here
        CAN_BEGIN: begin
          new_head_q <= (order_q.prev_ptr == '0) ? order_q.next_ptr
                                                 : level_q.head_ptr;
          new_tail_q <= (order_q.next_ptr == '0) ? order_q.prev_ptr
                                                 : level_q.tail_ptr;
          new_qty_q  <= level_q.total_qty - order_q.quantity;
          if (order_q.prev_ptr != '0) state <= SP_NEXT;
          else                        state <= SP_WR_NEXT;
        end

        // prev order read (sampled in CAN_BEGIN) arrives here
        SP_NEXT: begin
          prev_order_q <= pool_rdata;
          state        <= SP_WR_NEXT;
        end

        // next order read (sampled in SP_NEXT or CAN_BEGIN) arrives here
        SP_WR_NEXT: begin
          next_order_q <= pool_rdata;
          state        <= SP_WR_NEXT2;
        end

        SP_WR_NEXT2: begin
          case (op_q)
            OP_CANCEL:   state <= DEL_HASH;
            OP_EXECUTE:  state <= DEL_HASH;
            OP_MODIFY:   state <= RE_LVL;
            default:     state <= MGR_IDLE;
          endcase
        end

        // Wait for the hash deletion before releasing the pool slot. This
        // prevents a following command from observing a stale ID mapping.
        DEL_HASH: state <= DEL_WAIT;

        DEL_WAIT: begin
          if (hash_done) state <= DEL_COMMIT;
        end

        DEL_COMMIT: begin
          case (op_q)
            OP_CANCEL:  state <= CAN_ACK;
            OP_EXECUTE: state <= EX_TRADE;
            default:    state <= MGR_IDLE;
          endcase
        end

        // =========================== CANCEL ============================
        CAN_ACK: begin
          m_ack_valid <= 1'b1;
          m_ack <= ack_make(ACK_OK, cmd_q.order_id, '0);
          if (m_ack_ready) state <= MGR_IDLE;
        end

        CAN_ACK_ERR: begin
          m_ack_valid <= 1'b1;
          if (m_ack_ready) state <= MGR_IDLE;
        end

        // ===================== MODIFY quantity-only =====================
        MOD_QTY_WR: state <= MOD_ACK;

        MOD_ACK: begin
          m_ack_valid <= 1'b1;
          m_ack <= ack_make(ACK_OK, cmd_q.order_id, cmd_q.quantity);
          if (m_ack_ready) state <= MGR_IDLE;
        end

        // ============ MODIFY price-change: reinsert at new level =========
        // order write + new-level read sample here
        RE_LVL: state <= RE_LVL2;

        RE_LVL2: begin
          new_level_q <= lvl_rdata;
          if (lvl_rdata.head_ptr == '0) state <= RE_WR_EMPTY;
          else                          state <= RE_TAIL;
        end

        RE_WR_EMPTY: begin
          moved_valid <= 1'b1;
          state       <= MGR_IDLE;
        end

        // tail read (sampled in RE_LVL2) arrives here
        RE_TAIL: state <= RE_TAIL2;

        RE_TAIL2: begin
          moved_valid <= 1'b1;
          state       <= MGR_IDLE;
        end

        // ========================= EXECUTE ==============================
        EX_PARTIAL: state <= EX_TRADE;

        EX_TRADE: begin
          m_trade_valid <= 1'b1;
          m_trade       <= ex_trade;
          if (m_trade_ready) state <= EX_ACK;
        end

        EX_ACK: begin
          m_ack_valid <= 1'b1;
          m_ack <= ack_make(ACK_OK, cmd_q.order_id,
                            full_fill ? '0 : order_q.quantity - cmd_q.quantity);
          if (m_ack_ready) state <= MGR_IDLE;
        end

        EX_ACK_ERR: begin
          m_ack_valid <= 1'b1;
          if (m_ack_ready) state <= MGR_IDLE;
        end

        // ========================= ENQUEUE (ADD) ========================
        ENQ_GET_SLOT: begin
          if (!pool_ready) begin
            state <= ENQ_GET_SLOT;
          end else if (free_empty) begin
            enq_done   <= 1'b1;
            enq_status <= ACK_REJECT_FULL;
            state      <= MGR_IDLE;
          end else begin
            state <= ENQ_SLOT;
          end
        end

        // Reserve a pool slot, then establish the ID mapping before exposing
        // any order or price-level state.
        ENQ_SLOT: begin
          slot_q <= free_slot;
          state  <= ENQ_HASH;
        end


        ENQ_HASH: state <= ENQ_WAIT_HASH;

        ENQ_WAIT_HASH: begin
          if (hash_done) begin
            if (hash_hit && !hash_miss) state <= ENQ_LVL_REQ;
            else                        state <= ENQ_ROLLBACK;
          end
        end

        ENQ_ROLLBACK: begin
          enq_done   <= 1'b1;
          enq_status <= ACK_REJECT_INTERNAL;
          state      <= MGR_IDLE;
        end

        // Price-level read begins only after the hash insertion committed.
        ENQ_LVL_REQ: state <= ENQ_LVL;

        ENQ_LVL: begin
          level_q <= lvl_rdata;
          if (lvl_rdata.head_ptr == '0) state <= ENQ_WR_EMPTY;
          else                          state <= ENQ_TAIL;
        end

        ENQ_WR_EMPTY: state <= ENQ_DONE;

        // tail read (sampled in ENQ_LVL) arrives here
        ENQ_TAIL: state <= ENQ_TAIL2;

        ENQ_TAIL2: state <= ENQ_DONE;

        ENQ_DONE: begin
          enq_done   <= 1'b1;
          enq_status <= ACK_OK;
          state      <= MGR_IDLE;
        end

        default: state <= MGR_IDLE;
      endcase
    end
  end

endmodule
