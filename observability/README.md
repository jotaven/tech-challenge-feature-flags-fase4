# Observabilidade - OpenTelemetry Collector (Fase 4, frente 3)

O Collector é a peça central da telemetria: recebe traces, métricas e logs e
roteia cada sinal para o backend certo.

| Sinal    | Entrada                                   | Processamento                          | Saída no EKS              | Saída local     |
|----------|-------------------------------------------|----------------------------------------|---------------------------|-----------------|
| Traces   | OTLP dos apps                             | k8sattributes, resource, batch         | New Relic (OTLP)          | Jaeger          |
| Métricas | OTLP dos apps + spanmetrics (dos traces)  | k8sattributes, resource, batch         | Prometheus (remote write) | Prometheus      |
| Logs     | OTLP do Alloy (logs dos pods)             | groupbyattrs, transform, resource, batch | Loki (OTLP nativo)      | Loki            |

O connector **spanmetrics** transforma cada span em métricas de chamadas e
duração por serviço, rota e status HTTP. O formato é o mesmo para Go e Python,
o que simplifica o dashboard e a regra de alerta.

## Arquivos

| Arquivo | Para quê |
|---|---|
| `observability/local/docker-compose.observability.yml` | Stack local: Collector, Prometheus, Loki, Jaeger, Grafana |
| `observability/local/otelcol-local.yaml` | Config do Collector para o teste local |
| `observability/local/gerar_telemetria.py` | Gera traces, métricas e logs no formato do ToggleMaster, com taxa de erro configurável |
| `gitops/monitoring/otel-collector/values.yaml` | Values do chart oficial para o EKS (DaemonSet) |
| `gitops/argocd/monitoring-otel-collector.yaml` | Application do Argo CD que instala o chart |
| `gitops/monitoring/alloy/values.yaml` | Alloy passa a encaminhar os logs para o Collector |
| `gitops/monitoring/loki/values.yaml` | Loki indexa o rótulo `container` dos logs recebidos por OTLP |

## Teste local

Pré-requisito: Docker. Rode tudo a partir da raiz do repositório.

**1. Só a stack de observabilidade, com telemetria sintética**

```bash
docker compose --project-directory . -f observability/local/docker-compose.observability.yml --profile teste up
```

**2. Simular o ToggleMaster com erros no auth-service** (útil para o dashboard e o alerta)

```bash
pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-grpc
python observability/local/gerar_telemetria.py --segundos 120 --taxa-erro 0.2
```

**3. Junto com os microsserviços** (quando a instrumentação estiver pronta)

```bash
docker compose -f docker-compose.yml -f observability/local/docker-compose.observability.yml up --build
```

### O que conferir

| Onde | O que deve aparecer |
|---|---|
| http://localhost:13133 | `"status":"Server available"` |
| Grafana http://localhost:3000 → Explore → Prometheus | `traces_span_metrics_calls_total` por `service_name` |
| Grafana → Explore → Loki | `{service_name="auth-service"}` com logs INFO e ERROR |
| Jaeger http://localhost:16686 | traces evaluation → flag → auth |

Taxa de 5xx do auth-service (base para a regra de alerta da frente 5):

```promql
sum(rate(traces_span_metrics_calls_total{service_name="auth-service", http_response_status_code=~"5.."}[2m]))
/
sum(rate(traces_span_metrics_calls_total{service_name="auth-service"}[2m]))
```

Com `--taxa-erro 0.25`, essa consulta retornou 0,24 no teste.

## EKS

O Argo CD instala o chart `open-telemetry/opentelemetry-collector` 0.174.2 com
os values de `gitops/monitoring/otel-collector/values.yaml` (Application
`togglemaster-otel-collector`, registrada em `scripts/aws/05-bootstrap-cluster.sh`).

Endereços conferidos com a stack do Gabriel em 27/10: Prometheus
`togglemaster-prometheus-server` e Loki `togglemaster-loki:3100`.

### Logs: Alloy → Collector → Loki (decisão de 27/10)

O Alloy continua lendo os logs dos pods do namespace `togglemaster`, mas agora
envia por OTLP para o Service `togglemaster-otel-collector:4317` em vez de ir
direto ao Loki. Assim o Collector é a peça central dos três sinais e não há
leitura duplicada dos mesmos arquivos (o filelog do chart fica desligado).

No caminho, o Collector:

1. sobe os rótulos `container`, `pod` e `namespace` do Alloy para o *resource*
   (`groupbyattrs`), que é o que o Loki indexa;
