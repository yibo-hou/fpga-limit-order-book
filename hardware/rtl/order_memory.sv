`timescale 1ns / 1ps
import lob_pkg::*;
// order_memory.sv - order pool (BRAM) + free-list stack.
//
// The pool is a true-dual-port synchronous RAM of order_rec_t (198 bits),
// addressed by slot index.  Slot 0 is reserved as the null pointer, so
// usable slots are 1 .. MAX_ORDERS-1 (MAX_ORDERS-1 live orders).
//
// The free list is a LIFO stack of free slot indices.  In a real part it is
// a 1 x 18Kb BRAM; here it is a simple RAM with a synchronous read so it
// behaves like the rest of the design.  A short init FSM fills it with
// slots 1..MAX_ORDERS-1 after reset (synthesizable).
//
// Two access pairs are exposed (port A = matcher, port B = order_manager).
// The design is serialized (one command at a time) so A and B never contend.

module order_memory #(
    parameter int MAX_ORDERS = 8192,
    parameter int ADDR_W     = 13
) (
    input  logic clk,
    input  logic rst_n,

    // ---------------- port A (matcher) ----------------
    input  logic [ADDR_W-1:0] addr_a,
    input  logic              we_a,
    input  logic              re_a,
    input  order_rec_t        wdata_a,
    output order_rec_t        rdata_a,

    input  logic              free_alloc_a,          // pop a free slot (A)
    output logic [ADDR_W-1:0] free_slot_a,
    output logic              free_empty_a,
    input  logic              free_push_a,           // return a slot (A)
    input  logic [ADDR_W-1:0] free_push_slot_a,

    // ---------------- port B (order_manager) ----------------
    input  logic [ADDR_W-1:0] addr_b,
    input  logic              we_b,
    input  logic              re_b,
    input  order_rec_t        wdata_b,
    output order_rec_t        rdata_b,

    input  logic              free_alloc_b,
    output logic [ADDR_W-1:0] free_slot_b,
    output logic              free_empty_b,
    input  logic              free_push_b,
    input  logic [ADDR_W-1:0] free_push_slot_b,

    // ---------------- status ----------------
    output logic [ADDR_W-1:0] num_orders,
    output logic              init_done
);

  localparam int FREE_CNT_W = $clog2(MAX_ORDERS);

  // ---------------- pool (true dual port) ----------------
  localparam int ORDER_W = $bits(order_rec_t);
  logic [ORDER_W-1:0] mem [0:MAX_ORDERS-1];

  // Zero-initialize so every slot starts invalid (BRAM INIT in the FPGA).
  initial begin
    for (int i = 0; i < MAX_ORDERS; i++) begin
      mem[i] = '0;
    end
  end

  always_ff @(posedge clk) begin
    if (re_a) rdata_a <= order_rec_t'(mem[addr_a]);
    if (we_a) mem[addr_a] <= wdata_a;
  end

  always_ff @(posedge clk) begin
    if (re_b) rdata_b <= order_rec_t'(mem[addr_b]);
    if (we_b) mem[addr_b] <= wdata_b;
  end

  // ---------------- free list ----------------
  (* ram_style = "block" *) logic [ADDR_W-1:0] free_mem [0:MAX_ORDERS-1];
  logic [FREE_CNT_W:0] free_top;          // number of free slots (0..MAX_ORDERS-1)
  logic [ADDR_W-1:0] free_slot_a_q, free_slot_b_q;
  logic [ADDR_W-1:0] init_cnt;

  logic free_empty;
  logic do_alloc_a, do_alloc_b, do_push_a, do_push_b;

  assign do_alloc_a = init_done && free_alloc_a && (free_top != '0);
  assign do_alloc_b = init_done && free_alloc_b && (free_top != '0) && !free_alloc_a;
  assign do_push_a  = init_done && free_push_a;
  assign do_push_b  = init_done && free_push_b;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      free_top    <= '0;
      init_cnt    <= 1;                      // first slot to enqueue = 1
      init_done   <= 1'b0;
      free_slot_a_q <= '0;
      free_slot_b_q <= '0;
    end else if (!init_done) begin
      // init FSM: free_mem[i-1] = i for i = 1..MAX_ORDERS-1
      free_mem[init_cnt - 1] <= init_cnt;
      free_top               <= init_cnt;   // zero-extends to FREE_CNT_W+1
      if (init_cnt == (MAX_ORDERS - 1)) begin
        init_done <= 1'b1;
      end else begin
        init_cnt <= init_cnt + 1'b1;
      end
    end else begin
      if (do_alloc_a) begin
        free_slot_a_q <= free_mem[free_top - 1];
        free_top      <= free_top - 1'b1;
      end else if (do_alloc_b) begin
        free_slot_b_q <= free_mem[free_top - 1];
        free_top      <= free_top - 1'b1;
      end
      // pushes (a push never happens in the same cycle as an alloc in this
      // serialized design; pushes are applied after the alloc above)
      if (do_push_a) begin
        free_mem[free_top] <= free_push_slot_a;
        free_top           <= free_top + 1'b1;
      end
      if (do_push_b) begin
        free_mem[free_top] <= free_push_slot_b;
        free_top           <= free_top + 1'b1;
      end
    end
  end

  assign free_empty    = (free_top == '0);
  assign free_empty_a  = free_empty;
  assign free_empty_b  = free_empty;
  assign free_slot_a   = free_slot_a_q;
  assign free_slot_b   = free_slot_b_q;
  assign num_orders    = init_done ?
                         ADDR_W'(MAX_ORDERS - 1) - free_top[ADDR_W-1:0] :
                         '0;

endmodule
