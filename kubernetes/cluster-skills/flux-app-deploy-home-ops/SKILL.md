---
name: flux-app-deploy-home-ops
description: Deploy and maintain applications in this home-ops cluster using Flux GitOps patterns. Use when creating or updating app manifests under kubernetes/apps, adding namespace prerequisites in kubernetes/bootstrap, wiring BJW app-template HelmReleases, CloudNativePG databases, Reflector wildcard TLS replication, ExternalDNS records for both internal PowerDNS and Cloudflare tunnel ingress, and validating Flux-compatible YAML before commit.
---

# Flux App Deploy Home Ops

## Overview
Follow this workflow to add a new application in this repository without breaking established cluster conventions.

## Workflow
1. Inspect existing manifests in similar apps first.
2. Create namespace and shared prerequisites in `kubernetes/bootstrap/<namespace>-prereqs.yaml`.
3. Create one app manifest in `kubernetes/apps/<group>/<app>/<app>.yaml` unless the user asks for split files.
4. Reuse BJW `app-template` via `chartRef` to `OCIRepository` `app-template` in namespace `cozy-fluxcd`.
5. Add `ExternalSecret` resources for runtime secrets instead of plaintext credentials.
6. Add CloudNativePG `Cluster` when the app needs PostgreSQL.
7. Add internal DNS annotations on Service and Cloudflare DNS annotations on Ingress.
8. Reuse Authentik forward-auth ingress annotations unless explicitly disabled.
9. Ensure wildcard TLS secret is reflected to the target namespace by updating `kubernetes/bootstrap/cloudflare-tls-cert.yaml` allowed namespaces.
10. Validate YAML and key objects before finalizing.

## Repository Conventions
- Use namespace label `ingress.svc.egress: allow` for apps exposed via ingress.
- Keep image tags pinned as `version@sha256:digest`.
- For internal DNS (PowerDNS via external-dns-local), annotate Services with:
  - `external-dns.alpha.kubernetes.io/internal: "true"`
  - `external-dns.alpha.kubernetes.io/hostname: "<app>.${DOMAIN}"`
  - `external-dns.alpha.kubernetes.io/target: "cluster-ingress.${DOMAIN}"`
- For Cloudflare DNS (external-dns), annotate Ingress with:
  - `external-dns.alpha.kubernetes.io/target: ${CLOUDFLARE_TUNNEL_TARGET}`
  - `external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"`
  - `external-dns.alpha.kubernetes.io/hostname: "<app>.${DOMAIN}"`

## CNPG Pattern
- Prefer `instances: 2` for resilient apps and low resource overhead.
- Set `bootstrap.initdb.database`, `owner`, and credential secret.
- Use app DB endpoint: `<cluster-name>-rw.<namespace>.svc:5432`.

## Storage Pattern
- For NAS-backed shared data, use static NFS PV/PVC (`ReadWriteMany`) when matching existing repo style.
- Keep `persistentVolumeReclaimPolicy: Retain` for user data.
- Mount only required paths in the container (`/app/data`, archive directory, or equivalent).
- If dynamic NFS classes are preferred later, migrate PVCs intentionally and keep old PV retained until data is verified.

## App Runtime Notes
- Prefer the simplest runtime profile first (single pod, sqlite, minimal sidecars) for single-user services.
- For Obico specifically: skip CNPG for small installs; keep sqlite on persistent storage.
- Obico still depends on Redis-backed channels/cache. For "simple" setups, run Redis as a sidecar in the same pod instead of a separate Redis deployment.
- Avoid `envsubst` on manifests that contain ingress `$scheme/$host/$request_uri` annotations; substitute only `${...}` placeholders (for example with targeted `perl -pe` replacements) to prevent NGINX auth annotations from being corrupted.

## Validation Commands
Run from repo root:

```bash
kubectl kustomize ./kubernetes/bootstrap >/dev/null
kubectl kustomize ./kubernetes/apps >/dev/null
kubectl apply --dry-run=client -f kubernetes/bootstrap/<file>.yaml >/dev/null
kubectl apply --dry-run=client -f kubernetes/apps/<group>/<app>/<app>.yaml >/dev/null
```

## Checklist Before Merge
- Namespace exists in bootstrap and has required labels.
- TLS wildcard reflector namespace list includes the new namespace.
- Service and Ingress DNS annotations are both present.
- Image uses version plus digest.
- Secrets are sourced from ExternalSecret, not hardcoded.
- DB migrations/bootstrapping requirements are documented in manifest comments when needed.
