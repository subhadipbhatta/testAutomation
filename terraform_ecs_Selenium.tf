provider "aws" {
  region  = "us-east-2"
  shared_credentials_file = "enter path of your aws credential file"
  profile = "enter profile name"

}

variable "vpc_id" {
  type        = string
  description = "The id of a VPC in your AWS account"
  default = "vpc-xxxxxx"
}

variable subnet_public_ids {
  type    = list(string)  
  description = "The ids of the public subnet, for the load balancer"
  default = ["subnet-xxxx","subnet-xxxx"]
}

variable subnet_private_ids {
  type    = list(string)  
  description = "The ids of the private subnet, for the containers"
  default = ["subnet-xxxx"]
}

variable your_ip_addresses {
  type = list(string)
  description = "Change this to own IP address. Only use 0.0.0.0 for temporary testing"
  default = ["x.x.x.x/x","y.y.y.y/y"]
}

variable alb_ideal_timeout {
	type        = string
	description = "The Ideal Timeout setting for ALB Connection"
	default     = "900" 
}

variable cpu_scaleup_cool_period {
  description = "Cool up period for Scale out (must be 10,30 or multiply of 60)"
  type        = string
  default     = "10"
}

variable cpu_scaledown_cool_period {
  description = "Cool Down period for Scale out (must be 10,30 or multiply of 60)"
  type        = string
  default     = "10"
}

variable chrome_desired_count {
  description = "Initial count of the Chrome Service tasks"
  type        = string
  default     = "2"
}

variable firefox_desired_count {
  description = "Initial count of the Chrome Service tasks"
  type        = string
  default     = "1"
}

variable chrome_max_count {
  description = "Initial count of the Chrome Service tasks"
  type        = string
  default     = "10"
}

variable firefox_max_count {
  description = "Initial count of the Chrome Service tasks"
  type        = string
  default     = "2"
}


variable chrome_service_cpu_metric_upper_limit {
  description = "Chrome Service CPU threshold for Scale up tasks"
  type        = string
  default     = "4"
}

variable chrome_service_cpu_metric_lower_limit {
  description = "Chrome Service CPU threshold for Scale down tasks"
  type        = string
  default     = "3"
}


variable firefox_service_cpu_metric_upper_limit {
  description = "Firefox Service CPU threshold for Scale up tasks"
  type        = string
  default     = "4"
}

variable firefox_service_cpu_metric_lower_limit {
  description = "Firefox Service CPU threshold for Scale down tasks"
  type        = string
  default     = "3"
}


data "aws_vpc" "your_vpc" {
  id = var.vpc_id
}

## Create a security group to limit ingress

resource "aws_security_group" "sg_selenium_grid" {
  name        = "selenium_Grid"
  description = "Allow Selenium Grid ports within the VPC, and browsing from the outside"
  vpc_id      = var.vpc_id

   ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    # You should restrict this to your own IP
    # If creating internally, restrict it to your own range
    cidr_blocks = var.your_ip_addresses
    description = "Source System IP address"
  }

  ingress {
    from_port   = 4444
    to_port     = 4444
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.your_vpc.cidr_block,"x.x.x.x/x"]
    description = "Selenium Hub port"
  }

  ingress {
    from_port   = 5555
    to_port     = 5555
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.your_vpc.cidr_block,"x.x.x.x/x"]
    description = "Selenium Node port"
  }

   egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

}


## Create a role which allows ECS containers to perform actions such as write logs, call KMS

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "ecs_execution_policy" {
  name        = "ecsTaskExecutionPolicy"
  path        = "/"
  description = "Allows ECS containers to execute commands on our behalf"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:CreateLogGroup"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}


resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}


resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  # policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  policy_arn = aws_iam_policy.ecs_execution_policy.arn
}

## Service Discovery (AWS Cloud Map) for a private DNS, so containers can find each other

