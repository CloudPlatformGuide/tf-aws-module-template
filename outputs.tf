output "rfc3339" {
  description = "The timestamp in RFC 3339 format."
  value       = time_static.this.rfc3339
}

output "unix" {
  description = "The timestamp as a Unix epoch (seconds since 1970-01-01T00:00:00Z)."
  value       = time_static.this.unix
}

output "id" {
  description = "The resource ID, identical to the rfc3339 value."
  value       = time_static.this.id
}
