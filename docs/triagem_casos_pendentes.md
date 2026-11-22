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

### conclusão

**Classificação: bug no RTL (Bug 5).**

| Pergunta | Resposta |
| :--- | :--- |
| 1. Instrução | `0xc0012073`: `opcode = 1110011` (SYSTEM), `rd = 0`, `funct3 = 010` (CSRRS), `rs1 = 2`, `csr = 0xC00` → `csrrs x0, cycle, x2` |
| 2. CSR `0xC00` | `cycle` (`localparam CYCLE`), cópia somente leitura do `mcycle` (`0xB00`). É somente leitura porque `0xC00` = `1100 0000 0000`: bits `[11:10] = 11` |
| 3. Escreve no CSR? | Sim: CSRRS só deixa de escrever com `rs1 = x0`, e aqui `rs1 = x2`. A spec decide pelo número do registrador, não pelo valor guardado nele |
| 4. RTL | `csrxxx = 1` (`funct3 = 010` é diferente de `000` e de `100`), logo `illegal_system = 0`. Nem `csrxxx` nem `illegal_system` olham o endereço do CSR ou o `rs1`, então qualquer instrução de CSR é aceita como legal. A escrita cai no `else` do bloco do `mcycle`, que só aceita `MCYCLE`/`MCYCLEH`: é descartada e o contador segue incrementando normalmente |
| 5. Cenário possível? | Sim: a codificação é válida e a spec define o comportamento esperado (exceção de instrução ilegal) |
| 6. Classificação | Bug no RTL: o cenário é possível e a asserção segue a spec |
| 7. Extra: CSR inexistente | Não trata. Confirmado no Caso 3 (pergunta 7): `csrrw x0, 0x000, x0` acessa o CSR `0x000`, que não existe no RVX, sem gerar exceção. A causa é a mesma da resposta 4: o `illegal_system` não olha o endereço do CSR |

A especificação do RISC-V (em *CSR Address Mapping Conventions*) determina que uma tentativa de escrita em um registrador somente leitura deve ser tratada como instrução ilegal. Como o RTL não verifica se o endereço do CSR é somente leitura, um programa pode solicitar a escrita nesse registrador sem que uma exceção seja gerada. Nesse caso, o valor não é escrito e o RTL apenas incrementa em 1 o contador de ciclos. Contudo, nenhuma exceção é levantada, pois a operação não é reconhecida como ilegal. Como essa situação diverge da especificação do RISC-V, trata-se de um bug no RTL. A correção deveria ser feita no bloco da linha 814 de `rvx_core.v`, que hoje verifica apenas se a operação é `csrxxx`. A instrução só deve ser considerada ilegal quando, além de o CSR ser somente leitura, ela realmente escrever: CSRRW/CSRRWI sempre escrevem, e CSRRS/CSRRC (e as formas imediatas) só escrevem quando `rs1`/`uimm` ≠ 0.

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

Em portugues: Se, num ciclo T, o clock está habilitado, o estado é OPERATING, há um load ou store pendente e não há take_trap, então no ciclo T+1 o minstret deve ter o mesmo valor que tinha no ciclo T.

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

### Conclusão

**Classificação: bug no RTL (Bug 6), independente do Bug 2, mas com a mesma raiz.**

| Pergunta | Resposta |
| :--- | :--- |
| 1. Instrução | `0x00000023` = `sb x0, 0(x0)` (STORE, `funct3 = 000`, `rs1 = x0`, `rs2 = x0`, offset 0) |
| 2. Ciclo da falha | Antecedente no ciclo 4 (`clock_enable = 1`, OPERATING, `store_pending = 1`, sem trap). No ciclo 5, o `minstret` vai de 0 para 1, mas deveria continuar em 0 |
| 3. Contagem do store | Requisição: +1. Espera: não conta (`clock_enable = 0`). Commit: +1. **Total: 2 vezes** |
| 4. Load | Mesmo problema: o load também tem ciclo de requisição e de commit com `clock_enable = 1` |
| 5. Relação com o Bug 2 | Independente: aqui `take_trap = 0` e a instrução conclui normalmente. A correção do Bug 2 (`!take_trap`) não resolve este caso |
| 6. Correção | Incrementar só quando a instrução conclui: `current_state == STATE_OPERATING && !load_pending && !store_pending && !take_trap` |
| 7a. Cenário possível? | Sim: é um store comum, e o problema ocorre até sem espera de memória |
| 7b. Asserção segue a spec? | Sim: o `minstret` conta apenas instruções concluídas (*retired*) |
| 7c. Causa no RTL | `if (current_state == STATE_OPERATING)` no bloco do `minstret` (`rvx_core.v`, linha 1369) |

