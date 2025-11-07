output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnets" {
  value = { for k, s in aws_subnet.this : k => {
    id   = s.id
    cidr = s.cidr_block
    az   = s.availability_zone
    type = s.tags["SubnetType"]
  } }
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.this : s.id if s.tags["SubnetType"] == "public"]
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.this : s.id if s.tags["SubnetType"] == "private"]
}
