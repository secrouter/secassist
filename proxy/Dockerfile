# SecRouter auth proxy — zero-dependency Node service (node: builtins only).
FROM node:22.13-alpine

# Non-root.
RUN addgroup -S sec && adduser -S sec -G sec
WORKDIR /app
COPY secrouter-auth-proxy.mjs ./
USER sec

# NODE_EXTRA_CA_CERTS can be mounted to trust the suite's internal CA (SecCert).
EXPOSE 8088
ENTRYPOINT ["node", "secrouter-auth-proxy.mjs"]
