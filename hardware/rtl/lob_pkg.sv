`timescale 1ns / 1ps
// lob_pkg.sv - shared types and parameters for the LOB engine.
// Kept simple for Icarus Verilog 12 compatibility:
//   logic / packed structs / simple enums / parameters only.

package lob_pkg;

  // ---------------- configuration (frozen; see docs/01, docs/04) -----------
  // Price-grid mapping:  level_idx = (price - PRICE_BASE) >> TICK_SHIFT
  localparam int PRICE_BASE       = 0;
  localparam int TICK_SHIFT       = 0;
  localparam int MAX_ORDERS       = 8192;
  localparam int ADDR_W           = 13;   // clog2(MAX_ORDERS)
  localparam int NUM_PRICE_LEVELS = 4096;
  localparam int LEVEL_IDX_W      = 12;   // clog2(NUM_PRICE_LEVELS)
  localparam int HASH_BUCKETS     = 16384;
  localparam int BUCKET_ADDR_W    = 14;   // clog2(HASH_BUCKETS)
  localparam int HASH_WAYS        = 4;
  localparam int MAX_HASH_PROBE   = 8;    // sets, 4 buckets checked per set

  localparam logic [7:0] VERSION       = 8'h01;
  localparam logic [7:0] FLAG_EXTERNAL = 8'h01;

  // ---------------- enums --------------------------------------------------
  typedef enum logic [2:0] {
    ADD     = 3'd1,
    CANCEL  = 3'd2,
    MODIFY  = 3'd3,
    EXECUTE = 3'd4
  } msg_type_t;

  typedef enum logic {
    BUY  = 1'b0,
    SELL = 1'b1
  } side_t;

  typedef enum logic [2:0] {
    ACK_OK                 = 3'd0,
    ACK_REJECT_BAD_VERSION = 3'd1,
    ACK_REJECT_BAD_FIELD   = 3'd2,
    ACK_REJECT_NOT_LIVE    = 3'd3,
    ACK_REJECT_FULL        = 3'd4,
    ACK_REJECT_INTERNAL    = 3'd5
  } ack_status_t;

  // ---------------- records ------------------------------------------------
  // Decoded 32-byte wire message (field order == wire layout).
  typedef struct packed {
    logic [7:0]  version;
    msg_type_t   msg_type;
    side_t       side;
    logic [7:0]  flags;
    logic [31:0] seq_num;
    logic [63:0] order_id;
    logic [31:0] price;
    logic [31:0] quantity;
    logic [63:0] timestamp_ns;
  } msg_t;

  // Command passed to matcher / order_manager.
  typedef struct packed {
    msg_type_t   msg_type;
    side_t       side;
    logic [31:0] seq_num;
    logic [63:0] order_id;
    logic [31:0] price;
    logic [31:0] quantity;
    logic [63:0] timestamp_ns;
    logic [LEVEL_IDX_W-1:0] level_idx;
  } cmd_t;

  // Matched trade output.
  typedef struct packed {
    logic [63:0] buy_order_id;
    logic [63:0] sell_order_id;
    logic [31:0] price;
    logic [31:0] quantity;
    logic [63:0] timestamp_ns;
  } trade_t;

  // Per-command acknowledgement + status.
  typedef struct packed {
    ack_status_t     status;
    logic [63:0]     order_id;
    logic [31:0]     remaining_qty;
    logic [31:0]     best_bid;
    logic [31:0]     best_ask;
    logic [ADDR_W-1:0] num_orders;
  } ack_t;

  // Price level table entry (per side).
  typedef struct packed {
    logic [ADDR_W-1:0] head_ptr;
    logic [ADDR_W-1:0] tail_ptr;
    logic [15:0]       total_qty;
  } level_rec_t;

  // Order pool entry.
  typedef struct packed {
    logic              valid;
    side_t             side;
    logic [15:0]       price_q;
    logic [31:0]       quantity;
    logic [63:0]       timestamp_ns;
    logic [63:0]       order_id;
    logic [ADDR_W-1:0] next_ptr;
    logic [ADDR_W-1:0] prev_ptr;
  } order_rec_t;

  // ---------------- helpers ------------------------------------------------
  function automatic logic [LEVEL_IDX_W-1:0] price_to_level_idx(input logic [31:0] price);
    logic [31:0] p;
    p = (price - PRICE_BASE[31:0]) >> TICK_SHIFT;
    return p[LEVEL_IDX_W-1:0];
  endfunction

  function automatic logic price_in_range(input logic [31:0] price);
    logic [31:0] p;
    if (price < PRICE_BASE[31:0]) return 1'b0;
    p = (price - PRICE_BASE[31:0]) >> TICK_SHIFT;
    return (p < NUM_PRICE_LEVELS[31:0]);
  endfunction

endpackage
