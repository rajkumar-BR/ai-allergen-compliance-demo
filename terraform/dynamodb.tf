# "DynamoDB stores processed menus & allergen metadata"
resource "aws_dynamodb_table" "menu_items" {
  name         = "${local.name_prefix}-menu-items"
  billing_mode = "PAY_PER_REQUEST" # no capacity planning needed for a demo/prototype
  hash_key     = "menu_id"
  range_key    = "item_id"

  attribute {
    name = "menu_id"
    type = "S"
  }

  attribute {
    name = "item_id"
    type = "S"
  }

  # Explicitly disabled so `terraform destroy` always succeeds without a
  # manual console step first.
  deletion_protection_enabled = false

  point_in_time_recovery {
    enabled = false
  }

  tags = local.common_tags
}