resource "aws_service_discovery_private_dns_namespace" "selenium" {
  name        = "selenium"
  description = "private DNS for selenium"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "hub" {
  name = "hub"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.selenium.id

    dns_records {
      ttl  = 60
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}


## ECS cluster, with default fargate spot containers

resource "aws_ecs_cluster" "selenium_grid" {
  name = "selenium-grid"
  capacity_providers = ["FARGATE_SPOT"]
  default_capacity_provider_strategy {
      capacity_provider = "FARGATE_SPOT"
      weight = 1
  }

}

## The definition for Selenium hub container

resource "aws_ecs_task_definition" "seleniumhub" {
  family                = "seleniumhub"
  network_mode = "awsvpc"
  container_definitions = <<DEFINITION
[
   {
        "name": "hub", 
        "image": "selenium/hub:latest", 
        "portMappings": [
            {
            "hostPort": 4444,
            "protocol": "tcp",
            "containerPort": 4444
            }
        ], 
        "essential": true, 
        "entryPoint": [], 
        "command": []
        
    }
]
DEFINITION

requires_compatibilities = ["FARGATE"]
cpu = 4096
memory = 30720

}

## Service for selenium hub container

resource "aws_ecs_service" "seleniumhub" {
  name          = "seleniumhub"
  cluster       = aws_ecs_cluster.selenium_grid.id
  desired_count = 1

  network_configuration {
      subnets = var.subnet_private_ids
      security_groups = [aws_security_group.sg_selenium_grid.id]
      assign_public_ip = false
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight = 1
  }

  platform_version = "LATEST"
  scheduling_strategy = "REPLICA"
  service_registries {
      registry_arn = aws_service_discovery_service.hub.arn
      container_name = "hub"
  }

  task_definition = aws_ecs_task_definition.seleniumhub.arn

  load_balancer {
    target_group_arn =   aws_lb_target_group.selenium-hub.arn
    container_name   = "hub"
    container_port   = 4444
  }

  depends_on = [aws_lb_target_group.selenium-hub, aws_lb.selenium-hub]


}
 
resource "aws_lb_target_group" "selenium-hub" {
  name        = "selenium-hub-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
}

resource "aws_lb" "selenium-hub" {
  name               = "selenium-hub-lb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg_selenium_grid.id]
  subnets            = var.subnet_public_ids
  
  idle_timeout       = var.alb_ideal_timeout
  enable_deletion_protection = false
}

resource "aws_lb_listener" "selenium-hub" {
  load_balancer_arn = aws_lb.selenium-hub.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.selenium-hub.arn
  }
}



## Definition for Firefox container

resource "aws_ecs_task_definition" "firefox" {
  family                = "seleniumfirefox"
  network_mode = "awsvpc"
  container_definitions = <<DEFINITION
[
   {
            "name": "hub", 
            "image": "selenium/node-firefox:latest", 
            "portMappings": [
                {
                    "hostPort": 5555,
                    "protocol": "tcp",
                    "containerPort": 5555
                }
            ],
            "essential": true, 
            "entryPoint": [], 
            "command": [ "/bin/bash", "-c", "PRIVATE=$(curl -s ${ECS_CONTAINER_METADATA_URI_V4} | jq -r '.Networks[0].IPv4Addresses[0]') ; export REMOTE_HOST=\"http://$PRIVATE:5555\" ; /opt/bin/entry_point.sh" ],
            "environment": [
                {
                  "name": "HUB_HOST",
                  "value": "hub.selenium"
                },
                {
                  "name": "HUB_PORT",
                  "value": "4444"
                },
                {
                    "name":"NODE_MAX_SESSION",
                    "value":"10"
                },
                {
                    "name":"NODE_MAX_INSTANCES",
                    "value":"10"
                },
				{
					"name":"browserTimeout",
					"value":"300000"
				}
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-create-group":"true",
                    "awslogs-group": "awslogs-selenium",
                    "awslogs-region": "us-east-2",
                    "awslogs-stream-prefix": "firefox"
                }
            }
        }
]
DEFINITION

  requires_compatibilities = ["FARGATE"]
  cpu = 4096
  memory = 30720
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn

}



## Service for firefox  container

resource "aws_ecs_service" "firefox" {
  name          = "seleniumfirefox"
  
  cluster       = aws_ecs_cluster.selenium_grid.id
  desired_count = var.firefox_desired_count
  
  network_configuration {
      subnets = var.subnet_private_ids
      security_groups = [aws_security_group.sg_selenium_grid.id]
      assign_public_ip = false

  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight = 1
  }

  platform_version = "LATEST"
  scheduling_strategy = "REPLICA"
  

  task_definition = aws_ecs_task_definition.firefox.arn

}



## Definition for Chrome container

resource "aws_ecs_task_definition" "chrome" {
  family                = "seleniumchrome"
  network_mode = "awsvpc"
  container_definitions = <<DEFINITION
[
   {
            "name": "hub", 
            "image": "selenium/node-chrome:latest", 
            "portMappings": [
                {
                    "hostPort": 5555,
                    "protocol": "tcp",
                    "containerPort": 5555
                }
            ],
            "essential": true, 
            "entryPoint": [], 
            "command": [ "/bin/bash", "-c", "PRIVATE=$(curl -s ${ECS_CONTAINER_METADATA_URI_V4} | jq -r '.Networks[0].IPv4Addresses[0]') ; export REMOTE_HOST=\"http://$PRIVATE:5555\" ; /opt/bin/entry_point.sh" ],
            "environment": [
                {
                  "name": "HUB_HOST",
                  "value": "hub.selenium"
                },
                {
                  "name": "HUB_PORT",
                  "value": "4444"
                },
                {
                    "name":"NODE_MAX_SESSION",
                    "value":"25"
                },
                {
                    "name":"NODE_MAX_INSTANCES",
                    "value":"25"
                },
				{
					"name":"browserTimeout",
					"value":"300000"
				}
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-create-group":"true",
                    "awslogs-group": "awslogs-selenium",
                    "awslogs-region": "us-east-2",
                    "awslogs-stream-prefix": "chrome"
                }
            }
        }
]
DEFINITION

  requires_compatibilities = ["FARGATE"]
  cpu = 4096
  memory = 30720
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn

}

