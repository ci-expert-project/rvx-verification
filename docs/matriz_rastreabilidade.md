# Matriz de Rastreabilidade da Verificação do RVX

Guia de referência do plano de verificação do RVX no Verdi Planner. Explica de onde vêm os requisitos, como o plano está organizado, como gerar e ler o relatório de status e o que ainda falta.

Status registrado em 13/11/2026 (branch `feat/setup-dut`, commit `374ab9c`).

---

## 1. Visão geral

A matriz de rastreabilidade liga cada **requisito** à sua **fonte** (spec RISC-V ou documentação do RVX), às **propriedades** que o verificam e ao **status** dessas propriedades.

| Arquivo | Papel | Versionado? |
| :--- | :--- | :--- |
| `synopsys/plan/rvx.hvp` | O plano (a matriz): features, requisitos, ligação com as propriedades | Sim |
| `synopsys/plan/rvx_formal.data` | Status de cada propriedade, gerado a partir do `property_report.rpt` | Não, é gerado |
| `scripts/formal_status_to_hvp.py` | Gera o `.data` e confere a rastreabilidade | Sim |
| `scripts/run_formal.sh` | Roda o VC Formal e chama o script acima no final | Sim |
| `synopsys/plan/urgReport/` | Relatório HTML do plano | Não, é gerado |

O projeto exige ferramentas Synopsys, por isso a matriz usa o **Verdi Planner** (formato `.hvp`).

---

## 2. Fontes de requisitos

Não existe um documento oficial da RISC-V International do tipo "checklist de verificação". Estas são as referências usadas:

| Referência | Para que serve |
| :--- | :--- |
| RISC-V Unprivileged Spec (RV32I) | Semântica de cada instrução |
| RISC-V Privileged Spec, cap. 3 (Machine-Level ISA) | CSRs, traps, interrupções, campos WARL |
| riscv-formal (YosysHQ) | Interface RVFI e checks padrão: `insn_*`, `reg`, `pc_fwd`/`pc_bwd`, `causal`, `liveness`. Serve de modelo de plano formal para cores RISC-V |
| riscv-arch-test / RISCOF (coverpoints `.cgf`) | Cenários por instrução, inspiração para os `cover` |
| Vplans da OpenHW Group (core-v-verif) | Exemplos públicos de plano de verificação de cores RV32 |
| Documentação do RVX | Requisitos de itens custom (fast irqs, barramento, periféricos) |

> Nem todo requisito vem da spec RISC-V. As fast interrupts (`mfie`/`mfip`), o barramento e os periféricos são definidos pelo projeto RVX. Por isso o plano tem o atributo `spec_ref`, que registra a fonte de cada requisito.

---

## 3. Métodos de verificação por módulo

CC e FRV também são verificação **formal**: são apps do VC Formal, assim como o FPV. Muda quem escreve as propriedades.

| App | Você fornece | A ferramenta |
| :--- | :--- | :--- |
| **FPV** (cap. 17 do UG) | SVA escritas à mão | Prova as propriedades |
| **CC** - Connectivity Checking (cap. 13) | CSV de conexões: origem, destino, condição, atraso | Gera e prova uma propriedade por linha |
| **FRV** - Formal Register Verification (cap. 16) | Descrição dos registradores | Gera os checks de reset, RW, RO etc. |
| **FTA** - Formal Testbench Analyzer (cap. 21) | Nada além do ambiente | Injeta falhas no RTL e mostra as que nenhuma asserção detecta |
| **FCA / COI** (cap. 11 e 20) | Nada além do ambiente | Mede a cobertura do design pelas provas |

Regra geral: controle pequeno e cheio de casos de canto vai bem em formal. Datapath longo e sequências temporais extensas (protocolos seriais com divisores de clock) vão melhor em simulação.

