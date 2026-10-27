# Fase 4 — Progresso do João (frente 3: OpenTelemetry Collector)

Atualizado em 27/10/2026. Arquivo para retomar o trabalho em outro computador.

## Onde está o código

Fork: `https://github.com/jotaven/tech-challenge-feature-flags-fase4`
Original (Gabriel): `https://github.com/Gabrielpalhanogomes2803/tech-challenge-feature-flags`

| Branch no fork | Conteúdo | Situação |
|---|---|---|
| `feat/fase4-otel-collector` | Collector (values do EKS, Application do Argo CD), stack local, gerador de telemetria, este arquivo | Pronta para PR. Aplica sem conflito no `main` do Gabriel de 23/10 |
| `feat/fase4-instrumentacao-python-v2` | OpenTelemetry nos serviços flag, targeting e analytics, refeito sobre o `main` do Gabriel de 23/10 | Pronta para PR. Sem conflito |
| `feat/fase4-instrumentacao-python` | Versão antiga da instrumentação | **Obsoleta**: conflita com os logs JSON do Gabriel. Não usar |

Para continuar:

```bash
git clone https://github.com/jotaven/tech-challenge-feature-flags-fase4.git
cd tech-challenge-feature-flags-fase4
git remote add upstream https://github.com/Gabrielpalhanogomes2803/tech-challenge-feature-flags.git
git fetch origin upstream
git checkout feat/fase4-otel-collector
```

## O que já está feito e testado

- **Collector:** DaemonSet com OTLP, k8sattributes e spanmetrics; exporta métricas
  para o Prometheus (remote write), logs para o Loki (OTLP) e traces para o New Relic.
  Config validada com `otelcol-contrib validate` 0.161.0.
- **Endereços conferidos com a stack do Gabriel:**
  `togglemaster-prometheus-server.monitoring.svc.cluster.local/api/v1/write` e
  `togglemaster-loki.monitoring.svc.cluster.local:3100/otlp`.
- **Teste ponta a ponta local** (binários reais de Collector, Prometheus e Loki):
  métricas e logs chegaram; a taxa de 5xx do auth calculada pelo spanmetrics deu
  24% para 25% simulados.
- **Instrumentação Python:** Flask, requests, psycopg2 e botocore automáticos; o
  analytics continua o trace que vem pela SQS (atributo `traceparent`). Testado
  com o código de logs JSON do Gabriel.

## Decisão pendente com o grupo: logs

O Gabriel já coleta os logs dos contêineres com o **Grafana Alloy**, que envia direto
ao Loki. Se o Collector também lesse os logs (filelog), cada linha chegaria duas vezes.

| Opção | Como fica | Prós | Contras |
|---|---|---|---|
| **A (recomendada)** | Alloy → Collector (OTLP) → Loki | Collector central para os 3 sinais, como pede o enunciado; sem duplicação | Ajustar o `loki.write` do Alloy para `otelcol.exporter.otlp`; revisar os painéis de log do dashboard (rótulos mudam) |
| B | Alloy → Loki; Collector só traces e métricas | Nenhuma mudança no que já funciona | O enunciado pede o Collector roteando logs também; risco na avaliação |

Enquanto não houver decisão, o preset `logsCollection` do Collector está **desligado**.

## Pendências com outras frentes

- **Gabriel:** aplicar `gitops/argocd/observability/otel-collector.yaml` junto com as
  outras Applications de monitoramento; criar o Secret `newrelic-license`
  (chave `license-key`) no namespace `monitoring`. Se a opção A for aprovada,
  apontar o Alloy para `otel-collector-opentelemetry-collector-agent.monitoring.svc:4317`
  (confirmar o nome do Service depois do primeiro deploy).
- **Gustavo:** license key do New Relic; instrumentar auth e evaluation (Go);
  passar o contexto para `sendEvaluationEvent` com `context.WithoutCancel(r.Context())`
  e injetar o `traceparent` nos `MessageAttributes` (exemplo em
  `docs/fase4-instrumentacao-python.md`, na branch de instrumentação).
- **Susana:** o Gabriel criou regras de alerta no Prometheus, mas o Alertmanager está
  desligado. Combinar se os alertas ficam no Grafana. A taxa de erro por serviço
  virá de `traces_span_metrics_calls_total` (consulta no `observability/README.md`).
- **Heloisa:** os serviços agora têm 2 réplicas. O `/chaos/enable` chamado pelo
  Service ativa a falha em um pod só (taxa de erro perto de 50%, ainda acima de 5%).

## Próximos passos meus

1. Levar a decisão dos logs ao grupo.
2. Abrir os PRs das duas branches para o repositório do Gabriel.
3. Com o cluster ligado: conferir o Collector `Synced/Healthy` e consultar
   `traces_span_metrics_calls_total` no Prometheus.
4. Sugerir ao Gabriel um painel de req/s e erros por serviço com o spanmetrics
   (o dashboard atual só tem as sondas de `/health`, e o enunciado pede requisições
   dos microsserviços).
5. Opcional: incluir `trace_id` e `span_id` nos logs JSON para pular do log ao trace
   no Grafana.
6. Diagrama da arquitetura OTel para o relatório (até 05/11).

## Datas do grupo

- 01/11: integração pronta (traces, logs e métricas visíveis; Service Map completo)
- 05/11: evidências salvas; fluxo de incidente ensaiado 3 vezes
- 07–08/11: reunião final, gravação e entrega
- 17/11: prazo oficial
