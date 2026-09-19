#!/bin/bash
# Fix le prompt "default keyring" qui apparait au demarrage des apps
# Crée un login.keyring vide (pas de mot de passe) et nettoie les doublons

echo "=== Fix keyring ==="

# 1. Pointer default vers login
echo "login" > ~/.local/share/keyrings/default

# 2. Créer le login keyring s'il n'existe pas
if [ ! -f ~/.local/share/keyrings/login.keyring ]; then
  echo "Création du login keyring..."
  echo "fix" | secret-tool store --application=gnome-keyring --no-lock "dummy" "keyring-init"
  echo "login keyring créé."
else
  echo "login keyring existe déjà."
fi

# 3. Supprimer les doublons Default_keyring*
rm -f ~/.local/share/keyrings/Default_keyring*.keyring
rm -f ~/.local/share/keyrings/Default_Keyring*.keyring

echo "Nettoyage terminé."
echo "Redémarre le shell : omarchy restart shell"
