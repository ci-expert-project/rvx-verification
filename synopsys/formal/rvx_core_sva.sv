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
  input logic [63:0]  csr_mcycle,

  // Data paths used by the CSR and ISA reference checks
  input logic [31:0]  read_data,
  input logic [31:0]  writeback_multiplexer_output,
  input logic [31:0]  csr_data_out,
  input logic [31:0]  csr_write_data,
  input logic [31:0]  csr_mscratch,
  input logic [63:0]  real_time_clock
);

  // Encoding copied from rvx_core localparams
  localparam logic [3:0]  STATE_OPERATING   = 4'b0010;
  localparam logic [3:0]  STATE_TRAP_TAKEN  = 4'b0100;
  localparam logic [3:0]  STATE_TRAP_RETURN = 4'b1000;
  localparam logic [11:0] MCYCLE            = 12'hB00;
  localparam logic [11:0] MCYCLEH           = 12'hB80;
  localparam logic [11:0] MSCRATCH          = 12'h340;
  localparam logic [11:0] MINSTRET          = 12'hB02;
  localparam logic [11:0] MINSTRETH         = 12'hB82;

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

  // Optional: hide the known Bug 4 so it does not mask other results.
  // Bug 4: the state register advances with clock_enable | interrupt_pending,
  // so a pending interrupt while the core is stalled in TRAP_TAKEN/TRAP_RETURN
  // skips the trap entry/return actions (PC, mcause, mstatus). This assumption
  // removes that scenario. Enable with VCF_ASSUME_BUG4_FIXED=1; off by default,
  // so the regular report keeps showing the real bug.
