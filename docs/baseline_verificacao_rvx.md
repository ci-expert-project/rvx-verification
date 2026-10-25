# Baseline de Verificação Funcional do RVX com Synopsys VCS

## 1. Objetivo

Registrar o baseline de verificação funcional do processador RVX utilizando
Synopsys VCS, preservando os resultados originais e os artefatos necessários
para rastreabilidade e reprodução do experimento.

Este baseline caracteriza a execução dos testes disponíveis no fluxo de
verificação do núcleo. Não representa uma comparação entre implementações
com diferentes níveis de redundância TMR.

## 2. Escopo

O experimento foi executado sobre o núcleo RVX, utilizando:

- Lista de arquivos: `synopsys/filelist/rvx_core.f`
- Testbench: `synopsys/tb/rvx_core_tb.sv`
- RTL do núcleo: `dut/rvx/hardware/rvx_core.v`
- RTL da memória: `dut/rvx/hardware/rvx_ram.v`
- Resumo dos resultados: `synopsys/log/baseline_20261014/summary.tsv`

O fluxo de sistema completo também está presente no repositório, por meio de
`synopsys/filelist/rvx.f` e `synopsys/tb/rvx_tb.sv`. Sua existência não implica
que esse fluxo tenha sido validado neste baseline.

## 3. Ambiente de execução

| Item | Registro |
|---|---|
| Simulador | Synopsys VCS |
| Versão registrada | W-2024.09-SP2-3_Full64 |
| Ambiente | CADMICRO, Linux |
| Toolchain RISC-V | `riscv64-elf/14.2.0` |
| Data do baseline | 14/10/2026 |
| Branch | `fix/block-writeback-on-trap-20261009` |
| Commit do repositório principal | `0d24adfb753e82222ac94e2ec59d04d1ff52a362` |
| Tag do submódulo RVX | `v3.2` |
| Commit do submódulo RVX | `7af8290a770e6cb17e49dea75268a582bff5261f` |

Os identificadores completos dos commits e demais informações de execução
devem ser conferidos em `baseline_metadata.txt`.

## 4. Estrutura do fluxo de verificação

### 4.1 Lista de arquivos

O arquivo `synopsys/filelist/rvx_core.f` define os arquivos usados no fluxo
do núcleo. O RTL considerado inclui o núcleo RVX e sua memória.

A lista `synopsys/filelist/rvx.f` pertence ao fluxo de sistema completo e
inclui outros módulos periféricos. Esse fluxo não faz parte dos resultados
reportados neste documento.

### 4.2 Testbench

O testbench `synopsys/tb/rvx_core_tb.sv`:

1. Obtém o nome do teste por meio de `+TEST_NAME`.
2. Carrega o programa de teste em formato `.hex`.
3. Carrega o arquivo de referência `.reference.hex`.
4. Executa o teste e observa o endereço de conclusão `0x1000`.
5. Compara a assinatura produzida com a assinatura de referência.
6. Registra o resultado e gera uma falha fatal quando há divergência na
   comparação da assinatura.

O limite configurado é de 500.000 ciclos. O resultado é considerado PASS
quando não há erros na comparação; divergências na assinatura resultam em
FAIL.

## 5. Procedimento experimental

O baseline foi compilado e executado em 14/10/2026.

Na execução registrada, a compilação foi realizada separadamente e o
executável de simulação resultante foi reutilizado para executar os testes
individualmente.

O script `run_test.sh` também está disponível, mas seu fluxo compila e executa
um teste por chamada. Portanto, esse comportamento deve ser distinguido do
procedimento utilizado para produzir o baseline registrado.

Os artefatos originais devem ser preservados para permitir auditoria e
reprodução dos resultados.

## 6. Resultados do baseline

| Resultado | Quantidade | Percentual |
|---|---:|---:|
| PASS | 46 | 85,2% |
| FAIL | 8 | 14,8% |
| Total | 54 | 100% |

Os resultados individuais estão registrados em `summary.tsv` e nos logs
correspondentes. Os resultados brutos são mantidos como PASS ou FAIL; a
classificação de uma falha como limitação conhecida não altera o resultado
original da simulação.

### 6.1 Testes com resultado FAIL

Os oito testes abaixo apresentaram divergências na comparação de assinaturas:

- `misalign2-jalr-01`
- `misalign-beq-01`
- `misalign-bge-01`
- `misalign-bgeu-01`
- `misalign-blt-01`
- `misalign-bltu-01`
- `misalign-bne-01`
- `misalign-jal-01`

Esses testes correspondem aos casos de saltos e desvios com endereços de
instrução desalinhados identificados como esperados para falhar no testbench
Vivado, em `dut/rvx/hardware/tests/core/vivado/unit_tests.v`.