A especificação do RISC-V determina que o `minstret` conte apenas instruções concluídas (*retired*). No RVX, o contador incrementa em todo ciclo com `clock_enable` ativo no estado OPERATING (`rvx_core.v`, linha 1369), sem verificar se uma instrução realmente concluiu naquele ciclo. Loads e stores ocupam dois ciclos com `clock_enable` ativo: o ciclo de requisição, em que `load_pending`/`store_pending` vale 1, e o ciclo de commit, em que a resposta da memória chega e o sinal pendente vai a 0. Por isso, cada load e store é contado duas vezes, mesmo sem nenhum ciclo de espera da memória. O formal mostrou a instrução `sb x0, 0(x0)` (`0x00000023`): no ciclo de requisição o `minstret` já sobe de 0 para 1, e o store ainda seria contado de novo no commit.

Este bug é independente do Bug 2, pois aqui não há trap (`take_trap = 0`) e a instrução conclui normalmente, mas os dois têm a mesma raiz: o contador não verifica se a instrução foi concluída. A consequência é uma métrica distorcida: o `minstret` fica inflado e o CPI calculado com `mcycle`/`minstret` fica menor que o real, fazendo o processador parecer melhor do que é. Por exemplo, num programa de 100 ciclos com 50 instruções, das quais 20 são loads/stores, o CPI real é 2,0, mas o medido é 100/70 ≈ 1,43. A correção sugerida, que também resolve o Bug 2, é incrementar o contador apenas quando `current_state == STATE_OPERATING && !load_pending && !store_pending && !take_trap`. Assim, cada instrução é contada exatamente uma vez, no ciclo em que conclui.

---

## Caso 3: `ast_bus_word_aligned`

### A asserção

```systemverilog
// The bus is word addressed: every access uses a word-aligned address
ast_bus_word_aligned: assert property (
  (read_request || write_request) |-> rw_address[1:0] == 2'b00
);
```

Em portugues: Se há read_request ou write_request, então, no mesmo ciclo, os 2 bits menos significativos do rw_address precisam ser 00. Ou seja, "o barramento só é acessado em endereços múltiplos de 4". O barramento é endereçado por palavra (a rvx_ram, por exemplo, ignora os 2 bits de baixo: rw_address >> 2). Loads e stores de byte ou meia palavra usam o endereço da palavra mais o write_strobe para escolher os bytes.

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

**Classificação: asserção errada (regra mais rígida do que qualquer especificação). Asserção corrigida. A falha que permanece é causada pelo Bug 4.**

| Pergunta | Resposta |
| :--- | :--- |
| 1. Instrução | `0x0020106f`: `opcode = 1101111` (JAL, formato J), `rd = x0`, offset `0x1002` → `jal x0, 0x1002`. Alvo = PC + offset = `0x8 + 0x1002` = `0x100a`. Como os 2 bits de baixo do alvo são `10` (não é múltiplo de 4) e o RVX não implementa a extensão C, ocorre a exceção *instruction-address-misaligned*, por isso `take_trap = 1` |
| 2. Origem do `rw_address = 0x100a` | O RVX pede a próxima instrução no mesmo ciclo em que executa a atual. Para um salto, `next_address = branch_target_address` = `0x100a` (`rvx_core.v`, linhas 464-467) → `next_program_counter` (`PC_NEXT`, linhas 444-451) → `instruction_address` (linhas 431-436) → `rw_address`, pois o JAL não é load/store. O mesmo `next_address` é usado para detectar o desalinhamento (`misaligned_instruction_address = take_branch & next_address[1]`, linhas 1213-1214), mas essa detecção não bloqueia a busca |
| 3. A leitura é usada? | Não. No ciclo seguinte (`TRAP_TAKEN`), `program_counter_source = PC_TRAP` e o PC vai para o `mtvec`. A instrução lida de `0x100a` é descartada (busca especulativa) |
| 4. A spec define o barramento? | Não. O `rvx_bus` é uma interface própria do RVX. Nem a spec RISC-V nem a documentação do RVX (`docs/hardware.md`, só o mapa de memória) exigem acessos alinhados. O `rvx_bus` repassa qualquer endereço sem alterá-lo. A regra "todo acesso é alinhado" foi uma convenção nossa, baseada nos loads/stores, que sempre zeram `rw_address[1:0]` |
| 5. Impacto | Nenhum. A `rvx_ram` ignora os 2 bits de baixo (`rw_address >> 2`) e lê a palavra de `0x1008`. Nos periféricos, todos os registradores ficam em múltiplos de 4 (bit 1 = 0), e uma busca descartada sempre tem bit 1 = 1, então nunca acerta um registrador nem dispara efeito colateral (por exemplo, a leitura do `REG_RDATA` da UART, que limpa a interrupção de recepção) |
| 6. Decisão | Relaxar a asserção para ignorar a busca descartada durante toda a sua duração: no ciclo do trap (`take_trap`) e nos ciclos seguintes em que o core fica parado (`clock_enable = 0`) e o barramento repete o mesmo endereço. Foram necessárias três iterações, cada uma motivada por um novo contra-exemplo (ver abaixo) |
| 7. Extra: `0x00001073` | `csrrw x0, 0x000, x0` (`funct3 = 001`, CSRRW). O CSR `0x000` não existe no RVX: não há `localparam` com esse endereço, e a leitura cai no `default` (`csr_data_out = 0`, linha 1206). O core **não** marcou como ilegal (`take_trap = 0` nos ciclos 4 e 5), embora a spec exija exceção de instrução ilegal no acesso a CSR inexistente. Confirma a hipótese da pergunta 7 do Caso 1: o `illegal_system` não olha o endereço do CSR. É um achado novo, ligado ao requisito CORE-CSR-003 da matriz, e ainda precisa ser registrado (candidato a próximo bug do relatório) |