| Módulo | Método | Observação |
| :--- | :--- | :--- |
| `rvx_core` | FPV | Já tem o checker `rvx_core_sva.sv` |
| `rvx_bus` | FPV | Candidato clássico: decodificação e mux de resposta, espaço de estados pequeno |
| `rvx_ram` | FPV | Integridade de dados com **endereço simbólico**: uma propriedade cobre todos os endereços |
| `rvx_mtimer` | FPV + FRV | Use propriedades locais. Contadores de 64 bits têm profundidade enorme |
| `rvx_uart`, `rvx_spi` | FRV + sim | Registradores em formal, forma de onda serial em simulação |
| `rvx_gpio` | FRV + FPV | Registradores e lógica dos pinos |
| `rvx` (top) | CC + FPV | CC para conexões (IRQs, barramento), FPV para o mapa de memória |

### Requisitos que surgiram da leitura do `rvx_bus.v`

- **Endereço não mapeado**: o barramento responde com `response = 1` e `read_data = 0`, e a escrita é descartada, sem fault. A spec prevê *access fault*, mas o RVX não implementa (o `access_fault` está comentado no mtimer). É uma decisão de projeto e deve ser documentada.
- **Regiões sobrepostas**: se dois devices casam com o mesmo endereço, vence o de maior índice. Verificar com `$onehot0(device_sel)`.
- **Decodificação com máscara** (`~(size - 1)`): só funciona se `region_size` for potência de 2 e `start_address` estiver alinhado a ela. Vira `assume` no bus e `assert` no top.

---

## 4. Como a matriz foi construída

1. **Inventário (escopo)**: lista do que o DUT realmente implementa, com as escolhas de implementação e a fonte de cada item. O que não existe (PMP, S-mode, `mcountinhibit`) vira N/A justificado. Fontes: `localparam` do RTL e documentação do RVX.
2. **Requisitos atômicos**: cada feature quebrada em frases verificáveis, cada uma com um ID.
3. **Mapeamento**: cada requisito ligado às propriedades `ast_*`/`cov_*` que o verificam.
4. **Status**: preenchido automaticamente a partir do resultado do VC Formal.

---

## 5. Estrutura do plano (`rvx.hvp`)

### Hierarquia

```
rvx
├── core          traps · interrupts · csrs · counters · bus_protocol · x0 · liveness · isa
├── bus           addr_decode · unmapped_access · response_mux
├── ram           data_integrity · write_strobe · handshake
├── mtimer        registers (FRV) · counting · irq
├── uart          registers (FRV) · serial_protocol (sim) · irq
├── spi           registers (FRV) · serial_protocol (sim)
├── gpio          registers (FRV) · pin_logic
└── top           irq_connectivity (CC) · bus_connectivity (CC) · memory_map (FPV)
```

Até 13/11/2026, só o `core` tem requisitos atômicos. Os outros módulos têm apenas a estrutura.

### Atributos e métrica

```systemverilog
attribute string req_id   = "";
attribute string spec_ref = "";
attribute string method   = "";     // formal-FPV, formal-CC, formal-FRV, sim

metric enum {proven, covered, falsified, uncoverable, vacuous, inconclusive} formal;
  aggregator = sum;
  // Verde só se: tem pelo menos uma propriedade aprovada (senão é lacuna)
  // e nenhuma propriedade falhou
  goal = ((formal.proven + formal.covered) > 0) &&
         ((formal.falsified + formal.uncoverable +
           formal.vacuous   + formal.inconclusive) == 0);
endmetric
```

- Asserções e covers estão na **mesma métrica**. Um requisito costuma ter a asserção que prova e o cover que mostra que o cenário é alcançável.
- `vacuous`: asserção `proven` porque o antecedente nunca acontece. Conta como falha.
- `uncoverable`: cover inalcançável, quase sempre sinal de `assume` restritivo demais. Conta como falha.
- A primeira versão da meta não exigia `proven + covered > 0`, e por isso os requisitos **sem propriedade** apareciam verdes. A meta atual os marca em vermelho.

### Exemplo de requisito

