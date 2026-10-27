#!/usr/bin/env bash

set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

ensure_aws_auth
cd "$PROJECT_ROOT"

kubectl get nodes >/dev/null 2>&1 || {
  echo "O EKS não está acessível."
  echo "Execute primeiro: ./scripts/aws/04-open-eks.sh"
  exit 1
}

echo "Verificando imagens no ECR..."

for repository in \
  togglemaster-auth \
  togglemaster-flag \
  togglemaster-targeting \
  togglemaster-evaluation \
  togglemaster-analytics
do
  count="$(
    aws ecr describe-images \
      --region "$AWS_REGION_NAME" \
      --repository-name "$repository" \
      --query 'length(imageDetails)' \
      --output text
  )"

  if [[ "$count" == "0" ]]; then
    echo "O repositório $repository ainda não possui imagens."
    echo "Aguarde a conclusão do CD ECR and GitOps."
    exit 1
  fi
done

kubectl apply -f gitops/namespace.yaml

echo
echo "Criando Secret de runtime sem exibir seus valores..."

python3 - <<'PY'
import json
import os
import secrets
import subprocess
from urllib.parse import quote

region = os.environ.get("AWS_REGION_NAME", "us-east-1")

databases = {
    "AUTH_DATABASE_URL": (
        "togglemaster-homolog-auth",
        "auth_db",
    ),
    "FLAG_DATABASE_URL": (
        "togglemaster-homolog-flag",
        "flags_db",
    ),
    "TARGETING_DATABASE_URL": (
        "togglemaster-homolog-targeting",
        "targeting_db",
    ),
}

def aws_json(arguments):
    output = subprocess.check_output(
        ["aws", *arguments, "--region", region, "--output", "json"],
        text=True,
    )
    return json.loads(output)

secret_data = {}

for variable, (instance_id, database_name) in databases.items():
    instance = aws_json([
        "rds",
        "describe-db-instances",
        "--db-instance-identifier",
        instance_id,
        "--query",
        "DBInstances[0].{host:Endpoint.Address,port:Endpoint.Port,secret:MasterUserSecret.SecretArn}",
    ])

    credentials = aws_json([
        "secretsmanager",
        "get-secret-value",
        "--secret-id",
        instance["secret"],
        "--query",
        "SecretString",
    ])

    if isinstance(credentials, str):
        credentials = json.loads(credentials)

    username = quote(credentials["username"], safe="")
    password = quote(credentials["password"], safe="")

    secret_data[variable] = (
        f"postgres://{username}:{password}"
        f"@{instance['host']}:{instance['port']}/{database_name}"
        "?sslmode=require"
    )

# Preserva credenciais entre execuções do bootstrap.
result = subprocess.run(
    [
        "kubectl", "get", "secret",
        "togglemaster-runtime-secrets",
        "--namespace", "togglemaster",
        "-o", "json",
        "--ignore-not-found",
    ],
    capture_output=True,
    text=True,
    check=True,
)

if result.stdout.strip():
    import base64

    existing = json.loads(result.stdout)
    stored = existing.get("data", {})

    for key in ("MASTER_KEY", "SERVICE_API_KEY"):
        if key not in stored:
            raise RuntimeError(
                f"Secret existente sem {key}; correção manual necessária."
            )
        secret_data[key] = base64.b64decode(
            stored[key], validate=True
        ).decode("utf-8")

    print("Credenciais existentes preservadas.")
else:
    secret_data["MASTER_KEY"] = secrets.token_urlsafe(48)
    secret_data["SERVICE_API_KEY"] = secrets.token_urlsafe(48)
    print("Credenciais geradas para primeira implantação.")

manifest = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": "togglemaster-runtime-secrets",
        "namespace": "togglemaster",
    },
    "type": "Opaque",
    "stringData": secret_data,
}

subprocess.run(
    ["kubectl", "apply", "-f", "-"],
    input=json.dumps(manifest),
    text=True,
    check=True,
)

print("Secret criado com novas credenciais.")
PY

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

