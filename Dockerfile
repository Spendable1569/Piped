FROM node:24-alpine AS build

# The frontend reads the backend and proxy URLs from the environment at build
# time, but .dockerignore excludes .env, so without these the URLs compile to
# undefined and the built image cannot reach any backend. Override with
# --build-arg to point the image at a different instance.
ARG VITE_PIPED_API=https://pipedapi.kavin.rocks
ARG VITE_PIPED_PROXY=https://pipedproxy.kavin.rocks
ARG VITE_PIPED_INSTANCES=https://piped-instances.kavin.rocks/
ENV VITE_PIPED_API=$VITE_PIPED_API \
    VITE_PIPED_PROXY=$VITE_PIPED_PROXY \
    VITE_PIPED_INSTANCES=$VITE_PIPED_INSTANCES

WORKDIR /app/

RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
    curl

COPY . .

RUN corepack enable && corepack prepare pnpm@latest --activate

RUN --mount=type=cache,target=/root/.local/share/pnpm \
    pnpm install --prefer-offline && \
    pnpm build && ./localizefonts.sh

FROM nginxinc/nginx-unprivileged:alpine

COPY --chown=101:101 --from=build /app/dist/ /usr/share/nginx/html/

COPY --chown=101:101 docker/nginx.conf /etc/nginx/conf.d/default.conf

COPY docker/entrypoint.sh /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
