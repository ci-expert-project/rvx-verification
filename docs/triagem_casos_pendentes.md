# Triagem de Falhas Formais: 3 Casos Pendentes

Guia de estudo para classificar as três asserções do checker `rvx_core_sva.sv` que ainda não foram analisadas. Os contra-exemplos e os trechos de RTL estão incluídos, então dá para trabalhar sem acesso ao CADMICRO.

| # | Asserção | Profundidade |
| :--- | :--- | :--- |
| 1 | `ast_ro_csr_write_illegal` | 3 |
| 2 | `ast_minstret_no_count_while_waiting` | 4 |
| 3 | `ast_bus_word_aligned` | 3 |

Contra-exemplos gerados em 06/11/2026 (DUT `7af8290`), com:

```bash
CEX_SIGNALS="..." ./scripts/run_formal.sh trace ast_ro_csr_write_illegal \
  ast_minstret_no_count_while_waiting ast_bus_word_aligned
```

---

## 0. Roteiro de triagem (vale para qualquer falha)

1. **Releia a asserção** e escreva em português o que ela afirma (antecedente → consequente).
2. **Gere o contra-exemplo** com os sinais que aparecem na asserção.
3. **Ache o ciclo da falha**: a última linha (para `|->`) ou a penúltima (para `|=>`, que olha o ciclo seguinte).
4. **Decodifique a instrução** desse ciclo.
5. **Responda três perguntas:**

   | Pergunta | Se "não" → |
   | :--- | :--- |
   | a) O cenário é **possível na prática**? | **Ambiente**: acrescentar um `assume` |
   | b) A asserção está **de acordo com a especificação**? | **Asserção errada**: corrigir a asserção |
   | c) Se (a) e (b) são "sim": **onde está a causa no RTL?** | **Bug no RTL**, ou **limitação conhecida / decisão de projeto** se o autor documentou o comportamento |

6. **Registre a conclusão**: um parágrafo com o que a especificação exige, o que o RTL faz (com a linha), o contra-exemplo decodificado, a consequência e a correção sugerida.

### Lembretes de decodificação RV32I

| Bits | Campo |
| :--- | :--- |
| [6:0] | opcode |
| [11:7] | `rd` |
| [14:12] | `funct3` |
| [19:15] | `rs1` (ou `uimm` nas instruções de CSR com imediato) |
| [24:20] | `rs2` |
| [31:20] | imediato tipo I / **endereço do CSR** |

| Opcode (binário) | Tipo |
| :--- | :--- |
| `1110011` | SYSTEM (CSRs, `ecall`, `ebreak`, `mret`) |
| `0100011` | STORE |
| `1101111` | JAL |
| `1100011` | BRANCH |

`funct3` das instruções de CSR: `001` CSRRW, `010` CSRRS, `011` CSRRC, `101` CSRRWI, `110` CSRRSI, `111` CSRRCI.

Estados do core: `1` = `STATE_RESET`, `2` = `STATE_OPERATING`, `4` = `STATE_TRAP_TAKEN`, `8` = `STATE_TRAP_RETURN`.

---

## Caso 1: `ast_ro_csr_write_illegal`

### A asserção

```systemverilog
// CSRRW/CSRRWI always write; CSRRS/CSRRC and their immediate forms write
// only when rs1/uimm is not zero.
logic csr_is_write;
assign csr_is_write = instruction[13:12] == 2'b01 || instruction[19:15] != 5'd0;

ast_ro_csr_write_illegal: assert property (
  csrxxx && instruction_csr_address[11:10] == 2'b11 && csr_is_write
  |-> illegal_instruction
);
```

### O contra-exemplo

| cycle | current_state | instruction | csrxxx | csr_address | csr_is_write | illegal_instruction | take_trap |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 0–1 | 1 | `00000013` | 0 | `000` | 0 | 0 | 0 |
| 2–3 | 1 | `00000013` | 0 | `000` | 0 | 0 | 0 |
| **4** | **2** | **`c0012073`** | **1** | **`c00`** | **1** | **0** | **0** |

### RTL relevante (`dut/rvx/hardware/rvx_core.v`)

