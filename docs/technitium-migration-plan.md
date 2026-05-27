# Technitium Migration Plan (Replace PowerDNS + Blocky)

This runbook is tailored for the current repo setup:
- Authoritative internal DNS: `PowerDNS` in `local-dns`
- Internal DNS automation: `external-dns-local` with `provider: pdns`
- DNS filtering/forwarding over VPN+DoH: `Blocky` in `blocky`

## Current State (from repo)

- `external-dns-local` writes records to PowerDNS API:
  - `provider: pdns`
  - `--pdns-server=http://powerdns-api.local-dns.svc:8081`
  - File: `kubernetes/apps/network/external-dns-local/external-dns-local.yaml`
- PowerDNS serves internal authoritative DNS with two LB service IPs:
  - `192.168.222.101` and `192.168.222.102`
  - File: `kubernetes/apps/network/local-dns/powerdns.yaml`
- Blocky provides filtering and upstream privacy via Gluetun sidecar:
  - DoH/DoT endpoints exposed
  - File: `kubernetes/apps/network/blocky/blocky.yaml`

## Decision

Use **Technitium DNS Server** as single DNS stack for:
1. Authoritative internal zone(s)
2. Recursive resolver + ad/malware blocking
3. Forwarding to public resolvers over VPN + DoH

For ExternalDNS integration, use:
- **Recommended:** `external-dns` provider `rfc2136` (no custom webhook needed)
- **Fallback:** `webhook` provider + Technitium API adapter

## Why RFC2136 is the default path

- ExternalDNS has first-party `rfc2136` provider support.
- Technitium supports RFC2136 dynamic updates.
- This minimizes custom components compared to webhook adapter.

References:
- ExternalDNS providers/flags/RFC2136 docs:
  - https://kubernetes-sigs.github.io/external-dns/latest/docs/providers/
  - https://kubernetes-sigs.github.io/external-dns/latest/docs/flags/
  - https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/rfc2136/
- Technitium capabilities:
  - https://github.com/TechnitiumSoftware/DnsServer

## Target Architecture

- New namespace: `technitium-dns`
- Technitium deployed with:
  - `replicas: 2` (or 3)
  - Service `LoadBalancer` for DNS (UDP/TCP 53)
  - Optional API/UI service ingress (internal/admin only)
- Upstream egress path:
  - Keep Gluetun sidecar pattern from Blocky
  - Technitium forwards to DoH resolvers through VPN sidecar
- ExternalDNS local updater:
  - Existing `external-dns-local` HelmRelease switched from `pdns` to `rfc2136`
  - Update targets Technitium authoritative zone with TSIG

## Migration Phases

## Phase 0: Preflight

1. Lower TTL for internal records if currently high (temporary, e.g. 60-120s).
2. Export/backup PowerDNS zone data.
3. Capture baseline checks:
   - `dig` against `192.168.222.101` and `.102`
   - critical hostnames and internal-only overrides.
4. Keep current services running during whole migration.

## Phase 1: Deploy Technitium in parallel

Create new manifests under:
- `kubernetes/apps/network/technitium-dns/technitium-dns.yaml`

Initial components:
1. Namespace `technitium-dns`
2. ExternalSecret(s) for:
   - admin credentials/API token
   - VPN credentials (reuse Gluetun secret model)
3. HelmRelease/app-template (or direct Deployment) with:
   - Technitium container
   - optional Gluetun sidecar
   - persistent volume for Technitium config/data
4. Service LoadBalancer for DNS (new temporary IP, do not reuse old IP yet)
5. NetworkPolicies equivalent to current DNS/API restrictions

Validation:
- Technitium UI/API reachable internally
- DNS query success for recursive queries
- DoH upstream actually exits via VPN

## Phase 2: Migrate zone data

1. Create/import internal zone(s) into Technitium.
2. Recreate required records from PowerDNS:
   - A/AAAA/CNAME/TXT/SRV/etc
