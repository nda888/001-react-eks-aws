```mermaid
flowchart LR
  FE["frontend<br/>React · Vite · nginx"]
  BE["backend<br/>Express · Mongoose"]
  DB[("MongoDB")]

  FE -- "/api/todos" --> BE
  BE -- "Mongoose ODM" --> DB
```

## Repository structure

```text
├── src/                    # React frontend, Express backend, MongoDB compose stack
├── terraform/              # AWS infra modules + dev/uat env services
├── k8s-infra-aws-ssm/      # Kubernetes manifests for EKS deployment
├── script/                 # Deployment helper scripts
```

## Application

`src/` contains local application source and `compose.yaml`.

- `src/frontend/` — React client built with Vite, served by nginx in production.
- `src/backend/` — Express API service using Mongoose.
- `src/compose.yaml` — local frontend, backend, MongoDB stack.
- `src/frontend/Dockerfile-local` — frontend image for local deployment.
- `src/backend/Dockerfile-local` — backend image for local deployment.

API routes:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api` | List todos |
| `POST` | `/api/todos` | Create todo |
| `DELETE` | `/api/todos/:id` | Delete todo |

## Local development

From `src/`:

```bash
docker compose up --build
```

Local deployment uses the frontend and backend `Dockerfile-local` files:

```yaml
services:
  frontend:
    build:
      context: frontend
      dockerfile: Dockerfile-local
      target: development
  backend:
    build:
      context: backend
      dockerfile: Dockerfile-local
      target: development
```

Frontend package commands:

```bash
cd src/frontend
npm start
npm run build
npm test
```

Backend package commands:

```bash
cd src/backend
npm start
npm run dev
```

## Infrastructure

`terraform/` defines AWS infrastructure with environment services and reusable modules.

Dev services include:

- Networking
- ECR repositories
- EKS cluster
- EKS post-install resources
- AWS Load Balancer Controller
- SSM-backed secrets

Reusable modules include bootstrap state, networking, EKS, ECR, ALB controller, and public access allowlist.

## Kubernetes deployment

`k8s-infra-aws-ssm/` contains manifests for:

- Namespace and gp3 StorageClass
- Frontend Deployment, Service, HPA
- Backend Deployment, Service, HPA, ConfigMap
- MongoDB StatefulSet, Service, app-user job, rotation CronJobs/RBAC
- External Secrets resources backed by AWS SSM Parameter Store
- ALB Ingress routing
- Prometheus, Grafana, Loki, Alloy
- Metrics Server and Cluster Autoscaler

Ingress routes:

| Path | Service |
| --- | --- |
| `/api` | `backend:3000` |
| `/` | `frontend:3000` |

Get ALB DNS after deployment:

```bash
kubectl get ingress demo-react-eks -n dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Deployment scripts

`scripts/` is not used; helper scripts live in `script/`:

| Script | Purpose |
| --- | --- |
| `deploy-infra-eks-aws-ssm-react.sh` | Deploy Terraform infrastructure, images, and Kubernetes manifests |
| `deploy-img-fe-be-ecr-aws.sh` | Build and push frontend/backend images to ECR |
| `deploy-img-backend-aws.sh` | Build and push backend image to ECR |
| `deploy-img-frontend-aws.sh` | Build and push frontend image to ECR |
| `deploy-ssm-grafana-dashboards.sh` | Deploy Grafana dashboard data |

Common required tools:

- AWS CLI
- Docker with Buildx
- kubectl
- Terraform
