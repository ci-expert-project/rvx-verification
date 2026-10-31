# Análise de Causa-Raiz: Falhas em Testes de Desvio e Salto Desalinhados (*Instruction Address Misaligned*)

**Data:** 03 de Outubro de 2026 (revisado em 31 de Outubro de 2026)  
**Projeto:** Verificação do Núcleo Processador RVX (RISC-V RV32I)  
**Ferramentas:** Synopsys VCS®, Synopsys Verdi®, Synopsys VC Formal®  
**Commit do DUT (RVX):** `7af8290a770e6cb17e49dea75268a582bff5261f`  

> **Revisão (31/10/2026):** a versão original deste documento concluía que o `csr_mepc` era gravado com o PC adiantado em +8 (`0x138` no lugar de `0x130`). **Essa conclusão estava errada.** A verificação formal provou que o `mepc` está correto, e o valor `0x138` observado no Verdi foi escrito pelo próprio *trap handler* do teste (seção 4). As falhas são esperadas pelo projeto do RVX (seção 3). A investigação também encontrou dois *corner cases* reais: a escrita indevida em `rd` durante o trap (seção 5) e a contagem indevida no `minstret` (seção 6).

---

## 1. Resumo Executivo

Na suíte de conformidade RISC-V RV32I (54 testes unitários), o RVX passou em **46 testes (85,2%)**. Os **8 testes que falham** são de salto/desvio para endereços desalinhados:

- `misalign-jal-01`
- `misalign2-jalr-01`
- `misalign-beq-01`, `misalign-bge-01`, `misalign-bgeu-01`
- `misalign-blt-01`, `misalign-bltu-01`, `misalign-bne-01`

Conclusões:

1. **As 8 falhas são esperadas.** O RVX não suporta saltos para endereços múltiplos de 2 (isso exige a extensão C). O próprio repositório do RVX lista exatamente esses 8 testes como `expected_to_fail`.
2. **O tratamento do trap está correto.** `mepc`, `mcause` e `mtval` foram provados corretos por verificação formal, para qualquer programa e qualquer latência de memória.
3. **Há dois *corner cases* reais, que não causam as falhas:** a instrução que gera o trap ainda escreve no registrador `rd` (JAL/JALR desalinhado e instrução ilegal) e ainda é contada pelo `minstret`.

---

## 2. Descarte da Hipótese da Issue #83 do DUT