3. Validate zone answers directly against Technitium LB IP.

Important:
- Make sure Technitium zone allows RFC2136 updates and TSIG policy for ExternalDNS writer identity.

## Phase 3: Move external-dns-local to RFC2136

Edit file:
- `kubernetes/apps/network/external-dns-local/external-dns-local.yaml`

Changes:
1. Replace `provider: pdns` with `provider: rfc2136`
2. Remove PDNS API args/env
3. Add RFC2136 args and TSIG secret references
4. Keep existing behavior:
   - `sources: [service]`
   - `annotationFilter: external-dns.alpha.kubernetes.io/internal=true`
   - `domainFilters: [${DOMAIN}]`

Example values block (adapt placeholders):

```yaml
values:
  provider: rfc2136
  policy: sync
  txtOwnerId: "k8s-local-dns"
  txtPrefix: local-
  sources:
    - service
  domainFilters:
    - ${DOMAIN}
  annotationFilter: external-dns.alpha.kubernetes.io/internal=true
  publishInternalServices: true
  extraArgs:
    - --rfc2136-host=technitium-dns.technitium-dns.svc
    - --rfc2136-port=53
    - --rfc2136-zone=${DOMAIN}
    - --rfc2136-tsig-keyname=externaldns-key.
    - --rfc2136-tsig-secret-alg=hmac-sha256
    - --rfc2136-tsig-axfr
  env:
    - name: EXTERNAL_DNS_RFC2136_TSIG_SECRET
      valueFrom:
        secretKeyRef:
          name: technitium-rfc2136-tsig
          key: secret
```

Then add one arg (or value flag depending chart mapping):

```yaml
    - --rfc2136-tsig-secret=$(EXTERNAL_DNS_RFC2136_TSIG_SECRET)
```

Notes:
- Some deployments use direct arg substitution for secret.
- Validate exact chart behavior before final apply.

## Phase 4: DNS client cutover

1. Keep old PowerDNS and Blocky live.
2. Move a small client subset to Technitium LB IP.
3. Verify:
   - internal service names resolve correctly
   - split behavior (internal answers first)
   - ad-blocking behavior parity
   - upstream privacy path over VPN+DoH
4. Gradually move remaining clients.

## Phase 5: Swap service IPs (optional)

If you want no DHCP/client changes:
1. Reassign old DNS LB IP(s) from PowerDNS/Blocky services to Technitium service.
2. Apply in maintenance window to avoid IP conflict race.

## Phase 6: Decommission legacy stack

After stable period (e.g. 7 days):
1. Scale down/remove `blocky` resources.
2. Remove `external-dns-local` PDNS secrets no longer used.
3. Scale down/remove `powerdns` resources.
4. Keep backups of zone/config exports.

## Rollback Plan (fast)

If any failure after Phase 3/4:
1. Switch clients back to old DNS IPs.
2. Revert `external-dns-local` manifest to `provider: pdns`.
3. Reconcile Flux.
4. Confirm updates are again written to PowerDNS API.

Because migration is parallel-first, rollback should be low-risk and fast.

## File-by-File Change List

1. Create:
- `kubernetes/apps/network/technitium-dns/technitium-dns.yaml`

2. Modify:
- `kubernetes/apps/network/external-dns-local/external-dns-local.yaml`
  - switch provider and auth model

3. Later remove:
- `kubernetes/apps/network/blocky/blocky.yaml`
- `kubernetes/apps/network/local-dns/powerdns.yaml`

## Checklist

- [ ] Technitium pods healthy (>=2 replicas)
- [ ] Persistent config volume mounted
- [ ] RFC2136 dynamic updates accepted with TSIG
- [ ] ExternalDNS writes/updates/deletes records correctly
- [ ] Internal service annotations still drive local DNS records
- [ ] Filtering lists imported and effective
- [ ] Upstream recursive queries confirmed over VPN + DoH
- [ ] Client migration completed
- [ ] Rollback tested at least once before decommission
