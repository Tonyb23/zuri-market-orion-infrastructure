# ── Public IP ──────────────────────────────────────────────── 
# The public IP address of the EC2 instance.
# You need this to open the app in the browser and to SSH in. 
output "instance_public_ip" {
    description = "The AWS EC2 instance public IP address."
    value = aws_instance.k3s-server.public_ip
}

# ── Instance ID ──────────────────────────────────────────────── 
output "instance_id" {
    description = "The AWS EC2 instance ID."
    value = aws_instance.k3s-server.id
}

# ── SSH Command ──────────────────────────────────────────────── 
# A ready-to-run SSH command to connect to the EC2 instance - just copy and paste it.
output "ssh_command" {
    description = "The SSH command to connect to the EC2 instance."
    value = "ssh -i ${var.key_pair_name}.pem ubuntu@${aws_instance.k3s-server.public_ip}"
}


# ── App URL ──────────────────────────────────────────────── 
output "app_url" {
    description = "The URL to access the app once K3s and the app are deployed"
    value = "http://${aws_instance.k3s-server.public_ip}:30080"
}

# ── VPC ID ──────────────────────────────────────────────── 
output "vpc_id" {
    description = "The ID of the VPC"
    value = aws_vpc.main.id
}