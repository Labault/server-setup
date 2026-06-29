# Cahier des charges — `server-setup`

> **Statut : verrouillé.** Toutes les décisions ci-dessous sont arbitrées et figées. Ce document est la source de vérité pour l'implémentation (destiné à Claude Code). Tant qu'une décision figure au §11, elle ne se rediscute pas en cours de build.
>
> **Régénéré à partir de [`bootstrap-web-setup`](https://github.com/Labault/bootstrap-web-setup) mis à jour** (v0.6.0). Délta majeur vs. la v1.1 : la gamme a gagné un **profil `shell`** que bootstrap s'auto-applique. `server-setup` étant lui aussi un repo d'outillage Bash, il **consomme** désormais `bootstrap apply --profile shell` pour son propre outillage qualité, au lieu de le câbler à la main. Détail en §3.2 et Prompt 1.

---

## 1. Mission et raison d'être

La gamme `-setup` couvre une chaîne à quatre maillons :

|Maillon|Repo|Outille…|
|---|---|---|
|1. Machine|[`mac-dev-setup`](https://github.com/Labault/mac-dev-setup)|le poste de dev (installe les binaires, pose la config dans `~/`)|
|2. Projet|[`bootstrap-web-setup`](https://github.com/Labault/bootstrap-web-setup)|un projet web (dépose la config qualité, n'installe rien)|
|3. Serveur|**`server-setup`** ← ce document|une **box nue** (durcit + rend exploitable)|
|4. Runtime|[`push-to-deploy`](https://github.com/Labault/push-to-deploy)|le serveur en prod (proxy Caddy + CD par webhook + ops)|

Il manquait le maillon 3. Aujourd'hui, transformer un VPS Hetzner fraîchement spawné en box prête pour la prod, c'est une checklist manuelle (l'ère du tuto Coolify copié-collé) : créer un user non-root, désactiver root SSH, monter ufw, fail2ban, le swap, les unattended-upgrades, Docker, le réseau `web`… avec la dérive habituelle d'un serveur à l'autre — sauf que là, l'oubli ne diverge pas une config, il laisse un port ouvert.

`server-setup` automatise ce maillon. Il prend une **box Hetzner nue** (Ubuntu LTS fraîche) et la converge vers un état **durci et exploitable**, jusqu'au point exact où `push-to-deploy` n'a plus qu'à se cloner et démarrer.

**Principe directeur, non négociable :** `server-setup` **s'arrête où `push-to-deploy` commence.** Provisionnement + durcissement, rien d'autre. Pas de déploiement d'app, pas de Caddyfile, pas de webhook, pas de stack docker-compose applicative. C'est le pendant de la règle de bootstrap (« n'installe jamais un binaire ») : ici, **`server-setup` ne déploie jamais une app**. La frontière est décrite au §5.

---

## 2. Cible

- **Utilisateur :** mono-utilisateur au départ (toi), forkable ensuite.
- **Serveurs visés :** **Ubuntu LTS** (22.04 / 24.04) sur Hetzner Cloud — cible supportée **et testée**. Debian « marche probablement » mais n'est pas garanti.
- **État de la box :** **fraîche**. Au premier run, on n'a qu'un accès root (clé, éventuellement mot de passe). Le script doit être **idempotent** : relançable sur une box déjà convergée sans rien casser ni redurcir deux fois.
- **Exécution :** **run unique, non-interactif, en root.** Le coupe-circuit anti-lockout (§9.4) couvre la coupure SSH. On se reconnecte ensuite en `deploy` sudoer et on tape `server confirm`.

---

## 3. Cohérence avec la famille

### 3.1 Patterns repris (ce qui en fait un membre de la gamme)

`server-setup` réutilise la grammaire déjà éprouvée dans `mac-dev-setup` et `bootstrap-web-setup`, pour que les quatre repos se ressemblent et que la courbe d'apprentissage soit nulle :

|Pattern de la gamme|Repris dans `server-setup`|
|---|---|
|CLI mono-mot installée par `install.sh`|CLI **`server`**, symlink `bin/server` → `/usr/local/bin/server`|
|Profils héritables, pilotés par manifeste|`minimal` → `docker` → `web` (héritage via `extends`)|
|Manifeste data-driven, **parsé sans `yq`** (awk maison)|Idem — zéro dépendance d'exécution hors base Ubuntu|
|`<tool> doctor` (état réel vs attendu + dérive)|`server doctor` (+ santé de `push-to-deploy`)|
|`--dry-run` sur toute commande mutante|Idem, obligatoire|
|Backup avant remplacement d'un fichier|Idem, sur les fichiers système managés|
|Idempotence (rerun sans casse)|Idem, c'est le cœur du modèle (§4)|
|Fichier d'état avec hash|`state.yaml` — **deux natures** : fichiers (hash) + assertions (prédicats)|
|Architecture Bash en couches (`bin` → `lib/common` → `lib/cmd_*` → moteur)|Idem (§8, §9)|
|`set -euo pipefail`, logs sur stderr / data sur stdout, shellcheck+shfmt-clean|Idem|

### 3.2 La récursion : `server-setup` est outillé par `bootstrap`

Nouveauté apportée par le bootstrap mis à jour. Le profil **`shell`** de bootstrap existe précisément pour outiller les repos Bash de la gamme (bootstrap lui-même, `server-setup`…). Donc :

> **`server-setup` s'auto-applique `bootstrap apply --profile shell`.** Un fichier `.bootstrap.yaml` vit à la racine du repo. C'est bootstrap qui dépose le `shellcheck` / `shfmt` / `bats` / `markdownlint` / `gitleaks` / `lychee`, les workflows CI (`ci.yml`, `security.yml`, `tests.yml`), le `Makefile`, le `dependabot.yml`. On ne câble **rien** de tout ça à la main.

Il faut tenir deux plans bien distincts, sans jamais les confondre :

|Plan|Qui le configure|Quoi|
|---|---|---|
|**Outillage dev du repo** (méta)|`bootstrap --profile shell`|hooks, lint, tests, CI du repo `server-setup`|
|**Ce que `server-setup` fait à un serveur**|`server-setup` lui-même|durcissement, Docker, réseau `web`, user `deploy`…|

La gamme mange désormais sa propre nourriture en cascade : bootstrap outille le repo de `server-setup`, et `server-setup` outille le VPS. Joli, et accessoirement ça supprime ~80 % du Prompt 1 d'origine.

### 3.3 Les divergences assumées vs. bootstrap

Trois différences structurantes imposées par le domaine. Elles ne sont pas des écarts de style, ce sont des conséquences directes du fait qu'on agit sur une **machine vivante** et pas sur un dossier de projet :

1. **Convergeur, pas templateur.** bootstrap copie des fichiers puis oublie (one-shot évolutif). `server-setup` **converge une machine vers un état désiré** (façon mini-Ansible). Conséquence directe : **pas de verbe `reconcile`** — c'est `setup` qui reconverge. Voir §4.
2. **État à deux natures.** L'état de bootstrap, ce sont des hash de fichiers. Celui de `server-setup` aussi, **plus** des **assertions** : on ne « hash » pas _« root login désactivé »_, on **re-teste** le prédicat. Voir §10.1.
3. **Asymétrie de test (D15).** bootstrap s'auto-applique sur son runner CI. `server-setup` **ne peut pas durcir son propre runner GitHub** (on ne coupe pas le SSH root d'un runner éphémère). D'où : tests unitaires `bats` + harnais d'acceptation **en conteneur** pour le non-destructif, et **dogfooding sur le vrai VPS de prod** pour la partie destructive. Voir §12.

---

## 4. Modèle d'exécution — convergeur d'état désiré

La question « one-shot ou durable » de bootstrap ne se pose pas ici de la même façon. Un serveur **dérive tout seul** : un paquet se met à jour, quelqu'un touche une config, un `ufw disable` traîne dans un historique. L'outil ne peut donc pas « poser et oublier » : il doit pouvoir **re-vérifier et re-converger**.

### 4.1 Décision (D1)

**Convergeur d'état désiré.** `server setup --profile <p>` lit l'état désiré du profil, compare à l'état réel de la machine, et **n'agit que sur ce qui a dérivé**. Relancer la commande sur une box déjà conforme est un no-op. Mental model : `ansible-playbook` réduit à l'os, pas `composer create-project`.

Conséquence : **aucun `reconcile`**. Le 3-way merge de bootstrap n'a pas de sens sur des prédicats système — « le port 22 est ouvert » n'a pas de version locale à fusionner, il est vrai ou faux. `setup` **est** la réconciliation.

### 4.2 La pièce clé — `state.yaml` à deux natures

À chaque `setup`, `server-setup` écrit `/var/lib/server-setup/state.yaml` : profil convergé, double champ de version, et **deux collections** — les **fichiers managés** (avec hash, comme bootstrap) et les **assertions** (id + statut + horodatage). C'est ce que relit `server doctor` pour détecter la dérive. Contrat complet en §10.1.

### 4.3 Idempotence

Relancer `server setup --profile minimal` sur une box convergée ne doit produire **aucun changement** là où tout est déjà satisfait, et ne re-jouer que les unités dérivées. Un rerun = une remise en conformité propre, jamais une duplication ni un re-durcissement aveugle (on ne réécrit pas un swapfile de 2 Go pour le plaisir).

---

## 5. Périmètre — où s'arrête `server-setup`

La frontière est **la ligne d'arrivée de `server-setup` = la ligne de départ de `push-to-deploy`**. Le « Quick start (VPS setup) » de `push-to-deploy` se résume à : réseau `web`, clone, `.env`, `docker compose up -d`. `server-setup` doit garantir que **tout ce qui précède le clone est déjà fait**, et **rien de plus**.

### 5.1 DANS le périmètre

- **Durcissement OS** : drop-in SSH (root off, password off, pubkey only), user `deploy` non-root + sudo, `ufw` deny-by-default, `fail2ban`, `unattended-upgrades`.
- **Defaults système** : timezone, locale, synchro horaire, swap, cap journald, `known_hosts` GitHub, baseline `sysctl` (vide par défaut, voir D6).
- **Runtime conteneur** : Docker Engine + plugin `compose`, `daemon.json`.
- **Le réseau `web`** : créé par `server-setup` (il en est **propriétaire**, D5).
- **Pare-feu applicatif** : ouverture de 80/443 (profil `web` uniquement, D4).

### 5.2 HORS périmètre — le boulot de `push-to-deploy` (documenté pour traçabilité)

- Le **proxy Caddy** lui-même, le **`Caddyfile`**, les certificats TLS (Let's Encrypt s'en charge côté Caddy), les **security headers**.
- Le **listener webhook**, le `dispatch.sh`, les **deploy keys**, le `.env` (secret HMAC).
- Toute **stack docker-compose applicative** et tout `deploy.sh` de projet.

> `server-setup` t'amène sur le **paillasson**. `push-to-deploy` entre dans la maison. La porte (le réseau `web`, le user `deploy`, les ports ouverts) est posée et déverrouillée ; ce qu'on installe dans le salon ne le regarde pas.

### 5.3 HORS périmètre — définitivement

App, code, bases de données, données. `server-setup` ne `git clone` aucune app et ne touche à aucune donnée métier.

---

## 6. Inventaire détaillé — ce que `server-setup` converge

Pour chaque unité : ce qu'elle fait, le **fichier managé** déposé (le cas échéant) et/ou **l'assertion** re-vérifiable, et le profil qui la déclenche.

### 6.1 Profil `minimal` — durcissement + defaults

|#|Unité|Fichier managé / Assertion|Profil|
|---|---|---|---|
|1|**User `deploy`**|user non-root, dans `sudo`, `NOPASSWD` validé par `visudo -cf`, `authorized_keys` semée depuis la clé root entrante|`minimal`|
|2|**ufw deny-by-default + SSH**|`ufw default deny incoming` / `allow out` + `allow 22` ; activé **après** la règle SSH (anti-lockout, §9.3)|`minimal`|
|3|**fail2ban**|jail `sshd` (seuils chiffrés au §10.5)|`minimal`|
|4|**unattended-upgrades**|MAJ sécurité auto + reboot auto **04:00**|`minimal`|
|5|**Timezone**|**UTC** par défaut, override `--timezone`|`minimal`|
|6|**Locale**|`en_US.UTF-8` générée + définie|`minimal`|
|7|**Synchro horaire**|`systemd-timesyncd` actif|`minimal`|
|8|**Swap**|`/swapfile` **2 Go** + `vm.swappiness=10`|`minimal`|
|9|**Cap journald**|`SystemMaxUse` plafonné (drop-in `journald.conf.d`)|`minimal`|
|10|**`known_hosts` GitHub**|`github.com` pré-semé (pour les pulls SSH des app repos _plus tard_, côté push-to-deploy)|`minimal`|
|11|**Baseline `sysctl`**|drop-in **vide** par défaut ; tout le hardening réseau derrière `--paranoid` (D6)|`minimal`|
|12|**Drop-in SSH**|`99-server-setup.conf` : root off, password off, pubkey only — **séquence de cutover dédiée** (§9.3)|`minimal`|

### 6.2 Profil `docker` — runtime conteneur (`extends: minimal`)

|#|Unité|Fichier managé / Assertion|Profil|
|---|---|---|---|
|13|**Docker Engine + `compose`**|dépôt apt officiel Docker ; assertion = binaire présent **et** daemon actif|`docker`|
|14|**`daemon.json`**|rotation des logs + garde-fous (la **leçon des 16 Go de build cache** qui a tué `proxy_caddy` : `log-opts`, et pas de cache qui gonfle en silence)|`docker`|
|15|**`deploy` dans le groupe `docker`**|assertion d'appartenance|`docker`|

### 6.3 Profil `web` — paillasson de `push-to-deploy` (`extends: docker`)

|#|Unité|Fichier managé / Assertion|Profil|
|---|---|---|---|
|16|**ufw 80/443**|`allow 80,443` (le pare-feu **grandit** avec le profil, D4)|`web`|
|17|**Réseau `web`**|`docker network create web` idempotent — `server-setup` **en est propriétaire** (D5)|`web`|
|18|**Footgun ufw × Docker**|documenté + assertion : **seul Caddy publie 80/443**, le reste reste `internal` ; `ufw-docker` en **opt-in** (D8)|`web`|

---

## 7. Profils

Le profil décide **quelles unités sont convergées** et **quels binaires sont requis**. Comme dans bootstrap, ils sont data-driven : un manifeste par profil, parsé par un awk maison (**pas de `yq`**), héritage via `extends`.

|Profil|Pour quoi|Ajoute au-dessus de son parent|
|---|---|---|
|`minimal`|Box durcie, sans Docker|durcissement OS + defaults système (unités 1–12)|
|`docker`|+ runtime conteneur|Docker Engine + `compose`, `daemon.json`, `deploy` dans `docker` (13–15)|
|`web`|+ paillasson push-to-deploy|ufw 80/443, réseau `web`, gestion du footgun ufw×Docker (16–18)|

**Le pare-feu grandit avec le profil (D4) :** `minimal` n'ouvre que **22**. 80/443 n'arrivent qu'avec `web`. On ne laisse jamais un port ouvert « au cas où ».

**`--profile` est obligatoire et explicite.** Pas de défaut silencieux, **pas de sous-commande `detect`** : provisionner un serveur n'est pas un geste qu'on laisse deviner par un heuristique. (Décision durcie A1.)

### Format du manifeste (proposition, alignée bootstrap)

```yaml
# profiles/docker.yaml
extends: minimal            # héritage de capacité
requires_bin:               # binaires requis pour CE profil (vérifiés avant d'agir)
  - docker
files:                      # fichiers système managés : dest = chemin absolu, backup + hash
  - src: templates/docker/daemon.json
    dest: /etc/docker/daemon.json
units:                      # unités d'état désiré activées par ce profil (logique dans lib/)
  - docker-engine
  - docker-compose-plugin
  - deploy-in-docker-group
```

L'ajout d'un **profil** est de la donnée. L'ajout d'un **nouveau type d'unité** (un nouveau prédicat + son action) est du code, dans `lib/assert.sh` + `lib/converge.sh` — honnête et assumé : un convergeur n'est pas un copieur de fichiers.

---

## 8. Structure skeleton — arborescence

Arborescence du **dépôt `server-setup`** (l'outillage dev est déposé par `bootstrap --profile shell`, marqué `← bootstrap`) :

```text
server-setup/
├── install.sh                  # symlink bin/server -> /usr/local/bin/server (équiv. serveur de ~/.local/bin)
├── bin/
│   └── server                  # dispatcher (garde bash 4+, SERVER_ROOT symlink-safe, flags globaux)
├── lib/
│   ├── common.sh               # logs (stderr), --dry-run, die, require_root (EUID 0), tildify
│   ├── cmd_setup.sh            # le verbe `server setup` (boucle de convergence)
│   ├── cmd_doctor.sh           # ré-évalue les assertions + santé push-to-deploy
│   ├── cmd_confirm.sh          # `server confirm` (désarme le coupe-circuit)
│   ├── cmd_list.sh             # liste les profils + leur contenu
│   ├── cmd_update.sh           # met à jour server-setup lui-même (git pull dans /opt)
│   ├── manifest.sh             # parser awk + héritage (PAS de yq) — calqué sur bootstrap
│   ├── converge.sh             # moteur : pour chaque unité, assert -> agir si dérive -> ré-assert
│   ├── assert.sh               # bibliothèque de prédicats (root-off ? ufw-active ? web-network ? …)
│   ├── state.sh                # écrit /var/lib/server-setup/state.yaml (fichiers + assertions)
│   ├── state_read.sh           # lit l'état
│   ├── backup.sh               # backup d'un fichier système avant écrasement
│   ├── deadman.sh              # coupe-circuit systemd-run --on-active + rollback
│   └── bincheck.sh             # garde des binaires requis (par profil)
├── templates/                  # fichiers SYSTÈME managés (drop-ins), dest = chemins absolus
│   ├── ssh/99-server-setup.conf
│   ├── fail2ban/jail.local
│   ├── unattended/52-server-setup.conf
│   ├── sysctl/99-server-setup.conf      # vide hors --paranoid
│   ├── journald/99-server-setup.conf
│   └── docker/daemon.json
├── profiles/
│   ├── minimal.yaml
│   ├── docker.yaml
│   └── web.yaml
├── tests/                      # ← bootstrap (suite bats : smoke.bats + test_helper.bash)
├── validation/                # harnais d'acceptation black-box (en conteneur)
│   ├── run-all.sh
│   └── cases/
├── docs/
│   ├── cahier-des-charges-server-setup.md   # ce fichier
│   ├── architecture.md
│   ├── assets/images/system-overview.svg
│   └── profiles/{minimal,docker,web}.md
├── .bootstrap.yaml             # ← bootstrap : état de l'auto-application du profil shell
├── .pre-commit-config.yaml     # ← bootstrap
├── .gitleaks.toml .shellcheckrc .markdownlint-cli2.yaml .editorconfig lychee.toml   # ← bootstrap
├── .github/workflows/{ci,security,tests}.yml                                        # ← bootstrap
├── Makefile  Makefile.local                                                         # ← bootstrap (+ cibles repo-local)
├── CLAUDE.md  SECURITY.md  CONTRIBUTING.md                                          # ← bootstrap (squelettes à enrichir)
├── CHANGELOG.md  VERSION  LICENSE  README.md
```

Et voici ce qui **atterrit sur le serveur** après `server setup --profile web` :

```text
/usr/local/bin/server                         # symlink -> /opt/server-setup/bin/server
/opt/server-setup/                            # le clone (cible de `server update`)
/var/lib/server-setup/state.yaml              # état : profil + version + fichiers (hash) + assertions
/etc/ssh/sshd_config.d/99-server-setup.conf   # root off, password off, pubkey only
/etc/fail2ban/jail.local
/etc/apt/apt.conf.d/52-server-setup.conf      # unattended-upgrades
/etc/sysctl.d/99-server-setup.conf            # vide hors --paranoid
/etc/systemd/journald.conf.d/99-server-setup.conf
/etc/docker/daemon.json
/swapfile                                     # 2 Go
# + user `deploy` (sudo NOPASSWD, dans docker), ufw actif (22/80/443), réseau docker `web`
```

---

## 9. Comportement de la CLI

### 9.1 Commandes

|Commande|Effet|
|---|---|
|`server setup --profile <p>`|Converge la box vers l'état du profil + écrit `state.yaml`|
|`server setup --profile <p> --dry-run`|Liste ce qui serait changé, n'agit pas|
|`server confirm`|Désarme le coupe-circuit anti-lockout (§9.4)|
|`server doctor`|Ré-évalue les assertions du profil convergé + santé push-to-deploy|
|`server list`|Liste les profils, leur héritage, binaires requis et unités|
|`server update`|Met à jour `server-setup` lui-même (`git pull` dans `/opt`). **Ne touche pas au serveur convergé.**|

Drapeaux notables : `--paranoid` (active la baseline sysctl, D6), `--timezone <tz>` (sinon UTC), `--skip-bin-check`, `--no-overwrite`. Pas de `detect`, pas de `reconcile`.

### 9.2 Étape 0 — gardes bloquantes

1. **EUID 0 requis** pour toute commande mutante (`setup`, `confirm`). Sinon, on refuse net : un convergeur de serveur ne fait pas semblant en non-root. (Décision durcie B.)
2. **Binaires requis** (`requires_bin` du profil) : vérifiés avant d'agir (`command -v`), `--skip-bin-check` pour forcer.

### 9.3 La boucle de convergence

Pour chaque unité du profil (héritage résolu) : **évaluer l'assertion** → si satisfaite, **skip** (idempotence) → sinon, **agir** (déposer le fichier managé avec backup, ou exécuter l'action) → **ré-évaluer** l'assertion pour confirmer. Les fichiers managés sont écrits via `backup.sh` (backup avant écrasement) puis hashés dans `state.yaml`.

### 9.4 La séquence anti-lockout (la pièce maîtresse)

C'est la fonctionnalité qui distingue `server-setup` d'un script de durcissement random. Le drop-in SSH (unité 12) est le seul geste qui peut te verrouiller dehors. Donc, **uniquement sur une mutation SSH réellement restrictive** (D9, décision durcie : pas d'armement si le drop-in est déjà en place et inchangé) :

1. Écrire le drop-in candidat, puis **`sshd -t` sur la config fusionnée** — si la config est invalide, on abandonne avant tout reload.
2. **Self-test loopback** : vérifier qu'une connexion par **clé** sur `127.0.0.1` passe avec la nouvelle config.
3. **Armer le coupe-circuit** : `systemd-run --on-active=10min` qui **restaure** le drop-in précédent et **reload** SSH si `server confirm` n'est pas venu. État passé à `pending-confirmation` dans `state.yaml`.
4. **`systemctl reload ssh`** — **jamais `restart`** (un restart tue les sessions établies ; un reload non).
5. Afficher : _« reconnecte-toi en `deploy` et tape `server confirm` sous 10 min, sinon rollback automatique. »_

`server confirm` annule la minuterie et fige l'état à `confirmed`. **Reboot-edge assumé et documenté** : un reboot pendant la fenêtre perd la minuterie `systemd-run` — d'où la consigne _« confirme avant tout reboot »_ (gotcha du README).

### 9.5 `server doctor`

Relit `state.yaml` et **ré-évalue les mêmes prédicats** que la convergence (`assert.sh` est la source unique : `doctor` et `setup` partagent les assertions — pas de logique dupliquée qui dériverait). Il **rapporte**, ne mute jamais (pas de `--fix` en v1). Contrôles : root off ? password off ? clé OK ? ufw actif + règles ? fail2ban vivant ? unattended actif ? swap ? timezone ? daemon Docker ? réseau `web` ? **+ santé `push-to-deploy`** : conteneur `proxy_caddy` up, listener webhook joignable, réseau `web` présent. Codes de sortie définis (0 = conforme, non-zéro = dérive/manquant) ; `--strict` pour la CI.

### 9.6 Backup & idempotence

Tout fichier système écrasé est sauvegardé avant, horodaté. **Pas d'auto-purge des backups en v1** (décision durcie). Relancer `setup` ne re-joue que les unités dérivées (§4.3).

---

## 10. Contrat de contenu des fichiers / unités clés

### 10.1 `state.yaml` — l'unique trace

```yaml
# Managed by server-setup — do not edit by hand.
# Written by `server setup`; read by `server doctor`.
profile: web
server_setup_version: 0.1.0          # version de l'outil au moment du setup
server_setup_commit: <sha>           # double champ de version (décision durcie)
converged_at: 2026-07-03T09:00:00Z
confirm_state: confirmed             # pending-confirmation | confirmed (anti-lockout)
timezone: Europe/Paris               # fuseau passé à setup (repli UTC si absent)
paranoid: 0                          # 1 si setup --paranoid (repli : dérivé du drop-in sysctl)
files:                               # nature 1 : fichiers managés (comme bootstrap)
  - path: /etc/docker/daemon.json
    sha256: <hash réel sur disque>
    tpl_sha256: <hash du template>
assertions:                          # nature 2 : prédicats re-vérifiables
  - id: ssh-root-disabled
    status: pass
    checked_at: 2026-07-03T09:00:00Z
  - id: web-network-present
    status: pass
    checked_at: 2026-07-03T09:00:00Z
```

Lu par `server doctor`, **jamais édité à la main**. Le double champ version/commit permet de savoir non seulement « quelle version » mais « depuis quel commit exact » la box a été convergée. Les champs `timezone` et `paranoid` mémorisent les réglages passés à `setup` (qui ne se devinent ni par un hash ni par un prédicat) pour que `doctor` ré-évalue avec les **mêmes** valeurs et ne signale pas de fausse dérive ; un vieux `state.yaml` sans ces champs reste lisible (repli : `UTC`, et `paranoid` dérivé du drop-in sysctl).

### 10.2 Drop-in SSH (`99-server-setup.conf`)

`PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `KbdInteractiveAuthentication no`. Déposé en drop-in (`sshd_config.d`), **jamais** en éditant `sshd_config` directement. Validé par `sshd -t` avant tout reload (§9.4).

### 10.3 `daemon.json`

Rotation des logs obligatoire (`log-driver: json-file`, `log-opts` max-size / max-file), pour ne **jamais** revivre le coup des 16 Go qui remplissent le disque et tuent `proxy_caddy`. Valeurs chiffrées figées à l'implémentation.

### 10.4 User `deploy`

Non-root, shell `/bin/bash`, dans le groupe `sudo`, ligne `NOPASSWD` dans `/etc/sudoers.d/` **validée par `visudo -cf`** avant installation (décision durcie : jamais un sudoers cassé qui te bloque). `authorized_keys` semée depuis la clé root entrante. Sur profil `docker`, ajouté au groupe `docker`.

### 10.5 fail2ban, unattended-upgrades, swap, journald, sysctl

Jail `sshd` avec seuils chiffrés (figés à l'implémentation). Unattended-upgrades : MAJ sécurité + **reboot 04:00**. Swap : `/swapfile` **2 Go**, `swappiness 10`. Journald : `SystemMaxUse` plafonné. **Sysctl : drop-in vide par défaut**, peuplé uniquement sous `--paranoid` (D6 — on ne casse pas un réseau par excès de zèle).

### 10.6 `CLAUDE.md`

Squelette en **anglais** (cohérent avec la famille), enrichi par le repo : stack (Bash + systemd), conventions de commit, cibles `make`, et la règle d'or _« server-setup s'arrête où push-to-deploy commence »_.

---

## 11. Contraintes et décisions verrouillées

### 11.1 Cadrage (D1–D15)

|#|Décision|Choix arrêté|
|---|---|---|
|D1|Modèle|**Convergeur d'état désiré** (pas templateur). Pas de `reconcile` ; `setup` reconverge.|
|D2|Verbe principal|**`server setup`**|
|D3|Nommage des profils|Par capacité : **`minimal → docker → web`**|
|D4|Pare-feu par profil|**`minimal` n'ouvre que 22** ; 80/443 arrivent avec `web`|
|D5|Propriétaire du réseau `web`|**`server-setup`** (création idempotente)|
|D6|Niveau de durcissement|Défaut solide + drapeau **`--paranoid`** pour le sysctl|
|D7|Cluster « oubliés »|UTC + `--timezone` · `en_US.UTF-8` · `timesyncd` · swap 2 Go + swappiness 10 · unattended auto-reboot 04:00 · `journald SystemMaxUse` · `known_hosts` GitHub · IPv6 couvert|
|D8|ufw × Docker|Ne pas se battre : **seul Caddy publie 80/443**, le reste reste `internal` ; `ufw-docker` opt-in|
|D9|Self-test anti-lockout|Loopback en clé · `sshd -t` sur config fusionnée · **reload jamais restart**|
|D10|Dead-man's switch|**`systemd-run --on-active=10min`** · état `pending-confirmation` · `server confirm` · reboot-edge assumé/documenté|
|D11|Nom du repo|**`server-setup`** + CLI `server`|
|D12|État|`/var/lib/server-setup/state.yaml` · fichiers (hash) + assertions (prédicats)|
|D13|Exécution|Run en **root** · binaire `/usr/local/bin/server` · clone `/opt/server-setup` · clé : authorize|
|D14|Easter egg du vendredi|**Non bloquant** : simple ligne de commentaire à l'exécution, l'action passe quand même. Le canard te fait un clin d'œil, il ne te barre pas la route.|
|D15|Asymétrie de test|bootstrap s'auto-applique ; `server-setup` ne peut pas durcir son runner CI → dogfooding sur le **vrai VPS de prod** + harnais conteneur pour le non-destructif|

### 11.2 Passe de durcissement (verrouillée)

- **`--profile` obligatoire et explicite**, aucun défaut silencieux ; **suppression de la sous-commande `detect`**.
- **`sudo` NOPASSWD** pour le user **`deploy`**, validé par **`visudo -cf`**.
- **Armement anti-lockout** uniquement sur mutations SSH **réellement restrictives**.
- **EUID 0 requis** pour les mutations.
- **fail2ban / `daemon.json` / cap journald / swap / sysctl** : valeurs numériques concrètes figées à l'implémentation.
- **unattended-upgrades** : reboot **04:00**.
- **Sysctl** : baseline **vide** à `minimal`, tout derrière `--paranoid`.
- **Génération de locale** explicite ; **`known_hosts` GitHub** semé par méthode fixée.
- **Fenêtre de rollback : 10 minutes** via `systemd-run`.
- **Codes de sortie `doctor`** définis ; **double champ de version** dans l'état ; **pas d'auto-purge des backups en v1**.

### 11.3 Récursion d'outillage (nouveau, vs. v1.1)

- **`server-setup` s'auto-applique `bootstrap apply --profile shell`** pour son outillage dev. Le `.bootstrap.yaml` est versionné. On ne câble pas à la main ce que bootstrap dépose (shellcheck, shfmt, bats, markdownlint, gitleaks, lychee, workflows CI, Makefile, dependabot).
- **`yq` interdit en dépendance d'exécution** : parser awk maison pour le sous- ensemble YAML des manifestes, comme bootstrap (zéro dépendance hors base Ubuntu + `git`).

### 11.4 Cibles & accès

- **Ubuntu LTS 22.04 / 24.04** supporté + testé ; Debian non garanti.
- **`push-to-deploy` est public** → clone HTTPS, **zéro credential** côté `server-setup`. Le seul geste connexe est le pré-seed `known_hosts` GitHub (D7), utile pour les pulls SSH des **repos d'app** que le webhook fera plus tard.

---

## 12. Définition de « terminé » (DoD)

### v1 — convergeur `minimal → docker → web`

- [ ] Le repo s'auto-applique `bootstrap --profile shell` (`.bootstrap.yaml` versionné) ; `bats tests/` et la CI bootstrap tournent vert.
- [ ] `install.sh` pose la CLI `server` (`/usr/local/bin/server` → clone `/opt`), idempotent, `--dry-run`.
- [ ] Trois profils (`minimal`, `docker`, `web`) avec héritage, manifeste parsé sans `yq`.
- [ ] `server setup --profile <p>` converge la box, idempotent, écrit `state.yaml` (fichiers + assertions), backup avant écrasement.
- [ ] **Séquence anti-lockout** complète : `sshd -t`, self-test loopback, coupe- circuit `systemd-run` 10 min, `server confirm`, **reload jamais restart**.
- [ ] `server doctor` ré-évalue les assertions (+ santé `push-to-deploy`), codes de sortie, `--strict`.
- [ ] `server update` met à jour l'outil sans toucher au serveur convergé.
- [ ] `--dry-run` sur toutes les commandes mutantes ; EUID 0 requis.
- [ ] **Ligne d'arrivée prouvée** : sur une box convergée en `web`, `push-to-deploy` se clone et `docker compose up -d` démarre **sans aucun geste manuel intermédiaire** (réseau `web` présent, user `deploy`, 80/443 ouverts).
- [ ] Harnais d'acceptation en conteneur (non-destructif) + dogfooding documenté sur le vrai VPS (destructif) — D15.
- [ ] Docs : README (anglais, gotchas reboot-edge + footgun ufw×Docker + fenêtre 10 min), `architecture.md`, une page par profil, ce CDC, diagramme SVG « system overview », cross-link des 4 maillons.
- [ ] Easter egg du vendredi (non bloquant, D14).

---

_Document de conception — v2.0 (régénéré sur bootstrap-web-setup v0.6.0). Toutes les décisions structurantes sont verrouillées (§11). `server-setup` s'arrête où `push-to-deploy` commence — et accessoirement, il ne te verrouillera jamais dehors, même un vendredi._ 🦆
