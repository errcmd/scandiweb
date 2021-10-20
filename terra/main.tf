terraform {
    backend "s3" {
      bucket               = "errcmd-tfstate"
      region               = "us-east-1"
      key                  = "terraform.tfstate"
      workspace_key_prefix = "scandiweb"
    }
}

resource "aws_vpc" "main" {
  cidr_block       = var.vpc_cidr
  instance_tenancy = "default"
}

resource "aws_internet_gateway" "main_gateway" {
  vpc_id = "${aws_vpc.main.id}"
}

resource "aws_subnet" "private_subnets" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value
}

resource "aws_subnet" "public_subnets" {
  for_each = var.public_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value
}

resource "aws_s3_bucket" "lb_logs" {
  bucket        = "errcmd-lb-logs-${terraform.workspace}"
  force_destroy = true
  acl           = "private"
}

resource "aws_security_group" "allow_web" {
  name        = "allow_web"
  vpc_id      = aws_vpc.main.id

  ingress = [
    {
      description      = "https"
      from_port        = 443
      to_port          = 443
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    },
    {
      description      = "http"
      from_port        = 80
      to_port          = 80
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    }
  ]

  egress = [
    {
      description      = "all outbound"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    }
  ]
}

resource "aws_lb" "application_balancer" {
  name               = "alb-scandiweb-main"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_web.id]
  subnets            = [for s in aws_subnet.public_subnets:s.id]

  enable_deletion_protection = true

  access_logs {
    bucket  = aws_s3_bucket.lb_logs.bucket
    prefix  = "alb_main"
    enabled = false
  }
}

resource "tls_private_key" "ssl_key" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "self_signed_cert" {
  key_algorithm   = "ECDSA"
  private_key_pem = tls_private_key.ssl_key.private_key_pem

  subject {
    common_name  = "blablabla.net"
    organization = "olaolaola"
  }

  validity_period_hours = 672

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth"
  ]
}

resource "aws_iam_server_certificate" "self_signed_cert" {
  name             = "self_signed_cert"
  certificate_body = tls_self_signed_cert.self_signed_cert.cert_pem
  private_key      = tls_private_key.ssl_key.private_key_pem
}

resource "aws_lb_target_group" "magento" {
  name     = "magento"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    port     = 80
    protocol = "HTTP"
  }
}

resource "aws_lb_target_group" "varnish" {
  name     = "varnish"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    port     = 80
    protocol = "HTTP"
  }
}


resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.application_balancer.arn
  port          = "80"
  protocol      = "HTTP"

  default_action {
    type        = "redirect"

    redirect {
    port        = "443"
    protocol    = "HTTPS"
    status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "varnish" {
  load_balancer_arn = aws_lb.application_balancer.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_iam_server_certificate.self_signed_cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.varnish.arn
  }
}

resource "aws_lb_listener_rule" "magento_static" {
  listener_arn = aws_lb_listener.varnish.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.magento.arn
  }

  condition {
    path_pattern {
      values = ["/static/*"]
    }
  }
}


resource "aws_lb_listener_rule" "magento_media" {
  listener_arn = aws_lb_listener.varnish.arn
  priority     = 110

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.magento.arn
  }

  condition {
    path_pattern {
      values = ["/media/*"]
    }
  }
}

resource "aws_instance" "magento" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  tags = {
    type = "magento"
  }
}

resource "aws_instance" "varnish" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  tags = {
    type = "varnish"
  }
}


resource "aws_instance" "bastion" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  tags = {
    type = "bastion"
  }
}
