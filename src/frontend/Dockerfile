# syntax=docker/dockerfile:1.4

FROM node:lts-buster AS dev-server

WORKDIR /usr/src/app

COPY package.json /usr/src/app
COPY package-lock.json /usr/src/app

RUN npm ci

COPY . /usr/src/app

EXPOSE 3000
CMD ["npm", "start"]

FROM dev-server AS build

RUN npm run build

FROM nginx:1.27-alpine AS development

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /usr/src/app/build /usr/share/nginx/html

EXPOSE 3000
CMD ["nginx", "-g", "daemon off;"]