API_HASH="$(
  kubectl get secret togglemaster-runtime-secrets \
    --namespace togglemaster \
    -o jsonpath='{.data.SERVICE_API_KEY}' |
  base64 -d |
  sha256sum |
  awk '{print $1}'
)"

awk '
  /-- Chave conhecida apenas para comunicação/ {exit}
  {print}
' auth-service/db/init.sql > "$TEMP_DIR/auth-init.sql"

cat >> "$TEMP_DIR/auth-init.sql" <<EOF_AUTH

INSERT INTO api_keys (name, key_hash, is_active)
VALUES ('evaluation-service-aws', '${API_HASH}', true)
ON CONFLICT (key_hash) DO NOTHING;
EOF_AUTH

kubectl create configmap auth-db-schema \
  --namespace togglemaster \
  --from-file=init.sql="$TEMP_DIR/auth-init.sql" \
  --dry-run=client -o yaml |
kubectl apply -f -

kubectl create configmap flag-db-schema \
  --namespace togglemaster \
  --from-file=init.sql=flag-service/db/init.sql \
  --dry-run=client -o yaml |
kubectl apply -f -

kubectl create configmap targeting-db-schema \
  --namespace togglemaster \
  --from-file=init.sql=targeting-service/db/init.sql \
  --dry-run=client -o yaml |
kubectl apply -f -

echo "Verificando Jobs de inicialização..."

for job in auth-db-init flag-db-init targeting-db-init; do
  if kubectl get job "$job" -n togglemaster >/dev/null 2>&1; then
    echo "Job existente: $job"
  else
    echo "Job ausente: $job"
  fi
done

python3 - <<'PY' > "$TEMP_DIR/db-jobs.json"
import json

configurations = [
    (
        "auth-db-init",
        "auth-db-schema",
        "AUTH_DATABASE_URL",
    ),
    (
        "flag-db-init",
        "flag-db-schema",
        "FLAG_DATABASE_URL",
    ),
    (
        "targeting-db-init",
        "targeting-db-schema",
        "TARGETING_DATABASE_URL",
    ),
]

items = []

for job_name, configmap_name, secret_key in configurations:
    items.append({
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": job_name,
            "namespace": "togglemaster",
        },
        "spec": {
            "backoffLimit": 2,
            "template": {
                "spec": {
                    "restartPolicy": "Never",
                    "containers": [{
                        "name": "migration",
                        "image": "postgres:16",
                        "command": [
                            "sh",
                            "-c",
                            'psql "$DATABASE_URL" '
                            "-v ON_ERROR_STOP=1 "
                            "-f /sql/init.sql",
                        ],
                        "env": [{
                            "name": "DATABASE_URL",
                            "valueFrom": {
                                "secretKeyRef": {
                                    "name": "togglemaster-runtime-secrets",
                                    "key": secret_key,
                                },
                            },
                        }],
                        "volumeMounts": [{
                            "name": "schema",
                            "mountPath": "/sql",
                            "readOnly": True,
                        }],
                    }],
                    "volumes": [{
                        "name": "schema",
                        "configMap": {
                            "name": configmap_name,
                        },
                    }],
                },
            },
        },
    })

print(json.dumps({
    "apiVersion": "v1",
    "kind": "List",
    "items": items,
}))
PY

for job in auth-db-init flag-db-init targeting-db-init; do
  echo "Verificando Job: $job"

  JOB_CHECK="$(kubectl get job "$job" --namespace togglemaster --ignore-not-found -o name)" || {
    echo "ERRO: falha ao consultar Job $job no Kubernetes."
    exit 1
  }

  if [[ -n "$JOB_CHECK" ]]; then
    echo "Preservando Job existente: $job"
    continue
  fi

  echo "Criando Job: $job"

  python3 - "$TEMP_DIR/db-jobs.json" "$job" <<'PYFILTER' |
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    manifest = json.load(file)

matches = [
    item for item in manifest["items"]
    if item["metadata"]["name"] == sys.argv[2]
]

