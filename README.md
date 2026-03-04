# SR-SERVER

This repository is intended as an easy way to bootstrap a full Socialroots 
server. It uses Docker and Compose to start all the needed components:

  - NginX as an HTTP proxy
  - Postgres database
  - Redis cache database
  - Minio S3 storage provider
  - SR Orchestrator
  - SR Users microservice
  - SR Groups microservice
  - SR Notifications microservice
  - SR Connections microservice
  - SR Utils (a shared library with commonly used stuff)
  - [ToDo] A mock email server??

(*) Obs: All SR services are added as Git Submodules.

**Note:** Some modules referenced as submodules are not yet publicly available. We are open-sourcing the project incrementally.

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
  2. Then, load all the submodules by executing `git submodule update --init`;
  3. Bootstrap a brand-new database:
     1. start the Postgres server: `docker-compose --env-file .env up postgres -d`
     2. create the Socialroots databases: `./bin/init-db.sh` *(you may need to
        add execution permissions to the bash script first: `chmod +x bin/init-db.sh`)*
  4. Start the services: `docker-compose --env-file .env up NAME_OF_SERVICE 
  [--build] [-d]` 
     1. ... where `--build` is only needed if you want to rebuild the image in case you 
        made changes to the code and `-d` if you want the container to execute in detached mode.*
     2. ... you can add all the services in a single command call
     3. **The services available are:**
        1. redis
        2. minio-init
        2. orchestrator
        2. rs-users
        3. rs-groups
        4. rs-connections
        5. rs-notes
        6. rs-notifications
        7. rs-responses
  5. Configure name resolving of your computer to see the services by name.
     (There are many ways to do that, and this is the easiest one for Linux/MaxOS)

     Edit the `/etc/hosts` file to ADD the lines to point to `127.0.0.1`:
```
     127.0.0.1 sr-postgres
     127.0.0.1 sr-redis
     127.0.0.1 sr-s3-minio
     127.0.0.1 sr-orchestrator
     127.0.0.1 sr-rs-users
     127.0.0.1 sr-rs-groups
     127.0.0.1 sr-rs-connections
     127.0.0.1 sr-rs-notes
     127.0.0.1 sr-rs-notifications
     127.0.0.1 sr-rs-responses
```

### Observations

The configuration of all these services are made through the `.env` file and 
the default configuration is focused on a development environment, so, you
will need to adjust it accordingly.

- **S3-minio:** You want to be thoughtful about the host URL you configure
  as the uploaded files will be saved to the database pointing to that URL.
  The best case scenario here is that you will have a permanent, public 
  facing name (like https://images.socialroots.io).
