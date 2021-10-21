terraform {
  required_version = "= 1.0.9"
}

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

resource "aws_default_route_table" "main_table" {
  default_route_table_id = aws_vpc.main.default_route_table_id
  route {
    cidr_block           = "0.0.0.0/0"
    gateway_id           = "${aws_internet_gateway.main_gateway.id}"
  }
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

resource "aws_eip" "nat_eip" {
  vpc      = true
}

resource "aws_nat_gateway" "nat_for_private_subnets" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = [for s in aws_subnet.public_subnets:s.id][0]
  depends_on    = [aws_internet_gateway.main_gateway]
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.main.id

  route = [
    {
      carrier_gateway_id          = ""
      destination_prefix_list_id  = ""
      egress_only_gateway_id      = ""
      gateway_id                  = ""
      instance_id                 = ""
      ipv6_cidr_block             = ""
      local_gateway_id            = ""
      network_interface_id        = ""
      transit_gateway_id          = ""
      vpc_endpoint_id             = ""
      vpc_peering_connection_id   = ""
      cidr_block                  = "0.0.0.0/0"
      nat_gateway_id              = aws_nat_gateway.nat_for_private_subnets.id
    }
  ]
}

resource "aws_route_table_association" "change_route_table_private_subnets" {
  for_each = aws_subnet.private_subnets

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_route_table.id
}


resource "aws_s3_bucket" "lb_logs" {
  bucket        = "errcmd-lb-logs-${terraform.workspace}"
  force_destroy = true
  acl           = "private"
}

