#!/usr/bin/env bash
# Surveille la page YC Startup School et notifie via ntfy (push iPhone + Apple Watch).
# Pensé pour tourner dans GitHub Actions (toujours en ligne, indépendant du Mac).
# L'état est persisté dans ci-state/ et committé par le workflow entre deux passages.
#
# Détection (post-refonte du site, juillet 2026) :
#   - PRIMAIRE : apparition/changement de VRAIS liens d'inscription externes
#     (luma, partiful, eventbrite, meetup, posh.vip, dice.fm, splashthat, hopin,
#      zeffy, tickettailor, ra.co) -> alerte URGENTE. C'est LE signal fiable.
#   - SECONDAIRE : le contenu "after part(y|ies)" s'étoffe (nb d'occurrences en
#     hausse vs référence) -> alerte HIGH (peut sonner si YC reformule le texte).
#   - Le vieux marqueur "coming soon to this page" a disparu de la refonte : on ne
#     l'utilise plus (il causait une fausse alerte).
#   - Changement générique de la page -> ping MIN (silencieux, juste pour info).
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

HASHFILE="$STATE/last.hash"
LOGINFILE="$STATE/last.login"
LINKSFILE="$STATE/last.links"
AFTERFILE="$STATE/last.after"

# --- Signal PRIMAIRE : liens d'inscription vers une plateforme d'évènement externe ---
# (http(s):// exigé pour éviter les faux positifs sur des sous-chaînes)
party_links=$(printf '%s' "$content" \
  | grep -o -E 'https?://[^"\\ ]+' \
  | grep -i -E 'lu\.ma|luma\.com|partiful|eventbrite|posh\.vip|//ra\.co|dice\.fm|meetup\.com|splashthat|hopin\.com|zeffy|tickettailor' \
  | sort -u | head -12 || true)
links_now=$(printf '%s' "$party_links")

# --- Signal SECONDAIRE : quantité de contenu "after part(y|ies)" sur la page ---
after_now=$(printf '%s' "$content" | grep -o -i -E 'after[ -]?part(y|ies)' | wc -l | tr -d ' ')

save_state() {
  printf '%s' "$newhash"   > "$HASHFILE"
  printf '%s' "$logged_in" > "$LOGINFILE"
  printf '%s' "$links_now"  > "$LINKSFILE"
  printf '%s' "$after_now"  > "$AFTERFILE"
}

# --- Baseline / migration : si le nouveau format d'état n'existe pas encore, on
#     enregistre la référence d'aujourd'hui SANS alerter (évite tout faux positif au
#     redéploiement), et on envoie un ping min de confirmation. ---
if [ ! -f "$LINKSFILE" ]; then
  save_state
  nlinks=$(printf '%s' "$links_now" | grep -c . || true)
  notify "YC monitor actif (v2)" \
    "Détection recalibrée après la refonte YC. Référence: connecté=$logged_in, liens d'event=$nlinks, mentions after-party=$after_now. Tu seras prévenu dès que de vrais liens d'inscription (luma, partiful...) ou du contenu after-party apparaissent." \
    min "white_check_mark" || log "WARN: ntfy de démarrage non envoyée"
  log "baseline v2 (hash ${newhash:0:12}, connecté=$logged_in, liens=$nlinks, after=$after_now)"
  exit 0
fi

oldhash=$(cat "$HASHFILE" 2>/dev/null || true)
oldlogin=$(cat "$LOGINFILE" 2>/dev/null || echo "oui")
old_links=$(cat "$LINKSFILE" 2>/dev/null || true)
old_after=$(cat "$AFTERFILE" 2>/dev/null || echo 0); old_after=${old_after:-0}

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

# --- Cas 2 : de vrais liens d'inscription externes sont apparus / ont changé (URGENT) ---
elif [ -n "$links_now" ] && [ "$links_now" != "$old_links" ]; then
  body="Des liens d'inscription sont apparus sur la page YC : $(printf '%s' "$links_now" | tr '\n' ' ')"
  if notify "After-parties YC dispo !" "$body" urgent "tada,partying_face"; then
    save_state; log "AFTER-PARTY (liens) -> ntfy envoyé"
  else
    log "AFTER-PARTY (liens) mais ntfy échouée (retry)"
  fi

# --- Cas 3 : le contenu after-party s'est étoffé (mots-clés en hausse) (HIGH) ---
elif [ "$after_now" -gt "$old_after" ]; then
  if notify "After-parties YC : ca bouge" \
       "Le contenu 'after party' s'est étoffé sur la page ($old_after -> $after_now mentions). Va vérifier s'il y a des liens d'inscription." \
       high "eyes"; then
    save_state; log "AFTER-PARTY (mots-clés $old_after->$after_now) -> ntfy envoyé"
  else
    log "AFTER-PARTY (mots-clés) mais ntfy échouée (retry)"
  fi

# --- Cas 4 : la page a changé pour autre chose (silencieux, priorité min) ---
elif [ "$newhash" != "$oldhash" ]; then
  if notify "Page YC modifiee" \
       "La page Startup School a changé (connecté=$logged_in, mentions after-party=$after_now). Rien de décisif détecté." \
       min "bell"; then
    save_state; log "CHANGEMENT (min) -> ntfy envoyé (${oldhash:0:8}->${newhash:0:8})"
  else
    log "CHANGEMENT mais ntfy échouée (retry)"
  fi

else
  log "pas de changement (connecté=$logged_in, liens=$(printf '%s' "$links_now" | grep -c . || true), after=$after_now)"
fi
