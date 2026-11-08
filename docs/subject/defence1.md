Assessment report

Accessibility First Steps
0 / 3

Group comment:

La page dédiée à l'accessibilité n'est pas encore rédigée, mais elle sera inspirée d'une documentation de projet existante.
Aucune fonctionnalité d'accessibilité n'est actuellement présente dans le jeu.
Un plan clair des fonctionnalités à livrer pour la soutenance n'a pas encore été établi.

Networked and Authoritative Server
3 / 4

Group comment:

Le serveur est multithreadé et non bloquant, mais uniquement les joueurs sont réseau ; le client transmet uniquement ses entrées, tandis que le serveur effectue l’intégralité du calcul.

Consistency and Smoothness
2 / 2

Group comment:

Le gameplay présente une cohérence et une fluidité satisfaisantes.

Playable Prototype
2 / 4

Group comment:

Le prototype présente un joueur capable de tirer avec du son, mais il ne comporte pas de mobs, de son, ni de plusieurs niveaux.

Binary Protocol over UDP
4 / 4

Group comment:

Le protocole est binaire, little‑endian, avec un en‑tête de 8 octets et un encodage basé sur les types ; il utilise exclusivement UDP, avec des datagrammes limités à 1 200 octets.

Self-Contained Project
3 / 3

Group comment:

Raylib est intégré via un hash fixe et compilé à partir de ses sources ; seules les bibliothèques X11 et OpenGL sont requises sur Linux, ce qui respecte les critères de tolérance du barème.

Error Handling and Network Decoupling
3 / 4

Group comment:

Le serveur présente une robustesse suffisante pour gérer les départs annoncés, mais il ne traite pas les requêtes illégales et ne dispose pas d’un canal fiable. Les mécanismes de transport, de sérialisation, les messages et les règles sont répartis dans des fichiers distincts.

Build System
2 / 3

Group comment:

`zig build` propre, hors source, sans étape manuelle. Bonus non acquis : un seul fichier de build.

Protocol Documentation
0 / 3

Group comment:

Il n'existe pas encore de documentation décrivant le protocole réseau.

Engine and Architecture
4 / 6

Group comment:

Un debut d'ECS est mis en place mais manque de structure globale

Code Factorization
0 / 4

Group comment:

Une seule entité, le vaisseau, est gérée dans une structure dédiée en dehors du système ECS ; intégrer les vaisseaux, les ennemis et les projectiles dans l’ECS entraînerait rapidement une complexité accrue.

Decoupling and Modularity
3 / 4

Group comment:

raylib est complètement encapsulé, accessible via une couche de mappage des touches vers des actions, et les modules sont invoqués directement par les programmes sans mécanisme de plugin.

README
0 / 3

Group comment:

Le projet ne comporte pas de fichier README.