2. troca os `k8s.*` que o `k8sattributes` associou ao pod do Alloy pelos do pod
   que gerou o log (`transform`);
3. grava `service.name = togglemaster`, mantendo as consultas do dashboard
   `{service_name="togglemaster", container="<serviço>"}`.

O Loki indexa `container` além dos rótulos padrão do OTLP (`service_name`,
`k8s_pod_name`, `k8s_namespace_name`, `k8s_container_name`).

**Testado localmente (27/10)** com Alloy 1.11.3, Collector 0.161.0 e Loki 3.5.3
usando a config real do Alloy (só a fonte trocada por push HTTP): 100 de 100
linhas entregues nos 5 serviços; as consultas do painel de logs, do volume por
`container` e do filtro de erros retornaram como antes; os `k8s.*` do pod do
Alloy foram removidos.

**Ordem de implantação:** subir o Collector primeiro e depois sincronizar o
Alloy (a Application `togglemaster-alloy` não tem sync automático). Se o Alloy
apontar para o Collector antes de ele existir, as linhas ficam em retentativa e
podem se perder.

**Pendências com outras frentes**

- **Gabriel:** revisar o PR (mexe nos values do Alloy e do Loki), sincronizar o
  Alloy depois do Collector e criar o Secret `newrelic-license`
  (chave `license-key`) no namespace `monitoring`.
- **Gustavo:** a license key da conta central do New Relic.

### Como os apps falam com o Collector

Cada pod envia para o Collector do próprio nó. Variáveis a adicionar nos
Deployments de `gitops/services/*/deployment.yaml`:

```yaml
env:
- name: HOST_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://$(HOST_IP):4317"
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: grpc
- name: OTEL_SERVICE_NAME
  value: evaluation-service        # nome de cada serviço
- name: OTEL_RESOURCE_ATTRIBUTES
  value: service.namespace=togglemaster
- name: OTEL_LOGS_EXPORTER          # logs vão pelo stdout -> Alloy, não por OTLP
  value: none
```

`HOST_IP` precisa vir antes de `OTEL_EXPORTER_OTLP_ENDPOINT` na lista para a
expansão `$(HOST_IP)` funcionar.

## Achados no código que afetam a instrumentação

| Onde | Achado | Impacto |
|---|---|---|
| `evaluation-service/handlers.go` | `go a.sendEvaluationEvent(...)` sem contexto (o `ctx` global já foi removido pelo Gabriel em 23/10) | Para o trace atravessar a SQS, passar o contexto com `context.WithoutCancel(r.Context())` e injetar o `traceparent` |
| `evaluation-service/go.mod` | `go 1.21` | As libs atuais do OTel Go exigem versão mais nova; subir a diretiva (a imagem já usa golang 1.24) |
| `evaluation-service/sqs.go` | `aws-sdk-go` v1 | Não há instrumentação OTel mantida para o SDK v1. A injeção do `traceparent` nos `MessageAttributes` precisa ser manual |
| `analytics-service/app.py` | `receive_message` sem `MessageAttributeNames` | O contexto do trace não chegava ao consumidor. **Resolvido** na branch `feat/fase4-instrumentacao-python-v2` (`MessageAttributeNames=["All"]` e extração do contexto em `process_message`) |
| flag, targeting, analytics | Flask com `app.run`, sem gunicorn | Instrumentação automática direta com `opentelemetry-instrument`, sem o problema de fork |
| flag e targeting | Chamam `AUTH_SERVICE_URL/validate` com `requests` | O auth entra no caminho das requisições; o Service Map fica evaluation → flag/targeting → auth |
| `gitops/argocd/applications.yaml` | `selfHeal: true` | Confirma a necessidade de `ignoreDifferences` para o restart do self-healing |
| `terraform/modules/eks` | add-on `metrics-server` e HPA do evaluation já existem | Dá para mostrar o HPA no dashboard sem trabalho extra |
| Deployments | `readOnlyRootFilesystem: true` | Compatível com `opentelemetry-instrument`; não exige mudança |

## O que foi validado

- As duas configs do Collector passaram em `otelcol-contrib validate` (0.161.0).
  A config do EKS foi validada a partir de uma renderização aproximada do chart.
- Teste ponta a ponta com binários de Collector 0.161.0, Prometheus 3.5.0 e
  Loki 3.5.3: métricas e spanmetrics chegaram ao Prometheus, logs chegaram ao
  Loki com `service_name` e nível, e a consulta de 5xx retornou a taxa esperada.
- O envio para o Jaeger e as imagens Docker não foram testados nesse ambiente;
  rode o passo 1 do teste local para confirmar.