```systemverilog
feature CORE_TRAP_005;
  req_id      = "CORE-TRAP-005";
  description = "A instrução que gera exceção não escreve em rd (trap preciso)";
  spec_ref    = "Unpriv. Spec 1.6 (exceptions, traps); Priv. Spec 3.1.15 (mcause)";
  measure formal st;
    source = "ast_no_rd_write_on_exception", "ast_no_rd_write_misaligned_fetch",
             "ast_no_rd_write_illegal", "ast_no_rd_write_misaligned_load";
  endmeasure
endfeature
```

### Convenções

- **Nome da feature** sem hífen (`CORE_TRAP_005`). O ID legível vai em `req_id` (`"CORE-TRAP-005"`).
- **`description`** é um atributo nativo do HVP e não precisa ser declarado. Use-o para escrever o requisito em uma frase.
- **Os atributos são herdados** pelas features filhas. `method` fica na subfeature e só se repete no requisito quando for exceção. `spec_ref` deve ser sobrescrito no requisito com a seção exata.
- **`spec_ref = ""` apaga o valor herdado.** Omita a linha em vez de deixá-la vazia.
- **Requisito sem `measure`** é uma lacuna. As lacunas ficam no fim de cada subfeature, depois do comentário `// ---- Lacunas: requisitos ainda sem propriedade ----`.
- **Números de seção da spec** variam entre versões. Confira no PDF adotado e mantenha o nome do registrador entre parênteses, como em `3.1.14 (mepc)`.

### Erros comuns

| Sintoma | Causa |
| :--- | :--- |
| `undefined assignment metodo is used` | Atributo usado com nome diferente do declarado (`metodo` × `method`) |
| `unexpected token: spec_ref` na linha N | Falta `;` na linha **N-1**. O erro aponta para a linha seguinte |
| Requisito sem `spec_ref` no relatório | `spec_ref = ""` sobrescreveu o valor herdado |

---

## 6. Fluxo de uso

### Atualizar o status e gerar o relatório

```bash
./scripts/run_formal.sh                 # roda o formal e gera synopsys/plan/rvx_formal.data
module load vcs/W-2024.09-SP2-3         # carrega o verdi junto
cd synopsys/plan
urg -full64 -plan rvx.hvp -userdata rvx_formal.data -report urgReport
firefox urgReport/dashboard.html &
```

- Para o relatório em texto, acrescente `-format text` e leia `urgReport/hvp.rvx.txt`.
- No Verdi: `verdi -cov -plan rvx.hvp -userdata rvx_formal.data &`
- Modos do `run_formal.sh`: (nenhum) batch, `gui`, `trace <prop> ...`, `coverage` (formal core). Um modo digitado errado, como `coverge`, roda o modo batch sem avisar.

### O que o `formal_status_to_hvp.py` faz

1. Lê a *Property List* do `property_report.rpt` e escreve `nome = status`. As `assume` (`constrained`) ficam de fora.
2. Converte `proven` com a marca `(vacuous)` em `vacuous`.
3. Converte qualquer status desconhecido (ex.: `not_run`) em `inconclusive`, com aviso.
4. Confere a rastreabilidade nos dois sentidos: propriedade citada no plano que não está no relatório, e propriedade no relatório que não está ligada a nenhum requisito.

Uso avulso: `./scripts/formal_status_to_hvp.py [<report.rpt> <saída.data> [<plano.hvp>]]`

### Como ler o relatório HTML

| Página | O que mostra |
| :--- | :--- |
| `dashboard` | Só a raiz (`rvx`), somando tudo |
| `hvp` | Árvore inteira, uma linha por feature e requisito, com contagem por status |
| Página de um requisito (clicar no nome em `hvp`) | Em *Sources*, o status de cada propriedade. Também mostra os atributos e a meta |
| `userdata` | Lista plana das propriedades com o status e a linha do `.data` |
| `asserts` | **Fica vazia**: é para asserções de simulação (`simv.vdb`), não para o formal |

- A cor indica se a **meta** foi atingida e vale para a linha inteira, não para cada coluna.
- **Vermelho com `formal = 0`**: lacuna, falta escrever a propriedade.
- **Vermelho com `falsified > 0`**: existe propriedade e ela falhou, então é caso de triagem (ver [triagem_casos_pendentes.md](triagem_casos_pendentes.md)).
- "Total Coverage Summary" vazio é normal sem `.vdb` de simulação.

