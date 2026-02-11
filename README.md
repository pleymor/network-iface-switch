# 🚀 Gestionnaire de Priorité Réseau (IPv4)

Cet utilitaire PowerShell permet de forcer Windows à utiliser une interface réseau spécifique (ex: **Ethernet**) au lieu d'une autre (ex: **Wi-Fi**) en modifiant les métriques d'interface.

---

## 🛠️ Prérequis de Configuration

Pour que le forçage soit efficace à 100%, suivez ces trois étapes :

### 1. Désactivation de l'IPv6
Windows donne souvent la priorité à l'IPv6 sur l'IPv4. Si votre Wi-Fi est en IPv6, il pourrait ignorer vos réglages.
* Ouvrez les **Connexions Réseau** (via le bouton dans l'application ou en tapant `ncpa.cpl` dans Windows).
* Faites un clic-droit sur votre carte **Wi-Fi** > **Propriétés**.
* DÉCOCHEZ la case **Protocole Internet version 6 (TCP/IPv6)**.
* Cliquez sur **OK**.



### 2. Création du Raccourci
Pour éviter les erreurs d'accès et masquer la fenêtre console :
1.  Faites un clic-droit sur le bureau > **Nouveau** > **Raccourci**.
2.  Entrez la cible suivante (adaptez le chemin si nécessaire) :
    ```powershell
    powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "CHOIX_RESEAU.ps1"
    ```
3.  Nommez-le **"Gestionnaire Réseau"**.

### 3. Droits Administrateur (Obligatoire)
1.  Clic-droit sur votre nouveau raccourci > **Propriétés**.
2.  Dans l'onglet **Raccourci**, cliquez sur le bouton **Avancé**.
3.  Cochez la case **Exécuter en tant qu'administrateur**.
4.  Validez par **OK**.

---

## 📖 Mode d'emploi

1.  **Lancer l'application** via le raccourci créé.
2.  **Sélectionner** l'interface souhaitée dans la liste du haut (ex: *Ethernet 3*).
3.  Cliquer sur **FORCER LA PRIORITÉ**.
    * L'interface choisie passera en **Métrique 10** (Priorité haute).
    * Les autres interfaces repasseront en **Métrique Automatique** (Priorité basse).
4.  **Vérifier** dans le cadre "Diagnostic" que la métrique totale de votre choix est la plus petite.



## 📝 Notes Techniques
* **Métrique IP** : C'est le "poids" d'une connexion. Plus le chiffre est **bas**, plus la connexion est **prioritaire**.
* **Compatibilité** : Ce script cible uniquement l'IPv4 pour garantir une stabilité maximale sur Windows 10/11.