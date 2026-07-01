# React + Express + MongoDB — Compose sample application

## Project structure

```
src/
├── backend
│   ├── Dockerfile
│   ├── Dockerfile-local
│   ├── .dockerignore
│   ├── package.json
│   ├── server.js
│   ├── config/
│   │   ├── config.js
│   │   ├── config.json
│   │   └── messages.js
│   ├── db/
│   │   └── index.js
│   ├── middleware/
│   │   └── auth.js
│   ├── models/
│   │   └── todos/
│   │       └── todo.js
│   ├── routes/
│   │   └── index.js
│   ├── utils/
│   │   └── helpers/
│   │       ├── logger.js
│   │       └── responses.js
│   └── logs/
├── frontend
│   ├── Dockerfile
│   ├── Dockerfile-local
│   ├── .dockerignore
│   ├── .env.example
│   ├── package.json
│   ├── vite.config.js
│   ├── index.html
│   ├── nginx.conf
│   ├── public/
│   │   ├── favicon.ico
│   │   ├── logo192.png
│   │   ├── logo512.png
│   │   ├── manifest.json
│   │   └── robots.txt
│   └── src/
│       ├── index.jsx
│       ├── index.css
│       ├── App.jsx
│       ├── App.scss
│       ├── App.test.jsx
│       ├── custom.scss
│       ├── setupTests.js
│       ├── logo.svg
│       └── components/
│           ├── AddTodo.jsx
│           └── TodoList.jsx
├── compose.yaml
├── .env
└── .env.example
```

## Stack

| Layer    | Technology                                    |
|----------|-----------------------------------------------|
| Frontend | React 19 + Vite 6 + nginx (production image)  |
| Backend  | Express 4 (Node 22)                           |
| Database | MongoDB 8.0                                   |
| Testing  | Vitest (frontend)                             |

## Quick start (local development)

```bash
cp .env.example .env
cp frontend/.env.example frontend/.env
# make sure API_TOKEN and VITE_API_TOKEN match
docker compose up -d
```

Navigate to `http://localhost:3000`.

### Services

- **frontend** — Vite dev server on port 3000. Hot-reloads changes from `frontend/`. Proxies `/api` to the backend service.
- **backend** — Express API server (Nodemon) on internal port 3000. Hot-reloads changes from `backend/`. Exposes `/healthz` for liveness checks.
- **mongo** — MongoDB 8.0 (configurable via `MONGO_IMAGE` env var). Persistent volume at `mongo_data`.

### API routes

All routes under `/api` require the `Authorization: Bearer <API_TOKEN>` header and are protected by rate limiting in `middleware/auth.js`.

| Method | Path             | Rate limit     | Description          |
|--------|------------------|----------------|----------------------|
| GET    | `/api/`          | 60 req/min     | List all todos       |
| POST   | `/api/todos`     | 20 req/min     | Create a todo        |
| DELETE | `/api/todos/:id` | 30 req/min     | Delete a todo by ID  |

API responses use a shared envelope: `{ code, success, message, data }`.

### Environment variables

Copy the example files and edit the values. `API_TOKEN` and `VITE_API_TOKEN` must match so the frontend can authenticate with the backend.

| Variable                    | Purpose                          |
|-----------------------------|----------------------------------|
| `MONGO_INITDB_ROOT_USERNAME` | MongoDB root user               |
| `MONGO_INITDB_ROOT_PASSWORD` | MongoDB root password           |
| `MONGODB_URI`               | Backend connection string        |
| `API_TOKEN`                 | Backend bearer token for `/api`  |
| `MONGO_IMAGE`               | (optional) Override Mongo image  |
| `VITE_API_TOKEN`            | Frontend bearer token (must match `API_TOKEN`) |

## Production / AWS deployment

See the project root for Terraform modules, Kubernetes manifests (`k8s-infra-aws-ssm-dev-uat/` and `k8s-infra-aws-ssm-prod/`), and deploy scripts under `script/`.

The Dockerfiles under `src/` are:

- **`backend/Dockerfile`** — Node 22 bookworm-slim image running Nodemon (`npm run dev`). Used by CI / ECR push.
- **`backend/Dockerfile-local`** — Same as `Dockerfile`; used by `compose.yaml` for local development.
- **`frontend/Dockerfile`** — Multi-stage build: Vite dev server → Vite build → nginx 1.29-alpine serving `dist/`. Used by CI / ECR push.
- **`frontend/Dockerfile-local`** — Node 22 bookworm image running the Vite dev server. Used by `compose.yaml` for local development.

## Stop

```bash
docker compose down        # stop containers, keep volumes
docker compose down -v     # also remove volumes
```
