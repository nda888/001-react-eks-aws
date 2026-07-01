# Frontend — React + Vite

## Stack

| Layer | Technology |
| --- | --- |
| UI | React 19 |
| Build | Vite 6 |
| CSS | Bootstrap 5 + Sass |
| HTTP | Axios |
| Testing | Vitest |
| Production | nginx 1.29-alpine (multi-stage Docker image) |

## Structure

```
frontend/
├── Dockerfile                # Multi-stage: dev → build → nginx
├── Dockerfile-local          # Vite dev server image
├── .dockerignore
├── .env.example
├── package.json
├── vite.config.js            # Vite config with React plugin and `/api` proxy
├── index.html                # Entry HTML
├── nginx.conf                # nginx config for production
├── public/                   # Static assets
│   ├── favicon.ico
│   ├── logo192.png
│   ├── logo512.png
│   ├── manifest.json
│   └── robots.txt
└── src/
    ├── index.jsx              # React entry point
    ├── index.css
    ├── App.jsx                # Root component
    ├── App.scss
    ├── App.test.jsx           # Smoke test
    ├── custom.scss            # Bootstrap overrides
    ├── setupTests.js          # Vitest setup
    ├── logo.svg
    └── components/
        ├── AddTodo.jsx         # Todo input form
        └── TodoList.jsx        # Todo list display
```

## Local development

```bash
npm install
cp .env.example .env          # set VITE_API_TOKEN to match backend API_TOKEN
npm start                     # Vite dev server on port 3000 (hot reload)
```

## Testing

```bash
npm test                      # vitest run (single run)
```

## Production build

```bash
npm run build                 # Vite production build → dist/
npm run preview               # Preview production build locally
```

## Docker

```bash
# Development (Vite dev server with hot reload)
docker build --target development -t frontend-dev -f Dockerfile-local .
docker run -p 3000:3000 --env-file .env frontend-dev

# Production (nginx serving static build)
docker build --build-arg VITE_API_TOKEN=<token> -t frontend .
docker run -p 3000:3000 frontend
```

## Environment variables

| Variable | Purpose |
| --- | --- |
| `VITE_API_TOKEN` | Bearer token sent to backend; must match backend `API_TOKEN` |

There is no `VITE_API_URL` in this app. In development Vite proxies `/api` to `http://backend:3000`; in production nginx proxies `/api` to the backend service.