Investigou-se se o erro decorria de uma falha conhecida no `mtval` (Issue #83 do repositório do RVX). O RTL atual já trata o caso (`dut/rvx/hardware/rvx_core.v`, linhas 1517–1521):

```verilog
if(take_trap) begin
  if(misaligned_load | misaligned_store)
    csr_mtval <= target_address_adder;
  else if (misaligned_instruction_address)
    csr_mtval <= next_address;
```

A asserção formal `ast_mtval_misaligned_fetch` foi **provada**, e a assinatura da simulação registra `mtval = 0x33a` (seção 4). A Issue #83 está **descartada**.

---

## 3. Limitação de Projeto: o RVX não suporta alvos desalinhados

### 3.1. Evidência no repositório do RVX

O testbench Vivado do RVX (`dut/rvx/hardware/tests/core/vivado/unit_tests.v`) declara:

```verilog
// The tests below are expected to fail because
// RVX does not support misaligned branch/jump instructions
reg [167:0] expected_to_fail [0:7] = {
  "misalign-beq-01.hex",  "misalign-bge-01.hex",
  "misalign-bgeu-01.hex", "misalign-blt-01.hex",
  "misalign-bltu-01.hex", "misalign-bne-01.hex",
  "misalign-jal-01.hex",  "misalign2-jalr-01.hex"
};
```

A lista é **idêntica** às 8 falhas da nossa regressão (`sim/results/regression_report.txt`). Já o `misalign1-jalr-01` passa: o JALR zera o bit 0 do alvo, então um alvo com apenas o bit 0 setado deixa de ser desalinhado.

### 3.2. Por que a assinatura diverge

As assinaturas de referência (`*.reference.hex`) foram geradas em um alvo **com extensão C** (IALIGN = 16), em que saltar para um endereço múltiplo de 2 é válido e **não gera trap**. O RVX é RV32I puro (IALIGN = 32), e a especificação exige que ele gere a exceção *instruction-address-misaligned*, que é o que ele faz.

No `misalign-jal-01`:

| | Referência (com C) | RVX (sem C) |
| :--- | :--- | :--- |
| `JAL x10, 0x33a` em `0x130` | salta para `0x33a` | **trap**, `mcause = 0` |
| Assinatura | `0x0000002b` e nada mais | `0x2a`, `0x8f`, `0x00`, `0x124`, `0x32e` (registro do trap) |

Os 4 últimos valores do RVX são o registro que o *trap handler* do teste faz. A referência não tem esse registro porque, no alvo com C, nenhum trap acontece. A comparação, portanto, nunca pode passar em um núcleo sem C.

---

## 4. O `mepc` está correto: origem do valor `0x138` visto no Verdi

### 4.1. Prova formal

Com o VC Formal (`./scripts/run_formal.sh`, ver [formal_verif.md](formal_verif.md)), as seguintes propriedades foram **provadas** (sem limite de profundidade, com barramento e `halt` livres):

| Propriedade | Status |
| :--- | :--- |
| `ast_mepc_is_faulting_pc`: `mepc` = endereço da instrução que gerou a exceção | **proven** |
| `ast_mepc_misaligned_fetch`: idem, para JAL/JALR/branch desalinhado | **proven** |
| `ast_mcause_misaligned_fetch`: `mcause = 0` | **proven** |
| `ast_mtval_misaligned_fetch`: `mtval` = alvo desalinhado | **proven** |
| `ast_mret_to_mepc`: `mret` retorna para `mepc` | **proven** |

### 4.2. Confirmação na assinatura da simulação

Desmontando o `misalign-jal-01.hex`, o *trap handler* (a partir de `0x54c`) faz:

```text
590:  csrrs x7,mepc,x0       # lê mepc
594:  auipc x28,0x0          # x28 = 0x00c (início do código do teste)
59c:  sub   x29,x7,x28
5a0:  sw    x29,8(x6)        # assinatura: mepc - 0x00c
5a4:  andi  x29,x7,2
5a8:  sub   x7,x7,x29
5ac:  addi  x7,x7,8
5b0:  csrrw x0,mepc,x7       # *** handler REESCREVE mepc = mepc + 8 ***
...
660:  mret
```

Na assinatura do RVX:

| Palavra | Valor | Interpretação |
| :--- | :--- | :--- |
| 2 | `0x00` | `mcause = 0` ✅ |
| 3 | `0x124` | `mepc − 0x00c = 0x124` → **`mepc = 0x130`** ✅ (endereço do `JAL`) |
| 4 | `0x32e` | `mtval − 0x00c = 0x32e` → **`mtval = 0x33a`** ✅ |

O hardware gravou `mepc = 0x130`. O valor **`0x138`** observado no Verdi é o que o **próprio handler escreve** em `0x5b0` (`mepc + 8`), para pular o `JAL` e o `nop` seguinte e retomar em `0x138`. Isso é comportamento intencional do teste, não um descompasso de pipeline.

A proposta de correção da versão original (capturar outro PC no `mepc`) **não deve ser aplicada**.

---

## 5. Corner Case Real: escrita em `rd` durante o trap

A verificação formal falsificou (contra-exemplo com 3 ciclos). As asserções consideram apenas escritas em `rd ≠ x0`, porque `x0` é fixo em zero e escrever nele não tem efeito:

| Propriedade | Status | Contra-exemplo |
| :--- | :--- | :--- |
| `ast_no_rd_write_misaligned_fetch`: JAL/JALR desalinhado não escreve `rd` | **falsified** | `0x0020046f` = `JAL x8, +2` escreve em `x8` |
| `ast_no_rd_write_illegal`: instrução ilegal não escreve `rd` | **falsified** | `0x00004867` = JALR ilegal (`funct3 = 100`) escreve em `x16` |
| `ast_no_rd_write_misaligned_load`: load desalinhado não escreve `rd` | proven | – |

O load desalinhado é tratado corretamente porque `load_request` já é bloqueado por `~take_trap` (`rvx_core.v:556`). A mesma proteção falta na escrita do banco de registradores.

A simulação também mostra isso. No `misalign-jal-01`, a primeira palavra da assinatura é `x10 − 0x10c = 0x2a`, ou seja, `x10 = 0x136 = 0x134 ^ 2`. O valor `0x134` (PC + 4) só pode ter vindo do `JAL x10` que **gerou o trap**. Pela especificação, uma instrução que gera exceção não altera nenhum estado arquitetural, e o `x10` deveria manter o valor anterior.

**Causa:** o *write enable* do banco de registradores não é bloqueado por `take_trap` (`rvx_core.v:1051`):

```verilog
assign integer_file_write_enable =
  integer_file_write_request & !flush & !load_pending;
```

**Sugestão de correção** (a validar com as asserções acima):

```verilog
assign integer_file_write_enable =
  integer_file_write_request & !flush & !load_pending & !take_trap;
```

Esse problema **não** é a causa das 8 falhas: mesmo corrigido, a assinatura continuaria diferente da referência (seção 3.2). Ele é um achado independente, compatível com a observação de que o IP prioriza simplicidade e eficiência para sistemas embarcados e deixa alguns *corner cases* sem tratamento.

---

## 6. Corner Case Real: `minstret` conta instruções que geram trap

O `minstret` (*Machine Instructions Retired*) deve contar apenas instruções concluídas. Pela especificação privilegiada, instruções que geram exceção síncrona, incluindo `ecall` e `ebreak`, não são consideradas *retired*.

| Propriedade | Status | Contra-exemplo |
| :--- | :--- | :--- |
| `ast_minstret_no_count_on_trap`: `minstret` não muda no ciclo seguinte a um trap | **falsified** (4 ciclos) | `0x00044073` = SYSTEM ilegal (`funct3 = 100`, `rd = x0`): `minstret` passa de 0 para 1 |

**Causa:** o contador incrementa em todo ciclo habilitado no estado `STATE_OPERATING`, sem considerar `take_trap` (`rvx_core.v:1369-1370`):

```verilog
if (current_state == STATE_OPERATING)
  csr_minstret <= csr_minstret + 1;
```

**Sugestão de correção** (a validar com a asserção acima):

```verilog
if (current_state == STATE_OPERATING && !take_trap)
  csr_minstret <= csr_minstret + 1;
```

O contra-exemplo usa uma instrução com `rd = x0`, que não escreve registrador. Por isso esse problema é **independente** do da seção 5, embora tenha a mesma raiz: os efeitos colaterais da instrução não são cancelados quando ocorre o trap. O impacto é de métrica: o CPI calculado como `mcycle / minstret` fica menor que o real. Isso é relevante para este projeto, que pretende comparar desempenho entre RVX, RVX-GTMR e RVX-DTMR.

**Hipótese ainda não verificada:** o contador também pode incrementar nos ciclos de espera de load/store (`load_pending`/`store_pending`), contando essas instruções mais de uma vez.

---

## 7. Conclusão

- As 8 falhas `misalign-*` **são esperadas**: o RVX não implementa a extensão C, e as assinaturas de referência assumem IALIGN = 16. A regressão está **54/54 dentro do esperado** pelo projeto do RVX.
- O mecanismo de trap (`mepc`, `mcause`, `mtval`, desvio para `mtvec` e `mret`) está **formalmente provado correto**. A hipótese original de `mepc` adiantado em +8 está **descartada**.
- A verificação formal encontrou **dois corner cases reais** em instruções que geram trap:
  - a escrita em `rd` (JAL/JALR desalinhado e instrução ilegal);
  - a contagem no `minstret`.
  
  Esses são os achados a reportar ao projeto do RVX.

**Próximos passos:**

1. ~~Marcar os 8 testes como `expected_to_fail` no `scripts/run_all_tests.sh`~~ (feito: aparecem como `XFAIL`, e a regressão fica com `Passed: 46 | Failed: 0 | XFail: 8`).
2. Validar formalmente as correções do *write enable* e do `minstret` e abrir issue/PR no repositório do RVX.
3. Escrever uma asserção para verificar a hipótese de contagem dupla do `minstret` em load/store.
