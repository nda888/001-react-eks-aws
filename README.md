Terraform-managed AWS EKS demo for a React, Express, and MongoDB app. Includes Docker Compose configuration, ECR image build scripts, Kubernetes manifests, ALB ingress, SSM-backed secrets, and observability stack.

## Stack

| Layer | Technology |
| --- | --- |
| Frontend | React 17, Create React App, Axios, nginx runtime |
| Backend | Node.js, Express, Mongoose, CORS |
| Database | MongoDB 8.0.23 |
| Local runtime | Docker Compose |
| Cloud infrastructure | AWS, Terraform, EKS, ECR, ALB, SSM Parameter Store |
| Kubernetes add-ons | AWS Load Balancer Controller, External Secrets, Metrics Server, Cluster Autoscaler |
| Observability | Prometheus, Grafana, Loki, Alloy |

## Repository structure

```text
.
├── src/                    # React frontend, Express backend, MongoDB compose stack
├── terraform/              # AWS infrastructure modules and dev environment services
├── k8s-infra-aws-ssm/      # Kubernetes manifests for EKS deployment
├── script/                 # Deployment helper scripts
└── README.md               # Project overview
```

## Application

`src/` contains local application source and `compose.yaml`.

- `src/frontend/` — React client served by nginx in production.
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

Local deployment uses the frontend and backend `Dockerfile-local` files. Keep the Compose build config pointed at those files:

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

- networking
- ECR repositories
- EKS cluster
- EKS post-install resources
- AWS Load Balancer Controller
- SSM-backed secrets

Reusable modules include bootstrap state, networking, EKS, ECR, ALB controller, and public access allowlist.

## Kubernetes deployment

`k8s-infra-aws-ssm/` contains manifests for:

- namespace and gp3 StorageClass
- frontend Deployment, Service, HPA
- backend Deployment, Service, HPA, ConfigMap
- MongoDB StatefulSet, Service, PVC, app-user job, rotation CronJobs/RBAC
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

`scripts/` are not used; helper scripts live in `script/`:

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
