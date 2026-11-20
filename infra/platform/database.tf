resource "aws_security_group" "db" {
  name        = "${var.cluster_name}-db"
  description = "MySQL from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from cluster nodes (system and Karpenter nodes share this group)"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+" # avoids characters that need escaping in JDBC URLs and shells
}

resource "aws_db_instance" "dkm" {
  identifier     = "${var.cluster_name}-mysql"
  engine         = "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "dkm"
  username = "shop_admin"
  password = random_password.db.result

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az                = var.db_multi_az # demo: false; production: true
  backup_retention_period = 1
  # Demo: no final snapshot, because Flyway recreates the schema and sample data every session
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = !var.db_deletion_protection
  final_snapshot_identifier = var.db_deletion_protection ? "${var.cluster_name}-mysql-final" : null
  apply_immediately         = true
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.cluster_name}/db"
  description = "dkmwebapp database connection, synced into the cluster by External Secrets"
  # Delete immediately on destroy, so next session can create the same name again without a clash
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_db_instance.dkm.address
    port     = tostring(aws_db_instance.dkm.port)
    dbname   = aws_db_instance.dkm.db_name
    username = aws_db_instance.dkm.username
    password = random_password.db.result
  })
}
