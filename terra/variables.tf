variable "workspace" {
  default = "test"
}

variable "vpc_cidr" {
  default = "172.17.0.0/22"
}

variable "public_subnets" {
  default = {
    "us-east-1a": "172.17.0.0/24",
    "us-east-1b": "172.17.1.0/24"
  }
}

variable "private_subnets" {
  default = {
    "us-east-1a": "172.17.2.0/24",
    "us-east-1b": "172.17.3.0/24"
  }
}
