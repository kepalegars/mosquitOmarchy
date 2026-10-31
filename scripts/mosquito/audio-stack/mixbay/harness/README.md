# mixbay-reverse — harness de reverse engineering USB

Harnais réel pour capturer, différencier, étiqueter et rejouer le trafic USB
d'une carte audio. Il ne devine rien : il capture ce que le vendeur (ou le
firmware) envoie, puis rejoue **uniquement les octets observés**.

## Pourquoi usbmon

`usbmon` est le moniteur USB du noyau Linux. Il voit les transferts de contrôle,
bulk et interrupt, y compris quand la carte est passée à une VM Windows : c'est
la méthode utilisée par `douze` pour le SSL 12 et par `open-apollo` pour
l'Apollo USB.

Le harnais lit l'API texte (`/sys/kernel/debug/usb/usbmon/<bus>u`) : elle donne
le setup packet complet et les données, sans dépendre de `tshark`/`tcpdump`.
La capture nécessite root ; le replay utilise `pyusb` et les droits udev.

## Installation

```bash
./setup-mosquitomixbay.sh -y --no-kmod
```

Le binaire est déployé dans `~/.local/bin/mixbay-reverse`.

Dépendances :

- Python 3.10+ ;
- `pyusb` pour le replay (`python-pyusb` / `python3-usb`) ;
- `usbmon` (module noyau) pour la capture ;
- debugfs monté (le script tente `modprobe usbmon` et `mount -t debugfs`).

## Flux guidé

```bash
mixbay-reverse list
mixbay-reverse capture --guided --name "PreSonus Quantum ES 4" --match "Quantum ES"
```

1. **Découverte des canaux** (lecture seule) : carte ALSA/PipeWire, profil
   actif, nombre de canaux playback/capture, sinks et sources.
2. **Puis un step par contrôle** : `gain:input1`, `mute:input1`,
   `volume:output1`, etc. Chaque step capture une baseline silencieuse, puis
   **une seule** action. On peut passer (`s`) ou arrêter (`q`).
3. **Diff** : transferts nouveaux ou payload changée ; le polling identique
   est ignoré.
4. **Sauvegarde** dans `~/.config/mosquitomixbay/reverse/<carte>/<timestamp>/`.
5. **Résumé final** et confirmation, puis retour à Mixbay.

Le mode non guidé reste disponible pour capturer un seul contrôle :

```bash
mixbay-reverse capture --name "…" --label gain:input1
```

Si l'application constructeur n'existe que sous Windows, lancez-la dans une VM
Windows avec passthrough USB. L'hôte voit quand même le trafic via usbmon.

## Replay

```bash
mixbay-reverse show gain:input1
mixbay-reverse replay --label gain:input1 --dry-run
mixbay-reverse replay --label gain:input1 --yes
mixbay-reverse replay --label gain:input1 --verify
```

- Le replay reprend la fenêtre entre le premier et le dernier transfert
  candidat, **dans l'ordre capturé**, y compris les GET/acks intermédiaires
  (indispensable pour les séquences read-modify-write).
- `--dry-run` affiche tout sans envoyer.
- Sans `--yes`, il faut taper `REPLAY`.
- `--verify` compare les lectures IN aux valeurs capturées.
- `--detach` détache le driver kernel pour les endpoints bulk/interrupt ;
  à utiliser seulement si nécessaire.

**Sécurité :** baissez les monitors avant tout replay. Une séquence capturée
est réelle, mais elle peut correspondre à une action dangereuse si vous avez
capturé autre chose que le contrôle visé.

## Ce que le harnais fait / ne fait pas

Fait :

- résolution de la carte par nom, VID:PID, bus/dev ;
- capture texte usbmon filtrée par bus + devnum ;
- fusion submission/callback par URB ID ;
- diff baseline/action (nouveau transfert, payload changée) ;
- stockage JSONL + capture lisible + map des labels ;
- replay contrôle/bulk/interrupt, dry-run, confirmation, vérification IN.

Ne fait pas (encore) :

- capture HID multi-octets avec reconstruction de rapports fragmentés ;
- replay de séquences qui nécessitent un timing très précis (le harnais
  conserve l'ordre et un délai max de 50 ms, pas le timestamp exact) ;
- détection automatique du contrôle à partir du diff (l'utilisateur labelise) ;
- promotion automatique d'une carte beta en natif (le mapping `Spec` reste
  manuel, après validation) ;
- support des cartes Thunderbolt (usbmon ne voit pas le PCIe).

## Tests

```bash
python3 -m unittest discover -s harness/tests -v
```

Les tests couvrent le parsing usbmon (control IN/OUT, bulk OUT, interrupt IN),
le diff, la fenêtre de replay et le stockage. Aucun matériel requis.

## Intégration TUI

- **Settings → Reverse engineering harness (usbmon)** lance le harnais sans
  carte présélectionnée.
- Sur une carte beta : **Restart reverse engineering** lance le harnais avec le
  nom de la carte.
- Après la capture, la TUI affiche un toast ; `mixbay-reverse sessions` liste
  les labels.

Le harnais tourne dans le terminal via `tea.ExecProcess`, donc les prompts sudo
et les questions guidées restent utilisables.
