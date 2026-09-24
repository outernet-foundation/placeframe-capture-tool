ARG CADDY_IMAGE

FROM ${CADDY_IMAGE}

COPY workloads/aoa-gateway/Caddyfile /etc/caddy/Caddyfile

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