## Step Auto Scaling Service Targate

resource "aws_appautoscaling_target" "chrome_target" {
  max_capacity       = var.chrome_max_count
  min_capacity       = 2
  resource_id        = "service/selenium-grid/seleniumchrome"
  scalable_dimension = "ecs:service:DesiredCount"
  
  service_namespace  = "ecs"
  
  depends_on = [aws_ecs_service.chrome,aws_ecs_task_definition.chrome,aws_ecs_cluster.selenium_grid]
}

resource "aws_appautoscaling_target" "firefox_target" {
  max_capacity       = var.firefox_max_count
  min_capacity       = 2
  resource_id        = "service/selenium-grid/seleniumfirefox"
  scalable_dimension = "ecs:service:DesiredCount"
  
  service_namespace  = "ecs"
  
  depends_on = [aws_ecs_service.chrome,aws_ecs_task_definition.chrome,aws_ecs_cluster.selenium_grid]
}

resource "aws_appautoscaling_policy" "chrome_targate_down_policy" {
  name               = "Chrome_Service_Scale-Down"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.chrome_target.resource_id
  scalable_dimension = aws_appautoscaling_target.chrome_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.chrome_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = var.cpu_scaledown_cool_period
    metric_aggregation_type = "Average"

    step_adjustment {
	  metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
  depends_on = [aws_ecs_service.chrome,aws_ecs_task_definition.chrome,aws_ecs_cluster.selenium_grid,aws_appautoscaling_target.chrome_target]
}

resource "aws_appautoscaling_policy" "chrome_targate_up_policy" {
  name               = "Chrome_Service_Scale-Up"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.chrome_target.resource_id
  scalable_dimension = aws_appautoscaling_target.chrome_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.chrome_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = var.cpu_scaleup_cool_period
    metric_aggregation_type = "Average"

    step_adjustment {
	  metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
  depends_on = [aws_ecs_service.chrome,aws_ecs_task_definition.chrome,aws_ecs_cluster.selenium_grid,aws_appautoscaling_target.chrome_target]
}

resource "aws_cloudwatch_metric_alarm" "chrome_cpu_scaleup" {
  alarm_name          = "Chrome_cpu_scaleup"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "ECS"
  period              = var.cpu_scaleup_cool_period
  statistic           = "Average"
  threshold           = var.chrome_service_cpu_metric_upper_limit

  alarm_description = format(
    "Average service %v utilization %v last %d minute(s) over %v period(s)",
    "CPU",
    "High",
    1,
    1
	)

  alarm_actions     = [aws_appautoscaling_policy.chrome_targate_up_policy.arn]
  ok_actions    = []
  dimensions = {"ClusterName" = "selenium-grid"
				"ServiceName" = aws_ecs_service.chrome.name}

  depends_on = [aws_ecs_service.chrome,aws_ecs_task_definition.chrome,aws_ecs_cluster.selenium_grid,aws_appautoscaling_target.chrome_target,aws_appautoscaling_policy.chrome_targate_up_policy]				
}

resource "aws_cloudwatch_metric_alarm" "chrome_cpu_scaledown" {
  alarm_name          = "Chrome_cpu_scaledown"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "ECS"
  period              = var.cpu_scaleup_cool_period
  statistic           = "Average"
  threshold           = var.chrome_service_cpu_metric_lower_limit

  alarm_description = format(
    "Average service %v utilization %v last %d minute(s) over %v period(s)",
    "CPU",
    "High",
    1,
    1
	)

  alarm_actions     = [aws_appautoscaling_policy.chrome_targate_down_policy.arn]
  ok_actions    = []
  dimensions = {"ClusterName" = "selenium-grid"
				"ServiceName" = aws_ecs_service.chrome.name}
  
  depends_on = [aws_ecs_service.chrome,aws_ecs_task_definition.chrome,aws_ecs_cluster.selenium_grid,aws_appautoscaling_target.chrome_target,aws_appautoscaling_policy.chrome_targate_down_policy]
  
}

## Service for chrome  container

resource "aws_ecs_service" "chrome" {
  name          = "seleniumchrome"
  cluster       = aws_ecs_cluster.selenium_grid.id
  desired_count = var.chrome_desired_count

  network_configuration {
      subnets = var.subnet_private_ids
      security_groups = [aws_security_group.sg_selenium_grid.id]
      assign_public_ip = false
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight = 1
  }

  platform_version = "LATEST"
  scheduling_strategy = "REPLICA"
  

  task_definition = aws_ecs_task_definition.chrome.arn

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}


output "hub_address" {
  value = aws_lb.selenium-hub.dns_name
}