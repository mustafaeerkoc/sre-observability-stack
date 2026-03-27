output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.sre.id
}

output "public_ip" {
  description = "Elastic IP address"
  value       = aws_eip.sre.public_ip
}

output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_eip.sre.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL"
  value       = "http://${aws_eip.sre.public_ip}:9090"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i terraform/sre-key.pem ubuntu@${aws_eip.sre.public_ip}"
}