O testbench Synopsys utilizado neste experimento não aplica esse mecanismo
de classificação de falhas esperadas. Consequentemente, as divergências
aparecem como FAIL no baseline.

Essa correspondência indica uma limitação conhecida documentada no projeto,
mas não substitui uma análise detalhada da causa de cada divergência.

## 7. Artefatos e rastreabilidade

Os artefatos do baseline estão em:

`synopsys/log/baseline_20261014/`

O diretório contém, entre outros:

- `summary.tsv`: resumo dos resultados dos testes.
- `baseline_report.txt`: relatório consolidado do experimento.
- `baseline_metadata.txt`: metadados de execução e identificação das versões.
- `source_sha256.txt`: hashes das fontes registradas.
- `logs_sha256.txt`: hashes dos logs.
- `programs_sha256.txt`: hashes dos programas e arquivos de referência.
- `dumps_sha256.txt`: hashes dos dumps gerados.
- Logs individuais dos testes e log de compilação.

Os manifestos SHA-256 permitem verificar se os arquivos correspondem aos
artefatos registrados no baseline. Para auditorias futuras, devem ser
preservados juntamente com os arquivos aos quais se referem.

## 8. Limitações e interpretação

1. O resultado caracteriza o conjunto de 54 testes executados, não a cobertura
   funcional completa da arquitetura RISC-V.
2. A taxa de PASS de 85,2% é a taxa bruta observada no experimento.
3. Os oito FAILs são associados a testes de instruções com endereços
   desalinhados, uma limitação documentada no projeto. Isso não autoriza
   contabilizá-los como PASS.
4. A existência de uma lista de arquivos para o sistema completo não comprova
   que os periféricos ou a integração do sistema tenham sido validados.
5. Este baseline não fornece, por si só, cobertura funcional quantitativa,
   cobertura de código ou comparação entre versões com TMR.
6. Nenhuma alteração de RTL é necessária para documentar os resultados
   registrados.

## 9. Próximas etapas

- Investigar quais métricas de cobertura de código e cobertura funcional
  podem ser obtidas com a infraestrutura Synopsys disponível.
- Definir testes adicionais ou métricas complementares, conforme os
  objetivos do projeto e os recursos efetivamente disponíveis.
- Alinhar com a orientação acadêmica o escopo do projeto caso as versões
  alternativas com TMR continuem indisponíveis.

## 10. Fechamento documental do baseline

**Data da validação documental:** 2026-10-24

### 10.1. Consistência dos resultados

Foi realizada uma comparação entre a matriz de testes e o resumo do baseline:

- Matriz: `docs/matriz_testes_rvx.tsv`.
- Resumo: `synopsys/log/baseline_20261014/summary.tsv`.
- Testes na matriz: 54.
- Testes no resumo: 54.
- Resultados `PASS`: 46 (85,2%).
- Resultados `FAIL`: 8 (14,8%).
- Testes duplicados na matriz: nenhum.
- Testes ausentes ou extras: nenhum.
- Divergências entre os resultados dos arquivos: nenhuma.

A validação confirma a consistência entre a matriz e o resumo. Ela não
constitui uma nova execução da simulação nem uma validação independente
do comportamento funcional do processador.

### 10.2. Interpretação dos resultados

Os oito resultados `FAIL` foram preservados como registrados no baseline
Synopsys. Os testes correspondentes estão relacionados a desvios ou saltos
com endereços desalinhados e aparecem classificados como falhas esperadas
na infraestrutura de testes Verilator/Vivado do projeto.

Essa classificação é evidência de uma limitação conhecida no contexto
dos testes existentes; não transforma os resultados `FAIL` do baseline
Synopsys em `PASS`.

### 10.3. Limites do baseline

- O experimento cobre os 54 testes executados no fluxo de nível de núcleo
  (`rvx_core`); não demonstra cobertura funcional completa do processador.
- Não foi estabelecida uma métrica quantitativa de cobertura funcional
  nem de cobertura de código.
- O fluxo de sistema completo não foi validado neste baseline.
- Não foi realizada comparação entre versões com e sem TMR.
- Nenhuma alteração de RTL foi necessária para registrar e documentar
  os resultados.

### 10.4. Estado de encerramento

O baseline de simulação e sua conferência documental estão concluídos
para o escopo descrito neste documento. A matriz e o resumo apresentam
resultados consistentes.

A investigação de cobertura, a validação do fluxo de sistema completo
e a comparação entre implementações com TMR permanecem como atividades
futuras, condicionadas aos objetivos acordados e à disponibilidade
das implementações necessárias.
