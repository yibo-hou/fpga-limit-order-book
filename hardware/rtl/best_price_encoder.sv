`timescale 1ns / 1ps
import lob_pkg::*;
// best_price_encoder.sv - occupancy bitmap + best bid/ask registers.
//
// One occupancy bit per price level per side (distributed LUTRAM).  best_bid
// / best_ask are held in registers and refreshed when the current best level
// empties (scan) or a better level appears (compare on set).  This gives O(1)
// top-of-book reads every cycle, with a bounded refresh latency that only
// occurs on level-empty events.

module best_price_encoder #(
    parameter int NUM_PRICE_LEVELS = 4096,
    parameter int LEVEL_IDX_W      = 12
) (
    input  logic clk,
    input  logic rst_n,

    // level became occupied
    input  logic              set_valid,
    input  side_t             set_side,
    input  logic [LEVEL_IDX_W-1:0] set_idx,

    // level became empty
    input  logic              clear_valid,
    input  side_t             clear_side,
    input  logic [LEVEL_IDX_W-1:0] clear_idx,

    output logic [LEVEL_IDX_W-1:0] best_bid,
    output logic              best_bid_valid,
    output logic [LEVEL_IDX_W-1:0] best_ask,
    output logic              best_ask_valid,

    output logic              refresh_busy,
    output logic              init_done
);

  logic occ_bid [NUM_PRICE_LEVELS];
  logic occ_ask [NUM_PRICE_LEVELS];

  logic [LEVEL_IDX_W-1:0] best_bid_q, best_ask_q;
  logic best_bid_v_q, best_ask_v_q;

  logic bid_refresh_busy_q, ask_refresh_busy_q;
  logic [LEVEL_IDX_W-1:0] bid_scan_idx, ask_scan_idx;
  logic [LEVEL_IDX_W-1:0] init_idx;
  logic init_done_q;

  // One write port per side lets Vivado infer compact LUTRAM. Reset clearing
  // is serialized over NUM_PRICE_LEVELS cycles instead of expanding both
  // bitmaps into thousands of resettable flip-flops.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (!init_done_q) begin
        occ_bid[init_idx] <= 1'b0;
      end else if (set_valid && set_side == BUY) begin
        occ_bid[set_idx] <= 1'b1;
      end else if (clear_valid && clear_side == BUY) begin
        occ_bid[clear_idx] <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (!init_done_q) begin
        occ_ask[init_idx] <= 1'b0;
      end else if (set_valid && set_side == SELL) begin
        occ_ask[set_idx] <= 1'b1;
      end else if (clear_valid && clear_side == SELL) begin
        occ_ask[clear_idx] <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      best_bid_q     <= '0;
      best_ask_q     <= '0;
      best_bid_v_q   <= 1'b0;
      best_ask_v_q   <= 1'b0;
      bid_refresh_busy_q <= 1'b0;
      ask_refresh_busy_q <= 1'b0;
      bid_scan_idx       <= '0;
      ask_scan_idx       <= '0;
      init_idx           <= '0;
      init_done_q        <= 1'b0;
    end else if (!init_done_q) begin
      if (init_idx == (NUM_PRICE_LEVELS - 1)) begin
        init_done_q <= 1'b1;
      end else begin
        init_idx <= init_idx + 1'b1;
      end
    end else begin
      // Bid and ask refresh independently. A trade can empty both heads on
      // adjacent cycles, so a single shared scanner would drop the second
      // clear while the first side was refreshing.
      if (bid_refresh_busy_q) begin
        // A MODIFY can reinsert above the range currently being scanned.
        // Capture that new level immediately; otherwise the descending scan
        // would never visit it. Equality also matters because occ_bid still
        // has its pre-set value in this clock edge.
        if (set_valid && set_side == BUY && set_idx >= bid_scan_idx) begin
          best_bid_q         <= set_idx;
          best_bid_v_q       <= 1'b1;
          bid_refresh_busy_q <= 1'b0;
        end else if (occ_bid[bid_scan_idx]) begin
          best_bid_q         <= bid_scan_idx;
          best_bid_v_q       <= 1'b1;
          bid_refresh_busy_q <= 1'b0;
        end else if (bid_scan_idx == '0) begin
          bid_refresh_busy_q <= 1'b0;
        end else begin
          bid_scan_idx <= bid_scan_idx - 1'b1;
        end
      end else begin
        if (set_valid && set_side == BUY) begin
          // level went empty -> occupied
          if (!best_bid_v_q || (set_idx > best_bid_q)) begin
            best_bid_q   <= set_idx;
            best_bid_v_q <= 1'b1;
          end
        end
        if (clear_valid && clear_side == BUY) begin
          // level went occupied -> empty
          if (best_bid_v_q && (clear_idx == best_bid_q)) begin
            bid_refresh_busy_q <= 1'b1;
            bid_scan_idx       <= (clear_idx == '0) ? '0 : clear_idx - 1'b1;
            best_bid_v_q       <= 1'b0;
          end
        end
      end

      if (ask_refresh_busy_q) begin
        if (set_valid && set_side == SELL && set_idx <= ask_scan_idx) begin
          best_ask_q         <= set_idx;
          best_ask_v_q       <= 1'b1;
          ask_refresh_busy_q <= 1'b0;
        end else if (occ_ask[ask_scan_idx]) begin
          best_ask_q         <= ask_scan_idx;
          best_ask_v_q       <= 1'b1;
          ask_refresh_busy_q <= 1'b0;
        end else if (ask_scan_idx == (NUM_PRICE_LEVELS - 1)) begin
          ask_refresh_busy_q <= 1'b0;
        end else begin
          ask_scan_idx <= ask_scan_idx + 1'b1;
        end
      end else begin
        if (set_valid && set_side == SELL) begin
          if (!best_ask_v_q || (set_idx < best_ask_q)) begin
            best_ask_q   <= set_idx;
            best_ask_v_q <= 1'b1;
          end
        end
        if (clear_valid && clear_side == SELL) begin
          if (best_ask_v_q && (clear_idx == best_ask_q)) begin
            ask_refresh_busy_q <= 1'b1;
            ask_scan_idx       <= (clear_idx == (NUM_PRICE_LEVELS-1)) ?
                                  (NUM_PRICE_LEVELS-1) : clear_idx + 1'b1;
            best_ask_v_q       <= 1'b0;
          end
        end
      end
    end
  end

  assign best_bid       = best_bid_q;
  assign best_bid_valid = best_bid_v_q;
  assign best_ask       = best_ask_q;
  assign best_ask_valid = best_ask_v_q;
  assign refresh_busy   = !init_done_q || bid_refresh_busy_q || ask_refresh_busy_q;
  assign init_done      = init_done_q;

endmodule
