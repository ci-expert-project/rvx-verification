// ==============================================================================
// SVA checker for the RVX core (rvx_core) - M-mode trap behaviour
// ==============================================================================
// Bound into rvx_core (see bind at the end of this file), so it can observe
// internal signals without touching the DUT RTL.
//
// Reference: RISC-V Privileged Architecture Specification, section 3.1
// (mepc, mcause, mtval) and the RV32I base ISA (traps must not retire).
// ==============================================================================

module rvx_core_sva (
  input logic         clock,
  input logic         reset,
  input logic         reset_internal,
  input logic         clock_enable,
  input logic [3:0]   current_state,

  // Interrupt inputs (constrained below)
  input logic         irq_external,
  input logic         irq_timer,
  input logic         irq_software,
  input logic [15:0]  irq_fast,

  // Fetch / PC
  input logic [31:0]  instruction_address,
  input logic [31:0]  program_counter,
  input logic [31:0]  trap_address,
  input logic         load_commit_cycle,
  input logic         store_commit_cycle,
  input logic         load_pending,
  input logic         store_pending,

  // Trap sources
  input logic         take_trap,
  input logic         exception_pending,
  input logic         illegal_instruction,
  input logic         misaligned_instruction_address,
  input logic         misaligned_load,
  input logic         misaligned_store,
  input logic         ecall,
  input logic         ebreak,
  input logic         mret,
  input logic [31:0]  target_address_adder,

  // Architectural side effects
  input logic         integer_file_write_enable,
  input logic [4:0]   instruction_rd_address,
  input logic [31:0]  csr_mepc,
  input logic [31:0]  csr_mcause,
  input logic [31:0]  csr_mtval,
  input logic [63:0] csr_minstret
);

  // Encoding copied from rvx_core localparams
  localparam logic [3:0] STATE_OPERATING   = 4'b0010;
  localparam logic [3:0] STATE_TRAP_TAKEN  = 4'b0100;
  localparam logic [3:0] STATE_TRAP_RETURN = 4'b1000;

  default clocking cb @(posedge clock); endclocking
  default disable iff (reset_internal);

  // ----------------------------------------------------------------------------
  // Environment assumptions
  // ----------------------------------------------------------------------------
  // This first checker targets synchronous exceptions only. Interrupts are tied
  // off so that a counterexample always points to an exception path.

  asm_no_irq: assume property (
    !irq_external && !irq_timer && !irq_software && irq_fast == '0
  );

  // ----------------------------------------------------------------------------
  // Reference model: address of the instruction being executed
  // ----------------------------------------------------------------------------
  // The instruction word executed in cycle T is the memory response to the
  // address fetched in the last enabled cycle before T. During load/store commit
  // cycles the core replays the previous instruction, so those are excluded.

  logic [31:0] exec_pc;

  always_ff @(posedge clock) begin
    if (reset_internal)
      exec_pc <= '0;
    else if (clock_enable)
      exec_pc <= instruction_address;
  end

  // A synchronous trap raised by the instruction currently in the execute stage
  // (exceptions + ecall/ebreak; interrupts are tied off above)
  logic exc_taken;
  assign exc_taken =
    clock_enable && current_state == STATE_OPERATING && take_trap &&
    !load_commit_cycle && !store_commit_cycle;

  logic fetch_misaligned_only;
  assign fetch_misaligned_only =
    misaligned_instruction_address && !illegal_instruction;

  // ----------------------------------------------------------------------------
  // mepc
  // ----------------------------------------------------------------------------

  // mepc must hold the address of the instruction that raised the exception
  ast_mepc_is_faulting_pc: assert property (
    exc_taken |=> csr_mepc == $past(exec_pc)
  );

  // Same check, restricted to the failing misalign-* tests (JAL/JALR/branches)
  ast_mepc_misaligned_fetch: assert property (
    exc_taken && fetch_misaligned_only |=> csr_mepc == $past(exec_pc)
  );

  // IALIGN=32: mepc[1:0] must always read as zero
  ast_mepc_aligned: assert property (
    csr_mepc[1:0] == 2'b00
  );

  // ----------------------------------------------------------------------------
  // mcause / mtval for instruction-address-misaligned
  // ----------------------------------------------------------------------------

  // mcause is written in the TRAP_TAKEN cycle, i.e. on the next enabled clock
  ast_mcause_misaligned_fetch: assert property (
    exc_taken && fetch_misaligned_only
    |=> (clock_enable [->1]) ##1 csr_mcause == 32'h0000_0000
  );

  // mtval must hold the (halfword-aligned) misaligned target address
  ast_mtval_misaligned_fetch: assert property (
    exc_taken && fetch_misaligned_only
    |=> csr_mtval == $past({target_address_adder[31:1], 1'b0})
  );

  // ----------------------------------------------------------------------------
  // Trapping instruction must not retire
  // ----------------------------------------------------------------------------

  // Architectural register write (x0 is hardwired to zero, so writes to it
  // have no visible effect and are not a violation)
  logic rd_write;
  assign rd_write = integer_file_write_enable && instruction_rd_address != 5'd0;

  // No register file write in the cycle an exception is taken.
  // Split per cause so a failure points directly at the offending instruction.
  ast_no_rd_write_on_exception: assert property (
    exc_taken |-> !rd_write
  );

  // JAL/JALR with a misaligned target must not update rd
  ast_no_rd_write_misaligned_fetch: assert property (
    exc_taken && fetch_misaligned_only |-> !rd_write
  );

  ast_no_rd_write_illegal: assert property (
    exc_taken && illegal_instruction |-> !rd_write
  );

  ast_no_rd_write_misaligned_load: assert property (
    exc_taken && misaligned_load |-> !rd_write
  );

  // Machine Instructions Retired
  ast_minstret_no_count_on_trap: assert property (
    exc_taken |=> csr_minstret == $past(csr_minstret)
  );

  // ----------------------------------------------------------------------------
  // Control flow
  // ----------------------------------------------------------------------------

  // After a trap is taken, the next instruction comes from the trap vector
  ast_pc_to_trap_vector: assert property (
    current_state == STATE_TRAP_TAKEN && clock_enable && !load_pending && !store_pending
    |=> program_counter == $past(trap_address)
  );

  // mret resumes at mepc
  ast_mret_to_mepc: assert property (
    current_state == STATE_TRAP_RETURN && clock_enable && !load_pending && !store_pending
    |=> program_counter == $past(csr_mepc)
  );

  // ----------------------------------------------------------------------------
  // Covers - make sure the scenarios above are reachable (not vacuous)
  // ----------------------------------------------------------------------------

  cov_misaligned_fetch_trap: cover property (exc_taken && fetch_misaligned_only);
  cov_ecall_trap:            cover property (exc_taken && ecall);
  cov_ebreak_trap:           cover property (exc_taken && ebreak);
  cov_misaligned_load_trap:  cover property (exc_taken && misaligned_load);
  cov_misaligned_store_trap: cover property (exc_taken && misaligned_store);
  cov_trap_then_mret:        cover property (
    exc_taken ##[1:$] (current_state == STATE_OPERATING && mret && clock_enable)
  );

endmodule

bind rvx_core rvx_core_sva u_rvx_core_sva (.*);