`ifdef ASSUME_BUG4_FIXED
  asm_bug4_fixed: assume property (
    !clock_enable &&
    (current_state == STATE_TRAP_TAKEN || current_state == STATE_TRAP_RETURN)
    |-> !interrupt_pending
  );
`endif

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

  // Every access that takes effect is word aligned. Loads/stores always clear
  // rw_address[1:0]. The only misaligned access is the instruction fetch issued
  // in the same cycle as an instruction-address-misaligned trap (jump/branch to
  // a target with bit 1 set): it is discarded (the PC goes to mtvec) and, with
  // bit 1 set, never matches a peripheral register (all at multiples of 4).
  // Neither the RISC-V spec nor the RVX docs require aligned fetches.
  //
  // While the core is stalled (clock_enable = 0, waiting for the memory or
  // halted), instruction_address keeps the address of the last enabled cycle,
  // so the discarded fetch stays on the bus, even after the memory answers.
  // discarded_fetch records whether the last enabled cycle issued that fetch.
  // The next enabled cycle fetches from the trap vector, which is checked.
  logic discarded_fetch;

  always_ff @(posedge clock) begin
    if (reset_internal)
      discarded_fetch <= 1'b0;
    else if (clock_enable)
      discarded_fetch <= read_request && take_trap;
  end

  ast_bus_word_aligned: assert property (
    ((read_request && !take_trap && !(!clock_enable && discarded_fetch)) || write_request)
    |-> rw_address[1:0] == 2'b00
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

  // Accessing a CSR that does not exist raises an illegal instruction
  // exception. "Exists" = implemented by RVX, or mandatory in M-mode and allowed
  // to read as zero (mvendorid, mhartid, mconfigptr, hpm counters/events), or
  // optional with an ambiguous rule when absent (mcountinhibit, PMP, debug
  // triggers): those are not checked.
  function automatic logic csr_exists(input logic [11:0] a);
    case (a)
      12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'hF15,             // machine info
      12'h300, 12'h301, 12'h304, 12'h305, 12'h310, 12'h320,   // trap setup
      12'h340, 12'h341, 12'h342, 12'h343, 12'h344,            // trap handling
      12'hB00, 12'hB02, 12'hB80, 12'hB82,                     // mcycle/minstret
      12'hC00, 12'hC01, 12'hC02, 12'hC80, 12'hC81, 12'hC82:   // cycle/time/instret
        return 1'b1;
      default:
        return (a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'hB83 && a <= 12'hB9F) ||
               (a >= 12'h323 && a <= 12'h33F) ||
               (a >= 12'hC03 && a <= 12'hC1F) || (a >= 12'hC83 && a <= 12'hC9F) ||
               (a >= 12'h3A0 && a <= 12'h3EF) ||                   // PMP
               (a >= 12'h7A0 && a <= 12'h7AF);                     // debug triggers
    endcase
  endfunction

  ast_csr_nonexistent_illegal: assert property (
    csrxxx && !csr_exists(instruction_csr_address) |-> illegal_instruction
  );

  // ----------------------------------------------------------------------------
  // mcause / mtval for the other synchronous exceptions
  // ----------------------------------------------------------------------------
  // Same timing as ast_mcause_misaligned_fetch: mcause is written in the first
  // enabled TRAP_TAKEN cycle and holds the new value one cycle later.

  ast_mcause_ecall: assert property (
    exc_taken && ecall
    |=> (clock_enable [->1]) ##1 csr_mcause == 32'd11
  );

  ast_mcause_ebreak: assert property (
    exc_taken && ebreak
    |=> (clock_enable [->1]) ##1 csr_mcause == 32'd3
  );

  ast_mcause_illegal: assert property (
    exc_taken && illegal_instruction
    |=> (clock_enable [->1]) ##1 csr_mcause == 32'd2
  );

  ast_mcause_misaligned_load: assert property (
    exc_taken && misaligned_load && !illegal_instruction
    |=> (clock_enable [->1]) ##1 csr_mcause == 32'd4
  );

  ast_mcause_misaligned_store: assert property (
    exc_taken && misaligned_store && !illegal_instruction
    |=> (clock_enable [->1]) ##1 csr_mcause == 32'd6
  );

  // mtval holds the faulting byte address (written in the trap cycle)
  ast_mtval_misaligned_load_store: assert property (
    exc_taken && (misaligned_load || misaligned_store) && !illegal_instruction
    |=> csr_mtval == $past(target_address_adder)
  );

  // ----------------------------------------------------------------------------
  // Interrupt cause code and priority
  // ----------------------------------------------------------------------------
  // Spec order for the standard interrupts: MEI > MSI > MTI. RVX places the 16
  // fast interrupts (custom, cause 16 + i) above them, lower index first
  // (rvx.v: irq_fast[0] = UART "highest priority").
  logic [15:0] irq_fast_active;
  logic [4:0]  irq_code_now;
  logic [4:0]  irq_code_q;

  assign irq_fast_active = csr_mie[31:16] & csr_mip[31:16];

  always_comb begin
    irq_code_now = 5'd0;
    if (|irq_fast_active) begin
      for (int k = 15; k >= 0; k--)
        if (irq_fast_active[k]) irq_code_now = 5'(16 + k);
    end
    else if (csr_mie[11] && csr_mip[11]) irq_code_now = 5'd11;   // MEI
    else if (csr_mie[3]  && csr_mip[3])  irq_code_now = 5'd3;    // MSI
    else if (csr_mie[7]  && csr_mip[7])  irq_code_now = 5'd7;    // MTI
  end

  always_ff @(posedge clock) begin
    if (reset_internal)
      irq_code_q <= '0;
    else if (irq_taken)
      irq_code_q <= irq_code_now;
  end

  ast_irq_mcause_code: assert property (
    irq_taken
    |=> (clock_enable [->1]) ##1 csr_mcause == {1'b1, 26'b0, irq_code_q}
  );

  // ----------------------------------------------------------------------------
  // CSR instruction semantics (checked on mscratch, a plain read/write CSR)
  // ----------------------------------------------------------------------------
  // CSRRW: csr = src. CSRRS: csr = csr | src. CSRRC: csr = csr & ~src.
  // src = rs1 value, or the 5-bit uimm (instruction[19:15]) in the I forms.
  function automatic logic [31:0] csr_apply(
    input logic [1:0] op, input logic [31:0] old_value, input logic [31:0] src
  );
    case (op)
      2'b01:   return src;
      2'b10:   return old_value | src;
      2'b11:   return old_value & ~src;
      default: return old_value;
    endcase
  endfunction

  logic [31:0] csr_src;
  logic        mscratch_access;

  assign csr_src = instruction[14] ? {27'b0, instruction[19:15]} : rs1_data;
  assign mscratch_access =
    clock_enable && current_state == STATE_OPERATING && csrxxx &&
    instruction_csr_address == MSCRATCH;

  // The CSR gets the value defined by the operation
  ast_csr_mscratch_write: assert property (
    mscratch_access && !take_trap
    |=> csr_mscratch == $past(csr_apply(instruction[13:12], csr_mscratch, csr_src))
  );

  // rd gets the old value of the CSR
  ast_csr_read_old_value: assert property (
    mscratch_access && integer_file_write_enable && instruction_rd_address != 5'd0
    |-> writeback_multiplexer_output == csr_mscratch
  );

  // mscratch has no side effects: only a CSR instruction on it changes it
  ast_mscratch_stable: assert property (
    !mscratch_access |=> $stable(csr_mscratch)
  );

  // An interrupted CSR instruction that already changed mscratch must not be
  // replayed after mret (mepc must not point to it), or it executes twice
  // (e.g. csrrw x5, mscratch, x5 would swap and then swap back).
  ast_irq_no_double_csr_write: assert property (
    irq_taken && mscratch_access &&
    csr_apply(instruction[13:12], csr_mscratch, csr_src) != csr_mscratch
    |=> (handler_start [->1]) ##0 csr_mepc != irq_pc
  );

  // ----------------------------------------------------------------------------
  // minstret counts each retired instruction exactly once
  // ----------------------------------------------------------------------------
  // An instruction retires in an enabled OPERATING cycle with no trap and no
  // load/store still waiting for the memory (the commit cycle counts).
  // CSRRS/CSRRC with rs1 = x0 (e.g. csrr rd, minstret) do not write the CSR.
  logic retire;
  logic minstret_write;

  assign retire =
    clock_enable && current_state == STATE_OPERATING &&
    !load_pending && !store_pending && !take_trap;
  assign minstret_write =
    clock_enable && csrxxx && csr_is_write &&
    (instruction_csr_address == MINSTRET || instruction_csr_address == MINSTRETH);

  ast_minstret_counts_retired: assert property (
    !minstret_write
    |=> csr_minstret == $past(csr_minstret) + ($past(retire) ? 64'd1 : 64'd0)
  );

  // ----------------------------------------------------------------------------
  // RV32I instruction semantics (reference model)
  // ----------------------------------------------------------------------------
  // Decoded straight from the instruction word, independent of the RTL decoder.
  // exec_pc is the address of the instruction in execution (see above). Commit
  // cycles replay a load/store, so they are excluded where exec_pc is used.
  logic [6:0]  opcode;
  logic [2:0]  funct3;
  logic [6:0]  funct7;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  logic        is_op, is_op_imm, is_lui, is_auipc, is_jal, is_jalr, is_branch;
  logic        no_commit;

  assign opcode = instruction[6:0];
  assign funct3 = instruction[14:12];
  assign funct7 = instruction[31:25];
  assign imm_i  = {{20{instruction[31]}}, instruction[31:20]};
  assign imm_s  = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
  assign imm_b  = {{19{instruction[31]}}, instruction[31], instruction[7],
                   instruction[30:25], instruction[11:8], 1'b0};
  assign imm_u  = {instruction[31:12], 12'b0};
  assign imm_j  = {{11{instruction[31]}}, instruction[31], instruction[19:12],
                   instruction[20], instruction[30:21], 1'b0};

  assign is_op     = opcode == 7'b0110011;
  assign is_op_imm = opcode == 7'b0010011;
  assign is_lui    = opcode == 7'b0110111;
  assign is_auipc  = opcode == 7'b0010111;
  assign is_jal    = opcode == 7'b1101111;
  assign is_jalr   = opcode == 7'b1100111 && funct3 == 3'b000;
  assign is_branch = opcode == 7'b1100011 && funct3 != 3'b010 && funct3 != 3'b011;
  assign no_commit = !load_commit_cycle && !store_commit_cycle;

  // ALU result for OP / OP-IMM, valid only for legal encodings
  logic [31:0] alu_b, alu_ref;
  logic [4:0]  shamt;
  logic        alu_valid;

  assign alu_b = is_op ? rs2_data : imm_i;
  assign shamt = alu_b[4:0];

  always_comb begin
    alu_ref   = '0;
    alu_valid = 1'b0;
    if (is_op || is_op_imm) begin
      alu_valid = 1'b1;
      case (funct3)
        3'b000: alu_ref = (is_op && funct7[5]) ? rs1_data - alu_b : rs1_data + alu_b;
        3'b001: alu_ref = rs1_data << shamt;
        3'b010: alu_ref = {31'b0, $signed(rs1_data) < $signed(alu_b)};
        3'b011: alu_ref = {31'b0, rs1_data < alu_b};
        3'b100: alu_ref = rs1_data ^ alu_b;
        3'b101: alu_ref = funct7[5] ? 32'($signed(rs1_data) >>> shamt) : rs1_data >> shamt;
        3'b110: alu_ref = rs1_data | alu_b;
        3'b111: alu_ref = rs1_data & alu_b;
      endcase
      // funct7 must be 0, except SUB/SRA (0100000); OP-IMM only checks it
      // for the shifts
      if (is_op && !(funct7 == 7'b0 ||
                     (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))))
        alu_valid = 1'b0;
      if (is_op_imm && funct3 == 3'b001 && funct7 != 7'b0)
        alu_valid = 1'b0;
      if (is_op_imm && funct3 == 3'b101 && !(funct7 == 7'b0 || funct7 == 7'b0100000))
        alu_valid = 1'b0;
    end
    else if (is_lui) begin
      alu_valid = 1'b1;
      alu_ref   = imm_u;
    end
    else if (is_auipc) begin
      alu_valid = 1'b1;
      alu_ref   = exec_pc + imm_u;
    end
  end

  // ALU, LUI and AUIPC write the correct result to rd
  ast_isa_alu_result: assert property (
    clock_enable && rd_write && alu_valid && no_commit
    |-> writeback_multiplexer_output == alu_ref
  );

  // JAL/JALR write the return address (pc + 4) to rd
  ast_isa_link_address: assert property (
    clock_enable && rd_write && (is_jal || is_jalr) && no_commit
    |-> writeback_multiplexer_output == exec_pc + 32'd4
  );

  // Branches: the next fetch is the target if the condition holds, pc + 4 if not
  logic branch_taken_ref;

  always_comb begin
    case (funct3)
      3'b000:  branch_taken_ref = rs1_data == rs2_data;                    // BEQ
      3'b001:  branch_taken_ref = rs1_data != rs2_data;                    // BNE
      3'b100:  branch_taken_ref = $signed(rs1_data) <  $signed(rs2_data);  // BLT
      3'b101:  branch_taken_ref = $signed(rs1_data) >= $signed(rs2_data);  // BGE
      3'b110:  branch_taken_ref = rs1_data <  rs2_data;                    // BLTU
      3'b111:  branch_taken_ref = rs1_data >= rs2_data;                    // BGEU
      default: branch_taken_ref = 1'b0;
    endcase
  end

  ast_isa_branch_target: assert property (
    clock_enable && current_state == STATE_OPERATING && is_branch && !take_trap && no_commit
    |-> instruction_address == (branch_taken_ref ? exec_pc + imm_b : exec_pc + 32'd4)
  );

  // JAL jumps to pc + imm, JALR to (rs1 + imm) with bit 0 cleared
  ast_isa_jump_target: assert property (
    clock_enable && current_state == STATE_OPERATING && (is_jal || is_jalr) &&
    !take_trap && no_commit
    |-> instruction_address == (is_jal ? exec_pc + imm_j : (rs1_data + imm_i) & ~32'd1)
  );

  // Stores: word address, byte strobes from funct3 and address[1:0], and the
  // data of the enabled bytes in the right lanes
  logic [31:0] store_ea, store_data_ref, store_mask;
  logic [3:0]  store_strobe_ref;
  logic        store_valid;

  assign store_ea = rs1_data + imm_s;

  always_comb begin
    store_valid      = 1'b1;
    store_strobe_ref = 4'b0000;
    store_data_ref   = '0;
    case (funct3)
      3'b000: begin                                                   // SB
        store_strobe_ref = 4'b0001 << store_ea[1:0];
        store_data_ref   = {4{rs2_data[7:0]}};
      end
      3'b001: begin                                                   // SH
        store_strobe_ref = store_ea[1] ? 4'b1100 : 4'b0011;
        store_data_ref   = {2{rs2_data[15:0]}};
      end
      3'b010: begin                                                   // SW
        store_strobe_ref = 4'b1111;
        store_data_ref   = rs2_data;
      end
      default: store_valid = 1'b0;
    endcase
  end

  assign store_mask = {{8{write_strobe[3]}}, {8{write_strobe[2]}},
                       {8{write_strobe[1]}}, {8{write_strobe[0]}}};

  ast_isa_store_access: assert property (
    clock_enable && current_state == STATE_OPERATING && store && write_request &&
    store_valid && no_commit
    |-> rw_address   == {store_ea[31:2], 2'b00} &&
        write_strobe == store_strobe_ref &&
        (write_data & store_mask) == (store_data_ref & store_mask)
  );

  // Loads: in the commit cycle, rd gets the addressed byte/half/word of the
  // memory response, sign- or zero-extended
  logic [31:0] load_ea, load_ref;
  logic [7:0]  load_byte;
  logic [15:0] load_half;
  logic        load_valid;

  assign load_ea   = rs1_data + imm_i;
  assign load_byte = read_data[8 * load_ea[1:0] +: 8];
  assign load_half = load_ea[1] ? read_data[31:16] : read_data[15:0];

  always_comb begin
    load_valid = 1'b1;
    case (funct3)
      3'b000:  load_ref = {{24{load_byte[7]}}, load_byte};    // LB
      3'b001:  load_ref = {{16{load_half[15]}}, load_half};   // LH
      3'b010:  load_ref = read_data;                          // LW
      3'b100:  load_ref = {24'b0, load_byte};                 // LBU
      3'b101:  load_ref = {16'b0, load_half};                 // LHU
      default: begin
        load_ref   = '0;
        load_valid = 1'b0;
      end
    endcase
  end

  ast_isa_load_result: assert property (
    clock_enable && load && load_commit_cycle && rd_write && load_valid
    |-> writeback_multiplexer_output == load_ref
  );

  // Register file: the value read from a register is the last value written
  // to it. Checked on one symbolic register with a 32-bit shadow copy. The
  // register is chosen by the tool in the first cycle after reset (sampled from
  // real_time_clock, a free input that only feeds the time CSR) and then kept
  // constant, so the proof holds for every register x1..x31. The register file
  // and the shadow copy are both zero after reset, and no register is written
  // in that first cycle (the core is still in STATE_RESET).
  logic [4:0]  sym_reg;
  logic        sym_reg_chosen;
  logic [31:0] sym_reg_value;

  always_ff @(posedge clock) begin
    if (reset_internal)
      sym_reg_chosen <= 1'b0;
    else if (!sym_reg_chosen) begin
      sym_reg        <= real_time_clock[4:0];
      sym_reg_chosen <= 1'b1;
    end
  end

  always_ff @(posedge clock) begin
    if (reset_internal)
      sym_reg_value <= '0;
    else if (clock_enable && integer_file_write_enable && instruction_rd_address == sym_reg)
      sym_reg_value <= writeback_multiplexer_output;
  end

  ast_isa_regfile_rs1: assert property (
    sym_reg_chosen && sym_reg != 5'd0 && instruction_rs1_address == sym_reg
    |-> rs1_data == sym_reg_value
  );

  ast_isa_regfile_rs2: assert property (
    sym_reg_chosen && sym_reg != 5'd0 && instruction_rs2_address == sym_reg
    |-> rs2_data == sym_reg_value
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
