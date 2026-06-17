# k8s-infra-aws

AWS EKS manifests for the demo React + Express + MongoDB app.

## Architecture

| Component | Image | Replicas | Notes |
|-----------|-------|----------|-------|
| Backend | `demo-backend` → ECR `dev-demo-backend` | HPA 1-4 | RollingUpdate, 150m CPU / 256Mi memory request, probes on :3000 |
| Frontend | `demo-frontend` → ECR `dev-demo-frontend` | HPA 1-4 | 100m CPU / 128Mi memory request, probes on :3000 |
| MongoDB | `mongo:8.0` | 1 (StatefulSet) | PVC 5Gi gp3, affinity `workload=stateful` + `us-east-1a` |
| Prometheus | `prom/prometheus:v2.54.1` | 1 | 7d retention, basic auth via nginx proxy |
| Grafana | `grafana/grafana:13.0.2` | 1 | Pod affinity to prometheus node |
| Grafana Image Renderer | `grafana/grafana-image-renderer:v4.1.5` | 1 | Internal ClusterIP renderer for Grafana export images |
| Loki | Built-in | — | Log aggregation |
| Grafana Alloy | Built-in | — | Log tailing from `/var/log/pods` |
| Metrics Server | Built-in | — | Cluster metrics |
| Cluster Autoscaler | Built-in | — | Node scaling |

## Apply

```bash
kubectl apply -k k8s-infra-aws/
```

Image names are rewritten via Kustomize `images:` block to point to ECR (`654654604308.dkr.ecr.us-east-1.amazonaws.com`).

## ALB Ingress

Exposed via AWS Load Balancer Controller with dynamic security group injection:

- SG IDs injected at deploy time by `script/deploy-eks-aws-ssm-react.sh` (Step 7) — manifests store `PLACEHOLDER_FRONTEND_SG,PLACEHOLDER_BACKEND_SG` as sentinels; script replaces them before `kubectl apply`.
- No hardcoded SG IDs in source — survives ALB recreation.
- Certificate ARN in `ingress-dev.yaml` (us-east-1).

```bash
# Get ALB DNS
kubectl get ingress demo-react-eks -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# DNS record
demo-react-eks.h0m3.xyz CNAME <ALB DNS hostname>
```

### Shared IngressGroup contract

All four ingresses — DEV app, UAT app, Grafana, Prometheus — share one ALB via `alb.ingress.kubernetes.io/group.name: demo-react-eks-dev`.

AWS Load Balancer Controller merges all ingresses in the same group into one ALB. Every member must carry **identical** merge-sensitive annotations or the controller raises a `conflicting tag` reconcile error and stops adding listener rules.

Required identical values across all group members:

| Annotation | Value |
|---|---|
| `alb.ingress.kubernetes.io/tags` | `Project=demo-eks-dev,Environment=shared,ManagedBy=kubernetes,Name=demo-react-eks-dev-uat` |
| `alb.ingress.kubernetes.io/load-balancer-name` | `demo-react-eks-dev-uat` |
| `alb.ingress.kubernetes.io/subnets` | `subnet-0ca21f0f484edd27d,subnet-0d5b19984b533f703` |
| `alb.ingress.kubernetes.io/certificate-arn` | `arn:aws:acm:us-east-1:654654604308:certificate/ed9119c0-c6a7-49ac-84cf-ded38b29491c` |

Per-member values that may differ: `group.order`, `healthcheck-path`, host rule, target service/port.

## Routing

| Host | Path | Backend |
|------|------|---------|
| `demo-react-eks.h0m3.xyz` | `/api` | `dev/backend:3000` |
| `demo-react-eks.h0m3.xyz` | `/` | `dev/frontend:3000` |
| `grafana-demo.h0m3.xyz` | `/` | `monitor/grafana:3000` |
| `prometheus-demo.h0m3.xyz` | `/` | `monitor/prometheus:8080` |
| `uat-demo-react-eks.h0m3.xyz` | `/api` | `uat/backend:3000` |
| `uat-demo-react-eks.h0m3.xyz` | `/` | `uat/frontend:3000` |
| — | `/healthz` | DEV/UAT app (ALB health check) |

## Monitoring

