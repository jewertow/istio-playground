output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = aws_instance.bastion.public_ip
}

output "masters_subnet_ids" {
  description = "IDs of the dedicated master public subnets"
  value       = aws_subnet.masters_subnets[*].id
}

output "bastion_private_key_file" {
  description = "Path to the generated private key file for the bastion host"
  value       = local_file.bastion_private_key.filename
}
