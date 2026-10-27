# Fase 4 — Progresso do João (frente 3: OpenTelemetry Collector)

Atualizado em 27/10/2026. Arquivo para retomar o trabalho em outro computador.

## Onde está o código

Fork: `https://github.com/jotaven/tech-challenge-feature-flags-fase4`
Original (Gabriel): `https://github.com/Gabrielpalhanogomes2803/tech-challenge-feature-flags`

| Branch no fork | Conteúdo | Situação |
|---|---|---|
| `feat/fase4-otel-collector-v2` | Collector no padrão do Gabriel (`gitops/monitoring/otel-collector`), Alloy → Collector → Loki, bootstrap, stack local, gerador de telemetria, este arquivo | **Usar esta.** Feita sobre o `main` do Gabriel de 23/10, sem conflito |
| `feat/fase4-instrumentacao-python-v2` | OpenTelemetry nos serviços flag, targeting e analytics | **Usar esta.** Feita sobre o `main` do Gabriel de 23/10, sem conflito |
| `feat/fase4-otel-collector` | Versão anterior do Collector (pastas antigas, sem a mudança de logs) | Obsoleta |
| `feat/fase4-instrumentacao-python` | Versão antiga da instrumentação | Obsoleta: conflita com os logs JSON do Gabriel |

Para continuar:

```bash
git clone https://github.com/jotaven/tech-challenge-feature-flags-fase4.git
cd tech-challenge-feature-flags-fase4
git remote add upstream https://github.com/Gabrielpalhanogomes2803/tech-challenge-feature-flags.git
git fetch origin upstream
git checkout feat/fase4-otel-collector-v2
```

## Decisão tomada: logs passam pelo Collector (opção A)

Alloy → OTel Collector (OTLP) → Loki. O Collector é a peça central de métricas,
logs e traces, como pede o enunciado, e não há duplicação. Os rótulos usados
pelo dashboard (`service_name="togglemaster"` e `container`) foram mantidos.
Detalhes e teste em `observability/README.md`, seção "Logs".

## O que já está feito e testado

- **Collector:** DaemonSet com OTLP, k8sattributes e spanmetrics; métricas para o
  Prometheus (remote write), logs para o Loki (OTLP) e traces para o New Relic.
  Application `togglemaster-otel-collector` registrada no bootstrap.
- **Logs via Alloy:** testado localmente com Alloy, Collector e Loki reais:
  100 de 100 linhas entregues; as consultas do dashboard funcionam sem mudança.
- **Métricas:** taxa de 5xx do auth calculada pelo spanmetrics deu 24% para 25%
  simulados.
- **Instrumentação Python:** Flask, requests, psycopg2 e botocore automáticos; o
  analytics continua o trace que vem pela SQS (atributo `traceparent`). Testado
  com o código de logs JSON do Gabriel.

## Pendências com outras frentes

- **Gabriel:** revisar e aceitar os dois PRs (o do Collector mexe nos values do
  Alloy e do Loki); na implantação, subir o Collector antes de sincronizar o
  Alloy (sem sync automático); criar o Secret `newrelic-license`
  (chave `license-key`) no namespace `monitoring`.
- **Gustavo:** license key do New Relic; instrumentar auth e evaluation (Go);
  passar o contexto para `sendEvaluationEvent` com
  `context.WithoutCancel(r.Context())` e injetar o `traceparent` nos
  `MessageAttributes` (exemplo em `docs/fase4-instrumentacao-python.md`, na
  branch de instrumentação).
- **Susana:** o Gabriel criou regras de alerta no Prometheus, mas o Alertmanager
  está desligado. Combinar se os alertas ficam no Grafana. A taxa de erro por
  serviço vem de `traces_span_metrics_calls_total` (consulta no
  `observability/README.md`).
- **Heloisa:** os serviços têm 2 réplicas. O `/chaos/enable` chamado pelo
  Service ativa a falha em um pod só (taxa de erro perto de 50%, ainda acima de 5%).

## Próximos passos meus

1. Abrir os PRs de `feat/fase4-otel-collector-v2` e
   `feat/fase4-instrumentacao-python-v2` para o repositório do Gabriel.
2. Com o cluster ligado: conferir `togglemaster-otel-collector` Synced/Healthy,
   os logs no Grafana e `traces_span_metrics_calls_total` no Prometheus.
3. Sugerir ao Gabriel um painel de req/s e erros por serviço com o spanmetrics
   (o dashboard atual só tem as sondas de `/health`, e o enunciado pede
   requisições dos microsserviços).
4. Opcional: incluir `trace_id` e `span_id` nos logs JSON para pular do log ao
   trace no Grafana.
5. Prints da minha frente, diagrama da arquitetura OTel e parágrafo técnico para
   o relatório (até 05/11).

## Datas do grupo

- 01/11: integração pronta (traces, logs e métricas visíveis; Service Map completo)
- 05/11: evidências salvas; fluxo de incidente ensaiado 3 vezes
- 07–08/11: reunião final, gravação e entrega
- 17/11: prazo oficial
