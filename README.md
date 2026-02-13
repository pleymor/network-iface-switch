# Gestionnaire de Priorite Reseau (IPv4)

Utilitaire PowerShell pour forcer Windows a utiliser une interface reseau specifique (ex: **Wi-Fi** au lieu d'**Ethernet**) en modifiant les metriques d'interface et de route.

---

## Prerequis

### 1. Droits Administrateur (Obligatoire)
Le script doit etre execute en tant qu'administrateur. Il demandera automatiquement l'elevation si necessaire.

### 2. Creation du Raccourci
1. Clic-droit sur le bureau > **Nouveau** > **Raccourci**.
2. Entrez la cible suivante (adaptez le chemin si necessaire) :
    ```
    powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "CHOIX_RESEAU.ps1"
    ```
3. Nommez-le **"Gestionnaire Reseau"**.
4. Clic-droit sur le raccourci > **Proprietes** > **Avance** > cochez **Executer en tant qu'administrateur**.

---

## Mode d'emploi

### Forcer la priorite
1. Lancer l'application via le raccourci.
2. Selectionner l'interface souhaitee dans la liste (ex: *Wi-Fi*).
3. Cliquer sur **FORCER LA PRIORITE**.
   - L'interface choisie : metrique d'interface **10** + metrique de route **0** = total **10**
   - Les autres interfaces : metrique d'interface **1000** + metrique de route **1000** = total **2000**
4. Verifier dans le cadre diagnostic que la metrique totale de votre choix est la plus petite.

### Reset des priorites
Cliquer sur **RESET PRIORITES** pour remettre toutes les interfaces en metrique automatique et les metriques de route a 0. Le script `RESET_RESEAU.ps1` fait la meme chose en standalone.

### IPv6
Une checkbox permet d'activer/desactiver l'IPv6 par interface. Desactiver l'IPv6 peut aider a forcer la priorite car Windows utilise parfois l'IPv6 pour router le trafic, contournant les metriques IPv4. Cliquer sur le bouton **(i)** dans l'application pour plus de details.

### Test de l'interface prioritaire
Le bouton **Tester l'interface prioritaire** effectue un ping vers 8.8.8.8 et affiche quelle interface est reellement utilisee pour le routage. Utile car sur Windows 11, l'icone du system tray affiche toujours Ethernet tant qu'un cable est branche, meme si le Wi-Fi est prioritaire.

---

## Notes techniques
- **Metrique IP** : plus le chiffre est **bas**, plus la connexion est **prioritaire**.
- **Metrique totale** = metrique d'interface + metrique de route. Les deux sont modifiees par le script.
- **Compatibilite** : Windows 10/11, IPv4 uniquement.
- **Icone Windows 11** : l'icone du system tray ne reflete pas le routage reel. C'est un comportement normal.
