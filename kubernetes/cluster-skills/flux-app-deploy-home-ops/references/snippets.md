# Home-Ops Flux Snippets

## Authentik Forward Auth Annotations (NGINX)

```yaml
nginx.ingress.kubernetes.io/auth-url: "https://auth.${DOMAIN}/outpost.goauthentik.io/auth/nginx"
nginx.ingress.kubernetes.io/auth-signin: "https://auth.${DOMAIN}/outpost.goauthentik.io/start?rd=$scheme://$http_host$escaped_request_uri"
nginx.ingress.kubernetes.io/auth-response-headers: "Set-Cookie,X-authentik-username,X-authentik-email,X-authentik-name,X-authentik-uid,X-authentik-groups,X-authentik-jwt,X-authentik-meta"
nginx.ingress.kubernetes.io/auth-snippet: |
  proxy_set_header Host $host;
  proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
  proxy_set_header X-Original-URI $request_uri;
  proxy_set_header X-Original-Host $http_host;
  proxy_set_header X-Forwarded-Host $http_host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header X-Forwarded-Uri $request_uri;
  proxy_set_header X-Original-Method $request_method;
```

## Service DNS (PowerDNS)

```yaml
external-dns.alpha.kubernetes.io/internal: "true"
external-dns.alpha.kubernetes.io/hostname: "<app>.${DOMAIN}"
external-dns.alpha.kubernetes.io/target: "cluster-ingress.${DOMAIN}"
```

## Ingress DNS (Cloudflare Tunnel)

```yaml
external-dns.alpha.kubernetes.io/target: ${CLOUDFLARE_TUNNEL_TARGET}
external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
external-dns.alpha.kubernetes.io/hostname: "<app>.${DOMAIN}"
```
