# Where infra/foundation keeps its state for this environment. S3 native locking, no DynamoDB.
bucket       = "danielkojomegbenu-tfstate"
key          = "eks/foundation.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
