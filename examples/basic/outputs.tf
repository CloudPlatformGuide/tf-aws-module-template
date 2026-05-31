output "rfc3339" {
  description = "Timestamp captured at first apply."
  value       = module.timestamp.rfc3339
}

output "unix" {
  description = "Unix epoch of the first apply."
  value       = module.timestamp.unix
}
