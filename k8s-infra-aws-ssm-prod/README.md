# k8s-infra-aws-ssm-prod

AWS EKS manifests for the production environment of the React + Express + MongoDB app.

## Namespace

- `prod` — all prod workloads, secrets, and ingress

## Architecture

| Component | Image | Replicas | Notes |
|-----------|-------|----------|-------|
| Backend | `prod-demo-backend:local` → ECR `prod-demo-backend:latest` | HPA 1-4 | RollingUpdate, requests 150m CPU / 256Mi memory, limits 500m CPU / 512Mi memory, probes on :3000 |
| Frontend | `prod-demo-frontend:local` → ECR `prod-demo-frontend:latest` | HPA 1-4 | Requests 100m CPU / 128Mi memory, limits 300m CPU / 256Mi memory, probes on :3000 |
| MongoDB | `mongo:8.0.23` | 1 (StatefulSet) | PVC 10Gi gp3, affinity `workload=stateful` + `us-east-1a`, toleration `workload=stateful:NoSchedule` |
| Prometheus | `prom/prometheus:v3.5.1` | 1 (StatefulSet) | 1h local retention, `emptyDir` storage, remote-writes metrics to the dev cluster receiver NLB |
| Grafana Alloy | `grafana/alloy:v1.16.2` | DaemonSet | Tails logs from `/var/log/pods` in `prod` and `monitor`; pushes to dev cluster Loki receiver NLB |

Observability UI (Grafana, Loki) and cluster addons (metrics-server, cluster-autoscaler) run in the dev/UAT cluster. Prod streams metrics and logs there.

## Apply

Manifests contain the placeholder `__AWS_ACCOUNT_ID__`, ALB security-group sentinels, and a subnet placeholder that must be rendered before apply. Use the deploy script or the render helper:

```bash
# Full deploy (builds images, renders, applies)
script/deploy-eks-aws-ssm-react.sh prod

# Render only and pipe to kubectl
script/render-k8s.sh k8s-infra-aws-ssm-prod | kubectl --context eks-react-prod apply -f -
```

ECR image names are rewritten via the Kustomize `images:` block to:

```text
__AWS_ACCOUNT_ID__.dkr.ecr.us-east-1.amazonaws.com/prod-{demo-backend,demo-frontend,mongo-rotator}:latest
```

## ALB Ingress

A single internet-facing ALB for the prod app:

- ALB name: `elb-react-eks-prod`
- Ingress group: `elb-react-eks-prod` (only this ingress)
- Subnet IDs are injected at deploy time from `terraform/envs/prod/services/networking` output `edge_public_subnet_ids` — manifests store `PLACEHOLDER_PROD_SUBNETS` as a sentinel.
- SG IDs injected at deploy time by `script/deploy-eks-aws-ssm-react.sh` — manifests store `PLACEHOLDER_FRONTEND_SG,PLACEHOLDER_BACKEND_SG`.
- Certificate ARN uses `__AWS_ACCOUNT_ID__` and is substituted by `script/render-k8s.sh`.

```bash
# Get ALB DNS
kubectl --context eks-react-prod get ingress elb-react-eks-prod -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# DNS record
react-eks.h0m3.xyz  CNAME <ALB DNS hostname>
```

### Required ALB annotations

| Annotation | Value |
|---|---|
| `alb.ingress.kubernetes.io/tags` | `Project=demo-eks-prod,Environment=prod,ManagedBy=kubernetes,Name=elb-react-eks-prod` |
| `alb.ingress.kubernetes.io/load-balancer-name` | `elb-react-eks-prod` |
| `alb.ingress.kubernetes.io/subnets` | `PLACEHOLDER_PROD_SUBNETS` (rendered at deploy time) |
| `alb.ingress.kubernetes.io/certificate-arn` | `arn:aws:acm:us-east-1:__AWS_ACCOUNT_ID__:certificate/ed9119c0-c6a7-49ac-84cf-ded38b29491c` |
| `alb.ingress.kubernetes.io/security-groups` | `PLACEHOLDER_FRONTEND_SG,PLACEHOLDER_BACKEND_SG` (rendered at deploy time) |

## Routing

| Host | Path | Backend |
|------|------|---------|
| `react-eks.h0m3.xyz` | `/api` | `prod/backend:3000` |
| `react-eks.h0m3.xyz` | `/` | `prod/frontend:3000` |
| — | `/healthz` | prod app (ALB health check) |

## Cross-cluster observability

Prod does **not** run Grafana or Loki locally. Metrics and logs are shipped to the dev/UAT cluster:

- **Prometheus** — scrapes `prod` and `monitor` namespaces, then remote-writes to the dev receiver NLB:
  ```text
  http://nlb-dev-alloyprom-receiver-c25d628cb524b769.elb.us-east-1.amazonaws.com:9090/api/v1/write
  ```
  Auth token from AWS SSM `/demo-eks-prod/monitor/prometheus_rw_token`.
- **Grafana Alloy** — tails pod logs and pushes to the dev Loki receiver NLB:
  ```text
  http://nlb-dev-alloyprom-receiver-c25d628cb524b769.elb.us-east-1.amazonaws.com:3100/loki/api/v1/push
  ```
  Auth token from AWS SSM `/demo-eks-prod/monitor/loki_writer_token`.

Prod dashboard JSON definitions live in `grafana/dashboards/` and are rendered by the Grafana instance running in the dev cluster.

## Storage

- **StorageClass**: `gp3` (EBS CSI, encrypted, `WaitForFirstConsumer`)
- **MongoDB PVC**: 10Gi `ReadWriteOnce` in `prod`
- **Prometheus data**: `emptyDir` (1h retention, no persistence)

## Scheduling

| Workload | Constraint |
|----------|------------|
| MongoDB | `nodeAffinity`: `workload=stateful` + `topology.kubernetes.io/zone=us-east-1a`, `toleration: workload=stateful:NoSchedule` |
| Backend | None — schedules freely on any node |
| Frontend | None — schedules freely on any node |
| Prometheus | None — schedules freely on any node (uses `emptyDir`) |
| Alloy | DaemonSet; mounts host `/var/log/pods` and `/var/lib/alloy` |

## External Secrets

Uses `ClusterSecretStore` named `aws-ssm` backed by AWS SSM Parameter Store in `us-east-1`, authenticating via the `external-secrets` ServiceAccount in the `external-secrets-prod` namespace.

| Secret | SSM path | Purpose |
|--------|----------|---------|
| `mongo-app-secret` | `/demo-eks-prod/mongo/app_username`, `app_password`, `app_mongodb_uri` | MongoDB app user |
| `mongo-root-secret` | `/demo-eks-prod/mongo/root_username`, `root_password` | MongoDB root user |
| `api-token-secret` | `/demo-eks-prod/app/api_token` | Backend/API auth token |
| `prometheus-rw-token` | `/demo-eks-prod/monitor/prometheus_rw_token` | Prometheus remote-write auth |
| `loki-writer-token` | `/demo-eks-prod/monitor/loki_writer_token` | Alloy Loki push auth |

## Notes

- Backend `CORS_ORIGINS` is set to `https://react-eks.h0m3.xyz,http://localhost:3000` in `backend/configmap-prod.yaml`.
- Service names (`backend`, `mongo`, `frontend`) match in-cluster DNS inside the `prod` namespace.
- This overlay excludes metrics-server, cluster-autoscaler, Grafana, and Loki — those run in the dev/UAT cluster.
