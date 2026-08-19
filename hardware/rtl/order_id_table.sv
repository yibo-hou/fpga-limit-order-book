`timescale 1ns / 1ps
// order_id_table.sv - BRAM-backed 4-way set-associative order-id index.
//
// A hash selects the first set. Up to MAX_SET_PROBE consecutive sets are
// inspected, four buckets per BRAM row. Every inspected row is searched even
// after an empty bucket is seen, so deleting a bucket cannot break a probe
// chain and no tombstone state is required.
//
// INSERT scans the complete bounded probe window to reject duplicate IDs and
// remembers the first empty bucket. mgr_hit means the requested operation
// committed; mgr_miss means lookup/delete missed or insert could not commit.

module order_id_table #(
    parameter int BUCKETS       = 16384,
    parameter int WAYS          = 4,
    parameter int MAX_SET_PROBE = 8,
    parameter int ADDR_W        = 13
) (
    input  logic clk,
    input  logic rst_n,

    // manager: 0 lookup, 1 insert, 2 delete
    input  logic [1:0]          mgr_op,
    input  logic [63:0]         mgr_id,
    input  logic [ADDR_W-1:0]   mgr_slot,
    input  logic                mgr_valid,
    output logic                mgr_busy,
    output logic                mgr_done,
    output logic                mgr_hit,
    output logic                mgr_miss,
    output logic [ADDR_W-1:0]   mgr_hit_slot,

    // matcher uses the second request interface for delete only
    input  logic [63:0]         mat_id,
    input  logic                mat_valid,
    output logic                mat_busy,
    output logic                mat_done
);

  localparam logic [1:0] OP_LOOKUP = 2'd0;
  localparam logic [1:0] OP_INSERT = 2'd1;
  localparam logic [1:0] OP_DELETE = 2'd2;

  localparam int SETS       = BUCKETS / WAYS;
  localparam int SET_ADDR_W = $clog2(SETS);
  localparam int WAY_W      = (WAYS <= 1) ? 1 : $clog2(WAYS);
  localparam int PROBE_W    = (MAX_SET_PROBE <= 1) ? 1 :
                              $clog2(MAX_SET_PROBE);

  typedef struct packed {
    logic              valid;
    logic [63:0]       order_id;
    logic [ADDR_W-1:0] slot_ptr;
  } bucket_t;

  localparam int BUCKET_W = $bits(bucket_t);
  localparam int ROW_W    = WAYS * BUCKET_W;

  // A wide BRAM row contains all ways of one set, enabling four comparisons
  // after a single synchronous read.
  (* ram_style = "block" *) logic [ROW_W-1:0] mem [0:SETS-1];

  initial begin
    for (int set_idx = 0; set_idx < SETS; set_idx++) begin
      mem[set_idx] = '0;
    end
  end

  typedef enum logic [2:0] {S_IDLE, S_READ, S_EVAL, S_PREP, S_WRITE} state_t;
  state_t state;

  logic [1:0]            cur_op;
  logic [63:0]           cur_id;
  logic [ADDR_W-1:0]     cur_slot;
  logic                  cur_is_mat;
  logic [SET_ADDR_W-1:0] hash_base;
  logic [PROBE_W-1:0]    probe_idx;
  logic [SET_ADDR_W-1:0] read_set_q;
  logic [ROW_W-1:0]      row_q;

  logic                  first_empty_valid;
  logic [SET_ADDR_W-1:0] first_empty_set;
  logic [WAY_W-1:0]      first_empty_way;
  logic [ROW_W-1:0]      first_empty_row;

  logic [SET_ADDR_W-1:0] write_set_q;
  logic [ROW_W-1:0]      write_row_q;
  logic [ROW_W-1:0]      write_base_row_q;
  logic [WAY_W-1:0]      write_way_q;
  bucket_t               write_bucket_q;
  logic [ADDR_W-1:0]     write_result_slot_q;

  logic                  row_match;
  logic [WAY_W-1:0]      row_match_way;
  logic [ADDR_W-1:0]     row_match_slot;
  logic                  row_empty;
  logic [WAY_W-1:0]      row_empty_way;
  logic [WAYS-1:0]       row_way_valid;
  logic [63:0]           row_way_id [0:WAYS-1];
  logic [ADDR_W-1:0]     row_way_slot [0:WAYS-1];

  generate
    for (genvar way_gen = 0; way_gen < WAYS; way_gen++) begin : g_unpack_row
      assign {row_way_valid[way_gen], row_way_id[way_gen],
              row_way_slot[way_gen]} =
          row_q[way_gen * BUCKET_W +: BUCKET_W];
    end
  endgenerate

  logic [SET_ADDR_W-1:0] probe_set;
  assign probe_set = hash_base + SET_ADDR_W'(probe_idx);

  // Fold all 64 ID bits into a set address after a small xor-shift mix. The
  // function is combinational and contains no multiplier or divider.
  function automatic logic [SET_ADDR_W-1:0] hash64(input logic [63:0] id);
    logic [63:0] mixed;
    logic [SET_ADDR_W-1:0] hash_value;
    // Do not shift by SET_ADDR_W here: folding modulo SET_ADDR_W would make
    // the shifted copy cancel the original for small sequential IDs.
    mixed = id ^ (id >> 17) ^ (id >> 41);
    hash_value = '0;
    for (int bit_idx = 0; bit_idx < 64; bit_idx++) begin
      hash_value[bit_idx % SET_ADDR_W] =
          hash_value[bit_idx % SET_ADDR_W] ^ mixed[bit_idx];
    end
    return hash_value;
  endfunction

  function automatic logic [ROW_W-1:0] replace_bucket(
      input logic [ROW_W-1:0] source_row,
      input logic [WAY_W-1:0] way,
      input bucket_t value);
    logic [ROW_W-1:0] result;
    result = source_row;
    result[way * BUCKET_W +: BUCKET_W] = value;
    return result;
  endfunction

  // Four-way parallel comparison and first-empty selection for the current
  // BRAM row. Priority is lowest-numbered way.
  always_comb begin
    row_match      = 1'b0;
    row_match_way  = '0;
    row_match_slot = '0;
    row_empty      = 1'b0;
    row_empty_way  = '0;
    for (int way_idx = 0; way_idx < WAYS; way_idx++) begin
      if (!row_match && row_way_valid[way_idx] &&
          row_way_id[way_idx] == cur_id) begin
        row_match      = 1'b1;
        row_match_way  = WAY_W'(way_idx);
        row_match_slot = row_way_slot[way_idx];
      end
      if (!row_empty && !row_way_valid[way_idx]) begin
        row_empty     = 1'b1;
        row_empty_way = WAY_W'(way_idx);
      end
    end
  end

  // One BRAM port is sufficient because requests are serialized. A set read
  // and a row write never occur in the same FSM state.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      row_q      <= '0;
      read_set_q <= '0;
    end else begin
      if (state == S_READ) begin
        row_q      <= mem[probe_set];
        read_set_q <= probe_set;
      end else if (state == S_WRITE) begin
        mem[write_set_q] <= write_row_q;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state                <= S_IDLE;
      cur_op               <= OP_LOOKUP;
      cur_id               <= '0;
      cur_slot             <= '0;
      cur_is_mat           <= 1'b0;
      hash_base            <= '0;
      probe_idx            <= '0;
      first_empty_valid    <= 1'b0;
      first_empty_set      <= '0;
      first_empty_way      <= '0;
      first_empty_row      <= '0;
      write_set_q          <= '0;
      write_row_q          <= '0;
      write_base_row_q     <= '0;
      write_way_q          <= '0;
      write_bucket_q       <= '0;
      write_result_slot_q  <= '0;
      mgr_done             <= 1'b0;
      mgr_hit              <= 1'b0;
      mgr_miss             <= 1'b0;
      mgr_hit_slot         <= '0;
      mat_done             <= 1'b0;
    end else begin
      mgr_done <= 1'b0;
      mat_done <= 1'b0;

      case (state)
        S_IDLE: begin
          if (mgr_valid) begin
            cur_op            <= mgr_op;
            cur_id            <= mgr_id;
            cur_slot          <= mgr_slot;
            cur_is_mat        <= 1'b0;
            hash_base         <= hash64(mgr_id);
            probe_idx         <= '0;
            first_empty_valid <= 1'b0;
            mgr_hit           <= 1'b0;
            mgr_miss          <= 1'b0;
            state             <= S_READ;
          end else if (mat_valid) begin
            cur_op            <= OP_DELETE;
            cur_id            <= mat_id;
            cur_slot          <= '0;
            cur_is_mat        <= 1'b1;
            hash_base         <= hash64(mat_id);
            probe_idx         <= '0;
            first_empty_valid <= 1'b0;
            state             <= S_READ;
          end
        end

        S_READ: state <= S_EVAL;

        S_EVAL: begin
          if (row_match) begin
            if (cur_op == OP_LOOKUP) begin
              mgr_hit      <= 1'b1;
              mgr_miss     <= 1'b0;
              mgr_hit_slot <= row_match_slot;
              mgr_done     <= 1'b1;
              state        <= S_IDLE;
            end else if (cur_op == OP_INSERT) begin
              // Duplicate ID: insertion did not commit. The manager returns
              // its reserved pool slot through the rollback path.
              mgr_hit  <= 1'b0;
              mgr_miss <= 1'b1;
              mgr_done <= 1'b1;
              state    <= S_IDLE;
            end else begin
              write_set_q         <= read_set_q;
              write_base_row_q    <= row_q;
              write_way_q         <= row_match_way;
              write_bucket_q      <= '0;
              write_result_slot_q <= row_match_slot;
              state               <= S_PREP;
            end
          end else begin
            if (cur_op == OP_INSERT && !first_empty_valid && row_empty) begin
              first_empty_valid <= 1'b1;
              first_empty_set   <= read_set_q;
              first_empty_way   <= row_empty_way;
              first_empty_row   <= row_q;
            end

            if (probe_idx == PROBE_W'(MAX_SET_PROBE - 1)) begin
              if (cur_op == OP_INSERT &&
                  (first_empty_valid || row_empty)) begin
                write_set_q <= first_empty_valid ? first_empty_set
                                                 : read_set_q;
                write_base_row_q <= first_empty_valid ? first_empty_row
                                                      : row_q;
                write_way_q <= first_empty_valid ? first_empty_way
                                                  : row_empty_way;
                write_bucket_q <= bucket_t'({1'b1, cur_id, cur_slot});
                write_result_slot_q <= cur_slot;
                state <= S_PREP;
              end else begin
                if (cur_is_mat) begin
                  mat_done <= 1'b1;
                end else begin
                  mgr_hit  <= 1'b0;
                  mgr_miss <= 1'b1;
                  mgr_done <= 1'b1;
                end
                state <= S_IDLE;
              end
            end else begin
              probe_idx <= probe_idx + 1'b1;
              state     <= S_READ;
            end
          end
        end

        // Keep the four-way compare/priority path out of the wide row-update
        // mux.  This extra registered hash beat removes the former BRAM ->
        // compare -> 312-bit replace critical path at 125 MHz.
        S_PREP: begin
          write_row_q <= replace_bucket(write_base_row_q, write_way_q,
                                        write_bucket_q);
          state <= S_WRITE;
        end

        S_WRITE: begin
          if (cur_is_mat) begin
            mat_done <= 1'b1;
          end else begin
            mgr_hit      <= 1'b1;
            mgr_miss     <= 1'b0;
            mgr_hit_slot <= write_result_slot_q;
            mgr_done     <= 1'b1;
          end
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  assign mgr_busy = (state != S_IDLE);
  assign mat_busy = (state != S_IDLE);

endmodule
