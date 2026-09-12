# Raw menu file uploads (PDF/JPG/PNG) - "S3 stores raw images & PDFs"
resource "aws_s3_bucket" "menu_uploads" {
  bucket        = "${local.name_prefix}-menu-uploads-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # allows `terraform destroy` to remove the bucket even if objects exist

  tags = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "menu_uploads" {
  bucket                  = aws_s3_bucket.menu_uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "menu_uploads" {
  bucket = aws_s3_bucket.menu_uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
