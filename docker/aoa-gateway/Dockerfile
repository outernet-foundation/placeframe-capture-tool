ARG CADDY_IMAGE

FROM ${CADDY_IMAGE}

COPY docker/aoa-gateway/Caddyfile /etc/caddy/Caddyfile

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
