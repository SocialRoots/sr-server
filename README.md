# SR-SERVER

This repository is intended as an easy way to bootstrap a full Socialroots 
server. It uses Docker and Compose to start all the needed components:

  - NginX as an HTTP proxy
  - Postgres database
  - Redis cache database
  - SR Orchestrator
  - SR Users microservice
  - SR Groups microservice
  - SR Notifications microservice
  - SR Connections microservice
  - [ToDo] A mock email server??

(*) Obs: All SR services are added as Git Submodules.

## Directory structure

  - `.`: The most relevant files in the home directory are the 
    `docker-compose` and the `.env` which are used to configure and start 
    the server.
  - `data`: all the services in the server are configured to store and log 
    relevant information inside the `data` directory
  - `modules`: where all the git submodules are cloned into.

## How to get it running?

### Requirements

  - You need to have **Docker** and **docker-compose** installed and 
    accessible by the user that is running the commands below;
  - You need to have **git** and the Postgresql client **psql** available 
    on your path;

### Steps

  1. Cloning this repository and get inside its directory using a terminal;
  2. Then, load all the submodules by executing `git submodule update`;
  3. Bootstrap a brand-new database:
     1. start the Postgres server: `docker-compose --env-file .env up postgres`
     2. create the Socialroots databases: `./init-db.sh` *(you may need to 
        add execution permissions to the bash script first: `chmod +x 
        init-sb.sh`)*
  4. Start the services: `docker-compose --env-file .env NAME_OF_SERVICE [--build] [-d]` 
     1. ... where `--build` is only needed if you want to rebuild the image in case you 
        made changes to the code and `-d` if you want the container to execute in detached mode.*
     2. **The services available are:**
        1. orchestrator
        2. rs-users
        3. rs-groups
        4. rs-connections
        5. rs-notes
        6. rs-notifications
        7. rs-responses
