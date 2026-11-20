/**
 * ============================================================================
 *  Move for Bitwig by Pikub — Ableton Move → Bitwig Studio  (v5.11)
 * ============================================================================
 *  Installation :
 *    Documents/Bitwig Studio/Controller Scripts/Ableton Move/AbletonMove.control.js
 *  Bitwig > Settings > Controllers > Add Controller > Ableton > Move for Bitwig (by Pikub)
 *
 *  Ce script reproduit dans Bitwig les fonctions du « Control Live Mode » de la
 *  Move (chapitre 18 du manuel Move), plus le séquenceur 32 pas de la v1.
 *
 *  ── ORGANISATION DU PROJET (à lire avant de modifier) ──────────────────────
 *   Documents      NEXT_SESSION.md = état du projet, méthode, bugs, todos (point d'entrée) ;
 *                  CHANGELOG.md = historique ; cet en-tête = référence des gestes.
 *   Un seul fichier, pas de load(). Sections : 1 matériel · 2 paramètres · 3 état · 4 init ·
 *                  5 MIDI entrant · 6 modes · 7 pads (mémoires, morph) · 8 pas (8b Capture) ·
 *                  9 pistes, navigateur · 10 encodeurs, molette, vues · 11 Note Input ·
 *                  12 LED (flush) · 13 utilitaires · 14 mode chords / scale.
 *   Version        une seule vérité : la ligne 3 de ce fichier et defineController (même numéro).
 *                  +0.01 à chaque envoi sur le Mac ; l'ancienne version va dans sauvegardes/ en
 *                  .js.bak. Aucun autre fichier du dossier Bitwig ne doit finir par .control.js
 *                  (Bitwig les charge tous).
 *   Statut         chaque fonction est : EXPÉRIMENTALE (on cherche, peut disparaître) →
 *                  À VALIDER (codée, pas encore testée sur la Move) → VALIDÉE (testée, on n'y
 *                  touche plus sans raison). Le statut de chaque fonction est dans NEXT_SESSION.md.
 *   Règles         ne jamais remplacer ce qui est validé : ajouter un repli vérifié ; un échec
 *                  affiche un message ; toute valeur lue est déclarée (markInterested) ;
 *                  avant envoi : node --check, tests/simulateur.js, tests/simulateur_strict.js.
 *
 *  ── CAPTURE DES MOUVEMENTS DE POTARDS (EXPÉRIMENTAL, v5.06 — DÉSACTIVÉ : AUTO_CAPTURE_ENABLED)
 *   Clip qui joue + potards du device tournés, AUCUN pad joué, puis Capture : le script rejoue
 *   les mouvements du dernier tour de boucle pendant un tour, écriture d'automation du lanceur
 *   activée → Bitwig les grave dans le clip. Piste et device épinglés, piste armée pendant la
 *   gravure (même si l'on change de piste). Encodeurs du device seulement (pas volume / sends).
 *   Undo = annule (Bitwig). Avec des notes jouées, Capture grave les notes seulement.
 *
 *  ── TABLE DE CORRESPONDANCE  Move/Live  →  Bitwig ─────────────────────────
 *
 *  CAPTURE
 *   Capture (lecture)        clip qui commence à la mesure de la 1re note jouée, longueur
 *                            exacte en mesures, lancé tout de suite en phase ; appui
 *                            jusqu'à 1 temps après la barre = on visait la barre
 *   Capture (machine arrêtée) tempo détecté et réglé, clip créé et lancé depuis le début
 *   Delete + Capture / Shift + Capture   vide la mémoire Capture (Undo et Delete la vident aussi)
 *
 *  TRANSPORT
 *   Play                     lecture / arrêt           transport.play()/stop()
 *   Play                     lecture depuis le début (toujours) / stop ; vert en lecture
 *   Shift + Play             lecture depuis la position actuelle
 *   Record                   clip vide -> enregistre un clip ; clip qui joue -> overdub ;
 *                            pendant l'enregistrement -> arrête et lit le clip
 *   Shift + Record           enregistrement arrangeur  transport.record()
 *   Undo / Shift + Undo      annuler / rétablir        application.undo()/redo()
 *                            juste après une Capture : Undo annule toute la capture d'un coup
 *   Capture                  crée un clip avec ce que tu viens de jouer aux pads (intégré au
 *                            script, LED allumée quand il y a quelque chose à capturer)
 *   Shift + Capture          vide la mémoire Capture (vidée aussi à chaque changement de piste)
 *                            Si le clip sélectionné boucle : overdub — les notes du dernier
 *                            tour sont ajoutées DANS ce clip, à leur place (pas de nouveau clip)
 *                            Sinon : nouveau clip dans le prochain slot vide, lancé aussitôt
 *
 *  Double appui sur un bouton de piste (groupe) : déplie / replie le groupe
 *  MODES (bouton Note/Session)
 *   Note/Session             bascule Note ⇄ Session (en Session : au relâchement).
 *                            Tenu + bouton de piste = Stop de la piste (entré depuis Note :
 *                            retour en Note au relâchement ; en Session : on y reste)
 *   Shift + bouton de piste  (Shift tenu : boutons = FX 1-3 + Master) MODE SEND : potards,
 *                            devices et mode Preset sur la FX / le Master, clavier sur la piste
 *                            armée ; au relâchement de Shift, les boutons reviennent sur les
 *                            pistes ; un bouton de piste = retour normal sur cette piste.
 *   Shift + Note/Session     MODE SEND verrouillé : boutons bloqués sur FX / Master (sélection
 *                            clignotante), mode Preset sur la FX / le Master, toniques à la
 *                            couleur de la piste jouée (séquenceur et Capture coupés).
 *                            Shift tenu + piste : sélectionne la piste (elle reste sélectionnée ;
 *                            au relâchement de Shift, boutons sur FX / Master). Sortie : Shift + Note/Session
 *   Boutons de piste         muette = éteinte ; solo = clignote, les autres éteintes
 *   Shift + Pas 8            (ajout) mode « 32 pas » de la v1 (pads = pas)
 *
 *  MODE NOTE  (gestes repris du manuel de la Move)
 *   Pads                     jouent l'instrument / le Drum Machine de la piste (NoteInput)
 *     • Drum (auto si Drum Machine) : 4x4 gauche = pads 1-16, 4x4 droite = pads 17-32
 *     • Instrument : grille en quartes, In-Key ou chromatique
 *   Pad (batterie)           joue le son et le choisit pour le séquenceur (rien dans Bitwig)
 *   Shift + pad              sans son : choisit le son pour le séquenceur ET sélectionne le pad
 *                            et son device dans Bitwig (encodeurs)
 *   16 boutons de pas        séquenceur de la note sélectionnée (dernier pad joué)
 *   Appui sur un pas plein   efface (drum : le pad sélectionné ; instrument : tout le pas)
 *   Pas maintenu + pad       ajoute/retire cette note (plusieurs pads = accord)
 *   Pas maintenu + Volume    vélocité        | + molette : longueur (10 % de pas / cran)
 *   Pas maintenu + Gauche/Droite  déplace la note d'un pas (un pas = la grille, Shift + Pas 3)
 *   Pas maintenu + + / -     transposition (Shift : octave)
 *   Pas maintenu + encodeurs vélocité, longueur, probabilité, répétitions,
 *                            micro-transposition, pan, gain, timbre (en plus de la Move)
 *   Mute + pas               rend muette la note du pas (ajout)
 *   Copy + pas, relâcher Copy, puis pas de destination   copie un pas
 *   Copy + pas début + pas fin, relâcher, destination     copie une plage
 *   Copy (à nouveau)         annule la copie en attente
 *   Copy (seul)              duplique le clip sélectionné dans le prochain slot VIDE
 *   Delete (seul)            supprime le clip qui joue (sinon le clip sélectionné)
 *   Shift + Delete           vide toutes les notes du clip (Undo pour annuler)
 *   Delete + pas             efface le pas | Delete + pad : toutes les notes de ce pad
 *   Mute (seul)              coupe / réactive la piste sélectionnée
 *   Shift + Mute             solo / unsolo de la piste sélectionnée
 *   Double appui Mute        retire tous les mutes | Shift + double appui : tous les solos
 *   Mute + pad (drum)        mute du pad (LED blanc atténué)
 *   Shift + Gauche / Droite  mesure / page de pas précédente / suivante (Gauche / Droite seuls = devices)
 *   + / -                    piste précédente / suivante dans le bloc des 4 boutons ; au bord
 *                            du bloc, le bloc se décale d'une piste ; au bout : « Dernière piste »
 *                            (pas de passage vers les pistes FX)
 *   Shift + + / -            octave (instrument) ou banque de 16 pads (drum)
 *   Retour visuel            les pads s'allument en vert quand la note joue
 *   Couleurs                 pads, pas, pistes et clips reprennent les couleurs Bitwig
 *
 *  VUE LOOP (bouton Loop, comme sur la Move)
 *   Loop (seul)              entre / sort de la vue Loop : chaque pas = une mesure
 *                            vert = dans la boucle, blanc = mesure affichée
 *   Appui sur une mesure     l'affiche | double appui : boucle d'une mesure
 *   Mesure début + mesure fin  définit la boucle
 *   Loop maintenu + molette  longueur de boucle (Shift : au pas près)
 *   (vue Loop : aucune édition de notes ; seul Delete + mesure efface la mesure)
 *   Delete + mesure          efface les notes de la mesure
 *   Copy + Loop, Shift + Pas 15   double la boucle (Shift + Loop n'est plus utilisé pour ça)
 *
 *  PISTES (4 boutons de piste)
 *   Bouton de piste          sélectionne la piste ; ×2 sur un groupe = déplie / replie (rien d'autre)
 *                            MODE NOTE : la piste choisie depuis la Move devient la seule armée
 *                            (réglage ARM_FOLLOWS_SELECTION)
 *                            MODE SESSION : aucun armement automatique (celui que Bitwig fait en
 *                            changeant de piste est annulé) ; l'armement voulu est gardé : Sample,
 *                            Record, Shift + Pas 14, souris dans Bitwig, autre contrôleur
 *   Mute + piste             mute          | Shift + Mute + piste : solo (clignote)
 *   Note/Session + piste     arrête les clips de la piste (Note et Session)
 *   Delete + piste           supprime la piste | Copy + piste : duplique
 *   Piste maintenue          Volume = volume, encodeurs 1-7 = sends 1-7, encodeur 8 = pan
 *                            (pistes FX et Master : volume + pan seulement)
 *   En mode Session          un bouton de piste sélectionne la piste et revient en mode Note
 *
 *  MODE SESSION (vue horizontale, comme la Move et le lanceur horizontal de Bitwig)
 *   Grille 4 x 8             rangée = piste (haut = bouton de piste 1), colonne = scène
 *   Pad                      sélectionne le clip (blanc) et le lance ; clip en lecture = vert,
 *                            pulsation douce (1 toutes les 2 temps)
 *   Pad vide                 piste armée (à la main) = enregistre ; pas armée = arrête la piste
 *   Record                   slot vide sélectionné : enregistre un nouveau clip
 *   Shift + pad              sélectionne le clip sans le lancer
 *   Delete + pad             supprime le clip
 *   Copy + pad, puis pad     copie le clip vers le pad de destination (Copy à nouveau : annule)
 *   Mute + pad               mute de la piste
 *   Pas 1-8                  lancent les scènes visibles
 *   Pas 16 (rouge)           stop de tous les clips (Stop d'une piste : Note/Session + piste)
 *   Gauche/Droite            scènes (8 par page, Shift : 1)  | + / - : pistes
 *
 *  ENCODEURS / MOLETTE
 *   Encodeurs 1-8            8 Remote Controls du device sélectionné (Shift = fin)
 *   Toucher un potard        affiche ce qu'il règle et sa valeur (encodeurs, Volume, molette) ;
 *                            ● = ce paramètre a de l'automation
 *   Delete + toucher un potard   efface l'automation de ce paramètre
 *   Undo                     si un clip jouait avant l'action annulée, il reprend à sa place
 *   Shift + Undo             rend la main à l'automation si elle a été reprise à la main ; sinon Redo
 *   LEDs sous les encodeurs  rouge = automation ; rouge clignotant = automation reprise à la main
 *
 *  MÉMOIRES DE MACROS (par device, enregistrées dans le projet)
 *   Shift + pad (moitié droite, 16 mémoires) : 1er appui = mémorise l'état complet du
 *                            device (tous ses paramètres) ; ensuite = rappel
 *                            (mémoires liées au nom de piste + nom du device : on peut déplacer
 *                            pistes et devices ; une piste renommée retrouve ses mémoires)
 *   Copy + Shift + pad, puis Shift + pad   copie une mémoire | Copy à nouveau : annule
 *   Delete + Shift + pad     efface la mémoire
 *   mode Preset : les pas n'éditent QUE les presets (pas de notes) : appui court = dernier
 *                 preset utilisé (2e appui = retiré) ; Delete + pas = retire
 *   [EXPÉRIMENTAL] mode Preset : pas maintenu + pad preset = le preset est rappelé quand la lecture passe
 *                 sur ce pas (pas violets) ; Delete + pas = retire. Le dernier device où l'on
 *                 pose des presets de pas reste « épinglé » : il les rejoue même désélectionné
 *   mode Preset : Shift + pad preset = morph de l'état actuel vers ce preset : la pression
 *                 du pad dose (léger = état actuel, fort = preset) ; relâcher Shift = valeur
 *                 figée ; sans Shift = rappel direct
 *   mode Preset : pad preset A tenu + pad B = morph de A vers B (pression du pad B), en plus
 *   mode Preset : pendant un morph, toucher le potard Volume = il prend la main (les pads
 *                 peuvent être lâchés) ; tourner = de A vers B ; lâcher le potard = figé
 *   mode Preset : pad blanc = preset en cours (s'éteint si un paramètre est modifié à la main)
 *   mode Preset + Capture    enregistre l'automation des presets / morphs dans le clip (clignote) ;
 *                            Capture à nouveau = arrêt
 *                 pendant le morph, toucher un 3e pad : nouveau morph depuis l'état actuel (ex. 50 %)
 *   Double appui sur Shift   MODE PRESET : mémoires sur la moitié droite sans tenir Shift ; la
 *                            moitié gauche joue normalement. Copy/Delete + pad marchent aussi.
 *                            La molette change de page de macros (on reste sur le device).
 *                            Shift + molette = device suivant / précédent.
 *                            Un clic court sur Shift = sortie du mode (Shift tenu = Shift normal).
 *                            Presets vides : pads à peine allumés (repère en Drum Machine).
 *   LEDs avec Shift          mémoire pleine = couleur de piste, vide = atténuée
 *   Volume                   volume Master (piste maintenue / pad maintenu : leur volume)
 *   Molette                  pages de macros (Remote Controls) du device ; Shift + molette = device suivant/précédent
 *   Gauche / Droite          device précédent / suivant ; Shift + Gauche / Droite = pages de pas
 *                            (le panneau du bas ne s'ouvre/ferme qu'avec Shift + Back)
 *   SOUS-DEVICES
 *   Clic molette             entre dans le device : Drum Machine -> chaîne du pad sélectionné
 *                            (Shift + pad pour le choisir), Layer/Selector -> couche courante,
 *                            autres conteneurs -> 1re chaîne (FX, Note FX…) ;
 *                            plugin (VST/CLAP) -> ouvre / ferme sa fenêtre
 *   Device sélectionné       toujours rendu visible : panneau Devices ouvert, device déplié,
 *                            Remote Controls affichés, défilement jusqu'à lui
 *   Mute + clic molette      couche suivante d'un Layer / Selector
 *   Back                     ramène toujours à la vue Devices (aussi depuis la vue Loop) ;
 *                            double Back = resynchronise le panneau si le script s'est trompé ;
 *                            si les Devices sont déjà affichés :
 *                            remonte au device parent (ou quitte un menu molette)
 *   Shift + Back             seul moyen de masquer le panneau du bas (et de le rouvrir)
 *   Loop                     vue Loop : l'éditeur de notes apparaît tout seul en bas ;
 *                            Loop à nouveau ou Back = on sort et on revient à l'écran précédent
 *   Vue Loop : mesure de début de boucle maintenue + molette = décale le début de 1/16
 *   Vue Loop : mesure maintenue + Shift + molette = point de lecture (play start), même
 *              hors de la boucle : 1/16 par cran depuis sa position actuelle (pas bleu)
 *   Vue Loop : Copy + mesure (ou mesure de début + de fin), puis mesure de destination =
 *              copie les notes (remplace) ; Copy à nouveau = annule
 *   Vue Loop : l'éditeur est cadré sur la boucle (à l'entrée, à chaque changement, clic molette)
 *   Vue Loop : Loop maintenu + molette = décale la fin de 1/16 ; Shift + molette = zoom ;
 *              la molette ne navigue plus dans les devices
 *   Shift + Loop             affiche / masque l'éditeur de notes (panneau du bas)
 *   Shift + Loop ×2          active / désactive la boucle du clip (dans toutes les vues)
 *   Vue Loop aussi en mode Session : Shift + pad = choisit le clip sans le lancer
 *   Vue Loop : s'ouvre sur le clip en lecture de la piste (sinon le clip sélectionné, sinon
 *              le 1er) ; suit le changement de piste ; Shift + pas n'y déclenche aucune fonction
 *   Shift + clic molette     active / désactive le device (bypass)
 *   Delete + clic molette    supprime le device ; la main passe au device voisin ; dernier
 *                            device d'une couche : la couche vide est supprimée (Undo pour annuler)
 *   Delete + Shift + clic    supprime la couche courante d'un Layer / Selector
 *   Drum : choisir un son    les encodeurs suivent : le 1er device du pad est sélectionné
 *   Entrer dans un pad / FX  (sélection du son ou clic molette) : le device est sélectionné
 *                            et affiché dans le panneau Devices
 *   Back (sortie d'un pad / d'une chaîne)   remonte au conteneur, replie l'élément quitté
 *                            et ferme sa fenêtre de plugin (AUTO_FOLD, en test)
 *   Entrée dans un pad / FX  déplie le conteneur et le device sélectionné (AUTO_FOLD)
 *
 *  SHIFT + BOUTONS DE PAS (réglages, comme sur la Move)
 *   (un mode molette choisi par Shift + Pas 3/5/7/9 passe avant la vue Loop et mode Preset)
 *   Shift + Pas 3            molette = grille (1/64, 1/32, 1/16T, 1/16, 1/8T, 1/8, 1/4),
 *                            Shift + molette = force du Quantize ; Back pour revenir aux devices
 *   Shift + Pas 5            Tempo à la molette (Shift = 0,1 BPM) ; 2e appui = molette rendue aux devices
 *   Icônes sous les pas      Shift tenu : fonctions disponibles ; sinon allumées quand la fonction
 *                            est active (5 tempo, 6 métronome, 9 chords / scale, 10 vélocité pleine)
 *   Shift + Pas 6            métronome on/off
 *   Shift + Pas 7            Groove (shuffle) à la molette
 *   Shift + Pas 9            MODE CHORDS / SCALE (expérimental) :
 *                            pas 1-7 = fondamentale (pas 8 tenu = dièse), 9-15 = modes I-VII,
 *                            16 = mode perso (tenu + molette) ; molette = tonique, Shift + molette = gamme.
 *                            Shift mémorise le dernier accord joué ; Shift + pad droit vide = l'enregistre
 *                            (couleur du mode), Shift + pad plein = le rejoue et remet son mode ;
 *                            Delete + pad = efface ; double Shift = presets verrouillés (pas tenu +
 *                            preset = écrit l'accord). La gamme de Bitwig suit via deux contrôles du
 *                            projet à créer dans chaque set : « Root Key » et « Scale »
 *   Shift + Pas 10           vélocité pleine on/off
 *   Shift + Pas 14 (« new ») arrête le clip en cours et se place sur le prochain slot vide,
 *                            piste armée, prêt à enregistrer ou à écrire
 *   Slot vide                horloge sur les pas (temps 1 = pas 1-4, temps 2 = pas 5-8…) ;
 *                            la 1re note posée crée un clip d'1 mesure lancé aussitôt (synchronisé),
 *                            les notes posées entre-temps sont gardées et écrites dedans
 *   Shift + Pas 15           double la boucle (raccourci natif Move)
 *   Shift + Pas 16           quantifie le clip au relâchement ; en le gardant appuyé :
 *                            Shift + molette = force du Quantize, molette seule = grille
 *
 *  NOUVELLE PISTE / NOUVEAU DEVICE
 *   Shift + Pas 1            nouvelle piste MIDI juste après la piste sélectionnée,
 *                            puis le navigateur s'ouvre pour choisir l'instrument
 *   Shift + Pas 1 (double)   nouvelle piste audio, sans navigateur
 *   Shift + Pas 1 (bloc FX)  nouvelle piste d'effet (retour), sélectionnée, navigateur ouvert
 *   Shift + Pas 2            navigateur : nouveau device après le device sélectionné
 *                            (en fin de chaîne s'il n'y en a pas)
 *   Shift + Pas 4            presets du device sélectionné : molette = presets (avec Live Preview,
 *                            on les entend), clic molette = charger, Back = Catégorie puis fermer
 *   Shift + Pas 11 (« Arp ») effet de note AVANT l'instrument de la piste
 *   Shift + Pas 11 (double)  effet de note au DÉBUT de la couche / du pad du conteneur sélectionné
 *                            (Shift + Pas 2 double : fin de la couche — instrument ou effet,
 *                            Bitwig propose le type selon l'emplacement)
 *   Shift + Pas 2 (double)   DANS le conteneur : pad choisi du Drum Machine ; Layer / Selector :
 *                            NOUVELLE couche (copie de la couche courante, instrument remplacé
 *                            via le navigateur) ; sinon : comme l'appui simple
 *   Shift + molette          sur un Layer / Selector (Note FX, Instrument, FX) : choisir la couche ;
 *                            DANS une couche : couche suivante du même conteneur ; sinon device
 *   Shift + Pas 2 ×2 dans une couche : nouvelle couche dans le conteneur
 *   Shift + Pas 2 ×2 sur une Chain (FX, Note FX, Instrument) : device au bout de sa chaîne ;
 *                    une fois dedans, Shift + Pas 2 = après le device sélectionné
 *   Dans le navigateur       démarre dans Catégorie (provisoire). Colonnes : Type (icônes à gauche,
 *                            expérimental : Back depuis Catégorie) › Catégorie ›
 *                            Résultats. Molette = défile dans la colonne active (Shift : 10 par 10),
 *                            clic molette = colonne suivante puis valider, Back = colonne
 *                            précédente puis fermer, pads = écouter.
 *                            Shift + clic molette : colonne du milieu suivante (Catégorie, Créateur,
 *                            Tag, Emplacement, Fichier). Plug-ins : Créateur (marques) par défaut.
 *                            Souris : cliquer un élément dans une colonne (Catégorie, Créateur, Tags,
 *                            Emplacement…, Résultats, type) la rend active pour la molette.
 *                            Pas = colonne : 2 Emplacement, 4 Catégorie, 5 Créateur, 7 Tags,
 *                            8 Résultats (blanc = active) ; 16 = Favoris on / off (jaune = actif)
 *                            Les encodeurs restent sur les contrôles du device.
 *
 *  AJOUTS SANS ÉQUIVALENT LIVE
 *   Sample                   armer/désarmer la piste sélectionnée
 *
 *  NON REPRIS (pas d'équivalent dans l'API Bitwig ou dans Live)
 *   Écran OLED de la Move (protocole non documenté) → notifications Bitwig à la place
 *   Mode Slicing, Session Overview, Capture natif, Repeat / arpégiateur (les Note FX de
 *   Bitwig le font : Shift + Pas 11).
 *
 *  ⚠️ NUMÉROS MIDI : marqués [doc] = documentés par le projet communautaire
 *     move-anything ; [supposé] = à confirmer. Laisse DEBUG = true et regarde la
 *     console du script (Settings > Controllers > Show Script Console).
 * ============================================================================
 */

loadAPI(19); // Bitwig Studio 5.1+ / 6.x (19 : automation des paramètres — LEDs rouges, Delete + toucher)
host.setShouldFailOnDeprecatedUse(false);
var CHORDS_ERROR = null;   // mode chords / scale : code intégré plus bas (section « MODE CHORDS / SCALE »)
function chordsReady() { return !CHORDS_ERROR && typeof toggleScaleMode === "function"; }

host.defineController(
   "Ableton",
   "Move for Bitwig",
   "5.11",
   "b7e3c1a4-5d2f-4e8b-9a6c-3f1d2e7a8b90",
   "Pikub"
);
host.defineMidiPorts(1, 1);
// host.addDeviceNameBasedDiscoveryPair(["Nom du port IN"], ["Nom du port OUT"]);


// ============================================================================
//  1. CONFIGURATION MATÉRIELLE
// ============================================================================

var DEBUG = false;            // log des messages MIDI entrants

// --- Réveil (handshake) intégré — remplace l'utilitaire externe ----------------
// Protocole documenté par le projet movewire (github.com/auridevil/movewire).
// Le script fait lui-même ce que fait Live : demande d'identité, passage en mode
// « control surface », réveil de l'écran, puis renvoi régulier des LEDs.
// ⚠️ Live doit être FERMÉ : il occupe les ports et fait son propre handshake.
var HANDSHAKE = {
   ENABLED: true,
   KEEPALIVE_MS: 250,                       // battement de cœur toutes les 0,25 s : la Move semble
                                            // attendre un flux régulier (comme l'horloge MIDI), sinon
                                            // elle a des ratés
   KEEPALIVE_FULL: false,                   // true = renvoyer TOUTES les LEDs à chaque battement
                                            // (ancienne méthode : ~75 messages d'un coup, la Move
                                            //  avait un raté toutes les 2 s)
   IDENTITY_REQUEST: "F07E7F0601F7",        // requête d'identité MIDI universelle
   CONTROL_MODE:     "F000211D01014600F7",  // cmd 0x46, 0 = mode contrôleur
   STANDALONE_MODE:  "F000211D01014601F7",  // cmd 0x46, 1 = retour en standalone
   WAKE_DISPLAY:     "F000211D0101087F7FF7",// cmd 0x08 (127, 127)
   POLY_AFTERTOUCH:  "F000211D01011E01F7",  // cmd 0x1E, 1
   IDENTITY_REPLY_MARK: "00211d5832"        // présent dans la réponse d'une Move
};
var LIST_ACTIONS = false;    // true = liste les ID d'actions Bitwig dans la console (pour Capture)
var CAPTURE_ACTION_ID = null; // si défini : Capture déclenche cette action Bitwig au lieu du Capture intégré

// --- Capture intégré (comme sur la Move) -------------------------------------
// Le script mémorise en permanence ce que tu joues aux pads (mode Note), même sans
// enregistrer. Capture crée un clip dans un slot vide avec ces notes et le lance.
var CAPTURE = {
   MAX_BARS: 8,          // longueur maximale capturée (mesures)
   RESOLUTION: 0.0625,   // précision de placement des notes, en temps (1/64 de ronde)
   MAX_EVENTS: 1024,     // taille de la mémoire tampon
   LATE_TOLERANCE: 1,    // appui jusqu'à 1 temps après une barre = on visait la barre
   PHRASE_GAP_MS: 2000,  // machine arrêtée : un silence plus long = nouvelle phrase
   PHRASE_GAP_BARS: 2,   // en lecture : silence de plus de 2 mesures = nouvelle phrase
   EARLY_TOLERANCE: 0.25, // note jusqu'à 1/4 de temps avant la barre = sur le temps 1
   PICKUP: 1,            // notes jusqu'à 1 temps avant la barre = levée, placée en fin de boucle
   END_WEIGHT: 0.4       // poids de l'appui sur Capture (= fin de la boucle) dans la détection du tempo
};

var HW = {
   CHANNEL: 0,

   // Notes
   PAD_FIRST_NOTE: 68,   // [doc] 68..99, de bas-gauche à haut-droite
   STEP_FIRST_NOTE: 16,  // [doc] 16..31, boutons de pas 1..16
   CC_STEP_ICON_FIRST: 16, // [doc move-anything] LEDs des icônes sous les pas, CC 16..31
   TOUCH_FIRST_NOTE: 0,  // [doc movewire] toucher des encodeurs 1-8 = notes 0-7, Volume = 8, molette = 9

   // CC des boutons (127 = appui, 0 = relâché)
   CC_SHIFT: 49,         // [doc]
   CC_NOTE_SESSION: 50,  // [doc] nommé « Menu » dans move-anything
   CC_BACK: 51,          // [doc]
   CC_CAPTURE: 52,       // [doc]
   CC_DOWN: 54,          // [doc]
   CC_UP: 55,            // [doc]
   CC_UNDO: 56,          // [doc]
   CC_LOOP: 58,          // [doc]
   CC_COPY: 60,          // [doc]
   CC_LEFT: 62,          // [doc]
   CC_RIGHT: 63,         // [doc]
   CC_PLAY: 85,          // [doc]
   CC_RECORD: 86,        // [doc]
   CC_MUTE: 88,          // [doc]
   CC_SAMPLE: 118,       // [doc] (« Record audio »)
   CC_DELETE: 119,       // [doc]
   CC_TRACKS: [43, 42, 41, 40], // [doc 40-43 / ordre supposé] du HAUT vers le BAS

   // Encodeurs (relatifs : 1..63 = +, 65..127 = -)
   CC_ENCODER_FIRST: 71, // [doc] 71..78
   CC_VOLUME: 79,        // [doc]
   CC_WHEEL: 14,         // [doc]
   CC_WHEEL_CLICK: 3     // [doc]
};

// Index de palette des LEDs (vélocité du Note On renvoyé).
// Index connus (movewire) : 0 off, 120 blanc, 122 gris clair, 123 gris foncé,
// 125 bleu, 126 vert, 127 rouge, 1 rouge vif, 8 vert vif.
var COLOR = {
   OFF: 0,
   WHITE: 120,
   LIGHT: 122,
   DIM: 123,
   MEM_EMPTY: 124,    // pad preset vide (mode Preset) : à peine allumé, sur toutes les pistes
   BLUE: 125,
   GREEN: 126,
   RED: 127,
   // usages
   STEP_PRESET: 23,   // pas portant un preset (mode Preset) : violet
   NOTE: 125, PLAYHEAD: 120, PLAYHEAD_ON_NOTE: 126, BEAT: 123, LOOP: 126,
   DRUM: 123, DRUM_SELECTED: 125, DRUM_MUTED: 124, PLAYING_PAD: 126,
   ROOT: 125, IN_SCALE: 122,
   CLIP: 123, CLIP_PLAYING: 126, CLIP_QUEUED: 122, CLIP_RECORDING: 127,
   TRACK: 123, TRACK_SELECTED: 120, TRACK_PLAYING: 126,
   SETTING: 123, SETTING_ON: 120
};
var BTN = { OFF: 0, DIM: 123, ON: 120 }; // LEDs des boutons (index de palette) : gris foncé / blanc

// Palette RVB des 128 couleurs de la Move (index -> 0xRRGGBB), extraite par movewire
// (Move/colors.pyc). Sert à retrouver la couleur Move la plus proche d'une couleur Bitwig.
var MOVE_PALETTE = [0,16728114,8389632,13188096,11280128,9195544,4790276,16440379,16762134,11992846,7995160,3457558,5212676,6487893,2719059,2530930,3255807,3564540,1717503,1838310,1391001,3749887,5710591,9907199,8724856,16715826,16722900,10892321,10049064,8873728,9470495,4884224,32530,1594290,6441901,7551591,16301231,16751478,16760671,14266225,16774272,12565097,12373128,11468697,8183199,9024637,8451071,8048380,6857171,8753090,12298994,13482980,15698864,8756620,7042414,8687771,6975605,8947101,7105141,10323356,7629428,10263941,7632234,10323076,7694954,6691092,2164742,4588288,2621440,6100736,2100480,4656128,1837056,3877652,1839882,2428421,853506,6576151,2104327,6704648,2169090,4744709,1515777,3171849,991491,1330440,399618,2045697,659712,2582050,794891,1326633,530704,19766,6158,1262950,398881,1386340,461856,660582,198177,722012,196893,662604,264990,1447526,460577,2231654,721953,3936614,1246497,3476784,1115151,6686228,2163206,6689108,2163995,0,5855577,1710618,16777215,5855577,13421772,4210752,1315860,255,65280,16711680];
var LOOP_OFF_COLOR = 0;   // Loop hors vue Loop : éteint (0) ; index de palette sinon (56 ≈ 45 %, 121 ≈ 35 %)
var FLASHY_SAT = 1.6;      // renfort de saturation des couleurs de piste / clip (1 = couleurs d'origine)
var DIM_FACTOR = 0.25;   // luminosité des versions « atténuées » (pads non sélectionnés…)
var colorCache = {};

/** Couleur Bitwig (ColorValue) -> index de palette Move le plus proche. */
function moveColor(colorValue, dim, level) {
   var f = (dim ? DIM_FACTOR : 1) * (level === undefined ? 1 : level);
   var r0 = colorValue.red(), g0 = colorValue.green(), b0 = colorValue.blue();
   // Jamais de blanc : pas de couleur ou un gris -> couleur de repli (orange), pour que la
   // piste et sa tonique en mode Note soient toujours colorées
   var mx0 = Math.max(r0, g0, b0), mn0 = Math.min(r0, g0, b0);
   if (mx0 <= 0 || (mx0 - mn0) / mx0 < 0.08) { r0 = 1; g0 = 0.42; b0 = 0; }
   // Couleurs plus « flashy » : saturation renforcée et luminosité au maximum avant de
   // chercher la couleur la plus proche dans la palette de la Move.
   var mx = Math.max(r0, g0, b0), mn = Math.min(r0, g0, b0), sat = mx > 0 ? (mx - mn) / mx : 0;
   var boost = sat > 0.08 ? Math.min(1, sat * FLASHY_SAT + 0.25) / sat : 1;   // gris : on ne colore pas
   function chan(c) { var v = mx - (mx - c) * boost; return Math.max(0, Math.min(1, v / mx)); }
   var r = Math.round(chan(r0) * 255 * f), g = Math.round(chan(g0) * 255 * f), b = Math.round(chan(b0) * 255 * f);
   var key = r + "," + g + "," + b;
   if (colorCache[key] !== undefined) return colorCache[key];
   var best = 0, bd = Infinity;
   for (var i = 1; i < MOVE_PALETTE.length; i++) {
      var c = MOVE_PALETTE[i];
      if (c === 0) continue;
      var dr = r - (c >> 16), dg = g - ((c >> 8) & 255), db = b - (c & 255);
      var d = dr * dr + dg * dg + db * db;
      if (d < bd) { bd = d; best = i; }
   }
   colorCache[key] = best;
   return best;
}


// ============================================================================
//  2. PARAMÈTRES
// ============================================================================

var GRID_SIZES = [0.0625, 0.125, 1 / 6, 0.25, 1 / 3, 0.5, 1]; // en temps
var GRID_NAMES = ["1/64", "1/32", "1/16T", "1/16", "1/8T", "1/8", "1/4"];
var DEFAULT_VELOCITY = 100;
var ARM_FOLLOWS_SELECTION = true; // piste choisie DEPUIS LA MOVE = seule piste armée (Record)
var ARM_BANK_SIZE = 128;          // nombre de pistes surveillées pour le désarmement
var q16 = { held: false, used: false };   // Shift + Pas 16 maintenu (réglages Quantize / grille)
var QUANTIZE_AMOUNT = 1.0;     // force du Quantize (Shift + Pas 16), réglable avec Shift + Pas 3 puis Shift + molette

var SCALES = [
   { name: "Majeure",           iv: [0, 2, 4, 5, 7, 9, 11] },
   { name: "Mineure",           iv: [0, 2, 3, 5, 7, 8, 10] },
   { name: "Dorien",            iv: [0, 2, 3, 5, 7, 9, 10] },
   { name: "Mixolydien",        iv: [0, 2, 4, 5, 7, 9, 10] },
   { name: "Phrygien",          iv: [0, 1, 3, 5, 7, 8, 10] },
   { name: "Lydien",            iv: [0, 2, 4, 6, 7, 9, 11] },
   { name: "Mineure harmonique",iv: [0, 2, 3, 5, 7, 8, 11] },
   { name: "Penta mineure",     iv: [0, 3, 5, 7, 10] },
   { name: "Penta majeure",     iv: [0, 2, 4, 7, 9] },
   { name: "Locrien",           iv: [0, 1, 3, 5, 6, 8, 10] }
];
var NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

var MODE = { NOTE: "Note", SESSION: "Session", STEP32: "32 pas" };
var WHEEL = { DEVICE: "device", TEMPO: "tempo", GROOVE: "groove", SCALE: "scale", WORKFLOW: "workflow" };


// ============================================================================
//  3. ÉTAT
// ============================================================================

var S = {
   mode: MODE.NOTE,
   wheelMode: WHEEL.DEVICE,
   shift: false, mute: false, del: false, copy: false, copyUsed: false, loop: false, loopUsed: false,
   muteUsed: false, delUsed: false,
   loopMode: false,     // vue Loop (bouton Loop) : les pas = mesures
   loopHeldBar: -1, loopTap: { x: -1, t: 0 },
   clipboard: null,     // { a, b } plage de pas copiée (Copy)
   copySel: -1, copyCancel: false,
   slotClipboard: null, // clip copié en Session (Copy + pad source)
   sessionSel: null,    // slot sélectionné en Session

   heldSteps: {},       // x -> { created, edited }
   heldPads: {},        // index pad -> hauteur
   heldTrack: -1,       // bouton de piste maintenu (0..3)
   heldSessionTrack: -1,// piste maintenue via pas impair (session)
   copySource: -1,

   isDrum: false,
   drumBase: 36,
   octave: 1,           // instrument : 1 -> C1 (36)
   root: 0, scaleIndex: 0, inKey: true,
   selectedPitch: 36,
   fullVelocity: false,
   gridIndex: 3,        // 1/16

   page16: 0, page32: 0,
   playing16: -1, playing32: -1,

   isPlaying: false, isRecording: false, isOverdub: false, isMetronome: false
};

var data16 = [], data32 = [];  // [hauteur][pas] : 0 vide | 1 suite | 2 début de note
var ledCache = {};
var equalsCache = [];          // BooleanValue « piste t == piste sélectionnée » (banque Session)
var equals4 = [];              // idem pour la banque des 4 boutons de piste
var captureClip;               // clip à grille fine utilisé pour écrire la capture
var captureNotes = [];         // { pitch, vel, start, end } en temps
var captureHeld = {};          // index de pad -> note en cours
var lastPos = { beats: 0, t: 0 }; // dernière position du transport observée
var clipPlay = { step: -1, t: 0 };  // tête de lecture du clip sélectionné (pas de capture)
var capData = {};              // notes existantes du clip sélectionné (grille fine) : "x,y" -> état
var lastCapture = null;        // dernière capture, pour Undo : { type, notes:[{x,y}], slot }
var cursorLayer, layerFirstDevice, drumPadFirstDevice = [];  // navigation dans les sous-devices
var drumDevice;                // premier instrument de la piste (Drum Machine)
var armBank, armEquals = [];   // toutes les pistes, pour armer seulement la piste choisie
// Armement en Session : jamais AUTOMATIQUE. « Automatique » = l'armement qui arrive juste après un
// changement de piste (Bitwig arme la piste sélectionnée). Tout le reste est gardé : Move (Sample,
// Record, Shift + Pas 14), souris dans Bitwig, autre contrôleur (APC…).
var ARM_AUTO_WINDOW = 600;                 // ms autour du changement de piste
var armUserT = 0, selChangeT = 0, manualArm = [], armPendingT = [];
function armByUser() { armUserT = new Date().getTime(); }
function refuseAutoArm(t) {
   if (isAutoRepTrack(t)) return;                      // piste en cours de gravure : reste armée
   if (S.mode === MODE.SESSION && !manualArm[t] && armBank.getItemAt(t).arm().get()) armBank.getItemAt(t).arm().set(false);
}
function onArmChange(t, v) {
   var now = new Date().getTime();
   if (!v) { manualArm[t] = false; armPendingT[t] = 0; return; }
   if (now - armUserT < 400) { manualArm[t] = true; return; }             // demandé depuis la Move
   if (now - selChangeT < ARM_AUTO_WINDOW) { refuseAutoArm(t); return; }  // suit un changement de piste
   // Pas de changement de piste connu : souris ou autre contrôleur, sauf si le changement de piste
   // arrive juste après (l'ordre des deux messages de Bitwig n'est pas garanti).
   armPendingT[t] = now;
   host.scheduleTask(function () {
      if (armPendingT[t] !== now) return;                                 // traité entre-temps
      armPendingT[t] = 0;
      if (armBank.getItemAt(t).arm().get()) manualArm[t] = true;          // armement voulu : on le garde
   }, ARM_AUTO_WINDOW + 100);
}
/** Changement de piste : les armements tout juste arrivés étaient automatiques. */
function onSelectionChangeForArm() {
   selChangeT = new Date().getTime();
   for (var t = 0; t < ARM_BANK_SIZE; t++) {
      if (armPendingT[t] && selChangeT - armPendingT[t] < ARM_AUTO_WINDOW) { armPendingT[t] = 0; refuseAutoArm(t); }
   }
}
/** Entrée en Session : on désarme les pistes armées automatiquement (pas celles armées à la main). */
function disarmAutoInSession() {
   for (var t = 0; t < ARM_BANK_SIZE; t++) {
      var tr = armBank.getItemAt(t);
      if (tr.exists().get() && tr.arm().get() && !manualArm[t] && !isAutoRepTrack(t)) tr.arm().set(false);
   }
}
var memSetting, memStore = {};  // mémoires de macros : { clé device : { slot : { page, v:[8] } } }
var memClipboard = null;        // mémoire copiée (Copy + Shift + pad)
var memCopyHold = false, memClipIdx = -1;   // (Perf) n° du preset copié : Copy + pad puis pas = ce preset sur le pas        // la copie a été faite pendant l'appui en cours sur Copy
var atSeen = false;   // 1er aftertouch reçu (diagnostic)
var shiftDownT = 0, shiftJustLocked = false, SHIFT_CLICK_MS = 300;  // Perf : clic court sur Shift = sortie
// Preset en cours (Perf) : le pad du dernier preset rappelé brille ; il s'éteint dès qu'un
// paramètre du device est modifié à la main (souris, potard…).
var activePreset = { key: "", m: -1, t: 0 };
function setActivePreset(m) { activePreset = { key: memKey(), m: m, t: new Date().getTime() }; host.requestFlush(); }
function checkActivePreset(id, v) {
   if (activePreset.m < 0 || morph) return;
   if (new Date().getTime() - activePreset.t < 400) return;          // ce sont nos propres réglages
   var mem = (memStore[activePreset.key] || {})[activePreset.m];
   if (!mem || !mem.direct || !(id in mem.direct)) return;
   if (Math.abs(mem.direct[id] - v) > 0.002) { activePreset.m = -1; host.requestFlush(); }
}
var memLock = false, lastShiftTap = 0; // double appui sur Shift : mémoires verrouillées sur la moitié droite
var MEM_PAGES = 16, memPages = []; // vues indépendantes des pages de macros (lecture/écriture de toutes les pages)
var NUM_SENDS = 7;             // sends pilotés par les encodeurs 2 à 8 (piste maintenue)
var fxBank, equalsFx = [], trackDevBanks = [];     // bloc FX + Master
var nsPress = null;            // Note/Session tenu (sans Shift) : { from, used } — + piste = Stop
/** Mode Send : la FX ou le Master est sélectionné (encodeurs, devices, mode Preset), les boutons
 *  de piste restent sur FX / Master (sélection clignotante), la dernière piste jouée reste armée
 *  et garde le clavier (toniques à sa couleur). */
var fxCtl = null;
var unlockHold = false;         // Shift + Note/Session vient de quitter le Send verrouillé (Shift encore tenu)
/** Boutons de piste sur FX 1-3 + Master : vue FX, mode Send, ou Shift tenu (en mode Send,
 *  Shift tenu montre au contraire les pistes de base). Figé tant qu'un bouton de piste est tenu. */
function fxBtn() {
   if (S.heldTrack >= 0 && S.heldFx !== undefined) return S.heldFx;
   if (unlockHold) return false;                      // Send déverrouillé : pistes jusqu'au relâchement de Shift
   if (fxCtl && fxCtl.latchHold) return true;       // verrouillage : Shift encore tenu
   if (fxCtl && fxCtl.momentary) return S.shift && !S.mute;   // Shift + FX : Send, boutons sur les pistes (Shift : FX)
   var sh = S.shift && !S.mute;
   return sh ? !fxCtl : !!fxCtl;
}
/** Shift + bouton FX / Master : entrée en mode Send (la piste jouée garde le clavier). */
function enterSend(track, momentary) {
   if (!fxCtl) fxCtl = { since: new Date().getTime(), color: snapColor(cursorTrack.color()), momentary: momentary };
   else if (!momentary) fxCtl.momentary = false;
   if (!momentary && S.shift) fxCtl.latchHold = true;  // boutons sur FX / Master jusqu'au relâchement de Shift
   if (S.mode === MODE.SESSION && momentary) fxCtl.fromSession = true;   // (lock : pads du dernier instrument)
   fxCtl.ch = track;
   selectChannelAny(track);
   updateNoteInput(); host.requestFlush();
   popup("Mode Send — potards sur " + track.name().get() + ", clavier sur la piste jouée" +
         (fxCtl.momentary ? " (bouton de piste : retour)" : " (Shift + Note/Session : sortie)"));
}
/** Sélectionne une piste ; le Master se sélectionne aussi dans Bitwig (le curseur seul n'y va pas). */
function selectChannelAny(ch) {
   if (ch === masterTrack) {
      try { masterTrack.selectInMixer(); } catch (e1) {}
      try { masterTrack.selectInEditor(); } catch (e2) {}
   }
   cursorTrack.selectChannel(ch);
}
/** Shift + Note/Session : mode Send verrouillé (boutons bloqués sur FX / Master). */
function latchSend() {
   if (fxCtl) { fxCtl.momentary = false; fxCtl.fromSession = false; fxCtl.latchHold = true; popup("Mode Send verrouillé — " + cursorTrack.name().get()); host.requestFlush(); return; }
   for (var f = 0; f < 3; f++) if (fxBank.getItemAt(f).exists().get()) { enterSend(fxBank.getItemAt(f), false); return; }
   enterSend(masterTrack, false);
}
/** La piste sélectionnée est une FX / le Master ? */
function cursorOnFx() { for (var f = 0; f < 4; f++) if (equalsFx[f].get()) return true; return false; }
/** FX / Master choisi en Session puis retour en Note : pads éteints et muets. */
function padsOff() { return !!fxCtl && !!fxCtl.fromSession; }
/** Mode Send verrouillé : la Session montre les clips des pistes FX. */
function fxGrid() { return !!fxCtl && !fxCtl.momentary; }
/** Mode Send, boutons sur les pistes : bref flash (~120 ms) toutes les secondes. */
function sendFlashOn() { return (new Date().getTime() % 1000) < 70; }   // flash simple
var flashTimerOn = false;
function flashTick() {
   if (!sendFlashWanted()) { flashTimerOn = false; return; }
   host.requestFlush();
   host.scheduleTask(flashTick, 30);
}
/** Flash seulement en mode Send ouvert par Shift (pas en Send verrouillé, même Shift tenu). */
function sendFlashWanted() { return !!fxCtl && fxCtl.momentary && !fxBtn(); }
function startFlashTimer() { if (!flashTimerOn) { flashTimerOn = true; host.scheduleTask(flashTick, 30); } }
/** Un bouton de piste en solo parmi les 4 affichés ? */
function anyButtonSolo() {
   for (var t = 0; t < 4; t++) {
      if (fxBtn() && t === 3) continue;
      var ch = channelForButton(t);
      if (ch.exists().get() && ch.solo().get()) return true;
   }
   return false;
}
/** Couleur de la piste jouée (figée en mode Send, sinon piste sélectionnée). */
function playColor() { return fxCtl && fxCtl.color ? fxCtl.color : cursorTrack.color(); }
function snapColor(cv) {
   var r = cv.red(), g = cv.green(), b = cv.blue();
   return { red: function () { return r; }, green: function () { return g; }, blue: function () { return b; } };
}
/** Quitte le mode Send : la piste armée (celle du clavier) redevient la piste sélectionnée. */
function exitFxCtl(selectBase) {
   if (!fxCtl) return;
   fxCtl = null;
   if (selectBase) {
      for (var t = 0; t < ARM_BANK_SIZE; t++) {
         var tr = armBank.getItemAt(t);
         if (tr.exists().get() && tr.arm().get()) { cursorTrack.selectChannel(tr); break; }
      }
      popup("Mode Send terminé — retour à la piste jouée");
   }
   host.scheduleTask(checkDrumMode, 200);
   updateNoteInput();
   host.requestFlush();
}

/** Valeurs de mixage à surveiller pour une piste (pan, volume, sends). */
function markMixer(ch, nSends, tag) {
   ch.name().markInterested();
   ch.pan().markInterested();
   ch.volume().markInterested();                       // sans ça, Bitwig n'envoie pas la valeur
   try { ch.volume().hasAutomation().markInterested(); ch.pan().hasAutomation().markInterested(); } catch (eA) {}
   ch.volume().displayedValue().markInterested();
   ch.volume().name().markInterested(); ch.pan().name().markInterested();   // Delete + toucher : nom affiché
   ch.pan().displayedValue().addValueObserver(function (v) { valueChanged(tag, "pan", "Pan", v, ch); });
   ch.volume().displayedValue().addValueObserver(function (v) { valueChanged(tag, "vol", "Volume", v, ch); });
   if (nSends === 0) return;                          // Master : pas de sends
   var sb = ch.sendBank();
   for (var k = 0; k < NUM_SENDS; k++) {
      (function (snd, n) {
         snd.exists().markInterested(); snd.name().markInterested();
         snd.markInterested(); snd.displayedValue().markInterested();
         try { snd.hasAutomation().markInterested(); } catch (eA) {}
         snd.displayedValue().addValueObserver(function (v) {
            valueChanged(tag, "send" + n, "Send " + (n + 1) + " (" + snd.name().get() + ")", v, ch);
         });
      })(sb.getItemAt(k), k);
   }
}

/** Affichage des valeurs piloté par Bitwig : quand une valeur change juste après qu'on a
 *  tourné CE potard, on l'affiche (la valeur est alors toujours à jour). */
var lastTurn = { target: null, key: "", t: 0 };
function noteTurn(target, key) { lastTurn = { target: target, key: key, t: new Date().getTime() }; }
function valueChanged(tag, key, label, v, obj) {
   if (lastTurn.target !== tag || lastTurn.key !== key) return;
   if (new Date().getTime() - lastTurn.t > 1500) return;
   popup(obj.name().get() + " — " + label + " : " + v);
}
/** Mixage : on réaffiche avec le même code que le toucher (qui fonctionne), une fois
 *  après la mise à jour de Bitwig ; seul le dernier mouvement est affiché. */
var mixerShowGen = 0;
function mixerShowSoon(k) {
   var gen = ++mixerShowGen;
   host.scheduleTask(function () {
      if (gen !== mixerShowGen) return;
      try { onKnobTouch(k, true); } catch (e) { popup("Affichage mixage : " + e); }
   }, 180);
}
/** Étiquette stable de la piste pilotée par le bouton i (pour relier tour de potard et valeur). */
function channelTag(i) { return fxBtn() ? (i < 3 ? "F" + i : "M") : "T" + i; }

/** Piste pilotée par le bouton de piste i (bloc normal, ou bloc FX + Master). */
function channelForButton(i) {
   if (!fxBtn()) return trackBank4.getItemAt(i);
   return i < 3 ? fxBank.getItemAt(i) : masterTrack;
}
function buttonIsSelected(i) { return fxBtn() ? equalsFx[i].get() : equals4[i].get(); }
function buttonExists(i) { return (fxBtn() && i === 3) ? true : channelForButton(i).exists().get(); }
var project, lastMuteTap = 0;
var browser, browserResult, browserFilters = [], browsing = false, browserTick = [];
var browserCol = 0;             // étape active du navigateur par colonnes
var presetMode = false;         // navigateur ouvert pour les presets (Shift + Pas 4)
var devTypeBank, devTypeWild;   // éléments de la colonne « type de device » (icônes à gauche)
var devTypeSiblings;             // sélection du type par index (méthode DrivenByMoss)
var browserScriptMove = 0;      // dernier déplacement fait par le script (pour repérer les clics souris)
var browserCloseBy = { who: "", t: 0 };  // dernière fermeture demandée par le script
var lastGesture = "aucun";      // dernier message reçu de la Move (diagnostic)
var lastWheelTurn = 0;          // pour ignorer un clic molette accidentel en tournant
var wheelPressT = 0;            // début de l'appui molette (navigateur)
var WHEEL_CLICK_MIN_MS = 60;    // durée minimale d'un vrai clic molette dans le navigateur
var browserCols = [];           // objets colonnes Bitwig (même ordre que BROWSER_COLUMNS)
var browserSteps = [];          // étapes réellement disponibles : index de colonne, puis -1 = résultats
var BROWSER_AUDITION = false;   // écoute automatique du résultat sélectionné (désactivée : elle
                                // insérait le device en aperçu, ce qui ressemblait à une validation)
// Colonnes pilotées par les encodeurs 2 à 7 pendant la navigation (1 = type de contenu, 8 = résultats)
var BROWSER_COLUMNS = ["deviceTypeColumn", "categoryColumn", "creatorColumn", "tagColumn", "locationColumn", "fileTypeColumn", "smartCollectionColumn", "deviceColumn"];
var BROWSER_LABELS  = ["Type", "Catégorie", "Créateur", "Tag", "Emplacement", "Fichier", "Favoris / Collections", "Interface"];
var devicesShown = false;      // le script a-t-il déjà affiché le panneau Devices ?
var devicePanelAction = null;  // action Bitwig qui AFFICHE le panneau Devices (sans le basculer)
var lastDeviceWheel = 0;
var navGen = 0;                // génération de navigation : annule les affichages en retard
var siblings;                  // devices de la même chaîne que le device sélectionné
var devicePanelShowOnly = false; // true si l'action ne fait qu'afficher (aucun risque de masquer)
var noteEditorShown = false;   // éditeur de notes (panneau du bas) ouvert par le script (AUTO_PANELS)
var noteEditorOpen = false;    // (ancien : Shift + Loop) — plus utilisé
// Panneau du bas de Bitwig, suivi par le script (l'API ne sait que le basculer) :
// "devices", "note" (éditeur de notes) ou "none" (masqué). Shift + Back resynchronise.
var bottomPanel = "devices", panelBeforeLoop = "devices";
var loopFocused = false;       // vue Loop : focus déjà mis sur le panneau du bas (pour le zoom)
var loopNudge = false;         // vue Loop : molette sur la mesure de début = décale le début de boucle

// Objets Bitwig
var transport, application, groove, masterTrack, cursorTrack, cursorSlots,
    cursorDevice, remotes, drumPads, trackBank, trackBank4, clip16, clip32, noteInput;


// ============================================================================
//  4. INIT
// ============================================================================

function init() {
   var midiIn = host.getMidiInPort(0);
   midiIn.setMidiCallback(onMidi);

   // Les pads jouent l'instrument via une table de traduction (mise à jour selon le mode)
   noteInput = midiIn.createNoteInput("Move Pads", "80????", "90????", "A0????");
   noteInput.setShouldConsumeEvents(false); // onMidi reçoit quand même les messages

   for (var y = 0; y < 128; y++) {
      data16[y] = []; data32[y] = [];
      for (var x = 0; x < 32; x++) { data16[y][x] = 0; data32[y][x] = 0; }
   }

   // --- Transport / application / groove ---
   transport = host.createTransport();
   transport.isPlaying().addValueObserver(function (v) { S.isPlaying = v; });
   transport.isArrangerRecordEnabled().addValueObserver(function (v) { S.isRecording = v; });
   transport.isClipLauncherOverdubEnabled().addValueObserver(function (v) { S.isOverdub = v; });
   transport.isMetronomeEnabled().addValueObserver(function (v) { S.isMetronome = v; });
   transport.tempo().markInterested();
   transport.isAutomationOverrideActive().markInterested();
   transport.automationWriteMode().markInterested();
   transport.isClipLauncherAutomationWriteEnabled().markInterested();   // automation reprise à la main (LEDs clignotantes)
   transport.tempo().displayedValue().markInterested();

   application = host.createApplication();
   try { application.canUndo().markInterested(); } catch (eU) {}
   groove = host.createGroove();
   groove.getShuffleAmount().markInterested();
   groove.getShuffleAmount().displayedValue().markInterested();
   groove.getEnabled().markInterested();

   masterTrack = host.createMasterTrack(0);

   // --- Piste, slots et device suivis ---
   cursorTrack = host.createCursorTrack("MOVE_CURSOR", "Move", 0, 8, true);
   cursorTrack.name().markInterested();
   cursorTrack.arm().markInterested();
   cursorTrack.color().markInterested();
   cursorTrack.mute().markInterested();
   cursorTrack.solo().markInterested();
   project = host.getProject();
   project.hasSoloedTracks().markInterested();
   project.hasMutedTracks().markInterested();
   if (chordsReady()) { try { chordsInit(); } catch (eCi) { CHORDS_ERROR = "chordsInit : " + eCi; } }   // tonique / gamme Bitwig (section 14)
   cursorTrack.playingNotes().markInterested(); // notes jouées (clip ou pads) -> LEDs
   cursorSlots = cursorTrack.clipLauncherSlotBank();
   cursorSlots.itemCount().markInterested();
   cursorSlots.scrollPosition().markInterested();
   for (var i = 0; i < 8; i++) {
      var cs = cursorSlots.getItemAt(i);
      cs.hasContent().markInterested();
      cs.isPlaying().markInterested();
      cs.isRecording().markInterested();
      cs.isSelected().markInterested();
      cs.exists().markInterested();
      cs.isPlaybackQueued().markInterested();
   }

   cursorDevice = cursorTrack.createCursorDevice();
   // 2e curseur qui suit la sélection : épinglé le temps de supprimer un device, pendant que le
   // curseur principal passe sur le device voisin (on garde la main sur la Move)
   var fsm = followSelectionMode();
   delDev = fsm ? cursorTrack.createCursorDevice("MOVE_DEL", "Move Delete", 0, fsm) : cursorTrack.createCursorDevice();
   delDev.exists().markInterested(); delDev.name().markInterested(); delDev.isPinned().markInterested();
   cursorDevice.name().markInterested();
   cursorDevice.isEnabled().markInterested();
   cursorDevice.isExpanded().markInterested();
   cursorDevice.position().markInterested();
   siblings = cursorDevice.createSiblingsDeviceBank(64);
   for (var sb = 0; sb < 64; sb++) siblings.getItemAt(sb).exists().markInterested();
   cursorDevice.isNested().markInterested();
   cursorDevice.isExpanded().markInterested();
   cursorDevice.position().markInterested();
   for (var sb2 = 0; sb2 < 64; sb2++) siblings.getItemAt(sb2).name().markInterested();
   layerBank = cursorDevice.createLayerBank(16);      // couches du conteneur sélectionné (suppression)
   for (var lb = 0; lb < 16; lb++) { layerBank.getItemAt(lb).exists().markInterested(); layerBank.getItemAt(lb).name().markInterested(); }
   cursorDevice.isWindowOpen().markInterested();
   cursorDevice.isPlugin().markInterested();
   cursorDevice.isRemoteControlsSectionVisible().markInterested();
   cursorDevice.hasLayers().markInterested();
   cursorDevice.hasSlots().markInterested();
   cursorDevice.slotNames().markInterested();
   chainSlot = cursorDevice.getCursorSlot();          // chaîne interne (FX / Note FX / Instrument Chain…)
   // Couche courante d'un Instrument/FX Layer ou Selector + son premier device
   cursorLayer = cursorDevice.createCursorLayer();
   cursorLayer.name().markInterested();
   cursorLayer.exists().markInterested();
   // « la couche n°i est-elle la couche sélectionnée ? » : identification par POSITION (pas par nom)
   for (var le = 0; le < 16; le++) { layerEq[le] = layerBank.getItemAt(le).createEqualsValue(cursorLayer); layerEq[le].markInterested(); }
   layerFirstDevice = cursorLayer.createDeviceBank(1).getItemAt(0);
   layerFirstDevice.exists().markInterested();
   application.panelLayout().markInterested();
   cursorDevice.hasDrumPads().markInterested();

   // Le mode Drum des pads suit le PREMIER INSTRUMENT de la piste (le Drum Machine),
   // pas le device sélectionné : on garde l'accès aux pads même en naviguant à
   // l'intérieur d'un pad (sampler, effets…).
   drumDevice = createInstrumentFollower();
   drumDevice.exists().markInterested();
   drumDevice.hasDrumPads().addValueObserver(function () { checkDrumMode(); });
   drumDevice.exists().addValueObserver(function () { checkDrumMode(); });
   cursorTrack.position().addValueObserver(function () {
      onSelectionChangeForArm();                       // Session : repère l'armement automatique
      host.scheduleTask(checkDrumMode, 150);
      host.scheduleTask(function () { if (S.loopMode && !browsing) loopPickClip(); }, 200); // vue Loop suit la piste
   });
   host.scheduleTask(drumModeWatch, 500);
   host.scheduleTask(clockTick, 600);

   remotes = cursorDevice.createCursorRemoteControlsPage(8);
   remotes.getName().markInterested();
   remotes.selectedPageIndex().markInterested();
   remotes.pageCount().markInterested();
   remotes.pageNames().markInterested();
   cursorDevice.position().markInterested();
   cursorDevice.name().markInterested();
   cursorDevice.exists().markInterested();
   // Une « vue » indépendante par page de macros : on lit/écrit TOUTES les pages d'un coup,
   // sans changer la page affichée dans Bitwig.
   for (var mp = 0; mp < MEM_PAGES; mp++) {
      memPages[mp] = cursorDevice.createCursorRemoteControlsPage("MoveMem" + mp, 8, "");
      memPages[mp].selectedPageIndex().markInterested();
      memPages[mp].pageCount().markInterested();
      memPages[mp].getName().markInterested();
      for (var mk = 0; mk < 8; mk++) {
         memPages[mp].getParameter(mk).markInterested();
         memPages[mp].getParameter(mk).name().markInterested();
         memPages[mp].getParameter(mk).exists().markInterested();
         (function (prm, pg, k) {             // macro d'une autre page bougée (souris…) : on met à jour
            prm.value().addValueObserver(function (v) {
               var now = new Date().getTime();
               if (now - memAlignT < 400 || now - devChangeT < 800) return;   // valeurs de calage, pas fiables
               if (!prm.exists().get()) return;
               macroCache[pg + "/" + k] = { v: v, n: String(prm.name().get()) };
            });
         })(memPages[mp].getParameter(mk), mp, mk);
      }
   }
   // État COMPLET du device : tous ses paramètres, suivis en continu (valeurs + noms)
   cursorDevice.addDirectParameterIdObserver(function (ids) {
      var keep = {};
      for (var q = 0; q < ids.length; q++) { var id = String(ids[q]); keep[id] = (id in devParams) ? devParams[id] : NaN; }
      devParams = keep; devIdsT = new Date().getTime();
   });
   cursorDevice.addDirectParameterNormalizedValueObserver(function (id, v) {
      devParams[String(id)] = v; devValT = new Date().getTime();
      checkActivePreset(String(id), v);
   });
   cursorDevice.addDirectParameterNameObserver(40, function (id, nm) { devNames[String(id)] = String(nm); });
   remotes.selectedPageIndex().addValueObserver(function () { pageChangeT = new Date().getTime(); });
   remotes.getName().addValueObserver(function () {
      pageChangeT = new Date().getTime();
      host.scheduleTask(seedFromRemotes, 150);
      host.scheduleTask(captureMainPage, 300);     // page affichée : ses 8 macros (toujours justes)
   });
   for (var mi = 0; mi < 8; mi++) (function (prm, k) {
      prm.value().addValueObserver(function (v) {
         var pg = remotes.selectedPageIndex().get();
         if (new Date().getTime() - pageChangeT < 250) return;          // changement de page en cours
         if (pg >= 0 && prm.exists().get()) macroCache[pg + "/" + k] = { v: v, n: String(prm.name().get()) };
      });
   })(remotes.getParameter(mi), mi);
   cursorDevice.name().addValueObserver(function () {
      macroCache = {}; devChangeT = new Date().getTime();     // nouveau device : on repart de zéro
      host.scheduleTask(seedFromRemotes, 300);
      host.scheduleTask(captureMainPage, 300);
      if (!MEM_DIAG) return;
      host.scheduleTask(function () {
         var tot = 0, ok = 0;
         for (var id in devParams) { tot++; if (typeof devParams[id] === "number" && !isNaN(devParams[id])) ok++; }
         popup("DIAG " + cursorDevice.name().get() + " : valeurs reçues " + ok + " / " + tot + " paramètres");
      }, 1200);
   });
   remotes.pageCount().addValueObserver(function () { host.scheduleTask(memAlignPages, 50); });
   cursorDevice.name().addValueObserver(function () { host.scheduleTask(memAlignPages, 50); });
   // Mémoires de macros : enregistrées DANS le projet Bitwig (état du document)
   memSetting = host.getDocumentState().getStringSetting("Mémoires de macros", "Move", 4000000, "{}");
   if (chordsReady()) { try { chordsInitStore(); } catch (eCs) { CHORDS_ERROR = "chordsInitStore : " + eCs; } }   // presets d'accords (section 14)
   memSetting.addValueObserver(function (v) {
      try { memStore = JSON.parse(v || "{}"); } catch (e) { memStore = {}; }
   });
   for (i = 0; i < 8; i++) {
      remotes.getParameter(i).markInterested();
      remotes.getParameter(i).name().markInterested();
      remotes.getParameter(i).exists().markInterested();
      try { remotes.getParameter(i).hasAutomation().markInterested(); } catch (eA) {}
      (function (prm, n) {
         prm.displayedValue().addValueObserver(function (v) {
            valueChanged("D", "remote" + n, prm.name().get() || ("encodeur " + (n + 1)), v, cursorDevice);
         });
      })(remotes.getParameter(i), i);
      remotes.getParameter(i).setIndication(true);
   }

   drumPads = drumDevice.createDrumPadBank(32);
   drumPads.scrollPosition().set(S.drumBase);
   for (i = 0; i < 32; i++) {
      drumPads.getItemAt(i).exists().markInterested();
      drumPads.getItemAt(i).mute().markInterested();
      drumPads.getItemAt(i).color().markInterested();
      drumPads.getItemAt(i).name().markInterested();
      drumPadFirstDevice[i] = drumPads.getItemAt(i).createDeviceBank(1).getItemAt(0); // 1er device du pad
      drumPadFirstDevice[i].exists().markInterested();
   }

   // --- Banque de pistes / scènes pour le mode Session (8 x 4) ---
   trackBank = host.createMainTrackBank(8, 0, 4);
   for (var t = 0; t < 8; t++) {
      var track = trackBank.getItemAt(t);
      track.exists().markInterested();
      track.mute().markInterested();
      track.solo().markInterested();
      track.isStopped().markInterested();
      equalsCache[t] = track.createEqualsValue(cursorTrack); // « est la piste sélectionnée ? »
      equalsCache[t].markInterested();
      for (var s = 0; s < 4; s++) {
         var slot = track.clipLauncherSlotBank().getItemAt(s);
         slot.hasContent().markInterested();
         slot.isPlaying().markInterested();
         slot.isRecording().markInterested();
         slot.isPlaybackQueued().markInterested();
         slot.isRecordingQueued().markInterested();
      }
   }

   // --- Banque des 4 boutons de piste ---
   // Fenêtre de 4 pistes : bouton 1 = piste du haut de la fenêtre.
   // + / - décalent la fenêtre d'une piste et sélectionnent la piste du bouton 1.
   // Elle suit aussi la sélection faite à la souris dans Bitwig.
   trackBank4 = host.createMainTrackBank(4, NUM_SENDS, 8);
   // Bloc FX + Master (Shift + Note/Session) : 3 pistes d'effet + le Master sur le bouton 4
   // (version sans sends : celle avec sends exige une API plus récente et faisait planter)
   fxBank = host.createEffectTrackBank(3, 0, 8);      // (API 19) 8 scènes : clips des pistes FX en Session
   fxBank.scrollPosition().markInterested();
   fxBank.itemCount().markInterested();
   for (var fx = 0; fx < 3; fx++) {
      var ft = fxBank.getItemAt(fx);
      ft.exists().markInterested(); ft.name().markInterested(); ft.color().markInterested();
      ft.mute().markInterested(); ft.solo().markInterested(); ft.isGroup().markInterested();
      ft.arm().markInterested();                      // lu par les pads de Session des pistes FX
      equalsFx[fx] = ft.createEqualsValue(cursorTrack); equalsFx[fx].markInterested();
      for (var fs = 0; fs < 8; fs++) {
         var fsl = ft.clipLauncherSlotBank().getItemAt(fs);
         fsl.hasContent().markInterested(); fsl.color().markInterested(); fsl.isSelected().markInterested();
         fsl.isPlaying().markInterested(); fsl.isRecording().markInterested();
         fsl.isPlaybackQueued().markInterested(); fsl.isRecordingQueued().markInterested();
      }
      markMixer(ft, 0, "F" + fx);
   }
   masterTrack.name().markInterested(); masterTrack.mute().markInterested();
   equalsFx[3] = masterTrack.createEqualsValue(cursorTrack); equalsFx[3].markInterested();
   markMixer(masterTrack, 0, "M");
   trackBank4.followCursorTrack(cursorTrack);
   trackBank4.scrollPosition().markInterested();
   trackBank4.itemCount().markInterested();
   for (t = 0; t < 4; t++) {
      var tr4 = trackBank4.getItemAt(t);
      tr4.exists().markInterested();
      tr4.name().markInterested();
      tr4.mute().markInterested();
      tr4.arm().markInterested();
      tr4.isStopped().markInterested();
      markMixer(tr4, NUM_SENDS, "T" + t);
      tr4.color().markInterested();
      tr4.solo().markInterested();
      tr4.isGroup().markInterested(); tr4.isGroupExpanded().markInterested();
      trackDevBanks[t] = tr4.createDeviceBank(16);
      for (var dv = 0; dv < 16; dv++) { trackDevBanks[t].getItemAt(dv).exists().markInterested(); trackDevBanks[t].getItemAt(dv).isExpanded().markInterested(); }
      for (var s4 = 0; s4 < 8; s4++) {
         var sl4 = tr4.clipLauncherSlotBank().getItemAt(s4);
         sl4.hasContent().markInterested();
         sl4.color().markInterested();
         sl4.isSelected().markInterested();
         sl4.isPlaying().markInterested();
         sl4.isRecording().markInterested();
         sl4.isPlaybackQueued().markInterested();
         sl4.isRecordingQueued().markInterested();
      }
      equals4[t] = tr4.createEqualsValue(cursorTrack);
      equals4[t].markInterested();
   }
   updateIndications();

   // --- Navigateur Bitwig (ajout de devices, presets) ---
   browser = host.createPopupBrowser();
   browser.exists().addValueObserver(function (v) {
      if (!v && browsing) {
         // Qui a fermé le navigateur ? Si ce n'est pas le script, on le signale.
         var why = (new Date().getTime() - browserCloseBy.t < 1500) ? browserCloseBy.who : null;
         if (!why) popup("⚠ Navigateur fermé SANS commande du script (dernier geste : " + lastGesture + ")");
         println("Navigateur fermé : " + (why || "pas par le script") + " — dernier geste : " + lastGesture);
      }
      browsing = v;
      if (!v) host.scheduleTask(checkDrumMode, 300);   // après validation / annulation : vrai device
      if (v) {
         // Live preview : le script n'y touche plus du tout. Bitwig garde lui-même ton
         // choix ; c'est le script qui le faisait sauter en le réécrivant à chaque ouverture.
         // Étapes : Type (icônes à gauche du navigateur = « type de contenu » de l'API :
         // Instruments, Effets audio, Effets de note…) › Catégorie › Résultats
         // Provisoire : on démarre dans Catégorie. Back depuis Catégorie = Type (expérimental,
         // Bitwig ignore encore ce changement), Back depuis Type = fermer.
         browserSteps = ["type", 1, -1];
         browserCol = presetMode ? 2 : 1;      // presets : on part directement sur la liste
         browserIdx = {};
         browserScriptMove = new Date().getTime();
         host.scheduleTask(function () {      // état de départ des colonnes, puis surveillance
            lastSelName = {};
            for (var kk = 1; kk < BROWSER_COLUMNS.length; kk++) lastSelName[kk] = selectedNameOf(kk);
            lastSelName[-1] = String(browserResult.name().get());
            browserPoll();
         }, 300);
         host.scheduleTask(function () { browserSteps[1] = middleColumnForType(); showBrowserState(); }, 150);
         if (BROWSER_DIAG) host.scheduleTask(browserDiag, 600);
         if (BROWSER_ACTIONS_DIAG) host.scheduleTask(showBrowserActions, 300);
      }
   });
   browser.selectedContentTypeName().markInterested();
   browser.contentTypeNames().markInterested();
   browser.selectedContentTypeIndex().markInterested();
   // Live preview mémorisé : réglage du contrôleur (gardé après redémarrage de Bitwig),
   // mis à jour quand tu l'actives / désactives dans le navigateur (souris ou script)
   browser.shouldAudition().markInterested();
   browserResult = browser.resultsColumn().createCursorItem();
   browserResult.name().markInterested();
   // Cohérence souris : un clic dans une colonne (changement que le script n'a pas fait)
   // rend cette colonne active pour la molette.
   browserResult.name().addValueObserver(function (v) {
      if (lastSelName[-1] === String(v)) return;
      lastSelName[-1] = String(v);
      mouseFollow(-1);
   });
   for (var bc = 0; bc < BROWSER_COLUMNS.length; bc++) {
      if (bc === 0) {   // colonne « type de device » : banque d'éléments pour la sélection directe
         var dtc = browser[BROWSER_COLUMNS[0]]();
         devTypeWild = dtc.getWildcardItem();
         devTypeWild.name().markInterested();
         devTypeWild.isSelected().markInterested();
         devTypeBank = dtc.createItemBank(12);
         for (var di = 0; di < 12; di++) {
            var it = devTypeBank.getItemAt(di);
            it.exists().markInterested(); it.name().markInterested();
            it.isSelected().addValueObserver(function (v) { if (v) mouseFollow(0); });
         }
      }
      var col = browser[BROWSER_COLUMNS[bc]]();
      col.name().markInterested();
      col.exists().markInterested();
      browserCols[bc] = col;
      col.getWildcardItem().isSelected().markInterested();
      browserFilters[bc] = col.createCursorItem();
      browserFilters[bc].name().markInterested();
      browserFilters[bc].exists().markInterested();
      (function (k, column) {
         browserFilters[k].name().addValueObserver(function () { filterChanged(k); });
         // 1er clic souris : le curseur ne bouge pas toujours, on lit donc aussi la
         // sélection des éléments visibles. filterChanged() ne retient que les vrais
         // changements (le NOM sélectionné change), pas les recalculs de liste de Bitwig.
         if (k > 0) {
            var wild = column.getWildcardItem();
            wild.name().markInterested();
            wild.isSelected().addValueObserver(function () { filterChanged(k); });
            var bank = column.createItemBank(32);
            filterBanks[k] = { wild: wild, bank: bank };
            for (var bi = 0; bi < 32; bi++) {
               var item = bank.getItemAt(bi);
               item.name().markInterested();
               item.isSelected().addValueObserver(function () { filterChanged(k); });
            }
         }
      })(bc, col);

   }
   cursorTrack.position().markInterested();
   cursorDevice.exists().markInterested();

   // --- Armement qui suit la sélection faite depuis la Move ---
   armBank = host.createMainTrackBank(ARM_BANK_SIZE, 0, 0);
   for (t = 0; t < ARM_BANK_SIZE; t++) {
      var ta = armBank.getItemAt(t);
      ta.exists().markInterested();
      ta.arm().markInterested();
      (function (ti) { ta.arm().addValueObserver(function (v) { onArmChange(ti, v); }); })(t);
      ta.name().markInterested();                     // mémoires : détecter une piste renommée
      armEquals[t] = ta.createEqualsValue(cursorTrack);
      armEquals[t].markInterested();
   }
   initAutoCapEngine();                               // Capture des mouvements de potards (rejeu)

   // --- Clips : 16 pas (mode Note) et 32 pas (mode 32 pas) ---
   clip16 = createClip(16, data16, function (st) { S.playing16 = st - S.page16 * 16; });
   clip32 = createClip(32, data32, function (st) { S.playing32 = st - S.page32 * 32; });

   // Clip « capture » : grille fine couvrant CAPTURE.MAX_BARS mesures
   initPerfEngine();
   captureClip = cursorTrack.createLauncherCursorClip(Math.round(CAPTURE.MAX_BARS * 4 / CAPTURE.RESOLUTION), 128);
   captureClip.setStepSize(CAPTURE.RESOLUTION);
   captureClip.scrollToKey(0);
   captureClip.scrollToStep(0);
   captureClip.getLoopLength().markInterested();
   captureClip.getPlayStart().markInterested();
   captureClip.getLoopStart().markInterested();
   captureClip.addStepDataObserver(function (x, y, st) {
      if (st === 0) delete capData[x + "," + y]; else capData[x + "," + y] = st;
   });
   captureClip.addNoteStepObserver(function (noteStep) {});   // vélocité / durée à jour (copie de mesures)
   captureClip.addPlayingStepObserver(function (st) { clipPlay = { step: st, t: new Date().getTime() }; trackPlayRef(st); });
   transport.getPosition().addValueObserver(function (beats) {
      lastPos = { beats: beats, t: new Date().getTime() };
   });
   // Changement de piste : la mémoire Capture repart à zéro
   cursorTrack.position().addValueObserver(function () { captureNotes = []; captureHeld = {}; lastCapture = null; });

   devicePanelAction = findDevicePanelAction();
   listChainActions();

   if (LIST_ACTIONS) {
      var actions = application.getActions();
      for (i = 0; i < actions.length; i++) println(actions[i].getId() + "  —  " + actions[i].getName());
   }

   updateNoteInput();
   clearAllLeds();
   midiIn.setSysexCallback(onSysex);
   if (HANDSHAKE.ENABLED) connectMove();
   popup("Move prêt — mode " + S.mode);
}


// ============================================================================
//  4b. RÉVEIL DE LA MOVE (handshake SysEx + keep-alive)
// ============================================================================

var moveConnected = false;
var LOAD_REFRESH_MS = [600, 1200, 2500, 5000];   // renvois complets des LEDs après le chargement
var lastVelocity = 100;

function sendSysex(hex) {
   if (DEBUG) println("OUT sysex " + hex);
   host.getMidiOutPort(0).sendSysex(hex);
}

function connectMove() {
   sendSysex(HANDSHAKE.IDENTITY_REQUEST);
   // Petit délai pour laisser la Move répondre, puis passage en mode contrôleur
   host.scheduleTask(function () {
      sendSysex(HANDSHAKE.CONTROL_MODE);
      sendSysex(HANDSHAKE.WAKE_DISPLAY);
      sendSysex(HANDSHAKE.POLY_AFTERTOUCH);
      sendSysex(HANDSHAKE.IDENTITY_REQUEST); // nouvelle identité après changement de mode
      refreshAllLeds();
   }, 200);
   // La Move peut ignorer les LEDs envoyées pendant qu'elle passe en mode contrôleur, et le
   // cache empêche ensuite de les renvoyer (d'où des LEDs manquantes jusqu'au changement de
   // page). On renvoie donc TOUT plusieurs fois pendant les premières secondes.
   for (var rf = 0; rf < LOAD_REFRESH_MS.length; rf++) host.scheduleTask(refreshAllLeds, LOAD_REFRESH_MS[rf]);
   host.scheduleTask(keepAlive, HANDSHAKE.KEEPALIVE_MS);
}

/** Renvoie tout l'état des LEDs régulièrement pour que la Move reste « tenue ». */
function keepAlive() {
   if (!HANDSHAKE.ENABLED) return;
   if (HANDSHAKE.KEEPALIVE_FULL) refreshAllLeds();
   else {
      // Battement léger : un seul message (la LED Play renvoyée avec sa valeur actuelle)
      var v = ledCache["c" + HW.CC_PLAY];
      host.getMidiOutPort(0).sendMidi(0xB0 | HW.CHANNEL, HW.CC_PLAY, v === undefined ? BTN.DIM : v);
   }
   host.scheduleTask(keepAlive, HANDSHAKE.KEEPALIVE_MS);
}

function refreshAllLeds() {
   ledCache = {};       // force le renvoi de chaque LED au prochain flush
   host.requestFlush();
}

function onSysex(data) {
   var hex = data.toLowerCase();
   if (DEBUG) println("IN  sysex " + hex);
   if (hex.indexOf(HANDSHAKE.IDENTITY_REPLY_MARK) >= 0) {
      host.scheduleTask(refreshAllLeds, 150);          // la Move répond : elle est prête, on redessine tout
      if (!moveConnected) { moveConnected = true; popup("Ableton Move connectée"); }
   }
}

/** Disposition des pads selon l'instrument de la piste : Drum Machine (même vide) = pads
 *  de batterie, autre instrument ou aucun = clavier. Vérifiée aussi régulièrement, car
 *  Bitwig ne prévient pas toujours au changement de piste ou à la création d'une piste. */
function checkDrumMode() {
   if (fxCtl) return;                                 // mode Send : disposition de la piste jouée
   var v = drumDevice.exists().get() && drumDevice.hasDrumPads().get();
   // Live Preview : le device en aperçu n'est pas toujours visible pour le script. On se fie
   // alors au résultat choisi dans le navigateur (kit / drum / batterie / percussion…).
   if (browsing && !v) {
      var hint = (String(browserResult.name().get()) + " " + String(browserFilters[1].name().get())).toLowerCase();
      if (/drum|kit|batterie|percussion|perc\b|808|909|707|606|beat/.test(hint)) v = true;
   }
   if (v === S.isDrum) return;
   S.isDrum = v;
   if (v) S.selectedPitch = S.drumBase;
   updateNoteInput();
   host.requestFlush();
   popup(v ? "Pads : batterie" : "Pads : clavier");
}
function drumModeWatch() { checkDrumMode(); memAlignPages(); host.scheduleTask(drumModeWatch, 400); } // + vues de mémoires toujours prêtes

/** Device qui suit le premier instrument de la piste, indépendamment de la sélection. */
function createInstrumentFollower() {
   var mode = null;
   try { mode = Java.type("com.bitwig.extension.controller.api.CursorDeviceFollowMode").FIRST_INSTRUMENT; } catch (e1) {}
   if (!mode) { try { mode = com.bitwig.extension.controller.api.CursorDeviceFollowMode.FIRST_INSTRUMENT; } catch (e2) {} }
   if (mode) return cursorTrack.createCursorDevice("MOVE_DRUM", "Move Drum", 0, mode);
   println("CursorDeviceFollowMode indisponible : repli sur getPrimaryInstrument()");
   return cursorTrack.getPrimaryInstrument();
}

function createClip(width, store, onPlayingStep) {
   var clip = cursorTrack.createLauncherCursorClip(width, 128);
   clip.setStepSize(GRID_SIZES[S.gridIndex]);
   clip.scrollToKey(0);   // y = numéro de note MIDI
   clip.scrollToStep(0);
   clip.addStepDataObserver(function (x, y, v) {
      if (x >= 0 && x < width && y >= 0 && y < 128) store[y][x] = v;
   });
   clip.addNoteStepObserver(function (noteStep) {}); // garde les détails (vélocité, durée…) à jour pour getStep()
   clip.addPlayingStepObserver(onPlayingStep);
   clip.getLoopLength().markInterested();
   clip.getLoopStart().markInterested();
   clip.isLoopEnabled().markInterested();
   clip.getPlayStart().markInterested();
   clip.exists().markInterested();
   return clip;
}


// ============================================================================
//  5. ROUTAGE MIDI ENTRANT
// ============================================================================

function onMidi(status, d1, d2) {
   // Filet de sécurité : une erreur dans un geste est affichée au lieu d'arrêter le script
   try { handleMidi(status, d1, d2); }
   catch (e) { println("ERREUR : " + e + "  (st=" + status + " d1=" + d1 + " d2=" + d2 + ")"); popup("Erreur script : " + e); }
   // Shift, changement de mode… ne modifient rien côté Bitwig : sans cette ligne,
   // Bitwig n'appellerait pas flush() et les LEDs ne seraient pas redessinées.
   host.requestFlush();
}

function handleMidi(status, d1, d2) {
   lastGesture = "st=" + status + " d1=" + d1 + " d2=" + d2;
   if (DEBUG) println("IN  st=" + status + " d1=" + d1 + " d2=" + d2);
   var type = status & 0xF0;

   // Un modificateur (Mute, Delete, Copy, Loop) « appuyé seul » a une action propre.
   // Dès qu'un autre contrôle est utilisé pendant qu'il est tenu, c'est une combinaison.
   var modifiers = [HW.CC_SHIFT, HW.CC_MUTE, HW.CC_COPY, HW.CC_DELETE, HW.CC_LOOP];
   var isUse = (type === 0x90 && d2 > 0) || (type === 0xB0 && d2 > 0 && modifiers.indexOf(d1) < 0);
   // Toute autre édition rend la dernière capture « ancienne » : Undo redevient celui de Bitwig
   // Undo annule toute la dernière capture d'un coup, tant qu'on n'a pas édité de notes depuis :
   // seule une édition au séquenceur (pas, mode Note hors Perf / Loop) ou un enregistrement l'oublie.
   if (isUse && type === 0x90 && d1 >= HW.STEP_FIRST_NOTE && d1 < HW.STEP_FIRST_NOTE + 16 &&
       S.mode === MODE.NOTE && !memLock && !S.loopMode) lastCapture = null;
   if (isUse && type === 0xB0 && d1 === HW.CC_RECORD) lastCapture = null;
   if (isUse) {
      if (S.mute) S.muteUsed = true;
      if (S.shift) S.shiftUsed = true;
      if (S.del)  S.delUsed = true;
      if (S.copy) S.copyUsed = true;
      if (S.loop) S.loopUsed = true;
   }

   if (type === 0xA0) {                       // aftertouch polyphonique (pression par pad)
      if (morph) { onMorphPressure(d1 - HW.PAD_FIRST_NOTE, d2); return; }   // morphing entre 2 presets
      var cpn = chordPresetHeld[d1 - HW.PAD_FIRST_NOTE];                // preset d'accord joué : pression sur ses notes
      if (cpn) { for (var an = 0; an < cpn.length; an++) noteInput.sendRawMidiEvent(0xA0, cpn[an], d2); return; }
      return;                                  // le son passe par noteInput (traduit comme les notes)
   }
   if (type === 0x90 || type === 0x80) {
      var on = (type === 0x90 && d2 > 0);
      if (on) lastVelocity = S.fullVelocity ? 127 : d2;
      var pad = d1 - HW.PAD_FIRST_NOTE;
      if (pad >= 0 && pad < 32) { onPad(pad, on); return; }
      var step = d1 - HW.STEP_FIRST_NOTE;
      if (step >= 0 && step < 16) { onStepButton(step, on); return; }
      if (d1 >= HW.TOUCH_FIRST_NOTE && d1 <= HW.TOUCH_FIRST_NOTE + 8) knobTouchAutomation(d1 - HW.TOUCH_FIRST_NOTE, on);
      if (on && d1 >= HW.TOUCH_FIRST_NOTE && d1 <= HW.TOUCH_FIRST_NOTE + 9) onKnobTouch(d1 - HW.TOUCH_FIRST_NOTE);
      return; // autres notes ignorées
   }
   if (type !== 0xB0) return;

   var pressed = d2 > 0;
   var enc = d1 - HW.CC_ENCODER_FIRST;
   if (enc >= 0 && enc < 8) { onEncoder(enc, relative(d2)); return; }
   if (d1 === HW.CC_VOLUME) { onVolume(relative(d2)); return; }
   if (d1 === HW.CC_WHEEL)  { onWheel(relative(d2)); return; }

   var trackIdx = HW.CC_TRACKS.indexOf(d1);
   if (trackIdx >= 0) { onTrackButton(trackIdx, pressed); return; }

   // Modificateurs (appui + relâchement)
   switch (d1) {
      case HW.CC_SHIFT:
         S.shift = pressed;
         if (!pressed) unlockHold = false;
         if (!pressed && fxCtl) {
            fxCtl.latchHold = false;
            if (fxCtl.peek) {                           // Send verrouillé : boutons de nouveau sur FX / Master,
               fxCtl.peek = false;                      // la piste choisie reste sélectionnée
               popup("Mode Send — boutons sur FX / Master, " + cursorTrack.name().get() + " reste sélectionnée");
            }
         }
         host.requestFlush();                           // boutons de piste FX / pistes : mise à jour immédiate
         if (pressed) {
            var nowS = new Date().getTime();
            shiftDownT = nowS; shiftJustLocked = false;
            captureChordMemo(!scaleMode);                               // le dernier accord joué est mémorisé (toujours)
            if (scaleMode && !chordLock && nowS - lastShiftTap < 400 && !S.shiftUsed && S.mode === MODE.NOTE) {
               lastShiftTap = 0; chordLock = true; shiftJustLocked = true;   // double appui : presets d'accords verrouillés
               updateNoteInput();
               popup("Presets d'accords verrouillés : pads de droite = accords, pas = séquenceur (pas tenu + preset = écrit l'accord) — 1 clic sur Shift pour sortir");
            } else if (!memLock && !scaleMode && nowS - lastShiftTap < 400 && !S.shiftUsed && S.mode === MODE.NOTE) {   // double appui : mode Preset
               lastShiftTap = 0;
               memLock = true; shiftJustLocked = true; memAlignPages();
               if (Object.keys(stepPresetMap(false)).length) perfPinHere();   // ses pas à preset rejouent
               popup("mode Preset : pads de droite = presets, molette = pages, Shift tenu + molette = device, 1 clic sur Shift pour sortir");
            } else lastShiftTap = nowS;
            S.shiftUsed = false;
         } else if (morph && !morph.knob) {                             // relâcher Shift fige le morph
            popup("Morph figé à " + Math.round(morph.t * 100) + " %");
            morph = null;
         } else if (chordLock && !shiftJustLocked && !S.shiftUsed && new Date().getTime() - shiftDownT < SHIFT_CLICK_MS) {
            chordLock = false; lastShiftTap = 0; releaseChordPresets(); updateNoteInput();
            popup("Presets d'accords déverrouillés");
         } else if (memLock && !shiftJustLocked && !S.shiftUsed && new Date().getTime() - shiftDownT < SHIFT_CLICK_MS) {
            memLock = false; lastShiftTap = 0;                         // mode Preset : un clic court = sortie
            if (presetAutoRec) togglePresetAutomationRec();            // arrête l'enregistrement d'automation
            popup("mode Preset désactivé");
         }
         // Shift maintenu : les pads ne jouent plus (sélection silencieuse d'un son).
         // On ne change pas la table si un pad est tenu, pour éviter une note bloquée.
         if (heldPadPitches().length === 0) updateNoteInput();
         return;
      case HW.CC_MUTE:   onMuteButton(pressed); return;
      case HW.CC_COPY:   onCopyButton(pressed); return;
      case HW.CC_DELETE: if (pressed) { captureNotes = []; captureHeld = {}; } onDeleteButton(pressed); return;
      case HW.CC_LOOP:   onLoopButton(pressed); return;
      case HW.CC_WHEEL_CLICK:
         // Navigateur ouvert : on agit au RELÂCHEMENT, seulement si l'appui a duré assez
         // longtemps (un faux contact de la molette donne un appui très bref)
         if (browsing) {
            if (pressed) { wheelPressT = new Date().getTime(); return; }
            var held = new Date().getTime() - wheelPressT;
            if (wheelPressT && held >= WHEEL_CLICK_MIN_MS) onWheelClick();
            else popup("Clic molette trop bref ignoré (" + held + " ms)");
            wheelPressT = 0;
            return;
         }
         if (pressed) onWheelClick();
         return;
      case HW.CC_NOTE_SESSION:
         // Shift + Note/Session : mode Send verrouillé (ou sortie). Seul : Note ⇄ Session ;
         // tenu + bouton de piste = Stop.
         if (pressed) {
            if (S.shift && fxCtl && !fxCtl.momentary) { exitFxCtl(true); unlockHold = true; }   // Shift + Note/Session : fin du mode Send
            else if (S.shift) latchSend();                                                     // mode Send verrouillé
            else {
               // Depuis Note : Session tout de suite. Depuis Session : passage en Note au relâchement.
               // Tenu + bouton de piste = Stop de la piste.
               var fromMode = S.mode;
               if (S.mode !== MODE.SESSION) switchMode();
               nsPress = { from: fromMode, used: false };
            }
         } else if (nsPress) endNsPress();
         return;
   }
   if (!pressed) return;

   // Boutons simples (appui seulement)
   switch (d1) {
      case HW.CC_PLAY:
         // Bitwig reprend là où il s'était arrêté (le 1er Stop garde la position). Comme sur la
         // Move, Play repart toujours du début ; Shift + Play reprend à la position actuelle.
         if (S.isPlaying) transport.stop();
         else if (S.shift) { transport.play(); popup("Lecture depuis la position actuelle"); }
         else { transport.getPosition().set(0); transport.play(); }
         break;
      case HW.CC_RECORD:
         if (S.shift) transport.record();   // Shift + Record : enregistrement arrangeur
         else onRecordClip();
         break;
      case HW.CC_SAMPLE: armByUser(); cursorTrack.arm().toggle(); break;
      case HW.CC_UNDO:
         if (S.shift) {                         // Shift + Undo : rend la main à l'automation si elle a été reprise,
            var ovr = false; try { ovr = transport.isAutomationOverrideActive().get(); } catch (eO) {}
            if (ovr) { transport.resetAutomationOverrides(); popup("Automation rétablie (reprises manuelles annulées)"); }
            else application.redo();            // sinon Redo, comme sur la Move
         }
         else if (lastCapture) undoCapture();   // annule la dernière capture d'un coup
         else { application.undo(); relaunchDeletedClip(); resyncDeviceCursor(); }
         if (!S.shift) { captureNotes = []; captureHeld = {}; }   // Undo : la mémoire Capture repart de zéro
         break;
      case HW.CC_CAPTURE:
         if (CAPTURE_ACTION_ID) application.getAction(CAPTURE_ACTION_ID).invoke();
         else if (S.shift || S.del) { captureNotes = []; captureHeld = {}; popup("Mémoire Capture vidée"); }
         else if (memLock) togglePresetAutomationRec();     // Perf : enregistre l'enchaînement en automation
         else doCapture();
         break;
      case HW.CC_BACK:   onBack(); break;
      case HW.CC_LEFT:   navigate(-1, 0); break;
      case HW.CC_RIGHT:  navigate(1, 0);  break;
      case HW.CC_UP:     navigate(0, 1);  break;
      case HW.CC_DOWN:   navigate(0, -1); break;
   }
}

/** Encodeur relatif en complément à 2 : 1..63 = +, 65..127 = - */
function relative(v) { return v > 63 ? v - 128 : v; }


// ============================================================================
//  6. MODES ET NAVIGATION
// ============================================================================

/** Relâchement de Note/Session (sans Shift).
 *  Entré depuis Note : Stop ou clip choisi -> retour en Note ; sinon on reste en Session.
 *  En Session : rien de fait -> passage en Note ; Stop / clip -> on reste en Session. */
function endNsPress() {
   var p = nsPress; nsPress = null;
   if (p.from === MODE.SESSION) { if (!p.used && S.mode === MODE.SESSION) switchMode(); }
   else if (p.used && S.mode === MODE.SESSION) {
      S.mode = p.from; S.heldSteps = {}; S.heldPads = {};
      if (S.mode === MODE.NOTE) armFollowSelection();
      updateNoteInput(); updateIndications();
      popup("Mode " + S.mode);
   }
   host.requestFlush();
}
function switchMode() {
   S.mode = (S.mode === MODE.NOTE) ? MODE.SESSION : MODE.NOTE;
   S.heldSteps = {}; S.heldPads = {};
   if (S.mode === MODE.NOTE) armFollowSelection();      // retour en Note : l'armement auto reprend
   else disarmAutoInSession();                          // Session : pas d'armement automatique
   updateNoteInput();
   updateIndications();
   popup("Mode " + S.mode);
}

function navigate(dx, dy) {
   if (S.mode === MODE.SESSION) {
      // Vue horizontale : Gauche/Droite = scènes (8 par page, Shift : 1 par 1),
      // + / - = pistes, comme en mode Note
      var scenes = trackBank4.sceneBank(), fxs = fxBank.sceneBank();
      if (dx < 0) { if (S.shift) { scenes.scrollBackwards(); fxs.scrollBackwards(); } else { scenes.scrollPageBackwards(); fxs.scrollPageBackwards(); } }
      if (dx > 0) { if (S.shift) { scenes.scrollForwards(); fxs.scrollForwards(); } else { scenes.scrollPageForwards(); fxs.scrollPageForwards(); } }
      if (dy) moveTrackWindow(dy > 0 ? -1 : 1);
      return;
   }
   // Pas maintenu (mode Note) : Gauche/Droite = nudge, + / - = transposition (natif Move)
   if (S.mode === MODE.NOTE && heldStepList().length && !S.loopMode) {
      moveHeldNotes(dx, dy * (S.shift ? 12 : 1));
      return;
   }
   // + / - sans Shift : piste suivante / précédente (modes Note et 32 pas)
   // + = piste du dessus, - = piste du dessous (comme à l'écran)
   if (dy && S.heldTrack >= 0) { foldHeldTrack(dy < 0); return; }   // piste tenue : − = déplier, + = replier
   if (dy && !S.shift) { moveTrackWindow(dy > 0 ? -1 : 1); return; }
   // Gauche / Droite seuls : device précédent / suivant ; Shift + Gauche / Droite : pages de pas
   if (dx && !S.shift) {
      if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
      if (dx > 0) cursorDevice.selectNext(); else cursorDevice.selectPrevious();
      navGen++;
      revealSoon(function () { showDeviceLocation(true); });
      return;
   }
   if (S.mode === MODE.STEP32) {
      if (dx) {
         S.page32 = Math.max(0, S.page32 + dx);
         clip32.scrollToStep(S.page32 * 32);
         popup("Pas " + (S.page32 * 32 + 1) + "–" + (S.page32 * 32 + 32));
      }
      if (dy) { // Shift + / - : octave de la note séquencée
         S.selectedPitch = clamp(S.selectedPitch + dy * 12, 0, 127);
         popup("Note : " + noteName(S.selectedPitch));
      }
      return;
   }
   // MODE NOTE
   if (dx) {
      S.page16 = Math.max(0, S.page16 + dx);
      clip16.scrollToStep(S.page16 * 16);
      popup("Pas " + (S.page16 * 16 + 1) + "–" + (S.page16 * 16 + 16));
   }
   if (dy) { // Shift + / - : octave (instrument) ou banque de 16 pads (drum)
      if (S.isDrum) {
         S.drumBase = clamp(S.drumBase + dy * 16, 0, 96);
         drumPads.scrollPosition().set(S.drumBase);
         S.selectedPitch = S.drumBase;
         popup("Pads " + noteName(S.drumBase) + " – " + noteName(S.drumBase + 31));
      } else {
         S.octave = clamp(S.octave + dy, -2, 8);
         popup("Octave " + S.octave);
      }
      updateNoteInput();
   }
}


// ============================================================================
//  7. PADS
// ============================================================================

function onPad(i, on) {
   if (S.mode === MODE.SESSION) { if (on) onSessionPad(i); return; }
   if (S.mode === MODE.STEP32)  { if (on) onStep32Pad(i);  return; }
   if (padsOff() && !((S.shift || memLock) && (i % 8) >= 4)) return;   // FX / Master : pads inactifs (presets gardés)
   if (scaleMode && S.mode === MODE.NOTE && (i % 8) >= 4 && (S.shift || chordLock || chordPresetHeld[i] || chordPresetIgnore[i])) { onChordPresetPad(i, on); return; }

   // Shift + moitié DROITE des pads : mémoires de macros du device sélectionné
   if ((S.shift || memLock) && (i % 8) >= 4) {
      if (on) { memPadDown(i); onMemoryPad(memIndex(i)); } else memPadUp(i);
      return;
   }
   if (!on && memHeld[i] !== undefined) { memPadUp(i); return; }   // pad relâché après la sortie du mode

   // MODE NOTE — le son passe par noteInput ; ici on gère la logique
   var pitch = padPitch(i);
   if (!on) { delete S.heldPads[i]; captureNoteOff(i); return; }
   if (pitch < 0) return;
   S.heldPads[i] = pitch;
   if (!S.shift) { captureNoteOn(i, pitch, lastVelocity); noteChordCandidate(); }

   if ((S.loopMode || S.loop) && S.loopHeldBar >= 0) return;  // vue Loop : aucune édition de notes (le pad joue seulement)
   var held = heldStepList();
   if (held.length) {                       // pas maintenu + pad : ajoute/retire la note
      for (var k = 0; k < held.length; k++) {
         clip16.toggleStep(HW.CHANNEL, held[k], pitch, velocity());
         S.heldSteps[held[k]].edited = true;
      }
      return;
   }
   if (S.del) { clip16.clearStepsAtY(HW.CHANNEL, pitch); popup("Notes " + noteName(pitch) + " effacées"); return; }
   if (S.mute && S.isDrum) { drumPads.getItemAt(drumIndex(i)).mute().toggle(); return; }

   // Batterie : pad seul = son + devient la note du séquenceur (pas de sélection dans Bitwig).
   // Shift + pad = sans son, note du séquenceur + sélection du pad et de son device dans Bitwig.
   if (S.isDrum && !S.shift) { S.selectedPitch = pitch; return; }
   var changed = (pitch !== S.selectedPitch);
   S.selectedPitch = pitch;
   if (S.isDrum && !browsing) {   // navigateur ouvert : ne rien sélectionner (Bitwig validerait)
      var idx = drumIndex(i), dp = drumPads.getItemAt(idx);
      dp.selectInEditor();
      // Les encodeurs suivent le son choisi : on sélectionne le 1er device du pad
      if ((changed || S.shift) && drumPadFirstDevice[idx].exists().get()) {
         // Ouvre le panneau du pad : Drum Machine déplié (sa chaîne de pad devient visible),
         // puis le device du pad sélectionné, déplié et affiché
         if (AUTO_FOLD) drumDevice.isExpanded().set(true);
         goToDevice(drumPadFirstDevice[idx], function () {
            if (S.shift) popup("Son : " + (dp.name().get() || noteName(pitch)) + " — " + cursorDevice.name().get() + " — " + remotes.getName().get());
         });
      } else if (S.shift) popup("Son : " + (dp.name().get() || noteName(pitch)));
   }
}

// ============================================================================
//  MÉMOIRES DE MACROS (Shift + moitié droite des pads)
// ============================================================================

/** Numéro de mémoire (0..15) : bloc 4x4 de droite, 1re en haut à gauche. */
function memIndex(i) { var row = Math.floor(i / 8), col = i % 8; return (3 - row) * 4 + (col - 4); }

/** Chaque vue de mémoire pointe sur sa page (0, 1, 2…) du device sélectionné. */
var delDev, layerBank, inLayerName = "", inLayerIdx = -1, layerEq = [], chainSlot;
function followSelectionMode() {
   var m = null;
   try { m = Java.type("com.bitwig.extension.controller.api.CursorDeviceFollowMode").FOLLOW_SELECTION; } catch (e1) {}
   if (!m) { try { m = com.bitwig.extension.controller.api.CursorDeviceFollowMode.FOLLOW_SELECTION; } catch (e2) {} }
   return m;
}
var devParams = {}, devNames = {}, devIdsT = 0, devValT = 0;
// Macros (pages de Remote Controls) du device : elles peuvent piloter des paramètres de
// modulateurs ou de devices imbriqués (FX…) qui ne sont pas dans les paramètres directs.
// "page/encodeur" -> { v: valeur, n: nom }. Rempli par la page affichée, puis tenu à jour.
var macroCache = {}, devChangeT = 0, pageChangeT = 0;
var MEM_DIAG = false;   // diagnostic temporaire : nombre de valeurs reçues par device
var memAlignT = 0;     // dernier recalage des vues de pages (les valeurs arrivent un peu après)
function memAlignPages() {
   if (!memPages.length) return;
   var n = Math.min(remotes.pageCount().get(), MEM_PAGES);
   for (var p = 0; p < n; p++) if (memPages[p].selectedPageIndex().get() !== p) {
      memPages[p].selectedPageIndex().set(p); memAlignT = new Date().getTime();
   }
}

/** Vues de pages prêtes : chaque vue est sur sa page (index ET nom de page identiques à ceux
 *  du device), et Bitwig a eu le temps d'envoyer les valeurs depuis le dernier recalage. */
function memPagesAligned() {
   var n = Math.min(remotes.pageCount().get(), MEM_PAGES), names = remotes.pageNames().get();
   for (var p = 0; p < n; p++) {
      if (memPages[p].selectedPageIndex().get() !== p) return false;
      if (names && names[p] !== undefined && String(memPages[p].getName().get()) !== String(names[p])) return false;
   }
   return new Date().getTime() - memAlignT > 150;
}

/** Clé d'un device : nom de la piste + nom du device (indépendante de la position de la
 *  piste et du device : on peut déplacer pistes et devices sans perdre les mémoires). */
var MEM_SEP = " § ";
function memKey() { return cursorTrack.name().get() + MEM_SEP + cursorDevice.name().get(); }

/** Noms de toutes les pistes du projet (pour savoir si une piste a été renommée). */
function memTrackNames() {
   var names = {};
   for (var t = 0; t < ARM_BANK_SIZE; t++) {
      var tr = armBank.getItemAt(t);
      if (tr.exists().get()) names[tr.name().get()] = true;
   }
   return names;
}

/** Mémoires du device sélectionné. Si la piste a été renommée, on retrouve les mémoires
 *  d'un device du même nom dont l'ancienne piste n'existe plus, et on les rattache. */
function memSlots(create) {
   var k = memKey();
   if (memStore[k]) return memStore[k];
   var dev = cursorDevice.name().get(), names = memTrackNames();
   for (var old in memStore) {
      var parts = old.split(MEM_SEP);
      if (parts.length === 2 && parts[1] === dev && !names[parts[0]]) {
         memStore[k] = memStore[old]; delete memStore[old]; memSave();
         popup("Mémoires de " + dev + " retrouvées (piste renommée)");
         return memStore[k];
      }
   }
   if (!create) return {};
   memStore[k] = {};
   return memStore[k];
}
function memSave() {
   for (var k in memStore) if (Object.keys(memStore[k]).length === 0) delete memStore[k];
   memSetting.set(JSON.stringify(memStore));
}

/** Parcours des pages de macros avec le curseur PRINCIPAL (le seul dont les valeurs sont
 *  toujours à jour, touchées ou non). Pour chaque page : on l'affiche, on attend que Bitwig
 *  ait bien basculé (index + nom de page), puis on lit ou on écrit ses 8 valeurs.
 *  À la fin, on revient sur la page de départ. */
var memBusy = false;

/** Photo de l'état complet du device : la valeur de chacun de ses paramètres. */
function memSnapshotDirect() {
   var out = {}, n = 0;
   for (var id in devParams) {
      var v = devParams[id];
      if (typeof v === "number" && !isNaN(v)) { out[id] = Math.round(v * 100000) / 100000; n++; }
   }
   return { direct: out, count: n };
}
/** Complète les valeurs inconnues avec la page de macros affichée (ses valeurs sont toujours
 *  justes) : chaque macro est reliée à son paramètre par le nom. */
function seedFromRemotes() {
   for (var k = 0; k < 8; k++) {
      var prm = remotes.getParameter(k);
      if (!prm.exists().get()) continue;
      var nm = String(prm.name().get());
      if (!nm) continue;
      for (var id in devNames) if (devNames[id] === nm && (typeof devParams[id] !== "number" || isNaN(devParams[id]))) devParams[id] = prm.get();
   }
}

/** Lit les 8 macros de la page affichée (curseur principal : valeurs toujours justes). */
function captureMainPage() {
   var pg = remotes.selectedPageIndex().get();
   if (pg < 0) return;
   for (var k = 0; k < 8; k++) {
      var prm = remotes.getParameter(k);
      if (prm.exists().get()) macroCache[pg + "/" + k] = { v: prm.get(), n: String(prm.name().get()) };
   }
}

/** Pages de macros encore inconnues : on les affiche une à une très vite pour lire leurs
 *  valeurs (une seule fois par device ; ensuite le suivi des mouvements suffit). */
var MEM_SILENT_LEARN = true;   // true : lit les pages inconnues SANS les afficher (vues cachées) ;
                               // false : les affiche une à une (méthode v3.89, sûre)
function memLearnMissingPages(done) {
   if (MEM_SILENT_LEARN) { memLearnSilent(done); return; }
   var n = Math.min(remotes.pageCount().get(), MEM_PAGES), back = remotes.selectedPageIndex().get(), todo = [];
   for (var p = 0; p < n; p++) {
      var known = false;
      for (var k = 0; k < 8 && !known; k++) if (macroCache[p + "/" + k]) known = true;
      if (!known && p !== back) todo.push(p);
   }
   if (!todo.length) { done(); return; }
   memBusy = true;
   var i = 0, tries = 0, settled = false;
   function next() {
      if (i >= todo.length) {
         if (back >= 0) remotes.selectedPageIndex().set(back);
         memBusy = false; done(); return;
      }
      var pg = todo[i], names = remotes.pageNames().get();
      var ok = remotes.selectedPageIndex().get() === pg &&
               (!names || names[pg] === undefined || String(remotes.getName().get()) === String(names[pg]));
      if (!ok && tries < 30) {
         if (tries === 0) remotes.selectedPageIndex().set(pg);
         tries++; host.scheduleTask(next, 15); return;
      }
      if (!settled) { settled = true; host.scheduleTask(next, 30); return; }   // les valeurs suivent la page
      captureMainPage();
      i++; tries = 0; settled = false; next();
   }
   next();
}

/** Lecture des pages inconnues par les vues cachées (une par page), sans toucher à la page
 *  affichée. On attend que chaque vue soit calée (index + nom de page) puis un court délai. */
function memLearnSilent(done) {
   var n = Math.min(remotes.pageCount().get(), MEM_PAGES), cur = remotes.selectedPageIndex().get(), todo = [];
   for (var p = 0; p < n; p++) {
      var known = false;
      for (var k = 0; k < 8 && !known; k++) if (macroCache[p + "/" + k]) known = true;
      if (!known && p !== cur) todo.push(p);
   }
   if (!todo.length) { done(); return; }
   memBusy = true;
   memAlignPages();
   var tries = 0;
   function check() {
      var names = remotes.pageNames().get(), ready = true;
      for (var i = 0; i < todo.length; i++) {
         var pg = todo[i];
         if (memPages[pg].selectedPageIndex().get() !== pg) { ready = false; break; }
         if (names && names[pg] !== undefined && String(memPages[pg].getName().get()) !== String(names[pg])) { ready = false; break; }
      }
      if (!ready && tries < 40) { tries++; memAlignPages(); host.scheduleTask(check, 20); return; }
      host.scheduleTask(function () {
         for (var j = 0; j < todo.length; j++) {
            var pg2 = todo[j];
            for (var k2 = 0; k2 < 8; k2++) {
               var prm = memPages[pg2].getParameter(k2);
               if (prm.exists().get()) macroCache[pg2 + "/" + k2] = { v: prm.get(), n: String(prm.name().get()) };
            }
         }
         memBusy = false; done();
      }, Math.max(0, 150 - (new Date().getTime() - memAlignT)));
   }
   check();
}

/** Remet les macros mémorisées (y compris celles qui pilotent modulateurs / FX imbriqués). */
function memRecallMacros(macros) {
   var c = 0, cur = remotes.selectedPageIndex().get();
   for (var key in macros) {
      var parts = key.split("/"), pg = parseInt(parts[0], 10), k = parseInt(parts[1], 10), e = macros[key];
      var prm = (pg === cur) ? remotes.getParameter(k) : (pg < MEM_PAGES ? memPages[pg].getParameter(k) : null);
      if (!prm || !prm.exists().get()) continue;
      if (pg !== cur && memPages[pg].selectedPageIndex().get() !== pg) continue;   // vue pas calée
      if (e.n && String(prm.name().get()) !== e.n) continue;                        // autre paramètre à cette place
      prm.set(e.v); c++;
   }
   return c;
}

/** Remet chaque paramètre du device à sa valeur mémorisée. */
var MEM_RES = 16384;
function memRecallDirect(mem) {
   var c = 0;
   for (var id in mem.direct) {
      if (!(id in devParams)) continue;                  // paramètre absent sur ce device
      var v = mem.direct[id];
      cursorDevice.setDirectParameterValueNormalized(id, Math.round(v * (MEM_RES - 1)), MEM_RES);
      c++;
   }
   return c;
}



/** Premier appui : mémorise toutes les macros du device ; ensuite : rappel.
 *  Copy + Shift + pad = copier ; puis Shift + pad = coller. Delete + Shift + pad = effacer. */
function onMemoryPad(m) {
   if (!cursorDevice.exists().get()) { popup("Aucun device sélectionné"); return; }
   var name = cursorDevice.name().get(), slots = memSlots(false);
   if (S.del) {
      if (slots[m]) { delete slots[m]; memSave(); popup(name + " — mémoire " + (m + 1) + " effacée"); }
      return;
   }
   if (S.copy && !(memClipboard && memCopyHold)) {  // Copy tenu : 1er pad = source…
      if (!slots[m]) { popup("Mémoire " + (m + 1) + " vide"); return; }
      memClipboard = JSON.parse(JSON.stringify(slots[m])); memCopyHold = true; memClipIdx = m;
      popup("Preset " + (m + 1) + " copié — touche le pad de destination");
      return;
   }                                                  // …pad suivant (Copy tenu ou non) = destination
   if (memClipboard) {
      slots = memSlots(true);
      slots[m] = memClipboard; memClipboard = null; memSave();
      popup(name + " — collé en mémoire " + (m + 1));
      return;
   }
   if (memBusy) return;
   // mode Preset : pas maintenu(s) + pad preset = le preset est rappelé quand la lecture arrive sur ce pas
   var hsl = perfHeldList();
   if (hsl.length && S.mode === MODE.NOTE && isEmptySlotMode()) { perfHeld = {}; popup("Pas de clip : crée d'abord un clip"); return; }
   if (hsl.length && S.mode === MODE.NOTE) {
      if (!slots[m]) { popup("Mémoire " + (m + 1) + " vide : enregistre-la d'abord"); return; }
      memLast = m;
      for (var q = 0; q < hsl.length; q++) {
         perfHeld[hsl[q]] = "used";                   // le relâchement ne refera rien
         setStepPreset(hsl[q], m);
      }
      popup("Preset " + (m + 1) + " sur le" + (hsl.length > 1 ? "s pas " : " pas ") + hsl.map(function (v) { return v + 1; }).join(", "));
      return;
   }
   // 2e pad preset pendant qu'un autre est tenu : morphing entre les deux à l'aftertouch
   // Morph en cours (pad 2 sous le doigt) + pad 3 : on repart de l'état ACTUEL (ex. 50 %)
   if (morph && morph.active && slots[m] && slots[m].direct && !S.del && !S.copy && padOfMemory(m) !== morph.padB) {
      var fromPad = morph.padB, mix = morphMix(morph.A, morph.B, morph.t), pct = Math.round(morph.t * 100);
      var labelFrom = (morph.labelA || (morph.mA + 1)) + "/" + (morph.mB + 1) + " " + pct + "%";
      morph = null;
      startMorph(-1, m, mix, slots[m]);
      morph.padA = fromPad; morph.labelA = labelFrom;
      popup("Morph " + labelFrom + " → " + (m + 1) + " : la pression du " + (m + 1) + " fait le mouvement");
      return;
   }
   // Perf : Shift + pad preset = morph de l'état ACTUEL vers ce preset, dosé par la pression
   if (memLock && S.shift && slots[m] && slots[m].direct && !S.del && !S.copy) {
      seedFromRemotes(); captureMainPage();
      var cur = memSnapshotDirect(); cur.macros = JSON.parse(JSON.stringify(macroCache));
      startMorph(-1, m, cur, slots[m]);
      morph.labelA = "actuel";
      popup("Morph actuel → " + (m + 1) + " : la pression du pad fait le mouvement");
      return;
   }
   // Et toujours : pad preset A tenu + pad B = morph de A vers B (pression du pad B)
   var other = memOtherHeld(m);
   if (other >= 0 && slots[other] && slots[m] && slots[other].direct && slots[m].direct && !S.del && !S.copy) {
      startMorph(other, m, slots[other], slots[m]);
      return;
   }
   if (!slots[m]) {                                   // vide : état complet du device
      seedFromRemotes(); captureMainPage();
      memLearnMissingPages(function () { memStoreNow(m, name); });   // 1er enregistrement : apprend les pages inconnues
      return;
   }
   {                                                  // pleine : rappel immédiat
      var mem = slots[m];
      if (!mem.direct) { popup("Mémoire " + (m + 1) + " d'une ancienne version : efface-la (Delete + pad) et réenregistre-la"); return; }
      memLast = m;
      var cm = mem.macros ? memRecallMacros(mem.macros) : 0;   // d'abord les macros (modulateurs / FX imbriqués)
      setActivePreset(m);
      var c = memRecallDirect(mem);                            // puis les paramètres du device : ils ont le dernier mot
      popup(name + " — mémoire " + (m + 1) + " rappelée (" + c + " paramètres, " + cm + " macros)");
   }
}

// ----------------------------------------------------------------------------
//  Presets sur les pas (mode Preset) : { clé piste+device+slot : { position en temps : mémoire } }
// ----------------------------------------------------------------------------
var STEPS_KEY = "\u00a7pas\u00a7";
function stepPresetKey() { return memKey() + "|" + selectedSlotIndex(); }
function stepPresetMap(create) {
   if (!memStore[STEPS_KEY]) { if (!create) return {}; memStore[STEPS_KEY] = {}; }
   var all = memStore[STEPS_KEY], k = stepPresetKey();
   if (!all[k]) { if (!create) return {}; all[k] = {}; }
   return all[k];
}
function stepBeat(absStep) { return (Math.round(absStep * GRID_SIZES[S.gridIndex] * 1000) / 1000).toString(); }
/** Preset (0..15) porté par le pas affiché x, ou -1. */
function stepPresetAt(x) {
   var mp = stepPresetMap(false), v = mp[stepBeat(S.page16 * 16 + x)];
   return (v === undefined) ? -1 : v;
}
function setStepPreset(x, m) {
   if (m >= 0) perfPinHere();                        // ce device continue de jouer ses pas, même désélectionné
   var mp = stepPresetMap(true), key = stepBeat(S.page16 * 16 + x);
   var old = (mp[key] === undefined) ? -1 : mp[key];
   if (m < 0) { delete mp[key]; popup("Preset retiré du pas " + (x + 1)); } else mp[key] = m;
   var all = memStore[STEPS_KEY];
   if (all && Object.keys(mp).length === 0) delete all[stepPresetKey()];
   memSave();
}

// ----------------------------------------------------------------------------
//  Moteur des presets de pas : une piste + un device « épinglés » (pinned) sur le dernier
//  device où l'on a posé des presets. Il continue de jouer ses presets de pas même quand on
//  sélectionne un autre device ou une autre piste.
// ----------------------------------------------------------------------------
var perfTrack, perfDev, perfClip, perfSlots, perfPages = [], PERF_STEPS = 256;
var perfOwner = null;   // { key: clé mémoires, grid: taille de pas, name: nom du device }
function initPerfEngine() {
   perfTrack = host.createCursorTrack("MOVE_PERF_TRACK", "Move Perf", 0, 8, false);
   perfTrack.isPinned().markInterested();
   perfTrack.name().markInterested();
   var mode = null;
   try { mode = Java.type("com.bitwig.extension.controller.api.CursorDeviceFollowMode").FOLLOW_SELECTION; } catch (e1) {}
   if (!mode) { try { mode = com.bitwig.extension.controller.api.CursorDeviceFollowMode.FOLLOW_SELECTION; } catch (e2) {} }
   perfDev = mode ? perfTrack.createCursorDevice("MOVE_PERF_DEV", "Move Perf Device", 0, mode) : perfTrack.createCursorDevice();
   perfDev.isPinned().markInterested();
   perfDev.name().markInterested();
   perfDev.exists().markInterested();
   for (var p = 0; p < MEM_PAGES; p++) {
      perfPages[p] = perfDev.createCursorRemoteControlsPage("MovePerf" + p, 8, "");
      perfPages[p].selectedPageIndex().markInterested();
      perfPages[p].pageCount().markInterested();
      for (var k = 0; k < 8; k++) { perfPages[p].getParameter(k).name().markInterested(); perfPages[p].getParameter(k).exists().markInterested(); }
   }
   perfSlots = perfTrack.clipLauncherSlotBank();
   for (var i = 0; i < 8; i++) { perfSlots.getItemAt(i).isPlaying().markInterested(); perfSlots.getItemAt(i).isSelected().markInterested(); }
   perfClip = perfTrack.createLauncherCursorClip(PERF_STEPS, 1);
   perfClip.setStepSize(GRID_SIZES[S.gridIndex]);
   perfClip.scrollToStep(0);
   perfClip.addPlayingStepObserver(perfStepTick);
}
/** Épingle le moteur sur le device sélectionné (appelé quand on pose un preset sur un pas). */
function perfPinHere() {
   var key = memKey();
   if (perfOwner && perfOwner.key === key && perfOwner.grid === GRID_SIZES[S.gridIndex]) return;
   perfTrack.isPinned().set(false); perfDev.isPinned().set(false);
   perfTrack.selectChannel(cursorTrack);
   perfOwner = { key: key, grid: GRID_SIZES[S.gridIndex], name: cursorDevice.name().get() };
   host.scheduleTask(function () {
      perfTrack.isPinned().set(true);
      perfDev.selectDevice(cursorDevice);
      host.scheduleTask(function () {
         perfDev.isPinned().set(true);
         perfClip.setStepSize(perfOwner.grid);
         var n = Math.min(remotes.pageCount().get(), MEM_PAGES);
         for (var q = 0; q < n; q++) perfPages[q].selectedPageIndex().set(q);
      }, 80);
   }, 80);
}
function perfSlotIndex() {
   var i;
   for (i = 0; i < 8; i++) if (perfSlots.getItemAt(i).isPlaying().get()) return i;
   for (i = 0; i < 8; i++) if (perfSlots.getItemAt(i).isSelected().get()) return i;
   return -1;
}
/** La lecture du clip de la piste épinglée arrive sur un pas : rappel de son preset. */
function perfStepTick(st) {
   if (st < 0 || !S.isPlaying || !perfOwner || morph || memBusy) return;
   var all = memStore[STEPS_KEY]; if (!all) return;
   var mp = all[perfOwner.key + "|" + perfSlotIndex()]; if (!mp) return;
   var m = mp[(Math.round(st * perfOwner.grid * 1000) / 1000).toString()];
   if (m === undefined) return;
   var mem = (memStore[perfOwner.key] || {})[m];
   if (!mem || !mem.direct) return;
   if (mem.macros) {                                   // macros (modulateurs / FX imbriqués)
      for (var key in mem.macros) {
         var parts = key.split("/"), pg = parseInt(parts[0], 10), k = parseInt(parts[1], 10), e = mem.macros[key];
         if (pg >= MEM_PAGES || perfPages[pg].selectedPageIndex().get() !== pg) continue;
         var prm = perfPages[pg].getParameter(k);
         if (!prm.exists().get() || (e.n && String(prm.name().get()) !== e.n)) continue;
         prm.set(e.v);
      }
   }
   for (var id in mem.direct)                          // puis tous les paramètres du device
      perfDev.setDirectParameterValueNormalized(id, Math.round(mem.direct[id] * (MEM_RES - 1)), MEM_RES);
}

// ----------------------------------------------------------------------------
//  Morphing entre 2 presets : pad A tenu + pad B ; la pression (aftertouch) sur chaque pad
//  fait basculer : position = pression B / (pression A + pression B).
// ----------------------------------------------------------------------------
var memHeld = {}, memHeldOrder = [];   // pad -> mémoire, pads mémoire tenus (ordre d'appui)
var morph = null;
var MORPH_GAIN = 2.5;    // sensibilité : 1 = pression brute, 2.5 = mi-pression suffit pour aller au bout
var MORPH_CURVE = 0.6;   // < 1 : les pressions légères comptent davantage
var MORPH_SMOOTH = 0.85;  // lissage des mouvements (1 = aucun)
var MORPH_VEL_GAIN = 1.0;   // vélocité de frappe du 2e pad -> position de départ du morph
var MORPH_VEL_START = 0;    // part de la course donnée par la frappe (0 = départ toujours sur le 1)
var MORPH_QUICK_MS = 120; // relâchement plus rapide que ça = la valeur est figée                      // { padA, padB, A, B, pa, pb, t, dirty }
function memPadDown(i) { memHeld[i] = memIndex(i); memHeldOrder.push(i); }
function memPadUp(i) {
   delete memHeld[i];
   memHeldOrder = memHeldOrder.filter(function (p) { return p !== i; });
   if (!morph) return;
   if (i === morph.padA || morph.knob) return;         // lâcher le 1 ne change rien ; potard Volume : pads libres
   if (i === morph.padB) {                             // pad relâché : fin du morph, on reste où on est
      popup("Morph terminé à " + Math.round(morph.t * 100) + " %");
      if (morph.t > 0.97) setActivePreset(morph.mB);
      morph = null;
   }
}
function memOtherHeld(m) {
   for (var k = 0; k < memHeldOrder.length; k++) { var p = memHeldOrder[k]; if (memHeld[p] !== m) return memHeld[p]; }
   return -1;
}
function padOfMemory(m) { for (var p in memHeld) if (memHeld[p] === m) return parseInt(p, 10); return -1; }
/** État intermédiaire entre deux presets (t = 0 : A, 1 : B), au même format qu'une mémoire. */
function morphMix(A, B, t) {
   var out = { direct: {}, macros: {} }, k;
   for (k in A.direct) out.direct[k] = (k in B.direct) ? A.direct[k] + (B.direct[k] - A.direct[k]) * t : A.direct[k];
   for (k in B.direct) if (!(k in out.direct)) out.direct[k] = B.direct[k];
   var am = A.macros || {}, bm = B.macros || {};
   for (k in am) out.macros[k] = (bm[k] && bm[k].n === am[k].n) ? { v: am[k].v + (bm[k].v - am[k].v) * t, n: am[k].n } : am[k];
   for (k in bm) if (!out.macros[k]) out.macros[k] = bm[k];
   return out;
}
function startMorph(mA, mB, A, B) {
   activePreset.m = -1;
   // Le morph démarre tout de suite (le 1er doigt peut rester posé) : la pression du 2e pad
   // donne la position, toujours dans le sens 1 → 2.
   morph = { padA: padOfMemory(mA), padB: padOfMemory(mB), mA: mA, mB: mB, A: A, B: B, t: 0, dirty: false, sent: -1, active: true, hist: [] };
   // Démarrage immédiat : la vélocité de frappe du 2e pad donne la 1re position, sans attendre
   // que l'aftertouch arrive (il ne démarre qu'après un petit temps sur la Move)
   morph.t = Math.pow(Math.min(1, (lastVelocity / 127) * MORPH_VEL_GAIN), MORPH_CURVE) * MORPH_VEL_START;
   morph.hist.push({ time: new Date().getTime(), t: morph.t });
   host.scheduleTask(applyMorph, 0);
   popup("Morph " + (mA + 1) + " → " + (mB + 1) + " : la pression du " + (mB + 1) + " fait le mouvement");
}
function onMorphPressure(pad, v) {
   if (!morph) return;
   if (!morph.active || pad !== morph.padB || morph.knob) return;   // seule la pression du 2e pad compte (sauf potard)
   // Sensibilité : courbe qui amplifie les pressions légères (MORPH_GAIN, MORPH_CURVE)
   var target = Math.pow(Math.min(1, (v / 127) * MORPH_GAIN), MORPH_CURVE);
   morph.t = morph.t + (target - morph.t) * MORPH_SMOOTH;   // lissage : pas de sauts brusques
   var now = new Date().getTime();
   morph.hist.push({ time: now, t: morph.t });
   while (morph.hist.length && now - morph.hist[0].time > 600) morph.hist.shift();
   if (!morph.dirty) { morph.dirty = true; host.scheduleTask(applyMorph, 12); }   // réactif (~80 mises à jour / s max)
}
function applyMorph() {
   if (!morph) return;
   morph.dirty = false;
   var t = Math.round(morph.t * 100) / 100;
   if (t === morph.sent) return;
   morph.sent = t;
   var A = morph.A, B = morph.B, key, a, b;
   if (A.macros && B.macros) {                          // macros (modulateurs / FX imbriqués) d'abord
      var mix = {};
      for (key in B.macros) if (A.macros[key] && A.macros[key].n === B.macros[key].n) {
         a = A.macros[key].v; b = B.macros[key].v;
         if (Math.abs(a - b) > 0.0005) mix[key] = { v: a + (b - a) * t, n: B.macros[key].n };
      }
      memRecallMacros(mix);
   }
   for (key in B.direct) {                              // puis les paramètres du device
      if (!(key in A.direct) || !(key in devParams)) continue;
      a = A.direct[key]; b = B.direct[key];
      if (Math.abs(a - b) < 0.0005) continue;           // identiques : rien à faire
      cursorDevice.setDirectParameterValueNormalized(key, Math.round((a + (b - a) * t) * (MEM_RES - 1)), MEM_RES);
   }
   if (Math.round(t * 100) % 10 === 0) popup("Morph " + (morph.labelA || (morph.mA + 1)) + " → " + (morph.mB + 1) + " : " + Math.round(t * 100) + " %");
}

// mode Preset : les pas ne servent qu'aux presets (jamais aux notes)
//  appui court = met le dernier preset utilisé (ou le retire s'il y est déjà)
//  pas maintenu + pad preset = met ce preset ; Delete + pas = retire le preset
var perfHeld = {}, memLast = -1;
function perfHeldList() { var o = []; for (var k in perfHeld) o.push(parseInt(k, 10)); return o; }
function onPerfStep(x, on) {
   if (on && isEmptySlotMode()) { popup("Pas de clip : crée d'abord un clip pour y placer des presets"); return; }
   if (on) {
      if (S.del) { if (stepPresetAt(x) >= 0) setStepPreset(x, -1); else popup("Pas " + (x + 1) + " : aucun preset"); return; }
      perfHeld[x] = "down";
      return;
   }
   var st = perfHeld[x];
   delete perfHeld[x];
   if (st !== "down") return;                         // un pad preset a été choisi pendant l'appui
   if (memClipboard && memClipIdx >= 0) {             // Copy + pad preset, puis pas : le preset va sur le pas
      setStepPreset(x, memClipIdx);
      popup("Preset " + (memClipIdx + 1) + " sur le pas " + (x + 1) + " (le pad reste intact)");
      memClipboard = null; memClipIdx = -1; host.requestFlush();
      return;
   }
   if (memLast < 0) { popup("Choisis d'abord un preset (pad), ou maintiens le pas + pad preset"); return; }
   if (stepPresetAt(x) === memLast) { setStepPreset(x, -1); return; }
   setStepPreset(x, memLast);
   popup("Preset " + (memLast + 1) + " sur le pas " + (x + 1));
}

/** Enregistre l'état complet du device dans la mémoire m. */
function memStoreNow(m, name) {
   seedFromRemotes();       // (la page affichée a déjà été lue avant le parcours des pages)
   var snap = memSnapshotDirect(), tot = Object.keys(devParams).length;
   snap.macros = JSON.parse(JSON.stringify(macroCache));
   var nm = Object.keys(snap.macros).length;
   if (snap.count === 0 && nm === 0) { popup(name + " : paramètres pas encore reçus, réessaie"); return; }
   memSlots(true)[m] = snap; memSave(); memLast = m; setActivePreset(m);
   popup(name + " — mémoire " + (m + 1) + " enregistrée (" + snap.count + " / " + tot + " paramètres, " + nm + " macros)");
}

/** Index de pad Drum (0..31) : 4x4 gauche = 0..15, 4x4 droite = 16..31, en partant du bas. */
function drumIndex(i) {
   var row = Math.floor(i / 8), col = i % 8;
   return col < 4 ? row * 4 + col : 16 + row * 4 + (col - 4);
}

/** Hauteur jouée par un pad en mode Note (-1 = aucune). */
function padPitch(i) {
   var p;
   if (S.isDrum) {
      p = S.drumBase + drumIndex(i);
   } else {
      var row = Math.floor(i / 8), col = i % 8;
      var base = 12 * (S.octave + 2) + S.root; // octave 1 -> 36 (C1, convention 60 = C3)
      if (S.inKey) {
         var iv = SCALES[S.scaleIndex].iv;
         var degree = col + row * 3;        // rangées décalées d'une quarte (3 degrés)
         p = base + 12 * Math.floor(degree / iv.length) + iv[degree % iv.length];
      } else {
         p = base + col + row * 5;          // chromatique, quartes
      }
   }
   return (p >= 0 && p < 128) ? p : -1;
}

/** Session horizontale : rangée = piste (haut = bouton de piste 1), colonne = scène. */
function sessionSlot(i) {
   var rowFromTop = 3 - Math.floor(i / 8), col = i % 8;
   if (fxGrid()) {                                    // vue FX / Master : rangées 1-3 = pistes FX, 4 = vide
      if (rowFromTop > 2) return { track: masterTrack, slot: null };
      return { track: fxBank.getItemAt(rowFromTop), slot: fxBank.getItemAt(rowFromTop).clipLauncherSlotBank().getItemAt(col) };
   }
   return { track: trackBank4.getItemAt(rowFromTop),
            slot: trackBank4.getItemAt(rowFromTop).clipLauncherSlotBank().getItemAt(col) };
}

function onSessionPad(i) {
   if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
   var ref = sessionSlot(i), track = ref.track, slot = ref.slot;
   if (nsPress) nsPress.used = true;                  // clip choisi pendant Note/Session tenu
   if (DEBUG && !fxGrid() && track.isGroup().get()) { // diagnostic (console seulement) : couleurs reçues pour un groupe
      var tc = track.color(), sc = slot.color();
      var rgb = function (c) { return Math.round(c.red() * 255) + "," + Math.round(c.green() * 255) + "," + Math.round(c.blue() * 255); };
      println("Groupe " + track.name().get() + " : piste " + rgb(tc) + " / slot " + rgb(sc) + " / contenu " + slot.hasContent().get());
   }
   if (fxCtl && !fxGrid()) exitFxCtl(false);          // clip d'une piste : on quitte le mode Send
   if (!slot) { popup("Master : pas de clips"); return; }
   if (S.del)        { dropStepPresets(track.name().get(), i % 8); rememberDeletedClip(slot); slot.deleteObject(); return; }
   // Copy + pad source, puis pad de destination (Copy tenu ou relâché), comme sur la Move
   if (S.copy && !S.slotClipboard) {
      if (slot.hasContent().get()) { S.slotClipboard = slot; popup("Clip copié — choisis le pad de destination"); }
      else popup("Ce slot est vide");
      return;
   }
   if (S.slotClipboard) {
      slot.replaceInsertionPoint().copySlotsOrScenes(S.slotClipboard);
      S.slotClipboard = null;
      playNewClip(slot);
      popup("Clip collé (lecture)");
      return;
   }
   if (S.mute)       { track.mute().toggle(); return; }
   var wasArmed = track.arm().get();          // armement AVANT la sélection (qui arme la piste)
   // Comme sur la Move : le pad sélectionne le clip (et sa piste, qui est armée).
   selectTrackFromMove(track);
   slot.select();
   S.sessionSel = slot;                       // utilisé par Record en mode Session
   if (S.shift) { popup("Clip sélectionné (sans lancer)" + (S.loopMode ? " — vue Loop" : "")); return; }
   if (slot.hasContent().get()) { slot.launch(); return; }
   // Pad vide, comme dans Bitwig : piste armée = enregistre ; pas armée = stop.
   // Le pad arme la piste : un 2e appui sur le slot vide lance l'enregistrement.
   if (wasArmed) { slot.launch(); popup("Enregistrement dans le slot"); }
   else { track.stop(); popup("Piste arrêtée (pas armée : Sample pour armer, puis le slot pour enregistrer)"); }
}

function onStep32Pad(i) {
   var row = Math.floor(i / 8), col = i % 8;
   var step = (3 - row) * 8 + col;          // pas 1 en haut à gauche
   if (S.del) clip32.clearStep(HW.CHANNEL, step, S.selectedPitch);
   else clip32.toggleStep(HW.CHANNEL, step, S.selectedPitch, velocity());
}


// ============================================================================
//  8. BOUTONS DE PAS
// ============================================================================

/** Navigateur ouvert : les pas 1-8 choisissent la colonne active.
 *  1 Type · 2 Catégorie · 3 Créateur · 4 Tag · 5 Emplacement · 6 Fichier · 7 Favoris · 8 Résultats */
// 1 Type de composant · 2 Emplacement · 3 Type de fichier · 4 Catégorie · 5 Créateur ·
// 6 Interface · 7 Tags · 8 Résultats · 16 = Favoris on / off (jaune quand actif)
var BROWSER_STEP_COLS = [null, 4, null, 1, 2, null, 3, -1, null, null, null, null, null, null, null, "fav"];   // 1, 3, 6 : non pilotables par l'API
/** Favoris : élément « Favoris » de la colonne des collections, sélectionné ou non. */
function favItem() {
   var fb = filterBanks[6];
   if (!fb) return null;
   for (var i = 0; i < 32; i++) { var it = fb.bank.getItemAt(i); if (/favori|favorite/i.test(String(it.name().get()))) return it; }
   return null;
}
function favActive() { if (favAction) return favOn; var it = favItem(); try { return !!(it && it.isSelected().get()); } catch (e) { return false; } }
var FAV_DIM = 79;  // pas 16 (Favoris) : jaune atténué quand inactifs
var favAction = null, favActionScanned = false, favOn = false;
/** Action Bitwig « Commuter affichage favoris » (raccourci clavier du navigateur). */
function findFavAction() {
   if (favActionScanned) return favAction;
   favActionScanned = true;
   var acts = application.getActions();
   for (var i = 0; i < acts.length; i++) {
      var t = String(acts[i].getId()) + " " + String(acts[i].getName());
      if (/favori|favorite/i.test(t)) { println("Action favoris : " + t); if (!favAction) favAction = acts[i]; }
   }
   return favAction;
}
function toggleFavorites() {
   var fa = findFavAction();
   if (fa) {                                          // la commande de Bitwig (comme au clavier)
      fa.invoke(); favOn = !favOn;
      popup("Favoris : " + (favOn ? "ON" : "OFF") + " (" + String(fa.getName()) + ")");
      browserScriptMove = new Date().getTime();
      host.scheduleTask(showBrowserState, 300); host.requestFlush();
      return;
   }
   var it = favItem();
   if (!it) { popup("Favoris introuvables dans ce navigateur"); return; }
   if (favActive()) { filterBanks[6].wild.isSelected().set(true); popup("Favoris : OFF"); }
   else { it.isSelected().set(true); popup("Favoris : ON"); }
   browserScriptMove = new Date().getTime();
   host.scheduleTask(showBrowserState, 300);
   host.requestFlush();
}
function onBrowserStep(x) {
   var k = BROWSER_STEP_COLS[x];
   if (k === null || k === undefined) return;
   if (k === "fav") { toggleFavorites(); return; }
   if (k === "type") browserCol = 0;
   else if (k === -1) browserCol = browserSteps.length - 1;
   else {
      if (!browserCols[k] || !browserCols[k].exists().get()) { popup(BROWSER_LABELS[k] + " : indisponible ici"); return; }
      browserSteps[1] = k; browserCol = 1; browserIdx[String(k)] = null;
   }
   browserScriptMove = new Date().getTime();
   popup("Colonne active : " + browserStepName(browserCol) + " — molette pour défiler, clic pour valider");
   host.scheduleTask(showBrowserState, 400);
   host.requestFlush();
}
function flushBrowserSteps() {
   for (var x = 0; x < 16; x++) {
      var c = COLOR.OFF;
      if (BROWSER_STEP_COLS[x] === "fav") { sendNote(HW.STEP_FIRST_NOTE + x, favActive() ? 8 : FAV_DIM); continue; }   // jaune : vif = actifs, atténué = non
      if (BROWSER_STEP_COLS[x] !== null && BROWSER_STEP_COLS[x] !== undefined) {
         var k = BROWSER_STEP_COLS[x], active;
         if (k === "type") active = browserCol === 0;
         else if (k === -1) active = browserCol === browserSteps.length - 1;
         else active = browserCol === 1 && browserSteps[1] === k;
         var avail = (k === "type" || k === -1) || (browserCols[k] && browserCols[k].exists().get());
         c = active ? COLOR.WHITE : (avail ? COLOR.DIM : COLOR.OFF);
      }
      sendNote(HW.STEP_FIRST_NOTE + x, c);
   }
}
function onStepButton(x, on) {
   if (browsing) { if (on) onBrowserStep(x); return; }    // navigateur : pas = colonnes
   // Shift + Pas 16 maintenu : le relâchement quantifie (sauf si on a réglé avec la molette)
   if (!on && x === 15 && q16.held) {
      var wasUsed = q16.used; q16 = { held: false, used: false };
      if (!wasUsed) { clip16.quantize(QUANTIZE_AMOUNT); popup("Quantize " + Math.round(QUANTIZE_AMOUNT * 100) + " % appliqué"); }
      return;
   }
   // Vue Loop (Note ou Session) : les pas sont les mesures, même avec Shift (pas de fonctions)
   if (S.mode !== MODE.STEP32 && (S.loopMode || S.loop)) { onLoopStep(x, on); return; }
   if (on && S.shift) { shiftStep(x); return; }
   if (scaleMode && !chordLock && S.mode === MODE.NOTE) { onScaleStep(x, on); return; }   // pas = fondamentale / mode

   if (S.mode === MODE.SESSION) {
      if (!on) return;
      if (x < 8) trackBank4.sceneBank().getScene(x).launch();        // pas 1-8 : scènes (colonnes)
      else if (x === 15) {                                            // pas 16 : stop de TOUTES les pistes
         for (var k = 0; k < ARM_BANK_SIZE; k++) armBank.getItemAt(k).stop();
         for (var kf = 0; kf < 3; kf++) fxBank.getItemAt(kf).stop();
         popup("Stop de tous les clips");
      }
      return;
   }
   if (S.mode === MODE.STEP32) return;
   if (memLock && S.mode === MODE.NOTE && !S.loopMode && !S.loop) { onPerfStep(x, on); return; }   // Perf : presets seulement
   if (fxCtl && S.mode === MODE.NOTE) { if (on) popup("Mode Send : pas de séquenceur (Shift + Note/Session pour revenir)"); return; }

   // MODE NOTE
   if (S.loopMode || S.loop) { onLoopStep(x, on); return; }
   if (on) {
      if (S.del && memLock && stepPresetAt(x) >= 0) { setStepPreset(x, -1); return; }   // efface le preset du pas
      if (S.del) { clip16.clearStepsAtX(HW.CHANNEL, x); return; }
      if (S.copy) { selectCopySteps(x); return; }
      if (S.clipboard) { pasteSteps(x); return; }
      if (S.mute) { muteStep(x); return; }
      // Pas de clip : la 1re note posée crée un clip d'une mesure, lancé tout de suite
      if (isEmptySlotMode()) { bufferStep(x); return; }

      S.heldSteps[x] = { created: false, edited: false, pos: x };

      var pads = heldPadPitches();
      if (pads.length) {                    // pads maintenus + pas : ajoute/retire ces notes
         for (var k = 0; k < pads.length; k++) clip16.toggleStep(HW.CHANNEL, x, pads[k], velocity());
         S.heldSteps[x].edited = true;
         return;
      }
      if (data16[S.selectedPitch][x] === 0) {
         clip16.setStep(HW.CHANNEL, x, S.selectedPitch, velocity(), GRID_SIZES[S.gridIndex]);
         S.heldSteps[x].created = true;
      }
   } else {
      var h = S.heldSteps[x];
      delete S.heldSteps[x];
      // Appui court sur un pas déjà rempli, sans édition : on efface
      // (drum : la note du pad sélectionné ; instrument : toutes les notes du pas, comme la Move)
      if (h && !h.created && !h.edited) {
         if (S.isDrum) clip16.clearStep(HW.CHANNEL, x, S.selectedPitch);
         else clip16.clearStepsAtX(HW.CHANNEL, x);
      }
   }
}

/** Copy maintenu + pas (ou pas de début puis pas de fin) : met la plage en mémoire. */
function selectCopySteps(x) {
   if (S.copySel < 0) { S.copySel = x; S.clipboard = { a: x, b: x }; }
   else S.clipboard = { a: Math.min(S.copySel, x), b: Math.max(S.copySel, x) };
   var c = S.clipboard;
   popup("Copie : pas " + (c.a + 1) + (c.b > c.a ? "–" + (c.b + 1) : "") + " — relâche Copy, puis choisis la destination");
}

/** Colle la plage copiée à partir du pas x (remplace le contenu de destination). */
function pasteSteps(x) {
   var c = S.clipboard, notes = [], o, y;
   for (o = 0; o <= c.b - c.a; o++) {
      for (y = 0; y < 128; y++) {
         if (data16[y][c.a + o] === 2) {
            var n = clip16.getStep(HW.CHANNEL, c.a + o, y);
            notes.push({ o: o, y: y, v: Math.round(n.velocity() * 127), d: n.duration() });
         }
      }
   }
   for (o = 0; o <= c.b - c.a && x + o < 16; o++) clip16.clearStepsAtX(HW.CHANNEL, x + o);
   for (var k = 0; k < notes.length; k++) {
      if (x + notes[k].o < 16) clip16.setStep(HW.CHANNEL, x + notes[k].o, notes[k].y, notes[k].v, notes[k].d);
   }
   popup("Collé au pas " + (x + 1));
   S.clipboard = null;
}

/** Pas maintenu + flèches : déplace (nudge d'un pas entier) ou transpose les notes. */
function moveHeldNotes(dx, dy) {
   var held = heldStepList();
   for (var k = 0; k < held.length; k++) {
      var h = S.heldSteps[held[k]], from = h.pos;
      if (from + dx < 0 || from + dx > 15) continue;
      for (var y = 0; y < 128; y++) {
         if (data16[y][from] !== 2) continue;
         if (S.isDrum && y !== S.selectedPitch) continue;
         if (y + dy < 0 || y + dy > 127) continue;
         clip16.moveStep(HW.CHANNEL, from, y, dx, dy);
      }
      h.pos = from + dx;
      h.edited = true;
   }
   if (S.isDrum && dy) S.selectedPitch = clamp(S.selectedPitch + dy, 0, 127);
   popup(dx ? "Nudge " + (dx > 0 ? "→" : "←") + " (1 pas)" : "Transposition " + (dy > 0 ? "+" : "") + dy);
}

function muteStep(x) {
   forEachNoteAt(x, function (n) { n.setIsMuted(!n.isMuted()); });
}

/** Shift + pas : réglages globaux (mêmes numéros que sur la Move). */
var step1Pending = 0;           // Shift + Pas 1 : attente d'un éventuel double appui
var step2Pending = 0;           // Shift + Pas 2 : idem
var step11Pending = 0;          // Shift + Pas 11 : idem

var uiBusyUntil = 0;   // navigateur / nouvelle piste en cours d'ouverture : pas de zoom ni de focus
function markUiBusy(ms) { uiBusyUntil = Math.max(uiBusyUntil, new Date().getTime() + (ms || 2500)); }
function uiBusy() { return browsing || new Date().getTime() < uiBusyUntil; }

function shiftStep(x) {
   // Les gestes qui ouvrent le navigateur ou créent une piste quittent d'abord la vue Loop
   // (sinon Bitwig recevait focus / zoom pendant l'ouverture du navigateur).
   if ([1, 2, 4, 11].indexOf(x + 1) >= 0) {
      markUiBusy();
      if (S.loopMode) setLoopMode(false);
   }
   switch (x + 1) {
      case 1: {                    // nouvelle piste MIDI (+ navigateur) ; double appui : piste audio
         var now = new Date().getTime();
         if (step1Pending && now - step1Pending < 400) {
            step1Pending = 0;
            newTrack("audio");
         } else {
            var stamp = now;
            step1Pending = stamp;
            host.scheduleTask(function () {
               if (step1Pending !== stamp) return;   // un 2e appui est arrivé
               step1Pending = 0;
               newTrack("instrument");
            }, 400);
         }
         break;
      }
      case 2: {                    // nouveau device après ; double appui : DANS le conteneur
         var now2 = new Date().getTime();
         if (step2Pending && now2 - step2Pending < 400) {
            step2Pending = 0;
            openBrowser("inside");
         } else {
            var stamp2 = now2;
            step2Pending = stamp2;
            host.scheduleTask(function () {
               if (step2Pending !== stamp2) return;
               step2Pending = 0;
               openBrowser("after");
            }, 400);
         }
         break;
      }
      case 3:  // Grille : molette = grille (1/64 … 1/4, triolets), Shift + molette = force du Quantize
         S.wheelMode = WHEEL.WORKFLOW;
         popup("Molette = grille (" + GRID_NAMES[S.gridIndex] + ") — Shift + molette = Quantize " + Math.round(QUANTIZE_AMOUNT * 100) + " % — Back pour finir");
         break;
      case 5:                                                           // Tempo à la molette : 2e appui = sortie
         if (S.wheelMode === WHEEL.TEMPO) { setDeviceWheel(); popup("Tempo : molette rendue aux devices"); }
         else { S.wheelMode = WHEEL.TEMPO; popup("Tempo : " + transport.tempo().displayedValue().get() + " (Shift + Pas 5 pour sortir)"); }
         break;
      case 6:  transport.isMetronomeEnabled().toggle(); break;
      case 7:  S.wheelMode = WHEEL.GROOVE; groove.getEnabled().set(1); popup("Groove : molette"); break;
      case 9:                                                           // mode chords / scale
         if (chordsReady()) toggleScaleMode(); else popup("Mode chords indisponible : " + (CHORDS_ERROR || "section non chargée"));
         break;
      case 10:
         S.fullVelocity = !S.fullVelocity;
         updateNoteInput();
         popup("Vélocité pleine : " + (S.fullVelocity ? "ON" : "OFF"));
         break;
      case 4:  openBrowser("replace"); break;                         // presets du device sélectionné
      case 8:                                                         // mode « 32 pas » (v1)
         S.mode = (S.mode === MODE.STEP32) ? MODE.NOTE : MODE.STEP32;
         S.heldSteps = {}; S.heldPads = {};
         updateNoteInput(); updateIndications();
         popup("Mode " + S.mode);
         break;
      case 11: {                   // « Arp » : effet de note avant l'instrument ; double : début de la couche
         var now11 = new Date().getTime();
         if (step11Pending && now11 - step11Pending < 400) {
            step11Pending = 0;
            openBrowser("insideStart");
         } else {
            var stamp11 = now11;
            step11Pending = stamp11;
            host.scheduleTask(function () {
               if (step11Pending !== stamp11) return;
               step11Pending = 0;
               openBrowser("beforeInstrument");
            }, 400);
         }
         break;
      }
      case 14: createClipInNextSlot(); break;
      case 15: doubleClip(); break;                                   // raccourci natif Move : doubler la boucle
      case 16:                                                        // Quantize : au relâchement si la molette n'a pas servi
         q16 = { held: true, used: false };
         popup("Quantize " + Math.round(QUANTIZE_AMOUNT * 100) + " % — grille " + GRID_NAMES[S.gridIndex] +
               "  (Shift + molette = %, pas 16 tenu + molette = grille)");
         break;
   }
}

function doubleClip() {
   clip16.duplicateContent();
   host.scheduleTask(function () {
      popup("Boucle doublée : " + Math.round(clip16.getLoopLength().get() / 4) + " mesure(s)");
   }, 80);
}

function createClipInNextSlot() {
   if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
   for (var i = 0; i < 8; i++) {
      var slot = cursorSlots.getItemAt(i);
      if (slot.exists().get() && !slot.hasContent().get()) {
         // Pas de clip créé : on arrête le clip en cours, on se place sur le slot vide,
         // piste armée, prêt à enregistrer ou à écrire au séquenceur
         // Arrêt IMMÉDIAT du clip en cours : lancer un slot vide sur une piste non armée
         // arrête la piste ; avec la quantification « none », c'est instantané. On désarme le
         // temps du lancement (sinon Bitwig enregistrerait), puis on réarme.
         cursorTrack.arm().set(false);
         slot.select();
         try { slot.launchWithOptions("none", "default"); } catch (e) { cursorTrack.stop(); }
         host.scheduleTask(function () { armByUser(); cursorTrack.arm().set(true); }, 80);
         popup("Slot " + (i + 1) + " prêt — Record pour enregistrer, ou pose une note avec les pas");
         return;
      }
   }
   makeRoomSlot(createClipInNextSlot);
}

/** Loop : appui seul = entre/sort de la vue Loop (pas = mesures), comme sur la Move.
 *  Loop maintenu + molette = longueur de boucle. Shift/Duplicate + Loop = doubler. */
function onLoopButton(pressed) {
   if (pressed) {
      S.loop = true; S.loopUsed = false;
      if (S.shift) {                                                           // Shift + Loop
         S.loopUsed = true;
         var nowL = new Date().getTime();
         if (shiftLoopPending && nowL - shiftLoopPending < 400) {                // ×2 : boucle du clip on/off
            shiftLoopPending = 0;
            clip16.isLoopEnabled().toggle();
            host.scheduleTask(function () { popup("Boucle du clip : " + (clip16.isLoopEnabled().get() ? "activée" : "désactivée")); }, 80);
         } else {                                                              // simple : panneau éditeur de notes
            var stamp = nowL; shiftLoopPending = stamp;
            host.scheduleTask(function () {
               if (shiftLoopPending !== stamp) return;
               shiftLoopPending = 0;
               if (bottomPanel === "note") { panelShowDevices(); popup("Panneau du bas : Devices"); }
               else { panelShowNote(); popup("Panneau du bas : éditeur de notes"); }
            }, 400);
         }
      }
      else if (S.copy) { doubleClip(); S.loopUsed = true; S.copyUsed = true; } // Copy + Loop : doubler
   } else {
      S.loop = false;
      if (!S.loopUsed && S.mode !== MODE.STEP32) setLoopMode(!S.loopMode);
   }
}

function stepsPerBar() { return Math.round(4 / GRID_SIZES[S.gridIndex]); }

/** Pas (0..15) de la page affichée qui appartiennent à la mesure « bar ». */
function barSteps(bar) {
   var out = [], spb = stepsPerBar(), start = bar * spb - S.page16 * 16;
   for (var k = 0; k < spb; k++) if (start + k >= 0 && start + k < 16) out.push(start + k);
   return out;
}

/** Affiche la mesure « bar » dans les pas. */
function showBar(bar) {
   S.page16 = Math.floor(bar * stepsPerBar() / 16);
   clip16.scrollToStep(S.page16 * 16);
}

/** Change le début de boucle. Tant qu'on n'a pas déplacé le point de lecture (il est au
 *  même endroit que le début de boucle), il suit le début de boucle. */
/** Vue Loop : cadre l'éditeur de notes sur la boucle (après un petit délai, pour que Bitwig
 *  ait appliqué le changement ; plusieurs changements rapprochés = un seul cadrage). */
var zoomLoopGen = 0;
function zoomLoopSoon() {
   var gen = ++zoomLoopGen;
   host.scheduleTask(function () {
      if (gen !== zoomLoopGen || !S.loopMode || uiBusy()) return;
      application.focusPanelBelow();
      // Cadre aussi les NOTES (hauteur) : on sélectionne les notes de la boucle puis
      // « zoom sur la sélection » ; sans note : tout afficher.
      var ls = clip16.getLoopStart().get(), ll = clip16.getLoopLength().get(), first = true;
      var x0 = Math.round(ls / CAPTURE.RESOLUTION), x1 = Math.round((ls + ll) / CAPTURE.RESOLUTION);
      for (var key in capData) {
         if (capData[key] !== 2) continue;
         var pr = key.split(","), x = parseInt(pr[0], 10), y = parseInt(pr[1], 10);
         if (x < x0 || x >= x1) continue;
         try { captureClip.selectStepContents(HW.CHANNEL, x, y, first); first = false; } catch (e) { break; }
      }
      if (first) application.zoomToFit(); else application.zoomToSelection();
   }, 250);
}
function setLoopStartLinked(v) {
   zoomLoopSoon();
   var linked = Math.abs(clip16.getPlayStart().get() - clip16.getLoopStart().get()) < 0.001;
   clip16.getLoopStart().set(v);
   if (linked) clip16.getPlayStart().set(v);
}

function onLoopStep(x, on) {
   if (!on) { if (S.loopHeldBar === x) { S.loopHeldBar = -1; loopNudge = false; S.playStartTouched = false; } return; }
   if (S.del) { clearBar(x); return; }
   // Copie de mesures (comme la copie de pas) : Copy + mesure (ou mesure de début puis de fin),
   // puis mesure de destination (Copy tenu ou relâché). Copy à nouveau = annule.
   if (S.copy && !S.barClip) { selectCopyBars(x); return; }
   if (S.copy && S.barClip && S.copySel >= 0 && S.barClipHold) { selectCopyBars(x); return; }   // étend la plage
   if (S.barClip) { pasteBars(x); return; }
   // Pas de début maintenu + pas de fin : nouvelle boucle
   if (S.loopHeldBar >= 0 && S.loopHeldBar !== x) {
      var a = Math.min(S.loopHeldBar, x), b = Math.max(S.loopHeldBar, x);
      setLoopStartLinked(a * 4);
      clip16.getLoopLength().set((b - a + 1) * 4);
      popup("Boucle : mesures " + (a + 1) + "–" + (b + 1));
      return;
   }
   S.loopHeldBar = x;
   var now = new Date().getTime();
   if (S.loopTap.x === x && now - S.loopTap.t < 400) {   // double appui : boucle d'une mesure
      setLoopStartLinked(x * 4);
      clip16.getLoopLength().set(4);
      popup("Boucle : mesure " + (x + 1));
      S.loopTap = { x: -1, t: 0 };
   } else {
      S.loopTap = { x: x, t: now };
      showBar(x);
   }
}

/** Vue Loop : Copy + mesure(s) -> plage de mesures en mémoire. */
function selectCopyBars(x) {
   if (S.copySel < 0) { S.copySel = x; S.barClip = { a: x, b: x }; S.barClipHold = true; }
   else S.barClip = { a: Math.min(S.copySel, x), b: Math.max(S.copySel, x) };
   var c = S.barClip;
   popup("Copie : mesure" + (c.b > c.a ? "s " + (c.a + 1) + "–" + (c.b + 1) : " " + (c.a + 1)) + " — choisis la mesure de destination");
}
/** Colle les mesures copiées à partir de la mesure x (remplace son contenu). */
function pasteBars(x) {
   var c = S.barClip, per = Math.round(4 / CAPTURE.RESOLUTION), width = Math.round(CAPTURE.MAX_BARS * 4 / CAPTURE.RESOLUTION);
   S.barClip = null; S.barClipHold = false;
   if (x === c.a) { popup("Même mesure : rien à coller"); return; }
   var notes = [], k, xs, y, len = (c.b - c.a + 1) * per;
   for (k in capData) {
      if (capData[k] !== 2) continue;
      var parts = k.split(","); xs = parseInt(parts[0], 10); y = parseInt(parts[1], 10);
      if (xs < c.a * per || xs >= c.a * per + len) continue;
      var st = captureClip.getStep(HW.CHANNEL, xs, y);
      notes.push({ o: xs - c.a * per, y: y, v: Math.max(1, Math.round(st.velocity() * 127)), d: st.duration() });
   }
   captureClip.scrollToStep(0);
   for (var o = 0; o < len; o++) { xs = x * per + o; if (xs < width) captureClip.clearStepsAtX(HW.CHANNEL, xs); }
   var n = 0;
   for (k = 0; k < notes.length; k++) {
      xs = x * per + notes[k].o;
      if (xs >= width) continue;
      captureClip.setStep(HW.CHANNEL, xs, notes[k].y, notes[k].v, notes[k].d); n++;
   }
   popup("Collé : mesure" + (c.b > c.a ? "s " : " ") + (c.a + 1) + (c.b > c.a ? "–" + (c.b + 1) : "") + " → " + (x + 1) + " (" + n + " notes)");
}

/** Delete + mesure (vue Loop) : efface les notes de cette mesure. */
function clearBar(bar) {
   var spb = stepsPerBar(), start = bar * spb, back = S.page16 * 16;
   clip16.scrollToStep(start);
   host.scheduleTask(function () {
      for (var k = 0; k < Math.min(16, spb); k++) clip16.clearStepsAtX(HW.CHANNEL, k);
      if (spb > 16) {
         clip16.scrollToStep(start + 16);
         host.scheduleTask(function () {
            for (var k2 = 0; k2 < spb - 16; k2++) clip16.clearStepsAtX(HW.CHANNEL, k2);
            clip16.scrollToStep(back);
         }, 60);
      } else clip16.scrollToStep(back);
   }, 60);
   popup("Mesure " + (bar + 1) + " effacée");
}

/** Mute seul (mode Note) : coupe la piste sélectionnée. Mute + … : combinaisons. */
/** Mute (M) appuyé seul :
 *   M                  mute / unmute de la piste sélectionnée
 *   Shift + M          solo / unsolo de la piste sélectionnée
 *   double appui M     retire TOUS les mutes du projet
 *   Shift + double M   retire TOUS les solos du projet  */
function onMuteButton(pressed) {
   if (pressed) { S.mute = true; S.muteUsed = false; return; }
   S.mute = false;
   if (S.muteUsed) return;
   var now = new Date().getTime();
   if (now - lastMuteTap < 400) {               // double appui
      lastMuteTap = 0;
      if (S.shift) { project.unsoloAll(); popup("Tous les solos retirés"); }
      else { project.unmuteAll(); popup("Tous les mutes retirés"); }
      return;
   }
   lastMuteTap = now;
   if (S.shift) {
      cursorTrack.solo().toggle();
      popup("Solo " + (cursorTrack.solo().get() ? "OFF" : "ON") + " : " + cursorTrack.name().get());
   } else {
      cursorTrack.mute().toggle();
      popup("Piste " + (cursorTrack.mute().get() ? "réactivée" : "coupée") + " : " + cursorTrack.name().get());
   }
}

/** Delete seul : supprime le clip qui joue sur la piste (sinon le clip sélectionné).
 *  Shift + Delete : vide les notes du clip. */
function onDeleteButton(pressed) {
   if (pressed) {
      S.del = true; S.delUsed = false;
      return;
   }
   S.del = false;
   if (S.delUsed) return;
   // Shift + Delete (sans autre geste) : vide les notes du clip. Au relâchement, pour que
   // Shift + Delete + pad (effacer une mémoire) ne vide pas le clip.
   if (S.shift && S.mode === MODE.NOTE) { clip16.clearSteps(); popup("Clip vidé"); return; }
   var target = null, i, sl;
   for (i = 0; i < 8 && !target; i++) { sl = cursorSlots.getItemAt(i); if (sl.isPlaying().get()) target = sl; }
   for (i = 0; i < 8 && !target; i++) {
      sl = cursorSlots.getItemAt(i);
      if (sl.isSelected().get() && sl.hasContent().get()) target = sl;
   }
   if (target) {
      for (i = 0; i < 8; i++) if (cursorSlots.getItemAt(i) === target) dropStepPresets(cursorTrack.name().get(), i);
      rememberDeletedClip(target); target.deleteObject(); popup("Clip supprimé");
   }
   else popup("Aucun clip à supprimer");
}


/**
 * Record sur la piste sélectionnée :
 *  - un clip est en train d'enregistrer  -> fin de l'enregistrement, le clip joue
 *  - un clip joue                         -> overdub on/off dans ce clip
 *  - aucun clip ne joue                   -> enregistre un nouveau clip dans le slot
 *    sélectionné s'il est vide, sinon dans le premier slot vide
 */
function onRecordClip() {
   armByUser();                                     // armement demandé (Record) : gardé en Session
   if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
   if (S.mode === MODE.SESSION && S.sessionSel) { recordSessionSlot(S.sessionSel); return; }
   var i, slot, playing = -1, target = -1;
   for (i = 0; i < 8; i++) {
      slot = cursorSlots.getItemAt(i);
      if (slot.isRecording().get()) {
         slot.launch();
         if (S.isOverdub) transport.isClipLauncherOverdubEnabled().set(false);
         popup("Enregistrement terminé");
         return;
      }
      if (slot.isPlaying().get()) playing = i;
   }
   if (playing >= 0) {
      transport.isClipLauncherOverdubEnabled().toggle();
      popup("Overdub clip : " + (S.isOverdub ? "OFF" : "ON"));
      return;
   }
   for (i = 0; i < 8; i++) {
      slot = cursorSlots.getItemAt(i);
      if (!slot.isSelected().get()) continue;
      if (slot.hasContent().get()) {        // clip sélectionné à l'arrêt : on le lance en overdub
         slot.launch();
         transport.isClipLauncherOverdubEnabled().set(true);
         popup("Overdub clip : ON");
         return;
      }
      target = i; break;
   }
   if (target < 0) {
      for (i = 0; i < 8; i++) if (!cursorSlots.getItemAt(i).hasContent().get()) { target = i; break; }
   }
   if (target < 0) { popup("Aucun slot vide sur cette piste"); return; }
   armByUser(); cursorTrack.arm().set(true);
   slot = cursorSlots.getItemAt(target);
   slot.select();
   slot.record();
   popup("Enregistrement clip — slot " + (target + 1));
}

/** Record en Session sur le slot sélectionné :
 *  vide -> enregistre un nouveau clip ; en enregistrement -> arrête et joue ;
 *  clip qui joue -> overdub on/off ; clip à l'arrêt -> lance en overdub. */
function recordSessionSlot(slot) {
   armByUser();                                     // armement demandé (Record) : gardé en Session
   if (slot.isRecording().get()) {
      slot.launch();
      if (S.isOverdub) transport.isClipLauncherOverdubEnabled().set(false);
      popup("Enregistrement terminé");
   } else if (!slot.hasContent().get()) {
      armByUser(); cursorTrack.arm().set(true);
      slot.record();
      popup("Enregistrement d'un nouveau clip");
   } else if (slot.isPlaying().get()) {
      transport.isClipLauncherOverdubEnabled().toggle();
      popup("Overdub clip : " + (S.isOverdub ? "OFF" : "ON"));
   } else {
      slot.launch();
      transport.isClipLauncherOverdubEnabled().set(true);
      popup("Overdub clip : ON");
   }
}

/** Duplicate (bouton Copy) : en combinaison = copie ; appui seul = duplique le clip. */
function onCopyButton(pressed) {
   if (pressed) {
      if (S.clipboard || S.slotClipboard || memClipboard || S.barClip) {
         S.clipboard = null; S.slotClipboard = null; memClipboard = null; S.barClip = null; S.copyCancel = true; popup("Copie annulée");
      }
      S.copy = true; S.copyUsed = false; S.copySel = -1; memCopyHold = false;
      return;
   }
   S.copy = false; S.copySel = -1;
   if (S.copyCancel) { S.copyCancel = false; return; }
   S.barClipHold = false;
   if (S.clipboard || S.slotClipboard || memClipboard || S.barClip) return;  // en attente de la destination
   if (memLock) return;                         // Perf : Copy seul ne duplique pas le clip (les pas à preset restaient sur l'ancien)
   if (!S.copyUsed) duplicateToEmptySlot();     // appui seul : duplique le clip sélectionné
}

/** Duplique le clip sélectionné (sinon celui qui joue) dans le premier slot VIDE
 *  situé après lui sur la piste (sinon le premier slot vide de la piste). */
function duplicateToEmptySlot() {
   if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
   var src = -1, i;
   for (i = 0; i < 8; i++) {
      var sl = cursorSlots.getItemAt(i);
      if (sl.isSelected().get() && sl.hasContent().get()) { src = i; break; }
   }
   if (src < 0) for (i = 0; i < 8; i++) if (cursorSlots.getItemAt(i).isPlaying().get()) { src = i; break; }
   if (src < 0) { popup("Aucun clip à dupliquer"); return; }
   var dst = firstEmptySlot(src + 1);
   if (dst < 0) dst = firstEmptySlot(0);
   if (dst < 0) { makeRoomSlot(duplicateToEmptySlot); return; }
   var target = cursorSlots.getItemAt(dst);
   target.replaceInsertionPoint().copySlotsOrScenes(cursorSlots.getItemAt(src));
   target.select();
   playNewClip(target);
   popup("Clip dupliqué — slot " + (dst + 1) + " (lecture)");
}

/** Slot vide sélectionné (ou aucun clip) : le séquenceur écrit dans un tampon d'une mesure.
 *  NB : le curseur de clip de Bitwig garde l'ancien clip quand on sélectionne un slot vide,
 *  d'où ce test sur le slot sélectionné plutôt que sur l'existence du clip. */
var noteBuffer = [];            // { x, pitch, vel, len } en attente d'un clip
var bufferSlot = -1;            // slot où le clip est en cours de création (-1 = aucun)
function selectedSlotIndex() {
   for (var i = 0; i < 8; i++) if (cursorSlots.getItemAt(i).isSelected().get()) return i;
   return -1;
}
function isEmptySlotMode() {
   if (bufferSlot >= 0) return true;                       // clip en cours de création
   var sel = selectedSlotIndex();
   if (sel >= 0) return !cursorSlots.getItemAt(sel).hasContent().get();
   return !clip16.exists().get();
}

/** Pas pressé sans clip : note ajoutée / retirée du tampon ; la 1re crée le clip. */
function bufferStep(x) {
   var pitch = S.selectedPitch;
   for (var k = 0; k < noteBuffer.length; k++) {
      if (noteBuffer[k].x === x && noteBuffer[k].pitch === pitch) { noteBuffer.splice(k, 1); host.requestFlush(); return; }
   }
   noteBuffer.push({ x: x, pitch: pitch, vel: velocity(), len: GRID_SIZES[S.gridIndex] });
   host.requestFlush();
   if (bufferSlot < 0) createClipFromBuffer();
}

/** Crée un clip d'1 mesure, le lance (immédiatement et synchronisé si la lecture tourne),
 *  puis y écrit tout le tampon dès que Bitwig a fini de le créer. */
function createClipFromBuffer() {
   if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
   var dst = selectedSlotIndex();
   if (dst < 0 || cursorSlots.getItemAt(dst).hasContent().get()) dst = firstEmptySlot(0);
   if (dst < 0) { makeRoomSlot(createClipFromBuffer); return; }
   bufferSlot = dst;
   var slot = cursorSlots.getItemAt(dst);
   S.page16 = 0;
   slot.createEmptyClip(4);
   slot.select();
   popup("Nouveau clip (1 mesure) — slot " + (dst + 1));
   var tries = 0;
   function waitClip() {
      if (bufferSlot !== dst) return;
      if (!slot.hasContent().get()) {                 // pas encore créé
         if (++tries > 30) { popup("Création du clip impossible"); bufferSlot = -1; noteBuffer = []; return; }
         host.scheduleTask(waitClip, 100);
         return;
      }
      slot.select();
      if (S.isPlaying) { try { slot.launchWithOptions("none", "synced"); } catch (e) { slot.launch(); } }
      else { slot.launch(); transport.play(); }
      host.scheduleTask(function () {                 // le curseur suit le nouveau clip : on écrit
         clip16.scrollToStep(0);
         for (var k = 0; k < noteBuffer.length; k++) {
            var n = noteBuffer[k];
            clip16.setStep(HW.CHANNEL, n.x, n.pitch, n.vel, n.len);
         }
         noteBuffer = [];
         bufferSlot = -1;
         host.requestFlush();
      }, 250);
   }
   host.scheduleTask(waitClip, 100);
}

/** Horloge visuelle quand le slot est vide (comme la Move) : temps 1 = pas 1-4,
 *  temps 2 = pas 5-8, etc. Les notes du tampon restent affichées. */
function flushEmptyClock() {
   var beat = Math.floor(nowBeats()) % 4;
   for (var x = 0; x < 16; x++) {
      var buffered = false;
      for (var k = 0; k < noteBuffer.length; k++) if (noteBuffer[k].x === x && (!S.isDrum || noteBuffer[k].pitch === S.selectedPitch)) buffered = true;
      var c = buffered ? moveColor(cursorTrack.color(), false)
            : (Math.floor(x / 4) === beat ? COLOR.LIGHT : COLOR.OFF);
      sendNote(HW.STEP_FIRST_NOTE + x, c);
   }
}
var PULSE_BEATS = 2;                                  // 1 pulsation toutes les 2 temps
var PULSE_GREEN = { red: function () { return 0; }, green: function () { return 1; }, blue: function () { return 0; } };
/** Pulsation douce calée sur le temps : pleine lumière au début du cycle, ~20 % au milieu. */
function pulseLevel() {
   var bpm = transport.tempo().getRaw() || 120, now = new Date().getTime(), beats;
   if (S.isPlaying && lastPos) beats = lastPos.beats + (now - lastPos.t) * bpm / 60000;
   else beats = now * bpm / 60000;
   beats = beats / PULSE_BEATS;
   var ph = beats - Math.floor(beats);
   return 0.2 + 0.8 * (0.5 + 0.5 * Math.cos(2 * Math.PI * ph));
}
function pulseColor(colorValue) {
   var L = Math.round(pulseLevel() * 6) / 6;                      // 7 paliers (cache de couleurs)
   var r = colorValue.red(), g = colorValue.green(), b = colorValue.blue();
   return moveColor({ red: function () { return r; }, green: function () { return g; }, blue: function () { return b; } }, false, L);
}
var pulseRunning = false;
function pulseTick() {                                // ~25 images / s tant qu'on est en Session
   if (S.mode !== MODE.SESSION) { pulseRunning = false; return; }
   host.requestFlush();
   host.scheduleTask(pulseTick, 40);
}
function clockTick() {
   if (S.mode === MODE.SESSION && !pulseRunning) { pulseRunning = true; pulseTick(); }
   if (sendFlashWanted()) startFlashTimer();          // flash des boutons de piste (mode Send)
   if (S.mode === MODE.NOTE && !S.loopMode && isEmptySlotMode()) host.requestFlush();
   if (++blinkCount >= 3) {                           // clignotement (~300 ms) des LEDs d'automation reprise
      blinkCount = 0; blinkOn = !blinkOn;
      var ov = false; try { ov = transport.isAutomationOverrideActive().get(); } catch (e) {}
      if (ov || presetAutoRec || S.loopMode || memLock || chordLock || fxCtl || S.mode === MODE.SESSION || anyButtonSolo()) host.requestFlush();
   }
   host.scheduleTask(clockTick, 100);
}

/** Un nouveau clip passe en lecture automatiquement (transport démarré si besoin). */
function playNewClip(slot) {
   host.scheduleTask(function () {          // laisse Bitwig créer le clip avant de le lancer
      // En lecture : départ immédiat, synchronisé (sans attendre la fin de mesure du clip en cours)
      if (S.isPlaying) { try { slot.launchWithOptions("none", "synced"); } catch (e) { slot.launch(); } }
      else { slot.launch(); transport.play(); }
   }, 150);
}

function firstEmptySlot(from) {
   for (var i = from; i < 8; i++) {
      var sl = cursorSlots.getItemAt(i);
      if (sl.exists().get() && !sl.hasContent().get()) return i;
   }
   return -1;
}
/** Plus de slot vide : on ajoute une scène (donc un slot vide sur chaque piste), on fait
 *  défiler les slots de la piste pour la voir, puis on relance l'action (une seule fois). */
var roomBusy = false;
function makeRoomSlot(retry) {
   if (roomBusy) return;
   roomBusy = true;
   project.createScene();
   popup("Plus de slot libre : nouvelle scène créée");
   var tries = 0;
   (function wait() {
      var n = cursorSlots.itemCount().get();
      if (n > 8) cursorSlots.scrollPosition().set(n - 8);            // la nouvelle scène dans la fenêtre
      if (firstEmptySlot(0) >= 0 || tries++ > 30) { roomBusy = false; if (firstEmptySlot(0) >= 0) retry(); else popup("Impossible de créer un slot"); return; }
      host.scheduleTask(wait, 30);
   })();
}

// ============================================================================
//  8b. CAPTURE
// ============================================================================

/** Position musicale actuelle en temps : transport si lecture, sinon horloge + tempo. */
function nowBeats() {
   var now = new Date().getTime();
   var bpm = transport.tempo().getRaw();
   if (S.isPlaying) return lastPos.beats + (now - lastPos.t) * bpm / 60000;
   return now * bpm / 60000;
}

/** Position dans le clip sélectionné en lecture (en temps), ou -1 s'il ne joue pas. */
function clipBeatsNow() {
   if (clipPlay.step < 0 || !S.isPlaying) return -1;
   return clipPlay.step * CAPTURE.RESOLUTION + (new Date().getTime() - clipPlay.t) * transport.tempo().getRaw() / 60000;
}

function captureNoteOn(padIndex, pitch, vel) {
   var cp = clipBeatsNow();
   var n = { pitch: pitch, vel: vel, start: nowBeats(), end: -1, playing: S.isPlaying,
             clipPos: cp,                                                   // position dans la boucle en cours
             loopLen: cp >= 0 ? captureClip.getLoopLength().get() : 0,
             loopStart: cp >= 0 ? captureClip.getLoopStart().get() : 0 };
   captureHeld[padIndex] = n;
   captureNotes.push(n);
   if (captureNotes.length > CAPTURE.MAX_EVENTS) captureNotes.shift();
   // On ne garde que les MAX_BARS dernières mesures
   var limit = n.start - CAPTURE.MAX_BARS * 4;
   while (captureNotes.length && captureNotes[0].start < limit) captureNotes.shift();
}

function captureNoteOff(padIndex) {
   var n = captureHeld[padIndex];
   if (n) { n.end = nowBeats(); delete captureHeld[padIndex]; }
}

/** Undo après une capture : retire toutes les notes ajoutées (overdub) ou supprime
 *  le clip créé, en une seule fois (Bitwig annulerait note par note). */
function undoCapture() {
   var c = lastCapture;
   lastCapture = null;
   if (c.type === "new") {
      c.slot.deleteObject();
      popup("Capture annulée : clip supprimé");
      resumeAfterUndo();                               // le clip qui jouait avant reprend en place
   } else {
      captureClip.scrollToStep(0);
      for (var i = 0; i < c.notes.length; i++) captureClip.clearStep(HW.CHANNEL, c.notes[i].x, c.notes[i].y);
      popup("Capture annulée : " + c.notes.length + " note(s) retirée(s)");
   }
}

var tempoFromCapture = 0, captureEnd = 0;
/** Au lancement d'une capture, le clip démarre un peu après le début de la boucle : les notes
 *  de ce début (la 1re surtout) sont jouées tout de suite par le script, pour ne pas les perdre. */
function playMissedNotes(placed, upTo, bpm) {
   if (!(upTo > 0)) return;
   for (var i = 0; i < placed.length; i++) {
      var n = placed[i];
      if (n.pos > upTo || n.pos < upTo - 1) continue;   // seulement le dernier temps manqué
      var remain = Math.max(0.05, n.pos + n.dur - upTo) * 60000 / bpm;
      (function (pitch, vel, ms) {
         cursorTrack.startNote(pitch, vel);
         host.scheduleTask(function () { cursorTrack.stopNote(pitch, 0); }, Math.min(ms, 4000));
      })(n.pitch, n.vel, remain);
   }
}
/** Longueur en mesures entières, arrondie à 1, 2, 4 ou 8 mesures (en temps). */
function pow2Bars(beats) {
   var bars = Math.max(1, Math.ceil(beats / 4 - 0.05)), p = 1;
   while (p < bars && p < CAPTURE.MAX_BARS) p *= 2;
   return p * 4;
}
/** Tempo de ce qui a été joué machine arrêtée : on cherche le tempo (70-160 BPM) pour lequel
 *  les débuts de notes tombent le mieux sur une grille de doubles-croches, en favorisant
 *  une durée totale proche d'un nombre entier de mesures. null si trop peu de notes. */
function detectTempo(notes, endMs) {
   var bpm0 = transport.tempo().getRaw(), on = [], i;
   for (i = 0; i < notes.length; i++) {
      var t = notes[i].start * 60000 / bpm0;
      if (!on.length || t - on[on.length - 1] > 40) on.push(t);      // accords = un seul début
   }
   if (on.length < 4) return null;
   var t0 = on[0], best = null;
   for (var bpm = 70; bpm <= 160; bpm += 0.5) {
      var beat = 60000 / bpm, err = 0;
      for (i = 1; i < on.length; i++) {
         var x8 = (on[i] - t0) / (beat / 2), d8 = Math.abs(x8 - Math.round(x8));     // croches (prioritaire)
         var x16 = (on[i] - t0) / (beat / 4), d16 = Math.abs(x16 - Math.round(x16)); // doubles-croches
         err += 0.6 * d8 * d8 + 0.4 * d16 * d16;
      }
      err /= (on.length - 1);
      // Fin de la séquence : le moment de l'appui sur Capture (on lance la capture à peu près
      // à la fin de la boucle jouée). La durée doit faire un nombre entier de mesures,
      // de préférence 1, 2, 4 ou 8. Sans ce repère : dernier début + intervalle moyen.
      var avg = (on[on.length - 1] - t0) / (on.length - 1);
      var endT = (endMs && endMs > on[on.length - 1]) ? endMs : on[on.length - 1] + avg;
      var bars = (endT - t0) / (beat * 4), rb = Math.max(1, Math.round(bars));
      var barErr = Math.abs(bars - rb) / Math.max(1, rb * 0.5);
      var pow2 = (rb & (rb - 1)) === 0 ? 0 : 0.05;                     // 1, 2, 4, 8 mesures préférées
      var score = err + CAPTURE.END_WEIGHT * barErr + pow2 + 0.0004 * Math.abs(bpm - 120);
      if (!best || score < best.score) best = { bpm: bpm, score: score, span: rb * beat * 4 };
   }
   if (best) best.bpm = Math.round(best.bpm);        // tempo entier
   return best;
}

/** Clip supprimé PENDANT qu'il jouait : on retient où il en était, pour que Undo le remette
 *  en lecture à la bonne position (Bitwig le restaure, mais arrêté). */
var deletedPlaying = null;
function rememberDeletedClip(slot) {
   deletedPlaying = null;
   if (!slot.isPlaying().get() || !S.isPlaying) return;
   var pos = slot.isSelected().get() ? clipBeatsNow() : -1;
   deletedPlaying = { slot: slot, pos: pos, t: new Date().getTime(),
                      loopStart: captureClip.getLoopStart().get(), loopLen: captureClip.getLoopLength().get(),
                      playStart: captureClip.getPlayStart().get() };
}
/** Suit le clip qui joue (sélectionné) sur la piste : où il en est, et le précédent quand
 *  un autre prend sa place (ex. une capture). Sert à Undo pour reprendre la lecture en place. */
var playRef = null, prevPlayRef = null;
function trackPlayRef(st) {
   if (st < 0) return;
   var sel = selectedSlotIndex();
   if (sel < 0 || !cursorSlots.getItemAt(sel).isPlaying().get()) return;
   var ref = { idx: sel, slot: cursorSlots.getItemAt(sel), pos: st * CAPTURE.RESOLUTION, t: new Date().getTime(),
               loopStart: captureClip.getLoopStart().get(), loopLen: captureClip.getLoopLength().get(),
               playStart: captureClip.getPlayStart().get() };
   if (playRef && playRef.idx !== sel) prevPlayRef = playRef;
   playRef = ref;
}
/** Après un Undo : si plus rien ne joue sur la piste, on relance le dernier clip qui jouait
 *  (ou celui d'avant), à la position où il en serait. */
function resumeAfterUndo() {
   var cands = [playRef, prevPlayRef];
   host.scheduleTask(function () {
      if (!S.isPlaying) return;
      for (var i = 0; i < 8; i++) if (cursorSlots.getItemAt(i).isPlaying().get() || cursorSlots.getItemAt(i).isPlaybackQueued().get()) return;
      for (var c = 0; c < cands.length; c++) {
         var r = cands[c];
         if (!r || new Date().getTime() - r.t > 120000) continue;
         if (!r.slot.hasContent().get()) continue;
         deletedPlaying = { slot: r.slot, pos: r.pos, t: r.t, loopStart: r.loopStart, loopLen: r.loopLen, playStart: r.playStart };
         relaunchDeletedClip(true);
         return;
      }
   }, 200);
}
function relaunchDeletedClip(fromResume) {
   var d = deletedPlaying;
   deletedPlaying = null;
   if (!d || new Date().getTime() - d.t > 120000 || !S.isPlaying) { if (!fromResume) resumeAfterUndo(); return; }
   var tries = 0;
   function check() {
      if (!d.slot.hasContent().get()) { if (tries++ < 30) host.scheduleTask(check, 20); return; }
      d.slot.select();
      host.scheduleTask(function () {
         if (d.pos < 0 || d.loopLen <= 0) {                  // position inconnue : calé sur la mesure
            try { d.slot.launchWithOptions("none", "synced"); } catch (e) { d.slot.launch(); }
         } else {
            var elapsed = (new Date().getTime() - d.t) * transport.tempo().getRaw() / 60000;
            var rel = ((d.pos - d.loopStart + elapsed) % d.loopLen + d.loopLen) % d.loopLen;
            launchFromPoint(d.slot, d.loopStart + rel, d.playStart || 0, function () {   // démarre là où il en serait
               return Math.abs(captureClip.getLoopLength().get() - d.loopLen) < 0.001 && Math.abs(captureClip.getLoopStart().get() - d.loopStart) < 0.001;
            });
         }
         popup("Clip restauré et relancé à sa position");
      }, 80);
   }
   host.scheduleTask(check, 60);
}

/** mode Preset + Capture : active / coupe l'écriture d'automation du lanceur de clips. Les
 *  rappels de presets et les morphs joués pendant ce temps sont enregistrés par Bitwig dans
 *  le clip qui joue (en mode Latch : chaque changement reste jusqu'au suivant). */
var presetAutoRec = false, presetAutoSaved = null, launcherAutoAction = null, launcherAutoScanned = false;
/** Action Bitwig « écriture d'automation du lanceur » (repli si le réglage direct ne prend pas). */
function findLauncherAutoAction() {
   if (launcherAutoScanned) return launcherAutoAction;
   launcherAutoScanned = true;
   var acts = application.getActions();
   for (var i = 0; i < acts.length; i++) {
      var id = String(acts[i].getId()), nm = String(acts[i].getName()), t = id + " " + nm;
      if (/automation/i.test(t) && /launcher|clip/i.test(t) && /write|record|enregistr|écriture/i.test(t)) {
         println("Action automation lanceur : " + id + " — " + nm);
         if (!launcherAutoAction) launcherAutoAction = acts[i];
      }
   }
   return launcherAutoAction;
}
function setLauncherAutoWrite(on) {
   var v = transport.isClipLauncherAutomationWriteEnabled();
   v.set(on);
   host.scheduleTask(function () {                     // vérifie que Bitwig a bien changé l'état
      if (v.get() === on) return;
      var a = findLauncherAutoAction();
      if (a) { a.invoke(); println("Écriture automation lanceur via l'action " + a.getId()); }
      host.scheduleTask(function () {
         if (v.get() !== on) popup("Bitwig n'a pas pris l'écriture d'automation du lanceur : active-la à la main");
      }, 200);
   }, 150);
}
function togglePresetAutomationRec() {
   if (!presetAutoRec) {
      presetAutoSaved = { mode: transport.automationWriteMode().get(), on: transport.isClipLauncherAutomationWriteEnabled().get() };
      transport.automationWriteMode().set("latch");
      setLauncherAutoWrite(true);
      presetAutoRec = true;
      popup("Enregistrement de l'automation des presets : ON (Capture pour arrêter)" + (S.isPlaying ? "" : " — lance la lecture"));
   } else {
      setLauncherAutoWrite(!!(presetAutoSaved && presetAutoSaved.on));
      if (presetAutoSaved && presetAutoSaved.mode) transport.automationWriteMode().set(presetAutoSaved.mode);
      presetAutoRec = false;
      popup("Enregistrement de l'automation des presets : OFF");
   }
   host.requestFlush();
}


// ----------------------------------------------------------------------------
//  Capture des mouvements de potards — REJEU EN OVERDUB (EXPÉRIMENTAL, v5.06)
//  L'API ne sait pas écrire de l'automation dans un clip. Le script garde donc en mémoire
//  les mouvements des encodeurs du device (avec leur position dans la boucle du clip qui
//  joue) ; à l'appui sur Capture, il active l'écriture d'automation du lanceur et REJOUE
//  ces mouvements pendant un tour de boucle : Bitwig les enregistre comme s'ils étaient
//  joués en direct. Piste et device sont épinglés pendant le rejeu, et la piste reste
//  armée même si l'on change de piste.
// ----------------------------------------------------------------------------
var AUTO_CAPTURE_ENABLED = false;   // 17 nov. : mis de côté pour la bêta (code gardé, non testé sur la Move)
var AUTO_CAP = { GAP_BEATS: 1, MAX_EVENTS: 4000, LEAD_MS: 30, RELEASE_MS: 120 };
var autoMoves = [];          // { key, pg, k, v, start (temps), pos (dans la boucle), len, loopStart }
var autoRep = null;          // rejeu en cours : { key, armedByUs, saved, timers }
var capTrack, capDev, capPages = [], capArmEq = [];
function initAutoCapEngine() {
   capTrack = host.createCursorTrack("MOVE_AUTOCAP_TRACK", "Move Capture auto", 0, 0, false);
   capTrack.isPinned().markInterested();
   capTrack.arm().markInterested();
   capTrack.name().markInterested();
   var mode = null;
   try { mode = Java.type("com.bitwig.extension.controller.api.CursorDeviceFollowMode").FOLLOW_SELECTION; } catch (e1) {}
   if (!mode) { try { mode = com.bitwig.extension.controller.api.CursorDeviceFollowMode.FOLLOW_SELECTION; } catch (e2) {} }
   capDev = mode ? capTrack.createCursorDevice("MOVE_AUTOCAP_DEV", "Move Capture auto Device", 0, mode) : capTrack.createCursorDevice();
   capDev.isPinned().markInterested();
   capDev.name().markInterested();
   for (var p = 0; p < MEM_PAGES; p++) {
      capPages[p] = capDev.createCursorRemoteControlsPage("MoveAutoCap" + p, 8, "");
      capPages[p].selectedPageIndex().markInterested();
   }
   for (var t = 0; t < ARM_BANK_SIZE; t++) { capArmEq[t] = armBank.getItemAt(t).createEqualsValue(capTrack); capArmEq[t].markInterested(); }
}
/** Piste de la banque d'armement = piste du rejeu en cours ? (ne pas la désarmer) */
function isAutoRepTrack(t) { return !!(autoRep && capArmEq[t] && capArmEq[t].get()); }

/** Un encodeur a tourné sur le device : on garde la valeur et sa position dans la boucle. */
function noteAutoMove(i, delta) {
   if (!AUTO_CAPTURE_ENABLED || autoRep || !S.isPlaying) return;
   var cp = clipBeatsNow();
   if (cp < 0) return;                                   // pas de clip qui joue : rien à placer
   var len = captureClip.getLoopLength().get(), ls = captureClip.getLoopStart().get();
   if (!(len > 0)) return;
   var prm = remotes.getParameter(i);
   var v = Math.max(0, Math.min(1, prm.get() + delta / (S.shift ? 1024 : 128)));
   var now = nowBeats();
   autoMoves.push({ key: memKey(), pg: remotes.selectedPageIndex().get(), k: i, v: v, start: now,
                    pos: ((cp - ls) % len + len) % len, len: len, loopStart: ls });
   if (autoMoves.length > AUTO_CAP.MAX_EVENTS) autoMoves.shift();
   while (autoMoves.length && autoMoves[0].start < now - CAPTURE.MAX_BARS * 4) autoMoves.shift();
}
/** Mouvements du dernier tour de boucle, pour le device sélectionné. */
function pendingAutoMoves() {
   if (!autoMoves.length) return [];
   var key = memKey(), last = autoMoves[autoMoves.length - 1], now = nowBeats(), out = [];
   for (var i = 0; i < autoMoves.length; i++) {
      var m = autoMoves[i];
      if (m.key === key && m.start >= now - last.len) out.push(m);
   }
   return out;
}
/** Capture des mouvements : épingle piste + device, active l'écriture, rejoue un tour. */
function captureAutomation() {
   if (autoRep) { popup("Automation : gravure déjà en cours"); return true; }
   var moves = pendingAutoMoves();
   if (!moves.length) {
      if (autoMoves.length && autoMoves[autoMoves.length - 1].key !== memKey())
         popup("Automation : reviens sur le device où tu as tourné les potards, puis Capture");
      return false;
   }
   var cp = clipBeatsNow();
   if (cp < 0 || !S.isPlaying) { popup("Automation : lance le clip de la piste pour graver les mouvements"); return true; }
   var len = moves[moves.length - 1].len, ls = moves[moves.length - 1].loopStart;
   var bpm = transport.tempo().getRaw(), msPerBeat = 60000 / bpm;
   var p0 = ((cp - ls) % len + len) % len;
   autoRep = { key: memKey(), armedByUs: false, timers: 0, n: moves.length,
               saved: { mode: transport.automationWriteMode().get(), on: transport.isClipLauncherAutomationWriteEnabled().get() } };
   // 1) épingler la piste et le device (le rejeu ne suit pas un changement de piste)
   capTrack.isPinned().set(false); capDev.isPinned().set(false);
   capTrack.selectChannel(cursorTrack);
   host.scheduleTask(function () {
      capTrack.isPinned().set(true);
      capDev.selectDevice(cursorDevice);
      host.scheduleTask(function () {
         capDev.isPinned().set(true);
         for (var q = 0; q < MEM_PAGES; q++) capPages[q].selectedPageIndex().set(q);
         // 2) piste armée pendant la gravure (sécurité demandée), écriture d'automation du lanceur
         if (!capTrack.arm().get()) { armByUser(); capTrack.arm().set(true); autoRep.armedByUs = true; }
         transport.automationWriteMode().set("touch");
         setLauncherAutoWrite(true);
         host.scheduleTask(function () { autoReplay(moves, len, p0, msPerBeat); }, 150);
      }, 80);
   }, 80);
   popup("Automation : gravure de " + moves.length + " mouvement(s) pendant 1 tour (" + (len / 4) + " mes.) — ne touche pas aux potards");
   host.requestFlush();
   return true;
}
function autoReplay(moves, len, p0, msPerBeat) {
   if (!autoRep) return;
   // la boucle a avancé pendant la mise en place : on repart de la position actuelle
   var cpNow = clipBeatsNow(), lsNow = captureClip.getLoopStart().get();
   if (cpNow >= 0) p0 = ((cpNow - lsNow) % len + len) % len;
   // regroupe par paramètre, puis en « gestes » (écart > GAP_BEATS = nouveau geste)
   var byParam = {}, key, i;
   for (i = 0; i < moves.length; i++) {
      var m = moves[i]; key = m.pg + "/" + m.k;
      (byParam[key] = byParam[key] || []).push({ d: ((m.pos - p0) % len + len) % len, v: m.v, pg: m.pg, k: m.k });
   }
   var endMs = len * msPerBeat;
   for (key in byParam) {
      var ev = byParam[key].sort(function (a, b) { return a.d - b.d; });
      var seg = [ev[0]];
      for (i = 1; i <= ev.length; i++) {
         if (i < ev.length && ev[i].d - ev[i - 1].d <= AUTO_CAP.GAP_BEATS) { seg.push(ev[i]); continue; }
         autoScheduleGesture(seg, msPerBeat);
         if (i < ev.length) seg = [ev[i]];
      }
   }
   host.scheduleTask(function () { finishAutoCapture(true); }, Math.round(endMs + 250));
}
function autoScheduleGesture(seg, msPerBeat) {
   var prm = capPages[seg[0].pg] && capPages[seg[0].pg].getParameter(seg[0].k);
   if (!prm) return;
   var t0 = Math.max(0, Math.round(seg[0].d * msPerBeat) - AUTO_CAP.LEAD_MS);
   host.scheduleTask(function () { if (autoRep) prm.touch(true); }, t0);
   for (var j = 0; j < seg.length; j++) (function (e) {
      host.scheduleTask(function () { if (autoRep) prm.set(e.v); }, Math.round(e.d * msPerBeat));
   })(seg[j]);
   host.scheduleTask(function () { prm.touch(false); }, Math.round(seg[seg.length - 1].d * msPerBeat) + AUTO_CAP.RELEASE_MS);
}
/** Fin de la gravure (ou arrêt) : on remet l'écriture, l'armement et l'épinglage comme avant. */
function finishAutoCapture(done) {
   if (!autoRep) return;
   var r = autoRep;
   autoRep = null;
   for (var q = 0; q < MEM_PAGES; q++) for (var k = 0; k < 8; k++) { try { capPages[q].getParameter(k).touch(false); } catch (e) {} }
   setLauncherAutoWrite(!!r.saved.on);
   if (r.saved.mode) transport.automationWriteMode().set(r.saved.mode);
   if (r.armedByUs) capTrack.arm().set(false);
   capTrack.isPinned().set(false); capDev.isPinned().set(false);
   if (S.mode === MODE.NOTE) armFollowSelection();
   autoMoves = [];
   popup(done ? "Automation gravée (" + r.n + " mouvement(s)) — Undo pour annuler" : "Gravure de l'automation arrêtée");
   host.requestFlush();
}

/** Clip supprimé : on efface aussi ses presets de pas (Perf), pour tous les devices de la piste. */
function dropStepPresets(trackName, slotIdx) {
   var all = memStore[STEPS_KEY];
   if (!all) return;
   var pre = trackName + MEM_SEP, suf = "|" + slotIdx, n = 0;
   for (var k in all) if (k.indexOf(pre) === 0 && k.slice(-suf.length) === suf) { delete all[k]; n++; }
   if (n) memSave();
}

/** Lance un clip en démarrant DANS le clip (point de lecture temporaire), puis remet son point
 *  de lecture. Le point de lecture passe par le curseur de clip de Bitwig : on ne l'écrit que
 *  quand on est SÛR que le curseur est sur ce clip, sinon un autre clip le gardait.
 *  check() : vrai quand le curseur est sur le bon clip (ex. clip neuf encore vide, ou une de
 *  ses notes présente). Pas de certitude : lancement calé sur la mesure, sans rien modifier. */
function launchFromPoint(slot, point, restore, check) {
   var tries = 0;
   slot.select();
   (function go() {
      if (!(slot.isSelected().get() && check())) {
         if (tries++ < 25) { host.scheduleTask(go, 15); return; }
         try { slot.launchWithOptions("none", "synced"); } catch (e0) { slot.launch(); }
         popup("Lancement calé sur la mesure (clip pas encore prêt)");
         return;
      }
      captureClip.getPlayStart().set(point);
      try { slot.launchWithOptions("none", "from_start"); } catch (e) { slot.launch(); }
      var rt = 0;
      host.scheduleTask(function resetPS() {
         if (slot.isSelected().get() && check(true)) { captureClip.getPlayStart().set(restore); return; }
         if (rt++ === 0) slot.select();               // on revient sur ce clip pour le corriger
         if (rt < 30) host.scheduleTask(resetPS, 30);
      }, 400);
   })();
}
function capHas(x, y) { return capData[x + "," + y] === 2; }
function capEmpty() { for (var k in capData) if (capData[k] === 2) return false; return true; }

/** Delete aurait-il quelque chose à effacer ? (clip qui joue / sélectionné, ou clip en Session) */
function somethingToDelete() {
   if (S.mode === MODE.SESSION) return !!(S.sessionSel && S.sessionSel.hasContent().get());
   for (var i = 0; i < 8; i++) {
      var sl = cursorSlots.getItemAt(i);
      if (sl.hasContent().get() && (sl.isPlaying().get() || sl.isSelected().get())) return true;
   }
   return false;
}

/** Crée un clip avec ce qui a été joué récemment et le lance. */
function doCapture() {
   if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
   if (fxCtl) { popup("Mode Send : Capture indisponible (Shift + Note/Session pour revenir)"); return; }
   if (!captureNotes.length) {
      if (AUTO_CAPTURE_ENABLED && captureAutomation()) return;   // pas de notes : grave les mouvements de potards
      popup("Rien à capturer : joue aux pads ou tourne les potards pendant que le clip joue");
      return;
   }
   var notes = captureNotes.slice(), i, n, now = nowBeats();
   for (i = 0; i < notes.length; i++) if (notes[i].end < 0) notes[i].end = now;
   var ref = notes[notes.length - 1], placed = [], lenBeats, start, syncLaunch = false;
   tempoFromCapture = 0;

   if (ref.clipPos >= 0 && ref.loopLen > 0) {
      // Un clip bouclait : on garde SA longueur et on place les notes dans sa boucle
      lenBeats = Math.min(ref.loopLen, CAPTURE.MAX_BARS * 4);
      for (i = 0; i < notes.length; i++) {
         n = notes[i];
         if (n.clipPos < 0 || n.start < now - lenBeats) continue;   // dernier tour de boucle seulement
         var pos = ((n.clipPos - n.loopStart) % lenBeats + lenBeats) % lenBeats;
         placed.push({ pitch: n.pitch, vel: n.vel, pos: pos, dur: Math.min(n.end - n.start, lenBeats) });
      }
   } else if (notes[0].playing && S.isPlaying) {
      // Lecture en cours, pas de clip qui boucle : fin calée sur la barre de mesure.
      // Appui jusqu'à 1 temps APRÈS une barre = on visait cette barre (anticipation) ;
      // les notes jouées depuis la barre sont replacées au début du clip.
      var barEnd = Math.floor(now / 4) * 4;
      var end = (now - barEnd <= CAPTURE.LATE_TOLERANCE) ? barEnd : Math.ceil(now / 4) * 4;
      // Le clip commence à la mesure de la 1re note jouée (dans la dernière phrase) et
      // s'arrête à la barre visée : nombre exact de mesures, 1re note bien calée dans sa mesure.
      var cutP = 0;
      for (i = 1; i < notes.length; i++) if (notes[i].start - notes[i - 1].start > CAPTURE.PHRASE_GAP_BARS * 4) cutP = i;
      notes = notes.slice(cutP);
      // 1re note jouée un peu en avance sur une barre (jusqu'à EARLY_TOLERANCE) = on visait
      // la barre : le clip commence à cette barre, pas à la mesure d'avant (pas de mesure vide)
      var startBar = Math.floor((notes[0].start + CAPTURE.PICKUP) / 4) * 4;
      if (startBar >= end) startBar = end - 4;
      lenBeats = Math.min(end - startBar, CAPTURE.MAX_BARS * 4);
      startBar = end - lenBeats;
      for (i = 0; i < notes.length; i++) {
         n = notes[i];
         var pp = n.start - startBar;
         if (pp < 0 && pp >= -CAPTURE.EARLY_TOLERANCE) pp = 0;          // un poil en avance : sur le temps 1
         else if (pp < 0 && pp >= -CAPTURE.PICKUP) pp += lenBeats;       // levée (anacrouse) : fin de la boucle
         if (pp < 0) continue;
         if (pp >= lenBeats) pp -= lenBeats;                            // jouée juste après la barre : début du clip
         if (pp >= lenBeats) continue;
         placed.push({ pitch: n.pitch, vel: n.vel, pos: pp, dur: Math.min(n.end - n.start, lenBeats) });
      }
      captureEnd = end;
      syncLaunch = true;
   } else {
      // Machine arrêtée : on ne garde que la DERNIÈRE phrase jouée (un silence de plus de
      // CAPTURE.PHRASE_GAP_MS sépare deux phrases), pour que le clip commence sur sa 1re note.
      var bpmA = transport.tempo().getRaw(), cut = 0;
      for (i = 1; i < notes.length; i++) {
         var gapMs = (notes[i].start - notes[i - 1].start) * 60000 / bpmA;
         if (gapMs > CAPTURE.PHRASE_GAP_MS) cut = i;
      }
      if (cut > 0) notes = notes.slice(cut);
      // Note isolée au début (pad touché par erreur juste avant) : on l'écarte si elle est
      // bien plus loin de la suivante que l'écart habituel entre les notes
      if (notes.length >= 4) {
         var gaps = [];
         for (i = 1; i < notes.length; i++) gaps.push((notes[i].start - notes[i - 1].start) * 60000 / bpmA);
         var sorted = gaps.slice().sort(function (a, b) { return a - b; }), med = sorted[Math.floor(sorted.length / 2)];
         while (notes.length >= 4 && gaps[0] > Math.max(4 * med, 1000)) { notes = notes.slice(1); gaps = gaps.slice(1); }
      }
      // Puis on détecte le tempo joué, on le règle, et le clip démarre sur la 1re note
      var det = detectTempo(notes, new Date().getTime());   // appui sur Capture = fin de la boucle (en ms)
      var bpm0 = transport.tempo().getRaw(), bpm = det ? det.bpm : bpm0;
      var t0 = notes[0].start * 60000 / bpm0;                          // 1re note, en ms
      var lastMs = t0;
      for (i = 0; i < notes.length; i++) lastMs = Math.max(lastMs, notes[i].end * 60000 / bpm0);
      if (det && det.span > 0) lastMs = Math.max(lastMs, t0 + det.span);
      lenBeats = pow2Bars((lastMs - t0) * bpm / 60000);
      for (i = 0; i < notes.length; i++) {
         n = notes[i];
         var pos2 = (n.start * 60000 / bpm0 - t0) * bpm / 60000;
         if (pos2 >= lenBeats) continue;
         placed.push({ pitch: n.pitch, vel: n.vel, pos: Math.max(0, pos2), dur: Math.max(CAPTURE.RESOLUTION, (n.end - n.start) * bpm / bpm0) });
      }
      if (det) { transport.tempo().setRaw(bpm); tempoFromCapture = Math.round(bpm * 10) / 10; }
   }
   if (!placed.length) { popup("Rien à capturer dans la boucle en cours"); return; }

   // Clip en train de boucler : overdub — on ajoute les notes DANS ce clip, sans en créer
   if (ref.clipPos >= 0 && ref.loopLen > 0) {
      var width = Math.round(CAPTURE.MAX_BARS * 4 / CAPTURE.RESOLUTION), added = 0, written = [];
      captureClip.scrollToStep(0);
      for (i = 0; i < placed.length; i++) {
         var p = placed[i];
         var xs = Math.round((ref.loopStart + p.pos) / CAPTURE.RESOLUTION);
         if (xs < 0 || xs >= width) continue;
         if (capData[xs + "," + p.pitch] === 2) continue;           // note déjà présente : on ne la double pas
         captureClip.setStep(HW.CHANNEL, xs, p.pitch, p.vel, Math.max(CAPTURE.RESOLUTION, p.dur));
         written.push({ x: xs, y: p.pitch });
         added++;
      }
      lastCapture = { type: "overdub", notes: written };
      popup("Capture (overdub) : " + added + " note(s) ajoutée(s) — Undo pour annuler");
      captureNotes = [];
      return;
   }

   var sel = -1;
   for (i = 0; i < 8; i++) if (cursorSlots.getItemAt(i).isSelected().get()) { sel = i; break; }
   var dst = firstEmptySlot(sel + 1);
   if (dst < 0) dst = firstEmptySlot(0);
   if (dst < 0) { makeRoomSlot(doCapture); return; }               // la mémoire Capture est conservée

   var slot = cursorSlots.getItemAt(dst);
   slot.createEmptyClip(lenBeats);
   lastCapture = { type: "new", slot: slot };
   slot.select();
   // Dès que Bitwig a créé le clip : lancement immédiat, puis écriture des notes.
   // Machine arrêtée : l'appui sur Capture = fin de la séquence = reprise de la boucle. On
   // démarre la lecture « en phase » avec cet appui (position = temps écoulé depuis), pour
   // que le son reparte comme si la boucle avait redémarré pile au moment de l'appui.
   var pressT = new Date().getTime(), tries = 0;
   function whenReady() {
      if (!slot.hasContent().get() && tries++ < 40) { host.scheduleTask(whenReady, 15); return; }
      host.scheduleTask(launchAndWrite, 40);          // le curseur de clip passe sur le nouveau clip
   }
   // Tout passe par le curseur de clip de Bitwig : on attend qu'il soit VRAIMENT sur le clip
   // neuf (slot sélectionné, clip vide, bonne longueur) avant d'écrire quoi que ce soit, sinon
   // les notes ou le point de lecture allaient dans le clip d'avant.
   var gateTries = 0;
   function onNewClip() {
      return slot.isSelected().get() && capEmpty() && Math.abs(captureClip.getLoopLength().get() - lenBeats) < 0.001;
   }
   function launchAndWrite() {
      if (!onNewClip() && gateTries++ < 30) { slot.select(); host.scheduleTask(launchAndWrite, 15); return; }
      var sure = onNewClip();
      var bpmNow = transport.tempo().getRaw();
      var missedUpTo = 0;                              // notes du 1er tour que le clip ne jouera pas
      var usedPoint = false;
      if (syncLaunch && S.isPlaying) {
         // Départ IMMÉDIAT, en démarrant DANS le clip au point où il devrait être
         var late = nowBeats() - captureEnd;
         if (late < 0) {
            // Appui AVANT la barre visée : le clip démarre pile à cette barre, depuis son début
            // (avant : on démarrait tout de suite près de la FIN du clip, et si le point de
            // lecture ne revenait pas à 0, le clip repartait ensuite une mesure trop loin).
            try { slot.launchWithOptions("1", "from_start"); } catch (e) { slot.launch(); }
         } else {
            // Appui juste APRÈS la barre (tolérance) : départ immédiat, dans le clip au bon point
            var ph = late % lenBeats;
            missedUpTo = ph;
            if (sure && ph > 0.001) { captureClip.getPlayStart().set(ph); usedPoint = true; }
            try { slot.launchWithOptions("none", sure ? "from_start" : "synced"); } catch (e1) { slot.launch(); }
         }
      } else {
         // Machine arrêtée : transport d'abord (position = temps écoulé depuis l'appui), puis
         // le clip synchronisé (lancé à l'arrêt, Bitwig attendait la mesure suivante).
         var elapsed = ((new Date().getTime() - pressT) * bpmNow / 60000) % lenBeats;
         missedUpTo = elapsed + 0.06 * bpmNow / 60;
         transport.getPosition().set(elapsed);
         if (!S.isPlaying) transport.play();
         host.scheduleTask(function () {
            try { slot.launchWithOptions("none", "synced"); } catch (e2) { slot.launch(); }
         }, 60);
      }
      playMissedNotes(placed, missedUpTo, bpmNow);
      if (!sure && !slot.isSelected().get()) { popup("Capture : clip pas prêt à temps — les notes n'ont pas été écrites (Undo, puis recommence)"); return; }
      captureClip.scrollToStep(0);
      for (var k = 0; k < placed.length; k++) {
         var m = placed[k];
         var x = Math.round(m.pos / CAPTURE.RESOLUTION) % Math.round(lenBeats / CAPTURE.RESOLUTION);
         captureClip.setStep(HW.CHANNEL, x, m.pitch, m.vel, Math.max(CAPTURE.RESOLUTION, m.dur));
      }
      captureClip.getLoopStart().set(0);
      captureClip.getLoopLength().set(lenBeats);
      if (usedPoint) {                                  // remet le point de lecture à 0 sur CE clip
         var fp = placed.length ? { x: Math.round(placed[0].pos / CAPTURE.RESOLUTION) % Math.round(lenBeats / CAPTURE.RESOLUTION), y: placed[0].pitch } : null;
         var rt = 0;
         host.scheduleTask(function resetPS() {
            if (slot.isSelected().get() && (!fp || capHas(fp.x, fp.y))) { captureClip.getPlayStart().set(0); return; }
            if (rt++ === 0) slot.select();
            if (rt < 30) host.scheduleTask(resetPS, 30);
         }, 400);
      }
      popup("Capture : " + placed.length + " note(s), " + (lenBeats / 4) + " mesure(s) — slot " + (dst + 1) +
            (tempoFromCapture ? " — tempo détecté " + tempoFromCapture + " BPM" : ""));
   }
   whenReady();
   captureNotes = [];
}

// ============================================================================
//  9. BOUTONS DE PISTE
// ============================================================================

/** Sélectionne une piste depuis la Move ; si ARM_FOLLOWS_SELECTION, elle devient la
 *  seule piste armée (les sélections faites à la souris ne changent pas l'armement). */
function selectTrackFromMove(track) {
   if (browsing) { popup("Ferme d'abord le navigateur (Back) avant de changer de piste"); return; }
   cursorTrack.selectChannel(track);
   if (S.mode !== MODE.SESSION) armFollowSelection();   // Session : pas d'armement automatique
}

/** Arme seulement la piste sélectionnée (si ARM_FOLLOWS_SELECTION). */
function armFollowSelection() {
   if (!ARM_FOLLOWS_SELECTION || fxCtl) return;      // mode Send : la piste jouée reste armée
   host.scheduleTask(function () {
      for (var t = 0; t < ARM_BANK_SIZE; t++) {
         var tr = armBank.getItemAt(t);
         if (!tr.exists().get()) continue;
         var want = armEquals[t].get() || isAutoRepTrack(t);   // piste en cours de gravure : reste armée
         if (tr.arm().get() !== want) tr.arm().set(want);
      }
   }, 120);   // laisse Bitwig mettre à jour la sélection
}

// ============================================================================
//  NAVIGATEUR : nouveaux devices, presets, nouvelles pistes (bouton Sample)
// ============================================================================

/** Ouvre le navigateur de Bitwig au bon endroit de la chaîne. */
function openBrowser(where) {
   markUiBusy();
   var ip;
   var hasDevice = cursorDevice.exists().get();
   presetMode = (where === "replace");
   if (where === "replace") {
      if (!hasDevice) { popup("Aucun device sélectionné"); return; }
      ip = cursorDevice.replaceDeviceInsertionPoint();   // Bitwig propose les presets de ce device
   } else if (where === "before") {
      ip = hasDevice ? cursorDevice.beforeDeviceInsertionPoint() : cursorTrack.startOfDeviceChainInsertionPoint();
   } else if (where === "start") {
      ip = cursorTrack.startOfDeviceChainInsertionPoint();
   } else if (where === "beforeInstrument") {
      // Effet de note : juste avant le 1er instrument de la piste (Bitwig propose alors
      // les effets de note), sinon au début de la chaîne
      ip = drumDevice.exists().get() ? drumDevice.beforeDeviceInsertionPoint() : cursorTrack.startOfDeviceChainInsertionPoint();
   } else if (where === "inside" && inLayerDepth && cursorDevice.isNested().get() && !cursorDevice.hasLayers().get()) {
      // Dans une couche : nouvelle couche dans le conteneur parent
      cursorDevice.selectParent();
      host.scheduleTask(function () {
         if (cursorDevice.hasLayers().get() && cursorLayer.exists().get()) newLayerFromCurrent();
         else popup("Pas de conteneur à couches au-dessus");
      }, 150);
      return;
   } else if (where === "inside" && cursorDevice.hasLayers().get() && cursorLayer.exists().get()) {
      // Layer / Selector : NOUVELLE couche (l'API ne sait pas en créer une vide) : on duplique
      // la couche courante, on va dessus, et le navigateur remplace son 1er device.
      newLayerFromCurrent();
      return;
   } else if (where === "inside" || where === "insideStart") {
      // Layer / Selector sans couche choisie : on prend la 1re couche, puis on réessaie
      if (cursorDevice.hasLayers().get() && !cursorLayer.exists().get() && !openBrowser.retried) {
         cursorLayer.selectFirst();
         openBrowser.retried = true;
         host.scheduleTask(function () { openBrowser(where); openBrowser.retried = false; }, 150);
         return;
      }
      ip = insideInsertionPoint(where === "insideStart");
      if (!ip) return;
   } else {
      ip = hasDevice ? cursorDevice.afterDeviceInsertionPoint() : cursorTrack.endOfDeviceChainInsertionPoint();
   }
   if (browsing) { browserCloseBy = { who: "réouverture", t: new Date().getTime() }; browser.cancel(); }
   host.scheduleTask(function () { ip.browse(); }, 100);   // laisse l'ancien navigateur se fermer
}

/** Couche suivante / précédente du conteneur sélectionné, par la LISTE des couches (après un
 *  Undo, le curseur de couche de Bitwig pouvait rester accroché à une couche disparue). */
/** Position (0-15) de la couche sélectionnée dans le conteneur, -1 si Bitwig n'en désigne aucune
 *  (curseur perdu, typiquement après un Undo). */
function curLayerIndex() {
   for (var i = 0; i < 16; i++) if (layerBank.getItemAt(i).exists().get() && layerEq[i] && layerEq[i].get()) return i;
   return -1;
}
function stepLayer(d, done) {
   function fin() { if (done) done(); }
   var from = curLayerIndex(), lost = from < 0 || !cursorLayer.exists().get();
   // 1) voie normale : curseur de couche Bitwig (Layer / FX Layer / Selector)
   if (lost) cursorLayer.selectFirst(); else if (d > 0) cursorLayer.selectNext(); else cursorLayer.selectPrevious();
   host.scheduleTask(function () {
      var now = curLayerIndex();
      if (lost ? now >= 0 : now !== from) { fin(); return; }
      // cible attendue (par position)
      var t = lost ? 0 : from + (d > 0 ? 1 : -1);
      if (t < 0 || t > 15 || !layerBank.getItemAt(t).exists().get()) { fin(); return; }   // déjà au bout
      // 2) curseur figé (après un Undo) : on sélectionne la couche n°t dans Bitwig
      layerBank.getItemAt(t).selectInEditor();
      host.scheduleTask(function () {
         if (curLayerIndex() === t) { fin(); return; }
         // 3) dernier recours : on raccroche le curseur (re-sélection du conteneur) et on compte depuis la 1re
         cursorDevice.selectInEditor();
         cursorLayer.selectFirst();
         for (var k = 0; k < t; k++) cursorLayer.selectNext();
         host.scheduleTask(fin, 80);
      }, 80);
   }, 80);
}
/** Supprime une couche, repérée par sa POSITION : idx mémorisé (si la couche à cet endroit porte
 *  bien ce nom), sinon la couche sélectionnée, sinon recherche par nom en dernier recours. */
function deleteLayerNamed(name, idx) {
   var i = -1, cur = curLayerIndex();
   function ok(k) { return k >= 0 && k < 16 && layerBank.getItemAt(k).exists().get() && (name == null || String(layerBank.getItemAt(k).name().get()) === String(name)); }
   if (ok(idx)) i = idx;
   else if (ok(cur)) i = cur;
   else for (var k = 0; k < 16; k++) if (ok(k)) { i = k; break; }
   if (i < 0) return false;
   var L = layerBank.getItemAt(i), before = layerCount();
   L.deleteObject();
   // vérification : si rien n'a disparu, un 2e essai sur la même couche, puis un message.
   // (Plus de commande « Supprimer » de Bitwig : elle agit sur ce qui a le focus, parfois le
   //  conteneur entier — bug du 17 nov.)
   host.scheduleTask(function () {
      if (layerCount() < before) return;
      L.deleteObject();
      host.scheduleTask(function () {
         if (layerCount() >= before) popup("Bitwig n'a pas supprimé la couche « " + name + " » : supprime-la à la souris (rien d'autre n'a été supprimé)");
         resyncDeviceCursor();
      }, 200);
   }, 200);
   return true;
}
function siblingCount() { var n = 0; for (var i = 0; i < 64; i++) if (siblings.getItemAt(i).exists().get()) n++; return n; }
/** Après une suppression ou un Undo : si le curseur de device ne désigne plus rien, on le remet
 *  sur le 1er device de la piste et on oublie l'état « dans une couche » s'il n'est plus vrai.
 *  (Bug du 17 nov. : contrôles de la couche invisibles après suppression / Undo.) */
function resyncDeviceCursor() {
   host.scheduleTask(function () {
      if (!cursorDevice.exists().get()) { cursorDevice.selectFirstInChannel(cursorTrack); inLayerDepth = 0; inLayerName = ""; inLayerIdx = -1; }
      else if (!cursorDevice.isNested().get()) { inLayerDepth = 0; inLayerName = ""; inLayerIdx = -1; }
      host.requestFlush();
   }, 250);
}
function layerCount() { var n = 0; for (var i = 0; i < 16; i++) if (layerBank.getItemAt(i).exists().get()) n++; return n; }
/** Supprime le device sélectionné et garde la main : on passe d'abord sur le device voisin de
 *  la même chaîne (précédent, sinon suivant), puis on supprime l'ancien PAR SA PLACE dans la
 *  chaîne. Dernier device d'une couche : la couche vide est supprimée, retour au conteneur. */
function deleteDeviceKeepControl() {
   if (!cursorDevice.exists().get()) { popup("Aucun device à supprimer"); return; }
   var dn = String(cursorDevice.name().get()), pos = cursorDevice.position().get(), nested = cursorDevice.isNested().get();
   var target = (pos >= 0 && pos < 64) ? siblings.getItemAt(pos) : null;
   if (!target || !target.exists().get() || String(target.name().get()) !== dn) {   // place incertaine : suppression simple
      cursorDevice.deleteObject(); popup("Device supprimé : " + dn + " (Undo pour annuler)"); return;
   }
   var nb = null;
   if (pos > 0 && siblings.getItemAt(pos - 1).exists().get()) nb = siblings.getItemAt(pos - 1);
   else if (pos + 1 < 64 && siblings.getItemAt(pos + 1).exists().get()) nb = siblings.getItemAt(pos + 1);
   var gen = ++navGen, countBefore = siblingCount();
   if (nb) {
      cursorDevice.selectDevice(nb);
      host.scheduleTask(function () {
         if (gen !== navGen) return;
         target.deleteObject();
         popup("Device supprimé : " + dn + " — sur " + cursorDevice.name().get() + " (Undo pour annuler)");
         host.scheduleTask(function () {                   // vérification par le nombre de devices de la chaîne
            if (siblingCount() < countBefore) { showDeviceLocation(true); return; }
            target.deleteObject();                         // 2e essai sur le MÊME device (jamais « Supprimer » global)
            host.scheduleTask(function () {
               if (siblingCount() >= countBefore) popup("Bitwig n'a pas supprimé « " + dn + " » : supprime-le à la souris (rien d'autre n'a été supprimé)");
               if (nb.exists().get()) cursorDevice.selectDevice(nb);
               resyncDeviceCursor();
               showDeviceLocation(true);
            }, 200);
         }, 200);
      }, 100);
      return;
   }
   // plus aucun device dans cette chaîne
   if (nested && inLayerDepth && inLayerName) {
      var ln = inLayerName, li = inLayerIdx;
      cursorDevice.selectParent();
      host.scheduleTask(function () {
         if (gen !== navGen) return;
         if (cursorDevice.hasLayers().get() && deleteLayerNamed(ln, li)) {
            inLayerDepth = 0; inLayerName = ""; inLayerIdx = -1;
            popup("Dernier device supprimé — couche « " + ln + " » supprimée (Undo pour annuler)");
         } else { target.deleteObject(); popup("Device supprimé : " + dn); }
      }, 180);
      return;
   }
   if (nested) {
      cursorDevice.selectParent();
      host.scheduleTask(function () { if (gen === navGen) { target.deleteObject(); popup("Device supprimé : " + dn + " — sur " + cursorDevice.name().get()); } }, 180);
      return;
   }
   cursorDevice.deleteObject(); popup("Device supprimé : " + dn + " (Undo pour annuler)");
}
/** Delete + Shift + clic molette : supprime la couche courante (sur le conteneur, ou dedans). */
function deleteCurrentLayer() {
   function del(name, idx) {
      if (!cursorDevice.hasLayers().get()) { popup("Pas de couche à supprimer ici"); return; }
      if (idx == null) { idx = curLayerIndex(); name = idx >= 0 ? layerBank.getItemAt(idx).name().get() : String(cursorLayer.name().get()); }
      if (deleteLayerNamed(name, idx)) { inLayerDepth = 0; inLayerName = ""; inLayerIdx = -1; popup("Couche supprimée : " + name + " (Undo pour annuler)"); }
      else popup("Couche introuvable : " + name);
   }
   if (inLayerDepth && cursorDevice.isNested().get() && !cursorDevice.hasLayers().get()) {
      var nm = inLayerName, ix = inLayerIdx;
      cursorDevice.selectParent(); host.scheduleTask(function () { del(nm, ix); }, 180);
   } else del();
}

/** Groupe sans aucune couche : l'API n'a pas de « nouvelle couche ». On cherche une action
 *  Bitwig qui en ajoute une (raccourcis clavier) ; sinon on affiche celles qui existent. */
var layerAction = null, layerActionScanned = false;
function addFirstLayer() {
   if (!layerActionScanned) {
      layerActionScanned = true;
      var acts = application.getActions(), found = [];
      for (var i = 0; i < acts.length; i++) {
         var id = String(acts[i].getId()), nm = String(acts[i].getName()), t = id + " " + nm;
         if (/layer|couche|chain/i.test(t)) { found.push(acts[i]); println("Action couche : " + id + " — " + nm); }
      }
      for (var j = 0; j < found.length && !layerAction; j++) {
         var tt = String(found[j].getId()) + " " + String(found[j].getName());
         if (/(add|insert|new|create|ajout)/i.test(tt) && /layer|couche/i.test(tt)) layerAction = found[j];
      }
      if (!layerAction) {
         var names = []; for (var f = 0; f < found.length && f < 6; f++) names.push(String(found[f].getName()));
         popup("Groupe vide : l'API ne sait pas créer de couche. " + (found.length ? "Actions trouvées : " + names.join(" | ") : "Aucune action couche dans Bitwig") + " — ajoute la 1re couche à la souris");
         return;
      }
   }
   if (!layerAction) { popup("Groupe vide : ajoute la 1re couche à la souris, ensuite Shift + Pas 2 ×2 fonctionne"); return; }
   cursorDevice.selectInEditor();
   layerAction.invoke();
   popup("Nouvelle couche : " + String(layerAction.getName()));
}

function newLayerFromCurrent() {
   var src = cursorLayer.name().get();
   cursorLayer.duplicate();
   popup("Nouvelle couche (copie de " + src + ") — choisis l'instrument");
   host.scheduleTask(function () {
      cursorLayer.selectNext();                        // la copie est placée juste après
      host.scheduleTask(function () {
         var ip2 = layerFirstDevice.exists().get() ? layerFirstDevice.replaceDeviceInsertionPoint() : cursorLayer.endOfDeviceChainInsertionPoint();
         if (browsing) { browserCloseBy = { who: "réouverture", t: new Date().getTime() }; browser.cancel(); }
         host.scheduleTask(function () { ip2.browse(); }, 100);
      }, 200);
   }, 250);
}

/** Point d'insertion À L'INTÉRIEUR du conteneur sélectionné :
 *  Drum Machine -> fin de la chaîne du pad sélectionné ; Layer / Selector -> fin de la
 *  couche courante. Device qui n'est pas un conteneur -> après lui (comme l'appui simple). */
function insideInsertionPoint(atStart) {
   if (!cursorDevice.exists().get()) return atStart ? cursorTrack.startOfDeviceChainInsertionPoint() : cursorTrack.endOfDeviceChainInsertionPoint();
   if (cursorDevice.hasDrumPads().get()) {
      var idx = S.selectedPitch - S.drumBase;
      if (idx < 0 || idx > 31) { popup("Choisis d'abord un pad (Shift + pad)"); return null; }
      popup("Insertion dans le pad " + (drumPads.getItemAt(idx).name().get() || noteName(S.selectedPitch)));
      return atStart ? drumPads.getItemAt(idx).startOfDeviceChainInsertionPoint() : drumPads.getItemAt(idx).endOfDeviceChainInsertionPoint();
   }
   if (cursorDevice.hasLayers().get()) {
      if (!cursorLayer.exists().get()) { addFirstLayer(); return null; }
      popup("Insertion dans la couche " + cursorLayer.name().get() + " (Mute + clic molette pour en changer)");
      return atStart ? cursorLayer.startOfDeviceChainInsertionPoint() : cursorLayer.endOfDeviceChainInsertionPoint();
   }
   if (cursorDevice.hasSlots().get()) {               // Chain (FX, Note FX, Instrument) : dans sa chaîne
      var sn = cursorDevice.slotNames().get();
      if (!sn || !sn.length) { popup("Pas de chaîne interne dans ce device"); return null; }
      try { chainSlot.selectSlot(sn[0]); } catch (e) {}
      popup("Insertion dans la chaîne « " + sn[0] + " » de " + cursorDevice.name().get());
      return atStart ? chainSlot.startOfDeviceChainInsertionPoint() : chainSlot.endOfDeviceChainInsertionPoint();
   }
   // pas un conteneur : comme l'appui simple
   if (atStart) return drumDevice.exists().get() ? drumDevice.beforeDeviceInsertionPoint() : cursorTrack.startOfDeviceChainInsertionPoint();
   return cursorDevice.afterDeviceInsertionPoint();
}

/** Crée une piste juste après la piste sélectionnée, la sélectionne et l'arme. */
function newTrack(kind) {
   markUiBusy();
   var pos = cursorTrack.position().get() + 1;
   if (kind === "audio") application.createAudioTrack(pos);
   else if (kind === "effect") application.createEffectTrack(-1);   // les pistes FX vont à la fin
   else application.createInstrumentTrack(pos);
   popup(kind === "audio" ? "Nouvelle piste audio" : kind === "effect" ? "Nouvelle piste FX" : "Nouvelle piste MIDI — choisis l'instrument");
   host.scheduleTask(function () {
      armFollowSelection();
      if (kind === "instrument") openBrowser("start");             // choisir l'instrument tout de suite
   }, 350);
}

/** Type de device : Tout, puis chaque élément de la colonne (Instruments, Effets audio…). */
function deviceTypeList() {
   // Même ordre que les icônes de Bitwig : Tout, Instrument, Effet audio, Effet de note, puis le reste
   var order = ["instrument", "effet audio", "audio fx", "effet de note", "note fx"];
   var items = [];
   for (var i = 0; i < 12; i++) if (devTypeBank.getItemAt(i).exists().get()) items.push(devTypeBank.getItemAt(i));
   items.sort(function (a, b) {
      var ia = order.indexOf(String(a.name().get()).toLowerCase()), ib = order.indexOf(String(b.name().get()).toLowerCase());
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
   });
   return [devTypeWild].concat(items);
}
function stepDeviceType(d) {
   var list = deviceTypeList(), cur = 0;
   for (var i = 0; i < list.length; i++) if (list[i].isSelected().get()) cur = i;
   var nxt = (cur + d + list.length) % list.length;      // tourne en boucle dans les deux sens
   lastTypeAction = cur + "->" + nxt + " (" + list.length + " types)";
   browserScriptMove = new Date().getTime();
   list[nxt].isSelected().set(true);                        // 1re méthode : cocher l'élément
   host.scheduleTask(function () {
      if (list[nxt].isSelected().get()) return;              // ça a marché
      // 2e méthode : déplacer le curseur de la colonne
      // (la banque « sœurs » de DrivenByMoss a été retirée : elle plantait le script avec
      //  « This bank is not following any cursor »)
      try {
         if (d > 0) browserFilters[0].selectNext(); else browserFilters[0].selectPrevious();
      } catch (e) { println("Type : " + e); }
      host.scheduleTask(function () {
         if (deviceTypeName() === (list[cur].name().get() || "Tout"))
            popup("Type : Bitwig ignore encore le changement (reste « " + deviceTypeName() + " »). Clique l'icône à la souris, puis clic molette.");
      }, 150);
   }, 150);
}
function deviceTypeName() {
   var list = deviceTypeList();
   for (var i = 0; i < list.length; i++) if (list[i].isSelected().get()) return list[i].name().get() || "Tout";
   return "Tout";
}

var BROWSER_ACTIONS_DIAG = false;  // TEMPORAIRE : liste les actions Bitwig liées au navigateur
var browserActionIds = null;
function showBrowserActions() {
   if (!browserActionIds) {
      browserActionIds = [];
      var acts = application.getActions();
      for (var i = 0; i < acts.length; i++) {
         var id = String(acts[i].getId());
         if (/brows|device_?type|content_?type|filter|instrument|audio_?fx|note_?fx|effect/i.test(id)) browserActionIds.push(id);
      }
   }
   var chunk = browserActionIds.slice(0, 40).join("  ");
   popup("ACTIONS (" + browserActionIds.length + ") : " + chunk);
}

var BROWSER_DIAG = false;  // TEMPORAIRE : affiche toutes les 2 s ce que Bitwig répond
var lastTypeAction = "aucune";
function browserDiag() {
   if (!browsing || !BROWSER_DIAG) return;
   var dt = browserCols[0], items = deviceTypeList(), names = [];
   for (var i = 0; i < items.length; i++) names.push((items[i].isSelected().get() ? "*" : "") + (items[i].name().get() || "?"));
   popup("DIAG col=" + dt.exists().get() + "/" + dt.name().get() + " [" + names.join(",") + "] " + lastTypeAction);
   host.scheduleTask(browserDiag, 2000);
}

var lastMouseCol = { k: null, t: 0 };
var filterBanks = {};          // k -> { wild, bank } pour lire la sélection réelle d'une colonne
var lastSelName = {};          // k -> dernier nom sélectionné connu

/** Nom réellement sélectionné dans la colonne k (élément de la banque ou « Tout »). */
function selectedNameOf(k) {
   var fb = filterBanks[k];
   if (!fb) return String(browserFilters[k].name().get());
   var names = [];
   for (var i = 0; i < 32; i++) {
      var it = fb.bank.getItemAt(i);
      if (it.isSelected().get()) names.push(String(it.name().get()));
   }
   if (!names.length && fb.wild.isSelected().get()) names.push("*" + fb.wild.name().get());
   if (!names.length) names.push(String(browserFilters[k].name().get()));
   return names.join("|");
}

/** Surveillance régulière (0,2 s) des colonnes pendant que le navigateur est ouvert :
 *  plus fiable que les signaux de Bitwig, qui ratent souvent le 1er clic souris. */
function browserPoll() {
   if (!browsing) return;
   checkDrumMode();                                  // pads à jour pendant le Live Preview
   for (var k = 1; k < BROWSER_COLUMNS.length; k++) filterChanged(k);
   var r = String(browserResult.name().get());
   if (lastSelName[-1] !== r) { lastSelName[-1] = r; mouseFollow(-1); }
   host.scheduleTask(browserPoll, 200);
}

/** Une colonne a peut-être changé : on ne suit la souris que si la sélection a changé. */
function filterChanged(k) {
   if (!browsing) return;
   var name = selectedNameOf(k);
   if (lastSelName[k] === name) return;     // simple recalcul de liste : on ignore
   lastSelName[k] = name;
   mouseFollow(k);
}
/** Appelé quand une colonne change : si ce n'est pas le script, c'est la souris. */
var MOUSE_DIAG = false;   // TEMPORAIRE : affiche ce que le script voit quand une colonne change
function mouseFollow(k) {
   if (!browsing) return;
   var now = new Date().getTime();
   if (MOUSE_DIAG) host.scheduleTask(function () {
      popup("........................................................................ SOURIS col=" +
            (k === -1 ? "Résultats" : k === 0 ? "Type" : BROWSER_LABELS[k]) + " | actif=" + browserStepName(browserCol));
   }, 30);
   if (now - browserScriptMove < 700) return;                   // changement fait par le script
   // les résultats se recalculent parfois tard après un changement de filtre fait au script
   if (k === -1 && now - browserScriptMove < 1500) return;
   // un clic en Catégorie change aussi les Résultats : on garde la colonne cliquée
   if (k === -1 && lastMouseCol.k !== null && lastMouseCol.k !== -1 && now - lastMouseCol.t < 900) return;
   var step = (k === 0) ? "type" : k;
   var idx = browserSteps.indexOf(step);
   if (idx < 0 && typeof k === "number" && k > 0) {
      // Clic dans une autre colonne de filtre (Créateur, Tags, Emplacement…) : elle
      // remplace Catégorie comme étape du milieu, et la molette la suit
      browserSteps[1] = k;
      idx = 1;
   }
   if (idx < 0) return;
   lastMouseCol = { k: k, t: now };
   browserIdx[String(step)] = null;                            // position inconnue après un clic
   if (idx !== browserCol) { browserCol = idx; host.scheduleTask(showBrowserState, 50); }
}

/** Colonne du milieu selon le type : plug-ins -> Créateur (marques), sinon Catégorie. */
function middleColumnForType() {
   return /plug/i.test(deviceTypeName()) ? 2 : 1;
}
/** Shift + clic molette : Catégorie -> Créateur -> Tag -> Emplacement -> Fichier -> … */
function cycleMiddleColumn() {
   var order = [1, 2, 3, 4, 5, 6, 7], cur = order.indexOf(browserSteps[1]);
   browserSteps[1] = order[(cur + 1) % order.length];
   browserCol = 1;
   browserIdx[String(browserSteps[1])] = null;
   showBrowserState();
}

/** Curseur de la colonne active (Type -> Catégorie -> Résultats). */
function browserColumnCursor() {
   var k = browserSteps[browserCol];
   return (k === undefined || k === "type" || k < 0) ? browserResult : browserFilters[k];
}

function browserStepName(i) {
   var k = browserSteps[i];
   if (k === "type") return "Type";
   if (k === undefined || k < 0) return "Résultats";
   return browserCols[k].name().get() || BROWSER_LABELS[k];
}

/** Position connue dans la colonne active (0 = premier élément), null = inconnue
 *  (après un clic souris). Sert à ne JAMAIS remonter au-dessus du premier élément :
 *  à cet endroit, Bitwig validait le device en cours (bug constaté). */
var browserIdx = {};
function browserStepSafe(d) {
   var k = browserSteps[browserCol], key = String(k), idx = browserIdx[key];
   if (d < 0) {
      if (idx === 0) return;                                   // déjà tout en haut
      if (idx === undefined || idx === null) {
         // position inconnue : en Catégorie, « Toute catégorie » = tout en haut
         if (k !== -1 && k !== "type" && browserCols[k].getWildcardItem().isSelected().get()) return;
         d = -1;                                               // prudence : un seul cran
      } else d = Math.max(d, -idx);
   }
   if (idx !== undefined && idx !== null) browserIdx[key] = idx + d;
   browserStep(browserColumnCursor(), d);
}

/** Avance d'un ou plusieurs crans dans une colonne du navigateur. */
function browserStep(cursor, d) {
   browserScriptMove = new Date().getTime();
   for (var k = 0; k < Math.abs(d); k++) { if (d > 0) cursor.selectNext(); else cursor.selectPrevious(); }
   host.scheduleTask(showBrowserState, 60);
}


function showBrowserState() {
   if (!browsing) return;
   var parts = [];
   for (var k = 0; k < browserFilters.length; k++) {
      var v = browserFilters[k].name().get();
      if (v) parts.push(BROWSER_LABELS[k] + " : " + v);
   }
   var steps = [];
   for (var c = 0; c < browserSteps.length; c++) steps.push(c === browserCol ? "[" + browserStepName(c) + "]" : browserStepName(c));
   var cur = browserSteps[browserCol] === "type" ? deviceTypeName()
           : (browserColumnCursor().name().get() || "Tous");
   popup(steps.join(" › ") + "  :  " + cur + "     ▶ " + (browserResult.name().get() || "—") + "   " + parts.join(" · "));
}

/** Décale la fenêtre des 4 pistes d'un cran et sélectionne la piste du bouton 1. */
/** + / - : piste suivante / précédente À L'INTÉRIEUR du bloc des 4 boutons ; arrivé au
 *  bord du bloc, le bloc se décale d'une piste (la piste sélectionnée reste au bord). */
function moveTrackWindow(dir) {
   if (browsing) { popup("Ferme d'abord le navigateur (Back)"); return; }
   if (fxBtn()) { moveFxWindow(dir); return; }
   if (fxCtl) {                                       // mode Send, boutons sur les pistes : on décale le bloc
      var sc = trackBank4.scrollPosition().get(), cnt = trackBank4.itemCount().get();   // sans sélectionner
      var nsc = clamp(sc + dir, 0, Math.max(0, cnt - 4));
      if (nsc === sc) { popup(dir > 0 ? "Dernière piste" : "Première piste"); return; }
      trackBank4.scrollPosition().set(nsc);
      host.scheduleTask(showTrackWindow, 80);
      return;
   }
   var cur = -1;
   for (var t = 0; t < 4; t++) if (equals4[t].get()) cur = t;
   var target = (cur < 0 ? 0 : cur + dir);
   if (target >= 0 && target <= 3 && trackBank4.getItemAt(target).exists().get()) {
      selectTrackFromMove(trackBank4.getItemAt(target));
      return;
   }
   // Bord du bloc : on décale le bloc d'une piste, puis on sélectionne la piste du bord
   var scroll = trackBank4.scrollPosition().get(), count = trackBank4.itemCount().get();
   var absolute = scroll + Math.max(cur, 0);
   if (dir > 0 && absolute >= count - 1) { popup("Dernière piste"); return; }
   if (dir < 0 && absolute <= 0) { popup("Première piste"); return; }
   trackBank4.scrollPosition().set(clamp(scroll + dir, 0, Math.max(0, count - 4)));
   host.scheduleTask(function () {
      var edge = dir > 0 ? 3 : 0;
      while (edge > 0 && !trackBank4.getItemAt(edge).exists().get()) edge--;
      selectTrackFromMove(trackBank4.getItemAt(edge));
   }, 60);
}

/** + / - dans le bloc FX + Master : les 3 premiers boutons défilent dans toutes les pistes FX
 *  (comme les pistes) ; le 4e bouton reste le Master (sélection par son bouton). */
function moveFxWindow(dir) {
   var cur = -1;
   for (var t = 0; t < 3; t++) if (equalsFx[t].get()) cur = t;
   if (cur < 0) {                                     // depuis le Master (ou rien) : dernière FX visible
      for (var e = 2; e >= 0; e--) if (fxBank.getItemAt(e).exists().get()) { cursorTrack.selectChannel(fxBank.getItemAt(e)); return; }
      popup("Aucune piste FX"); return;
   }
   var target = cur + dir;
   if (target >= 0 && target <= 2 && fxBank.getItemAt(target).exists().get()) { cursorTrack.selectChannel(fxBank.getItemAt(target)); return; }
   var scroll = fxBank.scrollPosition().get(), count = fxBank.itemCount().get();
   if (dir > 0 && scroll + 3 < count) {
      fxBank.scrollPosition().set(scroll + 1);
      host.scheduleTask(function () { cursorTrack.selectChannel(fxBank.getItemAt(2)); }, 60); return;
   }
   if (dir < 0 && scroll > 0) {
      fxBank.scrollPosition().set(scroll - 1);
      host.scheduleTask(function () { cursorTrack.selectChannel(fxBank.getItemAt(0)); }, 60); return;
   }
   popup(dir > 0 ? "Dernière piste FX" : "Première piste FX");
}

/** Bouton de piste maintenu + + / − : groupe = déplier / replier ; piste = ses devices. */
function foldHeldTrack(open) {
   S.heldTrackUsed = true;
   if (fxBtn()) { popup("Pistes FX / Master : rien à déplier"); return; }
   var tr = trackBank4.getItemAt(S.heldTrack);
   if (tr.isGroup().get()) {
      tr.isGroupExpanded().set(open);
      popup(tr.name().get() + " : groupe " + (open ? "déplié" : "replié"));
      return;
   }
   var bank = trackDevBanks[S.heldTrack], n = 0;
   for (var d = 0; d < 16; d++) { var dev = bank.getItemAt(d); if (dev.exists().get()) { dev.isExpanded().set(open); n++; } }
   popup(tr.name().get() + " : " + n + " device" + (n > 1 ? "s" : "") + " " + (open ? "dépliés" : "repliés"));
}

/** Affiche dans Bitwig les 4 pistes tenues par les boutons. */
function showTrackWindow() {
   var names = [];
   for (var t = 0; t < 4; t++) {
      var tr = trackBank4.getItemAt(t);
      if (tr.exists().get()) names.push((t + 1) + ":" + tr.name().get());
   }
   popup(names.join("   "));
}

/** Cadre de couleur dans le lanceur de clips : 4 pistes en mode Note, 8x4 en Session. */
function updateIndications() {
   var t;
   for (t = 0; t < 4; t++) trackBank4.getItemAt(t).clipLauncherSlotBank().setIndication(true);
}

var lastTrackTap = { i: -1, t: 0 };   // double appui sur un bouton de piste
function onTrackButton(i, pressed) {
   if (!pressed) {
      if (S.heldTrack === i) {
         var pend = S.fxPend; S.fxPend = null;
         S.heldTrack = -1; S.heldFx = undefined;
         // FX / Master sélectionné : appui court = on passe sur la piste ; appui long (réglages
         // de mixage) = on reste sur la FX / le Master
         if (pend && pend.i === i && !S.heldTrackUsed && new Date().getTime() - pend.t < 400) {
            if (fxCtl) { exitFxCtl(false); popup("Mode Send terminé — " + pend.track.name().get()); }
            selectTrackFromMove(pend.track);
         }
      }
      return;
   }
   var isFx = fxBtn();
   var track = channelForButton(i);
   S.heldFx = isFx; S.heldTrack = i;
   S.heldTrackUsed = false;
   // Note/Session tenu + piste : Stop
   if (nsPress && !S.shift) {
      nsPress.used = true;
      if (isFx && i === 3) { popup("Master : pas de clips à arrêter"); return; }
      track.stop(); popup("Stop : " + track.name().get()); return;
   }
   // Shift + piste : FX / Master -> mode Send ; en mode Send, piste de base -> retour normal
   if (S.shift && !S.mute) {
      if (!(isFx && i === 3) && !track.exists().get()) return;   // (le Master n'a pas d'exists() suivi)
      if (fxCtl && !isFx) {                    // Send verrouillé : accès à la piste tant que Shift est tenu
         fxCtl.peek = true;
         cursorTrack.selectChannel(track);
         popup(track.name().get() + " sélectionnée — relâche Shift : boutons sur FX / Master");
      } else if (isFx) enterSend(track, true);   // Send : boutons revenus sur les pistes au relâchement de Shift
      return;
   }
   if (fxCtl && isFx) fxCtl.ch = track;              // mode Send : FX / Master courant
   if (isFx && i === 3) {                            // Master
      if (S.mute) { track.mute().toggle(); return; }
      selectChannelAny(track);
      popup("Master — encodeur 1 : pan, Volume : volume (bouton maintenu)");
      return;
   }
   if (S.mute) { if (S.shift) track.solo().toggle(); else track.mute().toggle(); return; }
   if (S.del) { track.deleteObject(); return; }
   if (S.copy) { track.duplicate(); return; }
   // Double appui sur un groupe : déplie / replie le groupe
   var nowT = new Date().getTime(), dblT = (lastTrackTap.i === i && nowT - lastTrackTap.t < 400);
   lastTrackTap = dblT ? { i: -1, t: 0 } : { i: i, t: nowT };
   if (dblT && !fxBtn() && track.isGroup().get()) {
      var open = !track.isGroupExpanded().get();
      track.isGroupExpanded().set(open);
      popup(track.name().get() + " : groupe " + (open ? "déplié" : "replié"));
      return;
   }
   // FX / Master sélectionné (mode Send ou non) : la sélection de la piste attend le relâchement
   if (!isFx && (fxCtl || cursorOnFx())) { S.fxPend = { i: i, t: new Date().getTime(), track: track }; return; }
   if (buttonIsSelected(i) && S.mode === MODE.NOTE) return;   // 17 nov. : plus d'affichage du device au 2e appui (seul ×2 groupe = déplier)
   selectTrackFromMove(track);                 // (en Session : sélection seule, on reste en Session)
}


// ============================================================================
//  10. ENCODEURS, VOLUME, MOLETTE
// ============================================================================

function onEncoder(i, delta) {
   // Bouton de piste maintenu : encodeurs 1 à 7 = sends 1 à 7, encodeur 8 = pan
   if (S.heldTrack >= 0) { mixerEncoder(channelForButton(S.heldTrack), i, delta); return; }
   // (les encodeurs restent sur les contrôles du device, même navigateur ouvert)
   var held = heldStepList();
   if (S.mode === MODE.NOTE && held.length) { editHeldSteps(i, delta, held); return; }
   noteTurn("D", "remote" + i);
   noteAutoMove(i, delta);                            // Capture des mouvements (rejeu en overdub)
   remotes.getParameter(i).inc(delta, S.shift ? 1024 : 128);
}

/** Affiche une valeur après un mouvement de potard. Bitwig met un instant à mettre à jour
 *  la valeur affichée : on attend un peu, et on n'affiche que le dernier mouvement. */
var valueGen = 0;

/** Toucher un potard : affiche ce qu'il règle et sa valeur, sans le tourner.
 *  k = 0..7 encodeurs, 8 = Volume, 9 = molette. */
/** Paramètre réglé par le potard k (0..7 encodeurs, 8 = Volume) dans la situation actuelle. */
function knobParameter(k) {
   if (S.heldTrack >= 0) {
      var ch = channelForButton(S.heldTrack);
      if (k === 8) return ch.volume();
      if (k === 7) return ch.pan();
      if (ch === masterTrack || fxBtn()) return null;
      var snd = ch.sendBank().getItemAt(k);
      return snd.exists().get() ? snd : null;
   }
   if (k === 8) return masterTrack.volume();
   if (k < 8 && !(S.mode === MODE.NOTE && heldStepList().length)) return remotes.getParameter(k);
   return null;
}
var autoErr = "";
function hasAuto(prm) { try { return !!(prm && prm.hasAutomation().get()); } catch (e) { autoErr = String(e); return false; } }

var lastVolTouch = 0, touchedPrm = [];
/** Doigt posé / levé sur un potard : on le signale à Bitwig (« touch »), comme la souris.
 *  Sans ça, Bitwig rend la main à l'automation entre deux crans : impossible de reprendre
 *  la main. Avec, le paramètre est repris (et enregistré en mode Touch) tant qu'on le tient. */
function knobTouchAutomation(k, on) {
   if (k === 8 && morph) {                              // Volume touché pendant un morph : il prend la main
      if (on) { morph.knob = true; popup("Morph au potard Volume : tourne pour aller de " + (morph.labelA || (morph.mA + 1)) + " à " + (morph.mB + 1) + " — lâche le potard pour figer"); return; }
      if (morph.knob) { popup("Morph figé à " + Math.round(morph.t * 100) + " %"); if (morph.t > 0.97) setActivePreset(morph.mB); morph = null; return; }
   }
   try {
      if (on) {
         var prm = knobParameter(k);
         if (!prm) return;
         prm.touch(true); touchedPrm[k] = prm;
      } else if (touchedPrm[k]) { touchedPrm[k].touch(false); touchedPrm[k] = null; }
   } catch (e) {}
}
function onKnobTouch(k, displayOnly) {
   if (k === 8 && morph && morph.knob) return;          // potard Volume = morph : pas d'info volume

   // Delete + toucher un potard : efface l'automation de ce paramètre
   if (S.del && k <= 8 && !displayOnly) {
      var prm = knobParameter(k);
      if (!prm) { popup("Rien à effacer sur ce potard"); return; }
      try { prm.deleteAllAutomation(); popup("Automation effacée" + (prm.name ? " : " + prm.name().get() : "")); return; }
      catch (e) {}
      automationActionScan();                          // API < 19 : on cherche une action Bitwig
      return;
   }
   var msg;
   if (k === 9) {
      msg = browsing ? "Molette : " + browserStepName(browserCol)
          : memLock ? "Molette : pages de macros de " + cursorDevice.name().get() + " — " + remotes.getName().get()
          : "Molette : " + cursorDevice.name().get() + " — page " + remotes.getName().get();
   } else if (k === 8) {
      if (S.heldTrack >= 0) { var vc = channelForButton(S.heldTrack); msg = vc.name().get() + " — Volume : " + vc.volume().displayedValue().get(); }
      else msg = "Master — Volume : " + masterTrack.volume().displayedValue().get();
   } else if (S.heldTrack >= 0) {
      var ch = channelForButton(S.heldTrack);
      if (k === 7) msg = ch.name().get() + " — Pan : " + ch.pan().displayedValue().get();
      else if (ch === masterTrack || fxBtn()) msg = ch.name().get() + " — encodeur " + (k + 1) + " : rien (encodeur 8 = pan)";
      else {
         var snd = ch.sendBank().getItemAt(k);
         msg = snd.exists().get() ? ch.name().get() + " — Send " + (k + 1) + " (" + snd.name().get() + ") : " + snd.displayedValue().get()
                                  : "Send " + (k + 1) + " : aucune piste FX";
      }
   } else if (S.mode === MODE.NOTE && heldStepList().length) {
      msg = "Pas maintenu — encodeur " + (k + 1) + " : " +
            ["vélocité", "longueur", "probabilité", "répétitions", "micro-transposition", "pan", "gain", "timbre"][k];
   } else {
      var prm = remotes.getParameter(k);
      msg = cursorDevice.name().get() + " — " + (prm.name().get() || ("encodeur " + (k + 1))) + " : " + (prm.displayedValue().get() || "—");
   }
   if (k <= 8 && hasAuto(knobParameter(k))) msg = "● " + msg + "  (automation)";
   else if (MEM_DIAG && k <= 8) msg += "  [auto : non" + (autoErr ? " — " + autoErr : "") + "]";
   popup(msg);
}

/** Réglages de piste au bouton de piste maintenu. */
function mixerEncoder(ch, i, delta) {
   var res = S.shift ? 1024 : 128;
   if (i === 7) {                                   // encodeur 8 : pan
      noteTurn(channelTag(S.heldTrack), "pan");
      ch.pan().inc(delta, res);
      mixerShowSoon(i);
      return;
   } else {                                         // encodeurs 1 à 7 : sends 1 à 7
      if (ch === masterTrack) { popup("Master : pas de sends (encodeur 8 = pan)"); return; }
      if (fxBtn()) { popup("Pistes FX : sends non disponibles (encodeur 8 = pan)"); return; }
      var snd = ch.sendBank().getItemAt(i);
      if (!snd.exists().get()) { popup("Send " + (i + 1) + " : aucune piste FX"); return; }
      noteTurn(channelTag(S.heldTrack), "send" + i);
      snd.inc(delta, res);
      mixerShowSoon(i);
   }
}

/** Pas maintenu + encodeur : édition des paramètres de note (NoteStep Bitwig). */
function editHeldSteps(enc, d, held) {
   var g = GRID_SIZES[S.gridIndex], label = "";
   for (var k = 0; k < held.length; k++) {
      S.heldSteps[held[k]].edited = true;
      forEachNoteAt(held[k], function (n) {
         switch (enc) {
            case 0: n.setVelocity(clamp(n.velocity() + d / 127, 0, 1));
                    label = "Vélocité " + Math.round(n.velocity() * 127); break;
            case 1: n.setDuration(Math.max(g / 10, n.duration() + d * g / 10)); // 10 % d'un pas par cran
                    label = "Longueur " + n.duration().toFixed(3) + " temps"; break;
            case 2: n.setIsChanceEnabled(true); n.setChance(clamp(n.chance() + d / 100, 0, 1));
                    label = "Probabilité " + Math.round(n.chance() * 100) + " %"; break;
            case 3: n.setIsRepeatEnabled(true);
                    n.setRepeatCount(clamp(n.repeatCount() + (d > 0 ? 1 : -1), 0, 16));
                    label = "Répétitions " + n.repeatCount(); break;
            case 4: n.setTranspose(clamp(n.transpose() + d * 0.1, -24, 24));
                    label = "Transpo " + n.transpose().toFixed(1) + " dt"; break;
            case 5: n.setPan(clamp(n.pan() + d / 64, -1, 1));
                    label = "Pan " + Math.round(n.pan() * 100); break;
            case 6: n.setGain(clamp(n.gain() + d / 100, 0, 1));
                    label = "Gain " + Math.round(n.gain() * 100) + " %"; break;
            case 7: n.setTimbre(clamp(n.timbre() + d / 64, -1, 1));
                    label = "Timbre " + Math.round(n.timbre() * 100); break;
         }
      });
   }
   if (label) popup(label);
}


/** Appelle fn(NoteStep) pour chaque note qui commence au pas x
 *  (drum : seulement la note sélectionnée ; instrument : toutes). */
function forEachNoteAt(x, fn) {
   for (var y = 0; y < 128; y++) {
      if (data16[y][x] !== 2) continue;
      if (S.isDrum && y !== S.selectedPitch) continue;
      fn(clip16.getStep(HW.CHANNEL, x, y));
   }
}

function onVolume(delta) {
   if (morph && morph.knob) {                           // morph au potard Volume
      morph.t = clamp(morph.t + delta * (S.shift ? 0.005 : 0.02), 0, 1);
      morph.sent = -1; applyMorph();
      return;
   }
   var res = S.shift ? 1024 : 128;
   var hs = heldStepList();
   if (S.mode === MODE.NOTE && hs.length) { editHeldSteps(0, delta, hs); return; }   // pas maintenu : vélocité
   // (vue Loop : plus d'édition de notes au Volume avec une mesure maintenue)
   var pads = Object.keys(S.heldPads);
   if (S.heldTrack >= 0) {
      var vch = channelForButton(S.heldTrack);
      noteTurn(channelTag(S.heldTrack), "vol");
      vch.volume().inc(delta, res);
      mixerShowSoon(8);
   }
   else if (S.heldSessionTrack >= 0) trackBank.getItemAt(S.heldSessionTrack).volume().inc(delta, res);
   else if (S.mode === MODE.NOTE && S.isDrum && pads.length)
      drumPads.getItemAt(drumIndex(parseInt(pads[0], 10))).volume().inc(delta, res);
   else { noteTurn("M", "vol"); masterTrack.volume().inc(delta, res); mixerShowSoon(8); }
}

function onWheel(d) {
   lastWheelTurn = new Date().getTime();
   if (scaleMode && scale16Held && !browsing) { cycleCustomScale(d > 0 ? 1 : -1); return; }   // pas 16 tenu + molette
   if (browsing) {                                                // navigateur : étape active
      if (browserSteps[browserCol] === "type") {
         stepDeviceType(d > 0 ? 1 : -1);
         host.scheduleTask(showBrowserState, 120);
      } else browserStepSafe(d * (S.shift ? 10 : 1));
      return;
   }
   if (q16.held) {                                                                   // pas 16 (après Shift) maintenu
      q16.used = true;
      if (S.shift) {                                                                 // Shift + molette : force du Quantize
         QUANTIZE_AMOUNT = clamp(Math.round((QUANTIZE_AMOUNT + d * 0.05) * 100) / 100, 0, 1);
         popup("Quantize " + Math.round(QUANTIZE_AMOUNT * 100) + " %");
      } else {                                                                       // molette seule : grille
         S.gridIndex = clamp(S.gridIndex + (d > 0 ? 1 : -1), 0, GRID_SIZES.length - 1);
         clip16.setStepSize(GRID_SIZES[S.gridIndex]);
         clip32.setStepSize(GRID_SIZES[S.gridIndex]);
         popup("Grille : " + GRID_NAMES[S.gridIndex]);
      }
      return;
   }
   var hs = heldStepList();
   if (S.mode === MODE.NOTE && hs.length) { editHeldSteps(1, d, hs); return; }       // pas maintenu : longueur
   // Vue Loop, une mesure maintenue + Shift + molette : point de lecture (play start) par 1/16,
   // librement, même en dehors de la boucle (Bitwig démarre le clip là, puis boucle)
   if (S.mode !== MODE.STEP32 && S.loopMode && S.loopHeldBar >= 0 && S.shift) {
      var ps = Math.max(0, clip16.getPlayStart().get() + d * 0.25);   // part toujours de la position actuelle
      clip16.getPlayStart().set(ps);
      var pb = Math.floor(ps / 4) + 1, pr = ps - (pb - 1) * 4;
      popup("Point de lecture : mesure " + pb + " + " + Math.round(pr * 4) + "/16");
      return;
   }
   // Vue Loop, mesure de début de boucle maintenue : la molette décale le début par 1/16
   if (S.mode !== MODE.STEP32 && S.loopMode && S.loopHeldBar >= 0 &&
       (loopNudge || S.loopHeldBar === Math.floor(clip16.getLoopStart().get() / 4))) {
      loopNudge = true;
      var st = Math.max(0, clip16.getLoopStart().get() + d * 0.25);   // 0,25 temps = 1/16
      setLoopStartLinked(st);
      var bar = Math.floor(st / 4) + 1, rest = st - (bar - 1) * 4;
      popup("Début de boucle : mesure " + bar + " + " + Math.round(rest * 4) + "/16");
      return;
   }
   // (vue Loop : plus d'édition des longueurs de notes à la molette avec une mesure maintenue)
   if (S.loop && S.loopMode && S.mode !== MODE.STEP32) {                               // vue Loop, Loop maintenu : fin de boucle par 1/16
      var ll = Math.max(0.25, clip16.getLoopLength().get() + d * 0.25);
      clip16.getLoopLength().set(ll); zoomLoopSoon();
      var end = clip16.getLoopStart().get() + ll, eb = Math.floor(end / 4) + 1, er = end - (eb - 1) * 4;
      popup("Fin de boucle : mesure " + eb + " + " + Math.round(er * 4) + "/16  (longueur " + (ll / 4).toFixed(2).replace(/\.?0+$/, "") + " mes.)");
      return;
   }
   if (S.loop) {                                                                     // Loop maintenu : longueur de boucle
      var g = GRID_SIZES[S.gridIndex];
      var len = Math.max(g, clip16.getLoopLength().get() + d * (S.shift ? g : 4));
      clip16.getLoopLength().set(len);
      popup("Boucle : " + (len / 4).toFixed(2).replace(/\.?0+$/, "") + " mesure(s)");
      return;
   }
   if (S.loopMode && S.mode !== MODE.STEP32 && S.wheelMode === WHEEL.DEVICE) {      // vue Loop : pas de navigation de devices
      if (S.shift) {                                                                 // Shift + molette : zoom de l'éditeur de notes
         if (uiBusy()) return;                                                       // jamais pendant l'ouverture du navigateur
         application.focusPanelBelow(); loopFocused = true;                          // le zoom agit sur le panneau du bas
         if (d > 0) application.zoomIn(); else application.zoomOut();
      } else popup("Vue Loop : Shift + molette = zoom, Loop + molette = fin, mesure de début + molette = début");
      return;
   }
   if (memLock && S.mode === MODE.NOTE && S.wheelMode === WHEEL.DEVICE) {           // mode Preset : pages de macros
      if (S.shift) { shiftWheelDevice(d); return; }                                // Shift + molette : couche / device
      if (d > 0) remotes.selectNextPage(false); else remotes.selectPreviousPage(false);
      host.scheduleTask(function () {
         popup(cursorDevice.name().get() + " — page " + (remotes.selectedPageIndex().get() + 1) + "/" +
               remotes.pageCount().get() + " : " + remotes.getName().get());
      }, 80);
      return;
   }
   switch (S.wheelMode) {
      case WHEEL.WORKFLOW:
         if (S.shift) {
            QUANTIZE_AMOUNT = clamp(Math.round((QUANTIZE_AMOUNT + d * 0.05) * 100) / 100, 0, 1);
            popup("Quantize " + Math.round(QUANTIZE_AMOUNT * 100) + " %");
         } else {
            S.gridIndex = clamp(S.gridIndex + (d > 0 ? 1 : -1), 0, GRID_SIZES.length - 1);
            clip16.setStepSize(GRID_SIZES[S.gridIndex]);
            clip32.setStepSize(GRID_SIZES[S.gridIndex]);
            popup("Grille : " + GRID_NAMES[S.gridIndex]);
         }
         break;
      case WHEEL.TEMPO:
         transport.tempo().incRaw(d * (S.shift ? 0.1 : 1));
         popup("Tempo : " + transport.tempo().displayedValue().get());
         break;
      case WHEEL.GROOVE:
         groove.getShuffleAmount().inc(d, 100);
         popup("Shuffle : " + groove.getShuffleAmount().displayedValue().get());
         break;
      case WHEEL.SCALE:
         if (S.shift) S.scaleIndex = (S.scaleIndex + (d > 0 ? 1 : SCALES.length - 1)) % SCALES.length;
         else S.root = (S.root + (d > 0 ? 1 : 11)) % 12;
         updateNoteInput();
         pushBitwigKey();                                           // gamme de Bitwig synchronisée
         popup(scaleLabel());
         break;
      default: // DEVICE
         // Après une pause, on réaffiche le panneau (il a pu être fermé à la souris).
         // Uniquement avec une action « afficher » : une bascule le refermerait.
         var nowT = new Date().getTime();
         if (devicePanelShowOnly && nowT - lastDeviceWheel > 5000) devicesShown = false;
         lastDeviceWheel = nowT;
         showDevices();
         // Molette = pages de macros du device ; Shift + molette = device suivant / précédent
         if (!S.shift) {
            if (d > 0) remotes.selectNextPage(false); else remotes.selectPreviousPage(false);
            host.scheduleTask(function () {
               popup(cursorDevice.name().get() + " — page " + (remotes.selectedPageIndex().get() + 1) + "/" +
                     remotes.pageCount().get() + " : " + remotes.getName().get());
            }, 80);
            return;
         }
         shiftWheelDevice(d);
   }
}
/** Shift + molette : sur un Layer / Selector = choisir la couche ; sinon device suivant / précédent. */
var inLayerDepth = 0;   // entré dans une couche d'un Layer / Selector (Shift + molette = couches du parent)
function shiftWheelDevice(d) {
   // Dans une couche : Shift + molette fait défiler les couches du conteneur parent et on reste
   // dedans (1er device de la couche suivante)
   if (inLayerDepth && cursorDevice.isNested().get() && !cursorDevice.hasLayers().get()) {
      var gen = ++navGen;
      cursorDevice.selectParent();
      host.scheduleTask(function () {
         if (gen !== navGen) return;
         if (!cursorDevice.hasLayers().get()) { inLayerDepth = 0; popup(cursorDevice.name().get()); return; }
         stepLayer(d, function () {
            if (gen !== navGen) return;
            var ln = cursorLayer.name().get(); inLayerName = ln; inLayerIdx = curLayerIndex();
            if (layerFirstDevice.exists().get()) { goToDevice(layerFirstDevice, function () { popup("Couche : " + ln + " — " + cursorDevice.name().get()); }); }
            else { inLayerDepth = 0; popup("Couche : " + ln + " (vide — Shift + Pas 2 pour y ajouter)"); }
         });
      }, 150);
      return;
   }
   if (cursorDevice.hasLayers().get()) {
      stepLayer(d, function () { popup(cursorDevice.name().get() + " — couche : " + cursorLayer.name().get() + " (clic molette : entrer)"); });
      return;
   }
   if (d > 0) cursorDevice.selectNext(); else cursorDevice.selectPrevious();
   navGen++;
   revealSoon(function () { showDeviceLocation(true); });
}

function onWheelClick() {
   if (S.del && S.shift && !browsing) { deleteCurrentLayer(); return; }   // Delete + Shift + clic : supprime la couche
   if (S.del && !browsing) { deleteDeviceKeepControl(); return; }         // Delete + clic molette : supprime le device
   if (S.shift && !browsing) {                         // Shift + clic molette : device on / off (avant tout le reste)
      cursorDevice.isEnabled().toggle();
      host.scheduleTask(function () { popup(cursorDevice.name().get() + (cursorDevice.isEnabled().get() ? " : activé" : " : désactivé (bypass)")); }, 80);
      return;
   }
   if (S.loopMode && !browsing) { zoomLoopSoon(); popup("Zoom sur la boucle"); return; }   // vue Loop : recadrer
   if (browsing && new Date().getTime() - lastWheelTurn < 300) { popup("Clic molette ignoré (molette en mouvement)"); return; }
   if (browsing) {                                   // clic : colonne suivante, puis valider
      if (S.shift) { cycleMiddleColumn(); return; }  // Shift + clic : colonne du milieu suivante
      if (browserCol < browserSteps.length - 1) {
         if (browserCol === 0) browserSteps[1] = middleColumnForType();
         browserCol++;
         browserScriptMove = new Date().getTime();
         if (browserSteps[browserCol] !== "type") {
            var target = browserColumnCursor(), key = String(browserSteps[browserCol]);
            target.selectFirst();                               // 1er élément
            browserIdx[key] = 0;
            // la liste des résultats se recalcule après le choix de catégorie : on
            // resélectionne le 1er élément une fois la liste à jour
            host.scheduleTask(function () { browserScriptMove = new Date().getTime(); target.selectFirst(); browserIdx[key] = 0; }, 200);
            host.scheduleTask(function () { browserScriptMove = new Date().getTime(); target.selectFirst(); browserIdx[key] = 0; showBrowserState(); }, 450);
         }
         host.scheduleTask(showBrowserState, 80);
      }
      else {
         var added = browserResult.name().get();
         browserCloseBy = { who: "clic molette (valider)", t: new Date().getTime() };
         browser.commit(); popup("Ajouté : " + added);
      }
      return;
   }
   if (S.wheelMode === WHEEL.SCALE) {
      S.inKey = !S.inKey; updateNoteInput(); popup(scaleLabel()); return;
   }
   if (S.wheelMode !== WHEEL.DEVICE) { setDeviceWheel(); return; }
   showDevices();
   if (S.mute) nextLayer();                                      // Mute + clic : couche suivante
   else enterDevice();                                           // clic : entrer dans le sous-device
}

// ---------------------------------------------------------------------------
//  Vues Bitwig et navigation dans les sous-devices
// ---------------------------------------------------------------------------

/** Passe la molette en navigation devices et affiche le panneau Devices. */
function setDeviceWheel() {
   S.wheelMode = WHEEL.DEVICE;
   showDevices();
   host.scheduleTask(showDeviceLocation, 50);
}

/** Affiche le panneau Devices de Bitwig. L'API ne permet que de le basculer :
 *  le script retient ce qui est affiché en bas. Shift + Back rebascule si ça se décale. */
var AUTO_PANELS = false;   // false : le panneau du bas ne s'ouvre/ferme QU'AVEC Shift + Back
var AUTO_FOLD = true;      // dépliage / repliage automatique des devices (entrée / Back) — en test

function showDevices() {
   if (!AUTO_PANELS) return;
   if (devicesShown && !noteEditorShown) return;
   if (devicePanelAction) devicePanelAction.invoke();   // affiche / met au premier plan
   else application.toggleDevices();                    // repli : simple bascule
   devicesShown = true;
   noteEditorShown = false;        // le panneau du bas n'affiche qu'un élément à la fois
}

/** LEDs sous les encodeurs : le format exact n'est pas documenté. Chaque appui sur
 *  Shift + Pas 3 essaie un format (tout en rouge), puis éteint le précédent. */
var encLedFormat = -1, ENC_LED_FORMATS = 5;
function hex2(n) { var h = (n & 0x7F).toString(16).toUpperCase(); return h.length < 2 ? "0" + h : h; }
function encoderLedSend(fmt, colors) {
   var i, out = host.getMidiOutPort(0), msg;
   switch (fmt) {
      case 0:                                         // SysEx 59/16 + 8 couleurs
         msg = "F000211D01013B10"; for (i = 0; i < 8; i++) msg += hex2(colors[i]); sendSysex(msg + "F7"); break;
      case 1:                                         // SysEx 59/16 + (encodeur, couleur) par encodeur
         for (i = 0; i < 8; i++) sendSysex("F000211D01013B10" + hex2(i) + hex2(colors[i]) + "F7"); break;
      case 2:                                         // SysEx 59 + (16 + encodeur, couleur)
         for (i = 0; i < 8; i++) sendSysex("F000211D01013B" + hex2(16 + i) + hex2(colors[i]) + "F7"); break;
      case 3:                                         // note des « touch » 0-7, valeur = couleur
         for (i = 0; i < 8; i++) out.sendMidi(0x90 | HW.CHANNEL, i, colors[i]); break;
      case 4:                                         // CC des encodeurs 71-78, valeur = couleur
         for (i = 0; i < 8; i++) out.sendMidi(0xB0 | HW.CHANNEL, 71 + i, colors[i]); break;
   }
}
/** LEDs sous les encodeurs (CC 71-78, valeur = couleur) : rouge = le paramètre a de
 *  l'automation ; rouge clignotant = automation reprise à la main (override actif). */
var blinkOn = false, blinkCount = 0;
function flushEncoderLeds() {
   var override = false;
   try { override = transport.isAutomationOverrideActive().get(); } catch (e) {}
   for (var k = 0; k < 9; k++) {
      var c = COLOR.OFF, prm = knobParameter(k);
      if (prm && hasAuto(prm)) c = (override && !blinkOn) ? COLOR.OFF : COLOR.RED;
      sendCC(k < 8 ? 71 + k : 79, c);
   }
}

/** API 17 : pas de commande d'effacement d'automation par paramètre. On liste les actions
 *  de Bitwig liées à l'automation (écran + console) pour trouver un équivalent. */
var autoScanDone = false;
function automationActionScan() {
   if (autoScanDone) { popup("Effacement d'automation : pas disponible avec cette version de l'API Bitwig"); return; }
   autoScanDone = true;
   var acts = application.getActions(), found = [];
   for (var i = 0; i < acts.length; i++) {
      var id = String(acts[i].getId()), nm = String(acts[i].getName());
      if (/automat/i.test(id + " " + nm)) { found.push(nm + " [" + id + "]"); println("Action automation : " + id + "  —  " + nm); }
   }
   popup(found.length ? "Actions automation (" + found.length + ") : " + found.slice(0, 8).join(" | ") : "Aucune action automation dans Bitwig");
}

/** Shift + Pas 3 : l'API de Bitwig n'a pas de fonction « ajouter un modulateur ». On cherche
 *  parmi les actions de Bitwig (celles des raccourcis clavier) une action de modulateur.
 *  1er appui : liste les actions trouvées (écran + console) ; si une action d'ajout est
 *  reconnue, elle est lancée. */
var modulatorAction = null, modulatorScanned = false;

/** Écrit dans la console les actions Bitwig qui pourraient afficher / masquer
 *  la chaîne d'un pad ou d'une couche (ce que l'API ne propose pas directement). */
function listChainActions() {
   var acts = application.getActions();
   for (var i = 0; i < acts.length; i++) {
      var id = String(acts[i].getId()), name = String(acts[i].getName());
      if (/chain|nested|layer|drum|pad|expand|collapse|show|hide/i.test(id + " " + name) && /chain|nested|layer|pad|slot/i.test(id + " " + name))
         println("Action chaîne candidate : " + id + "  —  " + name);
   }
}

/** Cherche parmi les actions de Bitwig celle qui affiche le panneau Devices.
 *  On préfère une action « afficher / focus » à une bascule, qui le masquerait
 *  s'il était déjà ouvert. Le choix est écrit dans la console du script. */
function findDevicePanelAction() {
   var acts = application.getActions(), found = [], i, id;
   for (i = 0; i < acts.length; i++) {
      id = String(acts[i].getId());
      if (/device/i.test(id) && /panel|chain/i.test(id)) found.push(acts[i]);
   }
   for (i = 0; i < found.length; i++) println("Action panneau Devices disponible : " + found[i].getId() + "  —  " + found[i].getName());
   var prefs = [/^(show|focus)_device_(panel|chain)$/i, /^(show|focus).*device.*(panel|chain)/i,
                /focus_or_toggle.*device/i, /device.*(panel|chain)/i];
   for (var p = 0; p < prefs.length; p++) {
      for (i = 0; i < found.length; i++) {
         id = String(found[i].getId());
         if (prefs[p].test(id) && !/^toggle_/i.test(id)) {
            devicePanelShowOnly = !/toggle/i.test(id);
            println("Panneau Devices : action utilisée = " + id + (devicePanelShowOnly ? " (affichage seul)" : " (focus/bascule)"));
            return found[i];
         }
      }
   }
   println("Panneau Devices : aucune action « afficher » trouvée, repli sur toggleDevices()");
   return null;
}

/** Panneau du bas : affiche les Devices / l'éditeur de notes / masque. */
function panelShowDevices() {
   if (bottomPanel === "devices") return;
   application.toggleDevices();                 // remplace l'éditeur de notes, ou ouvre le panneau
   bottomPanel = "devices";
}
function panelShowNote() {
   if (bottomPanel === "note") return;
   application.toggleNoteEditor();
   bottomPanel = "note";
}
function panelHide() {
   if (bottomPanel === "devices") application.toggleDevices();
   else if (bottomPanel === "note") application.toggleNoteEditor();
   bottomPanel = "none";
}
/** Revient à ce qui était affiché avant la vue Loop. */
function panelRestore(prev) {
   if (prev === "none") panelHide(); else panelShowDevices();
}
/** Vue Loop : se place sur le bon clip de la piste sélectionnée, sans passer par la Session.
 *  Priorité : clip en lecture / en enregistrement, puis clip sélectionné, puis 1er clip. */
function loopPickClip() {
   var i, sl, target = -1, sel = selectedSlotIndex();
   for (i = 0; i < 8 && target < 0; i++) { sl = cursorSlots.getItemAt(i); if (sl.isPlaying().get() || sl.isRecording().get()) target = i; }
   if (target < 0 && sel >= 0 && cursorSlots.getItemAt(sel).hasContent().get()) target = sel;
   for (i = 0; i < 8 && target < 0; i++) if (cursorSlots.getItemAt(i).hasContent().get()) target = i;
   if (target < 0) { popup("Vue Loop : aucun clip sur cette piste"); return; }
   if (target !== sel) cursorSlots.getItemAt(target).select();   // sélection seule : ne lance pas le clip
   S.page16 = 0;
}

/** Entrée / sortie de la vue Loop : l'éditeur de notes apparaît tout seul, puis on revient
 *  à l'écran précédent en sortant (Loop ou Back). */
function setLoopMode(on) {
   if (S.loopMode === on) return;
   S.loopMode = on; S.loopHeldBar = -1; loopNudge = false;
   if (!on) showBar(Math.floor(clip16.getLoopStart().get() / 4));   // vue pas : sur la 1re mesure de la boucle
   if (on) {
      loopPickClip();
      panelBeforeLoop = bottomPanel; panelShowNote();
      loopFocused = false;
      host.scheduleTask(function () { if (S.loopMode && !uiBusy()) { application.focusPanelBelow(); loopFocused = true; zoomLoopSoon(); } }, 120); // zoom = éditeur de notes
   }
   else panelRestore(panelBeforeLoop);
   popup(on ? "Vue Loop : les pas sont les mesures" : "Vue pas");
}


/** Back : quitte un menu molette, sinon remonte au device parent. Shift + Back : panneau Devices. */
var lastBackT = 0, shiftLoopPending = 0;
/** Affiche la vue Devices : action « afficher » de Bitwig si elle existe (sans risque de
 *  masquer), sinon bascule d'après l'état suivi par le script. */
function forceDevicesView() {
   // Bitwig ne dit pas ce que montre le panneau du bas : « éditeur de notes » puis « Devices »
   // finit TOUJOURS sur les Devices, quel que soit l'état de départ (masqué, notes ou devices).
   if (devicePanelAction && devicePanelShowOnly) { devicePanelAction.invoke(); bottomPanel = "devices"; return; }
   application.toggleNoteEditor();
   application.toggleDevices();
   bottomPanel = "devices";
}
function onBack() {
   if (browsing) {                                   // Back : colonne précédente, puis fermer
      if (browserCol > 0) { browserCol--; host.scheduleTask(showBrowserState, 60); }
      else { browserCloseBy = { who: "Back (annuler)", t: new Date().getTime() }; browser.cancel(); popup("Navigateur fermé"); }
      return;
   }
   // Shift + Back : seul moyen de faire disparaître le panneau du bas (et de le rouvrir)
   if (S.shift) {
      if (bottomPanel === "none") { panelShowDevices(); popup("Panneau Devices affiché"); }
      else { panelHide(); popup("Panneau du bas masqué (Shift + Back pour le rouvrir)"); }
      return;
   }
   // Back ramène TOUJOURS à la vue Devices (panneau du bas + molette sur les devices)
   var nowB = new Date().getTime(), dbl = nowB - lastBackT < 400;
   lastBackT = nowB;
   if (S.loopMode) {                                  // vue Loop : on en sort, vers les Devices
      setLoopMode(false); forceDevicesView(); if (S.wheelMode !== WHEEL.DEVICE) setDeviceWheel(); return;
   }
   var wasDevices = bottomPanel === "devices" && S.wheelMode === WHEEL.DEVICE;
   forceDevicesView();                                // toujours la page Devices, quel que soit l'état
   if (!wasDevices) { if (S.wheelMode !== WHEEL.DEVICE) setDeviceWheel(); popup("Vue Devices"); return; }
   if (S.wheelMode !== WHEEL.DEVICE) { setDeviceWheel(); return; }
   if (cursorDevice.isNested().get()) {
      var gen = ++navGen;          // annule les affichages encore en attente (sinon re-sélection)
      // On referme l'élément qu'on quitte (le dernier ouvert) ; le parent reste ouvert
      // 1) on referme l'élément quitté pendant qu'il est encore sélectionné
      if (AUTO_FOLD) {
         cursorDevice.isExpanded().set(false);
         cursorDevice.isRemoteControlsSectionVisible().set(false);
      }
      if (cursorDevice.isWindowOpen().get()) cursorDevice.isWindowOpen().set(false);
      // 2) on laisse Bitwig l'appliquer, puis on remonte au parent (qui reste ouvert)
      host.scheduleTask(function () {
         if (gen !== navGen) return;
         cursorDevice.selectParent();
         inLayerDepth = 0;
         host.scheduleTask(function () {
            if (gen !== navGen) return;
            // Pas de selectInEditor ici : si Bitwig n'a pas encore déplacé sa sélection,
            // il resélectionnait l'enfant (aller-retour parent / enfant). Le panneau
            // défile tout seul quand la sélection change.
            cursorDevice.isRemoteControlsSectionVisible().set(true);
            showDeviceLocation(true);
         }, 200);
      }, 80);
   } else popup("Déjà au premier niveau de la piste");
}

/** Clic molette : entre dans le device sélectionné.
 *  Drum Machine -> chaîne du pad sélectionné (Shift + pad pour le choisir sans jouer)
 *  Layer / Selector -> couche courante ; autre conteneur -> 1re chaîne (FX, Note FX…). */
function enterDevice() {
   if (AUTO_FOLD) cursorDevice.isExpanded().set(true);   // conteneur déplié
   if (cursorDevice.hasDrumPads().get()) {
      var idx = S.selectedPitch - S.drumBase;
      if (idx < 0 || idx > 31 || !drumPadFirstDevice[idx].exists().get()) { popup("Ce pad ne contient aucun device"); return; }
      goToDevice(drumPadFirstDevice[idx], showDeviceLocation);
      return;
   } else if (cursorDevice.hasLayers().get()) {
      if (!layerFirstDevice.exists().get()) { popup("Couche vide : Shift + molette pour en choisir une autre"); return; }
      inLayerDepth = 1; inLayerName = cursorLayer.name().get(); inLayerIdx = curLayerIndex();   // on est DANS une couche de ce conteneur
      goToDevice(layerFirstDevice, showDeviceLocation);
      return;
   } else if (cursorDevice.hasSlots().get()) {
      var slots = cursorDevice.slotNames().get();
      if (!slots || !slots.length) { popup("Aucune chaîne dans ce device"); return; }
      cursorDevice.selectFirstInSlot(slots[0]);
   } else if (cursorDevice.isPlugin().get()) {
      cursorDevice.isWindowOpen().toggle();                // plugin : ouvre / ferme sa fenêtre
      popup((cursorDevice.isWindowOpen().get() ? "Fermeture" : "Ouverture") + " de " + cursorDevice.name().get());
      return;
   } else { goToDevice(cursorDevice, function () { popup(cursorDevice.name().get() + " affiché"); }); return; }
   navGen++;
   revealSoon(showDeviceLocation);
}

/** Shift + clic : couche suivante d'un Layer / Selector (revient à la 1re après la dernière). */
function nextLayer() {
   if (!cursorDevice.hasLayers().get()) { popup("Ce device n'a pas de couches"); return; }
   cursorLayer.selectNext();
   host.scheduleTask(function () { popup("Couche : " + cursorLayer.name().get() + " — clic pour entrer"); }, 60);
}

/** Rend le device sélectionné visible : panneau Devices ouvert, device déplié,
 *  section Remote Controls affichée, et défilement jusqu'à lui. */
function revealDevice() {
   if (browsing) return;          // toute sélection pendant la navigation validerait le navigateur
   if (devicePanelShowOnly) devicesShown = false;   // réaffiche même si fermé à la souris
   showDevices();
   if (AUTO_FOLD && !cursorDevice.isExpanded().get()) cursorDevice.isExpanded().set(true);
   cursorDevice.isRemoteControlsSectionVisible().set(true);
   cursorDevice.selectInEditor();
}

/** Va sur un device en le DÉPLIANT D'ABORD : Bitwig recalcule la largeur, puis on le
 *  sélectionne, et le panneau défile alors à la bonne place (sinon il faut la souris). */
function goToDevice(device, then) {
   if (browsing) return;
   var gen = ++navGen;
   if (AUTO_FOLD) {
      device.isExpanded().set(true);
      device.isRemoteControlsSectionVisible().set(true);
   }
   host.scheduleTask(function () {
      if (gen !== navGen) return;
      device.selectInEditor();
      revealSoon(then);
   }, AUTO_FOLD ? 140 : 0);
}

/** Bitwig met un court instant à déplacer sa sélection : on révèle le device
 *  deux fois (rapide puis de sécurité), puis on appelle then(). */
function revealSoon(then) {
   var gen = navGen;   // si on navigue entre-temps (Back…), ces affichages sont annulés
   host.scheduleTask(function () { if (gen === navGen) revealDevice(); }, 80);
   host.scheduleTask(function () { if (gen === navGen) { revealDevice(); if (then) then(); } }, 220);
   host.scheduleTask(function () { if (gen === navGen) revealDevice(); }, 500);
}

/** Notification : device courant, niveau, page de contrôles. */
function showDeviceLocation(noReveal) {
   if (noReveal !== true) revealDevice();
   var lvl = cursorDevice.isNested().get() ? "  [dans un conteneur — Back pour remonter]" : "";
   var inside = cursorDevice.hasDrumPads().get() || cursorDevice.hasLayers().get() || cursorDevice.hasSlots().get()
      ? "  ▸ clic pour entrer" : "";
   popup(cursorDevice.name().get() + " — " + remotes.getName().get() + lvl + inside);
}


// ============================================================================
//  11. NOTE INPUT (son des pads)
// ============================================================================

function updateNoteInput() {
   if (!noteInput) return;
   var keys = [], vel = [];
   for (var n = 0; n < 128; n++) { keys[n] = -1; vel[n] = (S.fullVelocity && n > 0) ? 127 : n; }
   if (S.mode === MODE.NOTE && !S.shift && !padsOff()) {   // FX / Master : pads muets
      for (var i = 0; i < 32; i++) keys[HW.PAD_FIRST_NOTE + i] = ((memLock && (i % 8) >= 4) || (chordLock && (i % 8) >= 4)) ? -1 : padPitch(i);
   }
   noteInput.setKeyTranslationTable(keys);       // -1 = le pad ne joue rien
   noteInput.setVelocityTranslationTable(vel);
}


// ============================================================================
//  12. LEDs (flush est appelé par Bitwig après chaque changement d'état)
// ============================================================================

function flush() {
   flushStepIcons();
   try { flushEncoderLeds(); } catch (eL) {}
   if (S.mode === MODE.NOTE) flushNoteMode();
   else if (S.mode === MODE.SESSION) flushSessionMode();
   else flushStep32Mode();
   if (browsing) flushBrowserSteps();                  // navigateur : pas = colonnes (blanc = active)

   // Boutons de piste
   var soloOn = anyButtonSolo();
   for (var t = 0; t < 4; t++) {
      var c;
      var t4 = channelForButton(t);
      if (!buttonExists(t)) c = BTN.OFF;
      else if (fxBtn() && t === 3) c = soloOn ? BTN.OFF : (fxCtl && buttonIsSelected(t) && !blinkOn) ? BTN.OFF
                                     : buttonIsSelected(t) ? COLOR.WHITE : COLOR.DIM;           // Master
      else if (t4.solo().get()) c = blinkOn ? moveColor(t4.color(), false) : BTN.OFF;   // solo : clignote
      else if (soloOn) c = BTN.OFF;                                   // un solo : les autres éteints
      else if (t4.mute().get()) c = BTN.OFF;                          // muette : éteinte
      else if (fxCtl && fxBtn() && buttonIsSelected(t) && !blinkOn) c = BTN.OFF;        // mode Send : sélection clignote
      else if (sendFlashWanted() && sendFlashOn()) c = COLOR.WHITE;                     // mode Send (Shift) : flash blanc
      else c = moveColor(t4.color(), !buttonIsSelected(t));           // couleur de piste, vive si sélectionnée
      sendCC(HW.CC_TRACKS[t], c);
   }

   // Boutons
   sendCC(HW.CC_PLAY,   S.isPlaying ? COLOR.GREEN : BTN.DIM);              // vert en lecture
   sendCC(HW.CC_RECORD, (S.isRecording || S.isOverdub) ? COLOR.RED : BTN.DIM); // rouge en enregistrement
   sendCC(HW.CC_LOOP,   S.loopMode ? (blinkOn ? COLOR.WHITE : BTN.OFF) : COLOR.WHITE);   // allumé ; clignote en vue Loop
   sendCC(HW.CC_SAMPLE, cursorTrack.arm().get() ? COLOR.RED : BTN.DIM);   // rouge = piste armée
   sendCC(HW.CC_MUTE, cursorTrack.mute().get() ? BTN.ON : BTN.DIM);
   sendCC(HW.CC_COPY, (S.clipboard || S.slotClipboard || memClipboard || S.barClip) ? BTN.ON : BTN.DIM);
   var canU = false; try { canU = application.canUndo().get(); } catch (eU) {}
   sendCC(HW.CC_UNDO, (canU || lastCapture) ? BTN.ON : BTN.OFF);            // allumé = quelque chose à annuler
   sendCC(HW.CC_DELETE, somethingToDelete() ? BTN.ON : BTN.OFF);            // allumé = quelque chose à effacer
   sendCC(HW.CC_SHIFT, (memLock || chordLock) ? (blinkOn ? COLOR.WHITE : BTN.OFF) : COLOR.WHITE);   // allumé ; clignote en mode Preset
   sendCC(HW.CC_CAPTURE, presetAutoRec ? (blinkOn ? COLOR.WHITE : BTN.OFF) : (captureNotes.length ? BTN.ON : BTN.OFF));   // clignote = automation des presets
   sendCC(HW.CC_NOTE_SESSION, S.mode === MODE.NOTE ? BTN.DIM : (blinkOn ? COLOR.WHITE : BTN.OFF));   // Session : clignote (blanc = max)
}


function flushNoteMode() {
   // Notes en train de sonner sur la piste (lecture du clip ou jeu aux pads)
   var sounding = {};
   var playing = cursorTrack.playingNotes().get();
   for (var n = 0; n < playing.length; n++) sounding[playing[n].pitch()] = true;

   // Pads — couleurs reprises de Bitwig (pads du Drum Machine / couleur de piste)
   var chordPads = scaleMode && (S.shift || chordLock);   // moitié droite = presets d'accords (dessinés plus bas, une seule fois)
   for (var i = 0; i < 32; i++) {
      if (chordPads && (i % 8) >= 4) continue;
      if (padsOff() && !((S.shift || memLock) && (i % 8) >= 4)) { sendNote(HW.PAD_FIRST_NOTE + i, COLOR.OFF); continue; }   // FX / Master : éteints (presets gardés)
      var p = padPitch(i), c = COLOR.OFF;
      if ((S.shift || memLock) && (i % 8) >= 4) {     // mémoires de macros
         var ms = memStore[memKey()] || {};      // (une piste renommée est rattachée au 1er appui)
         c = ms[memIndex(i)] ? moveColor(cursorTrack.color(), false) : COLOR.MEM_EMPTY;   // vide : très atténué
         if (ms[memIndex(i)] && activePreset.m === memIndex(i) && activePreset.key === memKey()) c = COLOR.WHITE; // preset en cours
         if (memClipboard) c = ms[memIndex(i)] ? c : COLOR.LIGHT;
         sendNote(HW.PAD_FIRST_NOTE + i, c);
         continue;
      }
      if (p < 0) c = COLOR.OFF;
      else if (sounding[p] || S.heldPads[i] !== undefined) c = COLOR.PLAYING_PAD;
      else if (S.isDrum && browsing) {
         // Aperçu d'un kit dans le navigateur : Bitwig ne donne pas les pads du kit essayé.
         // On allume simplement les 16 pads de gauche à la couleur de la piste.
         c = (i % 8) < 4 ? moveColor(cursorTrack.color(), p !== S.selectedPitch) : COLOR.OFF;
      }
      else if (S.isDrum) {
         var pad = drumPads.getItemAt(drumIndex(i));
         if (!pad.exists().get()) {
            // Aperçu d'un kit dans le navigateur : Bitwig ne donne pas encore les pads du kit
            // essayé → on les affiche à la couleur de la piste (vif = son sélectionné)
            if (browsing) c = moveColor(cursorTrack.color(), p !== S.selectedPitch);
            else c = (p === S.selectedPitch) ? COLOR.LIGHT : COLOR.DIM;                 // pad vide : visible quand même
         }
         else if (pad.mute().get()) c = COLOR.DRUM_MUTED;
         else c = moveColor(pad.color(), p !== S.selectedPitch); // sélectionné = vif, autres = atténués
      } else {
         var pc = ((p - S.root) % 12 + 12) % 12;
         if (pc === 0) c = moveColor(playColor(), false);   // tonique = couleur de piste (mode Send : piste jouée)
         else if (S.inKey || SCALES[S.scaleIndex].iv.indexOf(pc) >= 0) c = COLOR.IN_SCALE;
      }
      sendNote(HW.PAD_FIRST_NOTE + i, c);
   }
   if (chordPads) flushChordPresetPads();                                     // presets d'accords (moitié droite)
   // Pas
   if (browsing) return;                               // navigateur : les pas = colonnes (flushBrowserSteps)
   if (S.loopMode || S.loop) { flushLoopSteps(); return; }
   if (S.shift) { flushShiftSteps(); return; }
   if (scaleMode && !chordLock) { flushScaleSteps(); return; }
   if (isEmptySlotMode()) { flushEmptyClock(); return; }
   for (var x = 0; x < 16; x++) {
      var col;
      if (S.clipboard && x >= S.clipboard.a && x <= S.clipboard.b) col = COLOR.WHITE; // plage copiée
      else {
         var has = stepHasNote(x), sp = memLock ? stepPresetAt(x) : -1;
         if (x === S.playing16 && S.isPlaying) col = has ? COLOR.PLAYHEAD_ON_NOTE : COLOR.PLAYHEAD;
         else if (sp >= 0) col = COLOR.STEP_PRESET;                           // mode Preset : pas avec preset
         else if (has) col = moveColor(cursorTrack.color(), false);
         else col = (x % 4 === 0) ? COLOR.BEAT : COLOR.OFF;
      }
      sendNote(HW.STEP_FIRST_NOTE + x, col);
   }
}

/** Vue Loop : chaque pas = une mesure. Vert = dans la boucle, blanc = mesure affichée. */
function flushLoopSteps() {
   var ls = clip16.getLoopStart().get() / 4, ll = clip16.getLoopLength().get() / 4;
   var psBar = Math.floor(clip16.getPlayStart().get() / 4);
   if (psBar === Math.floor(ls)) psBar = -1;                   // confondu avec le début de boucle : pas de bleu
   var shown = Math.floor(S.page16 * 16 / stepsPerBar());
   var playBar = (S.isPlaying && S.playing16 >= 0)
      ? Math.floor((S.page16 * 16 + S.playing16) / stepsPerBar()) : -1;
   for (var x = 0; x < 16; x++) {
      var c;
      if (x === playBar) c = COLOR.PLAYHEAD_ON_NOTE;
      else if (S.barClip && x >= S.barClip.a && x <= S.barClip.b) c = COLOR.LIGHT;   // mesures copiées
      else if (x === shown) c = COLOR.WHITE;
      else if (x === psBar) c = COLOR.BLUE;                       // point de lecture (play start)
      else if (x >= Math.floor(ls) && x < Math.ceil(ls + ll)) c = COLOR.LOOP;
      else c = COLOR.OFF;
      sendNote(HW.STEP_FIRST_NOTE + x, c);
   }
}

function stepHasNote(x) {
   if (S.isDrum) return data16[S.selectedPitch][x] > 0;
   for (var y = 0; y < 128; y++) if (data16[y][x] > 0) return true;
   return false;
}

/** Petites icônes imprimées sous les boutons de pas (LEDs pilotées en CC 16..31).
 *  Elles s'allument quand Shift est maintenu, pour les fonctions disponibles. */
var SHIFT_FUNCTIONS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15, 16]; // numéros de pas (1..16)
/** Hors Shift : l'icône reste allumée tant que sa fonction est active. */
function stepIconActive(n) {
   switch (n) {
      case 5:  return S.wheelMode === WHEEL.TEMPO;   // molette = tempo
      case 6:  return !!S.isMetronome;               // métronome
      case 9:  return chordsReady() && !!scaleMode;  // mode chords / scale ouvert
      case 10: return !!S.fullVelocity;              // vélocité pleine
   }
   return false;
}
function flushStepIcons() {
   for (var x = 0; x < 16; x++) {
      var lit = S.shift ? SHIFT_FUNCTIONS.indexOf(x + 1) >= 0 : stepIconActive(x + 1);
      sendCC(HW.CC_STEP_ICON_FIRST + x, lit ? BTN.ON : BTN.OFF);
   }
}

function flushShiftSteps() {
   var on = { 1: true, 2: true, 4: true, 8: true, 11: true, 3: true, 5: true, 6: S.isMetronome, 7: true, 9: true, 10: S.fullVelocity, 14: true, 15: true, 16: true };
   var bright = { 6: S.isMetronome, 10: S.fullVelocity };
   for (var x = 0; x < 16; x++) {
      var n = x + 1;
      sendNote(HW.STEP_FIRST_NOTE + x, on[n] === undefined ? COLOR.OFF : (bright[n] ? COLOR.SETTING_ON : COLOR.SETTING));
   }
}

function flushSessionMode() {
   for (var i = 0; i < 32; i++) {
      var slot = sessionSlot(i).slot;
      var c = COLOR.OFF;
      if (!slot) { sendNote(HW.PAD_FIRST_NOTE + i, COLOR.OFF); continue; }
      if (slot.isRecording().get()) c = COLOR.CLIP_RECORDING;
      else if (slot.isPlaying().get()) c = pulseColor(PULSE_GREEN);   // clip joué : vert, pulsation douce et lente
      else if (slot.isPlaybackQueued().get() || slot.isRecordingQueued().get()) c = COLOR.CLIP_QUEUED;
      else if (slot.isSelected().get()) c = COLOR.WHITE;                 // clip / slot sélectionné : blanc
      else if (slot.hasContent().get()) {
         var stk = sessionSlot(i).track;               // groupe : Bitwig ne donne pas de couleur au slot
         c = (!fxGrid() && stk.isGroup().get()) ? moveColor(stk.color(), false) : moveColor(slot.color(), false);
      }
      sendNote(HW.PAD_FIRST_NOTE + i, c);
   }
   if (browsing) return;
   if (S.loopMode || S.loop) { flushLoopSteps(); return; }
   if (S.shift) { flushShiftSteps(); return; }
   for (var x = 0; x < 16; x++) {
      var cc = COLOR.OFF;
      if (x < 8) cc = COLOR.TRACK;                                   // lancement de scène
      else if (x === 15) cc = COLOR.RED;                            // stop tout
      sendNote(HW.STEP_FIRST_NOTE + x, cc);
   }
}

function flushStep32Mode() {
   for (var step = 0; step < 32; step++) {
      var d = data32[S.selectedPitch][step], c;
      if (step === S.playing32 && S.isPlaying) c = d > 0 ? COLOR.PLAYHEAD_ON_NOTE : COLOR.PLAYHEAD;
      else if (d === 2) c = moveColor(cursorTrack.color(), false);
      else if (d === 1) c = COLOR.DIM;
      else c = (step % 4 === 0) ? COLOR.BEAT : COLOR.OFF;
      var rowFromTop = Math.floor(step / 8), col = step % 8;
      sendNote(HW.PAD_FIRST_NOTE + (3 - rowFromTop) * 8 + col, c);
   }
   if (browsing) return;
   if (S.shift) { flushShiftSteps(); return; }
   for (var x = 0; x < 16; x++) sendNote(HW.STEP_FIRST_NOTE + x, COLOR.OFF);
}

function sendNote(note, color) {
   var k = "n" + note;
   if (ledCache[k] === color) return;
   ledCache[k] = color;
   host.getMidiOutPort(0).sendMidi(0x90 | HW.CHANNEL, note, color);
}

function sendCC(cc, value) {
   if (cc === null || cc === undefined) return;
   var k = "c" + cc;
   if (ledCache[k] === value) return;
   ledCache[k] = value;
   host.getMidiOutPort(0).sendMidi(0xB0 | HW.CHANNEL, cc, value);
}

function clearAllLeds() {
   ledCache = {};
   var i;
   for (i = 0; i < 32; i++) sendNote(HW.PAD_FIRST_NOTE + i, COLOR.OFF);
   for (i = 0; i < 16; i++) {
      sendNote(HW.STEP_FIRST_NOTE + i, COLOR.OFF);
      sendCC(HW.CC_STEP_ICON_FIRST + i, BTN.OFF);
   }
   var ccs = [HW.CC_PLAY, HW.CC_RECORD, HW.CC_LOOP, HW.CC_SAMPLE, HW.CC_MUTE, HW.CC_COPY, HW.CC_CAPTURE, HW.CC_NOTE_SESSION]
      .concat(HW.CC_TRACKS);
   for (i = 0; i < ccs.length; i++) sendCC(ccs[i], BTN.OFF);
}


// ============================================================================
//  13. UTILITAIRES
// ============================================================================

function heldStepList() {
   var out = [];
   for (var k in S.heldSteps) out.push(parseInt(k, 10));
   return out;
}
function heldPadPitches() {
   var out = [];
   for (var k in S.heldPads) out.push(S.heldPads[k]);
   return out;
}
function velocity() { return S.fullVelocity ? 127 : DEFAULT_VELOCITY; }
function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
function noteName(n) { return NOTE_NAMES[n % 12] + (Math.floor(n / 12) - 2); }
function scaleLabel() {
   return NOTE_NAMES[S.root] + " " + SCALES[S.scaleIndex].name + (S.inKey ? " (In-Key)" : " (Chromatique)");
}
function popup(msg) { host.showPopupNotification(msg); }

function exit() {
   clearAllLeds();
   if (HANDSHAKE.ENABLED) sendSysex(HANDSHAKE.STANDALONE_MODE); // rend la Move à son mode autonome
   println("Ableton Move — script arrêté.");
}

// ============================================================================
//  14. MODE CHORDS / SCALE (Shift + Pas 9) — EXPÉRIMENTAL
//  Gestes : en-tête du script. État et idées : NEXT_SESSION.md.
// ============================================================================
/*
 *  Points d'entrée appelés par le reste du script : chordsInit(), chordsInitStore(),
 *  toggleScaleMode, onScaleStep, flushScaleSteps, captureChordMemo, noteChordCandidate,
 *  onChordPresetPad, flushChordPresetPads, releaseChordPresets, cycleCustomScale,
 *  pushBitwigKey, pullBitwigKey.
 */

// ---------- Tables gamme Bitwig / luminosité ----------
// Noms Bitwig (gamme globale) correspondant à SCALES, normalisés (minuscules, sans espaces)
var BW_SCALE_ALIASES = [["major", "ionian"], ["minor", "aeolian", "naturalminor"], ["dorian"], ["mixolydian"],
   ["phrygian"], ["lydian"], ["harmonicminor"], ["minorpentatonic", "pentatonicminor"],
   ["majorpentatonic", "pentatonicmajor"], ["locrian"]];
// Échelle de luminosité : du plus clair au plus sombre (index dans SCALES)
var BRIGHT_LADDER = [5, 0, 3, 2, 1, 4, 9];

var projRemotes;                // contrôles du projet (n°2 tonique, n°3 gamme globale)

/** À appeler dans init(), à la place du bloc d'origine (même ordre de création). */
function chordsInit() {
   projRemotes = project.getRootTrackGroup().createCursorRemoteControlsPage(8);
   for (var pr = 0; pr < 8; pr++) {
      var prm = projRemotes.getParameter(pr);
      prm.exists().markInterested(); prm.name().markInterested();
      prm.value().markInterested(); prm.displayedValue().markInterested();
   }
   for (var po = 0; po < 8; po++)                     // n'importe quel contrôle peut être la tonique ou la gamme
      projRemotes.getParameter(po).displayedValue().addValueObserver(function () { host.scheduleTask(pullBitwigKey, 50); });
}
function chordsInitStore() {
   chordSetting = host.getDocumentState().getStringSetting("Presets d'accords", "Move", 200000, "{}");
   chordSetting.addValueObserver(function (v) { try { chordStore = JSON.parse(v) || {}; } catch (e) { chordStore = {}; } });
}

// ---------- Couleurs partagées (presets d'accords, modes) ----------
function rgbObj(r, g, b) { return { red: function () { return r; }, green: function () { return g; }, blue: function () { return b; } }; }
var CH_COL = { maj: rgbObj(1, 0.62, 0.1) };
var BRIGHT_COL = [rgbObj(1, 1, 0.85), rgbObj(1, 0.85, 0.2), rgbObj(1, 0.55, 0.1), rgbObj(0.2, 0.8, 0.6),
                  rgbObj(0.2, 0.45, 1), rgbObj(0.45, 0.2, 0.9), rgbObj(0.35, 0.05, 0.45)];

// ---------- Mode chords / scale (Shift + Pas 9) ----------
//  Pas 1-7 = fondamentale (C D E F G A B), pas 8 tenu + note = dièse, pas 9-15 = modes I à VII
//  (Ionien … Locrien), pas 16 = mode perso (pas 16 tenu + molette pour le choisir).
//  Shift (même après avoir lâché les pads) mémorise le dernier accord joué ; Shift + pad droit vide
//  l'enregistre, Shift + pad plein le rejoue (vélocité + aftertouch). Double Shift = presets
//  verrouillés : pads de droite = accords, pas = séquenceur (pas tenu + preset = écrit l'accord).
var scaleMode = false, chordLock = false, scaleSharpHeld = false, scale16Held = false, customScale = 6;
var chordSetting, chordStore = {}, chordCandidate = null, chordMemo = null;
var chordPresetHeld = {}, chordPresetIgnore = {};
var NAT_PC = [0, 2, 4, 5, 7, 9, 11];
var THEORY_MODES = [0, 2, 4, 5, 3, 1, 9];           // I Ionien, II Dorien, III Phrygien, IV Lydien, V Mixolydien, VI Éolien, VII Locrien
var THEORY_NAMES = ["I Ionien", "II Dorien", "III Phrygien", "IV Lydien", "V Mixolydien", "VI Éolien", "VII Locrien"];
function toggleScaleMode() {
   scaleMode = !scaleMode;
   if (!scaleMode) { chordLock = false; releaseChordPresets(); if (S.wheelMode === WHEEL.SCALE) setDeviceWheel(); }
   else S.wheelMode = WHEEL.SCALE;
   updateNoteInput(); host.requestFlush();
   popup(scaleMode ? "Mode chords / scale — " + scaleLabel() + " (pas 1-7 note, 8 + note = dièse, 9-15 modes, 16 perso)"
                   : "Mode chords / scale fermé");
}
function applyKey(msg) { updateNoteInput(); pushBitwigKey(); host.requestFlush(); popup(msg || scaleLabel()); }
function onScaleStep(x, on) {
   if (x === 7) { scaleSharpHeld = on; return; }
   if (x === 15) {
      scale16Held = on;
      if (on) { S.scaleIndex = customScale; applyKey("Mode perso : " + SCALES[customScale].name + " (pas 16 tenu + molette pour changer)"); }
      return;
   }
   if (!on) return;
   if (x < 7) { S.root = (NAT_PC[x] + (scaleSharpHeld ? 1 : 0)) % 12; applyKey(); return; }
   var k = x - 8; S.scaleIndex = THEORY_MODES[k]; applyKey("Mode " + THEORY_NAMES[k] + " — " + scaleLabel());
}
function cycleCustomScale(dir) {
   customScale = ((customScale + dir) % SCALES.length + SCALES.length) % SCALES.length;
   S.scaleIndex = customScale; applyKey("Mode perso : " + SCALES[customScale].name);
}
function flushScaleSteps() {
   var rootNat = NAT_PC.indexOf(S.root), sharp = rootNat < 0;
   if (sharp) rootNat = NAT_PC.indexOf((S.root + 11) % 12);
   var modeK = THEORY_MODES.indexOf(S.scaleIndex), custom = (modeK < 0);
   for (var x = 0; x < 16; x++) {
      var c = COLOR.DIM;
      if (x < 7) c = (x === rootNat) ? COLOR.WHITE : COLOR.DIM;
      else if (x === 7) c = (sharp || scaleSharpHeld) ? COLOR.WHITE : BTN.OFF;
      else if (x < 15) c = (x - 8 === modeK) ? moveColor(BRIGHT_COL[BRIGHT_LADDER.indexOf(S.scaleIndex)] || CH_COL.maj, false) : COLOR.DIM;
      else c = custom ? COLOR.WHITE : BTN.OFF;
      sendNote(HW.STEP_FIRST_NOTE + x, c);
   }
}
/** Notes tenues en ce moment aux pads (clavier ou accords) : devient le « dernier accord ». */
function noteChordCandidate() {
   var set = {}, k;
   for (k in S.heldPads) set[S.heldPads[k]] = true;
   var arr = Object.keys(set).map(Number).sort(function (a, b) { return a - b; });
   if (arr.length) chordCandidate = { notes: arr, vel: lastVelocity || 100, scale: S.scaleIndex, root: S.root };
}
function captureChordMemo(silent) {
   if (!chordCandidate) return;
   chordMemo = { notes: chordCandidate.notes.slice(), vel: chordCandidate.vel, scale: S.scaleIndex, root: S.root };
   if (!silent) popup("Accord mémorisé : " + chordMemo.notes.map(noteName).join(" ") + " — Shift + pad vide (droite) pour l'enregistrer");
}
function chordSave() { chordSetting.set(JSON.stringify(chordStore)); }
function anyPlayPadHeld() {
   if (heldPadPitches().length) return true;
   return false;
}
function releaseChordPresets() {
   for (var k in chordPresetHeld) { var ns = chordPresetHeld[k]; for (var n = 0; n < ns.length; n++) noteInput.sendRawMidiEvent(0x80, ns[n], 0); }
   chordPresetHeld = {};
}
function onChordPresetPad(i, on) {
   if (!on) {
      if (chordPresetIgnore[i]) { delete chordPresetIgnore[i]; return; }
      var ns = chordPresetHeld[i]; delete chordPresetHeld[i];
      if (ns) for (var n = 0; n < ns.length; n++) noteInput.sendRawMidiEvent(0x80, ns[n], 0);
      host.requestFlush();
      return;
   }
   if (anyPlayPadHeld()) { chordPresetIgnore[i] = true; return; }   // accord encore tenu : aucune action sur les presets
   if (S.shift) S.shiftUsed = true;
   var slot = String(memIndex(i)), st = chordStore[slot];
   if (S.del) { if (st) { delete chordStore[slot]; chordSave(); popup("Preset d'accord " + (memIndex(i) + 1) + " effacé"); } return; }
   if (!st) {
      var memo = chordMemo || chordCandidate;                       // dernier accord joué, quel que soit l'état du mode
      if (S.shift && memo) { chordStore[slot] = { notes: memo.notes.slice(), vel: memo.vel, scale: memo.scale, root: memo.root }; chordSave(); popup("Preset d'accord " + (memIndex(i) + 1) + " enregistré : " + memo.notes.map(noteName).join(" ")); }
      else popup("Preset vide — joue un accord, puis Shift + ce pad pour l'enregistrer");
      host.requestFlush();
      return;
   }
   var held = heldStepList();
   if (chordLock && held.length) {                                  // pas tenu + preset : écrit l'accord sur le pas
      for (var h = 0; h < held.length; h++) {
         for (var q = 0; q < st.notes.length; q++) clip16.setStep(HW.CHANNEL, held[h], st.notes[q], velocity(), GRID_SIZES[S.gridIndex]);
         S.heldSteps[held[h]].edited = true;
      }
      popup("Accord écrit sur " + held.length + " pas");
   }
   if (st.scale !== undefined && st.scale !== S.scaleIndex) {     // le preset remet son mode (gamme de Bitwig comprise)
      S.scaleIndex = st.scale; updateNoteInput(); pushBitwigKey();
      popup("Preset " + (memIndex(i) + 1) + " — mode " + SCALES[st.scale].name);
   }
   var vel = Math.max(1, lastVelocity || st.vel || 100);           // rejoue avec la vélocité du pad
   for (var m = 0; m < st.notes.length; m++) noteInput.sendRawMidiEvent(0x90, st.notes[m], vel);
   chordPresetHeld[i] = st.notes.slice();
   host.requestFlush();
}
/** Couleur d'un mode (comme les pas 9-15) ; mode perso / inconnu : orange. */
function modeColor(scaleIdx) { return (scaleIdx !== undefined && BRIGHT_COL[BRIGHT_LADDER.indexOf(scaleIdx)]) || CH_COL.maj; }
function flushChordPresetPads() {
   for (var i = 0; i < 32; i++) {
      if ((i % 8) < 4) continue;
      var st = chordStore[String(memIndex(i))];
      var c = chordPresetHeld[i] ? COLOR.WHITE : st ? moveColor(modeColor(st.scale), false) : COLOR.MEM_EMPTY;
      sendNote(HW.PAD_FIRST_NOTE + i, c);
   }
}

// ---------- Synchronisation avec la gamme globale de Bitwig (contrôles du projet 2 et 3) ----------
var bwScale = { map: null, scanning: false, pushT: 0 };
/** Contrôles du projet : on garde la voie qui marchait (n°2 = tonique, n°3 = gamme).
 *  Repli seulement si ce contrôle n'existe pas ou porte visiblement le nom de l'autre :
 *  on cherche alors par le nom. */
function bwNameOf(prm) { return prm.exists().get() ? normName(prm.name().get()) : ""; }
function isScaleName(nm) { return nm.indexOf("scale") >= 0 || nm.indexOf("gamme") >= 0; }
function isRootName(nm) { return !isScaleName(nm) && (nm.indexOf("root") >= 0 || nm.indexOf("tonique") >= 0 || nm.indexOf("tonic") >= 0); }
function bwSearch(test) {
   for (var i = 0; i < 8; i++) { var prm = projRemotes.getParameter(i); if (test(bwNameOf(prm))) return prm; }
   return null;
}
function bwRoot() {
   var p = projRemotes.getParameter(1), nm = bwNameOf(p);
   if (p.exists().get() && !isScaleName(nm)) return p;            // voie d'origine
   return bwSearch(isRootName) || p;
}
function bwScaleP() {
   var p = projRemotes.getParameter(2), nm = bwNameOf(p);
   if (p.exists().get() && !isRootName(nm)) return p;             // voie d'origine
   return bwSearch(isScaleName) || p;
}
function normName(x) { return String(x).toLowerCase().replace(/[^a-z]/g, ""); }
function bwScanScales(done) {
   var r = bwScaleP();
   if (!r.exists().get()) { bwPopup("Gamme Bitwig : pas de contrôle « Scale » — " + bwControlsList()); return; }
   if (bwScale.scanning) return;
   bwScale.scanning = true; bwScale.scanT = new Date().getTime();
   var orig = r.value().get(), list = [], N = 200, k = 0;
   popup("Gamme Bitwig : lecture de la liste des gammes…");
   function step() {
      if (k > N) {
         bwScale.map = {}; bwScale.names = [];
         for (var e = 0; e < list.length; e++) { bwScale.map[normName(list[e].name)] = (list[e].lo + list[e].hi) / 2; bwScale.names.push(normName(list[e].name)); }
         println("Gammes Bitwig (" + list.length + ") : " + list.map(function (x) { return x.name; }).join(", "));
         r.value().set(orig);
         host.scheduleTask(function () { bwScale.scanning = false; if (done) done(); }, 80);
         return;
      }
      r.value().set(k / N);
      host.scheduleTask(function () {
         var nm = String(r.displayedValue().get()), last = list[list.length - 1];
         if (!last || last.name !== nm) list.push({ name: nm, lo: k / N, hi: k / N }); else last.hi = k / N;
         k++; step();
      }, 20);
   }
   step();
}
/** Liste lisible des contrôles du projet présents (pour les messages d'erreur). */
function bwControlsList() {
   var out = [];
   for (var i = 0; i < 8; i++) { var prm = projRemotes.getParameter(i); if (prm.exists().get()) out.push((i + 1) + " « " + prm.name().get() + " »"); }
   return out.length ? "contrôles du projet de ce set : " + out.join(", ") : "ce set n'a aucun contrôle du projet (à créer : Root Key et Scale)";
}
/** Après l'envoi de la gamme : on relit ce que Bitwig affiche. Si ce n'est pas la gamme voulue,
 *  on corrige d'après l'ordre de la liste (quelques essais), sinon on dit ce qui se passe. */
function bwVerifyScale(want, tries) {
   host.scheduleTask(function () {
      if (bwScale.scanning || want !== S.scaleIndex) return;
      var r = bwScaleP(), al = BW_SCALE_ALIASES[want] || [];
      var shown = String(r.displayedValue().get()), nn = normName(shown);
      if (al.indexOf(nn) >= 0) {                                     // c'est bon
         if (!bwScale.okShown) { bwScale.okShown = true; bwPopup("Gamme Bitwig synchronisée : " + bwRoot().displayedValue().get() + " " + shown); }
         return;
      }
      var names = bwScale.names || [], iNow = names.indexOf(nn), iWant = -1;
      for (var a = 0; a < al.length && iWant < 0; a++) iWant = names.indexOf(al[a]);
      if (tries > 0 && iNow >= 0 && iWant >= 0 && names.length > 1) {
         bwScale.pushT = new Date().getTime();
         r.value().set(Math.max(0, Math.min(1, (iWant + 0.5) / names.length)));
         bwVerifyScale(want, tries - 1);
         return;
      }
      bwPopup("Gamme Bitwig : demandé « " + SCALES[want].name + " », Bitwig affiche « " + shown + " » (" + names.length + " gammes lues) — " + bwControlsList());
   }, 150);
}
function bwScaleValue(idx) {
   var al = BW_SCALE_ALIASES[idx] || [];
   for (var a = 0; a < al.length; a++) if (bwScale.map[al[a]] !== undefined) return bwScale.map[al[a]];
   return null;
}
/** Messages de la synchro de gamme : affichés APRÈS le nom de la gamme (sinon il les recouvre). */
function bwPopup(msg) { host.scheduleTask(function () { popup(msg); }, 350); }
function pushBitwigKey() {
   if (!projRemotes) { bwPopup("Gamme Bitwig : contrôles du projet non créés (script)"); return; }
   if (bwScale.scanning) {
      if (new Date().getTime() - (bwScale.scanT || 0) < 15000) return;   // lecture en cours
      bwScale.scanning = false;                                          // lecture bloquée : on repart
      bwPopup("Gamme Bitwig : la lecture des gammes était bloquée, on recommence");
   }
   var rr = bwRoot();
   if (rr.exists().get()) { bwScale.pushT = new Date().getTime(); rr.value().set(S.root / 11); }
   else bwPopup("Tonique Bitwig : pas de contrôle « Root Key » — " + bwControlsList());
   if (!bwScaleP().exists().get()) { bwPopup("Gamme Bitwig : pas de contrôle « Scale » — " + bwControlsList()); return; }
   if (!bwScale.map) { bwScanScales(pushBitwigKey); return; }
   var v = bwScaleValue(S.scaleIndex);
   if (v === null) { bwPopup("Gamme Bitwig : « " + SCALES[S.scaleIndex].name + " » introuvable dans la liste de Bitwig (" + (bwScale.names || []).length + " gammes lues) — " + bwControlsList()); return; }
   bwScale.pushT = new Date().getTime();
   bwScaleP().value().set(v);
   bwVerifyScale(S.scaleIndex, 4);
}
/** Bitwig -> Move : la tonalité changée à la souris est reprise par le script. */
function pullBitwigKey() {
   if (bwScale.scanning || new Date().getTime() - bwScale.pushT < 400) return;
   var changed = false;
   if (bwRoot().exists().get()) {
      var tok = String(bwRoot().displayedValue().get()).split(/[\s\/]/)[0];
      var ri = NOTE_NAMES.indexOf(tok);
      if (ri >= 0 && ri !== S.root) { S.root = ri; changed = true; }
   }
   if (bwScaleP().exists().get()) {
      var nn = normName(bwScaleP().displayedValue().get());
      for (var si = 0; si < BW_SCALE_ALIASES.length; si++)
         if (BW_SCALE_ALIASES[si].indexOf(nn) >= 0) { if (si !== S.scaleIndex) { S.scaleIndex = si; changed = true; } break; }
   }
   if (changed) { updateNoteInput(); host.requestFlush(); }
}