```verilog
// linhas 751-754
assign csrxxx =
  system_type &
  instruction_funct3 != 3'b000 &
  instruction_funct3 != 3'b100;

// linhas 814-816
assign illegal_system =
  system_type &
  ~(csrxxx | ecall | ebreak | mret);
```

### Especificação

RISC-V Privileged Specification, seção *CSR Address Mapping Conventions*:
- Os bits [11:10] do endereço indicam se o CSR é de leitura/escrita (`00`, `01`, `10`) ou **somente leitura** (`11`).
- *"Attempts to write a read-only register raise an illegal instruction exception."*
- CSRRS/CSRRC com `rs1 = x0` (ou CSRRSI/CSRRCI com `uimm = 0`) **não escrevem** o CSR, então não geram essa exceção.

### Perguntas

1. Decodifique `0xc0012073`: opcode, `rd`, `funct3`, `rs1`, endereço do CSR. Qual é a instrução (nome e operandos)?
2. Qual CSR é o `0xC00`? Procure na lista de `localparam` no início do `rvx_core.v`. Por que ele é somente leitura?
3. A instrução **realmente escreve** no CSR? Confira com a regra do `csr_is_write` e com a especificação.
4. O `illegal_system` olha o endereço do CSR? O que o RTL faz com essa escrita (procure o bloco que atualiza o contador correspondente)?
5. Pergunta (a): um programa real poderia executar essa instrução?
6. **Classificação:** bug no RTL, asserção errada ou ambiente?
7. **Extra:** a especificação também diz que acessar um CSR **que não existe** gera instrução ilegal. O RVX trata isso? (Veja também o Caso 3, ciclos 4 e 5: CSR `0x000`.)

### Sua conclusão

> _escreva aqui_

---

## Caso 2: `ast_minstret_no_count_while_waiting`

### A asserção

```systemverilog
// A load/store waiting for the memory has not retired yet: minstret must
// not count it in the waiting cycle (it is counted when it completes)
ast_minstret_no_count_while_waiting: assert property (
  clock_enable && current_state == STATE_OPERATING &&
  (load_pending || store_pending) && !take_trap
  |=> csr_minstret == $past(csr_minstret)
);
```

### O contra-exemplo

| cycle | clock_enable | current_state | instruction | store | store_pending | write_request | csr_minstret |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 0–3 | – | 1 | `00000013` | 0 | 0 | 0 | 0 |
| **4** | **1** | **2** | **`00000023`** | **1** | **1** | **1** | **0** |
| **5** | **0** | **2** | **`00000023`** | **1** | **1** | **1** | **1** |

No ciclo 5, `clock_enable = 0` porque o core espera o `write_response` da memória.

### RTL relevante

```verilog
// linhas 546-553: commit e pendência de load/store
assign store_commit_cycle = prev_write_request & write_response;
assign store_pending      = store & !store_commit_cycle;

// linhas 1358-1372: minstret
always @(posedge clock) begin : minstret_implementation
  if (reset_internal)
    csr_minstret  <= 64'b0;
  else if (clock_enable) begin
    if (instruction_csr_address == MINSTRET && csr_file_write_enable) begin
      csr_minstret <= {csr_minstret[63:32], csr_write_data};
    end
    else if (instruction_csr_address == MINSTRETH && csr_file_write_enable) begin
      csr_minstret <= {csr_write_data, csr_minstret[31:0]};
    end
    else begin
      if (current_state == STATE_OPERATING)
        csr_minstret <= csr_minstret + 1;
      else
        csr_minstret <= csr_minstret;
    end
  end
end
```

Como um store funciona no RVX:
1. **Ciclo de requisição:** o core decodifica o store, envia `write_request` e `store_pending = 1`. O `program_counter` **não avança**.
2. **Ciclos de espera** (opcional): `clock_enable = 0` até a memória responder.
3. **Ciclo de commit:** `write_response = 1` → `store_commit_cycle = 1` → `store_pending = 0`. O `program_counter` avança.

### Perguntas

