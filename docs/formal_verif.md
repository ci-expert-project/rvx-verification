# Verificação Formal de Propriedades (SVA) — VC Formal

Este documento descreve como executar a verificação formal de propriedades (FPV) do núcleo **RVX** (`rvx_core`) com o **VC Formal** da Synopsys (`vc_static_shell`).

---

## 1. Visão Geral

Diferente do Formality (equivalência lógica RTL × netlist), o **VC Formal FPV** prova matematicamente que as asserções SVA (`assert property`) valem para **qualquer sequência de estímulos** nas entradas do bloco, sem vetores de teste.

No `rvx_core`, isso significa que o barramento (`read_data`, `read_response`, `write_response`) e `halt` ficam livres: a ferramenta explora qualquer programa e qualquer latência de memória.

---

## 2. Estrutura de Arquivos

```text
rvx-verification/
├── dut/rvx/hardware/rvx_core.v      # RTL do núcleo (submódulo, não é alterado)
└── synopsys/formal/
    ├── rvx_core_sva.sv              # Checker SVA + bind em rvx_core
    ├── rvx_core_formal.f            # Filelist (RTL + SVA)
    └── run_vc_formal.tcl            # Script do VC Formal
```

O checker é ligado ao núcleo via `bind rvx_core rvx_core_sva u_rvx_core_sva (.*);`, então ele enxerga sinais internos (`take_trap`, `csr_mepc`, ...) sem modificar o RTL do DUT.

O testbench de simulação (`synopsys/tb/*.sv`) **não** entra no fluxo formal: ele contém `initial`, atrasos e modelos de memória que não são sintetizáveis.

---

## 3. Propriedades Implementadas

Escopo atual: **exceções síncronas** em modo M. As interrupções são fixadas em zero (`asm_no_irq`).

| Propriedade | O que verifica |
| :--- | :--- |
| `ast_mepc_is_faulting_pc` | Ao tomar uma exceção, `mepc` recebe o endereço da instrução que a causou |
| `ast_mepc_misaligned_fetch` | Idem, restrito a salto/desvio com alvo desalinhado (testes `misalign-*`) |
| `ast_mepc_aligned` | `mepc[1:0]` é sempre `00` (IALIGN = 32) |
| `ast_mcause_misaligned_fetch` | `mcause = 0` (*Instruction address misaligned*) |
| `ast_mtval_misaligned_fetch` | `mtval` = endereço-alvo desalinhado |
| `ast_no_rd_write_on_exception` | A instrução que gera exceção não escreve em `rd` (escritas em `x0` são ignoradas, pois não têm efeito arquitetural) |
| `ast_no_rd_write_misaligned_fetch` / `_illegal` / `_misaligned_load` | Idem, separado por causa da exceção |
| `ast_minstret_no_count_on_trap` | O contador `minstret` não é incrementado por uma instrução que gera trap (incluindo `ecall`/`ebreak`) |
| `ast_pc_to_trap_vector` | Depois de `TRAP_TAKEN`, o PC vai para o vetor de trap |
| `ast_mret_to_mepc` | `mret` retorna para `mepc` |
| `cov_*` | Covers que confirmam que cada cenário é alcançável (evitam prova vazia) |

O endereço de referência da instrução em execução (`exec_pc`) é um registrador do próprio checker: ele guarda o endereço buscado no último ciclo habilitado (`clock_enable`). Os ciclos de *commit* de load/store ficam de fora, porque neles o núcleo repete a instrução anterior.

### 3.1 Resultados (DUT `7af8290`, 31/10/2026)

| Propriedade | Status |
| :--- | :--- |
| `ast_mepc_is_faulting_pc`, `ast_mepc_misaligned_fetch`, `ast_mepc_aligned` | **proven** |
| `ast_mcause_misaligned_fetch`, `ast_mtval_misaligned_fetch` | **proven** |
| `ast_pc_to_trap_vector`, `ast_mret_to_mepc` | **proven** |
| `ast_no_rd_write_misaligned_load` | **proven** |
| `ast_no_rd_write_misaligned_fetch` | **falsified** (profundidade 3) |
| `ast_no_rd_write_illegal` | **falsified** (profundidade 3) |
| `ast_no_rd_write_on_exception` | **falsified** (consequência das duas acima) |
| `ast_minstret_no_count_on_trap` | **falsified** (profundidade 4) |
| Todos os `cov_*` | **covered** |

Resumo: 12 asserções (8 *proven*, 4 *falsified*) e 6 covers (6 *covered*).

| Contra-exemplo | Instrução no ciclo da falha | Efeito indevido |
| :--- | :--- | :--- |
| `ast_no_rd_write_misaligned_fetch` | `0x0020046f` = `JAL x8, +2` (alvo desalinhado) | escreve PC+4 em `x8` |
| `ast_no_rd_write_illegal` | `0x00004867` = JALR com `funct3 = 100` (ilegal), `rd = x16` | escreve em `x16` |
| `ast_minstret_no_count_on_trap` | `0x00044073` = SYSTEM com `funct3 = 100` (ilegal), `rd = x0` | `minstret` passa de 0 para 1 |

