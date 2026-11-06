// ==============================================================================
// SVA checker for the RVX core (rvx_core)
// ==============================================================================
// Bound into rvx_core (see bind at the end of this file), so it can observe
// internal signals without touching the DUT RTL.
//
// Covers: M-mode traps (exceptions and interrupts), CSRs and counters, the
// memory bus protocol, x0 and absence of deadlock.
//
// Reference: RISC-V Privileged Architecture Specification, section 3.1
// (mstatus, mie/mip, mepc, mcause, mtval, counters) and the RV32I base ISA.
// ==============================================================================

module rvx_core_sva (
  input logic         clock,
  input logic         reset,
  input logic         reset_internal,
  input logic         clock_enable,
  input logic         halt,
  input logic [3:0]   current_state,

  // Memory bus
  input logic [31:0]  rw_address,
  input logic         read_request,
  input logic         read_response,
  input logic         write_request,
  input logic         write_response,
  input logic [31:0]  write_data,
  input logic [3:0]   write_strobe,

  // Interrupts
  input logic         irq_external,
  input logic         irq_timer,
  input logic         irq_software,
  input logic [15:0]  irq_fast,
  input logic         interrupt_pending,
  input logic         csr_mstatus_mie,
  input logic         csr_mstatus_mpie,
  input logic [31:0]  csr_mie,
  input logic [31:0]  csr_mip,

  // Decode
  input logic [31:0]  instruction,
  input logic [11:0]  instruction_csr_address,
  input logic [4:0]   instruction_rs1_address,
  input logic [4:0]   instruction_rs2_address,
  input logic [31:0]  rs1_data,
  input logic [31:0]  rs2_data,
  input logic         load,
  input logic         store,
  input logic         csrxxx,
  input logic         csr_file_write_enable,

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
  input logic         csr_mcause_interrupt_flag,
  input logic [63:0]  csr_minstret,
  input logic [63:0]  csr_mcycle
);

  // Encoding copied from rvx_core localparams
  localparam logic [3:0]  STATE_OPERATING   = 4'b0010;
  localparam logic [3:0]  STATE_TRAP_TAKEN  = 4'b0100;
  localparam logic [3:0]  STATE_TRAP_RETURN = 4'b1000;
  localparam logic [11:0] MCYCLE            = 12'hB00;
  localparam logic [11:0] MCYCLEH           = 12'hB80;

  default clocking cb @(posedge clock); endclocking
  default disable iff (reset_internal);

  // ----------------------------------------------------------------------------
  // Environment assumptions
  // ----------------------------------------------------------------------------
  // Interrupt inputs are free. The fairness assumptions below only constrain
  // the liveness property (ast_live_progress): the memory eventually answers
  // every request and the core is not halted forever. Safety properties are
  // proven for any memory latency, including one that never answers.

  asm_fair_read: assume property (
    read_request |-> s_eventually (read_response && !halt)
  );

  asm_fair_write: assume property (
    write_request |-> s_eventually (write_response && !halt)
  );

  asm_fair_halt: assume property (
    s_eventually !halt
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

  // Synchronous trap sources. rvx_core gives them priority over interrupts in
  // mcause, so a trap with any of them pending is an exception trap.
  logic sync_trap;
  assign sync_trap = exception_pending || ecall || ebreak;

  // A synchronous trap raised by the instruction currently in the execute stage
  logic exc_taken;
  assign exc_taken =
    clock_enable && current_state == STATE_OPERATING && take_trap && sync_trap &&
    !load_commit_cycle && !store_commit_cycle;

  // An interrupt taken on the instruction currently in the execute stage
  logic irq_taken;
  assign irq_taken =
    clock_enable && current_state == STATE_OPERATING && take_trap && !sync_trap &&
    !load_commit_cycle && !store_commit_cycle;

  // Address of the instruction interrupted by the last irq_taken
  logic [31:0] irq_pc;

  always_ff @(posedge clock) begin
    if (reset_internal)
      irq_pc <= '0;
    else if (irq_taken)
      irq_pc <= exec_pc;
  end

  // First cycle of the trap handler (first enabled OPERATING cycle)
  logic handler_start;
  assign handler_start = clock_enable && current_state == STATE_OPERATING;

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
  // Interrupts
  // ----------------------------------------------------------------------------

  // An interrupt is only taken when globally enabled (mstatus.MIE) and some
  // interrupt is both enabled in mie and pending in mip
  ast_irq_requires_enable: assert property (
    irq_taken |-> csr_mstatus_mie && (csr_mie & csr_mip) != '0
  );

  // Interrupt traps set mcause[31] (written in the TRAP_TAKEN cycle)
  ast_irq_mcause_flag: assert property (
    irq_taken |=> (clock_enable [->1]) ##1 csr_mcause[31]
  );

  // Trap entry: MPIE <- MIE, MIE <- 0
  ast_trap_entry_mstatus: assert property (
    current_state == STATE_TRAP_TAKEN && clock_enable
    |=> !csr_mstatus_mie && csr_mstatus_mpie == $past(csr_mstatus_mie)
  );

  // mret: MIE <- MPIE, MPIE <- 1
  ast_mret_mstatus: assert property (
    current_state == STATE_TRAP_RETURN && clock_enable
    |=> csr_mstatus_mie == $past(csr_mstatus_mpie) && csr_mstatus_mpie
  );

  // mepc is written once per trap: nothing may overwrite it while the core
  // is entering the handler
  ast_mepc_stable_on_trap_entry: assert property (
    current_state == STATE_TRAP_TAKEN |=> csr_mepc == $past(csr_mepc)
  );

  // rvx_core blocks the memory request of an interrupted load/store, so the
  // instruction did not execute and mret must replay it: mepc = its address
  ast_irq_replays_load_store: assert property (
    irq_taken && (load || store)
    |=> (handler_start [->1]) ##0 csr_mepc == irq_pc
  );

  // If the interrupted instruction already wrote rd, replaying it after mret
  // would execute it twice: mepc must not point to it
  ast_irq_no_double_execution: assert property (
    irq_taken && rd_write
    |=> (handler_start [->1]) ##0 csr_mepc != irq_pc
  );

  // ----------------------------------------------------------------------------
  // Memory bus protocol
  // ----------------------------------------------------------------------------

  ast_bus_no_read_and_write: assert property (
    !(read_request && write_request)
  );

  // A read request is held, with the same address, until the response arrives
  ast_bus_read_hold: assert property (
    (clock_enable && read_request) ##1 !read_response
    |-> read_request && $stable(rw_address)
  );

  // A write request is held, with the same address/data/strobe, until the
  // response arrives
  ast_bus_write_hold: assert property (
    (clock_enable && write_request) ##1 !write_response
    |-> write_request && $stable(rw_address) && $stable(write_data) && $stable(write_strobe)
  );

  ast_bus_write_strobe: assert property (
    write_request |-> write_strobe != 4'b0000
  );

  // The bus is word addressed: every access uses a word-aligned address
  ast_bus_word_aligned: assert property (
    (read_request || write_request) |-> rw_address[1:0] == 2'b00
  );

  // ----------------------------------------------------------------------------
  // x0 is hardwired to zero
  // ----------------------------------------------------------------------------

  ast_x0_rs1_zero: assert property (
    instruction_rs1_address == 5'd0 |-> rs1_data == '0
  );

  ast_x0_rs2_zero: assert property (
    instruction_rs2_address == 5'd0 |-> rs2_data == '0
  );

  // ----------------------------------------------------------------------------
  // CSRs and counters
  // ----------------------------------------------------------------------------

  logic mcycle_write;
  assign mcycle_write =
    clock_enable && csr_file_write_enable &&
    (instruction_csr_address == MCYCLE || instruction_csr_address == MCYCLEH);

  // mcycle counts every clock cycle (unless software writes it)
  ast_mcycle_increments: assert property (
    !mcycle_write |=> csr_mcycle == $past(csr_mcycle) + 64'd1
  );

  // A load/store waiting for the memory has not retired yet: minstret must
  // not count it in the waiting cycle (it is counted when it completes)
  ast_minstret_no_count_while_waiting: assert property (
    clock_enable && current_state == STATE_OPERATING &&
    (load_pending || store_pending) && !take_trap
    |=> csr_minstret == $past(csr_minstret)
  );

  // Writing a read-only CSR (address bits [11:10] == 2'b11) must raise an
  // illegal instruction exception. CSRRW/CSRRWI always write; CSRRS/CSRRC and
  // their immediate forms write only when rs1/uimm is not zero.
  logic csr_is_write;
  assign csr_is_write = instruction[13:12] == 2'b01 || instruction[19:15] != 5'd0;

  ast_ro_csr_write_illegal: assert property (
    csrxxx && instruction_csr_address[11:10] == 2'b11 && csr_is_write
    |-> illegal_instruction
  );

  // ----------------------------------------------------------------------------
  // Absence of deadlock (liveness)
  // ----------------------------------------------------------------------------
  // Under the fairness assumptions above, the core always eventually completes
  // or traps an instruction.
  // A trap counts as progress, so this detects deadlock, not livelock.

  ast_live_progress: assert property (
    s_eventually (clock_enable && current_state == STATE_OPERATING &&
                 ((!load_pending && !store_pending) || take_trap))
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
  cov_irq_taken:             cover property (irq_taken);
  cov_irq_on_load_store:     cover property (irq_taken && (load || store));
  cov_irq_then_mret:         cover property (
    irq_taken ##[1:$] (current_state == STATE_OPERATING && mret && clock_enable)
  );
  cov_read_wait_state:       cover property (
    (clock_enable && read_request) ##1 !read_response
  );
  cov_write_wait_state:      cover property (
    (clock_enable && write_request) ##1 !write_response
  );

endmodule

bind rvx_core rvx_core_sva u_rvx_core_sva (.*);