1. Decodifique `0x00000023`: qual instrução é (tipo, `funct3`, registradores, offset)?
2. Em qual ciclo o antecedente da asserção é verdadeiro? O que acontece com o `csr_minstret` no ciclo seguinte?
3. Usando o RTL acima, siga o store pelos três momentos (requisição, espera, commit). Em quais deles o `minstret` incrementa? **Quantas vezes, no total, esse store é contado?**
4. O mesmo acontece com um load? (`load_pending = load & !load_commit_cycle`)
5. Este problema é o mesmo do Bug 2 (`minstret` contando trap) ou é independente? Repare que aqui `take_trap = 0`.
6. Qual seria a correção no RTL? (Dica: em quais ciclos uma instrução realmente **conclui**?)
7. **Classificação** e consequência para a métrica de CPI.

### Sua conclusão

> _escreva aqui_

---

## Caso 3: `ast_bus_word_aligned`

### A asserção

```systemverilog
// The bus is word addressed: every access uses a word-aligned address
ast_bus_word_aligned: assert property (
  (read_request || write_request) |-> rw_address[1:0] == 2'b00
);
```

### O contra-exemplo

| cycle | current_state | program_counter | instruction | take_trap | read_request | rw_address |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 0–3 | 1 | `00000000` | `00000013` | 0 | 0/1 | `00000000` |
| 4 | 2 | `00000000` | `00001073` | 0 | 1 | `00000004` |
| 5 | 2 | `00000004` | `00001073` | 0 | 1 | `00000008` |
| **6** | **2** | **`00000008`** | **`0020106f`** | **1** | **1** | **`0000100a`** |

### RTL relevante

```verilog
// rvx_core.v, linhas 561-564: endereço do barramento
assign rw_address_internal =
  load_request | store_request ?
  {target_address_adder[31:2], 2'b00} :   // load/store: sempre alinhado
  instruction_address;                     // busca de instrução

// rvx_core.v: a busca usa o próximo PC calculado no ciclo
//   instruction_address = next_program_counter (quando clock_enable)
//   next_program_counter = next_address  (no estado OPERATING)
//   next_address = take_branch ? branch_target_address : program_counter + 4

// rvx_ram.v: a RAM ignora os 2 bits menos significativos
assign effective_address = $unsigned(rw_address[31:0] >> 2);
```

### Perguntas

1. Decodifique `0x0020106f` (ciclo 6): qual instrução, qual `rd`, qual alvo? Por que `take_trap = 1`?
2. De onde vem o `rw_address = 0x100a` no ciclo 6? Siga o caminho `next_address` → `next_program_counter` → `instruction_address` → `rw_address`.
3. Essa leitura é **usada** pelo core? O que acontece no ciclo seguinte (estado `TRAP_TAKEN`) com a instrução que chega da memória?
4. Pergunta (b): a especificação RISC-V fala sobre o **protocolo de barramento** do RVX? Ou a regra "todo acesso é alinhado" é uma convenção que **nós** assumimos para este barramento?
5. Pergunta (a)/(c): essa leitura desalinhada causa algum problema na `rvx_ram`? E num periférico mapeado no barramento (`rvx_bus` decodifica o endereço completo)? Uma leitura especulativa num periférico pode ter efeito colateral? (Ex.: ler o registrador de dados da UART pode consumir um byte recebido.)
6. Decida entre:
   - **Registrar como achado** (bug de baixa gravidade), ou
   - **Relaxar a asserção** para ignorar a busca descartada, por exemplo `(read_request && !take_trap) || write_request`, e justificar.
7. **Extra:** decodifique `0x00001073` (ciclos 4 e 5). Qual CSR ela acessa? Ele existe no RVX? O core marcou como ilegal? (Ligue com a pergunta 7 do Caso 1.)

### Sua conclusão

> _escreva aqui_

---

## Depois da triagem

- Atualize o `docs/bug_analysis_misaligned_mepc.md` (ou crie um documento de achados) com os casos classificados como bug.
- Se alguma asserção for corrigida, rode `./scripts/run_formal.sh` de novo e confira o novo status.
- Rode `./scripts/run_formal.sh coverage` para ver se o coverage formal mudou.
