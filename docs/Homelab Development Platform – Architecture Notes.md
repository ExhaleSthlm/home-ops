# Homelab Development Platform – Architecture Notes

**Status:** Planeringsunderlag · **Datum:** 2026-10-11

## Mål

En självhostad utvecklingsplattform i befintligt **Talos/Cozystack Kubernetes-kluster**, med både webbaserad och lokal VS Code-åtkomst. Plattformen ska stödja ESP32-utveckling och minska beroendet av externa Git-, container- och paketservrar.

## Översikt

```text
Mac (VS Code Desktop) ────────┐
                              ├── Coder ── Kubernetes Workspace
Webbläsare (Selkies) ─────────┘                │
                                    VS Code Desktop (LinuxServer.io)
                                    ESP-IDF / Arduino / PIOArduino
                                    ESPHome / Node.js / Vite
                                               │
                                   Build → OTA / firmware artifact
                                               │
                                  Mac USB → esptool (första flash)

GitHub / GHCR ──┐
Docker Hub ─────┼── git-pkgs/proxy ── Garage S3 (NAS)
npm / PyPI ─────┘           │
                          metadata: CNPG (föreslaget)

Gitea (planerat) → Git + Actions + registry för egna OCI-images
```

## 1. Coder och utvecklingsmiljön

- **Coder** provisionerar och hanterar workspaces i Kubernetes (start/stopp, åtkomst och resurser).
- **LinuxServer.io VS Code Desktop** (`lscr.io/linuxserver/vscode`) är kandidat för *full* Linux-VS Code (Electron), visad i webbläsaren via **Selkies**. Det är inte samma sak som `code-server` eller `vscode.dev`.
- På **Mac** används vanliga VS Code Desktop med remote-anslutning till **samma Coder-workspace**. Projektfiler och byggverktyg ligger på serversidan; klienternas extensions och inställningar kan skilja sig.
- Utvärdera även alternativet egen workspace-image med officiell VS Code Desktop + Selkies, för bättre kontroll över versionslåsning, användare och säkerhet.
- Toolchains i workspace: **ESP-IDF**, **Arduino CLI/Core**, **PIOArduino/PlatformIO**, **ESPHome**, Python, Node.js och Vite (t.ex. Svelte/SolidJS).
- Versionslås verktyg och image; undvik `latest` i produktion. Använd persistent lagring för projekt/cache där det behövs.

### Flashning och felsökning

- **Första flashning/återställning:** ESP32 ansluts via USB till Mac. Bygg firmware i Coder, överför binärfil och flasha lokalt med **`esptool`** (eller ESP Web Tools via Chromium/Web Serial).
- **Efter första flashning:** OTA direkt från Coder till ESP32 via nätverket; säkerställ routing/brandvägg till IoT-VLAN.
- **Seriell monitor/JTAG:** lokalt på Mac, alternativt separat fjärrbrygga senare. Coder-containern ser inte automatiskt Macens USB-enheter.
- Standardisera gärna firmware-artifacts och manifest, men använd rätt offsets/partitioner för respektive framework och chip.

## 2. Befintlig infrastruktur som återanvänds

| Komponent | Tänkt användning |
|---|---|
| Talos / Cozystack / Kubernetes | Coder, workspaces, Gitea och proxy |
| nginx Ingress + cert-manager | HTTPS med befintligt `*.myk8s.se`-certifikat |
| Authentik | Helst **OIDC direkt till Coder**, undvik onödig dubbel forward-auth |
| External Secrets + Infisical | Secrets för S3, databaser och tjänster |
| Reflector | Certifikat-/Secret-distribution vid behov |
| FluxCD + Renovate | GitOps och uppdateringar |
| CNPG | PostgreSQL för tjänster som behöver det |
| Garage på NAS | S3-objektlagring för paket-/image-cache |

**TLS:** `*.myk8s.se` täcker `coder.myk8s.se`, men inte `*.coder.myk8s.se`. Subdomänbaserade workspace-appar kan behöva separat wildcard-certifikat eller annan URL-strategi. För Selkies kan Coder proxya intern HTTP (exempelvis port 3000) bakom befintlig HTTPS, så att dess självsignerade certifikat inte behöver användas externt.

