# Fase 4 - Instrumentação dos serviços Python

Serviços: `flag-service`, `targeting-service` e `analytics-service`.

## O que mudou

| Arquivo | Mudança |
|---|---|
| `*/requirements.txt` | Pacotes do OpenTelemetry (SDK 1.45.0, instrumentações 0.66b0) |
| `*/Dockerfile` | `CMD` passa a rodar com `opentelemetry-instrument`; variáveis padrão do OTel |
| `analytics-service/app.py` | Continua o trace que chega pela SQS (atributo `traceparent`) |
| `docker-compose.yml` | Nome do serviço e endpoint do Collector local |
| `gitops/services/{flag,targeting,analytics}/deployment.yaml` | Envio para o Collector do próprio nó (`HOST_IP`) |

## O que é instrumentado automaticamente

- **Flask:** um span por requisição. `/health` e `/live` ficam de fora para não poluir o APM com as probes.
- **requests:** chamadas de flag e targeting para o `auth-service/validate`, com propagação do contexto.
- **psycopg2:** consultas ao PostgreSQL (flag e targeting).
- **botocore:** chamadas ao DynamoDB e à SQS (analytics).

Os atributos HTTP seguem a convenção estável (`http.response.status_code`,
`http.request.method`), a mesma do `otelhttp` no Go. Assim a regra de alerta e o
dashboard usam um único nome para os cinco serviços.

Logs continuam saindo no stdout e chegam ao Loki pelo `filelog` do Collector
(`OTEL_LOGS_EXPORTER=none` evita duplicar).

## Contrato com o evaluation-service (Go)

Para o Service Map ligar o evaluation ao analytics, o evaluation precisa enviar
o contexto do trace na mensagem da SQS:

- atributo de mensagem **`traceparent`**, `DataType` **`String`**
- valor no formato W3C, gerado pelo propagador `propagation.TraceContext{}`

Exemplo com `aws-sdk-go` v1:

```go
carrier := propagation.MapCarrier{}
otel.GetTextMapPropagator().Inject(ctx, carrier)
attrs := map[string]*sqs.MessageAttributeValue{}
for k, v := range carrier {
    attrs[k] = &sqs.MessageAttributeValue{DataType: aws.String("String"), StringValue: aws.String(v)}
}
// SendMessageInput{..., MessageAttributes: attrs}
```

O `ctx` precisa ser o da requisição (`r.Context()`), não o `context.Background()` global.

## Como foi testado

- As dependências instalam juntas com as versões fixadas dos serviços (Flask 2.2.5, boto3 1.34.122).
- `flag-service` com `opentelemetry-instrument`, banco e auth simulados: o Collector recebeu o
  span `GET /flags` (status 500, porque não havia banco) e o span de cliente para o auth (200);
  `/live` não gerou span; as métricas `http_server_request_duration_seconds` chegaram ao Prometheus.
- `analytics-service`: uma mensagem com `traceparent` gerou o span
  `togglemaster-analytics process` (CONSUMER) no mesmo trace e com o pai correto, com o
  `DynamoDB.PutItem` como filho. Sem `traceparent`, a mensagem é processada num trace novo.
