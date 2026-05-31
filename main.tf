resource "time_static" "this" {
  rfc3339  = var.rfc3339
  triggers = var.triggers
}