- **Prometheus** — runs in `monitor`, scrapes pod, cAdvisor, kubelet metrics from `dev` and `monitor`. 7-day retention. Protected by basic auth (nginx proxy).
- **Grafana** — runs in `monitor`, pre-provisioned with Prometheus + Loki datasources. Dashboards for API/frontend/MongoDB logs, PVC storage, CPU resources.
- **Grafana Image Renderer** — runs in `monitor`, remote renderer service for dashboard and panel PNG export. Token source: AWS SSM `/demo-eks-dev/image-render/grafana_image_render_auth_token` synced by External Secrets.
- **Loki** — runs in `monitor`, stores pod logs.
- **Grafana Alloy** — runs in `monitor`, tails logs from `/var/log/pods` for `dev` app workloads and `monitor` observability workloads.

Access Grafana via port-forward or internal ingress.

## Grafana Image Renderer

Grafana public URL must be configured for EKS/ALB image export:

- `GF_SERVER_ROOT_URL=https://grafana-demo.h0m3.xyz/` makes browser-side Grafana generate public render URLs.
- `GF_RENDERING_SERVER_URL=http://grafana-image-renderer:8081/render` stays internal.
- `GF_RENDERING_CALLBACK_URL=http://grafana:3000/` stays internal.
- `TZ=Asia/Bangkok` makes renderer headless Chromium report a known UTC+07 timezone instead of `Etc/Unknown`.

Validate public app URL:

```bash
curl -k -sS https://grafana-demo.h0m3.xyz/login | grep -o 'appUrl":"[^"]*'
```

Expected output:

```text
appUrl":"https://grafana-demo.h0m3.xyz/
```

Renderer token can be created manually with AWS CLI, or automatically by Terraform. Current repo uses Terraform token creation to match existing Mongo secret pattern.

Manual option:

```bash
aws ssm put-parameter \
  --name "/demo-eks-dev/image-render/grafana_image_render_auth_token" \
  --type "SecureString" \
  --value "$(openssl rand -hex 32)" \
  --overwrite
```

Terraform option:

```bash
terraform -chdir=terraform/envs/dev/services/secrets apply
aws ssm get-parameter \
  --name "/demo-eks-dev/image-render/grafana_image_render_auth_token" \
  --with-decryption \
  --query 'Parameter.Name' \
  --output text
```

Apply and validate:

```bash
kubectl apply -k k8s-infra-aws-ssm/
kubectl -n monitor rollout status deploy/grafana-image-renderer
kubectl -n monitor rollout status deploy/grafana
kubectl -n monitor get externalsecret grafana-image-renderer
kubectl -n monitor get secret grafana-image-renderer
kubectl -n monitor get pods -l app=grafana-image-renderer
kubectl -n monitor logs deploy/grafana -c grafana | grep -i rendering
```

## Storage

- **StorageClass**: `gp3` (EBS CSI, encrypted, `WaitForFirstConsumer`)
- **MongoDB PVC**: 5Gi `ReadWriteOnce` in `dev`
- **Prometheus PVC**: 5Gi `prometheus-data` claim in `monitor`
- **Grafana PVC**: 5Gi `grafana-data` claim in `monitor`
- **Loki PVC**: 5Gi `loki-data` claim in `monitor`

## Scheduling

| Workload | Constraint |
|----------|------------|
| MongoDB | `nodeAffinity`: `workload=stateful` + `topology.kubernetes.io/zone=us-east-1a`, `toleration: workload=stateful:NoSchedule` |
| Backend | None — schedules freely on any node |
| Frontend | None — schedules freely on any node |
| Grafana | Runs in `monitor`; AZ-pinned to `topology.kubernetes.io/zone=us-east-1a`; no `workload=stateful` selector/toleration |
| Prometheus | Runs in `monitor`; AZ-pinned to `topology.kubernetes.io/zone=us-east-1a`; no `workload=stateful` selector/toleration |
| Loki / Alloy | Run in `monitor`; Alloy DaemonSet tails `dev`, `uat`, and `monitor` pod logs |

## Notes

- Backend reads `MONGODB_URI=mongodb://app_user:...@mongo:27017/dev_be_db?authSource=admin` from Secret (via ExternalSecret/SSM)
- Service names (`backend`, `mongo`, `frontend`) match in-cluster DNS
- No overlay patches for AWS — base manifests are AWS-correct
