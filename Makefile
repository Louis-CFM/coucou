# Coucou — commandes utiles. `make` ou `make help` liste tout.
#
# Windows / Linux (Tauri, dossier windows/) : dev, build, paquets, installation.
# Mac : xcodegen + xcodebuild (voir CLAUDE.md). Le build Windows se fait sur Windows
# (Git Bash ou MSYS2 pour avoir make) ; le build Linux se fait sur Linux. Pas de cross-compilation.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

WIN := windows
RELEASE := $(WIN)/release
VERSION := $(shell node -p "require('./$(WIN)/src-tauri/tauri.conf.json').version" 2>/dev/null)
ARCH := $(shell uname -m)
DEB_ARCH := $(if $(filter aarch64 arm64,$(ARCH)),arm64,amd64)
APPIMAGE_DIR ?= $(HOME)/.local/bin

# Paquets système nécessaires pour compiler sous Debian / Ubuntu (liste de linux.yml).
LINUX_APT := build-essential pkg-config libwebkit2gtk-4.1-dev libgtk-layer-shell-dev \
	libayatana-appindicator3-dev librsvg2-dev libssl-dev libdbus-1-dev patchelf \
	gstreamer1.0-plugins-base gstreamer1.0-plugins-good

.PHONY: help
help: ## Affiche cette aide
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage : make \033[36m<cible>\033[0m\n"} \
		/^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
		/^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

# ── Garde-fous ────────────────────────────────────────────────────────────────
.PHONY: _need-linux _need-windows _need-node
_need-linux:
	@[ "$$(uname -s)" = "Linux" ] || { echo "Cette cible se lance sous Linux." >&2; exit 1; }
_need-windows:
	@case "$$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) echo "Cette cible se lance sous Windows (Git Bash / MSYS2). Le build ne se cross-compile pas." >&2; exit 1;; esac
_need-node:
	@node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 22 ? 1 : 0)' 2>/dev/null || { echo "Node 22 ou plus est requis (actuel : $$(node -v 2>/dev/null || echo absent))." >&2; exit 1; }

##@ Développement
.PHONY: linux-dev windows-dev dev-web
linux-dev: _need-linux _need-node node_modules ## Lance l'app Linux en développement (rechargement à chaud)
	cd $(WIN) && npm run tauri dev

windows-dev: _need-windows _need-node node_modules ## Lance l'app Windows en développement (rechargement à chaud)
	cd $(WIN) && npm run tauri dev

dev-web: _need-node node_modules ## Sert uniquement le front dans un navigateur (http://localhost:1420)
	cd $(WIN) && npm run dev

node_modules: $(WIN)/node_modules
$(WIN)/node_modules: $(WIN)/package-lock.json
	cd $(WIN) && npm ci
	@touch $@

.PHONY: deps
deps: _need-node ## Installe les dépendances npm
	cd $(WIN) && npm ci

.PHONY: linux-deps
linux-deps: _need-linux ## Installe les paquets système pour compiler (apt, demande sudo)
	@command -v apt-get >/dev/null || { echo "Pas d'apt : voir windows/README.md (section Linux) pour votre distribution." >&2; exit 1; }
	sudo apt-get update
	sudo apt-get install -y $(LINUX_APT)

##@ Vérifications
.PHONY: check test test-web test-rust types clippy watch
check: types test-web test-rust clippy ## Tout ce que la CI vérifie (types, tests, clippy)

types: _need-node node_modules ## Vérification TypeScript
	cd $(WIN) && npx tsc --noEmit

test: test-web test-rust ## Tous les tests (front + Rust)

test-web: _need-node node_modules ## Tests du front. Un seul fichier : make test-web F=tests/diff.test.mjs
	cd $(WIN) && $(if $(F),npm run test:one -- $(F),npm test)

watch: _need-node node_modules ## Relance les tests du front à chaque sauvegarde
	cd $(WIN) && npm run test:watch

test-rust: hook-fast ## Tests Rust (cargo test)
	cd $(WIN) && cargo test --workspace --locked

clippy: hook-fast ## Clippy (avertissements non bloquants)
	cd $(WIN) && cargo clippy --workspace --all-targets --locked

.PHONY: hook hook-fast
hook: _need-node ## Compile le relais coucou-hook en release complet
	cd $(WIN) && node scripts/build-hook.mjs

hook-fast: _need-node ## Compile le relais sans LTO (dev, tests)
	cd $(WIN) && node scripts/build-hook.mjs --fast

##@ Paquets (dans windows/release/)
.PHONY: linux-pack windows-pack
linux-pack: _need-linux _need-node node_modules ## Construit l'AppImage, le .deb et le .rpm
	cd $(WIN) && npm run pack

windows-pack: _need-windows _need-node node_modules ## Construit l'installeur .exe et le .msi
	cd $(WIN) && npm run pack

##@ Installation de l'app
.PHONY: linux-install linux-install-deb linux-install-rpm linux-install-appimage linux-uninstall windows-install
linux-install: _need-linux ## Installe l'app Linux (.deb ou .rpm selon la distribution, sinon AppImage)
	@if command -v apt-get >/dev/null; then $(MAKE) --no-print-directory linux-install-deb; \
	elif command -v dnf >/dev/null || command -v zypper >/dev/null; then $(MAKE) --no-print-directory linux-install-rpm; \
	else $(MAKE) --no-print-directory linux-install-appimage; fi

linux-install-deb: _need-linux ## Installe le .deb (sudo)
	@[ -f "$(RELEASE)/Coucou-Linux-$(VERSION)-$(DEB_ARCH).deb" ] || $(MAKE) --no-print-directory linux-pack
	sudo apt-get install -y "$(abspath $(RELEASE))/Coucou-Linux-$(VERSION)-$(DEB_ARCH).deb"

linux-install-rpm: _need-linux ## Installe le .rpm (sudo, dnf ou zypper)
	@[ -f "$(RELEASE)/Coucou-Linux-$(VERSION)-$(ARCH).rpm" ] || $(MAKE) --no-print-directory linux-pack
	@if command -v dnf >/dev/null; then sudo dnf install -y "$(abspath $(RELEASE))/Coucou-Linux-$(VERSION)-$(ARCH).rpm"; \
	else sudo zypper --no-gpg-checks install -y "$(abspath $(RELEASE))/Coucou-Linux-$(VERSION)-$(ARCH).rpm"; fi

linux-install-appimage: _need-linux ## Installe l'AppImage dans ~/.local/bin/coucou (sans sudo)
	@[ -f "$(RELEASE)/Coucou-Linux-$(ARCH).AppImage" ] || $(MAKE) --no-print-directory linux-pack
	mkdir -p "$(APPIMAGE_DIR)"
	install -m 755 "$(RELEASE)/Coucou-Linux-$(ARCH).AppImage" "$(APPIMAGE_DIR)/coucou"
	@echo "Installé : $(APPIMAGE_DIR)/coucou (assurez-vous que ce dossier est dans votre PATH)"

linux-uninstall: _need-linux ## Désinstalle l'app Linux (.deb, .rpm ou AppImage)
	@if dpkg -s coucou >/dev/null 2>&1; then sudo apt-get remove -y coucou; \
	elif rpm -q coucou >/dev/null 2>&1; then sudo rpm -e coucou; fi
	rm -f "$(APPIMAGE_DIR)/coucou"

windows-install: _need-windows ## Construit si besoin puis lance l'installeur Windows (installation utilisateur)
	@[ -f "$(RELEASE)/Coucou-Windows-setup.exe" ] || $(MAKE) --no-print-directory windows-pack
	"$(RELEASE)/Coucou-Windows-setup.exe"

##@ Mac
.PHONY: mac mac-test
mac: ## Compile l'app Mac (xcodegen + xcodebuild)
	cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build

mac-test: ## Tests Swift (filtre : make mac-test F=voice)
	scripts/test.sh $(F)

##@ Nettoyage
.PHONY: clean clean-all
clean: ## Supprime dist/ et les paquets (windows/release/)
	rm -rf $(WIN)/dist $(RELEASE)

clean-all: clean ## Supprime aussi node_modules et target/ (plusieurs Go)
	rm -rf $(WIN)/node_modules $(WIN)/target
