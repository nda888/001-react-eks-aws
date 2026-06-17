# React + Express + MongoDB — Compose sample application

## Project structure

```
src/
├── backend
│   ├── Dockerfile
│   ├── Dockerfile-local
│   ├── package.json
│   ├── server.js
│   ├── config/
│   ├── db/
│   ├── models/
│   ├── routes/
│   └── utils/
├── frontend
│   ├── Dockerfile
│   ├── Dockerfile-local
│   ├── package.json
│   ├── vite.config.js
│   ├── nginx.conf
│   └── src/
├── compose.yaml
└── .env.example
```

## Stack

| Layer    | Technology                          |
|----------|-------------------------------------|
| Frontend | React 17 + Vite 6 + nginx (production image) |
| Backend  | Express 4 (Node 22)                 |
| Database | MongoDB 8.0                         |

## Quick start (local development)

```bash
cp .env.example .env
docker compose up -d
```

Navigate to `http://localhost:3000`.

### Services

- **frontend** — Vite dev server on port 3000. Hot-reloads changes from `frontend/`.
- **backend** — Express API server (Nodemon). Hot-reloads changes from `backend/`. Exposes `/healthz` for liveness checks.
- **mongo** — MongoDB 8.0 (configurable via `MONGO_IMAGE` env var). Persistent volume at `mongo_data`.

### Environment variables

Copy `.env.example` to `.env` and edit. Required:

| Variable                    | Purpose                          |
|-----------------------------|----------------------------------|
| `MONGO_INITDB_ROOT_USERNAME` | MongoDB root user                |
| `MONGO_INITDB_ROOT_PASSWORD` | MongoDB root password            |
| `MONGODB_URI`               | Backend connection string        |
| `MONGO_IMAGE`               | (optional) Override Mongo image  |

## Production / AWS deployment

See project root for Terraform modules, Kubernetes manifests (`k8s-infra-aws-ssm/`), and the deploy script (`script/deploy-infra-eks-aws-ssm-react.sh`).

The Dockerfiles under `src/` are multi-stage:

- **`Dockerfile`** — Flat build from `node:22-bookworm-slim` (backend) / `nginx:1.29-alpine` (frontend, production via Vite build). Used by CI / ECR push.
- **`Dockerfile-local`** — Identical to `Dockerfile` but with `docker-compose`-compatible paths. Used by `compose.yaml`.

## Stop

```bash
docker compose down        # stop containers, keep volumes
docker compose down -v      # also remove volumes
```
