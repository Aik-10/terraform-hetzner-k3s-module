provider "hcloud" {
  token = var.hcloud_token
}

terraform {
  required_version = ">= 0.13"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    remote = {
      source  = "tenstad/remote"
      version = ">= 0.1.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.1.0"
    }
  }
}

resource "tls_private_key" "master_key" {
  algorithm = var.ssh_key_algorithm
  rsa_bits  = 4096
}

resource "hcloud_ssh_key" "master_node_key" {
  name       = var.generated_ssh_key_name
  public_key = tls_private_key.master_key.public_key_openssh
  depends_on = [tls_private_key.master_key]
}

resource "hcloud_network" "private_network" {
  name     = var.cluster_private_network_name
  ip_range = var.cluster_private_network_ip_range
}

resource "hcloud_network_subnet" "private_network_subnet" {
  type         = "cloud"
  network_id   = hcloud_network.private_network.id
  network_zone = var.cluster_private_network_subnet_zone
  ip_range     = var.cluster_private_network_subnet_ip_range
}

resource "random_string" "random" {
  count  = var.cluster_worker_node_count
  length  = 8
  special = false
}

data "http" "ip" {
  url = "https://ifconfig.me/ip"
}

data "hcloud_ssh_keys" "all_keys" {}

data "cloudinit_config" "master-config" {
  gzip          = false
  base64_encode = false

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/templates/cloudinit.yaml.tftpl", {
      ssh_authorized_key = tls_private_key.master_key.public_key_openssh
    })
  }
}

data "cloudinit_config" "worker-config" {
  gzip          = false
  base64_encode = false

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/templates/worker-cloudinit.yaml.tftpl", {
      ssh_authorized_key = tls_private_key.master_key.public_key_openssh
      ssh_private_key    = tls_private_key.master_key.private_key_openssh
      master_private_ip  = var.cluster_master_node_private_ip
    })
  }
}

locals {
  cluster_all_node_firewall_rules = [
    {
      description = "Kubelet metrics"
      direction   = "in"
      protocol    = "tcp"
      port        = "10250"
      source_ips  = [var.cluster_private_network_subnet_ip_range]
    },
    {
      description     = "HTTP traffic"
      direction       = "out"
      protocol        = "tcp"
      port            = "80"
      destination_ips = ["0.0.0.0/0"]
    },
    {
      description     = "HTTPs traffic"
      direction       = "out"
      protocol        = "tcp"
      port            = "443"
      destination_ips = ["0.0.0.0/0"]
    },
    {
      description     = "K3s server traffic"
      direction       = "out"
      protocol        = "tcp"
      port            = "6443-6444"
      destination_ips = ["0.0.0.0/0"]
    }
  ]
  cluster_master_node_firewall_rules = [
    {
      description = "Allow SSH access to the master node from the private network"
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = [var.cluster_private_network_subnet_ip_range, data.http.ip.response_body]
    },
    {
      description = "Allow traffic from the private network to the master node"
      direction   = "in"
      protocol    = "tcp"
      port        = "6443-6444"
      source_ips  = ["0.0.0.0/0"]
    }
  ]
  cluster_worker_node_firewall_rules = []
}

resource "hcloud_firewall" "basic_firewall" {
  name   = var.cluster_firewall_name
  labels = var.labels

  dynamic "rule" {
    for_each = concat(local.cluster_all_node_firewall_rules, local.cluster_master_node_firewall_rules, local.cluster_worker_node_firewall_rules)
    content {
      description     = rule.value.description
      direction       = rule.value.direction
      protocol        = rule.value.protocol
      port            = lookup(rule.value, "port", null)
      destination_ips = lookup(rule.value, "destination_ips", [])
      source_ips      = lookup(rule.value, "source_ips", [])
    }
  }
}

resource "hcloud_server" "master-node" {
  name        = "${var.cluster_name}-master"
  image       = var.cluster_server_os
  server_type = var.cluster_master_node_type
  location    = var.cluster_location

  ssh_keys = concat([hcloud_ssh_key.master_node_key.name], data.hcloud_ssh_keys.all_keys.ssh_keys.*.name)

  labels = merge(var.labels, { node = "master", attach-firewall = true })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    ignore_changes = [
      location,
      ssh_keys,
      user_data,
      image,
    ]
  }

  network {
    network_id = hcloud_network.private_network.id
    ip         = var.cluster_master_node_private_ip
  }

  user_data    = data.cloudinit_config.master-config.rendered
  depends_on   = [hcloud_network_subnet.private_network_subnet, hcloud_ssh_key.master_node_key]
  firewall_ids = concat([hcloud_firewall.basic_firewall.id], var.firewall_ids)
}

resource "hcloud_server" "worker-nodes" {
  count = var.cluster_worker_node_count

  name        = "${var.cluster_name}-worker-${random_string.random[count.index].result}-${count.index}"
  image       = var.cluster_server_os
  server_type = var.cluster_worker_node_type
  location    = var.cluster_location

  labels = merge(var.labels, { node = "worker", attach-firewall = true })

  ssh_keys                 = data.hcloud_ssh_keys.all_keys.ssh_keys.*.name

  lifecycle {
    ignore_changes = [
      location,
      ssh_keys,
      user_data,
      image,
    ]
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.private_network.id
  }

  user_data    = data.cloudinit_config.worker-config.rendered
  depends_on   = [hcloud_network_subnet.private_network_subnet, hcloud_server.master-node]
  firewall_ids = concat([hcloud_firewall.basic_firewall.id], var.firewall_ids)
}