if len(matches) != 1:
    raise SystemExit("Job não encontrado no manifesto.")

print(json.dumps(matches[0]))
PYFILTER
    kubectl create -f -
done

for job in auth-db-init flag-db-init targeting-db-init; do
  echo "Aguardando conclusão: $job"

  kubectl wait \
    --namespace togglemaster \
    --for=condition=Complete \
    "job/$job" \
    --timeout=10m
done

echo "Inicialização dos bancos validada."

echo
echo "Instalando Argo CD..."

kubectl create namespace argocd \
  --dry-run=client -o yaml |
kubectl apply -f -

kubectl apply \
  --server-side \
  --force-conflicts \
  --namespace argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml

for deployment in \
  argocd-applicationset-controller \
  argocd-dex-server \
  argocd-notifications-controller \
  argocd-redis \
  argocd-repo-server \
  argocd-server
do
  kubectl rollout status \
    --namespace argocd \
    "deployment/$deployment" \
    --timeout=10m
done

kubectl apply -f gitops/argocd/applications.yaml

echo
echo "Preparando namespace e credenciais do monitoramento..."

kubectl create namespace monitoring \
  --dry-run=client -o yaml |
kubectl apply -f -

echo
echo "Aguardando EBS CSI Driver..."

kubectl rollout status deployment/ebs-csi-controller --namespace kube-system --timeout=10m

echo "EBS CSI Driver disponível."

kubectl apply -f gitops/monitoring/storage/storageclass.yaml

bash scripts/monitoring/01-create-grafana-secret.sh

echo
echo "Registrando aplicações de observabilidade no Argo CD..."

kubectl apply -f gitops/argocd/monitoring-dashboard.yaml
kubectl apply -f gitops/argocd/monitoring-prometheus.yaml
kubectl apply -f gitops/argocd/monitoring-loki.yaml
kubectl apply -f gitops/argocd/monitoring-otel-collector.yaml
echo
echo "Aguardando sincronização do dashboard ToggleMaster..."

DASHBOARD_READY=false

for attempt in $(seq 1 60); do
  SYNC_STATUS="$(kubectl get application togglemaster-monitoring-dashboard -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  HEALTH_STATUS="$(kubectl get application togglemaster-monitoring-dashboard -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

  if [[ "$SYNC_STATUS" == "Synced" && "$HEALTH_STATUS" == "Healthy" ]] &&
     kubectl get configmap togglemaster-eks-dashboard -n monitoring >/dev/null 2>&1; then
    DASHBOARD_READY=true
    break
  fi

  sleep 5
done

if [[ "$DASHBOARD_READY" != "true" ]]; then
  echo "ERRO: dashboard não ficou Synced/Healthy em até 5 minutos."
  exit 1
fi

echo "Dashboard sincronizado e disponível."

kubectl apply -f gitops/argocd/monitoring-grafana.yaml

echo
echo "Aguardando os cinco microsserviços..."

kubectl wait \
  --namespace togglemaster \
  --for=condition=Available \
  deployment/auth-service \
  deployment/flag-service \
  deployment/targeting-service \
  deployment/evaluation-service \
  deployment/analytics-service \
  --timeout=15m

echo
echo
echo "Verificando saúde das aplicações de observabilidade..."

for application in togglemaster-prometheus togglemaster-loki togglemaster-otel-collector togglemaster-grafana; do
  echo "Aguardando $application..."

  READY=false

  for attempt in $(seq 1 120); do
    SYNC_STATUS="$(kubectl get application "$application" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    HEALTH_STATUS="$(kubectl get application "$application" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

    if [[ "$SYNC_STATUS" == "Synced" && "$HEALTH_STATUS" == "Healthy" ]]; then
      READY=true
      break
    fi

    sleep 5
  done

  if [[ "$READY" != "true" ]]; then
    echo "ERRO: $application não ficou Synced/Healthy em até 10 minutos."
    exit 1
  fi

  echo "$application: Synced/Healthy"
done

echo "Bootstrap Kubernetes concluído."
