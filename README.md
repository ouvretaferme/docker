# docker

Ce repository sert à utiliser l'application ouvretaferme dans un environnement conteneurisé avec Docker.
Vous trouverez les instructions d'installation de ouvretaferme ici : https://github.com/ouvretaferme/ouvretaferme-public/blob/main/INSTALL.md

## Usage

Cette instance est adaptée pour un test en local sur votre propre machine, mais **fortement déconseillée** en production.

1. Installez docker pour votre OS selon https://docs.docker.com/engine/install/
2. Cloner le repo qui permet l'utilisation de [Traefik](https://doc.traefik.io/traefik/) dans un nouveau dossier (n'importe où) : `git clone git@github.com:emilieguth/traefik.git .` et suivre les instructions de ce nouveau repo. Ceci permettra d'avoir plusieurs conteneurs dockers qui écoutent sur le port 80.
2. Récupérez une base de données de démonstration au format SQL à cette adresse : https://media.ouvretaferme.org/demo.sql
3. Puis exécutez les commandes suivantes (ces instructions sont aussi sur le repo [ouvretaferme](https://github.com/ouvretaferme/ouvretaferme-public)):

* `mkdir otf` (`otf` sera votre dossier root)
* `cd otf`
* `git clone git@github.com:ouvretaferme/docker.git .`
* `cp src/main/secret-example.c.php src/main/secret.c.php`
* `docker-compose up --build`
* Pour importer une base de données : copier le fichier SQL dans `otf/docker/mysql/tmp/demo.sql` puis connectez-vous en SSH à votre conteneur MySQL, puis à votre serveur SQL et créez la base de données `dev_ouvretaferme`. Ensuite, injectez en ligne de commande le fichier `demo.sql` dans cette nouvelle base. Exemple de commande : `mysql -u root -p -b dev_ouvretaferme < demo.sql`

4. Modifiez vos `hosts` pour ajouter un lien entre 127.0.0.1 et dev-ouvretaferme.org, www.dev-ouvretaferme.org, doc.dev-ouvretaferme.org (si vous avez récupéré son code source)
5. Ouvrez votre navigateur à l'adresse http://www.dev-ouvretaferme.org pour tester votre app.

À chaque fois que vous ferez une modification dans votre code, ne réécrasez pas votre fichier `secret.c.php`. Il vous suffira juste de lancer la commande `docker-compose up --build` pour rebuilder votre app et la lancer (ou sans `--build` si vous souhaitez juste relancer vos conteneurs).

## Suppression

Depuis le répertoire de votre app (```cd otf```)
 
- Si vous souhaitez garder Docker mais supprimer l'app et ses dépendances: ```docker compose rm```
- Si vous n'utilisez plus Docker pour d'autres usages: supprimer le répertoire de travail ```rm -rf otf```, et désinstallez Docker selon votre OS en inversant les commandes de https://docs.docker.com/engine/install/
