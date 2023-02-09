locals {
# choose a database user and password, you would want to change the following
# and store it in a secure place like Hashicorp vault
  database_user     = "superset"
  database_password = "superset"

  env_data = <<EOH
DATABASE_DB='superset'
PYTHONPATH='/app/pythonpath:/app/docker/pythonpath_dev'
DATABASE_HOST='127.0.0.1'
DATABASE_PASSWORD='superset'
DATABASE_USER='superset'
DATABASE_PORT=5432
DATABASE_DIALECT='postgresql+psycopg2'
SUPERSET_LOAD_EXAMPLES='yes'
REDIS_HOST='127.0.0.1'
REDIS_PORT=6379
EOH

}
job "superset" {
  reschedule {
      attempts       = 3
      delay       = "30s" 
      interval = "1m30s"
      delay_function = "constant" 
      unlimited      = false
    }
  datacenters = ["dc1"]
  type        = "service"
# Create a database that will be a metastore in this case we use postgressql

  group "metastore" {
# We would like only 1 database running in this setup
    count = 1
    service {
      name = "postgresdb"
      port = 5432
# Create a sidecar service so that other group tasks can reach the database
      connect {
        sidecar_service {}
      }
    }
# We want to be able to forward traffic to 5432 (default postgressql port) 
    network {
      mode = "bridge"
      port "db" {
        to = 5432
      }
    }
# Create postgres task attached to port "db". The docker postgres image 
# requires username & password and it will create a database 'superset' for us
    task "postgresdb" {
      driver = "docker"
      config {
        image = "postgres"
        ports = ["db"]
      }
      env {
        POSTGRES_USER     = local.database_user
        POSTGRES_PASSWORD = local.database_password
        POSTGRES_DB = "superset"
      }

    }
  }

# Create a redis cache that will act as results backend (RESULTS_BACKEND), 
# default cache for superset objects (CACHE_CONFIG), cache for datasource
# metadata & query results (DATA_CACHE_CONFIG), cache for explore form data state 
# (EXPLORE_FORM_DATA_CACHE_CONFIG) and, cache for dashboard filter state 
# (FILTER_STATE_CACHE_CONFIG)
  group "cache" {
# We would like only 1 cache running in this setup
    count = 1
# Create a sidecar service so that other group tasks can reach the cache
    service {
      name = "redis"
      port = 6379
      connect {
        sidecar_service {}
      }
    }
# We want to be able to forward traffic to 6379 (default redis port) 
    network {
      mode = "bridge"
      port "cache" {
        to = 6379
      }
    }
# Create redis task attached to port "cache".
    task "redis" {
      driver = "docker"
      config {
        image   = "redis"
        ports   = ["cache"]
      }
    }
  }
# We need to initialize the database, create default perms and create
# UI admin username and password. We make use of the init sript available 
# at Apache Superset github repository, this script runs the following commands
# superset db upgrade
# superset fab create-admin (username/ password -> admin/ admin)
# superset init
# superset load_examples (if SUPERSET_LOAD_EXAMPLES env var is set to "yes" then )
  group "initservice" {
# We would like only 1 init running in this setup
count = 1
    network {
      mode = "bridge"
    }

    restart {
      attempts = 2
      delay    = "30s"
    }
# Set up upstream sidecars to postgres db and redis cache
    service {
      name = "initservice"

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgresdb"
              local_bind_port  = 5432
            }
            upstreams {
              destination_name = "redis"
              local_bind_port  = 6379
            }
          }
        }
      }
    }
# Create init service task
    task "initservice" {
      driver = "docker"
# Download helper scripts from Apache superset github repo
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
# set environment variables for the task conatiner 
      template {
        data        =  local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
# Use the latest superset image, mount the downloaded script to /app/docker and run init.sh 
      config {
        image   = "apache/superset"
        command = "/app/docker/docker-init.sh"
        mounts = [{
          type     = "bind"
          source   = "local/repo"
          target   = "/app/docker"
          readonly = true
        }]
      }

    }
  }

# This group creates the gunicorn webservers 
  group "webservers" {
# Increase the count to scale up as load increases 
    count = 1
    network {
      mode = "bridge"
      port "supersetport" {
# route traffic to default superset port
        to     = 8088 
# Although it is recommended to use a lb or service like traefik to expose 
# our webserver service, here you can set port 8088 in the container to bind to port 80
# on the host if you'd like to access the webserver directly        
        static = 80
      }
    }
# Set up upstream sidecars to postgres db and redis cache
    service {
      name = "supersetwebserver"
      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "postgresdb"
              local_bind_port  = 5432
            }
            upstreams {
              destination_name = "redis"
              local_bind_port  = 6379
            }
          }
        }
      }
    }
    task "webserver" {
      driver = "docker"
# Download helper scripts from Apache superset github repo
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
# set environment variables for the task conatiner 
      template {
        data        =  local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
# Use the latest superset image, mount the downloaded script to /app/docker and run gunicorn server
      config {
        image   = "apache/superset"
        ports   = ["supersetport"]
        command = "/app/docker/docker-bootstrap.sh"
        args    = ["app-gunicorn"]
        mounts = [{
          type     = "bind"
          source   = "local/repo"
          target   = "/app/docker"
          readonly = true
        }]
      }
      
    }
  }
# This group sets up one celery scheduler that does the scheduling of the tasks for celery workers
  group "scheduler" {
# We want only one scheduler to run in the whole setup
      count = 1
    network {
      mode = "bridge"
    }
    service {
      name = "celerybeat"
# Set up upstream sidecars to postgres db and redis cache
      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "redis"
              local_bind_port  = 6379
            }
            upstreams {
              destination_name = "postgresdb"
              local_bind_port  = 5432
            }
          }
        }
      }
    }
    task "celerybeat" {
      driver = "docker"

# Download helper scripts from Apache superset github repo
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
# set environment variables for the task conatiner 
      template {
        data        =  local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
# Use the latest superset image, mount the downloaded script to /app/docker and run a celery beat
      config {
        image   = "apache/superset"
        command = "/app/docker/docker-bootstrap.sh"
        args    = ["beat"]
        mounts = [{
          type     = "bind"
          source   = "local/repo"
          target   = "/app/docker"
          readonly = true
        }]
      }
    }
  }

# This group creates celery workers that take tasks like report generation, sql lab queries queued in
# redis by celery scheduler 
  group "workers" {
# Increase the count to scale up as load increases 
    count = 1
    network {
      mode = "bridge"
    }
    service {
      name = "celeryworker"
# Set up upstream sidecars to postgres db and redis cache
      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "redis"
              local_bind_port  = 6379
            }
            upstreams {
              destination_name = "postgresdb"
              local_bind_port  = 5432
            }
          }
        }
      }
    }
    task "celeryworker" {
      driver = "docker"
# Download helper scripts from Apache superset github repo
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
# set environment variables for the task conatiner 
      template {
        data        =  local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
# Use the latest superset image, mount the downloaded script to /app/docker and run celery workers
      config {
        image   = "apache/superset"
        command = "/app/docker/docker-bootstrap.sh"
        args    = ["worker"]
        mounts = [{
          type     = "bind"
          source   = "local/repo"
          target   = "/app/docker"
          readonly = true
        }]
    }
    
  }
  }
}
