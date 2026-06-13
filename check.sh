#!/usr/bin/env bash
# Surveille la page YC Startup School et notifie via ntfy (push iPhone + Apple Watch).
# Pensé pour tourner dans GitHub Actions (toujours en ligne, indépendant du Mac).
# L'état est persisté dans ci-state/ et committé par le workflow entre deux passages.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${YC_URL:-https://events.ycombinator.com/startup-school-2026}"
STATE="${STATE_DIR:-$DIR/ci-state}"
mkdir -p "$STATE"

: "${NTFY_TOPIC:?NTFY_TOPIC manquant (secret GitHub)}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"

ts()  { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(ts) $*"; }

# notify "<titre ASCII>" "<corps>" "<priorité>" "<tags>"  -> renvoie 0 si l'envoi a réussi
notify() {
  curl -fsS --max-time 20 \
    -H "Title: $1" \
    -H "Priority: ${3:-default}" \
    -H "Tags: ${4:-}" \
    -H "Click: $URL" \
    -d "$2" \
    "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null
}

# Cookie de session YC (secret GitHub YC_COOKIE) -> sans lui, le planning reste invisible.
COOKIE_ARG=()
[ -n "${YC_COOKIE:-}" ] && COOKIE_ARG=(--cookie "$YC_COOKIE")

# Récupérer la page, avec quelques tentatives (réseau parfois lent à répondre).
raw=""
for _ in 1 2 3; do
  raw=$(curl -s -L --max-time 30 \
    -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
    "${COOKIE_ARG[@]+"${COOKIE_ARG[@]}"}" "$URL" 2>/dev/null)
  [ -n "$raw" ] && break
  sleep 5
done

content=$(printf '%s' "$raw" | python3 "$DIR/extract.py")
if [ -z "$content" ]; then
  log "WARN: contenu vide (réseau ou page inaccessible) — on réessaiera au prochain passage"
  exit 0
fi

# Connecté ? (current_user non nul = session valide ; sinon le planning n'apparaît pas)
logged_in="non"
printf '%s' "$content" | grep -q -E '"current_user":\s*\{' && logged_in="oui"

newhash=$(printf '%s' "$content" | shasum -a 256 | cut -d' ' -f1)
HASHFILE="$STATE/last.hash"; PARTYFILE="$STATE/last.party"; LOGINFILE="$STATE/last.login"

# Vrais liens d'after-party (plateformes d'évènement)
party_links=$(printf '%s' "$content" \
  | grep -o -E 'https?://[^"\\]+' \
  | grep -i -E 'lu\.ma|luma|partiful|eventbrite|posh\.vip|ra\.co|dice\.fm' \
  | sort -u | head -10 || true)

# Nb de placeholders "coming soon to this page" restants (2 aujourd'hui : Day 1 + Day 2)
placeholders=$(printf '%s' "$content" | grep -o -i 'coming soon to this page' | wc -l | tr -d ' ')
party_sig="links=$(printf '%s' "$party_links" | tr '\n' '|');ph=$placeholders"

save_state() {
  printf '%s' "$newhash"   > "$HASHFILE"
  printf '%s' "$party_sig" > "$PARTYFILE"
  printf '%s' "$logged_in" > "$LOGINFILE"
}

# Première exécution : baseline + ping de confirmation (sans alerte de changement)
if [ ! -f "$HASHFILE" ]; then
  save_state
  notify "YC monitor actif" \
    "Surveillance démarrée (connecté=$logged_in, $placeholders «coming soon» restants). Tu seras prévenu dès que les after-parties sortent." \
    min "white_check_mark" || log "WARN: ntfy de démarrage non envoyée"
  log "baseline (hash ${newhash:0:12}, connecté=$logged_in, ph=$placeholders)"
  exit 0
fi

oldhash=$(cat "$HASHFILE")
oldparty=$(cat "$PARTYFILE" 2>/dev/null || true)
oldlogin=$(cat "$LOGINFILE" 2>/dev/null || echo "oui")
old_ph=$(printf '%s' "$oldparty" | sed -n 's/.*;ph=//p'); old_ph=${old_ph:-0}

# On ne sauvegarde l'état QUE si la notif est bien partie ; sinon on retentera au prochain passage.

# --- Cas 1 : session expirée (on était connecté, on ne l'est plus) ---
if [ "$logged_in" = "non" ] && [ "$oldlogin" = "oui" ]; then
  if notify "Cookie YC expire" \
       "Le planning n'est plus visible. Reconnecte-toi sur YC et mets à jour le secret YC_COOKIE du dépôt." \
       high "warning"; then
    save_state; log "COOKIE EXPIRÉ -> ntfy envoyé"
  else
    log "COOKIE EXPIRÉ mais ntfy échouée (retry au prochain passage)"
  fi

# --- Cas 2 : after-parties publiées (placeholder retiré OU vrais liens apparus), si connecté ---
elif [ "$logged_in" = "oui" ] && [ "$party_sig" != "$oldparty" ] \
     && { [ -n "$party_links" ] || [ "$placeholders" -lt "$old_ph" ]; }; then
  body="Le «coming soon» a bougé ($old_ph→$placeholders)."
  [ -n "$party_links" ] && body="$body Liens: $party_links"
  if notify "After-parties YC dispo !" "$body" urgent "tada,partying_face"; then
    save_state; log "AFTER-PARTY -> ntfy envoyé (ph $old_ph→$placeholders)"
  else
    log "AFTER-PARTY mais ntfy échouée (retry)"
  fi

# --- Cas 3 : la page a changé pour autre chose (intervenant, FAQ, planning détaillé…) ---
elif [ "$newhash" != "$oldhash" ]; then
  if notify "Page YC modifiee" \
       "La page Startup School a changé (connecté=$logged_in). Vérifie les after-parties." \
       default "bell"; then
    save_state; log "CHANGEMENT -> ntfy envoyé (${oldhash:0:8}→${newhash:0:8})"
  else
    log "CHANGEMENT mais ntfy échouée (retry)"
  fi

else
  log "pas de changement (connecté=$logged_in, ph=$placeholders)"
fi