---

## 7. Status em 13/11/2026

Propriedades: 41 no total (30 asserções e 11 covers), todas ligadas a um requisito. Delas, 15 *proven*, 11 *covered* e 15 *falsified*.

Requisitos do `core`:

| Situação | Qtd | Requisitos |
| :--- | :--- | :--- |
| Atendido | 13 | TRAP-002, 006, 007 · IRQ-001, 003, 004 · CNT-001 · BUS-001 a 004 · X0-001 · LIVE-001 |
| Com falha | 12 | TRAP-001, 003, 004, 005, 008 · IRQ-002, 005, 006 · CSR-001 · CNT-002, 003 · BUS-005 |
| Lacuna | 15 | TRAP-009 a 012 · IRQ-007, 008 · CSR-002 a 004 · CNT-004 · ISA-001 a 005 |

Entre as falhas estão os bugs de misaligned já analisados ([bug_analysis_misaligned_mepc.md](bug_analysis_misaligned_mepc.md)) e os 3 casos pendentes de triagem (`ast_ro_csr_write_illegal`, `ast_minstret_no_count_while_waiting`, `ast_bus_word_aligned`).

Formal core (`./scripts/run_formal.sh coverage`, última execução às 13:00): **21,1%** dos bits de flop do DUT (330 de 1562). `integer_file` tem 62 de 1024 bits, porque não há verificação funcional das instruções. `csr_mcause`, `csr_mepc`, `csr_mtvec`, `csr_mscratch` e `csr_mip_m*ip` não entram em nenhuma prova.

---

## 8. Quando o plano está completo

São duas perguntas diferentes.

**A verificação está concluída?** Isso é objetivo e o relatório mostra:

- todo requisito tem pelo menos uma propriedade (nenhum `formal = 0`);
- toda propriedade está ligada a um requisito (aviso do script);
- nenhum *falsified*, *uncoverable*, *vacuous* ou *inconclusive*, ou seja, tudo verde.

**O plano está completo?** Nenhuma ferramenta responde sozinha. Os critérios usuais são:

1. **Cobertura da fonte**: cada seção da spec no escopo e cada linha do inventário aparecem em algum `spec_ref`. O *spec linking* do Verdi Planner (arquivo `rvx.hvp.spc`) mostra os trechos do PDF sem feature ligada.
2. **Nenhuma feature folha vazia.**
3. **Exclusões justificadas** (N/A com motivo).
4. **Revisão** do plano por outra pessoa, contra a spec.

Métricas que indicam requisito faltando: **formal core / COI** (registradores que nenhuma prova usa) e **FTA** (falhas injetadas que nenhuma asserção detecta).

---

## 9. Próximos passos

**Lacunas mais simples para começar** (os covers de ecall, ebreak e misaligned já saem *covered*):

- CORE-CSR-004: `mscratch` é leitura e escrita livres.
- CORE-TRAP-009 a 011: `mcause` de ecall (11), ebreak (3) e illegal (2).
- CORE-TRAP-012: `mcause` e `mtval` de load/store desalinhado.

**Lacunas maiores:**

- CORE-ISA-001 a 005: semântica das instruções. A alternativa mais completa é acrescentar uma porta **RVFI** ao `rvx_core` e adaptar os checks do riscv-formal.
- CORE-IRQ-007/008: prioridade entre interrupções e código em `mcause`. Também verificar o modo vectored do `mtvec` e os bits WARL.
- CORE-CSR-002/003: semântica de CSRRW/S/C e acesso a CSR inexistente.
- CORE-CNT-004: `minstret` +1 por instrução retirada, e carry de `mcycleh`/`minstreth`.
- Reset (PC, `mstatus.MIE`, `misa`) e barramento sem X.

**Outros módulos:** requisitos atômicos e propriedades para `bus` e `ram` (bons primeiros exercícios fora do core), depois CC no top e FRV nos periféricos.

