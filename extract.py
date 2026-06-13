#!/usr/bin/env python3
"""Extrait le contenu utile de la page YC (bloc data-page React),
en supprimant les jetons qui changent à chaque chargement, afin que
seul un vrai changement de contenu modifie le résultat."""
import sys, re, html

data = sys.stdin.read()

# Le vrai contenu de la page est dans l'attribut data-page="...".
m = re.search(r'data-page="(.*?)"', data, re.S)
blob = html.unescape(m.group(1)) if m else data

# --- Supprimer le bruit (jetons rotatifs qui changent à chaque requête) ---
# UUID du composant React, regénéré à chaque requête
blob = re.sub(r'react-component-[0-9a-fA-F-]{36}', 'react-component-X', blob)
# jetons csrf / authenticity / nonce / session
blob = re.sub(
    r'(authenticity_token|csrf[_-]?token|nonce|session[_-]?id)["\']?\s*[:=]\s*["\']?[A-Za-z0-9_\-+/=]{12,}',
    r'\1=X', blob)
# "version":"<hash de déploiement>" — change à chaque déploiement YC, pas un vrai changement de contenu
blob = re.sub(r'"version":"[0-9a-fA-F]{16,}"', '"version":"X"', blob)
# join_token / rsvp tokens propres à la session connectée (rotatifs)
blob = re.sub(r'"(join_token|rsvp_token|auth_token)":"[^"]+"', r'"\1":"X"', blob)

sys.stdout.write(blob)
