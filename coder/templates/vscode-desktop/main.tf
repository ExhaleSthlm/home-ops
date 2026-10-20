terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {}
provider "kubernetes" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "CPU cores available to VS Code Desktop"
  default      = "4"
  mutable      = true

  option {
    name  = "2 cores"
    value = "2"
  }
  option {
    name  = "4 cores"
    value = "4"
  }
  option {
    name  = "8 cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "Memory available to VS Code Desktop"
  default      = "8"
  mutable      = true

  option {
    name  = "4 GiB"
    value = "4"
  }
  option {
    name  = "8 GiB"
    value = "8"
  }
  option {
    name  = "16 GiB"
    value = "16"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Workspace storage"
  description  = "Persistent and replicated workspace storage in GiB"
  type         = "number"
  default      = "20"
  mutable      = false

  validation {
    min = 10
    max = 200
  }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  startup_script = <<-EOT
    set -eu
    mkdir -p /home/coder/workspace
    git config --global init.defaultBranch main
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "memory_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Workspace Disk"
    key          = "workspace_disk"
    script       = "coder stat disk --path /home/coder"
    interval     = 60
    timeout      = 1
  }
}

resource "coder_app" "vscode_desktop" {
  agent_id     = coder_agent.main.id
  slug         = "desktop"
  display_name = "VS Code Desktop"
  icon         = "/icon/code.svg"
  url          = "http://localhost:3000"
  subdomain    = false
  share        = "owner"
  open_in      = "slim-window"

  healthcheck {
    url       = "http://localhost:3000"
    interval  = 5
    threshold = 24
  }
}

resource "kubernetes_persistent_volume_claim_v1" "workspace" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-workspace"
    namespace = "coder-workspaces"
    labels = {
      "app.kubernetes.io/name"    = "coder-workspace"
      "app.kubernetes.io/part-of" = "coder"
      "backup.myk8s.se/volume"    = "true"
      "com.coder.resource"        = "true"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
      "com.coder.user.id"         = data.coder_workspace_owner.me.id
      "com.coder.user.username"   = data.coder_workspace_owner.me.name
    }
  }
  wait_until_bound = false

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "replicated"
    resources {
      requests = {
        storage = "${data.coder_parameter.disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "workspace" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false

  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = "coder-workspaces"
    labels = {
      "app.kubernetes.io/name"    = "coder-workspace"
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.resource"        = "true"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
      "com.coder.user.username"   = data.coder_workspace_owner.me.name
    }
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }

    selector {
      match_labels = {
        "com.coder.workspace.id" = data.coder_workspace.me.id
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "coder-workspace"
          "app.kubernetes.io/part-of" = "coder"
          "com.coder.resource"        = "true"
          "com.coder.workspace.id"    = data.coder_workspace.me.id
          "com.coder.workspace.name"  = data.coder_workspace.me.name
          "com.coder.user.username"   = data.coder_workspace_owner.me.name
        }
      }

      spec {
        automount_service_account_token  = false
        termination_grace_period_seconds = 30

        security_context {
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
        }

        container {
          name              = "desktop"
          image             = "lscr.io/linuxserver/vscode:latest@sha256:010fe3ed9e9a013508971a213b2e57f61ad500548c119224c880234609376193"
          image_pull_policy = "IfNotPresent"

          env {
            name  = "PUID"
            value = "1000"
          }
          env {
            name  = "PGID"
            value = "1000"
          }
          env {
            name  = "TZ"
            value = "Europe/Stockholm"
          }
          env {
            name  = "TITLE"
            value = "VS Code - ${data.coder_workspace.me.name}"
          }
          env {
            name  = "PIXELFLUX_WAYLAND"
            value = "false"
          }
          env {
            name  = "SELKIES_USE_CPU"
            value = "true"
          }
          env {
            name  = "MAX_RES"
            value = "3840x2160"
          }

          port {
            name           = "desktop"
            container_port = 3000
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              cpu    = data.coder_parameter.cpu.value
              memory = "${data.coder_parameter.memory.value}Gi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              add  = ["IPC_LOCK"]
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/home/coder"
          }
          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }
        }

        container {
          name              = "coder-agent"
          image             = "codercom/enterprise-base:ubuntu@sha256:191967da651ec0a567de173ef8a029080da8cd4992de192b65df54ef189be769"
          image_pull_policy = "IfNotPresent"
          command           = ["sh", "-c", coder_agent.main.init_script]

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          security_context {
            run_as_user                = 1000
            run_as_group               = 1000
            run_as_non_root            = true
            allow_privilege_escalation = false
            capabilities { drop = ["ALL"] }
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/config"
          }
        }

        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.workspace.metadata[0].name
          }
        }

        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Gi"
          }
        }
      }
    }
  }
}
