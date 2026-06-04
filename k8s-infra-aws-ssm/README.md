## Architecture

| Component | Image | Replicas | Notes |
|-----------|-------|----------|-------|
| Backend | `demo-backend` → ECR `dev-demo-backend` | HPA 1-4 | RollingUpdate, 150m CPU / 256Mi memory request, probes on :3000 |
| Frontend | `demo-frontend` → ECR `dev-demo-frontend` | HPA 1-4 | 100m CPU / 128Mi memory request, probes on :3000 |
| MongoDB | `mongo:8.0.23` | 1 (StatefulSet) | PVC 5Gi gp3, affinity `workload=stateful` + `us-east-1a` |
| Prometheus | `prom/prometheus:v3.5.0` | 1 | 7d retention, basic auth via pinned nginx proxy |
| Grafana | `grafana/grafana:13.0.2` | 1 | Probes enabled, image export via remote renderer, no explicit pod affinity |
| Grafana Image Renderer | `grafana/grafana-image-renderer:4.1.5` | 1 | Remote rendering on :8081, 32-character SSM-backed auth token, `TZ=Asia/Bangkok` |
| Loki | Built-in | — | Log aggregation |
| Grafana Alloy | `grafana/alloy:v1.16.2` | — | Log tailing from `/var/log/pods` |
| Metrics Server | `registry.k8s.io/metrics-server/metrics-server:v0.8.1` | — | Cluster metrics |
| Cluster Autoscaler | `registry.k8s.io/autoscaling/cluster-autoscaler:v1.34.0` | 1 | Node scaling |

## Apply

Deployment requires runtime injection of account-specific values. Real values are never committed.

### Required environment variables

| Variable | Description |
|----------|-------------|
| `AWS_REGION` | AWS region (default: `us-east-1`) |
| `ACM_CERTIFICATE_ARN` | ACM certificate ARN for ALB HTTPS listener |
| `ALB_SUBNET_IDS` | Comma-separated subnet IDs for ALB |

### Terraform prerequisites

Before deploying, create local `terraform.tfvars` from the `.tfvars.example` templates and run Terraform:

```bash
# Copy examples and fill in real values
cp terraform/envs/dev/services/eks/terraform.tfvars.example terraform/envs/dev/services/eks/terraform.tfvars
# ... repeat for each service

# Run Terraform
cd terraform && ./an-deploy be-init && ./an-deploy dev eks && ./an-deploy dev eks-alb && ./an-deploy dev secrets
```

### Deploy

```bash
export ACM_CERTIFICATE_ARN="arn:aws:acm:<region>:<account-id>:certificate/<certificate-id>"
export ALB_SUBNET_IDS="subnet-xxxxxxxx,subnet-yyyyyyyy"

./script/deploy-infra-eks-aws-ssm-react.sh
```

The script computes `ECR_REGISTRY` from `aws sts get-caller-identity`, replaces all placeholders in manifests, and applies.

Image names are rewritten via Kustomize `images:` block to point to ECR (`<account-id>.dkr.ecr.<region>.amazonaws.com`).

## ALB Ingress

Exposed via AWS Load Balancer Controller with dynamic security group injection:

- SG IDs managed by Terraform → ConfigMap `alb-security-groups` → Kustomize `replacements:` → Ingress annotations
- No hardcoded SG IDs — survives ALB recreation
- Certificate ARN in `ingress.yaml` (us-east-1)

```bash
# Get ALB DNS
kubectl get ingress demo-react-eks -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# DNS record
demo-react-eks.h0m3.xyz CNAME <ALB DNS hostname>
```

## Routing

| Path | Backend |
|------|---------|
| `/api` | `backend:3000` |
| `/` | `frontend:3000` |
| `/healthz` | Both (ALB health check) |

## Monitoring

- **Prometheus** — scrapes pod, cAdvisor, kubelet metrics. 7-day retention. Protected by basic auth (nginx proxy).
- **Grafana** — pre-provisioned with Prometheus + Loki datasources. Dashboards for API/frontend/MongoDB logs, PVC storage, CPU resources. Image export uses remote Grafana Image Renderer with 32-character SSM-backed auth token, internal render callback URLs, public root URL `https://grafana-demo.h0m3.xyz/`, and `TZ=Asia/Bangkok` for UTC+07 exports.
- **Loki** — stores pod logs.
- **Grafana Alloy** — tails logs from `/var/log/pods` in `dev` namespace.

Validate rendered monitoring manifests:

```bash
kubectl kustomize k8s-infra-aws-ssm >/tmp/k8s-infra-aws-ssm-rendered.yaml
python3 -m json.tool k8s-infra-aws-ssm/grafana/dashboards/mongodb-storage.json >/dev/null
bash -n script/deploy-ssm-grafana-dashboards.sh
```

Validate renderer after deployment:

```bash
kubectl -n dev rollout status deploy/grafana-image-renderer --timeout=180s
kubectl -n dev get deploy grafana-image-renderer -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep '^TZ=Asia/Bangkok$'
```

Access Grafana via port-forward or internal ingress.

## Storage

- **StorageClass**: `gp3` (EBS CSI, encrypted, `WaitForFirstConsumer`)
- **MongoDB PVC**: 5Gi `ReadWriteOnce`
- **Prometheus PVC**: `monitoring-data` claim
- **Grafana PVC**: `monitoring-data` claim (shared with Prometheus)

## Scheduling

| Workload | Constraint |
|----------|------------|
| MongoDB | `nodeAffinity`: `workload=stateful` + `topology.kubernetes.io/zone=us-east-1a`, `toleration: workload=stateful:NoSchedule` |
| Backend | None — schedules freely on any node |
| Frontend | None — schedules freely on any node |
| Grafana | None — no explicit pod affinity in current manifest |

## Notes

- Backend reads `MONGODB_URI=mongodb://mongo:27017/be_db` from ConfigMap
- Service names (`backend`, `mongo`, `frontend`) match in-cluster DNS
- No overlay patches for AWS — base manifests are AWS-correct