---

## 10. Ferramentas e documentação no CADMICRO

```bash
module load vc_formal/W-2024.09-SP2-5
module load vcs/W-2024.09-SP2-3          # carrega verdi/W-2024.09-SP2-6 junto
```

| Documento | Caminho |
| :--- | :--- |
| VC Formal User Guide | `/tools/synopsys/vc_formal/W-2024.09-SP2-5/doc/vcst/VC_Formal_Docs/VC_Formal_UG.pdf` |
| VC Formal (HTML, com busca) | `.../VC_Formal_Docs/HTML/` |
| VC Formal Quick Reference, Signoff Methodology, Navigator SVA Guide | Mesma pasta do UG |
| Verdi Coverage / Planner (cap. 5) | `/tools/synopsys/verdi/W-2024.09-SP2-6/doc/verdi_coverage.pdf` |
| Tutorial do Planner | `$VERDI_HOME/demo/coverage/quickstart_planner` |

Para abrir um PDF: `evince <caminho> &`

### Tutorial do Planner (comandos testados)

Os scripts originais do tutorial são para 32 bits e usam PLI obsoleto. Use:

```bash
module load vcs/W-2024.09-SP2-3
mkdir -p ~/planner_demo
cp -r $VERDI_HOME/demo/coverage/quickstart_planner/* ~/planner_demo/
chmod -R u+w ~/planner_demo && cd ~/planner_demo
vcs -full64 -sverilog -kdb -debug_access+all -f tr690.vc \
    -cm assert+line+tgl+branch+fsm+cond -l comp.log
./simv -cm assert+line+tgl+branch+fsm+cond -ucli -i vcs_ucli.do -l run.log
verdi -cov -covdir simv.vdb -plan HVP_Example.hvp -userdata HVP_Example.data &
```

O aviso `HVP_INVLD_UD` vem dos dados do próprio tutorial.

### Observações sobre as ferramentas

- `hvp annotate` só aceita plano `.xml` (planilha). Com `.hvp`, o `.data` entra por `-userdata` no `verdi -cov` ou no `urg`.
- O `urg` gera o relatório do plano sem nenhum `.vdb`, só com `-plan` e `-userdata`.
- `save_property_density_results -db_name COI` grava o formal core em VDB, que pode entrar no plano.
- Não foi confirmado se o VC Formal grava o status proven/falsified de cada asserção num VDB que o Planner leia direto. Perguntar no SolvNet ou ao suporte.

---

## 11. Git

O `.gitignore` ignora:

- `vdCov.conf` e `vdCovLog/`: sessão do Verdi (janela, fonte, logs, nome da máquina);
- `synopsys/plan/rvx_formal.data`: gerado a cada execução do formal, assim como o `property_report.rpt`;
- `urgReport/`, `novas.rc`, `verdiLog/`: já eram ignorados.

Quem clonar o repositório precisa rodar `./scripts/run_formal.sh` uma vez antes de abrir o plano com status. Se o *spec linking* for usado, o `rvx.hvp.spc` **deve** ser versionado.

O relatório HTML não vai para o GitHub: o GitHub não renderiza HTML, e o `urg` só roda no CADMICRO por causa da licença.

### Atualizar o branch com o `main`

Em 13/11/2026, o `main` estava 10 commits à frente (PR #4 do `joao/verification`).

- **`git rebase origin/main`**: não recomendado. Para no primeiro commit com conflito em 4 arquivos (`init.sh`, `run_test.sh`, `scripts/run_all_tests.sh`, `synopsys/tb/rvx_tb.sv`) e provavelmente terá mais rodadas. O branch já está no GitHub, então exigiria `push --force`.
- **`git merge origin/main`**: recomendado. Conflito em um arquivo só (`scripts/run_all_tests.sh`) e push normal.
- O `main` local tem um commit que não está no GitHub (`eac83ed`, já incluído no branch) e está 14 commits atrás. Para alinhar: `git checkout main && git reset --hard origin/main`.
