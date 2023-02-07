locals {
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
  datacenters = ["dc1"]
  type        = "service"
  group "postgresdb" {
    service {
      name = "postgresdb"
      port = 5432
      connect {
        sidecar_service {}
      }
    }
    network {
      mode = "bridge"
      port "db" {
        to = 5432
      }
    }
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
  group "cache" {
    service {
      name = "redis"
      port = 6379
      connect {
        sidecar_service {}
      }
    }
    network {
      mode = "bridge"
      port "cache" {
        to = 6379
      }
    }
    task "redis" {
      driver = "docker"
      config {
        image   = "redis"
        ports   = ["cache"]
      }
    }
  }

  group "initservice" {
    network {
      mode = "bridge"
    }
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
    task "initservice" {
      driver = "docker"
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
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
      template {
        data        =  local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
    }
  }


  group "webserver" {
    network {
      mode = "bridge"
      port "supersetport" {
        to     = 8088 # default superset port
        static = 80
      }
    }
    service {
      name = "superset"
      port = "supersetport"
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
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
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
      template {
        data        = local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
    }
  }
  group "celerybeat" {
    network {
      mode = "bridge"
    }
    service {
      name = "celerybeat"

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
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
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
      template {
        data        = local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
    }
  }

  group "celeryworker" {
    network {
      mode = "bridge"
    }
    service {
      name = "celeryworker"

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
      artifact {
        source      = "git::https://github.com/apache/superset.git//docker"
        destination = "local/repo"
      }
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

      template {
        data        = local.env_data
        destination = "secrets/env_data.env"
        env         = true
      }
    }
  }
  }
}
