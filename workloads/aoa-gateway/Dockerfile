ARG AOA_GATEWAY_IMAGE

FROM ${AOA_GATEWAY_IMAGE}

COPY workloads/aoa-gateway/Caddyfile /etc/caddy/Caddyfile

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