Conclusões:

1. **O `mepc` está correto.** A prova vale para qualquer programa e qualquer latência de memória, o que descarta a hipótese de `mepc` adiantado em +8 levantada em [bug_analysis_misaligned_mepc.md](bug_analysis_misaligned_mepc.md).
2. **As 8 falhas `misalign-*` são esperadas.** O próprio RVX as lista em `expected_to_fail` (`dut/rvx/hardware/tests/core/vivado/unit_tests.v`). As referências foram geradas em um alvo com IALIGN = 16 (extensão C), em que um salto para endereço múltiplo de 2 é válido e não gera trap. O RVX (RV32I, IALIGN = 32) gera o trap *instruction-address-misaligned*, como a especificação exige para um núcleo sem C.
3. **Corner case real encontrado pelo formal.** Quando a instrução que gera o trap tem `rd` (JAL/JALR com alvo desalinhado, ou uma codificação ilegal com campo `rd` ≠ 0), o banco de registradores é escrito mesmo assim. A causa é que `integer_file_write_enable` (`rvx_core.v:1051`) não é bloqueado por `take_trap`. Pela especificação, a instrução que gera exceção não pode alterar o estado arquitetural.
4. **Segundo corner case: `minstret` conta instruções que geram trap.** O contador é incrementado em todo ciclo habilitado no estado `STATE_OPERATING` (`rvx_core.v:1369-1370`), sem considerar `take_trap`. Pela especificação, instruções que geram exceção síncrona (incluindo `ecall` e `ebreak`) não são *retired* e não devem ser contadas. O contra-exemplo usa uma instrução com `rd = x0`, portanto o problema é independente do item 3. O efeito é uma distorção de métricas: o CPI calculado como `mcycle / minstret` fica menor que o real.

---

## 4. Como Executar

No CADMICRO, a partir da raiz do repositório:

```bash
./scripts/run_formal.sh        # batch: imprime o status de cada propriedade
./scripts/run_formal.sh gui    # GUI: debug de contra-exemplos
```

### Contra-exemplos sem GUI

Para conexões lentas (X11), o modo `trace` salva o contra-exemplo em FSDB (`fv_trace_save`), converte para VCD (`fsdb2vcd`) e imprime os sinais ciclo a ciclo (`scripts/cex_table.py`):

```bash
./scripts/run_formal.sh trace ast_no_rd_write_misaligned_fetch ast_no_rd_write_illegal
```

```text
cycle  reset  current_state  program_counter  instruction  ...  take_trap  integer_file_write_enable  instruction_rd_address
4      0      2              00000000         0020046f     ...  1          1                          08
```

Os sinais mostrados podem ser trocados com `CEX_SIGNALS="sinal1 sinal2 ..."`. O FSDB fica em `synopsys/formal/traces/` e pode ser aberto depois no Verdi.

A execução completa leva menos de 1 minuto. O relatório fica em `synopsys/formal/property_report.rpt` e o log em `synopsys/formal/vc_formal.log`.

> **Licença:** o servidor `27010@pgmicro01.ufrgs.br` só tem as features *legadas* do VC Formal. Sem opção, a ferramenta tenta `fml_base` → `fml_fv` e falha com `LICENSE_CHECKOUT_ERROR`; `-fml_base` e `-fml_elite` dão `LICENSE_MODE_INVALID`. O modo que funciona é **`-fml_ultra`**, que o script já usa. Para rodar manualmente:
>
> ```bash
> module load vc_formal
> cd synopsys/formal
> vc_static_shell -fml_ultra -f run_vc_formal.tcl
> ```

Na GUI, clique com o botão direito na propriedade *falsified* e escolha **View Trace** para abrir a forma de onda do contra-exemplo no Verdi.

---

## 5. Interpretação dos Resultados

| Status | Significado | Ação |
| :--- | :--- | :--- |
| **proven** | A propriedade vale para todos os estímulos e todos os ciclos. | Nenhuma. |
| **falsified** | Existe uma sequência de estímulos que viola a asserção. | Abrir o contra-exemplo na GUI. |
| **vacuous** | O antecedente nunca ocorre. | Rever a SVA ou as assumptions. |
| **inconclusive** | A ferramenta atingiu o limite de tempo ou de profundidade (*bounded*). | Aumentar o tempo ou simplificar a propriedade. |
| **covered** / **uncoverable** | O cenário do `cover` é / não é alcançável. | `uncoverable` indica restrição demais no ambiente. |

---

## 6. Próximos Passos

- Remover `asm_no_irq` e acrescentar propriedades para interrupções (`mstatus.MIE/MPIE`, `mcause` com bit de interrupção).
- Cobrir `mepc`, `mcause` e `mtval` para `illegal_instruction`, `ecall`, `ebreak` e load/store desalinhados.
- Propriedades do protocolo de barramento (`read_request`/`read_response`).