A asserção `ast_bus_word_aligned` exigia que todo acesso ao barramento usasse endereço alinhado a palavra. O formal encontrou uma exceção: no ciclo em que um salto para alvo desalinhado gera o trap *instruction-address-misaligned*, o core já coloca o alvo (`0x100a`) no barramento para buscar a próxima instrução, porque o endereço de busca vem do `next_address` e não é bloqueado pelo `take_trap`. Essa leitura é descartada: no ciclo seguinte, o PC vai para o `mtvec`. Ela também não tem efeito colateral, porque a `rvx_ram` ignora os 2 bits de baixo do endereço e, nos periféricos, um endereço com bit 1 = 1 nunca corresponde a um registrador. Como nem a especificação RISC-V nem a documentação do RVX exigem acessos alinhados ao barramento, a regra da asserção era uma convenção nossa, mais rígida do que o projeto define. Por isso, a classificação é asserção errada.

A asserção foi corrigida em `synopsys/formal/rvx_core_sva.sv` para verificar apenas os acessos que têm efeito. A correção precisou de três iterações, porque a busca descartada pode durar mais de um ciclo:

| Iteração | Asserção | Novo contra-exemplo |
| :--- | :--- | :--- |
| 1 | Ignorar a busca só no ciclo do trap: `read_request && !take_trap` | `jal x0, 2` (alvo `0x2`). No ciclo seguinte (`TRAP_TAKEN`), a memória ainda não respondeu, e o protocolo mantém o pedido com o mesmo endereço até a resposta (`ast_bus_read_hold`) |
| 2 | Marcar a busca descartada (`discarded_fetch`) e liberá-la na resposta da memória (`read_response`) | Alvo `0x6`. A resposta da busca anterior chegou no mesmo ciclo do trap e zerou a marca antes de ela ser feita. Além disso, com o core parado por `halt`, o barramento continua com o mesmo endereço mesmo depois da resposta |
| 3 | Seguir o `clock_enable`: com o core parado, o `instruction_address` repete o endereço do último ciclo ativo (`rvx_core.v`, linhas 431-436). `discarded_fetch` guarda se o último ciclo ativo emitiu a busca descartada | Bug 4 (abaixo): a asserção passa a pegar um problema real |

Versão final:

```systemverilog
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
```

Com essa versão, a asserção continua *falsified* (profundidade 6), mas a causa é o **Bug 4**. No contra-exemplo, um salto para `0x306` gera o trap (ciclo 5). No ciclo 6, o core está em `TRAP_TAKEN`, parado por `halt` (`clock_enable = 0`) e com `interrupt_pending = 1`. Como o registrador de estado avança com `clock_enable | interrupt_pending` (`rvx_core.v`, linha 1120), mas o PC só muda com `clock_enable` (linhas 470-473), no ciclo 7 o core volta a OPERATING com o PC ainda em `0x306`, sem ter ido para o `mtvec`. Ele passa a executar em endereço desalinhado e busca a próxima instrução em `0x30a`, sem trap. É uma consequência nova do Bug 4, além do `mcause` e do `mstatus` desatualizados: o core executa instruções em endereço desalinhado. A asserção também detectaria um `mret` para um `mepc` desalinhado (consequência do Bug 3), em que a busca acontece sem `take_trap`. Ela deve passar a ser provada quando o Bug 4 for corrigido.

O contra-exemplo revelou também um achado à parte: nos ciclos 4 e 5, a instrução `csrrw x0, 0x000, x0` acessa um CSR que não existe no RVX sem gerar exceção de instrução ilegal, como a especificação exige. A causa é a mesma do Bug 5 (o `illegal_system` não olha o endereço do CSR), e a correção deve tratar os dois casos juntos: marcar como ilegal o acesso a CSR inexistente e a escrita em CSR somente leitura.