resource "aws_security_group" "alb_allow_web" {
  name        = "alb_allow_web"
  vpc_id      = aws_vpc.main.id
  ingress     = [
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
}

resource "aws_security_group" "bastion_allow_ssh" {
  name        = "bastion_allow_ssh"
  vpc_id      = aws_vpc.main.id
  ingress     = [
    {
      description      = "ssh"
      from_port        = 22
      to_port          = 22
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    }
  ]
}

resource "aws_security_group" "hardening_ssh" {
  name        = "hardening_ssh"
  vpc_id      = aws_vpc.main.id
  ingress     = [
    {
      description      = "ssh"
      from_port        = 22
      to_port          = 22
      protocol         = "tcp"
      cidr_blocks      = []
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = [aws_security_group.bastion_allow_ssh.id]
      self             = false
    }
  ]
}

resource "aws_security_group" "hardening_web" {
  name        = "hardening_web"
  vpc_id      = aws_vpc.main.id
  ingress     = [
    {
      description      = "http"
      from_port        = 80
      to_port          = 80
      protocol         = "tcp"
      cidr_blocks      = []
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = [aws_security_group.alb_allow_web.id]
      self             = true
    }
  ]
}

resource "aws_security_group" "egress_all" {
  name        = "egress_all"
  vpc_id      = aws_vpc.main.id
  egress      = [
    {
      description      = "world unlimited egress"
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
  name                       = "alb-scandiweb-main"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb_allow_web.id]
  subnets                    = [for s in aws_subnet.public_subnets:s.id]
  enable_deletion_protection = false

  access_logs {
    bucket                   = aws_s3_bucket.lb_logs.bucket
    prefix                   = "alb_main"
    enabled                  = false
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
  name       = "magento"
  port       = 80
  protocol   = "HTTP"
  vpc_id     = aws_vpc.main.id

  health_check {
    port     = 80
    protocol = "HTTP"
  }
}

resource "aws_lb_target_group" "varnish" {
  name       = "varnish"
  port       = 80
  protocol   = "HTTP"
  vpc_id     = aws_vpc.main.id

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
  for_each               = aws_subnet.private_subnets
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.private_subnets[each.key].id
  vpc_security_group_ids = [aws_security_group.hardening_web.id, aws_security_group.egress_all.id, aws_security_group.hardening_ssh.id]

  tags = {
    type = "magento"
  }
  root_block_device {
    volume_size = 20
    tags        = {
                    type = "magento"
                  }
  }

  user_data = <<EOF
#!/bin/bash
echo -e "#Scandiweb\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDXkrXvB6eYbWqwoAWM3YJa5vLhW+83A1c4vinSbVVdxUsLTFgceKY9Ur7q0EIkFYetFkoLz5hnUgaPFOSuYEnVuHL9L7hT7y5RHL+pJBwBLcmkymmGTCI1+2lbBGru09+IvyW7HSNOxkojVTmcsN9v294CSuwHKj7QJ2FRuCo9G6lwfHhCJHLPr2E7X9wJcHCKwlpUoLdIHO6+5OQbEiyPBp4A46NeLWq/1cMJiv9catMb4EBO8LcOhpqGzsqcthEKSZj/R28JrPWHfsBV3dQ2PUgHPts0OP+ilJZSwGWZV8GYl+25TfuveiVI7Zqhj00dUycvLeRGiiYssK4zuVhjv0DALMOjcybp326F8zIvruYU/DPernBWSi10nA+foUFMruAZ5TcCUt1dIVzywbqJKBgHaYOTg87FnCwsY9gLbZB0ZcQzPrsfhaviEfPKF01Gba69t2XD4J+FgmZu0JE1IfPktaCIZtfaU/IipUNvrmS0KpkW93mmQ/r6JCSNKcKEhwbkjJBOXURtfgoKV3PGHCp+B7RHSjysAAOP4vSnnuaGa/pHAeq/fBBzQeD62whgvVwDUGHL/rBXHeQeF49PryZ06nV/LDFFmudac5dzIDK19zZ+o4mwAF7E8wxilb2WenmRwKwD0DqkEEhp6j1+J7rfUsqzo2DS/j/GDDf6aQ== scandi@scandi.web" >> /home/ubuntu/.ssh/authorized_keys
echo -e "#errcmd\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDNlAJ7+OL1BvLWIbuhpJP+WF0h/UTzIbEp8IW9ut9oBIVujMIvbH1SJTojoYO8gubM/ij6dTu2WTJIHQ3JBR3Ls5hrCPg/2uwc2sdJvw4YD3F7qFpFBIds3X9uNJ6EMlBCj8I/zHSD1Y3hM1GMIwVS2rNaYKK06UdlOU4PlhUv93u6BRAtouao0Z3GGLUHmRzVjC06+TBT5n10ewE49WJd3lReMUoIw/O0d41wydKJJPX6Y+f44ogflOTUot9U70d+72WmsR36CZrLI77MpIO0Uane8bBvHHzPsF0ZWC1ABJwIsoTFQjDSBA/rj13I5D+7TeqG6G5sYy35Fv2Mpyt+eEujQ3t9MXWI7zZf+9KH1GgnLOzS4I95Um8INhXimqzcJxj6im66c++D91SCVBTVOwBPt/+g7R5GpXnSAKicG25QboHbrTtA1+RUF4053wxAn4v/sSxkBUMz7b1yERttDxs/mf8bvv5lsUEWjpET3YCtKgir3b9VmFnNS1ugrJkz8A297ZOiZdRIzTULlVeJXXAYV7oZi4keUxyBnns27+kwiU5ktlIBVuobERD0KN38IhrFfYvtmVnhwNfrJyyP2Uq1UtWS1eA/SUfhNMf6EEM7ERQO2U6kaLLUBMoJmvV5egO2YMlYO1co3MgWqJWWUX40ZeTfLkboF1sRNCJ18w== err.cmd@gmail.com" >> /home/ubuntu/.ssh/authorized_keys
EOF

}

resource "aws_instance" "varnish" {
  for_each               = aws_subnet.private_subnets
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.private_subnets[each.key].id
  vpc_security_group_ids = [aws_security_group.hardening_web.id, aws_security_group.egress_all.id, aws_security_group.hardening_ssh.id]

  tags = {
    type = "varnish"
  }
  root_block_device {
    volume_size = 20
    tags        = {
                     type = "varnish"
                  }
   }

  user_data = <<EOF
#!/bin/bash
echo -e "#Scandiweb\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDXkrXvB6eYbWqwoAWM3YJa5vLhW+83A1c4vinSbVVdxUsLTFgceKY9Ur7q0EIkFYetFkoLz5hnUgaPFOSuYEnVuHL9L7hT7y5RHL+pJBwBLcmkymmGTCI1+2lbBGru09+IvyW7HSNOxkojVTmcsN9v294CSuwHKj7QJ2FRuCo9G6lwfHhCJHLPr2E7X9wJcHCKwlpUoLdIHO6+5OQbEiyPBp4A46NeLWq/1cMJiv9catMb4EBO8LcOhpqGzsqcthEKSZj/R28JrPWHfsBV3dQ2PUgHPts0OP+ilJZSwGWZV8GYl+25TfuveiVI7Zqhj00dUycvLeRGiiYssK4zuVhjv0DALMOjcybp326F8zIvruYU/DPernBWSi10nA+foUFMruAZ5TcCUt1dIVzywbqJKBgHaYOTg87FnCwsY9gLbZB0ZcQzPrsfhaviEfPKF01Gba69t2XD4J+FgmZu0JE1IfPktaCIZtfaU/IipUNvrmS0KpkW93mmQ/r6JCSNKcKEhwbkjJBOXURtfgoKV3PGHCp+B7RHSjysAAOP4vSnnuaGa/pHAeq/fBBzQeD62whgvVwDUGHL/rBXHeQeF49PryZ06nV/LDFFmudac5dzIDK19zZ+o4mwAF7E8wxilb2WenmRwKwD0DqkEEhp6j1+J7rfUsqzo2DS/j/GDDf6aQ== scandi@scandi.web" >> /home/ubuntu/.ssh/authorized_keys
echo -e "#errcmd\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDNlAJ7+OL1BvLWIbuhpJP+WF0h/UTzIbEp8IW9ut9oBIVujMIvbH1SJTojoYO8gubM/ij6dTu2WTJIHQ3JBR3Ls5hrCPg/2uwc2sdJvw4YD3F7qFpFBIds3X9uNJ6EMlBCj8I/zHSD1Y3hM1GMIwVS2rNaYKK06UdlOU4PlhUv93u6BRAtouao0Z3GGLUHmRzVjC06+TBT5n10ewE49WJd3lReMUoIw/O0d41wydKJJPX6Y+f44ogflOTUot9U70d+72WmsR36CZrLI77MpIO0Uane8bBvHHzPsF0ZWC1ABJwIsoTFQjDSBA/rj13I5D+7TeqG6G5sYy35Fv2Mpyt+eEujQ3t9MXWI7zZf+9KH1GgnLOzS4I95Um8INhXimqzcJxj6im66c++D91SCVBTVOwBPt/+g7R5GpXnSAKicG25QboHbrTtA1+RUF4053wxAn4v/sSxkBUMz7b1yERttDxs/mf8bvv5lsUEWjpET3YCtKgir3b9VmFnNS1ugrJkz8A297ZOiZdRIzTULlVeJXXAYV7oZi4keUxyBnns27+kwiU5ktlIBVuobERD0KN38IhrFfYvtmVnhwNfrJyyP2Uq1UtWS1eA/SUfhNMf6EEM7ERQO2U6kaLLUBMoJmvV5egO2YMlYO1co3MgWqJWWUX40ZeTfLkboF1sRNCJ18w== err.cmd@gmail.com" >> /home/ubuntu/.ssh/authorized_keys
EOF
  }

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = [for s in aws_subnet.public_subnets:s.id][0]
  vpc_security_group_ids = [aws_security_group.bastion_allow_ssh.id, aws_security_group.egress_all.id]

  tags = {
    type = "bastion"
  }

  user_data = <<EOF
#!/bin/bash
echo -e "#Scandiweb\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDXkrXvB6eYbWqwoAWM3YJa5vLhW+83A1c4vinSbVVdxUsLTFgceKY9Ur7q0EIkFYetFkoLz5hnUgaPFOSuYEnVuHL9L7hT7y5RHL+pJBwBLcmkymmGTCI1+2lbBGru09+IvyW7HSNOxkojVTmcsN9v294CSuwHKj7QJ2FRuCo9G6lwfHhCJHLPr2E7X9wJcHCKwlpUoLdIHO6+5OQbEiyPBp4A46NeLWq/1cMJiv9catMb4EBO8LcOhpqGzsqcthEKSZj/R28JrPWHfsBV3dQ2PUgHPts0OP+ilJZSwGWZV8GYl+25TfuveiVI7Zqhj00dUycvLeRGiiYssK4zuVhjv0DALMOjcybp326F8zIvruYU/DPernBWSi10nA+foUFMruAZ5TcCUt1dIVzywbqJKBgHaYOTg87FnCwsY9gLbZB0ZcQzPrsfhaviEfPKF01Gba69t2XD4J+FgmZu0JE1IfPktaCIZtfaU/IipUNvrmS0KpkW93mmQ/r6JCSNKcKEhwbkjJBOXURtfgoKV3PGHCp+B7RHSjysAAOP4vSnnuaGa/pHAeq/fBBzQeD62whgvVwDUGHL/rBXHeQeF49PryZ06nV/LDFFmudac5dzIDK19zZ+o4mwAF7E8wxilb2WenmRwKwD0DqkEEhp6j1+J7rfUsqzo2DS/j/GDDf6aQ== scandi@scandi.web" >> /home/ubuntu/.ssh/authorized_keys
echo -e "#errcmd\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDNlAJ7+OL1BvLWIbuhpJP+WF0h/UTzIbEp8IW9ut9oBIVujMIvbH1SJTojoYO8gubM/ij6dTu2WTJIHQ3JBR3Ls5hrCPg/2uwc2sdJvw4YD3F7qFpFBIds3X9uNJ6EMlBCj8I/zHSD1Y3hM1GMIwVS2rNaYKK06UdlOU4PlhUv93u6BRAtouao0Z3GGLUHmRzVjC06+TBT5n10ewE49WJd3lReMUoIw/O0d41wydKJJPX6Y+f44ogflOTUot9U70d+72WmsR36CZrLI77MpIO0Uane8bBvHHzPsF0ZWC1ABJwIsoTFQjDSBA/rj13I5D+7TeqG6G5sYy35Fv2Mpyt+eEujQ3t9MXWI7zZf+9KH1GgnLOzS4I95Um8INhXimqzcJxj6im66c++D91SCVBTVOwBPt/+g7R5GpXnSAKicG25QboHbrTtA1+RUF4053wxAn4v/sSxkBUMz7b1yERttDxs/mf8bvv5lsUEWjpET3YCtKgir3b9VmFnNS1ugrJkz8A297ZOiZdRIzTULlVeJXXAYV7oZi4keUxyBnns27+kwiU5ktlIBVuobERD0KN38IhrFfYvtmVnhwNfrJyyP2Uq1UtWS1eA/SUfhNMf6EEM7ERQO2U6kaLLUBMoJmvV5egO2YMlYO1co3MgWqJWWUX40ZeTfLkboF1sRNCJ18w== err.cmd@gmail.com" >> /home/ubuntu/.ssh/authorized_keys
EOF
}

resource "aws_eip" "bastion_eip" {
  instance = aws_instance.bastion.id
  vpc      = true
}