## 3. Gitea – planerad, inte installerad

- Självhostad **Git-server** och möjlig spegel/alternativ till GitHub.
- **Gitea Actions** för CI/CD.
- Inbyggt **Packages/OCI container registry** för egna images, exempelvis Coder-workspace-images.
- Inte avsett som generell pull-through-cache för alla externa containerregistries.
- **GHCR** är ett enkelt interimistiskt registry tills Gitea är driftsatt.
- Vid GitOps-migrering: tänk på bootstrap och åtkomst till Git om klustret är nere; behåll extern spegel/backup.

## 4. git-pkgs/proxy – prioriterad utvärdering

Projekt: <https://github.com/git-pkgs/proxy>

- En gemensam **cachande proxy** för externa OCI/containerimages och utvecklingspaket såsom **npm** och **PyPI**.
- **Garage S3 på NAS** föreslås för cacheobjekt, hellre än en stor Linstor-PVC.
- **CNPG/PostgreSQL** föreslås för metadata om projektets aktuella konfiguration stöder det; annars SQLite med liten persistent volym.
- Secrets hämtas via **External Secrets/Infisical**.
- Börja med Coder/utvecklingspaket och manuella OCI-tester. Konfigurera **Talos/containerd registry mirrors** först när OCI-stöd, upstream-mappning, digesthantering och fallback har verifierats.
- Proxy-endpoints bör nås internt utan interaktiv Authentik-redirect; begränsa åtkomst via nätverkspolicy/Ingress.

**Att verifiera mot aktuell version:** S3-backend för OCI-lager och andra paket, PostgreSQL-schema/metadata, retention/eviction, privat registry-autentisering, Helm-värden, samt beteende vid upstream- eller proxyavbrott.

## 5. Spegel – uppskjutet

**Spegel införs inte i första etappen.** Det är P2P-delning av images som redan finns i nodernas containerd-cache, inte ett push-registry eller en beständig cache. Kan utvärderas senare om nod-till-nod-distribution blir ett verkligt behov.

## 6. Viktiga driftsfrågor

- **Offline-drift är inte automatiskt garanterad:** Endast tidigare cachade images/paket finns lokalt; en cache eller Gitea *inne i klustret* kan skapa bootstrapberoenden.
- **Garage på NAS** måste vara tillgängligt när proxyn behöver läsa cachade objekt.
- **Coder och Selkies:** verifiera WebSocket/WebRTC-proxy, tangentbord/clipboard, extensions, prestanda och att browser- respektive Mac-klienten verkligen delar arbetsmiljö utan konflikter.
- **Säkerhet:** granska LinuxServer.io-imagens standardbehörigheter och åtkomstskydd; exponera inte dess desktopport direkt på internet.

## Föreslagen införandeordning

1. **Coder PoC:** en workspace i Kubernetes med LinuxServer.io VS Code Desktop/Selkies och åtkomst från både browser och Mac VS Code.
2. **ESP32-toolchains:** bygg ESP-IDF/PIOArduino/ESPHome; testa Mac USB-flash och OTA till IoT-VLAN.
3. **git-pkgs/proxy PoC:** Garage-bucket + metadata-backend; testa npm, PyPI och OCI innan cluster-wide mirror.
4. **Gitea:** Git, Actions och eget OCI-registry; börja med spegling från GitHub.
5. **Senare:** eventuell Talos registry-mirror och Spegel om behov uppstår.

## Referenser

- [Coder](https://coder.com/docs/)
- [LinuxServer.io VS Code](https://docs.linuxserver.io/images/docker-vscode/)
- [Selkies](https://github.com/selkies-project/selkies)
- [Gitea Packages – Container Registry](https://docs.gitea.com/usage/packages/container/)
- [git-pkgs/proxy](https://github.com/git-pkgs/proxy)
- [Spegel](https://spegel.dev/)
- [Homelab specification](https://github.com/ExhaleSthlm/home-ops/blob/main/docs/specification.md)
