# Administration

## Inscription des utilisateurs

Par défaut, les inscriptions sont fermées.

Vous pouvez les ouvrir ou les fermer depuis le panneau de configuration de YunoHost :

- Webadmin → Applications → Atuin → Configuration → Inscription

Ce réglage pilote l'option `open_registration` de `server.toml` ; le service Atuin est redémarré automatiquement pour l'appliquer.

### En ligne de commande

Vous pouvez aussi gérer les inscriptions à la main :

Ouvrir les inscriptions :
```
sudo sed -i 's/^open_registration = .*/open_registration = true/' __INSTALL_DIR__/server.toml
sudo yunohost service restart __APP__
```

Fermer les inscriptions :
```
sudo sed -i 's/^open_registration = .*/open_registration = false/' __INSTALL_DIR__/server.toml
sudo yunohost service restart __APP__
```

## Journaux et dépannage

Pour suivre les journaux du service :
```
sudo journalctl -u __APP__ -f -l
```
Les derniers journaux sont aussi disponibles dans la webadmin, sur la [page du service](#/services/__APP__).
